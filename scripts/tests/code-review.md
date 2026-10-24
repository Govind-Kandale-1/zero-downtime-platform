# scripts/tests/ — code review

**Purpose:** tests for repository hygiene and for the operator scripts. Each test prints `OK`/`PASS` lines and exits non-zero on failure, so CI and humans read them the same way.

| File | What it checks |
|---|---|
| `eol_test.sh` | Every tracked `*.sh`, `*.yaml`, `*.yml`, `*.tf`, `*.go` and `*.md` file has LF line endings in both the index and the working tree. It reads `git ls-files --eol` and lists any offenders. |

More tests (`bump_release_test.sh`, `gate_test.sh`, `image_smoke_test.sh`, `docs_test.sh`) are added by later build steps.

**Why `eol_test.sh` exists:** the host is Windows with `core.autocrlf=true`. A CRLF in a bash shebang line or a YAML file fails in confusing ways (`bad interpreter`, odd parse errors), and only on some machines. `.gitattributes` prevents it, and this test proves the prevention works.

**Verify:** `bash scripts/tests/eol_test.sh` prints `OK: all text files LF`.

**Label:** RUN-LOCAL.
