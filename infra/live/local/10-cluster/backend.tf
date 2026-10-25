# Remote state in the zdp-tfstate Postgres container (scripts/state-up.sh).
# The connection string comes from PG_CONN_STR (.local/tfstate.env) so no
# credential is committed. The pg backend locks with advisory locks.
terraform {
  backend "pg" {
    schema_name = "local_10_cluster"
  }
}
