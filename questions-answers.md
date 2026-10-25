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

### Q: Why does every stack have two database URLs?
**A:** Runtime queries go through PgBouncer in transaction mode, which multiplexes hundreds of client connections onto about 40 Postgres backends. Migrations go directly to Postgres. In transaction mode PgBouncer can give each transaction a different backend, so a session-level advisory lock (which Flyway, golang-migrate and Prisma use) can be taken on one backend and "released" on another. You end up with a stuck lock, or two pods migrating at once. A direct URL for migrations avoids that.
**Follow-ups:** "What if the black box accepts only one URL?" Point it at a session-mode pool, or direct, and accept less multiplexing. Or migrate from a pre-sync Job if the app supports a migrate-only mode.
**Point to:** ADR-007, `app/internal/migrate/code-review.md`.

### Q: Why Valkey and not Redis?
**A:** Licensing. Redis moved to source-available licences in 2024; Valkey is the BSD-licensed Linux Foundation fork, compatible with the same protocol and clients. AWS offers ElastiCache for Valkey at about 20% less than Redis OSS. Nothing in the app, KEDA or the exporter had to change.
**Point to:** ADR-008.

### Q: How does a secret get from the secrets manager into a pod?
**A:**
1. Terraform generates the DB password and writes three URLs to `stacks/<stack>/app` in the secrets manager.
2. External Secrets Operator, through a `ClusterSecretStore`, syncs that path into a Kubernetes Secret `app-env` in the stack's namespace.
3. The pods load it with `envFrom`.

Locally the store is OpenBao; on AWS it's Secrets Manager with Pod Identity. Only the store definition differs; the app chart is identical on both.
**Follow-ups:** "Isn't the secret in Terraform state?" Yes, Terraform created it, so state is treated as sensitive: a credentialed database locally, and an encrypted, access-controlled bucket on AWS. "Rotation?" Change it in the manager; ESO's refresh interval rolls it into the Secret, and a pod restart (or a reloader) picks it up.
**Point to:** ADR-009.

### Q: What would change to run this on AWS tomorrow?
**A:** No redesign. The steps:
1. Apply `infra/bootstrap/aws` once with an admin identity. That creates the state bucket, KMS key and the GitHub OIDC deploy role.
2. Init each root with `-backend-config=bucket=<output>`.
3. Apply 05 → 10 → 20 → 30 from a runner inside the VPC, because the EKS endpoint is private.

Argo CD then syncs `gitops/clusters/aws-eu-central-1`, which uses the same chart, release files and gates. What I'd expect to fix on first contact:
- IAM gaps;
- engine-version availability (I assumed PostgreSQL 18 and Valkey 8.1);
- a TLS TriggerAuthentication for KEDA, because ElastiCache uses in-transit encryption;
- DNS and TLS certificates for real hostnames.

None of that is in the platform or app layers.
**Point to:** `infra/live/aws/code-review.md`, `evidence/08-aws-static/README.md`.

### Q: Why EKS Pod Identity over IRSA?
**A:** Both give pods short-lived AWS credentials. IRSA needs an OIDC provider plus a trust policy per role that names the namespace and service account, and annotations on the service account. Pod Identity is one association resource (cluster + namespace + service account → role), managed in Terraform, with no per-role OIDC conditions. ESO, Karpenter and the EBS CSI driver all use it here.
**Point to:** `infra/modules/aws/eks/code-review.md`, ADR-022.

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

### Q: What does CI check on a pull request?
**A:** Six required jobs:
- **go-test:** unit tests, plus integration tests against real Postgres and Valkey containers.
- **chart-test:** 24 render assertions on the one chart, schema validation including CRDs, and promtool parsing the SLO PromQL.
- **policy-test:** every tenant file against the onboarding policy, which includes EU residency.
- **terraform-validate:** every root, local *and* AWS, plus tflint.
- **iac-scan:** Trivy misconfiguration checks on Terraform, charts and the Dockerfile.
- **shell-lint:** shellcheck, an LF line-ending check, and the promotion-script race test.

All actions are pinned by commit SHA. I showed a PR adding an EU tenant in us-east-1 being blocked by policy-test.
**Follow-ups:** "Did CI ever catch something the laptop didn't?" Yes. promtool passed on Windows but failed on Linux because of a 0700 temp directory and a non-root container, so running on two platforms paid off.
**Point to:** `.github/code-review.md`, `evidence/00-ci/README.md`.

