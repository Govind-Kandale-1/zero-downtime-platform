# policy/ — code review

**Purpose:** turn tenant rules, above all **EU data residency**, from documentation into a merge-blocking CI check (spec §11). Kyverno cluster policies live in `gitops/platform/` (P1).

| File | What it does |
|---|---|
| `tenants.rego` | Package `tenants` (Rego v1). Run with `conftest test --combine --namespace tenants -p policy tenants/*.yaml`; `--combine` passes `[{path, contents}]`, so file names can be checked. It **denies**: `residency: eu` with a region outside the EU set; an unknown residency, tier or SLO; a dedicated tenant without an integer `ring >= 1` or a valid `size`; a name not matching `^[a-z][a-z0-9-]{1,20}$`; a file name that isn't `<name>.yaml`. |
| `tenants_test.rego` | 11 unit tests (`conftest verify -p policy`): a valid dedicated EU tenant passes; EU in `us-east-1` is denied; EU in Frankfurt is allowed; **EU in London (`eu-west-2`) is denied**; dedicated without a ring, or with ring 0, is denied; bad SLO and bad tier are denied; a shared tenant needs no ring; the file name must match; an invalid name is denied. |

**Key decision:** the EU region set lists **EU member states only**. `eu-west-2` (London) and `eu-central-2` (Zurich) start with `eu-` but are outside the EU, so a naive `startswith("eu-")` check would leak EU data to the UK or Switzerland.

**Defence in depth (where else residency is enforced):**
- Terraform derives each tenant's provider region from the same file.
- On AWS, backups and snapshot copies stay in the residency zone.
- A sample SCP denies non-EU regions for EU accounts (`docs/policies/`, NOT RUN).

**Verify:**
- `source scripts/lib/tools.sh && tool_conftest verify -p policy`: 11 pass.
- `tool_conftest test --combine --namespace tenants -p policy tenants/*.yaml`: all pass.

**Label:** RUN-LOCAL.
