# Runbook: tenant onboarding failed

**How onboarding works** (`tenants/code-review.md`): one reviewed PR adds `tenants/<name>.yaml`.
- **Shared** tier: Argo CD's `tenants-shared` ApplicationSet renders a host route and per-tenant SLO rules on the prod stack.
- **Dedicated** tier: Terraform `20-data` creates the tenant's namespace, Postgres + PgBouncer, Valkey and secret. Then the `tenants-dedicated` ApplicationSet creates `stack-<name>` at its ring's release.

The Terraform apply is manual today (`tenant-apply.yml` is roadmap item 7). The target is under 30 minutes from merge to Healthy.

**Find the stage it's stuck at, top to bottom:**

| Stage | Check | Typical failure → fix |
|---|---|---|
| **1. CI** | the PR's `policy-test` job (conftest) | residency violation (`eu` with a non-EU region, including `eu-west-2` London and `eu-central-2` Zurich), missing or invalid field, a duplicate name → fix the file. The policy is the guard-rail; don't bypass it |
| **2. Provider layer** (dedicated) | `terraform -chdir=infra/live/local/20-data plan` shows the tenant's resources; `bash infra/live/local/20-data/tests/contract_test.sh` | apply not run yet → run it. A name collision or invalid size → fix the file. Postgres not becoming ready → `kubectl -n tenant-<name> describe cluster.postgresql.cnpg.io <name>-pg` (storage, image pull) |
| **3. Application created?** | `kubectl -n argocd get applicationset`; `kubectl -n argocd get application stack-<name>` (dedicated) or `tenant-<name>` (shared) | not created: the generator's post-selector filtered it out. Check `tier`, `ring` and, on AWS, `region` match the ApplicationSet; `kubectl -n argocd describe applicationset <set>` shows generator errors |
| **4. Release present?** | `ls gitops/releases/ring<N>.yaml` | a ring that has never been released has no file, so its stacks wait. The next release promoting to that ring creates it. Or promote the current digest: `scripts/bump-release.sh ring<N> <version> <digest>` |
| **5. App Healthy?** | `kubectl -n argocd get application stack-<name> -o jsonpath='{.status.health.status}'`; `kubectl -n tenant-<name> get externalsecret,pods` | `ExternalSecret` not `SecretSynced` → the secret path `stacks/<name>/app` is missing in the store (stage 2). Pods not ready → `/readyz` failing on the database or Valkey (the logs say which). PreSync backup Pending → the `pg-backups` PVC is missing (stage 2) |
| **6. Reachable?** | `curl -H "Host: <name>.localtest.me" http://localhost/healthz` (or its configured host) | no route → for shared tenants check `IngressRoute tenant-<name>` in `app-prod`; for dedicated, the stack's own `IngressRoute` |

## Backing out

- **Revert the PR.** Argo CD prunes the tenant's Applications (route, rules, stack).
- **The data services are not deleted automatically.** For a dedicated tenant, `terraform apply` after the revert plans to destroy its database and volume. Destroying tenant data is a separate, explicit decision: confirm the tenant holds nothing that must be kept, take a final dump first, then apply.

## Verify

The tenant's Application is Synced/Healthy, its SLO rules are loaded (`kubectl -n <ns> get prometheusrule`), and its host answers `/healthz` with 200. Record the merge-to-Healthy time: the < 30 min target needs evidence.
