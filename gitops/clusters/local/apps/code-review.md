# gitops/clusters/local/apps/ — code review

One Argo CD `Application` per platform component, managed by `root`. The file-name prefix mirrors the sync wave.

| File | Wave | Installs |
|---|---|---|
| `00-prometheus-operator-crds.yaml` | -2 | Prometheus Operator CRDs (ServerSideApply, because the CRDs exceed the client-side annotation size limit) |
| `10-traefik.yaml` | -1 | Traefik → ns `traefik` |
| `11-argo-rollouts.yaml` | -1 | Argo Rollouts and its dashboard → ns `argo-rollouts` |
| `12-keda.yaml` | -1 | KEDA → ns `keda` |
| `13-external-secrets.yaml` | -1 | ESO → ns `external-secrets` (the namespace pre-exists from Terraform) |
| `14-metrics-server.yaml` | -1 | metrics-server → `kube-system` |
| `20-kube-prometheus-stack.yaml` | 0 | Prometheus, Alertmanager, Grafana → ns `monitoring` |
| `21-platform-config.yaml` | 0 | `gitops/platform/config` (secret store, routes, priority classes) |
| `30-synthetic-traffic.yaml` | 1 | `gitops/platform/synthetic-traffic` → ns `synthetic` (labelled `restricted` via `managedNamespaceMetadata`) |

**Pattern:** chart Applications use **multi-source**. Source 1 is the upstream chart at a pinned version; source 2 is this repo as `ref: values`, so `valueFiles: [$values/gitops/platform/values/local/<x>.yaml]` keeps values reviewable in Git without vendoring charts. Every app has automated sync with prune and self-heal, plus `ServerSideApply`.

**Label:** RUN-LOCAL.
