# Decision Log

Every significant decision, the alternatives that were rejected, and the reason. Entries are appended as the work proceeds; IDs are stable (gaps mean the entry belongs to a later build step).

**Labels:**
- `RUN-LOCAL`: executed on the local kind platform.
- `RUN-LOCAL (stand-in)`: executed against the stand-in app, not the real black box.
- `NOT RUN (static validation only)`: written and validated, never applied.
- `DESCRIBED`: design only.

Template:

```
## ADR-NNN: Title
Date · Status · Label
**Context** — why a decision was needed
**Decision** — what we chose
**Rejected alternatives** — each with the reason
**Consequences** — what this costs us / what it enables
```

---

## ADR-001: Local kind is the only executed target; AWS is written and statically validated

2026-10-25 · Accepted · Label: RUN-LOCAL (local) / NOT RUN (AWS)

**Context.** The brief asks for the platform to "run on two targets (for example one cloud plus local kind/k3d)". An AWS account exists, but its credentials were invalid at the start. The submitter also chose not to spend money on live cloud infrastructure for an evaluation exercise.

**Decision.**
- Everything is built and executed on a local kind cluster.
- The AWS provider layer (VPC, EKS, RDS, ElastiCache for Valkey, Secrets Manager, S3 state, GitHub OIDC) is written in full against the same provider contract.
- In CI it is validated with `terraform validate`, `tflint` and `trivy config`.
- It is labelled `NOT RUN` everywhere.

**Rejected alternatives.**
- *Real EKS, created and destroyed each session (~$0.50/h, ~$15–25 total):* the strongest evidence, but declined by the submitter for cost and credential reasons.
- *Always-on EKS (~$12–15/day):* the same, and more expensive.
- *k3d as a second local target:* two local distributions prove little about cloud portability. The interesting differences are LB, IAM, managed databases and node autoscaling, and only a real cloud implementation exercises them.

**Consequences.** The "two targets" requirement is only *partially* met, and this is stated openly in the README. The portability claim rests on two things: (a) the provider contract, and (b) a complete second implementation that compiles and passes static analysis. The roadmap's first item is to run the AWS target.

## ADR-002: Proprietary, evaluation-only licence

2026-10-25 · Accepted · Label: n/a

**Context.** The repository is public so that reviewers can access it and so that GitOps can pull without credentials (ADR-020). Public is not the same as open source.

**Decision.** The root `LICENSE` contains the submitter's exact notice: all rights reserved; for evaluation during the interview process with immverse only; no commercial use, deployment or modification for production without written permission. The text is never edited, and no OSI licence is added.

**Rejected alternatives.**
- *MIT or Apache-2.0:* they grant reuse rights the author does not want to give.
- *No licence file:* legally "all rights reserved" by default, but ambiguous to readers. An explicit notice states the intended use.

**Consequences.** GitHub's Terms of Service still let anyone view and fork a public repo on GitHub; the licence forbids any use beyond that. `gh repo create` is run without `--license`.

## ADR-003: Three-layer infrastructure with an explicit provider contract

2026-10-25 · Accepted · Label: RUN-LOCAL / NOT RUN (AWS)

**Context.** The brief requires the provider layer (network, Kubernetes, databases, secrets) to be separate from the platform and app layers, and asks what is not portable.

**Decision.**
- **Provider layer (Terraform):** the only layer that differs per cloud. It must deliver exactly the following, the *provider contract*:
  - a cluster + kubeconfig;
  - per stack: Postgres, PgBouncer at `pgbouncer.<ns>.svc:5432`, and Valkey;
  - a secrets manager holding `DATABASE_URL`, `MIGRATION_DATABASE_URL` and `REDIS_URL` at `stacks/<stack>/app`;
  - a remote state backend with locking.
- **Platform layer (Argo CD-managed Helm):** identical everywhere apart from small per-provider values overlays.
- **App layer:** one Helm chart for every stack.

**Rejected alternatives.**
- *One monolithic Terraform root per cloud:* no portability boundary. Everything would be rewritten per cloud.
- *Crossplane for all infrastructure:* needs a running cluster before it can build one (bootstrap problem), and adds a control plane to learn and operate within the time box.
- *Helm/Kubernetes only:* cannot create networks, managed databases or IAM.

**Consequences.** Adding a cloud (e.g. for the change request) means writing one new provider implementation; nothing above it changes. The contract is listed in `infra/code-review.md`, and the leaks are listed in `docs/non-portable.md`.

## ADR-020: Public repository; `main` protected by a ruleset with a deploy-key bypass for release commits

2026-10-25 · Accepted · Label: RUN-LOCAL

**Context.**
- The repo needs branch protection and an approval step before production.
- The cluster must pull charts and images.
- The pipeline must be able to commit release files to `main`.

**Decision.**
- **Public repo.** Environment required reviewers and rulesets are free on public repos; Argo CD, the kubelet and Kyverno pull with no credentials.
- **Ruleset on `main`:** pull request + code-owner review, required CI checks, no force-push.
- **Bypass actors:**
  - repository admins, so the solo owner can merge;
  - a write-enabled **deploy key** used only by the release workflow to commit `gitops/releases/*.yaml`.
