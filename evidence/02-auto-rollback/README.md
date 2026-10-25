# Evidence 02: automatic rollback of a bad release (and rollback after a migration)

**Label:** RUN-LOCAL (stand-in)

## What was released

Commit `b0b7c5a`, "demo: bad release (intentional bug)":
- The stand-in's compiled-in `FaultErrorRate` went from **0.0 to 0.3**, so 30% of API requests return 500. **Unit tests still passed**: only a canary can catch this kind of bug.
- It also carried **migration `0002`**, an *expand* step that adds a nullable `items.description` column.

It went through the normal pipeline, as a new digest (`sha256:774afd14…`) and chart `0.1.4`: [run 40198041158](https://github.com/Govind-Kandale-1/zero-downtime-platform/actions/runs/40198041158).

## What happened in dev (`dev-rollout-timeline.csv`)

| Time (UTC) | Event |
|---|---|
| 13:34:25 | Argo CD syncs the new release; the canary ReplicaSet `8488c785ff` starts. Its first pod runs migration `0002` at startup (13:34:30). |
| 13:34:33 | Step 1: Traefik splits traffic **90 / 10** (stable / canary); background analysis starts. |
| 13:35:33 / 13:36:33 | Analysis measurements, from Traefik's view of the canary Service (`analysisrun-summary.txt`). **Success rate 0.710, then 0.728 (needs ≥ 0.99)**. p95 was 48 ms and request count 54/152 per minute, both fine. |
| **13:36:31** | 2 failures > `failureLimit` 1 → **`RolloutAborted`** → traffic **100% stable**, canary scaled down (`rollout-status.json`). The worker canary's analysis was **Successful**, correctly, because the bug only affects the API. |

**Blast radius:** 10% of dev traffic for about 2 minutes. The production rings never saw the release.

## Halt on failure

- **The dev gate failed, and staging, prod-ring0, ring1 and ring2 were skipped.**
- **First attempt** (`gate-first-attempt.txt`): it failed at its 15-minute timeout ("health=Degraded"). This exposed a gate weakness: an aborted canary leaves the app Degraded, so the gate never reached its Rollout check.
- **Fix:** the gate now inspects `status.abort` while it waits (commit `59c73a7`, with a test scenario).
- **Re-run** (`gate-rerun.txt`): it failed in **23 s** with `rollout/api aborted: canary analysis failed and Argo Rollouts rolled back to stable`.

## Rollback after a migration

After the rollback, dev kept serving from the **old** version (`9fee23a`, 5/5 requests returned 200). `schema_migrations` contains `0002`, and `items` has the new column. **The old version runs on the expanded schema**, which is the point of expand/contract (ADR-018): rolling back the image is safe because the migration was backward compatible. A *breaking* migration would need a forward fix or a restore (`docs/runbooks/rollback-after-migration.md`).

## Recovery

Commit `9d03ad1` ("fix: remove intentional bug") sets the default back to 0.0 and **keeps `0002`**, because migrations are forward-only. It ships as a new release; see evidence 01.
