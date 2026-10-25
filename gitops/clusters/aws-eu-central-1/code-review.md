# gitops/clusters/aws-eu-central-1/ — code review

**Label: NOT RUN (static validation only)**

The second cluster definition, showing that the platform layer is reused rather than rewritten.

| Path | What it is |
|---|---|
| `root.yaml` | App-of-apps root → `gitops/clusters/aws-eu-central-1/apps`, applied by `infra/live/aws/eu-central-1/30-gitops` |
| `apps/00…20-*.yaml` | The **same platform Applications** as the local cluster, pointing at `values/aws/` instead of `values/local/` |
| `apps/15-karpenter.yaml` | AWS-only: Karpenter (chart 1.15.1 from `public.ecr.aws/karpenter`) |
| `apps/21-platform-config.yaml` | Syncs `gitops/platform/aws` (Secrets Manager store, Karpenter pools, over-provisioning) |
| `apps/30-synthetic-traffic.yaml` | The same synthetic traffic as local (ADR-016), so canary analysis and gates always have data |
| `apps/40-appset-stacks.yaml` | The same as local, plus `valkeyMetrics: false`, `dbMetrics: false`, `backup.mode: managed` (RDS PITR replaces pg_dump), `queue.tls: true` (ElastiCache), and workers on the spot pool |
| `apps/41-appset-tenants-dedicated.yaml` | The same as local, plus a post-selector **`region: eu-central-1`**, so only tenants homed in this region get an app here; `nodePool.enabled` (the tenant's own pool) and `queue.tls: true` |
| `apps/42-appset-tenants-shared.yaml` | The same as local, plus the `region: eu-central-1` post-selector: a shared tenant rides the shared prod stack of its home region |

**What is identical to local:** the app chart, the release files, promotion and gates, the SLO rules and the canary analysis.
