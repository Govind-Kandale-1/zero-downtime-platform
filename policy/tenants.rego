# Tenant onboarding policy: every tenants/<name>.yaml must pass this before it
# can merge. It turns the EU-residency requirement from documentation into an
# enforced check (spec §11).
#
# Run: conftest test --combine --namespace tenants -p policy tenants/*.yaml
# (--combine passes [{path, contents}] so file names can be checked too.)
package tenants

import rego.v1

# EU member-state regions only. Deliberately excluded: eu-west-2 (London, UK)
# and eu-central-2 (Zurich, Switzerland) - "eu-" in the name is not the EU.
eu_regions := {"eu-central-1", "eu-west-1", "eu-west-3", "eu-north-1", "eu-south-1", "eu-south-2"}

tiers := {"shared", "dedicated"}

residencies := {"eu", "us", "none"}

slos := {"99.9", "99.95"}

sizes := {"small", "medium"}

deny contains msg if {
	some f in input
	t := f.contents
	t.residency == "eu"
	not t.region in eu_regions
	msg := sprintf("%s: EU residency requires an EU region, got %q", [f.path, t.region])
}

deny contains msg if {
	some f in input
	not f.contents.residency in residencies
	msg := sprintf("%s: residency must be one of %v", [f.path, residencies])
}

deny contains msg if {
	some f in input
	not f.contents.tier in tiers
	msg := sprintf("%s: tier must be one of %v", [f.path, tiers])
}

deny contains msg if {
	some f in input
	f.contents.tier == "dedicated"
	not valid_ring(f.contents)
	msg := sprintf("%s: dedicated tenants need an integer ring >= 1", [f.path])
}

deny contains msg if {
	some f in input
	f.contents.tier == "dedicated"
	not f.contents.size in sizes
	msg := sprintf("%s: dedicated tenants need size in %v", [f.path, sizes])
}

deny contains msg if {
	some f in input
	not f.contents.slo in slos
	msg := sprintf("%s: slo must be one of %v (quoted string)", [f.path, slos])
}

deny contains msg if {
	some f in input
	not regex.match(`^[a-z][a-z0-9-]{1,20}$`, f.contents.name)
	msg := sprintf("%s: name must match ^[a-z][a-z0-9-]{1,20}$", [f.path])
}

deny contains msg if {
	some f in input
	base := regex.replace(f.path, `^.*[/\\]`, "")
	base != sprintf("%s.yaml", [f.contents.name])
	msg := sprintf("%s: file name must be <name>.yaml (name is %q)", [f.path, f.contents.name])
}

valid_ring(t) if {
	is_number(t.ring)
	t.ring == floor(t.ring)
	t.ring >= 1
}
