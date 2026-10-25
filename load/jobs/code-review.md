# load/jobs/ — code review

| File | What it does |
|---|---|
| `producer.js` | k6 posts **TOTAL** jobs at **5.56 jobs/s** (20,000/h, `rate 556 per 100s`). Each job's duration is drawn from a **log-normal with mean 10 s** (σ = 0.8, μ = ln 10 − σ²/2), using a Box–Muller transform, and capped at the brief's **60 s maximum**. Every POST must return 202. |

**Why log-normal:** job runtimes are positive and right-skewed. Most are short and a few are long. A constant 10 s would never exercise the 60 s case that sets the 90 s grace period, and a uniform distribution would overweight long jobs.

**How the evidence uses it:** after the queue drains, the counters must balance: `jobs:enqueued_total == jobs:done_total + jobs:failed_total`. That proves no job was dropped during scale-up and scale-in (ADR-006).

**Label:** RUN-LOCAL (stand-in).
