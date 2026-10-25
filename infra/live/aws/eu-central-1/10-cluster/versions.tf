terraform {
  required_version = ">= 1.14"
  required_providers {
    aws = { source = "hashicorp/aws", version = "6.70.0" }
  }
  backend "s3" {
    key          = "eu-central-1/10-cluster.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = "eu-central-1"
  default_tags {
    tags = { project = "zero-downtime-platform", managed-by = "terraform", layer = "provider" }
  }
}
