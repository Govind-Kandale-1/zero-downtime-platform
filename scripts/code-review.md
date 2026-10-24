# scripts/ — code review

**Purpose:** operator entry points (bring-up, tear-down, demos, restore test) and their test harness. Everything is bash, written to run identically in Git Bash on Windows and in Linux CI.

| Path | What it is |
|---|---|
| `lib/` | Shared helpers sourced by every script (see `lib/code-review.md`) |
| `tests/` | Tests for the scripts themselves (see `tests/code-review.md`) |
| `test-go.sh` | `unit` runs `go test ./...` in the pinned Go container. `integration` starts throwaway Postgres + Valkey containers on network `zdp-test`, waits for **TCP** readiness (the Postgres image's init phase only listens on a socket), then runs `go test -tags integration ./...` on that network. The containers are removed on exit. |

Further entry points (`up.sh`, `down.sh`, `state-up.sh`, `runner-up.sh`, `gate.sh`, `bump-release.sh`, `restore-test.sh`, demos) are added by later build steps and listed here as they land.

**Conventions:**
- `set -euo pipefail`.
- Source `lib/common.sh`.
- Never hard-code repo or registry names; read `config/platform.env`.
- Never hard-code versions; read `config/versions.env`.

**Label:** RUN-LOCAL.
