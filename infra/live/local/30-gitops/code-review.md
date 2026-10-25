# infra/live/local/30-gitops/ — code review

**Purpose:** step 3 of the local provider layer, and the **handover point**. Terraform installs Argo CD and one root Application. After that, Terraform never touches workloads; everything in-cluster is reconciled from Git.

| File | What it does |
|---|---|
| `main.tf` | `helm_release.argocd` (chart `argo/argo-cd` 10.11.1, ns `argocd`, waits for readiness), then `kubectl_manifest.root`, which applies **the same `gitops/clusters/local/root.yaml` that lives in Git**. Providers are configured from 10-cluster's remote state. |
| `values-argocd.yaml` | Lean install: dex and notifications off, small requests. `server.insecure` because TLS terminates at Traefik. **`timeout.reconciliation: 60s`**, so a promotion commit lands within about a minute. A **Lua health check for `Application`** resources, which Argo CD no longer assesses by default; without it, app-of-apps sync waves wouldn't wait for operator/CRD apps to be Healthy before syncing their consumers. A repository entry for the public **OCI Helm repo** `ghcr.io/govind-kandale-1/charts` (`enableOCI`). |
| `backend.tf` | pg schema `local_30_gitops`, plus cluster remote state |

**Key decisions:**
- **Terraform bootstraps; Argo CD owns everything after.** This avoids the classic split-brain where Terraform and Argo both manage the same Helm releases. Argo CD could also manage itself (an `argocd` Application); it doesn't here, to keep the bootstrap readable.
- **No Git credentials:** the repo is public (ADR-020), so the pull model needs no secret in the cluster.
- **60 s reconciliation instead of webhooks:** the cluster is on a laptop and GitHub can't reach it. Polling once a minute is the pull-model answer; it also means no inbound connectivity is needed.

**Verify:** `kubectl -n argocd get application root -o jsonpath='{.status.sync.status}'` prints `Synced`, at the same revision as `git rev-parse origin/main`.

**Label:** RUN-LOCAL.

**Also:** `versions.tf` (Terraform and provider pins, and the `pg` backend). `.terraform.lock.hcl`: the provider dependency lock (exact versions and checksums), committed so every run uses the same providers.
