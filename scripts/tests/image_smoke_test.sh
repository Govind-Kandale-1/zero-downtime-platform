#!/usr/bin/env bash
# Builds the app image and proves the black-box contract end to end with real
# Postgres + Valkey: health, readiness, a read, an enqueue, a worker drain, a
# graceful SIGTERM stop with exit 0, and the image size budget.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
. "$(dirname "$0")/../lib/common.sh"
load_config
# Stop Git Bash rewriting container paths like /worker into C:/Program Files/...
# Scoped to docker only: native git.exe still needs the conversion.
docker() { MSYS_NO_PATHCONV=1 command docker "$@"; }

IMG=zdp-app:test
NET=zdp-smoke
PORT=18080
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

cleanup() { docker rm -f zdp-smoke-api zdp-smoke-worker zdp-smoke-pg zdp-smoke-valkey >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

cd "$(repo_root)/app"
docker build -q -t "$IMG" --build-arg GO_VERSION="$GO_VERSION" --build-arg BASE_IMAGE="$DISTROLESS_IMAGE" \
  --build-arg VERSION=smoke . >/dev/null || die "image build failed"

docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
docker run -d --name zdp-smoke-pg --network "$NET" -e POSTGRES_USER=app -e POSTGRES_PASSWORD=app \
  -e POSTGRES_DB=app "$POSTGRES_IMAGE" >/dev/null
docker run -d --name zdp-smoke-valkey --network "$NET" "$VALKEY_IMAGE" >/dev/null

DB=postgres://app:app@zdp-smoke-pg:5432/app?sslmode=disable
docker run -d --name zdp-smoke-api --network "$NET" -p "127.0.0.1:${PORT}:8080" \
  -e DATABASE_URL="$DB" -e REDIS_URL=redis://zdp-smoke-valkey:6379/0 "$IMG" >/dev/null

code() { curl -s -o /dev/null -w '%{http_code}' "$@" || true; }

for _ in $(seq 1 20); do [ "$(code "http://127.0.0.1:${PORT}/healthz")" = 200 ] && break; sleep 1; done
[ "$(code "http://127.0.0.1:${PORT}/healthz")" = 200 ] && pass "/healthz 200" || fail "/healthz not 200"

ready=no
for _ in $(seq 1 20); do
  if [ "$(code "http://127.0.0.1:${PORT}/readyz")" = 200 ]; then ready=yes; break; fi
  sleep 1
done
[ "$ready" = yes ] && pass "/readyz 200 within 20s (migrated, deps reachable)" || fail "/readyz not 200 within 20s"

body=$(curl -s "http://127.0.0.1:${PORT}/api/items/7" || true)
case "$body" in *'"id":7'*) pass "/api/items/7 returns id 7" ;; *) fail "/api/items/7 returned: $body" ;; esac

[ "$(code -X POST -d '{"duration_ms":500}' "http://127.0.0.1:${PORT}/api/jobs")" = 202 ] \
  && pass "POST /api/jobs 202" || fail "POST /api/jobs not 202"

docker run -d --name zdp-smoke-worker --network "$NET" --entrypoint /worker \
  -e REDIS_URL=redis://zdp-smoke-valkey:6379/0 "$IMG" >/dev/null
drained=no
for _ in $(seq 1 10); do
  if [ "$(docker exec zdp-smoke-valkey valkey-cli GET jobs:done_total)" = 1 ]; then drained=yes; break; fi
  sleep 1
done
[ "$drained" = yes ] && pass "worker completed the job (jobs:done_total=1)" || fail "worker did not complete the job within 10s"

start=$(date +%s)
docker stop -t 30 zdp-smoke-api >/dev/null
took=$(( $(date +%s) - start ))
exit_code=$(docker inspect -f '{{.State.ExitCode}}' zdp-smoke-api)
if [ "$exit_code" = 0 ] && [ "$took" -lt 30 ]; then
  pass "graceful stop: exit 0 after ${took}s (SIGTERM, not SIGKILL)"
else
  fail "stop took ${took}s with exit code $exit_code"
fi

# What matters for scale-up is the compressed bytes a node pulls. `docker image
# inspect .Size` on Docker Desktop's containerd store also counts snapshot
# overhead, so measure the gzipped export instead (close to registry size).
pull_mb=$(( $(docker save "$IMG" | gzip -c | wc -c) / 1024 / 1024 ))
[ "$pull_mb" -lt 25 ] && pass "image pull size ~${pull_mb} MB compressed (< 25 MB)" \
  || fail "image pull size ~${pull_mb} MB compressed (>= 25 MB)"

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "ALL PASS"
