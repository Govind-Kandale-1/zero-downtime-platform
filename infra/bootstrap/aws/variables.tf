variable "region" {
  description = "Home region of the state bucket (EU)."
  type        = string
  default     = "eu-central-1"
}

variable "github_repository" {
  description = "owner/name allowed to assume the deploy role via OIDC."
  type        = string
  default     = "Govind-Kandale-1/zero-downtime-platform"
}
