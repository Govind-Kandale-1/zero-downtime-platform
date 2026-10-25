# One stack's data services: the local implementation of provider-contract
# item 2 (Postgres + PgBouncer + Valkey) and item 3 (connection URLs in the
# secrets manager). See infra/code-review.md.

locals {
  name = var.stack.name
  ns   = var.stack.namespace

  presets = {
    tiny  = { pg_req = "128Mi", pg_lim = "256Mi", pg_shared_buffers = "32MB", vk_req = "32Mi", vk_lim = "64Mi", vk_maxmem = "40mb" }
    small = { pg_req = "256Mi", pg_lim = "512Mi", pg_shared_buffers = "64MB", vk_req = "48Mi", vk_lim = "128Mi", vk_maxmem = "96mb" }
  }
  p = local.presets[var.stack.size]

  # Pod Security "restricted" requires every container to declare these.
  restricted = {
    allowPrivilegeEscalation = false
    capabilities             = { drop = ["ALL"] }
    runAsNonRoot             = true
    seccompProfile           = { type = "RuntimeDefault" }
  }
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = local.ns
    labels = {
      "zdp/stack"                                  = local.name
      "zdp/tier"                                   = var.stack.tier
      "zdp/residency"                              = var.stack.residency
      "zdp/region"                                 = var.stack.region
      "pod-security.kubernetes.io/enforce"         = "restricted"
      "pod-security.kubernetes.io/enforce-version" = "latest"
    }
  }
}

resource "random_password" "app" {
  length  = 24
  special = false
}

# CNPG bootstraps the "app" owner with this password (bootstrap.initdb.secret).
resource "kubernetes_secret_v1" "pg_app" {
  metadata {
    name      = "${local.name}-pg-app"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }
  type = "kubernetes.io/basic-auth"
  data = {
    username = "app"
    password = random_password.app.result
  }
}

resource "kubectl_manifest" "postgres" {
  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"
    metadata   = { name = "${local.name}-pg", namespace = local.ns }
    spec = {
      instances = 1
      imageName = var.postgres_image
      storage   = { size = "1Gi" }
      resources = { requests = { cpu = "50m", memory = local.p.pg_req }, limits = { memory = local.p.pg_lim } }
      postgresql = {
        parameters = { max_connections = "200", shared_buffers = local.p.pg_shared_buffers }
      }
      bootstrap = {
        initdb = { database = "app", owner = "app", secret = { name = kubernetes_secret_v1.pg_app.metadata[0].name } }
      }
    }
  })

  wait_for {
    field {
      key   = "status.phase"
      value = "Cluster in healthy state"
    }
  }
}

# PgBouncer in transaction mode: hundreds of client connections (API pods x
# pool size + workers) multiplexed onto ~40 server connections. Migrations
# bypass it (MIGRATION_DATABASE_URL) because they need session advisory locks.
resource "kubectl_manifest" "pooler" {
  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Pooler"
    metadata   = { name = "pgbouncer", namespace = local.ns }
    spec = {
      cluster   = { name = "${local.name}-pg" }
      instances = 1
      type      = "rw"
      pgbouncer = {
        poolMode   = "transaction"
        parameters = { max_client_conn = "1000", default_pool_size = "40" }
      }
      template = {
        metadata = {}
        spec = {
          containers = [{
            name      = "pgbouncer"
            resources = { requests = { cpu = "20m", memory = "32Mi" }, limits = { memory = "64Mi" } }
          }]
        }
      }
    }
  })
  depends_on = [kubectl_manifest.postgres]
}

resource "kubectl_manifest" "valkey_service" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Service"
    metadata   = { name = "valkey", namespace = local.ns, labels = { "app.kubernetes.io/name" = "valkey" } }
    spec = {
      selector = { "app.kubernetes.io/name" = "valkey" }
      ports = [
        { name = "valkey", port = 6379, targetPort = 6379 },
        { name = "metrics", port = 9121, targetPort = 9121 },
      ]
    }
  })
  depends_on = [kubernetes_namespace_v1.this]
}

# Valkey with AOF persistence so queued jobs survive a restart, and
# maxmemory-policy noeviction so a full queue rejects writes (a visible 503 at
# enqueue) instead of silently evicting jobs.
resource "kubectl_manifest" "valkey" {
  yaml_body = yamlencode({
    apiVersion = "apps/v1"
    kind       = "StatefulSet"
    metadata   = { name = "valkey", namespace = local.ns }
    spec = {
      serviceName = "valkey"
      replicas    = 1
      selector    = { matchLabels = { "app.kubernetes.io/name" = "valkey" } }
      template = {
        metadata = { labels = { "app.kubernetes.io/name" = "valkey" } }
        spec = {
          securityContext = { runAsUser = 999, runAsGroup = 999, fsGroup = 999, runAsNonRoot = true, seccompProfile = { type = "RuntimeDefault" } }
          containers = [
            {
              name  = "valkey"
              image = var.valkey_image
              args = ["valkey-server", "--appendonly", "yes", "--save", "", "--dir", "/data",
              "--maxmemory", local.p.vk_maxmem, "--maxmemory-policy", "noeviction"]
              ports           = [{ name = "valkey", containerPort = 6379 }]
              readinessProbe  = { exec = { command = ["valkey-cli", "ping"] }, periodSeconds = 5 }
              livenessProbe   = { tcpSocket = { port = 6379 }, periodSeconds = 10 }
              resources       = { requests = { cpu = "20m", memory = local.p.vk_req }, limits = { memory = local.p.vk_lim } }
              securityContext = local.restricted
              volumeMounts    = [{ name = "data", mountPath = "/data" }]
            },
            {
              name            = "exporter"
              image           = var.exporter_image
              env             = [{ name = "REDIS_ADDR", value = "redis://localhost:6379" }, { name = "REDIS_EXPORTER_CHECK_KEYS", value = "jobs" }]
              ports           = [{ name = "metrics", containerPort = 9121 }]
              resources       = { requests = { cpu = "10m", memory = "16Mi" }, limits = { memory = "32Mi" } }
              securityContext = local.restricted
            },
          ]
        }
      }
      volumeClaimTemplates = [{
        metadata = { name = "data" }
        spec     = { accessModes = ["ReadWriteOnce"], resources = { requests = { storage = "1Gi" } } }
      }]
    }
  })
  depends_on = [kubectl_manifest.valkey_service]
}

# Backup storage for the chart's pg_dump CronJob and PreSync hook. It lives in
# the provider layer (like the database) so it exists before Argo CD's first
# sync and survives every sync; on AWS, RDS automated backups replace it.
resource "kubernetes_persistent_volume_claim_v1" "backups" {
  metadata {
    name      = "pg-backups"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = { storage = "1Gi" }
    }
  }
  wait_until_bound = false # local-path binds on first consumer
}

# Contract item 3: the app reads these three keys via External Secrets.
resource "vault_kv_secret_v2" "app" {
  mount = "secret"
  name  = "stacks/${local.name}/app"
  data_json = jsonencode({
    DATABASE_URL           = "postgres://app:${random_password.app.result}@pgbouncer.${local.ns}.svc:5432/app?sslmode=disable"
    MIGRATION_DATABASE_URL = "postgres://app:${random_password.app.result}@${local.name}-pg-rw.${local.ns}.svc:5432/app?sslmode=disable"
    REDIS_URL              = "redis://valkey.${local.ns}.svc:6379/0"
  })
}
