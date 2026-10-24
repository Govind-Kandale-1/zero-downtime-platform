#!/usr/bin/env bash
# Shared helpers for every script in scripts/. Source it; do not execute it.

# Resolved once at source time: BASH_SOURCE may be relative, and callers cd.
_ZDP_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

repo_root() {
  git -C "$_ZDP_LIB_DIR" rev-parse --show-toplevel
}

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

die() { log "ERROR: $*"; exit 1; }

require() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

# Exports every variable from config/platform.env and config/versions.env.
load_config() {
  local root
  root=$(repo_root)
  set -a
  # shellcheck source=/dev/null
  . "$root/config/platform.env"
  # shellcheck source=/dev/null
  . "$root/config/versions.env"
  set +a
}

# Path form that docker.exe accepts for bind mounts: C:/... in Git Bash on
# Windows, the plain path on Linux.
host_path() {
  if (cd "$1" && pwd -W) >/dev/null 2>&1; then (cd "$1" && pwd -W); else (cd "$1" && pwd); fi
}
