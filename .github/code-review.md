# .github/ — code review

**Purpose:** CI/CD definitions and repository governance.

| File | What it does |
|---|---|
| `workflows/ci.yml` | **PR validation**, on GitHub-hosted runners only, with no cluster access. Triggers: `pull_request` and `workflow_dispatch`. There is deliberately no `push` trigger, so CI doesn't run twice per PR. `permissions: contents: read`; one run per ref, superseded runs are cancelled. Six jobs, **each one a required status check** on `main`: **`go-test`**: `go vet`, unit tests, and integration tests against real Postgres 18.6 and Valkey 9.1 service containers. **`chart-test`**: `render_test.sh` (35 assertions, kubeconform incl. CRD schemas, promtool on the SLO and backup rules) and `helm lint` for both charts. **`policy-test`**: `conftest verify` (11 policy unit tests), then every `tenants/*.yaml` against the onboarding policy (EU residency etc.). **`terraform-validate`**: `fmt -check`, then `init -backend=false && validate` for **every** root (local and AWS), then `tflint --recursive`. **`iac-scan`**: `trivy config` on infra, both charts and the Dockerfile; fails on HIGH/CRITICAL. **`shell-lint`**: `shellcheck`, the LF check, and the script tests that need no cluster: `bump_release_test`, `gate_test` and `docs_test`. |
| `workflows/release.yml` | **Build once, promote by digest.** It triggers on a push to main touching `app/**` or `charts/**` (not `*.md`, and not `*_test.go`: docs and test-only changes cannot change the artifact), or on `workflow_dispatch`; `concurrency: release`, never cancelled. Jobs: **`build`** builds and pushes `ghcr.io/…/zero-downtime-platform:sha-<sha>` and outputs the **digest**. A chart-only change skips the build and reuses the digest in `dev.yaml`. **`scan`** runs Trivy on that digest (fails on fixable HIGH/CRITICAL) and produces a CycloneDX SBOM. **`sign`** runs keyless `cosign sign` and `cosign attest --type cyclonedx`, using `id-token: write` only here. **`chart`** packages `charts/app` as `0.1.<run_number>`, pushes it to `oci://ghcr.io/…/charts`, and signs the chart digest. Then `dev` → `staging` → `prod-ring0` (Environment **production**, with a required reviewer) → `ring1` (acme) → `ring2` (globex), each a call to `_promote.yml`. A failed job stops every later stage. |
| `workflows/_promote.yml` | A reusable promotion step. **`promote`** runs on a hosted runner in the stage's GitHub Environment: it checks out `main` with the **deploy key** and runs `bump-release.sh`, a commit that Argo CD pulls. **`gate`** runs `gate.sh` on the self-hosted runner `[self-hosted, local-kind]`, read-only, with a 45-minute timeout. Inputs reach `run:` steps through `env:`, never interpolated into the script, which avoids script injection. |
| `CODEOWNERS` | `/tenants/`, `/gitops/releases/` and `/policy/` require the owner's review |

**Supply-chain hygiene:**
- Every third-party action is **pinned by commit SHA**, with the tag in a comment. A moved tag can't change what runs.
- Tool versions are read from `config/versions.env`, the same file the laptop uses.

**Ruleset `main-protection`** (`scripts/repo-ruleset.sh`):
- PR plus 1 code-owner approval, the 6 checks green, no force-push, no deletion.
- Bypass actors: repo **admins** (a solo owner can't approve their own PR, so a "reviewed change" here means green checks plus an admin merge, documented in ADR-020) and **deploy keys** (the release pipeline's promotion commits).

**Verify:** [evidence/00-ci](../evidence/00-ci/README.md) shows a policy failure blocking a PR, then all checks green.

**Label:** RUN-LOCAL (GitHub Actions).
