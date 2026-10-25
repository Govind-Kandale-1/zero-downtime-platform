# gitops/clusters/local/ — code review

| File | What it does |
|---|---|
| `root.yaml` | The `Application root` in ns `argocd`: source `https://github.com/Govind-Kandale-1/zero-downtime-platform.git`, revision `main`, path `gitops/clusters/local/apps`, `directory.recurse: true`; destination is the in-cluster API. `syncPolicy.automated` with `prune: true` (a file removed from Git is removed from the cluster) and `selfHeal: true` (manual edits are reverted). |
| `apps/` | The Applications that root manages (see that folder's `code-review.md` once it holds manifests). |

**Why app-of-apps:** one object bootstraps the whole cluster, and adding a platform component is one new file in `apps/`, reviewed like any other change. A second cluster (e.g. `clusters/aws-eu-central-1/`) reuses the same platform definitions with different values.

**Label:** RUN-LOCAL.
