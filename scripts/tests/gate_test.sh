#!/usr/bin/env bash
# gate.sh against a stub kubectl that replays canned cluster/Prometheus answers
# for five scenarios. Proves the gate passes only on a healthy, correct,
# measured release, and fails fast with the reason otherwise (never hangs).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

D=sha256:$(printf 'd%.0s' $(seq 1 64))
OTHER=sha256:$(printf 'e%.0s' $(seq 1 64))

# Stub kubectl: answers depend on $SCENARIO.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
args="$*"
digest=$GOOD_DIGEST
[ "$SCENARIO" = wrong-digest ] && digest=$OTHER_DIGEST
case "$args" in
  *"get application"*)
    sync=Synced; health=Healthy
    [ "$SCENARIO" = never-healthy ] && { sync=OutOfSync; health=Progressing; }
    [ "$SCENARIO" = aborted ] && health=Degraded # an aborted canary leaves the app Degraded
    if [ "$SCENARIO" = transient-degraded ]; then
      # Degraded for the first two polls (a new stack converging), then Healthy.
      n=$(cat "$STATE/app-calls" 2>/dev/null || echo 0); echo $((n + 1)) > "$STATE/app-calls"
      [ "$n" -lt 2 ] && { sync=OutOfSync; health=Degraded; }
    fi
    printf '{"status":{"sync":{"status":"%s","revisions":["0.1.42","abc123"]},"health":{"status":"%s"}}}\n' "$sync" "$health" ;;
  *"get rollout"*)
    if [ "$SCENARIO" = aborted ]; then
      printf '{"spec":{"template":{"spec":{"containers":[{"image":"ghcr.io/x/y@%s"}]}}},"status":{"phase":"Degraded","abort":true,"stableRS":"h1","currentPodHash":"h2"}}\n' "$digest"
    else
      printf '{"spec":{"template":{"spec":{"containers":[{"image":"ghcr.io/x/y@%s"}]}}},"status":{"phase":"Healthy","stableRS":"h1","currentPodHash":"h1"}}\n' "$digest"
    fi ;;
  *"--raw"*)
    q=$(printf '%s' "$args" | sed 's/.*query=//')
    empty='{"status":"success","data":{"resultType":"vector","result":[]}}'
    one() { printf '{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[0,"%s"]}]}}\n' "$1"; }
    [ "$SCENARIO" = no-traffic ] && { echo "$empty"; exit 0; }
    case "$q" in
      *histogram_quantile*) one 0.12 ;;
      *queue_oldest*) one 3 ;;
      *) if [ "$SCENARIO" = sli-breach ]; then one 0.08; else one 0.0004; fi ;;
    esac ;;
  *) echo "stub kubectl: unexpected args: $args" >&2; exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/kubectl"

# A repo with a release file for stage "dev".
mkdir -p "$tmp/repo/gitops/releases"
printf 'stage: dev\nchart:\n  version: "0.1.42"\nimage:\n  repository: ghcr.io/x/y\n  digest: "%s"\n' "$D" > "$tmp/repo/gitops/releases/dev.yaml"
git -C "$tmp/repo" init -q && git -C "$tmp/repo" add -A && git -C "$tmp/repo" -c user.name=t -c user.email=t@e commit -qm init

run_gate() { # scenario -> prints output, returns gate exit code
  rm -rf "$tmp/state" && mkdir -p "$tmp/state"
  ( cd "$tmp/repo" && PATH="$tmp/bin:$PATH" SCENARIO=$1 GOOD_DIGEST=$D OTHER_DIGEST=$OTHER STATE="$tmp/state" \
      GATE_TIMEOUT=${2:-30} GATE_POLL=1 GATE_SOAK=0 bash "$here/gate.sh" dev dev 2>&1 )
}

out=$(run_gate healthy) && rc=0 || rc=$?
[ "$rc" = 0 ] && grep -q 'GATE PASS dev/dev' <<< "$out" && pass "healthy release passes" || fail "healthy: rc=$rc out=$out"

start=$(date +%s)
out=$(run_gate never-healthy 5) && rc=0 || rc=$?
took=$(( $(date +%s) - start ))
{ [ "$rc" != 0 ] && grep -q 'Application not Synced/Healthy' <<< "$out" && [ "$took" -lt 20 ]; } \
  && pass "never-healthy fails within the timeout (${took}s)" || fail "never-healthy: rc=$rc took=${took}s out=$out"

out=$(run_gate transient-degraded) && rc=0 || rc=$?
[ "$rc" = 0 ] && grep -q 'GATE PASS dev/dev' <<< "$out" \
  && pass "a stack that is briefly Degraded while converging still passes" || fail "transient-degraded: rc=$rc out=$out"

start=$(date +%s)
out=$(run_gate aborted 60) && rc=0 || rc=$?
took=$(( $(date +%s) - start ))
{ [ "$rc" != 0 ] && grep -q 'aborted' <<< "$out" && [ "$took" -lt 30 ]; } \
  && pass "an aborted canary fails fast (${took}s, not the 60s timeout)" || fail "aborted: rc=$rc took=${took}s out=$out"

out=$(run_gate wrong-digest) && rc=0 || rc=$?
[ "$rc" != 0 ] && grep -q 'digest mismatch' <<< "$out" && pass "wrong digest is rejected" || fail "wrong-digest: rc=$rc out=$out"

out=$(run_gate sli-breach) && rc=0 || rc=$?
[ "$rc" != 0 ] && grep -q 'error ratio' <<< "$out" && pass "SLI breach fails the gate" || fail "sli-breach: rc=$rc out=$out"

out=$(run_gate no-traffic) && rc=0 || rc=$?
[ "$rc" != 0 ] && grep -q 'no traffic' <<< "$out" && pass "no data is a failure, never a pass" || fail "no-traffic: rc=$rc out=$out"

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "ALL PASS"
