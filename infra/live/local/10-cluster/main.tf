# Provider layer, local target, step 1: the Kubernetes cluster.
module "cluster" {
  source = "../../../modules/local/kind-cluster"

  name            = "zdp"
  node_image      = "kindest/node:v1.34.0@sha256:7416a61b42b1662ca6ca89f02028ac133a309a2a30ba309614e8ec94d976dc5a"
  workers         = 2
  kubeconfig_path = abspath("${path.root}/../../../../.local/kubeconfig")
}
