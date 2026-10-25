# gitops/clusters/aws-eu-central-1/apps/ — code review

**Label: NOT RUN (static validation only)**

The local platform Applications re-pointed at `values/aws/`, plus `15-karpenter.yaml`. `21-platform-config.yaml` syncs `gitops/platform/aws`. `40/41-appset-*` are the stack and tenant ApplicationSets with AWS overrides (`backup.mode: managed`, `valkeyMetrics: false`), and the tenants set has a `region: eu-central-1` post-selector. See `../code-review.md`.
