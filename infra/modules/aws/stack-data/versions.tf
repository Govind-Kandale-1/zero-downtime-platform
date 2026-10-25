terraform {
  required_version = ">= 1.14"
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = ">= 6.0"
      configuration_aliases = [aws.backup]
    }
    kubernetes = { source = "hashicorp/kubernetes", version = ">= 3.0" }
    random     = { source = "hashicorp/random", version = ">= 3.0" }
  }
}
