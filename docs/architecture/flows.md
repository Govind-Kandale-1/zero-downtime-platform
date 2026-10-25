# How things flow

**Label:** RUN-LOCAL. Every flow below ran on the local platform (the evidence links show where), except the AWS notes, which are NOT RUN.

## 1. A release

From a merge on `main` to every stack running the new version. Evidence: `evidence/00-bringup`, `evidence/01-deploy-under-load`, `evidence/02-auto-rollback`.

```mermaid
sequenceDiagram
  autonumber
  participant Dev as Developer
  participant GH as GitHub (repo + Actions)
  participant GHCR as GHCR
  participant Argo as Argo CD
  participant RO as Argo Rollouts
  participant Prom as Prometheus
  participant Gate as zdp-runner (gate.sh)
  Dev->>GH: merge a change under app/ or charts/
  GH->>GH: build the image once, Trivy scan, SBOM, cosign sign
  GH->>GHCR: push image (by digest) and chart 0.1.N
  GH->>GH: bump-release.sh commits gitops/releases/dev.yaml (digest + chart)
  Argo->>GH: poll (60 s) and see the new release file
  Argo->>Argo: PreSync hook: pg_dump to pg-backups
  Argo->>RO: apply the new Rollout spec
  RO->>RO: canary 10 percent, then 25, then 50, with background analysis
  RO->>Prom: success rate, p95, request count of the canary only
  alt analysis passes
    RO->>RO: promote to 100 percent, canary becomes stable
  else analysis fails
    RO->>RO: abort, all traffic back to stable
  end
  Gate->>Argo: read: Synced and Healthy at chart 0.1.N?
  Gate->>Prom: read after 3 min soak: 5xx under 0.5 percent, p95 under 400 ms, oldest job under 120 s
  alt gate passes
    Gate-->>GH: GATE PASS, the next stage is promoted
  else gate fails
    Gate-->>GH: GATE FAIL, every later stage is skipped
  end
  Note over GH: dev, then staging, then human approval, then prod (ring 0), ring 1 (acme), ring 2 (globex)
```

**Key properties:**
- The cluster is never pushed to. CI writes Git, and Argo CD pulls.
- The digest checked by the gate is the digest built in step 2.
- A failure anywhere stops the fleet: evidence 02 shows a bad release aborted in dev, with every later stage skipped.

## 2. A request

```mermaid
flowchart LR
  C["Client<br/>prod.localtest.me"] -->|":80"| NP["NodePort 30080<br/>(kind node)"]
  NP --> T["Traefik<br/>(ns traefik)"]
  T -->|"IngressRoute api<br/>host match"| W["TraefikService api<br/>weights e.g. 90/10"]
  W -->|stable share| S1["Service api-stable"]
  W -->|canary share| S2["Service api-canary"]
  S1 --> P1["api pods (stable)"]
  S2 --> P2["api pods (canary)"]
  P1 & P2 -->|"DATABASE_URL"| B["PgBouncer<br/>(transaction mode)"]
  B --> PG[("Postgres")]
  T -.->|"metrics per service:<br/>requests, codes, latency"| M[("Prometheus")]
```

- **Traefik's metrics are the source of truth.** The SLIs, the canary analysis, the promotion gate and the API autoscaler all read the same counters, measured where users enter. The app needs no instrumentation for any of them.
- **Each API pod serves at most 8 requests at once.** Extra requests queue inside the pod. That's the stand-in's capacity model: about 180 req/s per pod.

## 3. A job

```mermaid
sequenceDiagram
  participant API as api pod
  participant V as Valkey
  participant W as worker pod
  participant R as reaper (in each worker, one at a time under a lock)
  API->>V: LPUSH jobs, INCR jobs:enqueued_total
  API-->>API: return 202 with the job id
  W->>V: BLMOVE jobs to jobs:processing:(pod name)
  loop while the job runs (up to 60 s)
    W->>V: heartbeat every 10 s (expires after 30 s)
  end
  W->>V: LREM from the processing list, INCR jobs:done_total
  R->>V: every 15 s, find processing lists whose heartbeat expired
  R->>V: move their jobs back to jobs (requeue)
```

