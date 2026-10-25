# NOT RUN (static validation only). AWS provider layer, step 2: data services
# for every stack that lives in THIS region. Same stack files as the local
# target; the region filter is what keeps an EU tenant's data in the EU (the
# conftest policy already guarantees an EU tenant names an EU region).

variable "state_bucket" {
  type = string
}

locals {
  region        = "eu-central-1"
  backup_region = "eu-west-1" # PITR replica stays inside the EU
  repo_root     = abspath("${path.root}/../../../../..")

  env_stacks = {
    for f in fileset("${local.repo_root}/gitops/stacks", "*.yaml") :
    trimsuffix(f, ".yaml") => yamldecode(file("${local.repo_root}/gitops/stacks/${f}")).stack
  }
  tenants = {
    for f in fileset("${local.repo_root}/tenants", "*.yaml") :
    trimsuffix(f, ".yaml") => yamldecode(file("${local.repo_root}/tenants/${f}"))
  }
  all = merge(
    { for k, s in local.env_stacks : k => { name = s.name, namespace = s.namespace, tier = s.tier, residency = s.residency, region = s.region, size = s.size } },
    { for k, t in local.tenants : k => { name = t.name, namespace = "tenant-${t.name}", tier = "dedicated", residency = t.residency, region = t.region, size = t.size } if t.tier == "dedicated" },
  )
  stacks = { for k, s in local.all : k => s if s.region == local.region }

  cluster = data.terraform_remote_state.cluster.outputs
  network = data.terraform_remote_state.network.outputs
}

data "terraform_remote_state" "network" {
  backend = "s3"
  config  = { bucket = var.state_bucket, key = "eu-central-1/05-network.tfstate", region = "eu-central-1" }
}

data "terraform_remote_state" "cluster" {
  backend = "s3"
  config  = { bucket = var.state_bucket, key = "eu-central-1/10-cluster.tfstate", region = "eu-central-1" }
}

provider "aws" {
  region = local.region
  default_tags {
    tags = { project = "zero-downtime-platform", managed-by = "terraform", layer = "provider" }
  }
}

provider "aws" {
  alias  = "backup"
  region = local.backup_region
  default_tags {
    tags = { project = "zero-downtime-platform", managed-by = "terraform", layer = "provider-backup" }
  }
}

provider "kubernetes" {
  host                   = local.cluster.endpoint
  cluster_ca_certificate = base64decode(local.cluster.cluster_ca_certificate)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.cluster.cluster_name, "--region", local.region]
  }
}

resource "aws_kms_key" "data" {
  description         = "zdp data services (${local.region})"
  enable_key_rotation = true
}

resource "aws_kms_key" "backup" {
  provider            = aws.backup
  description         = "zdp backup replicas (${local.backup_region})"
  enable_key_rotation = true
}

module "stack" {
  source   = "../../../../modules/aws/stack-data"
  for_each = local.stacks
  providers = {
    aws        = aws
    aws.backup = aws.backup
  }

  stack                  = each.value
  vpc_id                 = local.network.vpc_id
  private_subnet_ids     = local.network.private_subnet_ids
  node_security_group_id = local.cluster.node_security_group_id
  kms_key_arn            = aws_kms_key.data.arn
  backup_kms_key_arn     = aws_kms_key.backup.arn
}

output "stacks" {
  value = { for k, m in module.stack : k => m.secret_name }
}
