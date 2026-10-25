# charts/app/templates/ — code review

| Template | Objects | Key behaviour |
|---|---|---|
| `_helpers.tpl` | — | Labels (`zdp/stack`, `zdp/tier`, `zdp/region`); `repository@digest` image ref; size presets; default host `<stack>.localtest.me`; SLO objective (`"99.95"` → `0.9995`); Traefik service regexes; the restricted securityContext |
| `_backup.tpl` | — | The pg_dump script and pod spec shared by the CronJob and the PreSync Job |
| `api-rollout.yaml` | `Rollout api` | **Canary via Traefik** (`stableService`, `canaryService`, `weightedTraefikServiceName: api`). Steps 10 → 25 → 50 % with pauses. **Background analysis** `api-canary` starts after the first weight. Probes: startup `/healthz` (30×2 s, because migrations run at boot), readiness `/readyz`, liveness `/healthz`. **`preStop: sleep 5`** (native sleep hook, since distroless has no shell). Grace 30 s. Topology spread across nodes. No `replicas`: KEDA owns it. |
| `api-services.yaml` | `Service api-stable`, `api-canary` | Rollouts injects `rollouts-pod-template-hash` into each selector |
| `traefikservice.yaml` | `TraefikService api` | Weighted 100/0. **Rollouts rewrites the weights during a canary**, and Argo CD ignores that drift. |
| `ingressroute.yaml` | `IngressRoute api` | One `Host()` rule per host → the weighted service |
| `analysis-api.yaml` | `AnalysisTemplate api-canary` | Three metrics on the **canary Service's edge metrics**: request count ≥ 20/min (else inconclusive), success rate ≥ 0.99, p95 ≤ 0.4 s. Each metric names its success *and* failure conditions, so NaN or no data leads to **pause, not pass**. `failureLimit: 1`. |
| `analysis-worker.yaml` | `AnalysisTemplate worker-canary` | Canary job failure ratio ≤ 2% (isolated by **pod-template hash**; no jobs means no failures observed), oldest queued job < 120 s, zero restarts of canary worker pods (kube-state-metrics joined on the hash label) |
| `worker-rollout.yaml` | `Rollout worker` | **Canary without traffic routing**, so the weight is a share of replicas: a gated rolling update with automatic abort. `maxSurge 25%`, `maxUnavailable 0`. **Grace 90 s.** Liveness on `:9090/healthz`. |
| `scaledobject-api.yaml` | `ScaledObject api` → Rollout | Prometheus trigger `sum(rate(traefik_service_requests_total{service=~"<ns>-api-(stable\|canary)-.*"}[1m]))` / `rpsPerPod`, plus CPU 70% as a safety net. Scale up: no stabilization, `max(+100%, +8 pods)` per 15 s. Scale down: 300 s window, −20% per minute. |
| `scaledobject-worker.yaml` | `ScaledObject worker` → Rollout | KEDA `redis` trigger on `LLEN jobs` / `listLength` (5), at `valkey.<ns>.svc:6379` |
| `pdb.yaml` | `PDB api`, `worker` | `maxUnavailable: 1` |
| `externalsecret.yaml` | `ExternalSecret app-env` | `platform-secrets` → `stacks/<stack>/app` → Secret `app-env`, refreshed every minute |
| `serviceaccount.yaml` | `ServiceAccount app` | No token mounted, since the app never calls the Kubernetes API |
| `monitoring.yaml` | `PodMonitor api`, `worker`; `ServiceMonitor valkey` | PodMonitors, so stable and canary Services can't double-count. They copy `rollouts-pod-template-hash` onto every series. The Valkey exporter monitor is local-only (`valkeyMetrics`). |
| `prometheusrule-slo.yaml` | `PrometheusRule slo` | Recording rules `zdp:sli_availability:ratio_rate{5m,30m,1h,6h,3d}` and `zdp:sli_latency_good:ratio_rate*` (from `le="0.4"`). Alerts `ZdpErrorBudgetBurnPage` (14.4× over 1h & 5m, or 6× over 6h & 30m) and `ZdpErrorBudgetBurnTicket` (1× over 3d), for both SLIs, labelled with `stack`, `tier`, `objective` and a runbook link. |
| `networkpolicy.yaml` | 4 × `NetworkPolicy` | Default-deny ingress for the whole namespace (including Terraform-created Postgres and Valkey), then allows: same namespace; Traefik → API:8080; monitoring, cnpg-system and keda namespaces |
| `backup.yaml` | `PVC backups`, `CronJob backup`, `Job presync-backup` | The **PVC is itself a PreSync hook (weight -1)**. Hooks run before ordinary resources, so on the first install the Job's volume claim wouldn't exist yet and its pod would stay Pending forever. The first real release found this. Hourly `pg_dump -Fc` with a `.counts` file (rows + md5) and retention of 24. **A PreSync hook dumps before every sync.** It exits 0 when the Secret doesn't exist yet (first install), and otherwise *fails the sync* if the dump fails, so nothing deploys without a restore point. `pgdump` mode only. |

**Label:** RUN-LOCAL (stand-in).
