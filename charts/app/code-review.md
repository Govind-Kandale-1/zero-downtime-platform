# charts/app/ — code review

**Purpose:** **the one template** used for every stack: dev, staging, the shared prod stack, and every dedicated tenant. Shared and dedicated stacks differ only in values (`gitops/stacks/*.yaml`, or the tenant ApplicationSet), never in templates.

| File | What it is |
|---|---|
| `Chart.yaml` | `app` 0.1.0. CI overrides the version to `0.1.<run_number>` and publishes it to `oci://ghcr.io/govind-kandale-1/charts`, so the chart is promoted together with the image (ADR-014). `kubeVersion >= 1.30` because of the native `preStop.sleep` hook. |
| `values.yaml` | Defaults for one stack (see the table below) |
| `.helmignore` | Keeps `code-review.md` files and `tests/` out of the packaged chart. A review inside `templates/` would otherwise be rendered as a template and break the chart; a render check proves the package is clean |
| `values.schema.json` | Rejects a render without `image.digest` matching `sha256:<64 hex>` (no tags, ever); validates the name pattern, size, tier and SLO enums |
| `templates/` | 13 templates plus 2 partials (see `templates/code-review.md`) |
| `tests/` | Render assertions, kubeconform and promtool (see `tests/code-review.md`) |

**Key values and why:**

| Value | Default | Why |
|---|---|---|
| `api.canarySteps` / `pauseSeconds` | 10, 25, 50 / 120 s (60 s locally) | Small blast radius first; each pause gets at least one 1-minute analysis measurement |
| `api.minReplicas` | 3 | One per zone, so losing a zone (or a node locally) leaves capacity |
| `api.rpsPerPod` | 70 (placeholder) | 70% of the measured per-pod capacity; prod sets the calibrated 126 |
| `api.inflightMetric` / `api.inflightPerPod` | `http_inflight_requests` / 5.6 | The saturation trigger: requests in flight (served + queued) per pod, 70% of `maxInflight`. For the real app, its active-requests gauge (an assumption to confirm) |
| `api.cpuRequest` / `api.cpuUtilization` | 200m / 100 | The CPU safety net fires at ~143 req/s per pod: after the RPS trigger, before saturation. One value for every size, because CPU follows per-pod load (~1.4 m per req/s, measured in evidence 01) |
| `worker.terminationGracePeriodSeconds` | 90 | Longer than the 60 s maximum job, so draining never kills work |
| `worker.maxReplicas` | 120 | Little's law at 5.56 jobs/s × 10 s ≈ 56, with headroom (ADR-024) |
| `analysis.*` | success ≥ 99%, p95 ≤ 0.4 s, ≥ 20 requests/min | Matches the brief's p95 target; below the minimum count the result is *inconclusive*, never a pass |
| `backup.mode` | `pgdump` | Local CNPG. `managed` means RDS automated backups + PITR on AWS |
| `slo.latencyObjective` | 0.95 | The latency SLO: ≥ 95% of requests within 400 ms (the brief's p95). Availability uses `stack.slo` |
| `queue.address` / `queue.tls` | "" / false | Default: KEDA reads `QUEUE_ADDRESS` from the stack secret (every provider); `tls: true` for ElastiCache |
| `nodePool.enabled` / `limitsCpu` | false / 32 | AWS: render a tainted Karpenter pool for this stack and pin its pods to it (dedicated tenants) |
| `api/worker.nodeSelector`, `tolerations` | {} / [] | Per-component scheduling, e.g. workers on the spot pool on AWS |
| `alerts.queueAgeSeconds` | 300 | `ZdpQueueBacklog` threshold: 5× the longest job; the gate's limit is 120 s |
| `backup.timeoutSeconds` | 900 | A hung backup job fails instead of blocking later runs |
| `dbMetrics` | true | Scrape the CloudNativePG Postgres + PgBouncer exporters (local only; `false` on AWS) |

**Assumptions about the platform:**
- Traefik labels weighted child services as `<namespace>-<service>-<port>@kubernetescrd`, and its ServiceMonitor uses `honorLabels: true`, so `service=` is Traefik's label. This is checked live during the first deployment.
- The stack Application must ignore drift on `TraefikService` weights (`ignoreDifferences`). Otherwise Argo CD self-heal would reset the weights Argo Rollouts sets mid-canary.

**Verify:**
- `bash charts/app/tests/render_test.sh`: 40 checks.
- `helm lint charts/app -f charts/app/tests/values-prod.yaml --kube-version 1.34.0`.

**Label:** RUN-LOCAL (stand-in).
