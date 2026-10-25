# Provider layer, local target, step 2: data services and secrets for every
# stack. Providers are configured from 10-cluster's remote-state outputs.

provider "kubernetes" {
  host                   = local.cluster.endpoint
  client_certificate     = local.cluster.client_certificate
  client_key             = local.cluster.client_key
  cluster_ca_certificate = local.cluster.cluster_ca_certificate
}

provider "helm" {
  kubernetes = {
    host                   = local.cluster.endpoint
    client_certificate     = local.cluster.client_certificate
    client_key             = local.cluster.client_key
    cluster_ca_certificate = local.cluster.cluster_ca_certificate
  }
}

provider "kubectl" {
  host                   = local.cluster.endpoint
  client_certificate     = local.cluster.client_certificate
  client_key             = local.cluster.client_key
  cluster_ca_certificate = local.cluster.cluster_ca_certificate
  load_config_file       = false
}

# OpenBao is created in this same root, so the provider must not contact the
# server while configuring (skip_child_token / skip_get_vault_version).
provider "vault" {
  address                = module.operators.openbao_address
  token                  = "root"
  skip_child_token       = true
  skip_get_vault_version = true
}

module "operators" {
  source = "../../../modules/local/data-operators"

  cnpg_chart_version    = local.versions.cnpg_chart
  openbao_chart_version = local.versions.openbao_chart
}

module "stack" {
  source   = "../../../modules/local/stack-data"
  for_each = local.stacks

  stack          = each.value
  postgres_image = local.versions.postgres
  valkey_image   = local.versions.valkey
  exporter_image = local.versions.exporter

  depends_on = [module.operators]
}

output "stacks" {
  description = "Stack name to namespace and secrets path."
  value       = { for k, m in module.stack : k => { namespace = m.namespace, secret_path = m.secret_path } }
}
