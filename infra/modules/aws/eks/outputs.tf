output "cluster_name" {
  value = module.eks.cluster_name
}

output "endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_ca_certificate" {
  description = "Base64-encoded CA bundle."
  value       = module.eks.cluster_certificate_authority_data
}

output "node_security_group_id" {
  description = "Data services allow ingress only from this group."
  value       = module.eks.node_security_group_id
}

output "karpenter_queue_name" {
  value = module.karpenter.queue_name
}

output "karpenter_node_role_name" {
  value = module.karpenter.node_iam_role_name
}