### Q: "Build once." Prove production runs the exact artifact you tested in dev.
**A:**
1. The image is built once and from then on referenced only by its sha256 digest. The chart's schema refuses tags.
2. Every release file pins that digest, together with a chart version.
3. The gate checks that each Rollout's pod template ends in `@<that digest>` before passing.
4. It's signed keylessly. `cosign verify --certificate-identity-regexp '<repo>/.github/workflows/release.yml@refs/heads/main'` proves *this workflow on main* built it, and the SBOM is attached as a signed attestation.

Promotion copies the digest file to file. There's no rebuild and no retag.
**Follow-ups:** "Why promote the chart too?" Otherwise a change to probes or analysis rules would hit every stack at once and skip the gates.
**Point to:** ADR-014, `.github/workflows/release.yml`.

### Q: Why a self-hosted runner? Isn't that dangerous on a public repo?
**A:** The gates need the laptop cluster's Prometheus and Argo CD, and GitHub-hosted runners can't reach them without exposing them publicly. A runner that only dials out is safer. Three mitigations:
- Fork PR workflows require approval.
- Only the release workflow, on push to main or manual dispatch, targets that runner label.
- The runner's Kubernetes identity is read-only. The bring-up script proves it can't delete anything.

In the cloud this becomes Actions Runner Controller inside each cluster.
**Point to:** ADR-015, `scripts/runner/code-review.md`.

### Q: What happens when GitHub is down?
**A:** Nothing new deploys: no builds, no promotions, and no Git for Argo CD to pull. Running stacks are unaffected. Argo CD keeps the last-synced state, and KEDA and Rollouts are in-cluster. Images are already on the nodes; a node replacement would need GHCR, which is why a regional pull-through cache (ECR) is on the roadmap.
**Point to:** ADR-010, ADR-015.

### Q: How can the pipeline commit to a protected `main`?
**A:** The ruleset has two bypass actors: repo admins, and a write-enabled deploy key held only by the release workflow. `GITHUB_TOKEN` can't bypass rulesets, and requiring a human PR per promotion would defeat automated ring rollout.
**Follow-ups:** "Isn't a write deploy key risky?" It's scoped to one repo, stored as an Actions secret, used only in promote jobs, and every commit it makes is a one-line release-file change visible in history.
**Point to:** ADR-020.

## 4. Deployment strategy

### Q: GitOps pull vs pipeline push: what do you actually gain?
**A:** Three things:
- **No cluster credentials in CI.** The pipeline only commits to Git, and Argo CD inside the cluster pulls.
- **Clusters don't need to be reachable from CI.** This one is on a laptop; in production it would be a private EKS endpoint.
- **Continuous drift correction.** Self-heal reverts a manual `kubectl edit` within a minute, instead of it surviving until the next deploy.

The cost is that the pipeline can't directly "see" the deployment. My gates read Rollout status and Prometheus with a read-only identity.
**Follow-ups:** "Why Argo CD over Flux?" Both are fine. Argo's UI and native Argo Rollouts integration (abort/promote, rollout health) matter for operating canaries, and ApplicationSets fan out tenants from files.
**Point to:** ADR-010.

### Q: Why canary and not blue/green for the API?
**A:** Blue/green needs a second full fleet during cutover. At peak that's about 40 extra pods, and the cutover is all-or-nothing. It also doesn't protect the database, because both colours share one schema. A canary exposes 10% → 25% → 50% of traffic, checks edge metrics at each step, and aborts automatically. The blast radius of a bad release is about 10–25% of requests for 1–2 minutes, which I measured.
**Follow-ups:** "What exactly triggers the abort?" Two failed 1-minute measurements of canary success rate < 99% or p95 > 400 ms, read from Traefik for the canary Service only. Fewer than 20 requests per minute counts as inconclusive, which pauses the rollout and never passes it.
**Point to:** ADR-011, `charts/app/templates/analysis-api.yaml`.

### Q: How does the worker get a canary when it has no traffic?
**A:** It uses an Argo Rollouts canary without traffic routing, so the "weight" is the share of replicas: a rolling update that can stop and roll back on its own. The analysis isolates canary pods by their pod-template hash and checks three things: the job failure ratio, the age of the oldest queued job, and restarts. A plain Deployment would roll the same way but can't abort on a metric.
**Point to:** ADR-012.

