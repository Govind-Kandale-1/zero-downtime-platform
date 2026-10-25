# Evidence 00: CI blocks a tenant that violates EU residency

**Label:** RUN-LOCAL (GitHub Actions, hosted runners)

**What was run:** PR [Govind-Kandale-1/zero-downtime-platform#1](https://github.com/Govind-Kandale-1/zero-downtime-platform/pull/1) added `tenants/evilcorp.yaml` with `residency: eu` and `region: us-east-1`.

| Run | Commit | Result |
|---|---|---|
| [40150438650](https://github.com/Govind-Kandale-1/zero-downtime-platform/actions/runs/40150438650) | `459e6ac`: adds the violating tenant | **`policy-test` failed**: `tenants/evilcorp.yaml: EU residency requires an EU region, got "us-east-1"`. (`chart-test` also failed, from an unrelated CI-only bug; see below.) |
| [40150717361](https://github.com/Govind-Kandale-1/zero-downtime-platform/actions/runs/40150717361) | `fece804`: removes the tenant and fixes the bug | **All six required checks green**: go-test, chart-test, policy-test, terraform-validate, iac-scan, shell-lint |

**A bug this run found:** `chart-test`'s promtool step passed on the Windows laptop but failed on Linux runners. `mktemp -d` creates a 0700 directory, and the distroless Prometheus image runs as `nobody`, so it couldn't read the mounted rules file. Docker Desktop on Windows ignores the mode, which is why it passed locally. The fix (`chmod -R a+rX`) is in the same PR. Running the same checks on two platforms caught it.
