# Evidence 05: build once, scan, sign, promote by digest

**Label:** RUN-LOCAL (GitHub Actions + laptop verification)

**The artifact:** `ghcr.io/govind-kandale-1/zero-downtime-platform@sha256:f91b81a532996c027e73b3c689246593d7d95400f055a41e2177241c894bc4e7`. It was built **once**, by run [40182607417](https://github.com/Govind-Kandale-1/zero-downtime-platform/actions/runs/40182607417). The next run, [40183505084](https://github.com/Govind-Kandale-1/zero-downtime-platform/actions/runs/40183505084), was a chart-only change. It **reused that digest** with chart `0.1.2` and promoted it through all five stages.

| File | What it shows |
|---|---|
| `trivy-summary.txt` | Trivy found **0** vulnerabilities in the distroless OS layer and in all three Go binaries (`api`, `worker`, `synthetic`). The pipeline fails on fixable HIGH/CRITICAL findings. |
| `cosign-verify.txt` | Verified from the laptop, outside the pipeline: the **image signature**, the **CycloneDX SBOM attestation**, and the **chart signature** (`charts/app:0.1.2`). All three are keyless, bound to `…/.github/workflows/release.yml@refs/heads/main` with GitHub's OIDC issuer, and recorded in the Rekor transparency log. **Negative check:** the same image fails verification against any other signer identity. |
| `../00-bringup/gate-verdicts.txt` | Every gate checked that the running Rollouts used **exactly this digest** before passing |
| `../00-bringup/version-per-stack.txt` | All six hosts answer with the same build |

**Registry access:** the GHCR package inherited the public repo's visibility. Anonymous pulls return HTTP 200, so the cluster pulls the image and chart without any credentials.

**Not yet enforced:** admission-time signature verification (Kyverno `verifyImages`) is P1. Today, signatures can be verified but are not required at admission.
