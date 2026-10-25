# infra/live/aws/eu-central-1/20-data/ — code review

**Label: NOT RUN (static validation only)**

See `infra/live/aws/code-review.md` for how the four roots fit together. This root:

- `versions.tf`: AWS, Kubernetes and random providers; S3 backend.
- `main.tf`: builds the stack list from the same files as local and **filters it to `region == eu-central-1`**. It creates regional CMKs (eu-central-1, and eu-west-1 for backups) and calls `modules/aws/stack-data` once per stack. The Kubernetes provider authenticates with `aws eks get-token`; the `aws.backup` alias keeps PITR replicas in the EU.