- **Self-hosted runner hardening:**
  - fork-PR workflows need approval;
  - runner-labelled jobs run only on `push`, `schedule` and `workflow_dispatch`;
  - gate jobs use a read-only kubeconfig.

**Rejected alternatives.**
- *Private repo:* on a personal plan it gets no Environment approvals and no enforced branch protection, and needs pull secrets in every namespace.
- *Pushing release commits with `GITHUB_TOKEN`:* blocked by the ruleset, and it can't be made a bypass actor.
- *A PR per promotion:* needs a human merge for every stage and ring, which defeats automated fleet rollout. It remains an option for regulated tenants.

**Consequences.**
- A solo owner cannot approve their own PR, so "reviewed change" means checks plus an admin merge. This limitation is documented.
- Keyless signing records the repo identity in the public Rekor log, which is acceptable for a public repo.

## ADR-021: Toolchain runs in pinned containers on the Windows host

2026-10-25 · Accepted · Label: RUN-LOCAL

**Context.** The host is Windows 11 with Docker Desktop. Go, jq, yq, conftest, kubeconform, trivy, tflint and k6 are not installed; CI (Linux) installs them natively.

**Decision.**
- `scripts/lib/tools.sh` exposes `tool_<name>` functions. Each uses the native binary if present, otherwise the image pinned in `config/versions.env`, with the repo bind-mounted.
- Scripts are bash, run from Git Bash. `.gitattributes` forces LF, and `scripts/tests/eol_test.sh` enforces it.

**Rejected alternatives.**
- *Install everything natively:* modifies the host, and local versions drift from CI.
- *A WSL distro:* yet another environment to keep in sync with Docker Desktop's.
- *A dev container:* a good next step, but heavier to set up inside the time box.

**Consequences.** The same pinned versions run locally and in CI. The cost is a few seconds of container start-up per tool call, plus the Windows path quirks handled in `host_path` (`MSYS_NO_PATHCONV`).

## ADR-024: Load interpretation: 20,000 jobs/hour is the peak rate; mean job duration 10 s

2026-10-25 · Accepted · Label: DESCRIBED (assumption)

**Context.** The brief says "150 req/s baseline, 2,250 req/s peak (15x) with 20,000 jobs/hour" and "jobs up to 60 s". It doesn't say whether the job rate is the baseline or the peak, or what the average job duration is.

**Decision.** 20,000 jobs/h (λ = 5.56 jobs/s) is the *peak* rate, and the mean job duration is 10 s. By Little's law that needs about 56 concurrent workers at peak. The 60 s maximum sets the shutdown grace period (90 s), not the fleet size.

**Rejected alternatives.**
- *Jobs as baseline (×15 at peak = 83 jobs/s, ~830 workers):* kept as a documented sensitivity case in `docs/capacity.md`.
- *Sizing on the 60 s maximum (~333 workers):* wastes capacity, because throughput depends on the mean.

**Consequences.** `docs/capacity.md` carries a sensitivity table (5/10/30/60 s means, both interpretations). If the real mean differs, only `worker.maxReplicas` and the KEDA `listLength` change.

## ADR-005: Stand-in application in Go, contract-only, with a bounded-concurrency capacity model

2026-10-25 · Accepted · Label: RUN-LOCAL (stand-in)

**Context.** The brief treats the application as a black box ("do not rewrite") but supplies no image. Something has to run so the platform can be exercised, and the 15x load test (about 33 API pods and about 60 workers) has to fit in a ~9.7 GB Docker VM on a laptop.

**Decision.**
- **Contract only.** A small Go module with one image and three binaries (`/api`, `/worker`, `/synthetic`). It implements only the black-box contract, plus two stand-in-only knobs.
- **Capacity model.** `MAX_INFLIGHT` (8) is a queueing semaphore and `WORK_LATENCY_MS` (40) is a slept per-request delay. Together they give each pod a finite capacity (≈ `MAX_INFLIGHT / latency`, ~100 req/s), so overload shows up as rising latency, as with a real thread pool.
- **Fault injection.** `FAULT_ERROR_RATE` is a compiled-in default with an env override, used by the bad-release demo.

**Rejected alternatives.**
- *Python/FastAPI:* most readable, but about 4× the memory per pod and slower start-up. That is a problem for both the laptop budget and the scale-up time.
- *An existing demo app (e.g. podinfo):* it has the HTTP endpoints but no Postgres migrations and no Redis worker, so the migration and queue stories couldn't be shown.
- *CPU-burn work per request:* it makes per-pod capacity CPU-bound, but CPU then grows with pod count × load. That would saturate the laptop long before 2,250 req/s and measure the laptop, not the platform.

**Consequences.**
- Every result obtained with it is labelled `RUN-LOCAL (stand-in)`.
- Behaviours the stand-in guarantees but the real app might not are listed in the README as assumptions, each with a mitigation: SIGTERM draining, advisory-locked migrations, a separate migration URL, enqueue timestamps, idempotent jobs.
