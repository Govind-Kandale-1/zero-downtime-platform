# Evidence 03: 15x load (150 → 2,250 req/s) with 20,000 jobs/hour

**Label:** RUN-LOCAL (stand-in), on a laptop: a 12-CPU, 10 GiB Docker VM shared by the kind cluster *and* the load generator.

## Test shape

- **HTTP** (`load/k6/ramp-15x.js`, open model): 150 req/s for 2 min, ramp to 2,250 req/s over 3 min, hold 5 min, ramp down over 2 min. The load is `GET /api/items/{id}` through Traefik to the prod host.
- **Jobs** (`load/jobs/producer.js`): 5.56 jobs/s (20,000/hour, ADR-024), durations log-normal with mean 10 s and a 60 s cap, 5,000 jobs in total.
- **Pass criteria:** zero failed requests; p95 < 400 ms in the base and hold phases; every accepted job processed (`enqueued_total == done_total`, queue empty).
- `scripts/preflight-load.sh` first pins dev, staging, acme and globex to 1 replica and refuses to start if the projected peak memory exceeds 6.5 GiB.

## Attempt 1 (15:28:34–15:37:46 UTC, chart 0.1.6): FAILED, and why (`attempt-1/`)

**Result:**
- **55.7% of requests failed** (74,750 of 134,264). Base-phase p95 was 853 ms, ramp and hold p95 above 10 s (`ramp-15x.txt`). The run was stopped at 77%.
- **Jobs: no loss.** 2,327 jobs were enqueued during the run and 2,327 completed; 0 failed, queue empty (`job-counters.txt`). The producer saw 48% of its POSTs fail at the edge, so those jobs were never accepted, and so never lost.

**What happened** (Prometheus, 15-second steps):

| 15:30:30 → 15:31:30 | Offered (k6 schedule) | Completed req/s (1-min average) | In flight across API pods | API pods | HPA desired |
|---|---|---|---|---|---|
| 15:30:30 | 196 | 175 | 10 | 3 | 3 |
| 15:31:00 | 546 | 202 | 29 | 3 | 3 |
| 15:31:15 | 721 | 288 | **242** | 3 | **3** |
| 15:31:30 | 896 | 346 | **681** | 3 | 4 |

1. **The autoscaler couldn't see the overload.** It scaled on *completed* requests per second, and that number can't exceed what the pods can serve. It flattened around 300 while demand climbed past 900, and 3 pods held up to 681 requests in flight against a concurrency limit of 8 each. The HPA asked for 3, then 4.
2. **The load generator amplified it.** In an open model, slow responses mean more concurrent connections: k6 went from 122 to 3,000 VUs in under a minute.
3. **The edge fell over.** The single Traefik replica was **OOM-killed at its 256 MiB limit three times** (15:32:00, 15:33:45, 15:37). Its working set was 249–250 MiB just before each restart, with 2,000–6,700 connections open. Each kill took the edge down for every stack. That's where the `connection refused` / `reset` / `EOF` errors in `k6-ramp-failures.txt` come from.
4. **The VM ran out of CPU.** It went from 14% busy at the start to 77–100% from 15:32 (CPU pressure stall up to 0.95 s/s; swap grew from 0.2 to 1.4 GiB). KEDA's operator and metrics server, metrics-server, Argo CD's repo server and the CNPG operator all failed liveness probes and restarted. With KEDA down, scaling stopped entirely.

**Fixes** (each with a test or a render check):
- **In-flight saturation trigger** (`a81de00`, ADR-013 second revision). The API also scales on requests in flight per pod, with a target of 5.6 (70% of the limit of 8). It grows with the overload: at 15:31:15 it would have asked for about 43 pods, i.e. 3 → 11 → 21 within 30 s.
- **Traefik: 2 replicas, a PDB, a 512 MiB limit** (`75a3c45`), so one OOM can't take the edge down.
- **k6 discards response bodies**, so less of the shared VM's CPU goes to the load generator.

## Attempt 2 (17:19:23–17:30:42 UTC, chart 0.1.7, 2 Traefik replicas): FAILED, laptop-bound (`attempt-2/`)

