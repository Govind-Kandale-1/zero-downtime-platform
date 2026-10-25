# NOT RUN (static validation only). AWS provider layer, step 0: network.
module "network" {
  source = "../../../../modules/aws/network"

  name               = "zdp-euc1"
  cidr               = "10.20.0.0/16"
  azs                = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]
  single_nat_gateway = false
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "private_subnet_ids" {
  value = module.network.private_subnet_ids
}

output "intra_subnet_ids" {
  value = module.network.intra_subnet_ids
}
