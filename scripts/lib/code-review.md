# scripts/lib/ — code review

**Purpose:** helpers that every script sources, so behaviour is consistent across Windows and Linux.

| File | What it does |
|---|---|
| `common.sh` | `repo_root`, `log`, `die`, `require <cmd>`, and `load_config` (exports both files in `config/`). Also `host_path <dir>`, which returns a path `docker.exe` accepts for bind mounts: `C:/...` in Git Bash, the plain path on Linux. |
| `tools.sh` | `tool_go`, `tool_yq`, `tool_jq`, `tool_conftest`, `tool_kubeconform`, `tool_trivy`, `tool_tflint`, `tool_k6`, `tool_shellcheck`. Each uses the native binary when present (CI), otherwise the pinned container image with the repo mounted at `/work` and the same relative working directory. |

**Key decisions:**
- ADR-021: containers instead of host installs, so local runs use the same versions as CI.
- `MSYS_NO_PATHCONV=1` stops Git Bash from rewriting `/work`-style container paths into Windows paths.
- `tool_go` keeps the module and build caches in named Docker volumes (`zdp-gomod`, `zdp-gocache`), so repeated test runs are fast.
- `tool_trivy` mounts the Docker socket so it can scan locally built images.
- Extra `docker run` flags (e.g. `--network zdp-test` for integration tests) are passed through `TOOL_DOCKER_ARGS`.

**Verify:** `source scripts/lib/tools.sh && tool_yq --version && tool_jq --version`.

**Limitations:** tools run in a container can only see files inside the repo, and they reach host services through Docker networking, not `localhost`.

**Label:** RUN-LOCAL.
