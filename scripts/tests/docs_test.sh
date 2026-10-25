#!/usr/bin/env bash
# Documentation completeness (Task 18). Fails when the repo's written promises
# drift from its contents:
#   - a code-review.md is committed (they are the author's local notes only)
#   - locally, where the notes exist: a folder of code/config has none, or one
#     names a file that does not exist
#   - decisions.md is missing an allocated ADR
#   - the README coverage table lacks one of the brief's 11 items
#   - an evidence README, a doc, an architecture page or a runbook has no Label:
#   - a required doc, architecture page or alert-linked runbook is missing
#   - a relative Markdown link points to a file that does not exist
#   - docs/architecture.md exceeds ~5 printed pages (3,000 words)
#   - LICENSE differs by one byte from the owner's original text
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
fails=0
ok() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
skip() { echo "SKIP: $*"; }

# 1. Per-folder code reviews are local study notes (owner decision 2026-10-26):
# on disk, never committed.
tracked=$(git ls-files '*code-review.md' | wc -l | tr -d ' ')
[ "$tracked" = 0 ] && ok "no code-review.md is committed" || bad "$tracked code-review.md file(s) are committed"

reviews=$(find . -name code-review.md -not -path './.git/*' -not -path '*/.terraform/*' | sed 's|^\./||' | sort)
if [ -z "$reviews" ]; then
  skip "local code-review checks (no local notes here, e.g. in CI)"
else
  # 1a. Every folder with code/config has a review (or its parent's review
  # names it as "<sub>/"). docs/ and evidence/ are prose; root files: README.
  missing=""
  while read -r d; do
    [ -f "$d/code-review.md" ] && continue
    p=$(dirname "$d")
    [ -f "$p/code-review.md" ] && grep -q "$(basename "$d")/" "$p/code-review.md" && continue
    missing+=" $d"
  done < <(git ls-files | grep -E '(\.go|\.tf|\.ya?ml|\.sh|\.rego|Dockerfile)$' \
    | grep -vE '^(docs|evidence|\.github/workflows|\.superpowers)/' | grep '/' | xargs -n1 dirname | sort -u)
  [ -z "$missing" ] && ok "every code/config folder has a local code-review.md" || bad "no code-review.md in:$missing"

  # 1b. Files named in the first column of a review's tables exist. Only tokens
  # that look like file names are checked (value rows like `api.minReplicas` aren't).
  dangling=""
  while read -r cr; do
    d=$(dirname "$cr")
    while read -r f; do
      [ -e "$d/$f" ] || dangling+=" $d/$f"
    done < <(grep -oE '^\| `[^`*<> ]+`' "$cr" | sed -E 's/^\| `([^`]+)`/\1/' \
      | grep -E '(\.(sh|go|tf|ya?ml|rego|json|js|tpl|sql|hcl|env|md|txt|csv)|/|^Dockerfile)$' || true)
  done <<< "$reviews"
  [ -z "$dangling" ] && ok "every file a code-review.md names exists" || bad "named in a review but missing:$dangling"
fi

# 3. Every allocated ADR is in decisions.md. ADR-002 (the licence) was removed
# at the owner's request: LICENSE speaks for itself.
adrs=""
for n in $(seq -w 1 24); do
  [ "$n" = 02 ] && continue
  grep -q "^## ADR-0$n:" decisions.md || adrs+=" ADR-0$n"
done
[ -z "$adrs" ] && ok "decisions.md has every allocated ADR" || bad "decisions.md is missing:$adrs"

# 4. The README coverage table has a row for each of the brief's 11 items.
rows=""
for n in $(seq 1 11); do grep -qE "^\| *$n\. " README.md || rows+=" $n"; done
[ -z "$rows" ] && ok "README covers all 11 brief items" || bad "README coverage table lacks item(s):$rows"

# 5. Every evidence folder's README states its label.
unlabelled=""
for r in evidence/*/README.md; do grep -qE '(\*\*)?Label:(\*\*)?' "$r" || unlabelled+=" $r"; done
[ -z "$unlabelled" ] && ok "every evidence README has a Label line" || bad "no Label line in:$unlabelled"

# 5b. So does every doc, architecture page and runbook (RUN-LOCAL / DESCRIBED...).
unlabelled=""
for r in docs/*.md docs/architecture/*.md docs/runbooks/*.md; do grep -qE '^\*\*Labels?:\*\*' "$r" || unlabelled+=" $r"; done
[ -z "$unlabelled" ] && ok "every doc, architecture page and runbook has a Label line" || bad "no Label line in:$unlabelled"

# 6. Required docs exist, including every runbook an alert or doc links to.
need="docs/architecture.md docs/capacity.md docs/cost.md docs/slos.md docs/non-portable.md docs/roadmap.md"
for p in README components where-things-live flows tenancy; do need+=" docs/architecture/$p.md"; done
for r in burn-rate-page queue-backlog db-connection-saturation restore-from-backup failed-tenant-onboarding \
  drift-detected canary-aborted rollback-after-migration backup-stale; do need+=" docs/runbooks/$r.md"; done
for r in $(grep -rhoE 'docs/runbooks/[a-z-]+\.md' charts gitops 2>/dev/null | sort -u); do need+=" $r"; done
absent=""
for f in $need; do [ -f "$f" ] || absent+=" $f"; done
[ -z "$absent" ] && ok "required docs, architecture pages and linked runbooks exist" || bad "missing:$absent"

# 6b. Relative Markdown links resolve (anchors and URLs are not checked).
broken=""
while read -r md; do
  d=$(dirname "$md")
  while read -r link; do
    target=${link%%#*}
    [ -z "$target" ] && continue
    [ -e "$d/$target" ] || broken+=" $md->$target"
  done < <(grep -oE '\]\([^)[:space:]]+\)' "$md" | sed -E 's/^\]\(//; s/\)$//' | grep -vE '^(https?:|mailto:|#)' || true)
done < <(git ls-files '*.md' | grep -vE '^(docs/superpowers|\.superpowers)/')
[ -z "$broken" ] && ok "every relative Markdown link resolves" || bad "broken links:$broken"

# 7. The architecture doc fits ~5 printed pages.
if [ -f docs/architecture.md ]; then
  w=$(wc -w < docs/architecture.md)
  [ "$w" -le 3000 ] && ok "architecture.md is $w words (<= 3000)" || bad "architecture.md is $w words (> 3000, ~5 pages)"
fi

# 8. LICENSE is byte-identical to the owner's text (commit 957f994).
sum=$(sha256sum LICENSE | cut -d' ' -f1)
[ "$sum" = de792a5864cdd44be2072b615ed32bd8036a02aa5d0a0b3149aac3d33439dace ] \
  && ok "LICENSE unchanged" || bad "LICENSE changed (sha256 $sum)"

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "ALL PASS"
