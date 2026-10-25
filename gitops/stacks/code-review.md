# gitops/stacks/ — code review

**Purpose:** one file per **environment stack** (dev, staging, prod). Each file is read by two systems:
1. **Terraform** (`infra/live/local/20-data/locals.tf`) reads the `stack:` block to create the namespace and data services.
2. **Argo CD** (the stacks ApplicationSet) uses the whole file as Helm values for `charts/app`.

| File | Stack | Notes |
|---|---|---|
| `dev.yaml` | `app-dev`, tier `nonprod`, release `dev`, size tiny | First pipeline stage |
| `staging.yaml` | `app-staging`, tier `nonprod`, release `staging`, size tiny | Second stage |
| `prod.yaml` | `app-prod`, tier **`shared`**, release **`prod-ring0`**, size small | The shared production stack. Shared tenants (e.g. `initech`) are host routes onto it. It is ring 0 of the fleet rollout. |

**Schema of `stack:`:**

| Field | Meaning |
|---|---|
| `name` | Stack name |
| `namespace` | Kubernetes namespace |
| `tier` | `nonprod`, `shared` or `dedicated` |
| `release` | Which `gitops/releases/<stage>.yaml` pins its chart version and image digest |
| `residency` | `eu` or `us` |
| `region` | Simulated locally, real on AWS |
| `size` | `tiny` or `small`: resource presets |
| `slo` | `"99.9"` or `"99.95"` |

App-layer values (replicas, canary pauses, hosts) are added to these files with the chart.

**Label:** RUN-LOCAL.
