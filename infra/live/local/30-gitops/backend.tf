# Remote state in zdp-tfstate (connection string from PG_CONN_STR).
terraform {
  backend "pg" {
    schema_name = "local_30_gitops"
  }
}

data "terraform_remote_state" "cluster" {
  backend = "pg"
  config = {
    schema_name = "local_10_cluster"
  }
}
