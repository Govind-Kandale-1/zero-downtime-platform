# What is not portable

**Label:** Local column RUN-LOCAL; AWS column NOT RUN (static validation only).

The platform and app layers are identical on every target. Only the **provider layer** (`infra/modules/<provider>`) and the **platform values overlays** (`gitops/platform/values/<target>`) change. This is the complete list of what a third provider has to re-implement, and why each item can't be made generic.

## Provider layer: same contract, different implementation

| Concern | Local (kind) | AWS | Why it can't be generic |
|---|---|---|---|
| **Database + HA** | CloudNativePG `Cluster`, 1 instance | RDS PostgreSQL Multi-AZ | Managed HA (synchronous standby, failover) is a cloud service, not a manifest |
| **Backups / PITR** | hourly `pg_dump` + PreSync dump to PVC `pg-backups` (`backup.mode: pgdump`) | RDS automated backups, 14-day PITR, replicated to eu-west-1 (`backup.mode: managed`) | RDS PITR replaces the dump jobs; the chart switches them off |
| **Connection pooler** | CNPG `Pooler` (PgBouncer, transaction mode) | PgBouncer Deployment in the stack namespace | CNPG's Pooler only fronts CNPG clusters. The endpoint name `pgbouncer.<ns>.svc:5432` is the contract and is identical |
| **Cache / queue** | Valkey StatefulSet (AOF, `noeviction`) + `redis_exporter` sidecar | ElastiCache for Valkey, Multi-AZ, TLS (`rediss://`) | Managed failover; TLS changes the URL scheme, which travels in the secret |
| **Secrets store** | OpenBao (dev mode), written by Terraform's `vault` provider | AWS Secrets Manager | Different APIs. External Secrets abstracts reads; only the `ClusterSecretStore` provider block differs |
| **Workload identity** | none: a static OpenBao token in a Kubernetes Secret | EKS Pod Identity (ESO, Karpenter, EBS CSI) | Identity federation is cloud-specific |
| **Terraform state** | `backend "pg"`, a Postgres container started by `up.sh` | `backend "s3"` with `use_lockfile`, bucket from `infra/bootstrap/aws` | The backend block can't be templated; each target has its own chicken-and-egg bootstrap |
| **Encryption at rest** | none (laptop) | KMS CMKs: one for data in eu-central-1, one in the backup region | Key management is cloud-specific |
| **Network** | Docker `kind` bridge | VPC with 3 AZs, private subnets, a NAT per AZ | — |
| **Network policy enforcement** | kindnet enforces NetworkPolicy (verified: `evidence/00-bringup/networkpolicy-check.txt`) | VPC CNI with `enableNetworkPolicy` (without it, EKS accepts policies and enforces none) | CNI-specific |

## Platform overlays: same components, different values

| Concern | Local | AWS | Why |
|---|---|---|---|
| **Ingress exposure** | Traefik `NodePort` 30080, 2 replicas | Traefik behind an NLB (in-tree service annotations), 3 replicas across AZs | Load balancers are cloud resources |
| **Node autoscaling** | none: fixed kind nodes | Karpenter NodePools (`apps`, `workers-spot`, per-tenant tainted pools) + over-provisioning | Node provisioning is cloud-specific |
| **Storage class** | `standard` (local-path) | `gp3` (EBS CSI, encrypted) | — |
| **Data-tier metrics** | exporters scraped in-cluster (`valkeyMetrics`, `dbMetrics`) | CloudWatch / RDS Performance Insights (both flags `false`) | The managed services expose metrics through the cloud |
| **DNS / TLS** | `*.localtest.me` over HTTP | Route 53 + ACM or cert-manager (DESCRIBED) | Not built: there is no real domain |
| **Residency enforcement** | conftest policy on tenant files; regions simulated with labels | the same policy + Terraform region filtering + an EU-only permissions boundary (sample SCP in `docs/policies/`) | Account guard-rails are cloud-specific |

## Portable on purpose (don't re-implement)

The app chart; Argo CD, Argo Rollouts, KEDA, External Secrets, kube-prometheus-stack, Traefik (values only); the release pipeline, release files and gates; GHCR and cosign (they don't depend on the cluster's cloud); the tenant files and their policy.

## Caveats

- **Kyverno signature verification** (DESCRIBED) needs egress to Sigstore's public-good instance (Fulcio/Rekor) from the cluster. Air-gapped targets would need a private Sigstore or key-based signing.
- **GHCR** is reachable from both targets. An ECR pull-through cache (roadmap) would make image pulls survive a GitHub outage, but it is an AWS-only component.
