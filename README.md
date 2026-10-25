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
| `bash scripts/tests/bump_release_test.sh` | Promotion commits survive concurrent pushes; digests validated |
| `bash scripts/tests/image_smoke_test.sh` | The image serves, drains on SIGTERM (exit 0 in < 30 s), stays < 25 MB |
| `bash scripts/restore-test.sh <namespace>` | A fresh backup restores into a scratch database with identical rows (prints the RTO) |
| `bash scripts/tests/docs_test.sh` | Every ADR exists, this coverage table is complete, every doc carries a label, linked docs exist, LICENSE is unchanged |

## Brief coverage

| # | Brief item | Status | Label | Evidence / where |
|---|---|---|---|---|
| 1. | **Cloud-agnostic IaC**: a provider layer (network, k8s, databases, secrets) separate from platform and app; two targets; a non-portable list | Built for kind; written for AWS (EKS, RDS, ElastiCache, Secrets Manager) against the same provider contract | RUN-LOCAL; AWS NOT RUN | `infra/`, `infra/live/local/20-data/tests/contract_test.sh`, [non-portable.md](docs/non-portable.md), [evidence/08-aws-static](evidence/08-aws-static/README.md), ADR-001/003/022 |
| 2. | **Full automation**: empty → running with no console steps; remote state; drift detection; a secrets manager | `up.sh` takes an empty laptop to a running platform (24 min 52 s); `pg` remote state with locking (S3 + lockfile on AWS); OpenBao + External Secrets; Argo CD self-heal for Kubernetes drift. A scheduled **Terraform** drift check is DESCRIBED | RUN-LOCAL; Terraform drift DESCRIBED | [evidence/00-bringup](evidence/00-bringup/README.md), [drift-detected](docs/runbooks/drift-detected.md), ADR-004/009/010 |
| 3. | **Multi-stage pipeline**: build once, scan, sign, promote the same digest dev → staging → prod; gates on real metrics | Built. Trivy, CycloneDX SBOM and keyless cosign; the chart is promoted as a signed OCI artifact; read-only metric gates after every stage; a human approval before prod | RUN-LOCAL | [evidence/05-supply-chain](evidence/05-supply-chain/README.md), [evidence/00-bringup](evidence/00-bringup/README.md), [evidence/00-ci](evidence/00-ci/README.md), ADR-014/015 |
| 4. | **Deployment strategy**: justified choice for API and worker; traffic steps, gating metrics, automatic rollback; GitOps vs push; rollout order shared → rings → regions | Built. API canary 10/25/50 via Traefik weights with edge-metric analysis; worker gated rolling; GitOps pull; fleet order prod (shared) → ring 1 → ring 2 with halt on failure. Regions are simulated locally | RUN-LOCAL (stand-in) | [evidence/02-auto-rollback](evidence/02-auto-rollback/README.md), [architecture.md](docs/architecture.md) §5, ADR-010/011/012 |
| 5. | **Zero downtime**: graceful shutdown, probes, PDBs, worker draining, expand/contract migrations, rollback after a migration | Built. **116,988 requests, 0 failed** during a prod canary; the old version ran on an expanded schema after rollback | RUN-LOCAL (stand-in) | [evidence/01-deploy-under-load](evidence/01-deploy-under-load/README.md), [evidence/02](evidence/02-auto-rollback/README.md), [rollback-after-migration](docs/runbooks/rollback-after-migration.md), ADR-018 |
| 6. | **Autoscaling**: 15x in < 5 min and back, no dropped jobs, queue depth for workers, capacity maths, DB limits | Built: KEDA on edge RPS + in-flight + CPU (API) and queue length (worker). **No job lost** in any test. **15x with zero errors was not achieved**: the laptop's ceiling is ~650–800 req/s, and the headroom analysis shows the current targets would saturate briefly even on real infrastructure (fix designed) | RUN-LOCAL (stand-in), partial | [evidence/03-load-15x](evidence/03-load-15x/README.md), [capacity.md](docs/capacity.md), ADR-013 (3 revisions), ADR-024 |
| 7. | **Multi-deployment**: shared + dedicated from one template; a new tenant in < 30 min via one reviewed change; fleet rollout with halt on failure; EU data stays in the EU | Built: one chart for every stack; shared tenants are host routes, dedicated tenants get their own namespace and data services; onboarding is one tenant file. CI blocks non-EU regions for EU tenants. **The onboarding time is not measured** (the apply is manual; `tenant-apply.yml` is on the roadmap) | RUN-LOCAL; timing DESCRIBED | `tenants/`, `policy/`, [evidence/00-ci](evidence/00-ci/README.md), [failed-tenant-onboarding](docs/runbooks/failed-tenant-onboarding.md), ADR-017 |
| 8. | **Operations**: SLOs 99.9 / 99.95, alerts, per-tenant visibility, runbooks, backups, restore test | Built: edge SLIs, multi-window burn-rate alerts, cause alerts (queue, DB pool, stale backups), per-tenant availability SLIs, 9 runbooks, hourly + pre-deploy backups, a timed restore drill. Per-tenant dashboards are DESCRIBED | RUN-LOCAL (stand-in) | [slos.md](docs/slos.md), [docs/runbooks/](docs/runbooks/), [evidence/04-restore-test](evidence/04-restore-test/README.md), ADR-019/023 |
| 9. | **Cost and plan**: a steady + peak monthly estimate; a 90-day roadmap | **$2,789 steady / $5,073 peak** (upper bound) on AWS list prices fetched 2026-10-25; up to 8 dedicated tenants within $9k / $16k | DESCRIBED | [cost.md](docs/cost.md) (+ `scripts/fetch-prices.sh`, `docs/cost-prices.csv`), [roadmap.md](docs/roadmap.md) |
| 10. | **Deliverables**: repo; architecture doc ≤ 5 pages; evidence (deploy under load, auto-rollback, 15x, restore); change-request addendum | Repo, architecture doc and evidence 01–04 are done (15x partial, see row 6). **The change-request addendum is pending**: the request had not been received when this was written | mixed | [architecture.md](docs/architecture.md), `evidence/` |
| 11. | **Label everything not run** | Every evidence README, doc and runbook carries a label; `docs_test.sh` fails if one has none | — | the labels table above |

