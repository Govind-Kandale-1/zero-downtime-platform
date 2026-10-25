# gitops/ — code review

**Purpose:** the desired state of every cluster, reconciled by Argo CD (pull model, ADR-010). Nothing in here is applied by a pipeline. Pipelines only *commit* to it.

| Path | What it is |
|---|---|
| `clusters/local/root.yaml` | The app-of-apps root. Terraform applies it once; it points Argo CD at `clusters/local/apps/` on `main`, recursively, with automated sync, prune and self-heal. |
| `clusters/local/apps/` | One Argo CD `Application` (or `ApplicationSet`) per platform component and stack group. Sync waves order CRDs → operators → config → workloads. |
| `platform/` | Values and plain manifests for platform components, with per-provider overlays (`values/local`, `values/aws`). |
| `stacks/` | One file per environment stack: a Terraform descriptor plus Helm values. |
| `releases/` | One file per release stage (`dev`, `staging`, `prod-ring0`, `ring1`, `ring2`), pinning the **chart version and image digest**. Promotion is a commit that copies a digest from one file to the next. |

**How a change flows:**
1. Something is committed (a human PR, or a pipeline promotion).
2. Within 60 s Argo CD sees the new revision and syncs it.
3. Argo Rollouts runs the canary.
4. Self-heal reverts any manual `kubectl` change. This is drift correction for the cluster layer; Terraform drift detection covers the infrastructure layer.

**Label:** RUN-LOCAL.
