# zero-downtime-platform

A cloud-agnostic platform built for a Senior DevOps assignment. It provisions infrastructure through a separate provider layer, deploys a black-box API and worker through a build-once, signed, digest-promoted, metric-gated pipeline, ships with canary releases and automatic rollback, autoscales to 15x on request rate and queue depth, and runs one shared stack plus dedicated per-tenant stacks from a single template.

> **Licence:** all rights reserved. Evaluation use only. See [LICENSE](LICENSE).

## Labels used throughout

| Label | Meaning |
|---|---|
| `RUN-LOCAL` | Executed on the local kind platform |
| `RUN-LOCAL (stand-in)` | Executed, but against the minimal stand-in app rather than the real black box |
| `NOT RUN (static validation only)` | Written and validated (`terraform validate`, tflint, trivy), never applied |
| `DESCRIBED` | Design only |

## Prerequisites

- Windows 11 or Linux with Docker (Docker Desktop on WSL2 with at least 9 GB of memory), kind 0.30, kubectl, Helm 4, Terraform ≥ 1.14 and GitHub CLI (authenticated).
- Run scripts from **Git Bash** on Windows (`C:\Program Files\Git\bin\bash.exe`), not WSL's `bash.exe`.
- Go and the other CLIs are optional: `scripts/lib/tools.sh` runs pinned containers when they're missing.

## Quickstart

Run from Git Bash in the repo root.

**1. One-time GitHub setup** (repo owner only; it writes a repo secret):

```bash
bash scripts/deploy-key.sh
```

**2. Empty laptop → running platform:**

```bash
bash scripts/up.sh
```

This creates the state DB, the kind cluster, per-stack Postgres/PgBouncer/Valkey/secrets, Argo CD and the whole platform layer, then the self-hosted gate runner. It finishes by printing the URLs and the Argo CD admin password:
- http://argocd.localtest.me
- http://grafana.localtest.me
- http://rollouts.localtest.me
- http://prometheus.localtest.me

**3. Ship a release:** push a change under `app/` or `charts/`, or run:

```bash
gh workflow run release.yml
```

The pipeline builds once, scans, signs, then promotes dev → staging. It waits for your approval of the `production` environment in GitHub, then continues to prod (the shared stack) → ring 1 (acme) → ring 2 (globex), with a metric gate after every stage.

**4. Tear down:** `bash scripts/down.sh` destroys the infrastructure but keeps the state; `bash scripts/down.sh --purge` returns to an empty laptop.

**Tests you can run at any time:**

| Command | What it proves |
|---|---|
| `bash scripts/test-go.sh unit` (and `integration`) | Stand-in app behaviour (integration against real Postgres + Valkey) |
| `bash charts/app/tests/render_test.sh` | Chart properties, schemas, SLO PromQL |
| `bash infra/live/local/20-data/tests/contract_test.sh` | The provider contract, for every stack |
| `bash gitops/tests/platform_test.sh` | Platform layer healthy end to end |
| `bash scripts/tests/gate_test.sh` | Promotion gate behaviour (stubbed cluster) |

## Where to read

- `decisions.md`: every decision with rejected alternatives.
- `questions-answers.md`: review questions and answers.
- `code-review.md` in each folder: what the code in that folder does and why.
- `docs/superpowers/specs/`: the approved design. `docs/superpowers/plans/`: the build plan.
