# tenants/ — code review

**Purpose:** one YAML file per tenant. **Onboarding a tenant is one reviewed PR that adds one file here.**

| File | Tenant | Tier | Residency / region | Ring | SLO |
|---|---|---|---|---|---|
| `acme.yaml` | acme | dedicated | eu / eu-central-1 | 1 | 99.95 |
| `globex.yaml` | globex | dedicated | us / us-east-1 (simulated locally) | 2 | 99.95 |
| `initech.yaml` | initech | shared | eu / eu-central-1 | rides ring 0 | 99.9 |

**Schema:**

| Field | Meaning |
|---|---|
| `name` | Must match the filename |
| `tier` | `dedicated` gets its own namespace `tenant-<name>`, Postgres, PgBouncer, Valkey and app release. `shared` gets a host route `<name>.localtest.me` onto the shared prod stack. |
| `residency` | `eu`, `us` or `none` |
| `region` | An EU region is required when residency is `eu` (enforced by `policy/tenants.rego`) |
| `ring` | Integer ≥ 1, required for dedicated tenants; sets their place in the fleet rollout |
| `size` | `small` or `medium` |
| `slo` | `"99.9"` or `"99.95"` |

**What happens on merge:**
1. CI runs `conftest test --combine --namespace tenants -p policy tenants/*.yaml`, which checks residency, schema and file name (`policy/code-review.md`).
2. Terraform `20-data` creates the dedicated tenant's data services and secrets.
3. An Argo CD ApplicationSet creates the tenant's app release at its ring's pinned version.

**Label:** RUN-LOCAL.
