#!/usr/bin/env bash
# Before a load test on the laptop: free memory and refuse to start without
# headroom, so OOM kills never masquerade as application errors.
#   preflight-load.sh            pin non-prod stacks (dev, staging, acme, globex)
#                                to 1 replica via KEDA paused-replicas, then
#                                check projected peak memory requests <= 6.5 GiB
#   preflight-load.sh --restore  unpin them
set -euo pipefail
# shellcheck source=scripts/lib/tools.sh
. "$(dirname "$0")/lib/tools.sh"
KUBECONFIG="$(repo_root)/.local/kubeconfig"
export KUBECONFIG

others=(app-dev app-staging tenant-acme tenant-globex)
budget_mi=$((6656)) # 6.5 GiB

if [ "${1:-}" = "--restore" ]; then
  for ns in "${others[@]}"; do
    kubectl -n "$ns" annotate scaledobject api worker autoscaling.keda.sh/paused-replicas- >/dev/null 2>&1 || true
  done
  log "restored autoscaling for: ${others[*]}"
  exit 0
fi

for ns in "${others[@]}"; do
  kubectl -n "$ns" annotate scaledobject api worker autoscaling.keda.sh/paused-replicas=1 --overwrite >/dev/null
done
log "pinned to 1 replica during the test: ${others[*]}"
sleep 20 # let KEDA scale them down

# Current requests across all pods, in MiB.
current=$(kubectl get pods -A --field-selector=status.phase=Running -o json \
  | tool_jq '[.items[].spec.containers[].resources.requests.memory // "0"
              | if endswith("Gi") then (.[:-2] | tonumber * 1024)
                elif endswith("Mi") then (.[:-2] | tonumber)
                else 0 end] | add | floor')

# Projected growth of the stack under test (prod): extra pods up to max.
req_mi() { # pod memory request of a rollout's first container, in MiB
  kubectl -n app-prod get rollout "$1" -o jsonpath='{.spec.template.spec.containers[0].resources.requests.memory}' | sed 's/Mi$//'
}
grow() { # rollout name -> extra MiB if it scales from current to KEDA max
  local cur max
  cur=$(kubectl -n app-prod get rollout "$1" -o jsonpath='{.status.replicas}')
  max=$(kubectl -n app-prod get scaledobject "$1" -o jsonpath='{.spec.maxReplicaCount}')
  echo $(((max - cur) * $(req_mi "$1")))
}
peak=$((current + $(grow api) + $(grow worker)))
log "memory requests now ${current} MiB; projected peak with prod at max replicas ${peak} MiB; budget ${budget_mi} MiB"
if [ "$peak" -gt "$budget_mi" ]; then
  die "projected peak exceeds the budget by $((peak - budget_mi)) MiB - lower maxReplicas or free memory"
fi
log "OK: headroom $((budget_mi - peak)) MiB"
