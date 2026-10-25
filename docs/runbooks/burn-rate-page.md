# Runbook: error budget burning (`ZdpErrorBudgetBurnPage` / `Ticket` / `ZdpTenantErrorBudgetBurnPage`)

**Label:** DESCRIBED (a procedure, not exercised end to end; the queries run against the local Prometheus).

**Trigger:**
- **Page:** a stack (or one shared tenant) is spending its error budget at ≥ 14.4× over 1 h and 5 min, or ≥ 6× over 6 h and 30 min.
- **Ticket:** ≥ 1× over 3 days.

The `sli` label says which SLO: `availability` (5xx) or `latency_good` (requests over 400 ms). Targets are in `docs/slos.md`.

**User impact:** real and ongoing. At 14.4×, 2% of the month's budget goes every hour.

## 1. Was anything just changed? (2 min) — the most common cause

```bash
ns=app-prod   # the alert's namespace label
git log --oneline -5 -- gitops/releases/ gitops/stacks/ tenants/        # a release or config change?
kubectl -n $ns get rollout api worker -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,STEP:.status.currentStepIndex
kubectl -n $ns get analysisrun --sort-by=.metadata.creationTimestamp | tail -3
```

- **A canary in progress:** abort it, which sends 100% of traffic back to stable:
  ```bash
  kubectl -n $ns patch rollout api --type merge --subresource status -p '{"status":{"abort":true}}'
  ```
  Then follow [canary-aborted.md](canary-aborted.md).
- **A release that has fully promoted in the last hour:** roll back by reverting its release commit. See [rollback-after-migration.md](rollback-after-migration.md) first if it carried a migration.

## 2. Where are the errors or slow requests? (5 min)

In Grafana or Prometheus (the queries are copy-paste ready):

| Question | Query |
|---|---|
| Stable or canary? | `sum by (service) (rate(traefik_service_requests_total{service=~"<ns>-api-.*",code=~"5.."}[5m]))` |
| Saturated? (in flight per pod vs the limit of 8) | `sum(http_inflight_requests{namespace="<ns>",pod=~"api-.*"}) / count(http_inflight_requests{namespace="<ns>",pod=~"api-.*"})` |
| HPA at its maximum? | `kubectl -n <ns> get hpa keda-hpa-api` (replicas = max → capacity, not code) |
| Database waits? | `max(cnpg_pgbouncer_pools_maxwait{namespace="<ns>"})`, plus whether `ZdpDbPoolWaiting` is firing |
| Queue path? | `max(queue_oldest_job_age_seconds{namespace="<ns>"})`, plus whether `ZdpQueueBacklog` is firing |
| Edge itself? | `kubectl -n traefik get pods` (restarts, OOMKilled: evidence 03) |

## 3. Act

| Finding | Action |
|---|---|
| Bad release | Abort or roll back (step 1) |
| Saturated, HPA at max | Raise `api.maxReplicas` in `gitops/stacks/<stack>.yaml` (Argo CD applies it, no release needed); check node capacity (Karpenter `limits.cpu`) |
| Saturated, HPA *not* at max | The scaler is behind: `kubectl -n <ns> describe scaledobject api` for trigger errors (Prometheus unreachable means no scaling); raise `minReplicas` as a stop-gap |
| Database waits | [db-connection-saturation.md](db-connection-saturation.md) |
| Edge restarting | Check Traefik memory against its limit, scale Traefik replicas |
| Only one shared tenant (`ZdpTenant…`) | That tenant's traffic pattern; check its router's 5xx; if it's noisy-neighbouring the shared stack, rate-limit its route or move it to dedicated |

## 4. Verify and follow up

- The short-window burn rate falls first. The alert clears when the 5 min **and** 1 h windows (or 30 min and 6 h) drop below the threshold.
- Note how much budget was spent (`1 - zdp:sli_<sli>:ratio_rate3d`). If it's more than half the month's budget, freeze non-urgent releases (error-budget policy) and write a short post-incident review.
