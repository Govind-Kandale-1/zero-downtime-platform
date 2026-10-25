terraform {
  required_version = ">= 1.14"
  required_providers {
    aws     = { source = "hashicorp/aws", version = "6.70.0" }
    helm    = { source = "hashicorp/helm", version = "3.3.0" }
    kubectl = { source = "alekc/kubectl", version = "2.4.1" }
  }
  backend "s3" {
    key          = "eu-central-1/30-gitops.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}
