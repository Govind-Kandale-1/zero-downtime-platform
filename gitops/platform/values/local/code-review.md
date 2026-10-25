# gitops/platform/values/local/ — code review

Helm values for each platform chart on the local kind cluster. Every file sets explicit resource requests, so the laptop memory budget holds (~2.5 GB for the whole platform).

| File | Key settings and why |
|---|---|
| `traefik.yaml` | `service.spec.type: NodePort` with web `30080` and websecure `30443`; kind maps these to host 80/443. `allowCrossNamespace` is on for shared-tenant routes and cross-namespace weighted services. **Prometheus buckets `0.05…0.4…5`**, so the "< 400 ms" SLI is exact. Services, routers and entrypoints labels: the service label separates stable from canary, and the router label gives per-shared-tenant visibility. The chart creates its own ServiceMonitor (15 s). Dashboard off. **2 replicas, PDB `minAvailable: 1`, 512 Mi limit:** in 15x attempt 1 a single replica was OOM-killed at 256 Mi three times, and each kill took the edge down for every stack. |
| `argo-rollouts.yaml` | 1 controller with metrics plus a ServiceMonitor; the dashboard is on, reached at `rollouts.localtest.me`, for evidence screenshots |
| `keda.yaml` | Requests for operator, metrics server and webhooks; operator ServiceMonitor |
| `external-secrets.yaml` | CRDs installed by the chart; small requests for the controller, webhook and cert controller |
| `metrics-server.yaml` | `--kubelet-insecure-tls`, because kind's kubelets use self-signed certificates |
| `kube-prometheus-stack.yaml` | CRDs off (wave -2 installs them). Etcd, scheduler, controller-manager and kube-proxy scraping are off; kind doesn't expose them, so they'd only produce down targets. Retention 12 h, scrape and evaluation every **15 s**. The `*SelectorNilUsesHelmValues: false` settings make Prometheus pick up monitors and rules from every namespace, which the app chart relies on. Alertmanager routes to a `local-only` receiver: alerts are visible but not delivered (labelled). Grafana allows anonymous **Viewer** access, local only. |

**Label:** RUN-LOCAL.
