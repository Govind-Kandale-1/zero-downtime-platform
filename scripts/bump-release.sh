#!/usr/bin/env bash
# Promote one artifact to a release stage: rewrite gitops/releases/<stage>.yaml
# with the chart version and image digest, commit, push. This commit IS the
# deployment - Argo CD pulls it (ADR-010, ADR-015).
#
# Usage: bump-release.sh <stage> <chart-version> <sha256:digest>
#
# Safe under races: if main moved since checkout (another promotion, a human
# merge) the push is retried after a rebase, up to 5 times. Re-promoting the
# artifact a stage already runs is a no-op.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
. "$(dirname "$0")/lib/common.sh"
load_config

[ $# -eq 3 ] || die "usage: bump-release.sh <stage> <chart-version> <sha256:digest>"
stage=$1 version=$2 digest=$3

case "$stage" in dev|staging|prod-ring0|ring1|ring2) ;; *) die "unknown stage '$stage'" ;; esac
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "chart version must be semver, got '$version'"
[[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]] || die "digest must be sha256:<64 hex>, got '$digest'"

# Operate on the repository we are run from (CI checkout, or a test clone).
cd "$(git rev-parse --show-toplevel)"
file="gitops/releases/$stage.yaml"
mkdir -p gitops/releases

git pull -q --rebase origin main 2>/dev/null || true

cat > "$file" <<EOF
# Release pin for stage "$stage" - written by scripts/bump-release.sh.
# Every Application on this stage renders chart $version with this exact image.
stage: $stage
chart:
  version: "$version"
image:
  repository: $IMAGE
  digest: "$digest"
EOF

git add "$file"
if git diff --cached --quiet -- "$file"; then
  log "$stage already runs chart $version / ${digest:7:12}; nothing to do"
  exit 0
fi
git commit -q -m "release($stage): chart $version image ${digest:7:12}" -- "$file"

for attempt in 1 2 3 4 5; do
  if git push -q origin HEAD:main 2>/dev/null; then
    log "promoted $stage -> chart $version, image ${digest:7:12} (attempt $attempt)"
    exit 0
  fi
  log "push rejected (main moved); rebasing and retrying ($attempt/5)"
  git pull -q --rebase origin main
done
die "could not push after 5 attempts"
