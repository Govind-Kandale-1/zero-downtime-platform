output "secret_name" {
  description = "Secrets Manager name holding the three connection URLs."
  value       = aws_secretsmanager_secret.app.name
}

output "db_address" {
  value = aws_db_instance.this.address
}

output "cache_primary_endpoint" {
  value = aws_elasticache_replication_group.this.primary_endpoint_address
}
