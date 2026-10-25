#!/usr/bin/env bash
# Promotion gate between release stages (ADR-015). Runs on the self-hosted
# runner with a READ-ONLY kubeconfig: it never deploys, it only checks that
# what Argo CD pulled is healthy, is the exact artifact, and behaves well.
#
# Usage: gate.sh <stage> <stack> [<stack>...]
# For every stack:
#   1. Argo CD Application stack-<stack> is Synced/Healthy at the stage's chart version
#   2. Rollouts api + worker are Healthy and complete, running the stage's image digest
#   3. after a soak, edge SLIs hold: 5xx ratio < 0.5%, p95 < 400 ms
#   4. the worker keeps up: oldest queued job < 120 s
# Prints "GATE PASS <stage>/<stack>" or "GATE FAIL <stage>/<stack>: <check>: <detail>"
# and exits 1 on the first failure. No data is a failure ("no traffic"), never
# a pass. Checks 1-2 poll until GATE_TIMEOUT, so a gate cannot hang.
#
# Env: GATE_TIMEOUT (900 s), GATE_POLL (15 s), GATE_SOAK (180 s),
#      EXPECT_VERSION / EXPECT_DIGEST (override the release file), KUBECONFIG.
set -euo pipefail
# shellcheck source=scripts/lib/tools.sh
. "$(dirname "$0")/lib/tools.sh"

[ $# -ge 2 ] || die "usage: gate.sh <stage> <stack> [<stack>...]"
stage=$1
shift
timeout=${GATE_TIMEOUT:-900}
poll=${GATE_POLL:-15}
soak=${GATE_SOAK:-180}

cd "$(git rev-parse --show-toplevel)"
file="gitops/releases/$stage.yaml"
[ -f "$file" ] || die "no release file $file"
version=${EXPECT_VERSION:-$(sed -n 's/^  version: "\(.*\)"$/\1/p' "$file")}
digest=${EXPECT_DIGEST:-$(sed -n 's/^  digest: "\(.*\)"$/\1/p' "$file")}
[ -n "$version" ] && [ -n "$digest" ] || die "cannot read chart version / digest from $file"
log "gate $stage: expecting chart $version, image ${digest:7:12}, stacks: $*"

gate_fail() { echo "GATE FAIL $stage/$1: $2: $3"; exit 1; }

ns_of() { case "$1" in dev | staging | prod) echo "app-$1" ;; *) echo "tenant-$1" ;; esac; }

urlencode() {
  local s=$1 out="" c hex i
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case "$c" in
      [a-zA-Z0-9.~_-]) out+=$c ;;
      *) printf -v hex '%%%02X' "'$c"; out+=$hex ;;
    esac
  done
  printf '%s' "$out"
}

# Instant query through the API server's service proxy (no port-forward, no
# inbound access to the cluster). Prints the scalar, or "none" when empty.
prom() {
  kubectl get --raw "/api/v1/namespaces/monitoring/services/http:kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=$(urlencode "$1")" \
    | tool_jq -r '.data.result[0].value[1] // "none"'
}

is_num() { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$ ]]; }
lt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 < b + 0) }'; }

for s in "$@"; do
  ns=$(ns_of "$s")
  app="stack-$s"
  deadline=$(($(date +%s) + timeout))

  # 1. Argo CD has synced this stack to the stage's chart version and is Healthy.
  while :; do
    state=$(kubectl -n argocd get application "$app" -o json 2>/dev/null \
      | tool_jq -r '[.status.sync.status // "", .status.health.status // "", ((.status.sync.revisions // [.status.sync.revision // ""]) | join(","))] | @tsv' 2>/dev/null || true)
    IFS=$'\t' read -r sync health revs <<< "$state" || true
    if [ "${sync:-}/${health:-}" = "Synced/Healthy" ] && [[ ",${revs:-}," == *",$version,"* ]]; then
      break
    fi
    # A new or updating stack can be briefly Degraded while it converges (e.g.
    # its ExternalSecret has not synced yet), so Degraded alone is not a
    # verdict; an aborted canary is (check 2), and so is the deadline.
    [ "$(date +%s)" -ge "$deadline" ] \
      && gate_fail "$s" "Application not Synced/Healthy" "sync=${sync:-?} health=${health:-?} revisions=${revs:-?} (want chart $version)"
    sleep "$poll"
  done

  # 2. Both rollouts finished on exactly the promoted digest.
  for r in api worker; do
    while :; do
      ro=$(kubectl -n "$ns" get rollout "$r" -o json \
        | tool_jq -r '[.status.phase // "", .spec.template.spec.containers[0].image, (.status.stableRS == .status.currentPodHash), (.status.abort // false)] | @tsv')
      IFS=$'\t' read -r phase image complete aborted <<< "$ro"
      case "$image" in *"@$digest") ;; *) gate_fail "$s" "digest mismatch" "rollout/$r runs $image, want @$digest" ;; esac
      [ "$aborted" = true ] && gate_fail "$s" "rollout/$r aborted" "canary analysis failed and Argo Rollouts rolled back to stable"
      [ "$phase" = Healthy ] && [ "$complete" = true ] && break
      [ "$(date +%s)" -ge "$deadline" ] && gate_fail "$s" "rollout/$r not Healthy" "phase=$phase complete=$complete"
      sleep "$poll"
    done
  done

  # 3. Soak, then judge the stack on its own edge SLIs.
  [ "$soak" -gt 0 ] && sleep "$soak"
  win=$((soak > 60 ? soak : 60))s
  svc="$ns-api-(stable|canary)-.*"
  err=$(prom "(sum(rate(traefik_service_requests_total{service=~\"$svc\",code=~\"5..\"}[$win])) or vector(0)) / sum(rate(traefik_service_requests_total{service=~\"$svc\"}[$win]))")
  is_num "$err" || gate_fail "$s" "no traffic" "error-ratio query returned '$err' over $win"
  lt "$err" 0.005 || gate_fail "$s" "error ratio" "$err >= 0.005 over $win"
  p95=$(prom "histogram_quantile(0.95, sum by (le) (rate(traefik_service_request_duration_seconds_bucket{service=~\"$svc\"}[$win])))")
  is_num "$p95" || gate_fail "$s" "no traffic" "p95 query returned '$p95' over $win"
  lt "$p95" 0.4 || gate_fail "$s" "p95 latency" "${p95}s >= 0.4s over $win"

  # 4. The worker keeps up with the queue.
  age=$(prom "max(queue_oldest_job_age_seconds{namespace=\"$ns\"})")
  is_num "$age" || gate_fail "$s" "queue age" "no worker queue metrics ('$age')"
  lt "$age" 120 || gate_fail "$s" "queue age" "oldest job waited ${age}s >= 120s"

  echo "GATE PASS $stage/$s (5xx ratio=$err, p95=${p95}s, oldest job=${age}s)"
done