**Changes since attempt 1:** the in-flight trigger, 2 Traefik replicas, and the job producer started 3 minutes before the HTTP ramp. That's deliberate: 20,000 jobs/hour is the sustained peak, and the HTTP spike lands on top of it. It also keeps the 59-pod worker scale-out out of the HTTP baseline measurement.

**Result:**
- **51.6% of requests failed** (46,801 of 90,647). Stopped at 72%.
- **The base phase was clean: p95 49 ms** (attempt 1: 853 ms).
- Failures were almost all **timeouts**. Only 1,759 were `connection refused`, from one Traefik restart, and the second replica kept serving (`k6-ramp-failures.txt`).

**What happened** (`prom-timeline.csv`):

| Time | Offered | In flight | HPA desired | Ready pods | VM CPU busy |
|---|---|---|---|---|---|
| 17:25:00 | ~500 | 20 | 4 | 4 | 37% |
| 17:25:15 | ~650 | **357** | 4 | 4 | 57% |
| 17:25:30 | ~800 | 986 | **12** | 4 | 74% |
| 17:25:45 | ~950 | 997 | **21** | 4 → 3 | **100%+** |
| 17:28:15 | | | 21 | **21** | ~80% |

- **The in-flight trigger worked.** Within 30 s of saturation the HPA asked for 4 → 12 → 21 pods. Request rate alone had never asked for more than 4.
- **The laptop couldn't follow through.** Once 4 pods saturated at about 650 req/s, the pile-up (about 1,000 requests in flight, up to 3,000 k6 connections) took the shared 12-core VM to 100%. The 17 new pods then took 2.5 minutes to become ready instead of about 10 s. kube-controller-manager (which runs the HPA and ReplicaSet controllers) restarted 7 times, and the CNPG operator lost its leader election.
- On a real cluster the load generator and the control plane don't share CPU with the application. There, a 30-second reaction at saturation means a short latency bump, not a collapse. **The laptop's ceiling is about 650–800 req/s.**

## Attempt 3 (17:49:49–18:02:25 UTC, `BASE_RPS=50`: 50 → 750 req/s): FAILED (`attempt-3/`)

This is the fallback the plan set in advance: the same 15x shape and timing on the real prod configuration, at a third of the absolute rate.

**Result:**
- **44.6% of requests failed** (49,809 of 111,762), all of them timeouts (`k6-ramp-failures.txt`).
- Base-phase p95 was 1,241 ms: a burst in the first seconds, while 58 workers had only just become ready.
- **Jobs: no loss.** 3,716 enqueued and 3,714 done; the other 2 were in progress when read, and the queue was empty.

**What happened** (`prom-timeline.csv`):

| Time | Completed req/s (1-min average) | In flight | HPA desired | Ready pods | VM CPU busy |
|---|---|---|---|---|---|
| 17:57:15 | 421 | 22 | 4 | 4 | 45% |
| 17:57:45 | 538 | **152** | 4 | 4 | 55% |
| 17:58:00 | 445 | 475 | 6 | 4 | 71% |
| 17:58:15 | 295 | 538 | 14 | 5 | **100%+** |
| 18:00 | 0 | | 21 | 2 | |

**The 4 pods saturated (about 165 req/s each) while the VM was only 55% busy.** So this time the laptop did not *cause* the saturation. It only turned it into a collapse, the same death spiral as attempt 2. The cause is headroom, and the maths below applies on any infrastructure.

## The headroom analysis: why reactive scaling saturates during a 15x ramp

Reactive scaling has to add capacity *before* the load reaches current capacity. So the spare capacity at any moment must cover what the ramp adds while the scaler reacts:

> **headroom needed = ramp slope × reaction time**

**Reaction time.** The 1-minute rate window lags a linear ramp by about 30 s. Add the scrape (15 s, about 7.5 s on average), the KEDA poll (10 s, about 5 s), the HPA sync (15 s, about 7.5 s), and pod start to ready (about 10 s on a healthy cluster). That's **about 60 s, and 90 s on the loaded laptop**.

**Headroom available.** It's `pods × C × (1 − target utilisation)`. With `rpsPerPod` 126 = 70% of the calibrated C of 180, each pod has 54 req/s spare. Under test conditions (58 worker pods, k6 and Traefik on the same VM), effective C fell to about 160–165, leaving about 35–40 per pod.

