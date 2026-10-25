# infra/modules/aws/eks/ — code review

**Label: NOT RUN (static validation only)**

Wraps `terraform-aws-modules/eks` 21.29.0 and its `karpenter` submodule (ADR-022).

| Aspect | Setting and why |
|---|---|
| API endpoint | **Private only.** CI never talks to the cluster (GitOps pulls), and Terraform runs from inside the VPC. |
| Node group `system` | 2–3 × `m7i.large`, labelled `zdp/pool=system`. It holds CoreDNS, Karpenter, Argo CD and the other controllers. |
| Add-ons | CoreDNS, kube-proxy, vpc-cni **with its network-policy agent enabled** (otherwise EKS accepts NetworkPolicy objects but enforces none, and the chart's default-deny would be void), **EKS Pod Identity agent** (credentials for ESO, Karpenter and the EBS CSI driver without IRSA annotations), EBS CSI driver |
| Karpenter | IAM role, SQS interruption queue and Pod Identity association. NodePools are platform manifests (`gitops/platform/aws/karpenter.yaml`). |
| Pod Identity roles | **External Secrets**: read-only on `stacks/*` secrets, KMS decrypt only via Secrets Manager. **EBS CSI driver**: the AWS-managed `AmazonEBSCSIDriverPolicy`. Both bound with `aws_eks_pod_identity_association` (the independent review found only Karpenter had one, so ESO couldn't have read a secret and no volume could have been created) |
| Access | `enable_cluster_creator_admin_permissions`; secrets envelope-encrypted with the module's KMS key |

**Key decisions:**
- **Karpenter instead of Cluster Autoscaler:** it provisions the right instance type directly in about 60–90 s, without pre-defined node groups per size, and consolidates after the peak.
- **Pod Identity instead of IRSA:** there's no OIDC trust policy per service account to maintain, and the associations are managed in Terraform.

**Accepted finding:** `AWS-0104` (the node security group allows all egress, a module default). Nodes need to reach GHCR, AWS APIs, Sigstore and GitHub. The reason is recorded in `.trivyignore.yaml`; VPC endpoints and an egress allow-list are on the roadmap.

**Files:** `main.tf` (the resources above), `variables.tf` and `outputs.tf` (the module's inputs and outputs), `versions.tf` (Terraform and provider version pins).
