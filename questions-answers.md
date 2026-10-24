# Interview Questions & Answers

Likely review questions, grouped by the brief's sections. Each entry has a short answer you can say out loud, the follow-ups to expect, and where to point in the repo. Entries are added as each part is built.

---

## 0. Scope, honesty and labels

### Q: What did you actually run, and what is only described?
**A:** The whole platform runs on a local kind cluster: the provider layer, GitOps, canaries, autoscaling, backups and the pipeline gates. The AWS provider layer is fully written but never applied. It is labelled `NOT RUN` and only statically validated in CI. Every evidence item and README row carries one of four labels, so nothing is presented as run when it wasn't.
**Follow-ups:** "So the two-targets requirement isn't met?" Partially: the second target is a complete implementation that passes `terraform validate`, tflint and trivy, but it isn't applied (ADR-001).
**Point to:** `README.md` coverage table, `decisions.md` ADR-001.

### Q: Why not just spin up EKS for an hour?
**A:** It was a deliberate cost and credentials decision for an evaluation exercise. A create-and-destroy approach would have cost about $15–25. I made the provider contract strict, so running AWS is a matter of credentials and `apply`, not redesign. It is the first roadmap item.
**Point to:** ADR-001, `docs/roadmap.md`.

### Q: Why is a public repo "all rights reserved"?
**A:** Public visibility is needed for review and for credential-free GitOps pulls. It doesn't grant reuse rights. The LICENSE limits use to evaluation during this interview process. GitHub's ToS still allows viewing and forking on GitHub itself.
**Point to:** `LICENSE`, ADR-002.

## 1. Cloud-agnostic infrastructure as code

### Q: Where exactly is the boundary between "provider" and "platform"?
**A:** It's the provider contract in ADR-003. A provider must hand over:
- a cluster;
- per stack: Postgres, a PgBouncer endpoint and Valkey;
- a secrets manager with three well-known keys per stack;
- a locked remote state backend.

Everything above that (Argo CD, Traefik, Rollouts, KEDA, the app chart) only consumes those names. On kind the contract is met by CloudNativePG, Valkey and OpenBao; on AWS by RDS, ElastiCache and Secrets Manager.
**Follow-ups:** "What leaks through?" LB annotations, IAM, node autoscaling, backup mechanics and the state backend type (`docs/non-portable.md`).
**Point to:** `infra/code-review.md`, ADR-003.

### Q: Why not Crossplane, so everything is Kubernetes-native?
**A:** Crossplane needs a cluster before it can create one, which is a bootstrap problem. It also adds a control plane to run and debug. Terraform is the common denominator interviewers and operators know, and the contract keeps it swappable.
**Point to:** ADR-003.

## 2. Full automation

### Q: How do you run the same tools on a Windows laptop and in Linux CI?
**A:** Every tool is pinned in `config/versions.env`. Locally, `scripts/lib/tools.sh` runs the pinned container when the binary isn't installed, so versions match CI exactly. Line endings are forced to LF and checked in CI, because CRLF silently breaks bash, YAML and Terraform.
**Point to:** ADR-021, `scripts/lib/code-review.md`.

## 3. Multi-stage pipeline

### Q: How can the pipeline commit to a protected `main`?
**A:** The ruleset has two bypass actors: repo admins, and a write-enabled deploy key held only by the release workflow. `GITHUB_TOKEN` can't bypass rulesets, and requiring a human PR per promotion would defeat automated ring rollout.
**Follow-ups:** "Isn't a write deploy key risky?" It's scoped to one repo, stored as an Actions secret, used only in promote jobs, and every commit it makes is a one-line release-file change visible in history.
**Point to:** ADR-020.

## 4. Deployment strategy
*(added in later steps)*

## 5. Zero downtime
*(added in later steps)*

## 6. Autoscaling and capacity

### Q: 20,000 jobs per hour: baseline or peak? How many workers?
**A:** I assumed peak: λ = 5.56 jobs/s. With a 10 s mean job, Little's law gives L = λ × W ≈ 56 concurrent workers. Sizing uses the mean; the 60 s maximum sets the 90 s shutdown grace period so scale-in never kills a job. If it's the baseline, peak is ~83 jobs/s and ~830 workers, and capacity.md shows that case.
**Follow-ups:** "Why not size for 60 s?" That gives ~333 workers, mostly idle. Throughput depends on the mean.
**Point to:** ADR-024, `docs/capacity.md`.

## 7. Multi-deployment and tenancy
*(added in later steps)*

## 8. Operations
*(added in later steps)*

## 9. Cost and plan
*(added in later steps)*

## 10. Deliverables and evidence
*(added in later steps)*

## 11. Uncomfortable questions
*(added in later steps; see spec §14 for the list)*