### Q: Why gate on Traefik metrics and not the app's?
**A:** The app is a black box. I don't know its metric names, and every tenant's app might expose different ones. The ingress sees every request, with status code and latency, for every service, in one consistent format. The same signal drives canary gates, autoscaling and SLOs.
**Point to:** ADR-011, ADR-023.

### Q: Why is there synthetic traffic? Doesn't it distort your SLIs?
**A:** Argo Rollouts treats "no data" as inconclusive and pauses the rollout. Dev, staging and the tenant stacks get no user traffic locally, so without it every canary would stall. A tiny generator sends 10 req/s per stack through the real ingress. Requests carry `X-Synthetic: 1`, so user-facing dashboards can exclude them, while canary analysis deliberately includes them. It also works as a black-box probe: if synthetic requests fail, the stack is broken whether or not anyone noticed.
**Follow-ups:** "Is 1 req/s to a 10% canary enough?" It's enough to catch a gross failure (the demo bug fails 30% of requests) within a minute, not a subtle regression. That's what production traffic, longer steps and a minimum-request-count guard are for.
**Point to:** ADR-016, `app/cmd/synthetic/code-review.md`.

### Q: How is drift handled?
**A:** At two layers:
- **Cluster objects:** Argo CD auto-sync with `selfHeal` and `prune`. Manual changes are reverted, and objects deleted from Git are deleted from the cluster.
- **Infrastructure** (databases, secrets, cluster): `terraform plan -detailed-exitcode` per root, where exit code 2 means drift. A scheduled job turns that into a GitHub issue.

Running `plan` after the provider layer was applied returns 0.
**Point to:** ADR-004, ADR-010.

## 5. Zero downtime

### Q: What happens to a job when a worker is killed mid-job?
**A:** There are two cases.
- **Graceful** (rollout, KEDA scale-in, drain): SIGTERM makes the worker stop claiming and finish the job in hand. The pod has 90 s of grace against a 60 s maximum job, so nothing is lost or duplicated.
- **Ungraceful** (OOM, node loss, SIGKILL): the job is still in `jobs:processing:<pod>`, because claims are atomic moves, not pops. The pod's heartbeat key expires after 30 s, and a peer's reaper moves the job back to the head of the queue. The job is late, not lost.

**Follow-ups:**
- "What if a worker is alive but its heartbeat stalls?" Three missed beats (30 s) is the threshold. The worst case is a duplicate run, which is why jobs must be idempotent.
- "Why does the heartbeat keep running after SIGTERM?" Otherwise a peer would reap the job the stopping worker is still finishing.

**Point to:** `app/internal/worker/code-review.md`, ADR-006.

### Q: Walk me through a zero-downtime API pod shutdown.
**A:**
1. Kubernetes sends the pod SIGTERM and starts removing it from Service endpoints.
2. In parallel, `preStop: sleep 5` keeps the container serving while Traefik notices the endpoint change. This is the window where requests are still routed to the pod.
3. Then the app sees SIGTERM. It fails `/readyz`, waits its own 5 s, and calls `http.Server.Shutdown`, which finishes in-flight requests (up to 20 s).
4. The 30 s grace period covers all of it.

A PDB limits voluntary disruptions to one pod at a time, and topology spread keeps replicas on different nodes.
**Follow-ups:** "Why a native sleep hook?" The image is distroless, with no shell, so `exec: sleep` is impossible. Kubernetes 1.30+ has `preStop.sleep`.
**Point to:** `charts/app/templates/api-rollout.yaml`, `app/cmd/api/code-review.md`.

### Q: What if the real black-box app doesn't drain on SIGTERM?
**A:** Then the platform limits the damage, but it can't prevent it.
- **API:** `preStop` still holds the pod for 5 s while it leaves the load balancer. After that, a non-draining app drops whatever is in flight when it exits, typically a handful of requests, which clients should retry.
- **Worker:** a non-draining worker is killed at the 90 s grace period. Its job is still in its processing list, and the reaper returns it to the queue within about 30 s. The job is late and runs twice, never lost. That's why idempotency is listed as an assumption.

**Follow-ups:** "So what do you ask the app team for?" Three things: SIGTERM handling, idempotent jobs, and ideally a migrate-only mode.
**Point to:** ADR-006, ADR-012.

