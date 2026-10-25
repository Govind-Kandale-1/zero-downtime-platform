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

## ADR-006: Reliable list queue (BLMOVE + heartbeat reaper), at-least-once delivery

2026-10-25 · Accepted · Label: RUN-LOCAL (stand-in)

**Context.** The brief requires autoscaling "without dropping jobs" (jobs take up to 60 s) and worker draining during rollouts. A worker can be stopped by a rollout, by KEDA scale-in, by node drain, by OOM or by a crash. The first three send SIGTERM; the last two don't.

**Decision.**
- **Claims are atomic moves, not pops.** `BLMOVE jobs → jobs:processing:<pod>`, so a job is always in exactly one list (pending, processing or failed).
- **Graceful stops.** On SIGTERM the worker stops claiming and finishes the job in hand. Its heartbeat keeps running until it exits, and `terminationGracePeriodSeconds: 90` exceeds the 60 s maximum job.
- **Ungraceful stops.** Each worker keeps a heartbeat key with a 30 s TTL. A reaper (one leader via `SET NX EX`) moves the processing lists of dead workers back to the *head* of the queue.
- **Accounting.** Counters (`enqueued_total`, `done_total`, `failed_total`) make "zero dropped jobs" provable.

**Rejected alternatives.**
- *Plain `BRPOP`:* simplest, but a crash between pop and completion loses the job silently.
- *Redis Streams with consumer groups (`XREADGROUP` + `XAUTOCLAIM`):* the industry-standard version of the same idea. Rejected only because the brief fixes the black box to a *list*-style "Redis queue", and KEDA's Redis *Lists* scaler matches that. Streams would be the choice for a new system.
- *KEDA ScaledJob (one Kubernetes Job per queue item):* never interrupts a job, but at 5.56 jobs/s it means 5.56 pod starts per second. Too much churn and too slow.
- *Exactly-once:* needs a dedupe store keyed by job id plus transactional side effects. Out of scope; jobs must be idempotent instead.

**Consequences.**
- Delivery is **at-least-once**. A job finished just before a crash (before `Ack`) runs again, so real jobs must be idempotent. This is listed as an assumption about the black box.
- After an ungraceful death, a job waits up to ~30 s (heartbeat TTL) plus up to 15 s (reaper interval) before it is retried.

## ADR-004: Terraform for the provider layer; `pg` backend locally, S3 with native locking on AWS

2026-10-25 · Accepted · Label: RUN-LOCAL (local) / NOT RUN (AWS)

**Context.** The brief requires IaC, remote state and drift detection, starting from an empty account with no console steps. The provider layer must create clusters, networks, managed databases and IAM on any cloud.

**Decision.**
- **Terraform** (≥ 1.14), one numbered root per stage (`10-cluster`, `20-data`, `30-gitops`; AWS adds `05-network`).
- **Local state:** the `pg` backend, pointed at a Postgres container (`zdp-tfstate`) started by `scripts/state-up.sh`. Each root gets its own schema, and locking uses Postgres advisory locks. The credentials live in the git-ignored `.local/tfstate.env`.
- **AWS state:** the `s3` backend with `use_lockfile = true` (S3-native conditional-write locking, so no DynamoDB table). The bucket is created by `infra/bootstrap/aws`, which uses local state.

**Rejected alternatives.**
- *OpenTofu:* functionally equivalent here and a fine choice. Terraform is already installed and more commonly asked about, and the code runs on both.
- *Pulumi / CDK:* infrastructure in a general-purpose language. It adds a second toolchain and a different review model, and gives no advantage for declarative cloud resources.
- *Crossplane:* needs a cluster before it can build one, and adds a control plane to operate (see ADR-003).
- *Local state for the local target:* violates "remote state" and has no locking.
- *S3 emulation (MinIO/LocalStack) to mirror AWS exactly:* adds a component whose licensing and distribution have changed recently. The interesting property is *networked state with locking*, which the pg backend gives directly.
- *The Kubernetes backend:* state would live inside the cluster that Terraform creates (chicken-and-egg), and destroying the cluster would destroy the state.

