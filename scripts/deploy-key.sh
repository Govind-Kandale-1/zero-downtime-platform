#!/usr/bin/env bash
# Creates the write-enabled deploy key the release workflow uses to commit
# gitops/releases/*.yaml past the main ruleset (ADR-020), and stores the
# private half as the Actions secret GITOPS_DEPLOY_KEY. Idempotent: an existing
# key with the same title is replaced. The private key never leaves .local/
# except into the encrypted Actions secret.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
. "$(dirname "$0")/lib/common.sh"
load_config
require gh
require ssh-keygen

repo="$GITHUB_OWNER/$GITHUB_REPO"
key="$(repo_root)/.local/gitops_deploy_key"
mkdir -p "$(dirname "$key")"

if [ ! -f "$key" ]; then
  ssh-keygen -q -t ed25519 -N "" -C "gitops-release@$GITHUB_REPO" -f "$key"
  log "generated $key"
fi

old=$(gh api "repos/$repo/keys" --jq '.[] | select(.title=="gitops-release") | .id' || true)
for id in $old; do
  gh api -X DELETE "repos/$repo/keys/$id" >/dev/null
  log "removed old deploy key $id"
done
gh repo deploy-key add "$key.pub" --repo "$repo" --allow-write --title gitops-release >/dev/null
gh secret set GITOPS_DEPLOY_KEY --repo "$repo" < "$key"
log "deploy key gitops-release (write) added; secret GITOPS_DEPLOY_KEY set"