### Q: You rolled back the image, but the migration already ran. Now what?
**A:** It depends on what the migration did.
- **Expand migration** (added a nullable column): nothing to do. The old version runs fine on the expanded schema, because every release must be N-1 compatible. My bad-release demo shows exactly this.
- **Breaking migration shipped by mistake:** fix forward first, because it loses no data. As a last resort, restore the dump taken automatically by the PreSync hook just before that sync, or use point-in-time recovery on AWS. That restore has an explicit data-loss window.

No down-migrations: they're rarely tested and can't restore dropped data.
**Follow-ups:** "How do you stop a breaking migration shipping?" Make expand/contract part of code review, and run migrations against a prod-like copy in staging. The platform makes mistakes recoverable, not impossible.
**Point to:** ADR-018, `docs/runbooks/rollback-after-migration.md`.

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

### Q: Why KEDA on request rate instead of a CPU-based HPA?
**A:** The API is I/O-bound. It waits on the database, so pods hit their concurrency limit and latency climbs long before CPU does. CPU lags the actual problem. KEDA scales on Traefik's request rate divided by a per-pod target (70% of measured capacity), with CPU as a safety net. Scale-up has no stabilization and can double every 15 s. Scale-down waits 5 minutes and sheds at most 20% per minute, so we don't flap.
**Follow-ups:** "How long to reach 15x?" In-cluster, about 10 s polling plus 15 s per HPA step, doubling each step, plus a few seconds of pod start: 1–2 minutes. On AWS, add about 60–90 s for Karpenter nodes, hidden by over-provisioning pods.
**Point to:** ADR-013, `charts/app/templates/scaledobject-api.yaml`.

### Q: Your evidence shows prod scaling to 14 pods for 160 req/s. Isn't that a bug?
**A:** Yes, and the evidence run is what found it. The HPA events said "cpu resource utilization above target", not RPS. The API's CPU request was 50m and the safety-net trigger 70% of it. The stand-in uses about 1.4 millicores per req/s, so CPU crossed the line at about 25 req/s per pod, five times below the RPS target of 126. The "safety net" was really the primary trigger, and the fleet sat at about 7% utilisation. The fix is a rule, not a tweak: a safety-net trigger must fire *after* the primary one and *before* saturation. A 200m request at 100% fires at about 143 req/s per pod, between the target (126) and capacity (~180). A render test now enforces that inequality, so a future resize can't quietly reintroduce the problem.
**Follow-ups:**
- "Why not just delete the CPU trigger?" It covers the case where the RPS signal is missing (a Prometheus outage) or a release makes each request heavier.
- "And the latency bump during that scale-up?" p95 was about 1 s for roughly 45 s, with 0 errors. Every pod slowed down, including warm ones, while node CPU stayed at 54% and nothing was throttled. That points at shared database connection setup, but there were no pool metrics to prove it. So the PgBouncer and Postgres exporters are now scraped too.

**Point to:** ADR-013 (revised), `evidence/01-deploy-under-load/README.md`.

### Q: Your first 15x run failed. Why, and what changed?
**A:** The autoscaler was watching the wrong thing during an overload. It scaled on *completed* requests per second, and that number can't exceed what the pods can serve. As offered load climbed past capacity, the signal flattened at about 290 req/s while 3 pods held 242 requests in flight (limit 8 each), so the HPA stayed at 3. Latency rose, k6 opened thousands of connections on the same VM, and CPU starvation then took KEDA and Traefik down with it: 55.7% of requests failed. The fix is a second trigger on **in-flight requests per pod**. By Little's law in-flight = arrival rate × latency, so it grows with the overload instead of saturating. The HPA takes the max of request rate (steady sizing), in-flight (saturation) and CPU (safety net). Jobs were fine throughout: 2,327 enqueued, 2,327 done.
**Follow-ups:**
- "Wouldn't that happen on AWS too?" Yes. The laptop only made it collapse faster. A capped signal under-reports demand on any cloud.
- "What if the real app has no in-flight metric?" Use its OpenTelemetry active-requests gauge if it has one. Otherwise Traefik's entrypoint open connections, which are noisier. Or put the concurrency limit at the edge and scale on queue time there.

**Point to:** ADR-013 (second revision), `evidence/03-load-15x/README.md`.