## Tested with the stand-in vs the real app

The brief's app is a black box, so a minimal Go stand-in (`app/`, ADR-005) implements its contract. What that means for each result:

| Holds for the real app as-is (platform behaviour) | Measured on the stand-in, must be re-measured with the real app |
|---|---|
| The pipeline: build once, scan, sign, promote by digest, gates, halt on failure | Per-pod capacity (C ≈ 180 req/s, so `rpsPerPod` 126) and CPU per request (~1.4 m per req/s) |
| Canary mechanics, traffic steps and automatic abort (the fault was injected as a real code change) | Startup time, drain time, and whether it drains on SIGTERM at all (architecture risk 3) |
| GitOps sync, drift self-heal, ring order | Migration behaviour: the stand-in tolerates a newer schema; the real app must too (open question) |
| Backups and the restore drill; SLO rules and alerts on edge SLIs | Queue semantics (`BLMOVE`, heartbeats, reaper) and job idempotency |
| Residency policy and tenant routing | The `http_inflight_requests` and `queue_oldest_job_age_seconds` metrics the scalers and alerts use (`api.inflightMetric` is configurable) |

## Manual steps (everything else is automated)

1. **Once per repository:** `bash scripts/deploy-key.sh`. It writes a deploy key and the `GITOPS_DEPLOY_KEY` secret, so it stays a human step.
2. **Once per release:** approve the `production` environment in GitHub. That's the human gate before prod (ring 0).
3. **When onboarding a dedicated tenant:** `terraform apply` in `infra/live/local/20-data` after the tenant PR merges (automated by `tenant-apply.yml` on the roadmap).
4. **AWS only, once per account:** `infra/bootstrap/aws` with local state, to create the state bucket (the chicken-and-egg step; NOT RUN).

## Evidence index

| Folder | What it shows |
|---|---|
| [00-bringup](evidence/00-bringup/README.md) | empty laptop → running platform → first fleet release; NetworkPolicy enforcement check |
| [00-ci](evidence/00-ci/README.md) | CI blocks a tenant that violates EU residency |
| [01-deploy-under-load](evidence/01-deploy-under-load/README.md) | a prod canary under 150 req/s with zero failed requests |
| [02-auto-rollback](evidence/02-auto-rollback/README.md) | a bad release aborted automatically; rollback after a migration |
| [03-load-15x](evidence/03-load-15x/README.md) | three 15x attempts, what failed and why, the headroom analysis |
| [04-restore-test](evidence/04-restore-test/README.md) | timed restores; the backup stall that was found and fixed |
| [05-supply-chain](evidence/05-supply-chain/README.md) | scan, SBOM, signature and digest verification |
| [08-aws-static](evidence/08-aws-static/README.md) | AWS code: `terraform validate`, tflint, trivy |

## Where to read

- [docs/architecture.md](docs/architecture.md): the 5-page overview (diagram, flows, five key decisions, top five risks).
- [docs/architecture/](docs/architecture/README.md): **how the platform works**, component by component: [what each component is and why it's there](docs/architecture/components.md), [where everything lives](docs/architecture/where-things-live.md) (machines, namespaces, repo folders, state, secrets), [step-by-step flows](docs/architecture/flows.md) (release, request, job, scale-up, secret, backup, shutdown), and [tenancy](docs/architecture/tenancy.md).
- [docs/capacity.md](docs/capacity.md), [docs/slos.md](docs/slos.md), [docs/cost.md](docs/cost.md), [docs/non-portable.md](docs/non-portable.md), [docs/roadmap.md](docs/roadmap.md), [docs/runbooks/](docs/runbooks/).
- `decisions.md`: every decision with rejected alternatives. `questions-answers.md`: review questions and answers, including the uncomfortable ones.
- Root files: `.gitattributes` (LF endings, because the host is Windows), `.gitignore`, `.tflint.hcl` (the `terraform` ruleset, recommended preset; no AWS-specific plugin), `.trivyignore.yaml` (one accepted finding, with its reason).
- `docs/superpowers/specs/`: the approved design. `docs/superpowers/plans/`: the build plan.
