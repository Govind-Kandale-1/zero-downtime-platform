# Provider layer, local target, step 3: hand over to GitOps. Terraform installs
# Argo CD and one root Application; from then on everything in-cluster
# (platform layer, app stacks, tenants) is reconciled from Git by Argo CD.

locals {
  cluster      = data.terraform_remote_state.cluster.outputs
  repo_root    = abspath("${path.root}/../../../..")
  argocd_chart = "10.11.1" # config/versions.env CHART_ARGOCD
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

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = local.argocd_chart
  namespace        = "argocd"
  create_namespace = true
  wait             = true
  timeout          = 600

  values = [file("${path.module}/values-argocd.yaml")]
}

# The root Application is the same manifest that lives in Git, so its
# definition is versioned and reviewable like everything else.
resource "kubectl_manifest" "root" {
  yaml_body  = file("${local.repo_root}/gitops/clusters/local/root.yaml")
  depends_on = [helm_release.argocd]
}
