# infra/live/local/20-data/ — code review

**Purpose:** step 2 of the local provider layer. It installs the shared data operators, then one `stack-data` module per stack.

| File | What it does |
|---|---|
| `locals.tf` | Builds `local.stacks` from the **same files Argo CD reads**: every `gitops/stacks/*.yaml` `stack:` block (dev, staging, prod), plus every `tenants/*.yaml` with `tier: dedicated` (acme, globex; namespace `tenant-<name>`). Shared tenants get no data services. It also mirrors the image and chart pins from `config/versions.env`. |
| `main.tf` | Configures the kubernetes, helm, kubectl and vault providers from 10-cluster's remote-state outputs. The vault provider uses `skip_child_token` and `skip_get_vault_version`, so it doesn't contact OpenBao before this same apply has created it. `module.operators`, then `module.stack` with `for_each`. |
| `backend.tf` | pg backend schema `local_20_data`, plus `terraform_remote_state.cluster` |
| `tests/contract_test.sh` | Per stack: Postgres healthy, PgBouncer Available, `valkey-0` Ready with `appendonly=yes`, the secret has exactly the three keys, and `psql $DATABASE_URL` through PgBouncer returns 1 |

**Key decisions:**
- **One file per tenant drives both Terraform and Argo CD.** That is what makes onboarding "one reviewed change": merging `tenants/<name>.yaml` gives Terraform a new `module.stack` key, and an ApplicationSet a new Application.
- `for_each` keyed by stack name, never `count`, so adding or removing a tenant never re-indexes or touches the others.

**Verify:** `terraform -chdir=infra/live/local/20-data plan -detailed-exitcode` exits 0 (no drift), then run the contract test.

**Label:** RUN-LOCAL.
