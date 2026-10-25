# NOT RUN (static validation only). AWS provider layer, step 3: hand over to
# GitOps - identical to the local root except for auth and the cluster folder.

variable "state_bucket" {
  type = string
}

data "terraform_remote_state" "cluster" {
  backend = "s3"
  config  = { bucket = var.state_bucket, key = "eu-central-1/10-cluster.tfstate", region = "eu-central-1" }
}

locals {
  cluster   = data.terraform_remote_state.cluster.outputs
  repo_root = abspath("${path.root}/../../../../..")
  exec_args = ["eks", "get-token", "--cluster-name", local.cluster.cluster_name, "--region", "eu-central-1"]
}

provider "aws" {
  region = "eu-central-1"
}

provider "helm" {
  kubernetes = {
    host                   = local.cluster.endpoint
    cluster_ca_certificate = base64decode(local.cluster.cluster_ca_certificate)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = local.exec_args
    }
  }
}

provider "kubectl" {
  host                   = local.cluster.endpoint
  cluster_ca_certificate = base64decode(local.cluster.cluster_ca_certificate)
  load_config_file       = false
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = local.exec_args
  }
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.11.1"
  namespace        = "argocd"
  create_namespace = true
  wait             = true
  values           = [file("${local.repo_root}/infra/live/local/30-gitops/values-argocd.yaml")]
}

resource "kubectl_manifest" "root" {
  yaml_body  = file("${local.repo_root}/gitops/clusters/aws-eu-central-1/root.yaml")
  depends_on = [helm_release.argocd]
}