| Ramp | Slope | Headroom needed (60–90 s) | Headroom at the start (3 pods) | Outcome |
|---|---|---|---|---|
| The brief: 150 → 2,250 in 3 min | 11.7 req/s per s | 700–1,050 req/s | ~390 (idle C) | saturates during the ramp, on any infrastructure |
| Attempt 3: 50 → 750 in 3 min | 3.9 req/s per s | 230–350 req/s | ~110–160 at 4 pods (contended C) | saturated at ~640 req/s |

**What saturation costs depends on where you are:**
- **On a real cluster**, the in-flight trigger sizes the fleet to the overload in one step (attempt 2: 4 → 12 → 21 within 30 s). The ramp then costs a short latency bump, about 30–60 s with p95 above the target. The test design allows for this: during the ramp the bar is p95 < 2 s and zero failures, while p95 < 400 ms applies in the base and hold phases.
- **On this laptop**, saturation is fatal. The pile-up of queued requests and k6 connections starves the VM that also runs the control plane, so the new pods can't become ready.

**The fix, designed but not applied** (ADR-013 third revision, roadmap):
1. **Shorten the reaction time:** `rate(...[30s])`, a 5 s scrape and KEDA poll for the scaling metrics. That brings it to about 35–40 s.
2. **Size the target for the ramp, not only for steady state:** `rpsPerPod` ≈ 80 (about 45–50% of C) and `inflightPerPod` 3.5. Prod at peak then needs about 30 API pods instead of about 18–21. On AWS that is about 4.5 vCPU more *while the peak lasts* (one more `m7i.xlarge`, about $0.25/hour on demand), at most about $185/month even if peak capacity ran around the clock (`docs/cost.md`).
3. **For peaks known in advance** (campaigns, launches): KEDA `cron` pre-scaling, which removes the reaction time altogether.

These are stack values, except the rate window. The decision to stop at analysis was the owner's: the laptop runs would only re-confirm the arithmetic.

## Second finding: the worker trigger keeps a standing backlog

During steady job load (attempt 3, 17:51–17:57), the queue held **260–290 waiting jobs** with 51–58 workers, and the **oldest job waited 40–51 s**. That's what `listLength: 5` asks for: KEDA computes `desired = LLEN / 5`, so to keep 56 workers it needs about 280 jobs waiting. The worker *count* is right (Little's law: 5.56 jobs/s × 10 s ≈ 56). The extra ~50 s wait per job is pure queueing. **A target of 1 keeps the same workers with a 5x shorter queue** (about 10 s). Better still, scale on queued + in-progress jobs. This is on the roadmap. It never broke the gate's 120 s queue-age limit.

## What this evidence proves, and what it doesn't

| Claim | Status |
|---|---|
| Jobs are never lost under overload (accepted = processed) | **Proven** in all three attempts (2,327 / 3,171 / 3,716 jobs enqueued during each window, all completed, 0 failed, queue drained) |
| The scaling *mechanism* reacts to overload within 30 s | **Proven** (attempt 2: in-flight 357 → HPA 4 → 12 → 21) |
| The edge survives one Traefik replica dying | **Proven** (attempt 2: one restart, the other replica kept serving) |
| p95 < 400 ms at 150 req/s with 20k jobs/h running | **Proven** (attempt 2 base phase: p95 49 ms) |
| 15x within 5 minutes with zero errors | **Not proven.** The laptop's ceiling is about 650–800 req/s, and the headroom maths says the current targets would saturate briefly even on real infrastructure |
| 2,250 req/s on AWS | **Described only:** `docs/capacity.md` (pod and node sizing), `docs/cost.md` |

## Reproduce

```bash
bash scripts/preflight-load.sh                      # pins non-prod stacks, checks memory
# jobs first (sustained peak), then the HTTP ramp 3 minutes later
TOTAL=5000 k6 run load/jobs/producer.js &           # see attempt-*/started.txt for the exact docker run
BASE_RPS=50 k6 run load/k6/ramp-15x.js
bash scripts/canary-timeline.sh app-prod <start> <end> 15   # rebuild the timeline from Prometheus
bash scripts/preflight-load.sh --restore
```
