#!/usr/bin/env bash
# Fails if any tracked script, manifest, Terraform, Go or Markdown file has
# CRLF (or mixed) line endings in the index or the working tree. The host is
# Windows, and bash, YAML and Terraform all misbehave on CRLF.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

offenders=()
while IFS=$'\t' read -r info path; do
  case "$info" in
    *i/crlf*|*w/crlf*|*i/mixed*|*w/mixed*) offenders+=("$path") ;;
  esac
done < <(git ls-files --eol -- '*.sh' '*.yaml' '*.yml' '*.tf' '*.go' '*.md')

if [ "${#offenders[@]}" -gt 0 ]; then
  echo "FAIL: CRLF line endings in:" >&2
  printf '  %s\n' "${offenders[@]}" >&2
  exit 1
fi
echo "OK: all text files LF"
