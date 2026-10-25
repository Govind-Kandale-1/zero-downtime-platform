# Cost estimate (AWS eu-central-1)

**Label:** DESCRIBED (the AWS code is NOT RUN). Every price is AWS on-demand list price for EU (Frankfurt), fetched on 2026-10-25 by `scripts/fetch-prices.sh` from AWS's public price lists. They're listed in full, with sources, at the end and in `docs/cost-prices.csv`. Re-run the script to refresh. All figures are USD per month (730 h), before tax, support and discounts.

## Summary

| Scenario | Monthly | Budget | Headroom |
|---|---|---|---|
| **Steady**: shared prod at 150 req/s + dev + staging + 1 dedicated tenant (acme) | **$2,789** | $9,000 | $6,211 |
| **Peak**: the same, at 2,250 req/s and with tenants at their peak, **for the whole month** (an upper bound) | **$5,073** | $16,000 | $10,927 |
| **Maximum dedicated tenants** (eu-central-1, size `small`) | **8**, limited by the steady budget: $8,669 steady, $13,421 at peak | | |

A peak lasting the whole month is deliberately pessimistic. A 15x event that lasts hours adds only the hours: one `m7i.xlarge` costs $0.2415/hour.

## Assumptions

- **Topology** as written in `infra/` (NOT RUN): one EKS cluster in eu-central-1 across 3 AZs, a NAT Gateway per AZ, one NLB, a 2-node `m7i.large` system group, Karpenter `m7i.xlarge` nodes at 80% usable (3.2 vCPU), over-provisioning pods reserving 4.5 vCPU so scale-up never waits for a node, and 2 Prometheus replicas on 100 GB gp3 each (15-day retention).
- **Per stack:** RDS PostgreSQL Multi-AZ (`small` = `db.r7g.large`, `tiny` = `db.t4g.medium`), 50 GB gp3, automated backups replicated to eu-west-1; ElastiCache Valkey with 2 nodes (`small` = `cache.m7g.large`, `tiny` = `cache.t4g.small`); one Secrets Manager secret.
- **Compute per pod** (the real app is heavier than the stand-in): **0.5 vCPU per API pod at capacity, 0.1 vCPU per worker** (`docs/capacity.md` §6). Prod peaks at 21 API + 60 workers. A dedicated tenant runs 3 API + 2 workers steady and 10 API + 20 workers at peak, on its own tainted NodePool (ADR-017).
- **Traffic:** 2 KB per response, so egress is about 750 GB/month steady and about 11 TB at peak sustained. NAT traffic (image pulls, Sigstore, GitHub) is 300 GB steady and 1 TB at peak. NLB capacity is 1 LCU steady and 16 at peak, by bytes processed.
- **Not included:** CloudWatch logs and metrics (Prometheus runs in-cluster), inter-region transfer for backup replication (small), Route 53 and ACM (cents), GitHub (outside AWS), support plans.
## Region-shared platform, steady (150 req/s)

| Item | USD/month |
|---|---|
| EKS control plane | 73.00 |
| System node group: 2 x m7i.large | 176.29 |
| NAT Gateways: 3 (one per AZ) | 113.88 |
| NAT data processed: 300 GB | 15.60 |
| NLB hours | 19.71 |
| NLB capacity units: 1 LCU average | 4.38 |
| Public IPv4: 6 (3 NAT + 3 NLB) | 21.90 |
| KMS keys: 2 (data + backup region) | 2.00 |
| Over-provisioning headroom: 4.5 vCPU, about 1.5 nodes | 264.44 |
| Prometheus volumes: 2 x 100 GB gp3 (2 replicas, 15 d retention) | 19.04 |
| Internet egress: 752 GB at 150 req/s x 2 KB (first 100 GB free) | 58.67 |
| **Total** | **768.92** |

## Region-shared platform, at peak (2,250 req/s)

| Item | USD/month |
|---|---|
| EKS control plane | 73.00 |
| System node group: 2 x m7i.large | 176.29 |
| NAT Gateways: 3 (one per AZ) | 113.88 |
| NAT data processed: 1000 GB | 52.00 |
| NLB hours | 19.71 |
| NLB capacity units: 16 LCU average | 70.08 |
| Public IPv4: 6 (3 NAT + 3 NLB) | 21.90 |
| KMS keys: 2 (data + backup region) | 2.00 |
| Over-provisioning headroom: 4.5 vCPU, about 1.5 nodes | 264.44 |
| Prometheus volumes: 2 x 100 GB gp3 (2 replicas, 15 d retention) | 19.04 |
| Internet egress: 11,278 GB at 2250 req/s x 2 KB (first 100 GB free) | 1,006.03 |
| **Total** | **1,818.38** |

