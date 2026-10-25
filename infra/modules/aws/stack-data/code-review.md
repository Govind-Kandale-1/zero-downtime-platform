# infra/modules/aws/stack-data/ — code review

**Label: NOT RUN (static validation only)**

**Purpose:** the AWS implementation of the **same provider contract** as `modules/local/stack-data`, one per stack. The app layer can't tell the two apart.

| Resource | What it is |
|---|---|
| Security groups | Postgres 5432 and Valkey 6379, reachable **only from the EKS node security group** |
| `aws_db_instance` | PostgreSQL 18, **Multi-AZ** (synchronous standby), gp3 storage that autoscales from 50 to 500 GB, encrypted with the regional CMK. **14-day PITR**, deletion protection, a final snapshot, Performance Insights, IAM auth, `rds.force_ssl`, `max_connections=200`. Instance class by size: tiny `db.t4g.medium`, small `db.r7g.large`, medium `db.r7g.xlarge`. |
| `aws_db_instance_automated_backups_replication` | PITR backups replicated through the `aws.backup` provider to the **second region of the same residency zone** (EU → eu-west-1) |
| `aws_elasticache_replication_group` | **Valkey** 8.1: 2 nodes, automatic failover, Multi-AZ, at-rest and in-transit encryption (so `rediss://`), 7 snapshots |
| `aws_secretsmanager_secret(_version)` | `stacks/<stack>/app`: `DATABASE_URL` (via PgBouncer), `MIGRATION_DATABASE_URL` (direct to RDS, `sslmode=require`), `REDIS_URL` (`rediss://`) |
| Namespace + PgBouncer | A namespace labelled for residency, with Pod Security `restricted`. A 2-replica PgBouncer Deployment (`edoburu/pgbouncer` v1.26.1, transaction mode, `max_client_conn` 1000, `default_pool_size` 40, TLS to RDS) plus Service `pgbouncer`, the same DNS name as locally. |

**Key decisions:**
- **In-cluster PgBouncer rather than RDS Proxy:** portable, and RDS Proxy *pins* connections that use session state (ADR-007).
- **ElastiCache for Valkey:** the licence is clean, and it costs about 20% less than Redis OSS (ADR-008).
- **Backup replication stays inside the residency zone.** It's driven by a provider alias the root chooses from the tenant's residency.

**Not wired yet** (would be needed to run it): a TriggerAuthentication for KEDA's Redis scaler with TLS, because ElastiCache has in-transit encryption.
