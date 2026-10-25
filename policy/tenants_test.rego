package tenants

import rego.v1

# conftest --combine gives input = [{path, contents}] so the policy can also
# check that the file name matches the tenant name.
file(path, contents) := [{"path": path, "contents": contents}]

acme := {"name": "acme", "tier": "dedicated", "residency": "eu", "region": "eu-central-1", "ring": 1, "size": "small", "slo": "99.95"}

test_valid_dedicated_eu_tenant_allowed if {
	count(deny) == 0 with input as file("tenants/acme.yaml", acme)
}

test_eu_tenant_in_us_region_denied if {
	t := object.union(acme, {"region": "us-east-1"})
	some msg in deny with input as file("tenants/acme.yaml", t)
	contains(msg, "EU residency")
}

test_eu_tenant_in_frankfurt_allowed if {
	count(deny) == 0 with input as file("tenants/acme.yaml", acme)
}

test_eu_tenant_in_london_denied if {
	# eu-west-2 is London: the UK is not in the EU.
	t := object.union(acme, {"region": "eu-west-2"})
	some msg in deny with input as file("tenants/acme.yaml", t)
	contains(msg, "EU residency")
}

test_dedicated_without_ring_denied if {
	t := object.remove(acme, ["ring"])
	some msg in deny with input as file("tenants/acme.yaml", t)
	contains(msg, "ring")
}

test_dedicated_with_ring_zero_denied if {
	t := object.union(acme, {"ring": 0})
	some msg in deny with input as file("tenants/acme.yaml", t)
	contains(msg, "ring")
}

test_bad_slo_denied if {
	t := object.union(acme, {"slo": "99.99"})
	some msg in deny with input as file("tenants/acme.yaml", t)
	contains(msg, "slo")
}

test_bad_tier_denied if {
	t := object.union(acme, {"tier": "premium"})
	some msg in deny with input as file("tenants/acme.yaml", t)
	contains(msg, "tier")
}

test_shared_tenant_needs_no_ring if {
	t := {"name": "initech", "tier": "shared", "residency": "eu", "region": "eu-west-1", "slo": "99.9"}
	count(deny) == 0 with input as file("tenants/initech.yaml", t)
}

test_filename_must_match_name if {
	some msg in deny with input as file("tenants/other.yaml", acme)
	contains(msg, "file name")
}

test_invalid_name_denied if {
	t := object.union(acme, {"name": "Acme_Corp"})
	some msg in deny with input as file("tenants/Acme_Corp.yaml", t)
	contains(msg, "name")
}