## Shared prod data tier (small)

| Item | USD/month |
|---|---|
| RDS PostgreSQL db.r7g.large Multi-AZ | 424.86 |
| ElastiCache Valkey 2 x cache.m7g.large | 219.58 |
| RDS gp3 storage 50 GB Multi-AZ | 13.70 |
| Backup replica storage in eu-west-1, about 50 GB | 5.15 |
| Secrets Manager: 1 secret | 0.40 |
| **Total** | **663.69** |

## One non-prod stack data tier (tiny; dev and staging each)

| Item | USD/month |
|---|---|
| RDS PostgreSQL db.t4g.medium Multi-AZ | 108.77 |
| ElastiCache Valkey 2 x cache.t4g.small | 42.05 |
| RDS gp3 storage 50 GB Multi-AZ | 13.70 |
| Backup replica storage in eu-west-1, about 50 GB | 5.15 |
| Secrets Manager: 1 secret | 0.40 |
| **Total** | **170.07** |

## One dedicated tenant (small), steady

| Item | USD/month |
|---|---|
| RDS PostgreSQL db.r7g.large Multi-AZ | 424.86 |
| ElastiCache Valkey 2 x cache.m7g.large | 219.58 |
| RDS gp3 storage 50 GB Multi-AZ | 13.70 |
| Backup replica storage in eu-west-1, about 50 GB | 5.15 |
| Secrets Manager: 1 secret | 0.40 |
| Tenant NodePool: 1 x m7i.xlarge (3 API + 2 workers = 1.7 vCPU) | 176.29 |
| **Total** | **839.99** |

## One dedicated tenant (small), at peak

| Item | USD/month |
|---|---|
| RDS PostgreSQL db.r7g.large Multi-AZ | 424.86 |
| ElastiCache Valkey 2 x cache.m7g.large | 219.58 |
| RDS gp3 storage 50 GB Multi-AZ | 13.70 |
| Backup replica storage in eu-west-1, about 50 GB | 5.15 |
| Secrets Manager: 1 secret | 0.40 |
| Tenant NodePool at peak: 3 x m7i.xlarge (10 API + 20 workers = 7 vCPU) | 528.88 |
| **Total** | **1,192.58** |

## Application nodes (shared Karpenter `apps` pool)

| Scenario | vCPU | Nodes | USD/month |
|---|---|---|---|
| Steady: prod 3 API + 2 workers, dev and staging at their minimum | 2.9 | 1 × `m7i.xlarge` | 176.30 |
| Peak: prod 21 API + 60 workers, dev and staging at their minimum | 17.7 | 6 × `m7i.xlarge` | 1,057.77 |

## Totals

| Component | Steady | Peak (whole month) |
|---|---|---|
| Region-shared platform | 768.92 | 1,818.38 |
| Application nodes | 176.30 | 1,057.77 |
| Shared prod data tier | 663.69 | 663.69 |
| dev + staging data tiers (2 × 170.07) | 340.14 | 340.14 |
| **Base, without dedicated tenants** | **1,949.04** | **3,879.98** |
| acme, the first dedicated tenant | 839.99 | 1,192.58 |
| **Total as deployed** | **2,789.03** | **5,072.56** |

**Maximum dedicated tenants:** (9,000 − 1,949.04) / 839.99 = **8** at steady; (16,000 − 3,879.98) / 1,192.58 = 10 at peak. **Eight** fit both. The binding cost is each tenant's own Multi-AZ RDS + ElastiCache ($644 of its $840). That's the price of the isolation ADR-017 chose.

**A dedicated tenant in another region** (globex, us-east-1; DESCRIBED, not written) also needs that region's shared platform: about $769 more for the first tenant there.

## What moves the number

| Lever | Effect | Trade-off |
|---|---|---|
| Compute Savings Plan / RDS reserved instances (1 year) | roughly −30% on nodes and databases | a commitment; do it after 2–3 months of real usage |
| Non-prod RDS Single-AZ | −$54.75 per non-prod stack | no failover testing in non-prod |
| Spot for workers (`workers-spot` NodePool exists) | workers cost less (the AWS spot price was not fetched) | interruptions; safe because of draining + the reaper (ADR-006) |
| Graviton nodes (`m7g`) | lower price per vCPU (not fetched) | needs an arm64 image: the release builds linux/amd64 only today (buildx can add `--platform linux/arm64`) |
| **The headroom fix** (ADR-013, third revision): ~30 API pods at peak instead of 21 | +4.5 vCPU at peak, i.e. +1 node: $0.2415/hour while the peak lasts, at most $176.30/month | the cost of not saturating mid-ramp |
| Prod RDS to `db.r7g.xlarge` (risk 1 in the architecture doc) | about +$425/month (price not fetched; estimated as double `r7g.large`) | only if the real app's query load needs it |
| Egress per response | the biggest variable at peak ($1,006 at 2 KB) | measure the real app's response size |

