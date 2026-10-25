# NOT RUN (static validation only). One stack's data services on AWS - the
# same provider contract as infra/modules/local/stack-data:
#   RDS PostgreSQL Multi-AZ  + in-cluster PgBouncer (transaction mode)
#   ElastiCache for Valkey   (Multi-AZ replication group, TLS)
#   Secrets Manager          stacks/<stack>/app = DATABASE_URL,
#                            MIGRATION_DATABASE_URL, REDIS_URL
# Automated backups (PITR) are replicated to a second region INSIDE the
# tenant's residency zone (EU stays in the EU).

locals {
  name = "zdp-${var.stack.name}"
  ns   = var.stack.namespace

  sizes = {
    tiny   = { db = "db.t4g.medium", cache = "cache.t4g.small" }
    small  = { db = "db.r7g.large", cache = "cache.m7g.large" }
    medium = { db = "db.r7g.xlarge", cache = "cache.m7g.xlarge" }
  }
  s = local.sizes[var.stack.size]
}

resource "random_password" "app" {
  length  = 32
  special = false
}

# --- network access: only from cluster nodes -------------------------------
resource "aws_security_group" "db" {
  name_prefix = "${local.name}-db-"
  description = "Postgres for ${var.stack.name}: from EKS nodes only"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "db_from_nodes" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = var.node_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PgBouncer and migrations from EKS nodes"
}

resource "aws_security_group" "cache" {
  name_prefix = "${local.name}-cache-"
  description = "Valkey for ${var.stack.name}: from EKS nodes only"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "cache_from_nodes" {
  security_group_id            = aws_security_group.cache.id
  referenced_security_group_id = var.node_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  description                  = "Queue access from EKS nodes"
}

# --- PostgreSQL --------------------------------------------------------------
resource "aws_db_subnet_group" "this" {
  name       = local.name
  subnet_ids = var.private_subnet_ids
}

resource "aws_db_parameter_group" "this" {
  name   = local.name
  family = "postgres${var.postgres_major}"

  parameter {
    name         = "max_connections"
    value        = "200" # PgBouncer multiplexes ~640 clients onto ~40 server connections
    apply_method = "pending-reboot"
  }
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
}

resource "aws_db_instance" "this" {
  identifier     = local.name
  engine         = "postgres"
  engine_version = var.postgres_major
  instance_class = local.s.db

  db_name  = "app"
  username = "app"
  password = random_password.app.result

  multi_az               = true # 99.9/99.95 SLOs: synchronous standby in another AZ
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  parameter_group_name   = aws_db_parameter_group.this.name

  allocated_storage     = 50
  max_allocated_storage = 500
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = var.kms_key_arn

  backup_retention_period   = 14 # PITR window
  copy_tags_to_snapshot     = true
  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.name}-final"

  performance_insights_enabled        = true
  performance_insights_kms_key_id     = var.kms_key_arn
  iam_database_authentication_enabled = true
  auto_minor_version_upgrade          = true
  enabled_cloudwatch_logs_exports     = ["postgresql", "upgrade"]
}

# PITR backups replicated to the residency zone's second region.
resource "aws_db_instance_automated_backups_replication" "this" {
  provider               = aws.backup
  source_db_instance_arn = aws_db_instance.this.arn
  retention_period       = 7
  kms_key_id             = var.backup_kms_key_arn
}

# --- Valkey ------------------------------------------------------------------
resource "aws_elasticache_subnet_group" "this" {
  name       = local.name
  subnet_ids = var.private_subnet_ids
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = local.name
  description          = "Job queue for ${var.stack.name}"
  engine               = "valkey"
  engine_version       = var.valkey_version
  node_type            = local.s.cache

  num_cache_clusters         = 2
  automatic_failover_enabled = true
  multi_az_enabled           = true

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.cache.id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  kms_key_id                 = var.kms_key_arn
  snapshot_retention_limit   = 7
}

# --- Secrets Manager (contract item 3) ----------------------------------------
resource "aws_secretsmanager_secret" "app" {
  name                    = "stacks/${var.stack.name}/app"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id = aws_secretsmanager_secret.app.id
  secret_string = jsonencode({
    DATABASE_URL           = "postgres://app:${random_password.app.result}@pgbouncer.${local.ns}.svc:5432/app?sslmode=disable"
    MIGRATION_DATABASE_URL = "postgres://app:${random_password.app.result}@${aws_db_instance.this.address}:5432/app?sslmode=require"
    REDIS_URL              = "rediss://${aws_elasticache_replication_group.this.primary_endpoint_address}:6379/0"
  })
}

# --- In-cluster: namespace + PgBouncer -----------------------------------------
resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = local.ns
    labels = {
      "zdp/stack"                          = var.stack.name
      "zdp/tier"                           = var.stack.tier
      "zdp/residency"                      = var.stack.residency
      "zdp/region"                         = var.stack.region
      "pod-security.kubernetes.io/enforce" = "restricted"
    }
  }
}

resource "kubernetes_secret_v1" "pgbouncer" {
  metadata {
    name      = "pgbouncer"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }
  data = {
    DATABASE_URL = "postgres://app:${random_password.app.result}@${aws_db_instance.this.address}:5432/app"
  }
}

resource "kubernetes_deployment_v1" "pgbouncer" {
  metadata {
    name      = "pgbouncer"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }
  spec {
    replicas = 2
    selector {
      match_labels = { "app.kubernetes.io/name" = "pgbouncer" }
    }
    template {
      metadata {
        labels = { "app.kubernetes.io/name" = "pgbouncer" }
      }
      spec {
        security_context {
          run_as_non_root = true
          run_as_user     = 70
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }
        container {
          name  = "pgbouncer"
          image = var.pgbouncer_image
          env_from {
            secret_ref {
              name = kubernetes_secret_v1.pgbouncer.metadata[0].name
            }
          }
          env {
            name  = "POOL_MODE"
            value = "transaction"
          }
          env {
            name  = "MAX_CLIENT_CONN"
            value = "1000"
          }
          env {
            name  = "DEFAULT_POOL_SIZE"
            value = "40"
          }
          env {
            name  = "SERVER_TLS_SSLMODE"
            value = "require"
          }
          env {
            name  = "AUTH_TYPE"
            value = "scram-sha-256"
          }
          port {
            container_port = 5432
          }
          resources {
            requests = { cpu = "50m", memory = "32Mi" }
            limits   = { memory = "128Mi" }
          }
          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "pgbouncer" {
  metadata {
    name      = "pgbouncer"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }
  spec {
    selector = { "app.kubernetes.io/name" = "pgbouncer" }
    port {
      port        = 5432
      target_port = 5432
    }
  }
}
