# Contract outputs read by 20-data and 30-gitops via terraform_remote_state.
output "kubeconfig_path" {
  value = module.cluster.kubeconfig_path
}

output "endpoint" {
  value = module.cluster.endpoint
}

output "cluster_ca_certificate" {
  value = module.cluster.cluster_ca_certificate
}

output "client_certificate" {
  value     = module.cluster.client_certificate
  sensitive = true
}

output "client_key" {
  value     = module.cluster.client_key
  sensitive = true
}
