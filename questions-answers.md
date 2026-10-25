# Interview Questions & Answers

Likely review questions, grouped by the brief's sections. Each entry has a short answer you can say out loud, the follow-ups to expect, and where to point in the repo. Entries are added as each part is built.

---

## 0. Scope, honesty and labels

### Q: What did you actually run, and what is only described?
**A:** The whole platform runs on a local kind cluster: the provider layer, GitOps, canaries, autoscaling, backups and the pipeline gates. The AWS provider layer is fully written but never applied. It is labelled `NOT RUN` and only statically validated in CI. Every evidence item and README row carries one of four labels, so nothing is presented as run when it wasn't.
**Follow-ups:** "So the two-targets requirement isn't met?" Partially: the second target is a complete implementation that passes `terraform validate`, tflint and trivy, but it isn't applied (ADR-001).
**Point to:** `README.md` coverage table, `decisions.md` ADR-001.

### Q: Why not just spin up EKS for an hour?
**A:** It was a deliberate cost and credentials decision for an evaluation exercise. A create-and-destroy approach would have cost about $15–25. I made the provider contract strict, so running AWS is a matter of credentials and `apply`, not redesign. It is the first roadmap item.
**Point to:** ADR-001, `docs/roadmap.md`.

### Q: Why is a public repo "all rights reserved"?
**A:** Public visibility is needed for review and for credential-free GitOps pulls. It doesn't grant reuse rights. The LICENSE limits use to evaluation during this interview process. GitHub's ToS still allows viewing and forking on GitHub itself.
**Point to:** `LICENSE`, ADR-002.

### Q: The brief says "black box, do not rewrite". Why is there application code in the repo?
**A:** The brief describes the app but doesn't supply an image, so something has to run. The stand-in implements only the contract: port 8080, the three endpoints, a Redis-queue worker and startup migrations. Every result produced with it is labelled "stand-in". It proves the platform mechanisms (probes, draining, canaries, scaling, job accounting), not the real app's performance.
**Follow-ups:** "What does it assume about the real app?" That it drains on SIGTERM, takes an advisory lock when migrating, can be given a separate migration URL, puts timestamps on jobs, and that jobs are idempotent. Each assumption has a mitigation in the README.
**Point to:** `app/code-review.md`, ADR-005.

### Q: Why Go for the stand-in?
**A:** Resource budget. About 33 API pods plus about 60 workers have to fit in a ~9.7 GB Docker VM. A Go pod idles at around 15 MB and starts in milliseconds, which also shortens scale-up. The distroless image gives Trivy almost nothing to flag. Python would have been easier to read but would cost about 4× the memory per pod.
**Point to:** ADR-005.

## 1. Cloud-agnostic infrastructure as code

### Q: Where exactly is the boundary between "provider" and "platform"?
**A:** It's the provider contract in ADR-003. A provider must hand over:
- a cluster;
- per stack: Postgres, a PgBouncer endpoint and Valkey;
- a secrets manager with three well-known keys per stack;
- a locked remote state backend.

Everything above that (Argo CD, Traefik, Rollouts, KEDA, the app chart) only consumes those names. On kind the contract is met by CloudNativePG, Valkey and OpenBao; on AWS by RDS, ElastiCache and Secrets Manager.
**Follow-ups:** "What leaks through?" LB annotations, IAM, node autoscaling, backup mechanics and the state backend type (`docs/non-portable.md`).
**Point to:** `infra/code-review.md`, ADR-003.

### Q: Why not Crossplane, so everything is Kubernetes-native?
**A:** Crossplane needs a cluster before it can create one, which is a bootstrap problem. It also adds a control plane to run and debug. Terraform is the common denominator interviewers and operators know, and the contract keeps it swappable.
**Point to:** ADR-003.

## 2. Full automation

### Q: How do you run the same tools on a Windows laptop and in Linux CI?
**A:** Every tool is pinned in `config/versions.env`. Locally, `scripts/lib/tools.sh` runs the pinned container when the binary isn't installed, so versions match CI exactly. Line endings are forced to LF and checked in CI, because CRLF silently breaks bash, YAML and Terraform.
**Point to:** ADR-021, `scripts/lib/code-review.md`.

### Q: Where is Terraform state, and how is it locked?
**A:**
- **Locally:** a dedicated Postgres container, through Terraform's `pg` backend. Each root module has its own schema, and Postgres advisory locks stop two applies from racing. The connection string sits in a git-ignored file, never in code.
- **On AWS:** an S3 bucket with versioning and KMS encryption, using S3's native lockfile, so no DynamoDB table is needed since Terraform 1.10/1.11.

**Follow-ups:** "Prove it's remote." `select name from local_10_cluster.states` returns the state row, and there's no `terraform.tfstate` in the repo.
**Point to:** ADR-004, `infra/live/local/code-review.md`.

