# infra/modules/aws/network/ — code review

**Label: NOT RUN (static validation only)**

Wraps `terraform-aws-modules/vpc` 6.7.3 (ADR-022).

| Aspect | Setting and why |
|---|---|
| Subnets | Three AZs. **Public** subnets (`/24`) hold the NLB and NAT. **Private** subnets (`/20`) hold nodes, RDS and ElastiCache. **Intra** subnets (`/24`, no internet route) hold the EKS control-plane ENIs. |
| NAT | One per AZ by default, so an AZ outage can't cut egress for the others. `single_nat_gateway = true` saves about $65/month per extra AZ in non-prod. |
| Tags | `kubernetes.io/role/elb` (public LB), `kubernetes.io/role/internal-elb`, and `karpenter.sh/discovery` on the private subnets, so Karpenter knows where to launch nodes |
| Flow logs | Enabled, to CloudWatch |

Outputs: `vpc_id`, `private_subnet_ids`, `intra_subnet_ids`, `public_subnet_ids`.
