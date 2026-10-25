# infra/live/aws/eu-central-1/30-gitops/ — code review

**Label: NOT RUN (static validation only)**

See `infra/live/aws/code-review.md` for how the four roots fit together. This root:

- `versions.tf`: AWS, Helm and kubectl providers; S3 backend.
- `main.tf`: installs Argo CD (the same values file as local) and applies `gitops/clusters/aws-eu-central-1/root.yaml`. From there everything is GitOps, exactly as on kind. Only the auth (`aws eks get-token`) and the cluster folder differ.
