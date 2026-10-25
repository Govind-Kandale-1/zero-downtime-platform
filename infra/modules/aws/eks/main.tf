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
