# NOT RUN (static validation only). Provider contract item 1: the cluster.
# Private API endpoint only (CI never talks to the cluster - GitOps pulls;
# Terraform runs from inside the VPC, e.g. an in-cluster runner).
# A small managed node group runs system pods + Karpenter; Karpenter launches
# everything else on demand (node join ~60-90 s), absorbed by overprovisioning.
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.29.0"

  name               = var.name
  kubernetes_version = var.kubernetes_version

  vpc_id                   = var.vpc_id
  subnet_ids               = var.private_subnet_ids
  control_plane_subnet_ids = var.intra_subnet_ids

  endpoint_public_access  = false
  endpoint_private_access = true

  enable_cluster_creator_admin_permissions = true

  addons = {
    coredns    = {}
    kube-proxy = {}
    # enableNetworkPolicy starts the VPC CNI's policy agent: without it EKS
    # accepts NetworkPolicy objects but enforces nothing, and the chart's
    # default-deny would be silently void (enforcement is verified locally:
    # evidence/00-bringup/networkpolicy-check.txt).
    vpc-cni = {
      before_compute       = true
      configuration_values = jsonencode({ enableNetworkPolicy = "true" })
    }
    eks-pod-identity-agent = { before_compute = true }
    aws-ebs-csi-driver     = {}
  }

  eks_managed_node_groups = {
    system = {
      instance_types = ["m7i.large"]
      min_size       = 2
      max_size       = 3
      desired_size   = 2
      labels         = { "zdp/pool" = "system" }
    }
  }

  node_security_group_tags = { "karpenter.sh/discovery" = var.name }
}

# Karpenter's IAM role, interruption queue and Pod Identity association. The
# NodePool/EC2NodeClass objects are platform-layer manifests
# (gitops/platform/aws/karpenter.yaml).
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.29.0"

  cluster_name                    = module.eks.cluster_name
  namespace                       = "kube-system"
  create_pod_identity_association = true

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }
}

# Pod Identity for the other controllers that call AWS APIs (Karpenter's is
# created by its module above). Without these, External Secrets can't read
# Secrets Manager and the EBS CSI driver can't create volumes.
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

# EBS CSI driver: the AWS-managed policy for volume lifecycle.
resource "aws_iam_role" "ebs_csi" {
  name_prefix        = "${var.name}-ebs-csi-"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi.arn
}

# External Secrets: read-only, and only the per-stack contract secrets
# (stacks/<stack>/app), decrypted through Secrets Manager only.
data "aws_iam_policy_document" "external_secrets" {
  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = ["arn:aws:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:stacks/*"]
  }
  statement {
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${data.aws_region.current.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "external_secrets" {
  name_prefix        = "${var.name}-eso-"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy" "external_secrets" {
  role   = aws_iam_role.external_secrets.id
  policy = data.aws_iam_policy_document.external_secrets.json
}

resource "aws_eks_pod_identity_association" "external_secrets" {
  cluster_name    = module.eks.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.external_secrets.arn
}
