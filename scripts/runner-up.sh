#!/usr/bin/env bash
# Starts the self-hosted GitHub Actions runner that executes promotion gates
# (ADR-015). Fully scripted - no console steps:
#   1. RBAC: ServiceAccount ci-gate with read-only access (view + Argo CD
#      Applications/Rollouts + the Prometheus service proxy)
#   2. a kubeconfig for that SA, addressed to the cluster's internal endpoint
#   3. the runner image (official runner + kubectl + jq)
#   4. a registration token from the GitHub API, then the container
# The runner only ever receives jobs from the release workflow (push/dispatch
# on main); fork PRs need approval and never target it.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
. "$(dirname "$0")/lib/common.sh"
load_config
require docker
require kubectl
require kind
require gh

root=$(repo_root)
export KUBECONFIG="$root/.local/kubeconfig"
repo="$GITHUB_OWNER/$GITHUB_REPO"
dir="$root/.local/runner"
mkdir -p "$dir"

log "applying read-only RBAC for ci-gate"
kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata: { name: ci-gate, namespace: argocd }
---
apiVersion: v1
kind: Secret
metadata:
  name: ci-gate-token
  namespace: argocd
  annotations: { kubernetes.io/service-account.name: ci-gate }
type: kubernetes.io/service-account-token
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: ci-gate-read }
rules:
  - apiGroups: [argoproj.io]
    resources: [applications, rollouts, analysisruns]
    verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: ci-gate-read }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: ci-gate-read }
subjects: [{ kind: ServiceAccount, name: ci-gate, namespace: argocd }]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: ci-gate-view }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: view }
subjects: [{ kind: ServiceAccount, name: ci-gate, namespace: argocd }]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: ci-gate-prometheus-proxy, namespace: monitoring }
rules:
  - apiGroups: [""]
    resources: [services/proxy]
    resourceNames: ["http:kube-prometheus-stack-prometheus:9090"]
    verbs: [get]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: ci-gate-prometheus-proxy, namespace: monitoring }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: ci-gate-prometheus-proxy }
subjects: [{ kind: ServiceAccount, name: ci-gate, namespace: argocd }]
EOF

for _ in $(seq 1 30); do
  token=$(kubectl -n argocd get secret ci-gate-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
  [ -n "$token" ] && break
  sleep 1
done
[ -n "$token" ] || die "ci-gate token was not issued"

log "writing read-only kubeconfig (internal endpoint) to .local/runner/kubeconfig"
internal=$(kind get kubeconfig --internal --name "$KIND_CLUSTER")
server=$(printf '%s\n' "$internal" | sed -n 's/^ *server: //p' | head -1)
ca=$(printf '%s\n' "$internal" | sed -n 's/^ *certificate-authority-data: //p' | head -1)
cat > "$dir/kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters: [{ name: zdp, cluster: { server: $server, certificate-authority-data: $ca } }]
users: [{ name: ci-gate, user: { token: $token } }]
contexts: [{ name: ci-gate, context: { cluster: zdp, user: ci-gate } }]
current-context: ci-gate
EOF
chmod 600 "$dir/kubeconfig"

log "building runner image"
docker build -q -t zdp-runner:local --build-arg RUNNER_IMAGE="$ACTIONS_RUNNER_IMAGE" "$root/scripts/runner" >/dev/null

log "requesting a registration token"
reg=$(gh api -X POST "repos/$repo/actions/runners/registration-token" --jq .token)

docker rm -f zdp-runner >/dev/null 2>&1 || true
MSYS_NO_PATHCONV=1 docker run -d --name zdp-runner --restart unless-stopped --network kind \
  -e REPO_URL="https://github.com/$repo" -e RUNNER_TOKEN="$reg" -e RUNNER_NAME=zdp-local-kind \
  -e KUBECONFIG=/home/runner/.kube/kubeconfig \
  -v "$(host_path "$dir"):/home/runner/.kube:ro" \
  zdp-runner:local >/dev/null

for _ in $(seq 1 60); do
  status=$(gh api "repos/$repo/actions/runners" --jq '.runners[] | select(.name=="zdp-local-kind") | .status' 2>/dev/null || true)
  [ "$status" = online ] && break
  sleep 2
done
[ "$status" = online ] || die "runner did not come online (docker logs zdp-runner)"
log "runner zdp-local-kind is online (labels: self-hosted, local-kind)"

# Prove the credentials are read-only and sufficient.
MSYS_NO_PATHCONV=1 docker exec zdp-runner kubectl -n argocd get applications >/dev/null \
  || die "runner cannot read Argo CD applications"
if MSYS_NO_PATHCONV=1 docker exec zdp-runner kubectl -n argocd delete application root --dry-run=server >/dev/null 2>&1; then
  die "runner credentials can delete Applications - expected read-only"
fi
log "verified: runner kubeconfig reads applications and cannot modify them"
