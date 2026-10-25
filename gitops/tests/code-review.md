# gitops/tests/ — code review

| File | What it checks |
|---|---|
| `platform_test.sh` | 1. Every Argo CD Application is `Synced/Healthy`. 2. Grafana answers 200 through the Traefik ingress (`Host: grafana.localtest.me` on 127.0.0.1:80), which proves the kind port mapping, the NodePort and the IngressRoute. 3. Prometheus has `up{job=~".*traefik.*"} == 1`, queried through the API server's service proxy, so no port-forward is needed. 4. `ClusterSecretStore platform-secrets` is Ready, which proves ESO can authenticate to the secrets manager. 5. `kubectl top nodes` works, which proves metrics-server. |

**Label:** RUN-LOCAL.
