# zero-downtime-platform

A cloud-agnostic platform built for a Senior DevOps assignment. It provisions infrastructure through a separate provider layer, deploys a black-box API and worker through a build-once, signed, digest-promoted, metric-gated pipeline, ships with canary releases and automatic rollback, autoscales to 15x on request rate and queue depth, and runs one shared stack plus dedicated per-tenant stacks from a single template.

> **Licence:** all rights reserved. Evaluation use only. See [LICENSE](LICENSE).

## Labels used throughout

| Label | Meaning |
|---|---|
| `RUN-LOCAL` | Executed on the local kind platform |
| `RUN-LOCAL (stand-in)` | Executed, but against the minimal stand-in app rather than the real black box |
| `NOT RUN (static validation only)` | Written and validated (`terraform validate`, tflint, trivy), never applied |
| `DESCRIBED` | Design only |

## Prerequisites

- Windows 11 or Linux with Docker (Docker Desktop on WSL2 with at least 9 GB of memory), kind 0.30, kubectl, Helm 4, Terraform ≥ 1.14 and GitHub CLI (authenticated).
- Run scripts from **Git Bash** on Windows (`C:\Program Files\Git\bin\bash.exe`), not WSL's `bash.exe`.
- Go and the other CLIs are optional: `scripts/lib/tools.sh` runs pinned containers when they're missing.

## Quickstart

*Coming with the one-command bring-up (`scripts/up.sh`).*

## Where to read

- `decisions.md`: every decision with rejected alternatives.
- `questions-answers.md`: review questions and answers.
- `code-review.md` in each folder: what the code in that folder does and why.
- `docs/superpowers/specs/`: the approved design. `docs/superpowers/plans/`: the build plan.
