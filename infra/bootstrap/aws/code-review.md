# infra/bootstrap/aws/ — code review

**Label: NOT RUN (static validation only)**

**Purpose:** a one-time bootstrap for an **empty AWS account**. It is applied once with **local state**, because the state bucket can't hold the state that creates it. Afterwards that state can be migrated into the bucket (`terraform init -migrate-state`).

| File | What it creates |
|---|---|
| `main.tf` | A KMS key with rotation. The **S3 state bucket**: versioned, CMK-encrypted, public access blocked, a TLS-only bucket policy, and access logging to a second bucket. Locking uses S3's native lockfile, so there's no DynamoDB table. The **GitHub OIDC provider** and the role `zdp-deploy`, trusting only `repo:Govind-Kandale-1/zero-downtime-platform:ref:refs/heads/main`, so **no long-lived AWS keys exist anywhere**. The role is broad (AdministratorAccess) but capped by a **permissions boundary** that denies non-EU regions (`docs/policies/eu-region-scp.json`). |
| `variables.tf` | `region` (eu-central-1), `github_repository` |
| `outputs.tf` | `state_bucket` (passed to every live root as `-backend-config=bucket=…`), the KMS key ARN, the deploy role ARN |
| `versions.tf` | AWS provider 6.70.0, default tags |

**Key decisions:**
- OIDC instead of access keys: the credentials are short-lived and scoped to one repo and one branch. ADR-004 covers state.
- A permissions boundary rather than an SCP: SCPs need AWS Organizations, which a single account may not have. The same JSON works as an SCP in an organisation.

**Verify:** `terraform -chdir=infra/bootstrap/aws init -backend=false && terraform validate` succeeds; Trivy finds 0 HIGH/CRITICAL (`evidence/08-aws-static/`).
