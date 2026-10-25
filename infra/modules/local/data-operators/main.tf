# Local stand-ins for managed cloud services, shared by every stack:
#   CloudNativePG operator  = RDS (each stack gets a Cluster + Pooler CR)
#   OpenBao (dev mode)      = AWS Secrets Manager
resource "helm_release" "cnpg" {
  name             = "cnpg"
  repository       = "https://cloudnative-pg.github.io/charts"
  chart            = "cloudnative-pg"
  version          = var.cnpg_chart_version
  namespace        = "cnpg-system"
  create_namespace = true
  wait             = true

  values = [yamlencode({
    resources = { requests = { cpu = "50m", memory = "64Mi" }, limits = { memory = "256Mi" } }
  })]
}

resource "helm_release" "openbao" {
  name             = "openbao"
  repository       = "https://openbao.github.io/openbao-helm"
  chart            = "openbao"
  version          = var.openbao_chart_version
  namespace        = "openbao"
  create_namespace = true
  wait             = true

  values = [yamlencode({
    injector = { enabled = false }
    ui       = { enabled = false }
    server = {
      # Dev mode: in-memory, auto-unsealed, KV v2 mounted at secret/. Fine for a
      # laptop; data is lost on pod restart and re-seeded by `terraform apply`.
      dev         = { enabled = true, devRootToken = var.openbao_root_token }
      dataStorage = { enabled = false }
      service     = { type = "NodePort", nodePort = 30200 } # 127.0.0.1:8200 via the kind port mapping
      resources   = { requests = { cpu = "25m", memory = "64Mi" }, limits = { memory = "128Mi" } }
    }
  })]
}

# The token External Secrets Operator uses to read OpenBao (ClusterSecretStore
# platform-secrets, created by the platform layer). On AWS this is replaced by
# EKS Pod Identity: no static credential at all.
resource "kubernetes_namespace_v1" "external_secrets" {
  metadata {
    name = "external-secrets"
  }
}

resource "kubernetes_secret_v1" "openbao_token" {
  metadata {
    name      = "openbao-token"
    namespace = kubernetes_namespace_v1.external_secrets.metadata[0].name
  }
  data = {
    token = var.openbao_root_token
  }
}
