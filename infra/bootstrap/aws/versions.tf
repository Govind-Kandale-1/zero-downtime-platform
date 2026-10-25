terraform {
  required_version = ">= 1.14"
  required_providers {
    aws = { source = "hashicorp/aws", version = "6.70.0" }
  }
  # Local state by design (see main.tf). After apply it can be migrated into
  # the bucket it created with `terraform init -migrate-state`.
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { project = "zero-downtime-platform", managed-by = "terraform", layer = "bootstrap" }
  }
}
