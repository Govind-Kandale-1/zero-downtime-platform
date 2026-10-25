# Capacity and autoscaling maths

How the platform reaches **15x (150 → 2,250 req/s) in under 5 minutes without dropping jobs**, and where the limits are.

Labels:
- `MEASURED` is `RUN-LOCAL (stand-in)`, measured on the laptop against the stand-in app.
- `DERIVED` is computed from measured numbers with the formulas below.
- `DESCRIBED` is an assumption or extrapolation for AWS that was not run.

## 1. Per-pod API capacity (MEASURED)

**Method.** The prod API was pinned to **one pod** (KEDA `paused-replicas=1`). k6 then offered constant arrival rates of 20 → 240 req/s in 60 s steps, through the real ingress (`load/k6/step-single-pod.js`). About 20 req/s of synthetic traffic hit the same pod throughout. Raw data is in `evidence/03-load-15x/calibration/step-single-pod.csv`.

| Offered by k6 (req/s) | Achieved | p95 | Errors | Verdict |
|---|---|---|---|---|
| 20 | 19.9 | 320 ms ¹ | 0 | OK |
| 40–160 | as offered | 48–52 ms | 0 | OK |
| 180 | 174.1 | 2,160 ms | 0 | saturated |
| 200–240 | ~176 | ~3,440 ms | 0 | saturated |

¹ The first step includes connection set-up and cold caches.

**Result.** **C ≈ 180 req/s per pod** (160 from k6 + ~20 synthetic) with p95 ≈ 50 ms. The pod saturates at about 195 req/s total.

This matches the stand-in's model: `MAX_INFLIGHT / latency = 8 / ~0.042 s ≈ 190 req/s`. Beyond capacity, requests **queue** rather than fail (0 errors), so latency is the signal. That's why the API scales on request rate, not CPU (ADR-013).

## 2. API autoscaling targets (DERIVED)

| Quantity | Formula | Value |
|---|---|---|
| Target per pod (`api.rpsPerPod`) | `floor(0.7 × C)` | **126 req/s** |
| Pods at baseline (150 req/s) | `max(ceil(150 / 126), minReplicas)` | 3 (the HA minimum of one per zone dominates) |
| Pods at peak (2,250 req/s) | `ceil(2250 / 126)` | **18** |
| `api.maxReplicas` | peak + 3 (canary surge + headroom) | **21** |
| Per-pod load at peak | `2250 / 18` | 125 req/s, about 69% of C |

**Why 70%:** the 30% headroom absorbs the gap between demand rising and new pods becoming Ready (the timeline is in §5). It also absorbs uneven load balancing and an extra canary ReplicaSet during a rollout.

Your original research guessed 3 → 33 pods at an assumed 100 req/s per pod. The measured capacity gives **3 → 18**.

## 3. Worker capacity (DERIVED; ADR-024)

Little's law: **L = λ × W**. The concurrent jobs in progress, L, equals the arrival rate times the mean time in the system. Each worker processes one job at a time.

λ = 20,000 jobs/h = **5.56 jobs/s**. That is assumed to be the peak rate.

| Mean job duration W | Workers needed (λ = 5.56/s) | If 20k/h were the *baseline*, so peak = 83.3/s |
|---|---|---|
| 5 s | 28 | 417 |
| **10 s (assumed)** | **56** | 833 |
| 30 s | 167 | 2,500 |
| 60 s (the maximum) | 333 | 5,000 |

- **Sizing uses the mean.** The 60 s maximum decides `terminationGracePeriodSeconds: 90`, so a scale-in never cuts a job short (ADR-006). It doesn't decide the fleet size.
- **KEDA target:** `listLength: 5` pending jobs per worker, so desired workers = queue depth ÷ 5. A backlog of 280 jobs therefore asks for 56 workers.
- **Max replicas:** 120 in production, about 2× the mean-duration need, for bursts. On the laptop it is capped at 60 (labelled), at 24 Mi per worker.

## 4. Data-tier limits (DERIVED)

**Postgres connections.**
- The stand-in uses pgx's default pool (`max(4, NumCPU)`), which is 12 connections per pod on the 12-CPU laptop VM.
- At the 21-pod maximum: 21 × 12 = **252 client connections** into PgBouncer (`max_client_conn` 1,000), multiplexed onto **40 server connections** (`default_pool_size`), against `max_connections = 200`.
- In production, set the pool explicitly (e.g. `pool_max_conns=10` in `DATABASE_URL`) so the count doesn't depend on node size.
- Workers hold no DB connections in the stand-in. If the real worker does, budget 2 per worker: 120 × 2 = 240 more client connections, still under PgBouncer's limit.

**Query rate.**
- The stand-in does one indexed SELECT per request, so 2,250 queries/s at peak.
- For the real app, assume about 2 queries per request: **~4,500 queries/s on a single writer**. That's comfortable for simple indexed reads on a 2-vCPU RDS instance with the working set in memory, but it's the **top scaling risk**: writes don't scale out.
- Mitigations, in order: read replicas (needs app support), connection-level caching, then partitioning by tenant (dedicated tenants already spread load).

**Valkey.** Each job costs about 6 operations (LPUSH + INCR, BLMOVE, LREM + INCR, plus heartbeats and the reaper). At 5.56 jobs/s that's about 35 ops/s, plus KEDA polls every 10 s. A single Valkey node handles more than 100k ops/s, so it isn't a bottleneck.

**RDS sizing (DESCRIBED).**
- Shared prod: `db.r7g.large` (2 vCPU, 16 GiB) Multi-AZ. The memory fits a working set of tens of GB of hot data with `shared_buffers` around 4 GB, and 40 pooled server connections stay below vCPU × 4 active backends.
- Dedicated tenants: `small` → `db.r7g.large`, `tiny` → `db.t4g.medium` (non-prod only, because burstable CPU credits are a risk under sustained load).

## 5. Scale-up timeline to 15x (DERIVED; the 15x run measures it)

| Step | Time |
|---|---|
| Traefik counts the new traffic, Prometheus scrapes it (15 s interval) | ≤ 15 s |
| `rate(...[1m])` follows the ramp (it lags by design) | 15–30 s |
| KEDA polls (`pollingInterval` 10 s) → HPA (15 s sync) | ≤ 25 s |
| HPA doubles per 15 s, or +8 pods: 3 → 6 → 12 → 18 → 21 | ~45 s |
| Pod start: image already on the node, ~15 MB, no migration work | ~5–10 s |
| **In-cluster total** | **~1.5–2 min** |
| AWS only: Karpenter launches a node and it joins | +60–90 s, hidden by over-provisioning pods (4.5 vCPU spare) |

The whole chain fits well inside the 5-minute target, even with the 3-minute ramp used in the test.

## 6. Nodes on AWS (DESCRIBED)

With the stand-in's requests (API 50m/32 Mi, worker 20m/24 Mi), the whole peak fleet (21 API + 120 workers) needs about 3.5 vCPU and 3.5 GiB. That's two `m7i.large` nodes. A real app is heavier. Assuming **0.5 vCPU / 512 Mi per API pod at C**, the sizing works out as follows:

| Load | API pods | API vCPU | Workers (0.1 vCPU each) | Nodes (`m7i.xlarge`, 4 vCPU, 80% usable) |
|---|---|---|---|---|
| Baseline | 3 | 1.5 | 2 → 0.2 | 2 (plus the 2-node system group) |
| Peak | 21 | 10.5 | 56–120 → 5.6–12 | 6–8 |

Karpenter adds these on demand, and the `apps` NodePool's `limits.cpu: 200` caps the spend.
