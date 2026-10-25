# The stack list is derived from the same files Argo CD reads, so adding a
# tenant is one file in one PR: Terraform creates its data services from it and
# an ApplicationSet creates its app release from it.
locals {
  repo_root = abspath("${path.root}/../../../..")

  # Environment stacks: gitops/stacks/<name>.yaml, `stack:` block.
  env_stacks = {
    for f in fileset("${local.repo_root}/gitops/stacks", "*.yaml") :
    trimsuffix(f, ".yaml") => yamldecode(file("${local.repo_root}/gitops/stacks/${f}")).stack
  }

  # Dedicated tenants: tenants/<name>.yaml with tier: dedicated. Shared tenants
  # have no data services of their own (they ride the prod stack).
  tenants = {
    for f in fileset("${local.repo_root}/tenants", "*.yaml") :
    trimsuffix(f, ".yaml") => yamldecode(file("${local.repo_root}/tenants/${f}"))
  }
  dedicated = {
    for k, t in local.tenants : k => {
      name      = t.name
      namespace = "tenant-${t.name}"
      tier      = "dedicated"
      residency = t.residency
      region    = t.region
      size      = t.size
    } if t.tier == "dedicated"
  }

  stacks = merge(
    { for k, s in local.env_stacks : k => {
      name      = s.name
      namespace = s.namespace
      tier      = s.tier
      residency = s.residency
      region    = s.region
      size      = s.size
    } },
    local.dedicated,
  )

  cluster = data.terraform_remote_state.cluster.outputs

  # Mirrors config/versions.env (Terraform cannot read env files natively).
  versions = {
    cnpg_chart    = "0.29.1"
    openbao_chart = "0.30.4"
    postgres      = "ghcr.io/cloudnative-pg/postgresql:18.6"
    valkey        = "valkey/valkey:9.1.2-alpine"
    exporter      = "oliver006/redis_exporter:v1.96.0"
  }
}
