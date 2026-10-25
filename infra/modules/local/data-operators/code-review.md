# infra/modules/local/data-operators/ — code review

**Purpose:** cluster-wide local stand-ins for managed services, installed once and shared by every stack.

| File | What it does |
|---|---|
| `main.tf` | **CloudNativePG operator** (chart 0.29.1, ns `cnpg-system`). This is the local "RDS": each stack declares a `Cluster` and a `Pooler`. **OpenBao** (chart 0.30.4, ns `openbao`) in **dev mode** with root token `root`, KV v2 at `secret/`, and a NodePort on 30200, which kind maps to `127.0.0.1:8200` for Terraform. This is the local "Secrets Manager". It also creates the `external-secrets` namespace and the `openbao-token` Secret the ClusterSecretStore authenticates with. |
| `variables.tf` | Chart versions; the dev root token (sensitive) |
| `outputs.tf` | `openbao_address` (`http://127.0.0.1:8200`) for the vault provider |

**Key decisions:**
- **CloudNativePG** over a plain Postgres StatefulSet or the Bitnami chart. It is a real operator (failover, backups, a pooler CRD) and its CRDs mirror what RDS gives you. Bitnami's free images moved to an unmaintained legacy repo in 2025 (ADR-007).
- **OpenBao** (the Linux Foundation fork of Vault) over in-cluster plain Secrets. External Secrets Operator talks to it through the same `ClusterSecretStore` abstraction it uses for AWS Secrets Manager, so the app layer is identical on both targets (ADR-009).
- **Dev mode is deliberate and labelled.** It is in-memory, auto-unsealed and uses a static root token. A pod restart loses the secrets; re-running `terraform apply` on `20-data` re-seeds them, and drift detection notices the loss. In production this would be HA storage + auto-unseal (KMS) + Kubernetes auth, or simply the cloud's secrets manager.

**Verify:** `kubectl -n cnpg-system get deploy` (Available); `kubectl -n openbao exec openbao-0 -- bao status` (Sealed: false).

**Limitations:** the static token Secret is a local-only shortcut. On AWS, ESO uses EKS Pod Identity and holds no credential.

**Label:** RUN-LOCAL.
