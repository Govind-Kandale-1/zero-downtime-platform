#!/usr/bin/env bash
# Starts (idempotently) the Postgres container that holds Terraform state for
# the local target, and writes PG_CONN_STR to .local/tfstate.env (ADR-004).
# The password is generated once; the data lives in Docker volume zdp-tfstate.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
. "$(dirname "$0")/lib/common.sh"
load_config

root=$(repo_root)
envf="$root/.local/tfstate.env"
mkdir -p "$root/.local"

if [ ! -f "$envf" ]; then
  if docker volume inspect zdp-tfstate >/dev/null 2>&1; then
    die "volume zdp-tfstate exists but $envf is missing; restore the file or run scripts/down.sh --purge"
  fi
  # od reads exactly 16 bytes, so nothing gets SIGPIPE under pipefail.
  pw=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  printf 'export PG_CONN_STR="postgres://tfstate:%s@127.0.0.1:5433/tfstate?sslmode=disable"\n' "$pw" > "$envf"
  chmod 600 "$envf"
  log "generated $envf"
fi
pw=$(sed -n 's#.*tfstate:\([a-f0-9]*\)@.*#\1#p' "$envf")

if ! docker container inspect zdp-tfstate >/dev/null 2>&1; then
  log "creating zdp-tfstate ($POSTGRES_IMAGE)"
  MSYS_NO_PATHCONV=1 docker run -d --name zdp-tfstate --restart unless-stopped \
    -p 127.0.0.1:5433:5432 \
    -e POSTGRES_USER=tfstate -e POSTGRES_PASSWORD="$pw" -e POSTGRES_DB=tfstate \
    -v zdp-tfstate:/var/lib/postgresql "$POSTGRES_IMAGE" >/dev/null
elif [ "$(docker inspect -f '{{.State.Running}}' zdp-tfstate)" != true ]; then
  docker start zdp-tfstate >/dev/null
fi

for _ in $(seq 1 60); do
  docker exec zdp-tfstate pg_isready -q -h 127.0.0.1 -U tfstate && break
  sleep 1
done
docker exec zdp-tfstate pg_isready -q -h 127.0.0.1 -U tfstate || die "tfstate database not ready"

# Lets in-cluster/runner jobs reach state as zdp-tfstate:5432 once kind exists.
if docker network inspect kind >/dev/null 2>&1; then
  docker network connect kind zdp-tfstate 2>/dev/null || true
fi
log "Terraform state backend ready: source .local/tfstate.env"
