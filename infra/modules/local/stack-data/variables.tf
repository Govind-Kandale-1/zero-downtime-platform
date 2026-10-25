variable "stack" {
  description = "Stack descriptor: name, namespace, tier, residency, region, size (tiny|small)."
  type = object({
    name      = string
    namespace = string
    tier      = string
    residency = string
    region    = string
    size      = string
  })
}

variable "postgres_image" {
  description = "CloudNativePG operand image (config/versions.env CNPG_POSTGRES_IMAGE)."
  type        = string
}

variable "valkey_image" {
  type = string
}

variable "exporter_image" {
  description = "redis_exporter image; exposes queue length (LLEN jobs) to Prometheus."
  type        = string
}
