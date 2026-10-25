#!/usr/bin/env bash
# Tear the local platform down.
#   down.sh          terraform destroy 30-gitops -> 20-data -> 10-cluster (state kept)
#   down.sh --purge  delete the kind cluster and the Terraform state DB + volume
#                    (back to an empty laptop; the deploy key in .local/ is kept)
# Both stop and deregister the self-hosted runner.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
. "$(dirname "$0")/lib/common.sh"
load_config

root=$(repo_root)
cd "$root"
repo="$GITHUB_OWNER/$GITHUB_REPO"

log "stopping the self-hosted runner"
docker rm -f zdp-runner >/dev/null 2>&1 || true
id=$(gh api "repos/$repo/actions/runners" --jq '.runners[] | select(.name=="zdp-local-kind") | .id' 2>/dev/null || true)
[ -n "$id" ] && gh api -X DELETE "repos/$repo/actions/runners/$id" >/dev/null && log "deregistered runner $id"

if [ "${1:-}" = "--purge" ]; then
  log "purge: deleting kind cluster, state DB and local state files"
  kind delete cluster --name "$KIND_CLUSTER" 2>/dev/null || true
  docker rm -f zdp-tfstate >/dev/null 2>&1 || true
  docker volume rm zdp-tfstate >/dev/null 2>&1 || true
  rm -rf .local/tfstate.env .local/kubeconfig .local/runner
  log "purged (kept .local/gitops_deploy_key)"
  exit 0
fi

[ -f .local/tfstate.env ] || die "no .local/tfstate.env - nothing to destroy (use --purge to clean up)"
bash scripts/state-up.sh
# shellcheck source=/dev/null
. .local/tfstate.env
for r in 30-gitops 20-data 10-cluster; do
  log "terraform destroy infra/live/local/$r"
  terraform -chdir="infra/live/local/$r" init -input=false -no-color >/dev/null
  terraform -chdir="infra/live/local/$r" destroy -auto-approve -input=false -no-color >/dev/null
done
log "destroyed (state DB kept; down.sh --purge removes it)"
