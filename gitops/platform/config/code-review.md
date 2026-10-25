# gitops/platform/config/ — code review

Plain manifests synced by the `platform-config` Application (wave 0).

| File | What it does |
|---|---|
| `secret-store.yaml` | **`ClusterSecretStore platform-secrets`**: the *only* place the secrets backend is named. Locally it points at OpenBao (`http://openbao.openbao.svc:8200`, KV v2 at `secret/`, token from `external-secrets/openbao-token`). Every stack's `ExternalSecret` refers to it by name, so moving to AWS Secrets Manager changes only this object (ADR-009). |
| `ingress-routes.yaml` | Traefik `IngressRoute`s for the UIs: `argocd.localtest.me`, `grafana.localtest.me`, `prometheus.localtest.me` and `rollouts.localtest.me` (`*.localtest.me` resolves to 127.0.0.1). |
| `priority-classes.yaml` | `platform-critical` (100000), `app` (1000), and **`overprovision` (-10, `preemptionPolicy: Never`)**. The last is for placeholder pods that hold spare capacity: the scheduler evicts them instantly when real pods need room, while the node autoscaler adds nodes. That is how a cloud cluster absorbs the first seconds of a 15x burst. It is used on AWS with Karpenter; DESCRIBED locally, because kind has fixed nodes. |

**Verify:** `kubectl get clustersecretstore platform-secrets` shows Ready=True; `curl -H 'Host: grafana.localtest.me' http://127.0.0.1/api/health` returns 200.

**Label:** RUN-LOCAL.
