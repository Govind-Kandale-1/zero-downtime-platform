#!/usr/bin/env bash
# One command: empty laptop (Docker running) -> running platform.
#   1. preflight (tools, Docker memory, GitHub auth)
#   2. Terraform state backend (Postgres container)
#   3. provider layer: 10-cluster -> 20-data -> 30-gitops (Argo CD + root app)
#   4. wait until Argo CD has installed the whole platform layer
#   5. self-hosted runner for the promotion gates (skip with --no-runner)
# Re-running is safe: every step is idempotent.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
. "$(dirname "$0")/lib/common.sh"
load_config

runner=yes
[ "${1:-}" = "--no-runner" ] && runner=no

root=$(repo_root)
cd "$root"
start=$(date +%s)

log "preflight"
for c in docker kind terraform helm kubectl gh git; do require "$c"; done
docker info >/dev/null 2>&1 || die "Docker is not running"
mem=$(docker info --format '{{.MemTotal}}')
[ "$mem" -ge $((9 * 1024 * 1024 * 1024)) ] || log "WARNING: Docker has $((mem / 1024 / 1024)) MiB; 9+ GiB recommended (the 15x load test needs it)"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated (gh auth login)"

log "terraform state backend"
bash scripts/state-up.sh
# shellcheck source=/dev/null
. .local/tfstate.env

apply() {
  log "terraform apply infra/live/local/$1"
  terraform -chdir="infra/live/local/$1" init -input=false -no-color >/dev/null
  terraform -chdir="infra/live/local/$1" apply -auto-approve -input=false -no-color >/dev/null
}
apply 10-cluster
bash scripts/state-up.sh # attach the state DB to the new "kind" network
apply 20-data
bash infra/live/local/20-data/tests/contract_test.sh | tail -1
apply 30-gitops

log "waiting for Argo CD to install the platform layer (up to 20 min)"
ok=no
for _ in $(seq 1 40); do
  if bash gitops/tests/platform_test.sh >/dev/null 2>&1; then ok=yes; break; fi
  sleep 30
done
[ "$ok" = yes ] || { bash gitops/tests/platform_test.sh || true; die "platform did not become healthy"; }
bash gitops/tests/platform_test.sh | tail -1

if [ "$runner" = yes ]; then
  bash scripts/runner-up.sh
fi

export KUBECONFIG="$root/.local/kubeconfig"
pw=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
log "platform ready in $(( ($(date +%s) - start) / 60 )) min $(( ($(date +%s) - start) % 60 )) s"
cat <<EOF

  Argo CD     http://argocd.localtest.me      (admin / $pw)
  Grafana     http://grafana.localtest.me
  Rollouts    http://rollouts.localtest.me
  Prometheus  http://prometheus.localtest.me
  kubectl     export KUBECONFIG=$root/.local/kubeconfig

  Apps appear per stack once a release is promoted (GitHub Actions: release).
EOF
