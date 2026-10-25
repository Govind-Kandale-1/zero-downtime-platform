# evidence/08-aws-static — AWS provider layer, statically validated

**Label:** NOT RUN (static validation only)

The AWS Terraform was never applied, because no AWS account was used (ADR-001). These files show it is syntactically and semantically valid against the pinned providers and modules, and free of HIGH/CRITICAL misconfigurations:

| File | What it shows |
|---|---|
| `terraform-validate.txt` | `init -backend=false && validate`: **Success** for bootstrap, 05-network, 10-cluster, 20-data and 30-gitops |
| `tflint.txt` | `tflint --recursive` with the terraform ruleset (recommended preset): exit 0 |
| `trivy-config.txt` | `trivy config --severity HIGH,CRITICAL infra`: 0 failures. One accepted finding is recorded with its reason in `.trivyignore.yaml` (AWS-0104, node egress, a module default). Example manifests inside downloaded modules (`.terraform/`) are skipped. |

CI repeats the validate, tflint and trivy checks on every pull request (`terraform-validate`, `iac-scan`).

**What static validation cannot prove:** IAM permission gaps, service quotas, regional availability of instance types or engine versions (PostgreSQL 18 and Valkey 8.1 are assumptions), or whether the cluster actually converges. Those need a real `apply`, the first roadmap item.
