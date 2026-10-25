# Runbook: canary aborted

**Label:** RUN-LOCAL for detection and diagnosis (a real abort: evidence 02); the retry path is DESCRIBED.

**Trigger:** a release run's gate fails with `GATE FAIL <stage>/<stack>: rollout/api aborted` (or `rollout/worker`). In Argo CD the stack shows **Degraded**, and the Rollout has a `RolloutAborted` event.

**User impact right now:** usually none left. Argo Rollouts has already put 100% of traffic back on stable and scaled the canary down. The blast radius was the canary weight for the length of the analysis: 10% for about 2 minutes, in evidence 02. Later stages and rings were skipped, because each needs the previous gate.

## 1. Confirm what failed (2 min)

```bash
ns=app-dev   # the stack named in the gate message (tenant-<name> for tenants)
kubectl -n $ns get rollout api -o jsonpath='{.status.abort} {.status.message}{"\n"}'
kubectl -n $ns get analysisrun --sort-by=.metadata.creationTimestamp | tail -3
kubectl -n $ns get analysisrun <newest> -o yaml | grep -A4 'name: canary-'   # each measurement and its value
```

Which metric failed tells you what kind of problem it is:

| Failed metric | Means |
|---|---|
| `canary-success-rate` < 0.99 | The new version returns 5xx. This is almost always a real bug. |
| `canary-p95-latency` > 0.4 s | The new version is slower: a query regression, a cold cache, a heavier request. |
| `canary-request-count` < 20/min | No traffic reached the canary, so the analysis can't judge it. **Not a bug in the release.** Check that the synthetic traffic deployment is running (ADR-016) and that Traefik routes to `api-canary`. |
| Error / inconclusive | Prometheus could not be queried. A platform problem, not a release problem. |

## 2. Decide

- **Real bug** → **fix forward.** Commit the fix; the release pipeline builds a new digest and runs it through every gate again. Evidence 02 → 01 is exactly this path. Leaving the stage Degraded until then is safe, because stable serves.
- **False positive** (no traffic, Prometheus down) → fix the platform cause, then retry the *same* artifact:
  ```bash
  kubectl argo rollouts retry rollout api -n $ns   # or, without the plugin:
  kubectl -n $ns patch rollout api --subresource status --type merge -p '{"status":{"abort":false}}'
  ```
  Then re-run the failed gate job from the GitHub run page ("Re-run failed jobs").
- **The fix will take hours, and the Degraded state is noisy** → pin the stage back to the last good release. It's a normal promotion commit, so provenance is kept:
  ```bash
  scripts/bump-release.sh <stage> <previous chart version> <previous digest>   # values: git log gitops/releases/<stage>.yaml
  ```

## 3. Did the bad release carry a migration?

The canary's first pod migrates the shared database *before* the analysis judges it. The stable version is now running on the new schema.

```bash
git diff <last good sha> <bad sha> -- app/migrations/
```

If anything changed, follow [rollback-after-migration.md](rollback-after-migration.md) **before** deciding anything else.

## 4. Verify

- `kubectl -n $ns get rollout api` → `Healthy`; the Argo CD app → `Synced/Healthy`.
- In Grafana, the stack's error-budget burn rate is back below 1.
- For a fix-forward: the new release run's gates all print `GATE PASS`.

**Evidence:** `evidence/02-auto-rollback/` (a real abort, its timeline and the gate output).
