# The local "cloud": a kind cluster. Host ports map onto NodePorts on the
# control-plane node, so the ingress answers on http://*.localtest.me and the
# local secrets manager (OpenBao) on 127.0.0.1:8200 for Terraform.
resource "kind_cluster" "this" {
  name            = var.name
  node_image      = var.node_image
  wait_for_ready  = true
  kubeconfig_path = var.kubeconfig_path

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role = "control-plane"

      # Traefik web / websecure NodePorts → host 80 / 443.
      extra_port_mappings {
        container_port = 30080
        host_port      = 80
        listen_address = "127.0.0.1"
      }
      extra_port_mappings {
        container_port = 30443
        host_port      = 443
        listen_address = "127.0.0.1"
      }
      # OpenBao NodePort → host 8200, used by the Terraform vault provider.
      extra_port_mappings {
        container_port = 30200
        host_port      = 8200
        listen_address = "127.0.0.1"
      }
    }

    dynamic "node" {
      for_each = range(var.workers)
      content {
        role = "worker"
      }
    }
  }
}
