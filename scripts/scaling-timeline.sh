#!/usr/bin/env bash
# Sample how a stack scales during a load test, every 5 s, as CSV:
#   epoch_s,elapsed_s,api_desired,api_ready,worker_desired,worker_ready,queue_depth,edge_rps
# Usage: scaling-timeline.sh <namespace> <seconds>
set -euo pipefail
# shellcheck source=scripts/lib/tools.sh
. "$(dirname "$0")/lib/tools.sh"
KUBECONFIG="$(repo_root)/.local/kubeconfig"
export KUBECONFIG

ns=${1:?namespace}
secs=${2:?seconds}
start=$(date +%s)
q='sum(rate(traefik_service_requests_total{service=~"'"$ns"'-api-(stable|canary)-.*"}[1m]))'
enc=$(printf '%s' "$q" | tool_jq -sRr @uri)

echo "epoch_s,elapsed_s,api_desired,api_ready,worker_desired,worker_ready,queue_depth,edge_rps"
while [ $(($(date +%s) - start)) -lt "$secs" ]; do
  now=$(date +%s)
  api=$(kubectl -n "$ns" get rollout api -o jsonpath='{.spec.replicas},{.status.readyReplicas}' 2>/dev/null || echo ",")
  wrk=$(kubectl -n "$ns" get rollout worker -o jsonpath='{.spec.replicas},{.status.readyReplicas}' 2>/dev/null || echo ",")
  depth=$(kubectl -n "$ns" exec valkey-0 -c valkey -- valkey-cli LLEN jobs 2>/dev/null || echo "")
  rps=$(kubectl get --raw "/api/v1/namespaces/monitoring/services/http:kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=$enc" 2>/dev/null \
    | tool_jq -r '.data.result[0].value[1] // "0"' 2>/dev/null | cut -c1-8 || echo "")
  echo "$now,$((now - start)),$api,$wrk,$depth,$rps"
  sleep 5
done
