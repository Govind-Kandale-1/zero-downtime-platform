#!/usr/bin/env bash
# Rebuild what happened during a canary from Prometheus' own records, so the
# evidence does not depend on a recorder having been running at the time.
#
# Usage: canary-timeline.sh <namespace> <start> <end> [step_s]
#   start/end: anything `date -d` accepts, e.g. 2026-10-25T14:09:00Z
# CSV, one row per step (rates are 1-minute averages):
#   time_utc,stable_rps,canary_rps,canary_pct,http_5xx_rps,p95_ms,hpa_desired,
#   api_inflight,worker_desired,queue_depth,ready_pods_per_replicaset
# Also used for load tests (evidence 03): in-flight requests show saturation,
# and the worker columns show the queue being drained.
set -euo pipefail
# shellcheck source=scripts/lib/tools.sh
. "$(dirname "$0")/lib/tools.sh"
KUBECONFIG=${KUBECONFIG:-"$(repo_root)/.local/kubeconfig"}
export KUBECONFIG

[ $# -ge 3 ] || die "usage: canary-timeline.sh <namespace> <start> <end> [step_s]"
ns=$1
start=$(date -u -d "$2" +%s)
end=$(date -u -d "$3" +%s)
step=${4:-15}
svc="$ns-api-(stable|canary)-.*"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# series <file> <promql>: writes "epoch value [replicaset]" lines.
series() {
  local enc
  enc=$(printf '%s' "$2" | tool_jq -sRr @uri)
  kubectl get --raw "/api/v1/namespaces/monitoring/services/http:kube-prometheus-stack-prometheus:9090/proxy/api/v1/query_range?query=$enc&start=$start&end=$end&step=$step" \
    | tool_jq -r '.data.result[] | (.metric.replicaset // "") as $rs | .values[] | "\(.[0] | floor) \(.[1]) \($rs)"' > "$tmp/$1"
}

series 1 "sum(rate(traefik_service_requests_total{service=~\"$ns-api-stable-.*\"}[1m]))"
series 2 "sum(rate(traefik_service_requests_total{service=~\"$ns-api-canary-.*\"}[1m]))"
series 3 "sum(rate(traefik_service_requests_total{service=~\"$svc\",code=~\"5..\"}[1m])) or vector(0)"
series 4 "histogram_quantile(0.95, sum by (le) (rate(traefik_service_request_duration_seconds_bucket{service=~\"$svc\"}[1m]))) * 1000"
series 5 "max(kube_horizontalpodautoscaler_status_desired_replicas{namespace=\"$ns\",horizontalpodautoscaler=\"keda-hpa-api\"})"
series 6 "sum(http_inflight_requests{namespace=\"$ns\",pod=~\"api-.*\"})"
series 7 "max(kube_horizontalpodautoscaler_status_desired_replicas{namespace=\"$ns\",horizontalpodautoscaler=\"keda-hpa-worker\"})"
series 8 "max(queue_depth{namespace=\"$ns\"})"
series rs "sum by (replicaset) (kube_replicaset_status_ready_replicas{namespace=\"$ns\",replicaset=~\"api-.*\"})"

echo "time_utc,stable_rps,canary_rps,canary_pct,http_5xx_rps,p95_ms,hpa_desired,api_inflight,worker_desired,queue_depth,ready_pods_per_replicaset"
awk -v start="$start" -v end="$end" -v step="$step" '
  FILENAME ~ /\/rs$/ { if ($2 + 0 > 0) rs[$1] = (rs[$1] == "" ? "" : rs[$1] " ") $3 "=" $2; next }
  { n = FILENAME; sub(/.*\//, "", n); v[$1, n] = $2 }
  END {
    for (t = start; t <= end; t += step) {
      s = v[t, 1] + 0; c = v[t, 2] + 0
      pct = (s + c > 0) ? 100 * c / (s + c) : 0
      printf "%s,%.1f,%.1f,%.0f,%.2f,%s,%s,%s,%s,%s,%s\n", strftime("%H:%M:%S", t, 1), s, c, pct, v[t, 3] + 0,
        (v[t, 4] == "" || v[t, 4] == "NaN") ? "" : sprintf("%.0f", v[t, 4]), v[t, 5], v[t, 6], v[t, 7], v[t, 8], rs[t]
    }
  }' "$tmp/1" "$tmp/2" "$tmp/3" "$tmp/4" "$tmp/5" "$tmp/6" "$tmp/7" "$tmp/8" "$tmp/rs"
