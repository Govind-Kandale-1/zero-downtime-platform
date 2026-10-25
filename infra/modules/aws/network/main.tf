# NOT RUN (static validation only). Provider contract: network for EKS + data.
# 3 AZs: public subnets (NLB, NAT), private (nodes, RDS, ElastiCache), intra
# (EKS control-plane ENIs, no internet route). Flow logs on.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = var.name
  cidr = var.cidr
  azs  = var.azs

  public_subnets  = [for i, _ in var.azs : cidrsubnet(var.cidr, 8, i)]
  private_subnets = [for i, _ in var.azs : cidrsubnet(var.cidr, 4, i + 1)]
  intra_subnets   = [for i, _ in var.azs : cidrsubnet(var.cidr, 8, i + 100)]

  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway # true saves ~$65/month per extra AZ in non-prod
  one_nat_gateway_per_az = !var.single_nat_gateway

  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags  = { "kubernetes.io/role/elb" = "1" }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = "1", "karpenter.sh/discovery" = var.name }

  enable_flow_log                      = true
  create_flow_log_cloudwatch_iam_role  = true
  create_flow_log_cloudwatch_log_group = true
}
