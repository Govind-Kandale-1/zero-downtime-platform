#!/usr/bin/env bash
# Proves the platform layer is up: every Argo CD Application Synced/Healthy,
# ingress serving, Prometheus scraping Traefik, ESO connected to the secrets
# manager, and resource metrics available (needed by HPA/KEDA).
set -euo pipefail
# shellcheck source=scripts/lib/tools.sh
. "$(git rev-parse --show-toplevel)/scripts/lib/tools.sh"
KUBECONFIG="$(repo_root)/.local/kubeconfig"
export KUBECONFIG
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

apps=$(kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name}={.status.sync.status}/{.status.health.status}{"\n"}{end}')
[ -n "$apps" ] || fail "no Argo CD applications"
while IFS= read -r line; do
  [ -z "$line" ] && continue
  case "$line" in
    *=Synced/Healthy) pass "app ${line%%=*} Synced/Healthy" ;;
    *) fail "app $line" ;;
  esac
done <<< "$apps"

code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: grafana.localtest.me' http://127.0.0.1/api/health || true)
[ "$code" = 200 ] && pass "grafana via traefik ingress (200)" || fail "grafana via ingress returned $code"

q='up%7Bjob%3D~%22.%2Atraefik.%2A%22%7D'
up=$(kubectl get --raw "/api/v1/namespaces/monitoring/services/http:kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=$q" 2>/dev/null \
  | tool_jq -r '.data.result[0].value[1] // "none"' 2>/dev/null || echo none)
[ "$up" = 1 ] && pass "prometheus scrapes traefik (up=1)" || fail "prometheus traefik up=$up"

css=$(kubectl get clustersecretstore platform-secrets -o jsonpath='{.status.conditions[0].status}' 2>/dev/null || true)
[ "$css" = True ] && pass "ClusterSecretStore platform-secrets Ready" || fail "ClusterSecretStore status '$css'"

kubectl top nodes >/dev/null 2>&1 && pass "kubectl top nodes (metrics-server)" || fail "kubectl top nodes"

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "ALL PASS"
