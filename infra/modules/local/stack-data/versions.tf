terraform {
  required_version = ">= 1.14"
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "3.4.0" }
    kubectl    = { source = "alekc/kubectl", version = "2.4.1" }
    vault      = { source = "hashicorp/vault", version = "5.13.0" }
    random     = { source = "hashicorp/random", version = "3.9.1" }
  }
}
