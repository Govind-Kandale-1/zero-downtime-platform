#!/usr/bin/env bash
# bump-release.sh must (1) write the release file, (2) survive a race where
# main moved since the runner checked out, (3) be idempotent, (4) reject bad
# input. Uses throwaway repos; never touches the real remote.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
bump="$here/bump-release.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
gitq() { git -c user.name=test -c user.email=test@example.com "$@"; }
D=sha256:$(printf 'b%.0s' $(seq 1 64))

git init -q --bare -b main "$tmp/remote.git"
git clone -q "$tmp/remote.git" "$tmp/a" 2>/dev/null
( cd "$tmp/a" && echo init > README && gitq add README && gitq commit -qm init && git push -q origin main )
git clone -q "$tmp/remote.git" "$tmp/b"

# Someone else pushes first: b is now behind.
( cd "$tmp/a" && echo change >> README && gitq commit -qam "unrelated change" && git push -q origin main )

if ( cd "$tmp/b" && GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=t@e GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=t@e \
       bash "$bump" staging 0.1.7 "$D" >/dev/null 2>&1 ); then
  pass "bump pushed despite main having moved (rebase + retry)"
else
  fail "bump failed on a moved main"
fi

git clone -q "$tmp/remote.git" "$tmp/check"
log=$(git -C "$tmp/check" log --format=%s main)
case "$log" in *"unrelated change"*) pass "other commit preserved" ;; *) fail "other commit lost" ;; esac
case "$log" in *"release(staging): chart 0.1.7"*) pass "release commit on main" ;; *) fail "release commit missing: $log" ;; esac
grep -q "digest: \"$D\"" "$tmp/check/gitops/releases/staging.yaml" && pass "release file pins the digest" || fail "digest not in release file"
grep -q 'version: "0.1.7"' "$tmp/check/gitops/releases/staging.yaml" && pass "release file pins the chart version" || fail "chart version not in release file"

before=$(git -C "$tmp/check" rev-list --count main)
( cd "$tmp/b" && git pull -q --rebase && GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=t@e GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=t@e \
    bash "$bump" staging 0.1.7 "$D" >/dev/null 2>&1 )
git -C "$tmp/check" pull -q
after=$(git -C "$tmp/check" rev-list --count main)
[ "$before" = "$after" ] && pass "re-promoting the same artifact is a no-op" || fail "duplicate promotion created a commit"

if ( cd "$tmp/b" && bash "$bump" staging 0.1.8 "sha256:nothex" >/dev/null 2>&1 ); then
  fail "accepted a malformed digest"
else
  pass "rejects a malformed digest"
fi
if ( cd "$tmp/b" && bash "$bump" production 0.1.8 "$D" >/dev/null 2>&1 ); then
  fail "accepted an unknown stage"
else
  pass "rejects an unknown stage"
fi

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "ALL PASS"