**Consequences.**
- The backend *type* differs per target (`pg` vs `s3`), so it is listed as non-portable. Everything else in the roots is identical.
- The bootstrap stack for AWS keeps local state by necessity; this is documented.
- Drift detection is `terraform plan -detailed-exitcode` per root (exit 2 = drift).

## ADR-007: CloudNativePG + PgBouncer in transaction mode, with a separate direct URL for migrations

2026-10-25 · Accepted · Label: RUN-LOCAL (local) / NOT RUN (AWS RDS)

**Context.** At 15x the platform runs about 40 API pods and up to about 120 workers. With a 10-connection pool per API pod and 2 per worker, that is roughly **640 client connections**, while a Postgres primary performs best with a few dozen active backends. Separately, the black box runs migrations at startup, and safe concurrent migrations need a **session-level advisory lock**.

**Decision.**
- **Pooling.** Every stack gets PgBouncer in **transaction mode** (`max_client_conn=1000`, `default_pool_size=40`). Runtime traffic uses `DATABASE_URL` → PgBouncer.
- **Migrations go direct.** They use `MIGRATION_DATABASE_URL` straight to the primary.
- **The trap this avoids.** In transaction mode, PgBouncer may give each transaction a different server backend. A `pg_advisory_lock` taken in one transaction can then be held by a backend the client never talks to again, and the `pg_advisory_unlock` lands on another backend and does nothing. The result is a lock held forever, or two pods migrating at once. Flyway, golang-migrate and Prisma all use session advisory locks.
- **Where it runs.** Locally, Postgres is a CloudNativePG `Cluster`, with PgBouncer from its `Pooler` CRD. On AWS: RDS PostgreSQL Multi-AZ plus an in-cluster PgBouncer Deployment.

**Rejected alternatives.**
- *No pooler:* about 640 backends on one primary means context switching and per-backend memory, and `max_connections` exhaustion during scale-up.
- *PgBouncer in session mode for everything:* safe for advisory locks, but gives almost no multiplexing. One client equals one backend.
- *RDS Proxy:* managed, but AWS-only (not portable). It "pins" connections that use session state such as advisory locks, which silently removes the pooling benefit.
- *Bitnami PostgreSQL chart:* Bitnami's free images moved to an unmaintained legacy repository in 2025.
- *A plain Postgres StatefulSet:* no failover, backup or pooler management. CNPG behaves much more like a managed service.

**Consequences.**
- The app must accept two URLs. The stand-in does; for the real black box this is an assumption. If it accepts only one, run its migrations through a session-mode pool, or a direct URL plus a startup flag.
- Prepared statements over transaction mode need PgBouncer ≥ 1.21 (`max_prepared_statements`) or driver settings that avoid them.
- The connection maths lives in `docs/capacity.md`.

## ADR-008: Valkey instead of Redis

2026-10-25 · Accepted · Label: RUN-LOCAL (local) / NOT RUN (AWS)

**Context.** The black box consumes a "Redis queue", so any Redis-protocol server works. In 2024 Redis moved from BSD to source-available licences (RSAL/SSPL), and Redis 8 added AGPL as an option.

**Decision.** Valkey 9.1 (the Linux Foundation fork of Redis 7.2, BSD-licensed) runs locally as a StatefulSet with AOF persistence and `noeviction`. On AWS it is **ElastiCache for Valkey**.

**Rejected alternatives.**
- *Redis OSS / Redis 8:* the licence terms are a procurement and legal question for a platform that may be resold to tenants. Valkey removes the question at no functional cost.
- *KeyDB / Dragonfly:* compatible, but less widely adopted, and not offered as a managed service on the major clouds.

**Consequences.**
- The client libraries (go-redis), KEDA's Redis scaler and redis_exporter all work unchanged with Valkey.
- ElastiCache for Valkey is priced about 20% below ElastiCache for Redis OSS, which helps the cost model.

