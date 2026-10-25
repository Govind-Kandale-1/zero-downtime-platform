# gitops/clusters/aws-eu-central-1/apps/ — code review

**Label: NOT RUN (static validation only)**

The local platform Applications re-pointed at `values/aws/`, plus `15-karpenter.yaml`. `21-platform-config.yaml` syncs `gitops/platform/aws`. `40/41-appset-*` are the stack and tenant ApplicationSets with AWS overrides (`backup.mode: managed`, `valkeyMetrics: false`), and the tenants set has a `region: eu-central-1` post-selector. See `../code-review.md`.

| File | What it is |
|---|---|
| `00-prometheus-operator-crds.yaml` | Monitoring CRDs first (sync wave 0), so every later app can create ServiceMonitors and PrometheusRules |
| `10-traefik.yaml` | Traefik with `values/aws/traefik.yaml`: 3 replicas, PDB, NLB annotations |
| `11-argo-rollouts.yaml` | Argo Rollouts controller and dashboard |
| `12-keda.yaml` | KEDA operator and metrics server |
| `13-external-secrets.yaml` | External Secrets Operator (Secrets Manager via Pod Identity) |
| `14-metrics-server.yaml` | metrics-server (the HPA's CPU metrics) |
| `15-karpenter.yaml` | Karpenter controller (AWS only) |
| `20-kube-prometheus-stack.yaml` | Prometheus, Alertmanager and Grafana with `values/aws` (2 replicas, 15 d retention, gp3) |
| `21-platform-config.yaml` | `gitops/platform/aws`: ClusterSecretStore, Karpenter NodePools, over-provisioning |
| `40-appset-stacks.yaml` | one Application per env stack, with `backup.mode: managed`, `valkeyMetrics: false`, `dbMetrics: false` |
| `41-appset-tenants-dedicated.yaml` | one Application per dedicated tenant whose `region` is eu-central-1 |
