#!/usr/bin/env bash
# Renders charts/app with each fixture and asserts the zero-downtime, scaling,
# SLO and safety properties the platform relies on. Also schema-validates the
# output (core kinds + CRDs from the datree catalog) with kubeconform.
set -euo pipefail
# shellcheck source=scripts/lib/tools.sh
. "$(git rev-parse --show-toplevel)/scripts/lib/tools.sh"
chart="$(repo_root)/charts/app"
t="$chart/tests"
fails=0
check() { # name, actual, expected
  if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (got '$2', want '$3')"; fails=$((fails + 1)); fi
}
render() { helm template app "$chart" -f "$t/$1" --kube-version 1.34.0 --namespace "$2"; }
# yq prints "---" separators and blank lines for documents that do not match.
q() { printf '%s\n' "$1" | tool_yq -N -r "$2" | sed '/^---$/d;/^$/d'; }

prod=$(render values-prod.yaml app-prod)
check "api canary steps 10/25/50" \
  "$(q "$prod" 'select(.kind=="Rollout" and .metadata.name=="api") | [.spec.strategy.canary.steps[] | select(has("setWeight")) | .setWeight] | join(",")')" "10,25,50"
check "api canary routes via Traefik weighted service" \
  "$(q "$prod" 'select(.kind=="Rollout" and .metadata.name=="api") | .spec.strategy.canary.trafficRouting.traefik.weightedTraefikServiceName')" "api"
check "api preStop sleep 5s" \
  "$(q "$prod" 'select(.kind=="Rollout" and .metadata.name=="api") | .spec.template.spec.containers[0].lifecycle.preStop.sleep.seconds')" "5"
check "worker steps 25/50" \
  "$(q "$prod" 'select(.kind=="Rollout" and .metadata.name=="worker") | [.spec.strategy.canary.steps[] | select(has("setWeight")) | .setWeight] | join(",")')" "25,50"
check "worker terminationGracePeriodSeconds 90" \
  "$(q "$prod" 'select(.kind=="Rollout" and .metadata.name=="worker") | .spec.template.spec.terminationGracePeriodSeconds')" "90"
check "presync backup secret is optional" \
  "$(q "$prod" 'select(.kind=="Job" and .metadata.name=="presync-backup") | .spec.template.spec.containers[0].envFrom[0].secretRef.optional')" "true"
# Backup storage is provider-layer infrastructure (Terraform creates PVC
# "pg-backups" before Argo CD syncs). The chart must not own it: as a plain
# resource it does not exist when the PreSync hook first runs, and as a hook
# Argo CD's default BeforeHookCreation policy would delete it - and the
# backups on it - before every sync.
check "chart does not own the backup PVC (provider layer does)" \
  "$(q "$prod" 'select(.kind=="PersistentVolumeClaim") | .metadata.name' | wc -l | tr -d ' ')" "0"
check "backup jobs mount the provider-layer claim" \
  "$(q "$prod" 'select(.kind=="Job" and .metadata.name=="presync-backup") | .spec.template.spec.volumes[] | select(.name=="backups") | .persistentVolumeClaim.claimName')" "pg-backups"
check "presync backup is an Argo CD PreSync hook" \
  "$(q "$prod" 'select(.kind=="Job" and .metadata.name=="presync-backup") | .metadata.annotations["argocd.argoproj.io/hook"]')" "PreSync"
check "both ScaledObjects target Rollouts" \
  "$(q "$prod" 'select(.kind=="ScaledObject") | .spec.scaleTargetRef.kind' | sort -u | tr '\n' ' ')" "Rollout "
check "API ScaledObject scales on Traefik RPS per pod" \
  "$(q "$prod" 'select(.kind=="ScaledObject" and .metadata.name=="api") | .spec.triggers[] | select(.type=="prometheus") | .metadata.threshold')" "70"
check "worker ScaledObject scales on list length 5" \
  "$(q "$prod" 'select(.kind=="ScaledObject" and .metadata.name=="worker") | .spec.triggers[0].metadata.listLength')" "5"
check "PDBs for api and worker" \
  "$(q "$prod" 'select(.kind=="PodDisruptionBudget") | .metadata.name' | sort | tr '\n' ' ')" "api worker "
check "images pinned by digest, never a tag" \
  "$(q "$prod" 'select(.kind=="Rollout") | .spec.template.spec.containers[0].image' | grep -cv '@sha256:' || true)" "0"
check "default-deny ingress NetworkPolicy" \
  "$(q "$prod" 'select(.kind=="NetworkPolicy" and .metadata.name=="default-deny-ingress") | .spec.policyTypes[0]')" "Ingress"
check "containers run non-root with read-only root FS" \
  "$(q "$prod" 'select(.kind=="Rollout") | .spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem' | sort -u)" "true"
check "Rollouts leave replicas to KEDA" \
  "$(q "$prod" 'select(.kind=="Rollout") | .spec.replicas' | sort -u)" "null"

tenant=$(render values-tenant.yaml tenant-acme)
check "99.95 SLO renders objective 0.9995" \
  "$(q "$tenant" 'select(.kind=="PrometheusRule") | .spec.groups[].rules[] | select(.alert=="ZdpErrorBudgetBurnPage") | .labels.objective' | sort -u)" "0.9995"
check "tenant host defaults to <name>.localtest.me" \
  "$(q "$tenant" 'select(.kind=="IngressRoute") | .spec.routes[0].match')" 'Host(`acme.localtest.me`)'

dev=$(render values-dev.yaml app-dev)
check "dev overrides canary pause to 60s" \
  "$(q "$dev" 'select(.kind=="Rollout" and .metadata.name=="api") | .spec.strategy.canary.steps[1].pause.duration')" "60s"

if helm template app "$chart" -f "$t/values-nodigest.yaml" --kube-version 1.34.0 >/dev/null 2>&1; then
  check "render fails without image.digest" "rendered" "error"
else
  check "render fails without image.digest" "error" "error"
fi

for f in values-prod.yaml values-tenant.yaml values-dev.yaml; do
  if render "$f" ns | tool_kubeconform -strict -ignore-missing-schemas -kubernetes-version 1.34.0 -summary \
      -schema-location default \
      -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' - >/dev/null; then
    check "kubeconform ($f)" ok ok
  else
    check "kubeconform ($f)" invalid ok
  fi
done

# Regression: a code-review.md inside templates/ is rendered as a manifest and
# breaks the chart unless .helmignore excludes it.
pkg=$(mktemp -d)
helm package "$chart" -d "$pkg" >/dev/null
check "packaged chart excludes docs and tests" \
  "$(tar -tzf "$pkg"/app-*.tgz | grep -cE 'code-review\.md|/tests/' || true)" "0"
rm -rf "$pkg"

# PromQL inside the PrometheusRule is just a string to Helm and kubeconform;
# promtool (same version as the cluster's Prometheus) actually parses it.
tmp=$(mktemp -d)
q "$tenant" 'select(.kind=="PrometheusRule") | .spec' > "$tmp/rules.yaml"
# mktemp dirs are 0700; the distroless Prometheus image runs as nobody.
chmod -R a+rX "$tmp"
if out=$(MSYS_NO_PATHCONV=1 docker run --rm -v "$(host_path "$tmp"):/r" --entrypoint promtool \
    "$PROMETHEUS_IMAGE" check rules /r/rules.yaml 2>&1); then
  check "promtool parses SLO recording + alert rules" ok ok
else
  printf '%s\n' "$out" | tail -5
  check "promtool parses SLO recording + alert rules" invalid ok
fi
rm -rf "$tmp"

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "ALL PASS"
