#!/usr/bin/env bash
# Runs the Go test suite for app/ in the pinned toolchain container.
#   unit         go test ./...            (no external services)
#   integration  starts Postgres + Valkey on Docker network zdp-test and runs
#                go test -tags integration ./... against them
set -euo pipefail
# shellcheck source=scripts/lib/tools.sh
. "$(dirname "$0")/lib/tools.sh"

mode=${1:-unit}
cd "$(repo_root)/app"

cleanup() { docker rm -f zdp-test-pg zdp-test-valkey >/dev/null 2>&1 || true; }

case "$mode" in
  unit)
    tool_go test -count=1 ./...
    ;;
  integration)
    docker network inspect zdp-test >/dev/null 2>&1 || docker network create zdp-test >/dev/null
    cleanup
    trap cleanup EXIT
    docker run -d --name zdp-test-pg --network zdp-test \
      -e POSTGRES_USER=test -e POSTGRES_PASSWORD=test -e POSTGRES_DB=test "$POSTGRES_IMAGE" >/dev/null
    docker run -d --name zdp-test-valkey --network zdp-test "$VALKEY_IMAGE" >/dev/null
    # TCP readiness only succeeds once the image's init phase has finished.
    for _ in $(seq 1 60); do
      docker exec zdp-test-pg pg_isready -q -h 127.0.0.1 -U test && break
      sleep 1
    done
    docker exec zdp-test-pg pg_isready -q -h 127.0.0.1 -U test || die "postgres did not become ready"
    TOOL_DOCKER_ARGS="--network zdp-test \
      -e TEST_DATABASE_URL=postgres://test:test@zdp-test-pg:5432/test?sslmode=disable \
      -e TEST_REDIS_URL=redis://zdp-test-valkey:6379/0" \
      tool_go test -count=1 -tags integration ./...
    ;;
  *) die "usage: test-go.sh unit|integration" ;;
esac
