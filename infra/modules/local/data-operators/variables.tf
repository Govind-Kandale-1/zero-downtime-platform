variable "cnpg_chart_version" {
  description = "cloudnative-pg chart version (config/versions.env CHART_CNPG)."
  type        = string
}

variable "openbao_chart_version" {
  description = "openbao chart version (config/versions.env CHART_OPENBAO)."
  type        = string
}

variable "openbao_root_token" {
  description = "Dev-mode root token. Local target only; never used outside the laptop."
  type        = string
  sensitive   = true
  default     = "root"
}
