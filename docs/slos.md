# SLOs, error budgets and alerts

**Label:** RUN-LOCAL (stand-in). The rules render from `charts/app/templates/prometheusrule-slo.yaml`, `backup.yaml` and `charts/tenant-route`. Decision record: ADR-023.

## SLIs

Measured at the **edge** (Traefik), so they need nothing from the black box and are the same for every tenant.

| SLI | Definition (per stack) | Source |
|---|---|---|
| **Availability** | non-5xx requests / all requests | `traefik_service_requests_total{service=~"<ns>-api-(stable\|canary)-.*"}` |
| **Latency** | requests answered within 400 ms / all requests (exact: Traefik has a 0.4 s bucket) | `traefik_service_request_duration_seconds_bucket{le="0.4"}` |
| **Shared tenant availability** | the same ratio, from **that tenant's own router** on the shared stack | `traefik_router_requests_total{router=~"app-prod-tenant-<name>-.*"}` |

The recording rules `zdp:sli_<sli>:ratio_rate<window>` cover 5m, 30m, 1h, 6h and 3d, labelled with `namespace`, `stack` and `tier`.

## Targets and budgets (30-day window)

| Stack type | Availability SLO | Availability budget | Latency SLO | Latency budget |
|---|---|---|---|---|
| Shared prod, non-prod, shared tenants | **99.9%** | 43.2 min of full outage, or 0.1% of requests | **95% of requests ≤ 400 ms** (the brief's p95) | 5% of requests slower than 400 ms |
| Dedicated tenants (`slo: "99.95"` in the tenant file) | **99.95%** | 21.6 min, or 0.05% of requests | 95% ≤ 400 ms | 5% |

The availability target comes from `stack.slo`. The latency target is `slo.latencyObjective` (0.95). Until 2026-10-26 the latency alerts reused the availability objective, which in effect demanded p99.9 < 400 ms and would have paged on slow tails the brief allows (ADR-023 revised).

## Alerts

| Alert | Fires when | Severity | Runbook |
|---|---|---|---|
| `ZdpErrorBudgetBurnPage` (per SLI) | burn > **14.4×** over 1h AND 5m (2% of the monthly budget in an hour), or > **6×** over 6h AND 30m | page | [burn-rate-page](runbooks/burn-rate-page.md) |
| `ZdpErrorBudgetBurnTicket` (per SLI) | burn > 1× over 3 days (on course to spend the whole budget) | ticket | [burn-rate-page](runbooks/burn-rate-page.md) |
| `ZdpTenantErrorBudgetBurnPage` | the same multi-window logic on one shared tenant's router | page | [burn-rate-page](runbooks/burn-rate-page.md) |
| `ZdpQueueBacklog` | oldest queued job > 300 s (5× the longest job) for 5 min | page | [queue-backlog](runbooks/queue-backlog.md) |
| `ZdpDbPoolWaiting` (local CNPG only) | a client waited ≥ 1 s for a PgBouncer server connection, sustained for 5 min | ticket | [db-connection-saturation](runbooks/db-connection-saturation.md) |
| `ZdpBackupStale` (local `pgdump` mode only; on AWS, RDS backups are managed and AWS Backup / EventBridge would alert, DESCRIBED) | no successful hourly backup for 2 h, or the CronJob is older than 2 h and has never succeeded | ticket | [backup-stale](runbooks/backup-stale.md) |

**Why burn rates and not thresholds.** A static "5xx > 1% for 5 min" alert pages on blips that don't threaten the SLO and misses slow burns that do. Two windows give fast detection (the short window) and fast reset after recovery (the long one).

**Why the cause alerts aren't budget-based.** Queue age and pool waits are causes, not user-visible symptoms. They exist to point at the broken part early. When users feel the problem, a burn-rate alert pages anyway.

## Where the SLOs are also enforced

- **Canary analysis:** each canary step needs success ≥ 99% and p95 ≤ 400 ms on the canary's own traffic, with at least 20 requests per minute. Too little data is inconclusive, never a pass.
- **Promotion gate:** after a 3-minute soak, the stack's 5xx ratio must be < 0.5%, p95 < 400 ms, and the oldest job younger than 120 s. Otherwise the fleet halts.

## Known limitations

- Locally, Prometheus keeps 12 h, so the 3-day windows compute over whatever data exists.
- Synthetic traffic (ADR-016) is included in the local SLIs. Production would exclude it with Traefik's `synthetic` header label.
- A shared tenant has an availability SLI only. Router latency histograms exist but aren't wired into a latency SLO yet (roadmap).
- On AWS, `ZdpDbPoolWaiting` is replaced by CloudWatch `DatabaseConnections` and RDS Performance Insights (DESCRIBED). `ZdpQueueBacklog` assumes the real worker exposes queue age (open question). If it doesn't, list length from the Valkey exporter divided by throughput is the fallback.
