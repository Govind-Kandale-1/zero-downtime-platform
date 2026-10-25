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

| `40-appset-stacks.yaml` | 1 | **ApplicationSet `stacks`.** A matrix of `gitops/stacks/*.yaml` × `gitops/releases/{{.stack.release}}.yaml`, generating `Application stack-<name>`. The chart is pulled from the OCI repo at the release file's `chart.version`; values are the stack file plus `image.{repository,digest}` from the release file. |
| `41-appset-tenants-dedicated.yaml` | 1 | **ApplicationSet `tenants-dedicated`.** A matrix of `tenants/*.yaml` (post-selector `tier: dedicated`) × `gitops/releases/ring{{.ring}}.yaml`, generating `Application stack-<name>` in `tenant-<name>`, with values built from the tenant file |
| `42-appset-tenants-shared.yaml` | 1 | **ApplicationSet `tenants-shared`.** `tenants/*.yaml` (post-selector `tier: shared`) generates `Application tenant-<name>`, using `charts/tenant-route` from Git, into `app-prod` |

**ApplicationSet details that matter:**
- **No release file, no Application.** Until a stage has been promoted, its release file doesn't exist, the matrix yields nothing, and no half-rendered app appears.
- `goTemplate` with `missingkey=error`. `pathParamPrefix: release` on the second git generator stops its `.path` params from colliding with the first's.
- The release file uses `stage:`, not `name:`, so it can't collide with the tenant `name` parameter.
- `ignoreDifferences` on `TraefikService /spec/weighted/services`, plus `RespectIgnoreDifferences`: Argo Rollouts owns the canary weights.
- `preserveResourcesOnDeletion: true`: deleting a tenant file never cascades into deleting its workloads.
- **Lesson recorded (Task 11):** the post-`selector` is a field of the *generator*, a sibling of `git:`. Nested under `git:`, it was silently dropped. Every tenant then got a shared route, and the dedicated matrix failed on the shared tenant's missing `ring`. Because of `preserveResourcesOnDeletion`, the mistaken routes had to be deleted by hand afterwards.

**Pattern:** chart Applications use **multi-source**. Source 1 is the upstream chart at a pinned version; source 2 is this repo as `ref: values`, so `valueFiles: [$values/gitops/platform/values/local/<x>.yaml]` keeps values reviewable in Git without vendoring charts. Every app has automated sync with prune and self-heal, plus `ServerSideApply`.

**Label:** RUN-LOCAL.
