#!/usr/bin/env bash
# Proves the provider contract (infra/code-review.md) for every stack:
# Postgres healthy, PgBouncer available and usable, Valkey ready with AOF on,
# and the three connection URLs present in the secrets manager.
set -euo pipefail
# shellcheck source=scripts/lib/tools.sh
. "$(git rev-parse --show-toplevel)/scripts/lib/tools.sh"
root=$(repo_root)
export KUBECONFIG="$root/.local/kubeconfig"
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

# Stacks = env stacks + dedicated tenants (same rule as 20-data/locals.tf).
stacks=()
for f in "$root"/gitops/stacks/*.yaml; do stacks+=("$(basename "$f" .yaml)"); done
for f in "$root"/tenants/*.yaml; do
  grep -q '^tier: dedicated' "$f" && stacks+=("$(basename "$f" .yaml)")
done

ns_of() { if [ -f "$root/gitops/stacks/$1.yaml" ]; then echo "app-$1"; else echo "tenant-$1"; fi; }
bao() { kubectl exec -n openbao openbao-0 -- env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=root bao "$@"; }

for s in "${stacks[@]}"; do
  ns=$(ns_of "$s")
  if ! kubectl get ns "$ns" >/dev/null 2>&1; then fail "$s: namespace $ns missing"; continue; fi

  phase=$(kubectl get clusters.postgresql.cnpg.io "$s-pg" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ "$phase" = "Cluster in healthy state" ] && pass "$s: postgres healthy" || fail "$s: postgres phase '$phase'"

  # Terraform does not wait for the Pooler Deployment; the stack is eventually
  # consistent (apps retry), so wait up to 2 minutes rather than sample once.
  if kubectl wait deploy/pgbouncer -n "$ns" --for=condition=Available --timeout=120s >/dev/null 2>&1; then
    pass "$s: pgbouncer available"
  else
    fail "$s: pgbouncer not available after 120s"
  fi

  if kubectl get pvc pg-backups -n "$ns" >/dev/null 2>&1; then
    pass "$s: backup claim pg-backups exists (provider layer)"
  else
    fail "$s: backup claim pg-backups missing"
  fi

  if kubectl wait pod/valkey-0 -n "$ns" --for=condition=Ready --timeout=5s >/dev/null 2>&1; then
    pass "$s: valkey ready"
    aof=$(kubectl exec -n "$ns" valkey-0 -c valkey -- valkey-cli CONFIG GET appendonly | tail -1)
    [ "$aof" = yes ] && pass "$s: valkey appendonly=yes" || fail "$s: valkey appendonly=$aof"
  else
    fail "$s: valkey-0 not ready"
  fi

  secret=$(bao kv get -format=json "secret/stacks/$s/app" 2>/dev/null || true)
  keys=$(printf '%s' "$secret" | tool_jq -r '.data.data | keys | join(",")' 2>/dev/null || true)
  if [ "$keys" = "DATABASE_URL,MIGRATION_DATABASE_URL,REDIS_URL" ]; then
    pass "$s: secret has DATABASE_URL, MIGRATION_DATABASE_URL, REDIS_URL"
    url=$(printf '%s' "$secret" | tool_jq -r '.data.data.DATABASE_URL')
    # Connect through PgBouncer from inside the cluster (from the PG pod, which has psql).
    if kubectl exec -n "$ns" "$s-pg-1" -c postgres -- psql "$url" -tAc 'select 1' 2>/dev/null | grep -qx 1; then
      pass "$s: psql via pgbouncer works"
    else
      fail "$s: psql via pgbouncer failed"
    fi
  else
    fail "$s: secret keys '$keys'"
  fi
done

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "ALL PASS (${#stacks[@]} stacks)"
