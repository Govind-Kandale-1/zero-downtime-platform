# scripts/tests/ — code review

**Purpose:** tests for repository hygiene and for the operator scripts. Each test prints `OK`/`PASS` lines and exits non-zero on failure, so CI and humans read them the same way.

| File | What it checks |
|---|---|
| `eol_test.sh` | Every tracked `*.sh`, `*.yaml`, `*.yml`, `*.tf`, `*.go` and `*.md` file has LF line endings in both the index and the working tree. It reads `git ls-files --eol` and lists any offenders. |
| `image_smoke_test.sh` | Builds `zdp-app:test`, then runs it against real Postgres + Valkey on network `zdp-smoke`. It asserts: `/healthz` 200; `/readyz` 200 within 20 s (migrations done, dependencies reachable); `/api/items/7`; `POST /api/jobs` 202; the worker container completes the job (`jobs:done_total=1`); `docker stop` gives **exit 0 in under 30 s**, which proves SIGTERM draining rather than a SIGKILL; compressed pull size < 25 MB. |
| `bump_release_test.sh` | Uses throwaway bare and clone repos, so it never touches GitHub. It checks: a promotion succeeds even after someone else pushed to main (rebase and retry); the other commit is preserved; the release file pins both the version and the digest; re-promoting the same artifact is a no-op; malformed digests and unknown stages are rejected. |
| `docs_test.sh` | Documentation completeness, so the written promises can't drift from the repo. It fails when: a folder of code/config has no `code-review.md` (or a parent review naming it); a review names a file that doesn't exist; `decisions.md` misses an ADR from 001–024; the README coverage table lacks one of the brief's 11 items; an evidence README has no `Label:`; a required doc or a runbook an alert links to is missing; `docs/architecture.md` exceeds 3,000 words (~5 pages); or `LICENSE` differs by one byte from the owner's original (sha256 pinned). No cluster or Docker needed. |
| `gate_test.sh` | Puts a **stub `kubectl`** on `PATH` that replays canned Argo CD, Rollout and Prometheus answers for eight scenarios, against a throwaway repo with a release file. **healthy** → `GATE PASS`. **transient-degraded** (the app is Degraded for 2 polls, then Healthy) → still passes. **aborted** (`status.abort: true` on the expected digest, with the app Degraded) → fails fast. **stale-abort** (a previous release's abort is still present until Argo CD syncs the new digest) → ignored, and the gate passes. **never-healthy** (with `GATE_TIMEOUT=5`) → fails within the timeout ("Application not Synced/Healthy"). **wrong-digest** → "digest mismatch". **sli-breach** (8% errors) → "error ratio". **no-traffic** (empty vectors) → "no traffic". No cluster is needed, so it runs in CI. |

**Windows note:** Git Bash rewrites arguments that look like absolute paths (`/worker` → `C:/Program Files/Git/worker`). The smoke test wraps `docker` with `MSYS_NO_PATHCONV=1`, scoped to docker only, because native `git.exe` still needs the conversion.

**Why `eol_test.sh` exists:** the host is Windows with `core.autocrlf=true`. A CRLF in a bash shebang line or a YAML file fails in confusing ways (`bad interpreter`, odd parse errors), and only on some machines. `.gitattributes` prevents it, and this test proves the prevention works.

**Verify:** `bash scripts/tests/eol_test.sh` prints `OK: all text files LF`.

**Label:** RUN-LOCAL.
