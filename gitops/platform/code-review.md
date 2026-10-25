# gitops/platform/ — code review

**Purpose:** the **platform layer**, the same everywhere except for small per-provider values overlays. Installed by the Applications in `gitops/clusters/<cluster>/apps/`.

| Path | What it holds |
|---|---|
| `values/local/` | Helm values for the local cluster (see that folder's `code-review.md`) |
| `values/aws/` | Values for the AWS cluster: NLB service, Pod Identity secret store, gp3, Karpenter. NOT RUN |
| `config/` | Plain manifests synced by `platform-config`: the secret store, UI ingress routes, priority classes |
| `synthetic-traffic/` | The always-on traffic generator that keeps canary analysis conclusive |

**Components and why:**

| Component | Version | Role |
|---|---|---|
| Traefik | chart 42.1.3 (v3.7) | Ingress. **Edge metrics are the SLIs and canary signal**, because the app is a black box. Weighted `TraefikService` objects carry canary traffic splits. |
| Argo Rollouts | chart 2.43.8 (v1.10.1) | Canary steps, AnalysisRuns against Prometheus, automatic abort. **Verified: Traefik routing is native in v1.10** (`trafficRouting.traefik.weightedTraefikServiceName`), no plugin needed. |
| KEDA | 2.21.0 | Scales the API on Prometheus RPS and the worker on Valkey list length |
| External Secrets | 2.14.0 | Secrets manager → per-stack Secrets (ADR-009) |
| kube-prometheus-stack | 92.13.1 | Prometheus (12 h retention, 15 s scrapes), Alertmanager, Grafana, kube-state-metrics |
| metrics-server | 3.14.0 | `kubectl top`, CPU triggers |

**Sync waves** (Argo CD waits for each wave to be Healthy before the next, using the Application health check configured in `30-gitops`):
- `-2`: Prometheus CRDs.
- `-1`: Traefik, Rollouts, KEDA, ESO, metrics-server.
- `0`: kube-prometheus-stack, platform-config. These need the CRDs and the ESO webhook from earlier waves.
- `1`: synthetic traffic and the stack/tenant ApplicationSets.

**Lesson recorded (Task 8):** Traefik chart v42 moved the Service type to `service.spec.type`. The old `service.type` key was **silently ignored**, leaving a `LoadBalancer` stuck `<pending>` on kind. The Traefik app then stayed `Progressing` and blocked every later wave. Rendering with `helm template` passed, because only the *effective values* were wrong. Checks now assert rendered output (e.g. `type: NodePort`), not just that rendering succeeds.

**Verify:** `bash gitops/tests/platform_test.sh` checks that all Applications are Synced/Healthy, Grafana answers through the ingress, Prometheus scrapes Traefik, the ClusterSecretStore is Ready, and `kubectl top nodes` works. The platform requests about 2.5 GB of memory.

**Label:** RUN-LOCAL (values/aws: NOT RUN).
