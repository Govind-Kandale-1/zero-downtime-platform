terraform {
  required_version = ">= 1.14"
  required_providers {
    helm       = { source = "hashicorp/helm", version = "3.3.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "3.4.0" }
    random     = { source = "hashicorp/random", version = "3.9.1" }
  }
}
