# config/ — code review

**Purpose:** the two files that make the repo reproducible and forkable. Scripts and CI read both through `load_config` (`scripts/lib/common.sh`).

| File | What it holds |
|---|---|
| `platform.env` | Identity: GitHub owner and repo, the lowercase GHCR owner, the image and chart repository, the Cosign signer identity regex and OIDC issuer, and the kind cluster name. A reviewer forking the repo changes only this file (spec §18). |
| `versions.env` | Every pinned version (toolchain images, kind node image with digest, data-service images, Helm charts, the runner image, Terraform providers and modules), resolved on 2026-10-25 from upstream release feeds and checked to exist. |

**Key decisions:**
- One place for versions means an upgrade is a one-line diff, reviewed like code.
- The kind node image is pinned by **digest**, as kind's release notes recommend, because tags can move.
- The distroless base is `static-debian13` (newest), so Trivy has the fewest packages to flag.

**Verify:** `source scripts/lib/common.sh && load_config && echo "$IMAGE $CHART_ARGOCD"`.

**Limitations:** Terraform `versions.tf` files repeat provider versions, because Terraform can't read env files in `required_providers`. CI's `terraform-validate` job catches drift.

**Label:** RUN-LOCAL.
