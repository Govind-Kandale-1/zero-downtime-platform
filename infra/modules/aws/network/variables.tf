variable "name" {
  type = string
}

variable "cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "azs" {
  type = list(string)
}

variable "single_nat_gateway" {
  description = "One shared NAT gateway (non-prod) instead of one per AZ (prod: an AZ outage must not cut egress)."
  type        = bool
  default     = false
}
