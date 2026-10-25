# infra/live/local/10-cluster/ — code review

**Purpose:** step 1 of the local provider layer: create the cluster and publish its connection details as contract outputs.

| File | What it does |
|---|---|
| `main.tf` | Calls `modules/local/kind-cluster` with name `zdp`, the digest-pinned `kindest/node:v1.34.0`, 2 workers, and the kubeconfig at `<repo>/.local/kubeconfig` |
| `backend.tf` | `backend "pg" { schema_name = "local_10_cluster" }`. The connection string comes from `PG_CONN_STR`. |
| `outputs.tf` | `kubeconfig_path`, `endpoint`, CA, and the client cert/key (sensitive), read by `20-data` and `30-gitops` |
| `versions.tf` | Terraform ≥ 1.14, `tehcyx/kind` 0.13.0 |

**Verify:**
- `terraform -chdir=infra/live/local/10-cluster validate`
- After apply, 3 nodes are Ready.
- `docker exec zdp-tfstate psql -U tfstate -tAc "select name from local_10_cluster.states"` prints `default`. This proves state is remote, not a local `terraform.tfstate`.

**Limitations:** the node image digest is repeated here and in `config/versions.env`. Terraform can't read env files in a `module` block without a wrapper, and CI's validate job keeps the two honest.

**Label:** RUN-LOCAL.

**Also:** `.terraform.lock.hcl`: the provider dependency lock (exact versions and checksums), committed so every run uses the same providers.
