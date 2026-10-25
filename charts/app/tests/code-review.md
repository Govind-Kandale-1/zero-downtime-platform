# charts/app/tests/ — code review

| File | What it is |
|---|---|
| `render_test.sh` | Renders the chart with each fixture and makes **23 assertions**: canary steps and Traefik routing, preStop, worker steps and the 90 s grace, the PreSync hook and its optional Secret, ScaledObjects targeting Rollouts with the RPS and list-length thresholds, PDBs, digest-only images, default-deny NetworkPolicy, read-only root FS, no `spec.replicas`, the 99.95 objective, the default tenant host, the dev pause override, schema rejection of a missing digest, **kubeconform** (core schemas plus CRD schemas from the datree catalog, k8s 1.34), and **promtool** parsing the SLO rules with the cluster's Prometheus version. |
| `values-dev.yaml` | tiny, slo 99.9, min 1 / max 3, 60 s pauses |
| `values-prod.yaml` | small, shared tier, chart defaults |
| `values-tenant.yaml` | dedicated tenant `acme`, slo 99.95 |
| `values-nodigest.yaml` | Negative fixture: the render must fail |

**Why promtool as well as kubeconform:** to Helm and to schema validation, PromQL is just a string. A typo in a burn-rate expression would render, validate and deploy, and then silently never fire. promtool actually parses the expressions.

**Label:** RUN-LOCAL.
