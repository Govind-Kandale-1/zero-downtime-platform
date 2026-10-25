# gitops/platform/aws/ — code review

**Label: NOT RUN (static validation only)**

These are the AWS-only manifests synced by `platform-config-aws`; this folder replaces `gitops/platform/config` on the AWS cluster.

| File | What it does |
|---|---|
| `secret-store.yaml` | `ClusterSecretStore platform-secrets` → **AWS Secrets Manager** (eu-central-1). Credentials come from EKS Pod Identity, so there's no token. It has the **same name** as the local OpenBao store, so every stack's `ExternalSecret` is unchanged. |
| `karpenter.yaml` | `EC2NodeClass default` (AL2023, IMDSv2 only, encrypted gp3, discovery tags). `NodePool apps`: on-demand c/m generation ≥ 7, consolidation, at most 10% of nodes disrupted at once, and a **CPU limit of 200 as a cost guard-rail**. `NodePool workers-spot`: tainted, spot or on-demand, for queue workers. `NodePool tenant-acme`: an example **dedicated-tenant pool**, tainted and labelled, for compute isolation (ADR-017). |
| `overprovisioning.yaml` | 3 pause pods at priority **-10**, holding about 4.5 vCPU and 9 GiB of headroom. Real pods evict them instantly during a burst. The evicted placeholders then go Pending, which makes Karpenter add nodes in the background. That's how a 15x burst stays under the 5-minute target, despite node boot time. |
| `priority-classes.yaml` | The same three classes as local |
