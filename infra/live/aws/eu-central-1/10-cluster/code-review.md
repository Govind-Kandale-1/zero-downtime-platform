# infra/live/aws/eu-central-1/10-cluster/ — code review

**Label: NOT RUN (static validation only)**

See `infra/live/aws/code-review.md` for how the four roots fit together. This root:

- `versions.tf`: AWS provider, S3 backend.
- `main.tf`: reads `05-network` via remote state (input `state_bucket`), then runs `modules/aws/eks` (Kubernetes 1.34, private endpoint, Karpenter). It outputs the cluster name, endpoint, CA and node security group.
