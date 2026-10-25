# Remote state in zdp-tfstate (connection string from PG_CONN_STR).
terraform {
  backend "pg" {
    schema_name = "local_20_data"
  }
}

# Cluster credentials published by 10-cluster.
data "terraform_remote_state" "cluster" {
  backend = "pg"
  config = {
    schema_name = "local_10_cluster"
  }
}
