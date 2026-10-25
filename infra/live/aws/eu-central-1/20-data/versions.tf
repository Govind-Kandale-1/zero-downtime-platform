terraform {
  required_version = ">= 1.14"
  required_providers {
    aws        = { source = "hashicorp/aws", version = "6.70.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "3.4.0" }
    random     = { source = "hashicorp/random", version = "3.9.1" }
  }
  backend "s3" {
    key          = "eu-central-1/20-data.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}
