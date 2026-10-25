# Runbook: drift detected

**Label:** DESCRIBED. Part A's fixes were applied for real during the build (Tasks 14 and 16); part B is a manual check until roadmap item 8.

Drift is live state that no longer matches Git. There are two layers, with different tools.

## A. Kubernetes drift: an Argo CD Application is `OutOfSync`

Every Application has `selfHeal: true`, so Argo CD reverts manual changes within its reconcile loop (60 s). **Drift that keeps coming back** means something in the cluster is writing the field.

```bash
app=stack-prod
kubectl -n argocd get application $app -o json | jq -r '.status.resources[] | select(.status=="OutOfSync") | "\(.kind)/\(.name)"'
kubectl -n argocd get application $app -o jsonpath='{.status.operationState.message}{"\n"}'
# who owns the drifting field?
kubectl -n <ns> get <kind> <name> --show-managed-fields -o yaml | grep -B2 -A6 'manager:'
```

| Writer | Meaning | Action |
|---|---|---|
| A person (`kubectl-client-side-apply`, `kubectl-edit`, `kubectl-patch`) | A manual hot-fix | Self-heal reverts it. If it was needed, commit it to Git |
| A **controller that legitimately owns the field** (e.g. `rollouts-controller` on Service selectors, Argo Rollouts on TraefikService weights) | Argo CD and a controller are fighting | Add a narrow `ignoreDifferences` for exactly that field. Prefer `managedFieldsManagers` over JSON pointers (see the stack ApplicationSets). Never ignore a whole resource |
| A **render that changes every time** (random passwords, timestamps) | Permanent `OutOfSync` and endless rollouts (Task 16: Grafana's random admin password made 12 ReplicaSets in 90 min) | Make the render deterministic: move the value to a Secret created outside the chart (`existingSecret`) |
| An empty value the API server drops (e.g. `group: ""`) | Cosmetic, but permanent | Remove the empty field from the manifest |

A hook or Job stuck after a sync: **don't delete hook Jobs during an active operation** (Task 14). Terminate the operation first (`argocd app terminate-op`), then sync again.

## B. Provider drift: Terraform state vs reality

A nightly `terraform plan -detailed-exitcode` per root, opening an issue, is roadmap item 8. Until then, check by hand:

```bash
. .local/tfstate.env   # PG_CONN_STR for the pg backend
for r in 10-cluster 20-data 30-gitops; do
  terraform -chdir=infra/live/local/$r plan -detailed-exitcode -lock-timeout=60s -no-color >/dev/null; echo "$r exit $?"
done   # 0 = no drift, 2 = drift, 1 = error
```

| Drift | Action |
|---|---|
| A change made in a console or CLI that should stay | **Codify it**: change the module, re-plan until it's clean |
| A change that shouldn't exist | **Revert it**: `terraform apply` the reviewed plan |
| A resource created outside Terraform that should be managed | `terraform import` it (the `monitoring` namespace was imported this way in Task 16) |
| A resource replaced by a restore (AWS PITR) | Point the module at the new resource or import it, *before* the next apply |

**Never** edit state by hand, and never `terraform apply` without reading the plan. The `pg` and S3 backends lock, so a second apply waits instead of corrupting state.
