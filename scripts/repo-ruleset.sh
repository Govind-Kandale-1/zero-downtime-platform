#!/usr/bin/env bash
# Creates or updates the `main-protection` ruleset (ADR-020): PRs with an
# owner review and green CI for everyone, except two bypass actors:
#   - repository admins (the solo owner can merge)
#   - deploy keys (the release pipeline commits gitops/releases/*.yaml)
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
. "$(dirname "$0")/lib/common.sh"
load_config
require gh
repo="$GITHUB_OWNER/$GITHUB_REPO"

checks='[{"context":"go-test"},{"context":"chart-test"},{"context":"policy-test"},
         {"context":"terraform-validate"},{"context":"iac-scan"},{"context":"shell-lint"}]'

body=$(cat <<JSON
{
  "name": "main-protection",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["refs/heads/main"], "exclude": [] } },
  "bypass_actors": [
    { "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always" },
    { "actor_type": "DeployKey", "bypass_mode": "always" }
  ],
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "pull_request", "parameters": {
        "required_approving_review_count": 1,
        "require_code_owner_review": true,
        "dismiss_stale_reviews_on_push": true,
        "require_last_push_approval": false,
        "required_review_thread_resolution": false } },
    { "type": "required_status_checks", "parameters": {
        "strict_required_status_checks_policy": false,
        "required_status_checks": $checks } }
  ]
}
JSON
)

id=$(gh api "repos/$repo/rulesets" --jq '.[] | select(.name=="main-protection") | .id' 2>/dev/null || true)
if [ -n "$id" ]; then
  printf '%s' "$body" | gh api -X PUT "repos/$repo/rulesets/$id" --input - >/dev/null
  log "updated ruleset main-protection ($id)"
else
  printf '%s' "$body" | gh api -X POST "repos/$repo/rulesets" --input - >/dev/null
  log "created ruleset main-protection"
fi
gh api "repos/$repo/rulesets" --jq '.[] | "\(.name): \(.enforcement)"'
