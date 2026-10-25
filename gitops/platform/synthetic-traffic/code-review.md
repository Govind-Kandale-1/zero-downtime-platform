# gitops/platform/synthetic-traffic/ — code review

| File | What it does |
|---|---|
| `deployment.yaml` | Runs `/synthetic` from the app image in namespace `synthetic` (Pod Security `restricted`, non-root, read-only root FS, no service account token). It targets `http://traefik.traefik.svc` with `Host:` headers for dev, staging, prod, initech, acme and globex: 10 req/s each, plus one job every 10 s. Requests 20m CPU / 32 Mi. |

**Lifecycle:** it ships with `replicas: 0` and a placeholder image, because no image has been published when the platform is first installed. After the first release, the bring-up step pins the published **digest** and sets `replicas: 1`. That is a reviewed commit, not an automated one, so this tooling never changes silently alongside the app.

**Why it exists:** ADR-016. Argo Rollouts treats "no data" as *inconclusive* and pauses. Without steady traffic, dev, staging and tenant canaries would never complete.

**Label:** RUN-LOCAL (platform tooling).
