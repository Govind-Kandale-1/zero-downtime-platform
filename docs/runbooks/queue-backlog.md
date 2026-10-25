# Runbook: queue backlog (`ZdpQueueBacklog`)

**Label:** DESCRIBED (a procedure, not exercised end to end).

**Trigger:** page. The oldest queued job has waited more than 300 s (5× the longest job) for 5 minutes.

**User impact:** jobs finish minutes late. **Nothing is lost** at this point: the queue is durable (Valkey AOF) and accepted jobs stay queued until processed (evidence 03: enqueued = done in every load test). The risk grows if Valkey fills up: with `noeviction`, new enqueues then fail with 503.

## 1. Are workers running and scaling? (3 min)

```bash
ns=app-prod
kubectl -n $ns get hpa keda-hpa-worker                      # replicas vs max (60 in prod)
kubectl -n $ns get rollout worker -o jsonpath='{.status.readyReplicas}/{.status.replicas}{"\n"}'
kubectl -n $ns get pods -l app.kubernetes.io/name=worker | grep -v Running   # crash loops, Pending
kubectl -n $ns describe scaledobject worker | grep -A5 Conditions             # scaler errors (Valkey unreachable)
kubectl -n $ns exec valkey-0 -c valkey -- sh -c 'valkey-cli LLEN jobs; valkey-cli GET jobs:failed_total; valkey-cli INFO memory | grep used_memory_human'
```

| What you see | Cause | Action |
|---|---|---|
| Workers at max, all busy, queue growing | Arrivals > capacity: at 10 s mean, 60 workers ≈ 6 jobs/s | Raise `worker.maxReplicas` in `gitops/stacks/<stack>.yaml`; check node capacity |
| Workers far below max, queue growing | The scaler isn't acting (ScaledObject condition `Ready=False`, Valkey or KEDA down) | Fix the scaler; meanwhile set `worker.minReplicas` higher in the stack file |
| Workers crash-looping | A bad release (a worker canary normally catches this) or a broken dependency | `kubectl -n $ns logs -l app.kubernetes.io/name=worker --previous`; roll back the release |
| Pods `Pending` | No node capacity | Karpenter events (`kubectl get nodeclaims`); `limits.cpu` on the NodePool |
| `jobs:failed_total` rising, the same jobs coming back | Poison jobs: the reaper requeues jobs whose worker died mid-job | Find the job ids in the worker logs; remove poison jobs from `jobs:processing:*` by hand after recording them |
| Valkey `used_memory` near `maxmemory` | The queue is growing faster than it drains | Act on capacity *now*: at the limit, `POST /api/jobs` returns 503 |

## 2. Verify

- `max(queue_oldest_job_age_seconds{namespace="<ns>"})` falls below 120 s (the promotion gate's limit), and the alert clears after 5 minutes.
- Afterwards: `jobs:enqueued_total == jobs:done_total + jobs:failed_total` once the queue is empty.

**Known design debt:** the worker trigger's `listLength: 5` keeps about 5 × workers jobs waiting at peak (about 50 s of queueing). Roadmap item 4 fixes it.