## Prices used

| Item | USD | Unit | Fetched | Source |
|---|---|---|---|---|
| EKS cluster | 0.1 | Hours | 2026-10-25 | [offer: AmazonEKS](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonEKS/current/eu-central-1/index.json) |
| RDS PostgreSQL db.r7g.large Multi-AZ | 0.582 | Hrs | 2026-10-25 | [offer: AmazonRDS](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonRDS/current/eu-central-1/index.json) |
| RDS PostgreSQL db.r7g.large Single-AZ | 0.291 | Hrs | 2026-10-25 | [offer: AmazonRDS](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonRDS/current/eu-central-1/index.json) |
| RDS PostgreSQL db.t4g.medium Multi-AZ | 0.149 | Hrs | 2026-10-25 | [offer: AmazonRDS](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonRDS/current/eu-central-1/index.json) |
| RDS PostgreSQL db.t4g.medium Single-AZ | 0.074 | Hrs | 2026-10-25 | [offer: AmazonRDS](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonRDS/current/eu-central-1/index.json) |
| RDS gp3 storage Multi-AZ | 0.274 | GB-Mo | 2026-10-25 | [offer: AmazonRDS](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonRDS/current/eu-central-1/index.json) |
| RDS backup storage | 0.103 | GB-Mo | 2026-10-25 | [offer: AmazonRDS](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonRDS/current/eu-central-1/index.json) |
| ElastiCache Valkey cache.m7g.large | 0.1504 | Hrs | 2026-10-25 | [offer: AmazonElastiCache](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonElastiCache/current/eu-central-1/index.json) |
| ElastiCache Valkey cache.t4g.small | 0.0288 | Hrs | 2026-10-25 | [offer: AmazonElastiCache](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonElastiCache/current/eu-central-1/index.json) |
| NLB hour | 0.027 | Hrs | 2026-10-25 | [offer: AWSELB](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSELB/current/eu-central-1/index.json) |
| NLB LCU hour | 0.006 | LCU-Hrs | 2026-10-25 | [offer: AWSELB](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSELB/current/eu-central-1/index.json) |
| Secrets Manager secret | 0.4 | Secrets | 2026-10-25 | [offer: AWSSecretsManager](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSSecretsManager/current/eu-central-1/index.json) |
| KMS customer managed key | 1 | Keys | 2026-10-25 | [offer: awskms](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/awskms/current/eu-central-1/index.json) |
| Public IPv4 address | 0.005 | Hrs | 2026-10-25 | [offer: AmazonVPC](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonVPC/current/eu-central-1/index.json) |
| Data transfer out to internet | 0.09 | GB | 2026-10-25 | [offer: AWSDataTransfer](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSDataTransfer/current/eu-central-1/index.json) |
| EC2 m7i.large Linux on-demand | 0.12075 | Hrs | 2026-10-25 | [EC2 pricing page price map](https://b0.p.awsstatic.com/pricing/2.0/meteredUnitMaps/ec2/USD/current/ec2-ondemand-without-sec-sel/EU%20(Frankfurt)/Linux/index.json) |
| EC2 m7i.xlarge Linux on-demand | 0.2415 | Hrs | 2026-10-25 | [EC2 pricing page price map](https://b0.p.awsstatic.com/pricing/2.0/meteredUnitMaps/ec2/USD/current/ec2-ondemand-without-sec-sel/EU%20(Frankfurt)/Linux/index.json) |
| EBS gp3 storage | 0.0952 | GB-Mo | 2026-10-25 | [offer: AmazonEC2 (CSV)](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonEC2/current/eu-central-1/index.csv) |
| NAT Gateway data processed | 0.052 | GB | 2026-10-25 | [offer: AmazonEC2 (CSV)](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonEC2/current/eu-central-1/index.csv) |
| NAT Gateway hour | 0.052 | Hrs | 2026-10-25 | [offer: AmazonEC2 (CSV)](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonEC2/current/eu-central-1/index.csv) |
