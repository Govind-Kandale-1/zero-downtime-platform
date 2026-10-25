# infra/live/aws/ — code review

**Label: NOT RUN (static validation only)**

The AWS target, one folder per region. Only `eu-central-1/` is written. A US tenant such as `globex` would live in a `us-east-1/` folder with the same structure; that folder is DESCRIBED, not written.

| Root (eu-central-1) | Creates | State key |
|---|---|---|
| `eu-central-1/05-network/` | VPC across 3 AZs (`modules/aws/network`) | `eu-central-1/05-network.tfstate` |
| `eu-central-1/10-cluster/` | EKS + Karpenter IAM (`modules/aws/eks`) | `eu-central-1/10-cluster.tfstate` |
| `eu-central-1/20-data/` | Regional CMKs, plus one `modules/aws/stack-data` for **every stack whose `region` is eu-central-1** (env stacks + EU dedicated tenants), with backup replicas in eu-west-1 | `eu-central-1/20-data.tfstate` |
| `eu-central-1/30-gitops/` | Argo CD plus the root Application for `gitops/clusters/aws-eu-central-1` | `eu-central-1/30-gitops.tfstate` |

**Backend:** `backend "s3"` with `use_lockfile = true` and `encrypt = true`, configured partially. Each root is initialised with `terraform init -backend-config=bucket=<bootstrap output>`. Later roots read earlier ones through `terraform_remote_state` (input `state_bucket`).

**Residency:**
- `20-data` filters stacks by region, so a tenant's data services are only ever created in the region its file names.
- The conftest policy has already guaranteed that an EU tenant names an EU region.
- Backups replicate within the same zone.

**Same inputs as local:** `20-data` reads the same `gitops/stacks/*.yaml` and `tenants/*.yaml` as the local root. One tenant file drives both targets.

**Verify:** CI's `terraform-validate` job validates every root here; output is captured in `evidence/08-aws-static/`.