- **Delivery is at least once.** A worker killed mid-job never loses it: the reaper requeues it.
- **Jobs must be idempotent.** A job can run twice, and so can a client retry after a timeout (evidence 03).
- **The accounting invariant** `enqueued_total == done_total + failed_total` held in every load test.

## 4. A scale-up

```mermaid
flowchart LR
  T["Traefik metrics<br/>req/s per stack"] --> P[("Prometheus")]
  A["api pods<br/>http_inflight_requests"] --> P
  MS["metrics-server<br/>pod CPU"] --> K
  P --> K["KEDA metrics server"]
  V[("Valkey<br/>LLEN jobs")] -->|"address from Secret app-env<br/>(TriggerAuthentication)"| K
  K --> H["HPA (sync every 15 s)<br/>replicas = max of the triggers"]
  H --> RA["Rollout api"]
  H --> RW["Rollout worker"]
  RA & RW -.->|"AWS: pods pending"| KP["Karpenter<br/>adds nodes"]
```

| Trigger | Target | Role |
|---|---|---|
| API req/s per pod | 126 (70% of the measured capacity) | steady-state sizing |
| API requests in flight per pod | 5.6 (70% of the limit of 8) | reacts to saturation, where req/s stops growing |
| API CPU | 100% of 200m | safety net: fires after the others |
| Worker queue length per worker | 5 | job load |

- **Scale-up:** the larger of +100% and +8 pods every 15 s (3 → 11 → 21).
- **Scale-down:** after a 5-minute window, at most −20% per minute.
- **Evidence 03** shows why the in-flight trigger exists, and why the headroom rule is the next change.

## 5. A secret

```mermaid
sequenceDiagram
  participant TF as Terraform (20-data)
  participant OB as OpenBao
  participant ESO as External Secrets
  participant K as Secret app-env
  participant Pod as api and worker pods
  participant KEDA as KEDA
  TF->>OB: write secret/stacks/(stack)/app: DATABASE_URL, MIGRATION_DATABASE_URL, REDIS_URL
  ESO->>OB: read (every minute) through ClusterSecretStore platform-secrets
  ESO->>K: write the 3 keys plus QUEUE_ADDRESS derived from REDIS_URL
  Pod->>K: envFrom at start
  KEDA->>K: read QUEUE_ADDRESS (TriggerAuthentication worker-queue)
```

On AWS, the store is Secrets Manager and External Secrets authenticates with Pod Identity. The ExternalSecret, the Secret and the chart are identical.

## 6. A backup and a restore drill

```mermaid
sequenceDiagram
  participant CJ as CronJob backup (hourly)
  participant HK as Job presync-backup (before every sync)
  participant PG as Postgres
  participant BV as volume pg-backups
  participant RT as scripts/restore-test.sh
  CJ->>PG: pg_dump
  CJ->>BV: write backup-(time).dump and .counts (rows + md5)
  HK->>PG: pg_dump
  HK->>BV: write presync-(time).dump and .counts
  RT->>RT: create a scratch Postgres cluster restore-test
  RT->>BV: read the newest dump (read-only)
  RT->>RT: pg_restore into the scratch cluster, recompute rows + md5
  RT-->>RT: RESTORE PASS if they match .counts, then delete the scratch cluster
```

The drill is non-destructive and timed: RTO 34–43 s for the stand-in's data (evidence 04). Backup jobs time out after 15 minutes, so a hung job can't block the schedule, and `ZdpBackupStale` alerts if no backup has succeeded for 2 hours.

## 7. A shutdown (rollout, scale-in or node drain)

```mermaid
sequenceDiagram
  participant K as Kubernetes
  participant T as Traefik
  participant P as api pod
  participant W as worker pod
  K->>T: pod leaves the endpoints (starts immediately)
  K->>P: preStop: sleep 5 s, so Traefik stops routing to it first
  K->>P: SIGTERM
  P->>P: /readyz returns 503, finish in-flight requests, exit (grace 30 s)
  K->>W: SIGTERM
  W->>W: stop claiming jobs, finish the current job (up to 60 s), exit (grace 90 s)
  Note over K,W: a pod still running at the end of its grace gets SIGKILL, and the reaper requeues its job
```

Evidence: `scripts/tests/image_smoke_test.sh` shows `docker stop` exiting cleanly (exit 0) in under 30 s. Evidence 01 shows a whole prod rollout under 150 req/s with zero failed requests.
