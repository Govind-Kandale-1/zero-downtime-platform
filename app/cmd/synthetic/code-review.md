# app/cmd/synthetic/ — code review

**Purpose:** **platform tooling**, not part of the black-box contract. It sends a small, constant stream of traffic to every stack through the ingress, so canary analysis always has data (ADR-016). It also works as a black-box probe: if the synthetic error rate rises, the stack is broken whether or not real users have noticed.

| File | What it does |
|---|---|
| `main.go` | Config is read from env: `TRAFFIC_TARGET` (default `http://traefik.traefik.svc`), `HOSTS` (comma list), `RPS_PER_HOST` (10) and `JOB_EVERY` (10 s). For each host it sends `GET /api/items/{1..1000}` at RPS_PER_HOST and `POST /api/jobs {"duration_ms":2000}` every JOB_EVERY, with `Host: <host>` and **`X-Synthetic: 1`**. At most 20 requests are in flight per host; anything beyond is counted as `skipped`, not queued. Exposes `synthetic_requests_total{host,code}` on :9090. |
| `targets_test.go` | `parseHosts` trims whitespace and drops empty entries. |

**Key decisions:**
- **Why it exists.** Argo Rollouts marks analysis *inconclusive* when a metric has no data, and an inconclusive result **pauses** the rollout. Dev, staging and the tenant stacks get no real traffic locally, so without this tool every pipeline run would stall at the first gate.
- **Through the ingress, by Host header.** The traffic follows the same path as users, so Traefik's edge metrics (the SLIs) see it.
- **The `X-Synthetic` header** lets dashboards exclude it from user-facing numbers. Canary analysis includes it on purpose.
- **Bounded in-flight requests per host:** a hung stack can't make the tool exhaust memory.

**Limitations:** it ships in the same image as the stand-in, for convenience, and is pinned by digest in `gitops/platform/synthetic-traffic/`. In a real platform it would be its own image, or a blackbox-exporter/k6-operator job.

**Label:** RUN-LOCAL (platform tooling).
