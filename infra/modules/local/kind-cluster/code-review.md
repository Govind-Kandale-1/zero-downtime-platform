# infra/modules/local/kind-cluster/ — code review

**Purpose:** the local implementation of contract item 1, the cluster.

| File | What it does |
|---|---|
| `main.tf` | `kind_cluster` (provider `tehcyx/kind` 0.13.0): one control-plane node plus `var.workers` worker nodes, node image pinned **by digest**, `wait_for_ready = true`. Host ↔ NodePort mappings on the control-plane node, all on `127.0.0.1`: **80 → 30080** and **443 → 30443** (Traefik), **8200 → 30200** (OpenBao, for the Terraform vault provider). |
| `variables.tf` | `name` (zdp), `node_image`, `workers` (2), `kubeconfig_path` |
| `outputs.tf` | `kubeconfig_path`, `endpoint`, `cluster_ca_certificate`, `client_certificate` and `client_key` (both sensitive), consumed by later roots through remote state |
| `versions.tf` | Provider pin |

**Key decisions:**
- **Two workers, not one:** PDBs, topology spread and node drains can only be shown with more than one schedulable node. kind keeps the control-plane tainted when workers exist.
- **NodePorts mapped to host ports, not a LoadBalancer:** kind has no cloud LB. kube-proxy serves a NodePort on every node, so mapping it on the control-plane container is enough. On AWS the same Traefik service is `type: LoadBalancer` with NLB annotations. That difference is listed as non-portable.
- **Bound to 127.0.0.1:** nothing is exposed to the LAN.
- **Digest-pinned node image:** kind's release notes recommend it, because the image must match the kind binary version (0.30.0 ↔ v1.34.0).

**Verify:** `kubectl --kubeconfig .local/kubeconfig get nodes` shows 3 nodes `Ready`, `v1.34.0`.

**Limitations:**
- All nodes share the laptop's ~9.7 GB Docker VM. There is no real node autoscaling, and capacity is pre-provisioned (spec §10).
- The kubeconfig contains an admin client cert. It is written to the git-ignored `.local/`.

**Label:** RUN-LOCAL.
