# .github/ — code review

**Purpose:** CI/CD definitions and repository governance.

| File | What it does |
|---|---|
| `workflows/ci.yml` | **PR validation**, on GitHub-hosted runners only, with no cluster access. Triggers: `pull_request` and `workflow_dispatch`. There is deliberately no `push` trigger, so CI doesn't run twice per PR. `permissions: contents: read`; one run per ref, superseded runs are cancelled. Six jobs, **each one a required status check** on `main`: **`go-test`**: `go vet`, unit tests, and integration tests against real Postgres 18.6 and Valkey 9.1 service containers. **`chart-test`**: `render_test.sh` (24 assertions, kubeconform incl. CRD schemas, promtool on the SLO rules) and `helm lint` for both charts. **`policy-test`**: `conftest verify` (11 policy unit tests), then every `tenants/*.yaml` against the onboarding policy (EU residency etc.). **`terraform-validate`**: `fmt -check`, then `init -backend=false && validate` for **every** root (local and AWS), then `tflint --recursive`. **`iac-scan`**: `trivy config` on infra, both charts and the Dockerfile; fails on HIGH/CRITICAL. **`shell-lint`**: `shellcheck`, the LF check, and script tests that need no cluster. |
| `CODEOWNERS` | `/tenants/`, `/gitops/releases/` and `/policy/` require the owner's review |

**Supply-chain hygiene:**
- Every third-party action is **pinned by commit SHA**, with the tag in a comment. A moved tag can't change what runs.
- Tool versions are read from `config/versions.env`, the same file the laptop uses.

**Ruleset `main-protection`** (`scripts/repo-ruleset.sh`):
- PR plus 1 code-owner approval, the 6 checks green, no force-push, no deletion.
- Bypass actors: repo **admins** (a solo owner can't approve their own PR, so a "reviewed change" here means green checks plus an admin merge, documented in ADR-020) and **deploy keys** (the release pipeline's promotion commits).

**Verify:** [evidence/00-ci](../evidence/00-ci/README.md) shows a policy failure blocking a PR, then all checks green.

**Label:** RUN-LOCAL (GitHub Actions).
