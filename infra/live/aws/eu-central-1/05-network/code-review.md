# infra/live/aws/eu-central-1/05-network/ — code review

**Label: NOT RUN (static validation only)**

See `infra/live/aws/code-review.md` for how the four roots fit together. This root:

- `versions.tf`: AWS provider 6.70.0, the S3 backend (partial config, `use_lockfile`), default tags.
- `main.tf`: `modules/aws/network` for `zdp-euc1`, `10.20.0.0/16`, 3 AZs, NAT per AZ. It outputs the VPC and subnet IDs for `10-cluster` and `20-data`.
