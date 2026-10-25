# scripts/tests/ — code review

**Purpose:** tests for repository hygiene and for the operator scripts. Each test prints `OK`/`PASS` lines and exits non-zero on failure, so CI and humans read them the same way.

| File | What it checks |
|---|---|
| `eol_test.sh` | Every tracked `*.sh`, `*.yaml`, `*.yml`, `*.tf`, `*.go` and `*.md` file has LF line endings in both the index and the working tree. It reads `git ls-files --eol` and lists any offenders. |

| `image_smoke_test.sh` | Builds `zdp-app:test`, then runs it against real Postgres + Valkey on network `zdp-smoke`. It asserts: `/healthz` 200; `/readyz` 200 within 20 s (migrations done, dependencies reachable); `/api/items/7`; `POST /api/jobs` 202; the worker container completes the job (`jobs:done_total=1`); `docker stop` gives **exit 0 in under 30 s**, which proves SIGTERM draining rather than a SIGKILL; compressed pull size < 25 MB. |

More tests (`bump_release_test.sh`, `gate_test.sh`, `docs_test.sh`) are added by later build steps.

**Windows note:** Git Bash rewrites arguments that look like absolute paths (`/worker` → `C:/Program Files/Git/worker`). The smoke test wraps `docker` with `MSYS_NO_PATHCONV=1`, scoped to docker only, because native `git.exe` still needs the conversion.

**Why `eol_test.sh` exists:** the host is Windows with `core.autocrlf=true`. A CRLF in a bash shebang line or a YAML file fails in confusing ways (`bad interpreter`, odd parse errors), and only on some machines. `.gitattributes` prevents it, and this test proves the prevention works.

**Verify:** `bash scripts/tests/eol_test.sh` prints `OK: all text files LF`.

**Label:** RUN-LOCAL.
