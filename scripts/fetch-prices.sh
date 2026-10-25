#!/usr/bin/env bash
# Fetch the AWS eu-central-1 on-demand prices that docs/cost.md uses, straight
# from AWS's public price lists, so every figure has a source URL and a date.
# Writes docs/cost-prices.csv: item,usd,unit,description,source,fetched_utc
#
# Sources: the Price List bulk offer files (pricing.us-east-1.amazonaws.com)
# for every service except EC2 instances, whose offer file is ~430 MB; those
# come from the price map the AWS EC2 pricing page itself loads. NAT Gateway
# and EBS gp3 are also EC2 SKUs: they are streamed out of the EC2 CSV.
set -euo pipefail
# shellcheck source=scripts/lib/tools.sh
. "$(dirname "$0")/lib/tools.sh"
cd "$(repo_root)"
out=docs/cost-prices.csv
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
today=$(date -u +%F)
bulk=https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws
ec2web='https://b0.p.awsstatic.com/pricing/2.0/meteredUnitMaps/ec2/USD/current/ec2-ondemand-without-sec-sel/EU%20(Frankfurt)/Linux/index.json'

# offer <service> <item> <jq product filter> [first]: a CSV row per matching
# SKU's lowest non-zero on-demand tier; "first" keeps only one row. (Done in jq:
# piping into head would close the pipe under jq and trip pipefail.)
offer() {
  local svc=$1 item=$2 filter=$3 first=${4:-} f="$tmp/$1.json"
  [ -s "$f" ] || curl -sf --max-time 300 -o "$f" "$bulk/$svc/current/eu-central-1/index.json"
  tool_jq -r --arg item "$item" --arg src "$bulk/$svc/current/eu-central-1/index.json" --arg day "$today" --arg first "$first" "
    . as \$o | [.products | to_entries[] | select(.value | $filter) | .key as \$sku
      | [\$o.terms.OnDemand[\$sku][]?.priceDimensions[]? | select((.pricePerUnit.USD | tonumber) > 0)]
      | sort_by(.beginRange | tonumber? // 0) | .[0] | select(. != null)]
    | (if \$first == \"first\" then .[:1] else . end) | .[]
    | [\$item, .pricePerUnit.USD, .unit, .description, \$src, \$day] | @csv" < "$f"
}

log "fetching AWS eu-central-1 prices ($today)"
{
  echo '"item","usd","unit","description","source","fetched_utc"'
  offer AmazonEKS "EKS cluster" '.attributes.usagetype == "EUC1-AmazonEKS-Hours:perCluster"'
  for t in db.r7g.large db.t4g.medium; do
    for d in Multi-AZ Single-AZ; do
      offer AmazonRDS "RDS PostgreSQL $t $d" ".productFamily == \"Database Instance\" and .attributes.instanceType == \"$t\" and .attributes.databaseEngine == \"PostgreSQL\" and .attributes.deploymentOption == \"$d\" and (.attributes.usagetype | test(\"UnusedBox\") | not)" first
    done
  done
  offer AmazonRDS "RDS gp3 storage Multi-AZ" '.productFamily == "Database Storage" and .attributes.volumeType == "General Purpose-GP3" and .attributes.deploymentOption == "Multi-AZ" and (.attributes.databaseEngine == "PostgreSQL" or .attributes.databaseEngine == "Any")' first
  offer AmazonRDS "RDS backup storage" '.attributes.usagetype == "EUC1-RDS:ChargedBackupUsage" and .attributes.databaseEngine == "PostgreSQL"' first
  for t in cache.m7g.large cache.t4g.small; do
    offer AmazonElastiCache "ElastiCache Valkey $t" ".productFamily == \"Cache Instance\" and .attributes.instanceType == \"$t\" and .attributes.cacheEngine == \"Valkey\" and (.attributes.usagetype | test(\"SyncDurability\") | not)" first
  done
  offer AWSELB "NLB hour" '.productFamily == "Load Balancer-Network" and .attributes.usagetype == "EUC1-LoadBalancerUsage"'
  offer AWSELB "NLB LCU hour" '.productFamily == "Load Balancer-Network" and .attributes.usagetype == "EUC1-LCUUsage"'
  offer AWSSecretsManager "Secrets Manager secret" '.attributes.usagetype == "EUC1-AWSSecretsManager-Secrets"'
  offer awskms "KMS customer managed key" '.attributes.usagetype == "eu-central-1-KMS-Keys" or .attributes.usagetype == "EUC1-KMS-Keys"' first
  offer AmazonVPC "Public IPv4 address" '.attributes.usagetype == "EUC1-PublicIPv4:InUseAddress"'
  offer AWSDataTransfer "Data transfer out to internet" '.attributes.fromLocation == "EU (Frankfurt)" and .attributes.toLocation == "External" and .attributes.transferType == "AWS Outbound"' first

  # EC2 instances: the page's price map (gzip), keyed by instance type.
  curl -sf --compressed --max-time 120 -o "$tmp/ec2.json" "$ec2web"
  tool_jq -r --arg src "$ec2web" --arg day "$today" '
    .regions["EU (Frankfurt)"] | to_entries[] | .value
    | select(.["Instance Type"] == "m7i.large" or .["Instance Type"] == "m7i.xlarge")
    | ["EC2 " + .["Instance Type"] + " Linux on-demand", .price, "Hrs", (.["Instance Type"] + ", " + .vCPU + " vCPU, " + .Memory), $src, $day] | @csv' < "$tmp/ec2.json"

  # NAT Gateway and EBS gp3 rows from the (large) EC2 CSV, streamed and filtered.
  csv="$bulk/AmazonEC2/current/eu-central-1/index.csv"
  curl -s --max-time 900 "$csv" \
    | grep -E '"EUC1-(NatGateway-Hours|NatGateway-Bytes|EBS:VolumeUsage\.gp3)"' | grep '"OnDemand"' \
    | awk -F'","' -v src="$csv" -v day="$today" '{
        item = ($0 ~ /NatGateway-Hours/) ? "NAT Gateway hour" : ($0 ~ /NatGateway-Bytes/) ? "NAT Gateway data processed" : "EBS gp3 storage"
        if (!seen[item]++) printf "\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\"\n", item, $10, $9, $5, src, day
      }' || true
} > "$out"
log "wrote $out ($(($(wc -l < "$out") - 1)) prices)"
