# NOT RUN (static validation only). AWS provider layer, step 1: EKS + Karpenter.
variable "state_bucket" {
  description = "Bootstrap output state_bucket."
  type        = string
}

data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "eu-central-1/05-network.tfstate"
    region = "eu-central-1"
  }
}

module "eks" {
  source = "../../../../modules/aws/eks"

  name               = "zdp-euc1"
  kubernetes_version = "1.34"
  vpc_id             = data.terraform_remote_state.network.outputs.vpc_id
  private_subnet_ids = data.terraform_remote_state.network.outputs.private_subnet_ids
  intra_subnet_ids   = data.terraform_remote_state.network.outputs.intra_subnet_ids
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "endpoint" {
  value = module.eks.endpoint
}

output "cluster_ca_certificate" {
  value = module.eks.cluster_ca_certificate
}

output "node_security_group_id" {
  value = module.eks.node_security_group_id
}
