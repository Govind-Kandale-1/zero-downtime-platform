variable "stack" {
  description = "Stack descriptor (same shape as the local module)."
  type = object({
    name      = string
    namespace = string
    tier      = string
    residency = string
    region    = string
    size      = string
  })
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "node_security_group_id" {
  type = string
}

variable "kms_key_arn" {
  description = "Regional CMK for RDS, ElastiCache, Performance Insights and Secrets Manager."
  type        = string
}

variable "backup_kms_key_arn" {
  description = "CMK in the backup-replica region (same residency zone)."
  type        = string
}

variable "postgres_major" {
  type    = string
  default = "18"
}

variable "valkey_version" {
  type    = string
  default = "8.1"
}

variable "pgbouncer_image" {
  type    = string
  default = "edoburu/pgbouncer:v1.26.1-p0"
}