### Q: Doesn't scaling workers down kill jobs?
**A:** No. KEDA scale-in sends SIGTERM like any other stop: the worker stops claiming and finishes its current job within the 90 s grace period. If it's killed anyway, the reaper requeues the job. Scale-down is also damped (a 5-minute window, at most −20% per minute), so a brief dip in the queue doesn't trigger a mass stop.
**Point to:** ADR-006, ADR-013.

### Q: How do you measure queue *age* when the worker is a black box?
**A:** List length is always available from outside: redis_exporter reads `LLEN`, and that's what KEDA scales on. Age needs a timestamp inside each job. The stand-in puts `enqueued_at` in the payload and exports `queue_oldest_job_age_seconds` by reading the oldest item. For the real app, that's an assumption to confirm. If its payloads have no timestamp, you either add one at the producer or fall back to depth ÷ throughput as an estimated wait.
**Point to:** `app/internal/queue/code-review.md`.

### Q: How does the stand-in model per-pod capacity? Why not burn CPU?
**A:** Each pod has `MAX_INFLIGHT` slots (8). Each request holds a slot for a slept `WORK_LATENCY_MS` (40 ms) plus a DB lookup, so capacity is about 8 / 0.04 ≈ 100–200 req/s depending on DB time. Beyond that, requests *queue*, so latency rises like a real thread pool, and scaling is genuinely required to keep p95 under 400 ms. Burning CPU instead would tie CPU use to pod count, and the laptop would saturate before the platform did.
**Follow-ups:** "So the 70 req/s target is invented?" No. It is 70% of the per-pod capacity *measured* with a k6 step test (Task 16).
**Point to:** `app/internal/httpapi/code-review.md`, ADR-005.

## 7. Multi-deployment and tenancy

### Q: How is EU residency *enforced*, not just documented?
**A:** At several layers:
- **Merge time:** a Rego policy runs in CI on every tenant file and blocks the merge if a tenant marked `residency: eu` names a region outside the EU.
- **Region list:** member states only. London (`eu-west-2`) and Zurich (`eu-central-2`) start with "eu-" but aren't in the EU, and the policy has tests proving both are rejected.
- **Apply time:** Terraform takes each tenant's region from that same file, so a tenant can't be validated against one region and deployed to another.
- **On AWS:** backups and snapshot copies stay inside the residency zone, and an SCP denies non-EU regions to EU accounts. These are designed but not run.

**Point to:** `policy/code-review.md`, ADR-017.

### Q: How do you get per-tenant visibility on a shared black-box app?
**A:** At the ingress. Each shared tenant gets its own host, so its own Traefik router, and Traefik labels metrics per router. That gives per-tenant request rate, error rate and latency without the app knowing tenants exist. Dedicated tenants have their own namespace, so every metric is per tenant by definition.
**Point to:** `charts/tenant-route/code-review.md`.

### Q: Dedicated tenant: namespace or cluster?
**A:** By default, a dedicated namespace plus dedicated databases and cache (plus a tainted node pool on AWS) on a shared regional cluster. A cluster per tenant gives the strongest isolation but adds a $73/month control plane plus system nodes, a separate upgrade cycle and a separate Argo CD per tenant. Under the $9k budget that caps the fleet at a few tenants. I'd offer cluster-per-tenant only when a contract requires it.
**Point to:** ADR-017, `docs/cost.md`.

## 8. Operations

### Q: Explain your SLO alerting.
**A:** I use two SLIs per stack, both measured at the edge: availability (non-5xx share) and latency (share of requests within ≤ 400 ms). The error budget is 0.1% for shared and 0.05% for dedicated: 43 and 22 minutes a month. I page on a 14.4× burn over 1h AND 5m (2% of the month's budget gone in an hour), or 6× over 6h AND 30m. A 1× burn over 3 days opens a ticket. Requiring both windows makes the page fire quickly and clear quickly once the problem is fixed.
**Follow-ups:**
- "Why not 'error rate > 1%'?" A static threshold isn't tied to the budget. It pages on blips that don't matter and misses slow burns that do.
- "Per-tenant?" Every rule is labelled with stack and tier, and shared tenants get per-host router metrics.

**Point to:** ADR-023, `charts/app/templates/prometheusrule-slo.yaml`.

## 9. Cost and plan
*(added in later steps)*

## 10. Deliverables and evidence
*(added in later steps)*

## 11. Uncomfortable questions
*(added in later steps; see spec §14 for the list)*