## ADR-009: OpenBao + External Secrets Operator as the secrets interface

2026-10-25 · Accepted · Label: RUN-LOCAL (local) / NOT RUN (AWS)

**Context.** The brief requires a secrets manager. The provider contract needs the app's database and cache URLs to come from it, without the app layer knowing which cloud it is on.

**Decision.**
- **One flow on both targets:** Terraform writes `stacks/<stack>/app` into the secrets manager. **External Secrets Operator** syncs it into a Kubernetes Secret `app-env` in each stack namespace, through a `ClusterSecretStore` named `platform-secrets`.
- **Locally**, the store is **OpenBao** in dev mode, using a token.
- **On AWS**, the store is **AWS Secrets Manager**, using EKS Pod Identity.
- The app chart's `ExternalSecret` is identical on both targets. Only the `ClusterSecretStore` spec differs.

**Rejected alternatives.**
- *Plain Kubernetes Secrets written by Terraform:* no secrets manager, no rotation, no audit, and the values end up in Terraform state *and* etcd with no central control.
- *SOPS-encrypted secrets in Git:* good for GitOps, but key management moves to the repo, rotation means a commit, and there is no runtime audit trail. Not a "secrets manager".
- *Sealed Secrets:* one controller key per cluster, so it doesn't map onto a cloud secrets manager and is hard to share across clusters.
- *Vault (HashiCorp):* the same API, but BSL-licensed since 2023. OpenBao is the open-licence fork, and ESO's Vault provider works with it unchanged.

**Consequences.**
- The secrets are still present in Terraform state, which generated them. State is therefore treated as sensitive: it is held in a credentialed Postgres locally and in an encrypted, access-controlled S3 bucket on AWS.
- Dev-mode OpenBao loses data on restart. That is acceptable for a laptop: `terraform apply` re-seeds it, and drift detection notices the loss.

## ADR-010: GitOps pull with Argo CD (app-of-apps + ApplicationSets)

2026-10-25 · Accepted · Label: RUN-LOCAL

**Context.** The brief asks to "choose GitOps (pull) or pipeline push" and to roll out shared first, then dedicated tenants in rings, then regions. The cluster may be anywhere (a laptop, a private VPC), and the platform must correct drift.

**Decision.**
- **Pull model.** Argo CD runs in each cluster and pulls from Git every 60 s. Terraform installs it and applies one root Application (app-of-apps).
- **What the root manages.**
  - Platform components: one Application each, ordered by sync waves.
  - Environment stacks and tenants: ApplicationSets driven by `gitops/stacks/*.yaml` and `tenants/*.yaml`, with release-file pins.
- **What pipelines do.** They never call `kubectl` or `helm` against a cluster. They only commit to Git.
- **Drift.** Automated sync with prune and self-heal.

**Rejected alternatives.**
- *Pipeline push (`helm upgrade`/`kubectl apply` from CI):*
  - CI would need cluster-admin credentials for every cluster, with a large blast radius if leaked.
  - The cluster must be reachable from CI, which a private EKS or a laptop isn't.
  - There's no continuous drift correction: a manual `kubectl edit` survives until the next deploy.
- *Flux:* an equally valid pull-based tool. Argo CD was chosen for its UI (useful for the demo and the review), its first-class Argo Rollouts integration (rollout health, abort and promote in the UI), and ApplicationSets for tenant fan-out.
- *One central Argo CD managing remote clusters (hub-and-spoke):* fewer installs, but the hub then holds credentials for every cluster and becomes a single point of failure. Per-cluster Argo CD keeps the pull model pure. A hub is a roadmap item, once there are many clusters.

**Consequences.**
- A promotion takes effect within about 60 s plus sync time, not instantly. That is acceptable and visible.
- The pipeline needs a way to *observe* the result without pushing. Gates read Rollout status and metrics with read-only credentials (ADR-015).
- Git becomes production-critical. If GitHub is down, nothing new deploys, but running workloads are unaffected.
