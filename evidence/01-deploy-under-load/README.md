# Evidence 01: a production deploy under steady load, with zero failed requests

**Label:** RUN-LOCAL (stand-in)

## What was released

The recovery release after evidence 02. Commit `9d03ad1` ("fix: remove intentional bug") went through the normal pipeline as image `sha256:bacdf833941d…` and chart `0.1.5`: [run 40199541412](https://github.com/Govind-Kandale-1/zero-downtime-platform/actions/runs/40199541412). Prod was running `f91b81a5…`, because the bad release in evidence 02 never got past dev.

- **Every stage gated and passed** (`gate-verdicts.txt`, `release-run-jobs.tsv`): dev → staging → prod-ring0 (after a human approval in the `production` GitHub Environment) → ring1 (acme) → ring2 (globex). Each gate saw a 5xx ratio of 0 and p95 ≈ 48 ms.

## The load

k6 sent a constant **150 req/s** of `GET /api/items/{id}` to the prod host. That's the brief's baseline, sent through Traefik exactly as users would reach it, and it ran from 14:10:26 until after the rollout ended. The synthetic traffic deployment adds about 20 req/s on top.

**Result (`steady.txt`, `k6.log`): 116,988 requests, 0 failed, p95 53 ms.**

## What happened in prod (`prod-canary-timeline.csv`)

The timeline was rebuilt afterwards from Prometheus (`scripts/canary-timeline.sh`). Rates are 1-minute averages, so each step shows up smoothed over about a minute.

| Time (UTC) | Event | Edge traffic stable / canary | 5xx/s |
|---|---|---|---|
| 14:10:45 | The load arrives | 50 → 165 / 0 req/s | 0 |
| 14:11:03–14:11:33 | **The HPA scales 3 → 5 → 12 → 14 API pods, on CPU** (see Finding 1) | 164 / 0 | 0 |
| 14:12:01–14:12:06 | The Argo CD PreSync hook takes a `pg_dump` backup before the sync applies | | 0 |
| 14:12:07 | Canary ReplicaSet `api-5f4b6fd58d` is created; background analysis starts at 14:12:11 | | 0 |
| 14:12:45–14:13:30 | **Step 1: 10% to the canary** | 153 / 17 | 0 |
| 14:13:45–14:14:30 | **Step 2: 25%** | 128 / 43 | 0 |
| 14:14:45–14:15:30 | **Step 3: 50%** | 85 / 85 | 0 |
| 14:15:35 | The AnalysisRun completes **Successful**: 3 of 3 measurements per metric. Success rate 1.0, p95 47–48 ms, 998 / 2,552 / 5,061 canary requests per minute (`analysisrun-summary.txt`) | | 0 |
| 14:16:00–14:16:45 | Promotion: 100% to the new ReplicaSet, which becomes stable; the old ReplicaSet scales to 0 | 170 / 0 | 0 |

The worker's canary analysis (`worker-76945dc875-2`) also finished Successful.

## Finding 1: the CPU "safety net" was really the primary trigger (fixed)

The HPA events (`hpa-events.txt`) show the scale-up came from **`cpu resource utilization above target`**, not from request rate. The fleet then sat at 14–15 pods for about 170 req/s, roughly 7% of its capacity. It shrank back to 3 pods only after the 5-minute scale-down window.

**Cause.** The API's CPU request was 50m and the CPU trigger 70% of it. Prometheus shows the stand-in uses about **1.4 millicores per req/s** (total API CPU vs total edge req/s: 26m at 20 req/s on 3 pods, about 230m at 170 req/s on 15 pods; no meaningful fixed cost per pod). So CPU crossed its threshold at about **25 req/s per pod**, five times below the RPS target of 126.

**Fix** (commit `0b815e7`, ADR-013 revised):
- The CPU request is now **200m** and the trigger **100%**. CPU fires at about 143 req/s per pod: after the RPS trigger (126), before saturation (C ≈ 180).
- A render test enforces the inequality.

## Finding 2: a 45-second latency bump during the scale-up, with 0 errors

From 14:11:30 to 14:12:15, edge p95 rose to about 1 s.
- **Counts:** 387 of the ~117k requests took longer than 1 s, 48 took longer than 2.5 s, and 3 took longer than 5 s (k6's max was 5.9 s). **None failed.**
- **Timing:** this was *before* the canary started. During the canary itself, p95 stayed at 48–106 ms.

What the data rules out:
- **Node CPU:** the 12-core VM peaked at 54% busy.
- **CPU throttling:** none, on any pod.
- **PgBouncer saturation:** it peaked at 142m CPU, on a single thread.
- **The backup hook:** it ran from 14:12:01 to 14:12:06, after the bump had started.

What the data shows:
- **App-side latency rose on every pod**, including the three that were already warm. So the delay was inside the handler, in something all pods share.
- **Postgres CPU jumped from 14m to 286m** as about 100 new client connections arrived at PgBouncer within 30 seconds: 11 new pods, plus the existing pods growing their pools for an 8x jump in load.

The most likely cause is **database connection setup under a burst**. It can't be proven from this run, because **no Postgres or PgBouncer metrics were being scraped**. The fix commit adds PodMonitors for both exporters (`dbMetrics`), so the next run shows pool waits directly. Finding 1's fix also removes the trigger for the burst here: at 170 req/s the RPS trigger keeps 3 pods instead of starting 11 at once.

## Reproduce

```bash
TOOL_DOCKER_ARGS="--network kind -e HOST=prod.localtest.me -e RATE=150 -e DURATION=60m -e OUT=evidence/01-deploy-under-load/steady" \
  bash -c '. scripts/lib/tools.sh; tool_k6 run load/k6/steady-under-deploy.js'
gh workflow run release.yml        # approve production when asked
bash scripts/canary-timeline.sh app-prod <start> <end> 15
```
