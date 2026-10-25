# Evidence 00: empty laptop → running platform → first fleet release

**Label:** RUN-LOCAL (stand-in)

## 1. One command from empty: `scripts/up.sh`

`down-purge.log` shows the start state: the kind cluster, the Terraform state DB and its volume, and the local state files all deleted.

`networkpolicy-check.txt` (added 2026-10-26): a pod in an unrelated namespace can't reach prod's API directly (only Traefik may), while Prometheus, which has no policy, stays reachable. kindnet enforces the chart's default-deny.

`up.log` shows the bring-up (the Argo CD password is redacted):

| Step | Time |
|---|---|
| Preflight + Terraform state DB | ~1 min |
| `10-cluster` (kind, 3 nodes) | 2 min 40 s |
| `20-data` (CNPG, OpenBao, 5 stacks); contract test **ALL PASS (5 stacks)** | 5 min 55 s |
| `30-gitops` (Argo CD + root app) | 2 min 38 s |
| Argo CD installs the platform layer; `platform_test.sh` **ALL PASS** | ~12 min |
| Self-hosted gate runner registered; **read-only access verified** | 1 min |
| **Total** | **24 min 52 s**, exit 0 |

## 2. First release through every stage

Run [40183505084](https://github.com/Govind-Kandale-1/zero-downtime-platform/actions/runs/40183505084) shipped one artifact everywhere: image `sha256:f91b81a5…` and chart `0.1.2`. Job timeline: `release-run-jobs.tsv`.

`build → scan → sign → chart → dev → staging → [production approval by the repo owner] → prod (ring 0, the shared stack + shared tenant initech) → ring 1 (acme) → ring 2 (globex)`

Gate verdicts (`gate-verdicts.txt`), measured on each stack's own edge metrics after a 180 s soak:

| Stage | Stack | 5xx ratio | p95 | Oldest job |
|---|---|---|---|---|
| dev | dev | 0 | 49 ms | 0 s |
| staging | staging | 0 | 48 ms | 0 s |
| prod-ring0 | prod | 0 | 79 ms | 0 s |
| ring1 | acme | 0 | 49 ms | 0 s |
| ring2 | globex | 0 | 53 ms | 0 s |

Afterwards, all 16 Argo CD apps were Synced/Healthy (`argocd-apps-after-release.txt`). Every host, including the shared tenant `initech`, serves the same build through the ingress (`version-per-stack.txt`).

## 3. What the first real release found, and how it was fixed

Each item was fixed in its own commit, with a test where one applies:

1. **The first install hung on the PreSync backup.** The backup Job mounted a volume claim that doesn't exist before the first sync, because hooks run before ordinary resources. Fix: the claim is itself a PreSync hook with weight -1, and a render regression check covers it. The first run, `40182607417`, was cancelled.
2. **Halt-on-failure, observed for real.** While dev was stuck, its gate timed out and staging was skipped. The failed gate was re-run after the fixes.
3. **Rollouts and Services were permanently OutOfSync.** The cause was mixing ServerSideApply with Argo CD's client-side diff. Fix: `controller.diff.server.side=true`. Separately, Argo Rollouts owns the Services' (atomic) selectors, so Argo CD now ignores fields managed by `rollouts-controller`.
4. **The gate failed prod instantly on a transient "Degraded".** That status came from a brand-new stack still converging. Fix: only `status.abort=true` on a Rollout fails fast; Degraded waits until the deadline. Two new stubbed gate scenarios cover it. Rings 1–2 were skipped until the prod gate was re-run, which again showed halt-on-failure.
5. **Operator errors, recorded honestly.** A push of mine raced the pipeline's release commit and was rejected without my noticing. Separately, I deleted a hook Job during an active sync, which left the sync stuck. Both are recorded in the build ledger, with the rule each one taught.

**Not part of this evidence:** canary analysis on a *change* (first installs skip canary steps) is covered in evidence 01 and 02.
