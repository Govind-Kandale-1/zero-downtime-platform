output "namespace" {
  value = kubernetes_namespace_v1.this.metadata[0].name
}

output "secret_path" {
  description = "Secrets-manager path holding DATABASE_URL, MIGRATION_DATABASE_URL, REDIS_URL."
  value       = "secret/stacks/${local.name}/app"
}