### Q: What's the chicken-and-egg problem with remote state, and how do you solve it?
**A:** The bucket (or database) that holds state has to exist before any root can use it, so whatever creates it can't keep its own state there. The answer is a tiny bootstrap step:
- **AWS:** `infra/bootstrap/aws` uses *local* state to create the S3 bucket and the GitHub OIDC role, once. Its state can then be migrated into the bucket.
- **Locally:** a script starts the state container before Terraform runs.

The same logic is why the Kubernetes backend was rejected: state would live inside the cluster Terraform creates.
**Point to:** ADR-004.

## 3. Multi-stage pipeline

### Q: How can the pipeline commit to a protected `main`?
**A:** The ruleset has two bypass actors: repo admins, and a write-enabled deploy key held only by the release workflow. `GITHUB_TOKEN` can't bypass rulesets, and requiring a human PR per promotion would defeat automated ring rollout.
**Follow-ups:** "Isn't a write deploy key risky?" It's scoped to one repo, stored as an Actions secret, used only in promote jobs, and every commit it makes is a one-line release-file change visible in history.
**Point to:** ADR-020.

## 4. Deployment strategy
*(added in later steps)*

## 5. Zero downtime

### Q: What happens to a job when a worker is killed mid-job?
**A:** There are two cases.
- **Graceful** (rollout, KEDA scale-in, drain): SIGTERM makes the worker stop claiming and finish the job in hand. The pod has 90 s of grace against a 60 s maximum job, so nothing is lost or duplicated.
- **Ungraceful** (OOM, node loss, SIGKILL): the job is still in `jobs:processing:<pod>`, because claims are atomic moves, not pops. The pod's heartbeat key expires after 30 s, and a peer's reaper moves the job back to the head of the queue. The job is late, not lost.

**Follow-ups:**
- "What if a worker is alive but its heartbeat stalls?" Three missed beats (30 s) is the threshold. The worst case is a duplicate run, which is why jobs must be idempotent.
- "Why does the heartbeat keep running after SIGTERM?" Otherwise a peer would reap the job the stopping worker is still finishing.

**Point to:** `app/internal/worker/code-review.md`, ADR-006.

### Q: Is job processing exactly-once?
**A:** No, it's at-least-once, by design. A worker that finishes a job but dies before acknowledging it will have that job re-run. Exactly-once would need a dedupe store keyed by job id and transactional side effects. The honest platform answer is "make jobs idempotent". That is listed as an assumption about the black box.
**Point to:** ADR-006.

### Q: How do you prove no jobs were dropped during the load test?
**A:** Three counters are updated atomically with each queue operation: `enqueued_total`, `done_total` and `failed_total`. After the queue drains, `enqueued = done + failed` must hold. A unit test asserts it with 3 workers and malformed jobs, and the 15x evidence run checks it on the real platform.
**Point to:** `TestAccountingInvariant`, `evidence/03-load-15x/`.

## 6. Autoscaling and capacity

### Q: 20,000 jobs per hour: baseline or peak? How many workers?
**A:** I assumed peak: λ = 5.56 jobs/s. With a 10 s mean job, Little's law gives L = λ × W ≈ 56 concurrent workers. Sizing uses the mean; the 60 s maximum sets the 90 s shutdown grace period so scale-in never kills a job. If it's the baseline, peak is ~83 jobs/s and ~830 workers, and capacity.md shows that case.
**Follow-ups:** "Why not size for 60 s?" That gives ~333 workers, mostly idle. Throughput depends on the mean.
**Point to:** ADR-024, `docs/capacity.md`.

### Q: How do you measure queue *age* when the worker is a black box?
**A:** List length is always available from outside: redis_exporter reads `LLEN`, and that's what KEDA scales on. Age needs a timestamp inside each job. The stand-in puts `enqueued_at` in the payload and exports `queue_oldest_job_age_seconds` by reading the oldest item. For the real app, that's an assumption to confirm. If its payloads have no timestamp, you either add one at the producer or fall back to depth ÷ throughput as an estimated wait.
**Point to:** `app/internal/queue/code-review.md`.

### Q: How does the stand-in model per-pod capacity? Why not burn CPU?
**A:** Each pod has `MAX_INFLIGHT` slots (8). Each request holds a slot for a slept `WORK_LATENCY_MS` (40 ms) plus a DB lookup, so capacity is about 8 / 0.04 ≈ 100–200 req/s depending on DB time. Beyond that, requests *queue*, so latency rises like a real thread pool, and scaling is genuinely required to keep p95 under 400 ms. Burning CPU instead would tie CPU use to pod count, and the laptop would saturate before the platform did.
**Follow-ups:** "So the 70 req/s target is invented?" No. It is 70% of the per-pod capacity *measured* with a k6 step test (Task 16).
**Point to:** `app/internal/httpapi/code-review.md`, ADR-005.

## 7. Multi-deployment and tenancy
*(added in later steps)*

## 8. Operations
*(added in later steps)*

## 9. Cost and plan
*(added in later steps)*

## 10. Deliverables and evidence
*(added in later steps)*

## 11. Uncomfortable questions
*(added in later steps; see spec §14 for the list)*
