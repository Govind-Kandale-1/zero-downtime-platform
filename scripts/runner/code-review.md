# scripts/runner/ — code review

**Purpose:** the image for the **self-hosted GitHub Actions runner** that executes promotion gates (ADR-015). It runs on the laptop, on Docker network `kind`.

| File | What it does |
|---|---|
| `Dockerfile` | `ghcr.io/actions/actions-runner:2.338.1`, plus `jq` and `kubectl` v1.34.0, and nothing else. It switches back to the unprivileged `runner` user. |
| `entrypoint.sh` | Registers **once** (`config.sh --unattended --replace`, labels `self-hosted,local-kind`). The registration persists in the container, so `--restart unless-stopped` reconnects without a new token. Then it runs `exec ./run.sh`. |

**Security posture:**
- The runner holds a kubeconfig for ServiceAccount `ci-gate`. Its permissions are the built-in `view` role, `get`/`list`/`watch` on Applications, Rollouts and AnalysisRuns, and `get` on one Service proxy (Prometheus). `runner-up.sh` checks with a server-side dry-run that it **cannot delete** an Application.
- It receives jobs only from `release.yml`, which runs on `push` to main and `workflow_dispatch`. Fork-PR workflows need maintainer approval (`all_external_contributors`) and never reference this label.
- The registration token comes from the GitHub API at start-up and is valid for one hour. The long-lived runner credential stays inside the container.

**In the cloud (DESCRIBED):** the same role would be filled by Actions Runner Controller in each cluster, or a management cluster, using Pod Identity.

**Label:** RUN-LOCAL.
