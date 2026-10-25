# 90-day roadmap

**Label:** DESCRIBED. The order follows the risk: first make the evidence real on the target cloud, then automate the remaining manual steps, then scale out.

## Days 1–30: prove it on AWS, fix what the laptop found

| # | Work | Why | Done when |
|---|---|---|---|
| 1 | **First AWS apply** of the NOT RUN code in a sandbox account: `bootstrap/aws` → `05-network` → `10-cluster` → `20-data` → `30-gitops` | Static validation is not a deploy; the EU guard-rails, Pod Identity and Karpenter have never run | All Argo CD apps Healthy on EKS; the contract test passes against RDS/ElastiCache/Secrets Manager |
| 2 | **The headroom fix** (ADR-013, third revision): a 30 s rate window, 5 s scrape and KEDA poll for the scaling metrics, `rpsPerPod` ≈ 80, `inflightPerPod` 3.5 | The current targets saturate for 30–60 s mid-ramp on any infrastructure (evidence 03) | Render tests updated; the 15x test (item 3) shows no saturation |
| 3 | **15x test on EKS** with the load generator *outside* the cluster (EC2 in another VPC, or k6 Cloud) | The laptop's ceiling (~650–800 req/s) made the full test impossible locally | 150 → 2,250 req/s in ≤ 5 min: 0 failed requests, hold-phase p95 < 400 ms, `enqueued == done` |
| 4 | **Worker scaling on outstanding jobs** (`listLength: 1`, or waiting + in-progress via Prometheus) | `listLength: 5` keeps ~280 jobs waiting at peak, about 50 s of pure queueing (evidence 03) | Oldest-job age at peak < 15 s with the same worker count |
| 5 | **Close the black-box assumptions** with the app team: SIGTERM drain, job idempotency, an older version tolerating a newer schema, an active-requests metric, queue age, response size | The design relies on each of them (architecture doc, risks 2–3) | Each one confirmed, or a mitigation merged |
| 6 | **Kyverno image verification** at admission (cosign keyless, the GitHub OIDC identity regex) | Signing without verification is only half a supply chain | An unsigned image is rejected in every stack namespace (a test proves it) |

## Days 31–60: automate the last manual steps

| # | Work | Why | Done when |
|---|---|---|---|
| 7 | **`tenant-apply.yml`**: Terraform plan on the tenant PR, apply on merge (an environment with a reviewer) | Onboarding a dedicated tenant needs a manual `terraform apply` today | A new dedicated tenant goes from PR merge to Healthy in **< 30 min**, timed and saved as evidence |
| 8 | **`drift.yml`**: a nightly `terraform plan -detailed-exitcode` per root, opening an issue on drift ([runbook](runbooks/drift-detected.md)) | Argo CD self-heals Kubernetes drift; nothing watches the provider layer | Out-of-band changes show up as an issue within 24 h |
| 9 | **Scheduled restore drill** (weekly CronJob running `restore-test.sh`, alerting on `RESTORE FAIL`) and an AWS PITR drill | A backup is only proven by restoring it; today the drill runs by hand | Weekly `RESTORE PASS` in the history; RTO tracked |
| 10 | **Migration safety check in CI**: flag `DROP` / `RENAME` / `NOT NULL` without a default / type changes, and require a two-release plan | Expand/contract is a policy; nothing enforces it before merge | A breaking migration fails CI unless labelled with its contract release |
| 11 | **Per-tenant Grafana dashboards** and a latency SLI for shared tenants | Per-tenant visibility is availability-only today | One dashboard per tenant, from the tenant file |
| 12 | **Edge hardening:** AWS Load Balancer Controller (replacing in-tree annotations), a Traefik HPA, egress allow-listing (trivy AWS-0104) | One Traefik replica was OOM-killed in evidence 03; node egress is wide open | Traefik scales with connections; egress limited to known endpoints |

## Days 61–90: scale out

| # | Work | Why | Done when |
|---|---|---|---|
| 13 | **The change request**: a second dedicated stack on another provider, written as a third `infra/modules/<provider>` set, plus failover | The provider contract exists for exactly this | The new stack passes the same contract test and the same gates; the failover runbook has been rehearsed |
| 14 | **A second region** (`infra/live/aws/us-east-1`) for non-EU tenants such as globex | globex is labelled us-east-1 but simulated locally | ring 2 deploys to its own region; residency policy unchanged |
| 15 | **Database scaling plan**: measure the real query mix at 15x, then read replicas or `r7g.xlarge` as needed | The single Postgres writer is risk 1 | The DB has ≥ 30% headroom at peak in the 15x test |
| 16 | **Game days**: AZ loss during a canary, a node drain at peak, Valkey failover, a GitHub outage during a release | Proves the HA claims, and the "GitHub down" break-glass | Each one run, with findings fixed or ticketed |
| 17 | **Cost commitments** after 60 days of real usage: a Compute Savings Plan, RDS reservations, spot for workers | About −30% on the largest lines (`docs/cost.md`) | Commitments sized to the measured baseline, not the peak |

## Not planned (deliberately)

- **A service mesh:** mTLS between API and pooler isn't required by the brief, and it adds a data-plane hop to every request.
- **Multi-cluster per region:** one regional cluster plus per-tenant namespaces, data services and node pools gives the isolation the tiers need (ADR-017).
