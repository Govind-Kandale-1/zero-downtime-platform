# gitops/platform/values/aws/ — code review

**Label: NOT RUN (static validation only)**

Per-provider Helm values for the AWS cluster. Compared with `values/local`:

| File | What differs from local |
|---|---|
| `traefik.yaml` | `LoadBalancer` with **NLB** annotations (cross-zone), `externalTrafficPolicy: Local`, 3 replicas spread across zones with a PDB, priority `platform-critical`. The metrics config is **identical**, so SLIs, analysis and KEDA queries are the same on both targets. |
| `kube-prometheus-stack.yaml` | 2 Prometheus replicas, 15 d retention on 100 Gi gp3, Alertmanager routing `severity=page` → page and everything else → ticket |
| `karpenter.yaml` | Cluster name and interruption queue; the controller runs on the system pool |
| `metrics-server.yaml` | No `--kubelet-insecure-tls` (EKS kubelets have proper certificates) |
| `argo-rollouts.yaml`, `keda.yaml`, `external-secrets.yaml` | The same as local |

**Non-portable by design:** the LB annotations, Karpenter and storage classes are listed in `docs/non-portable.md`.
