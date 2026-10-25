# charts/tenant-route/ — code review

**Purpose:** a **shared** tenant is a host route onto the shared prod stack, not a stack of its own. It is rendered once per `tenants/<name>.yaml` with `tier: shared`, by the `tenants-shared` ApplicationSet.

| File | What it does |
|---|---|
| `templates/ingressroute.yaml` | `IngressRoute tenant-<name>` in `app-prod`: `Host(<name>.localtest.me)` → the shared stack's weighted `TraefikService api`. The tenant therefore **rides the shared stack's canaries** (ring 0) with no extra deploys. Rendering fails if `tenant.name` is missing. |
| `templates/prometheusrule.yaml` | A per-tenant availability SLI from **this tenant's Traefik router**, `router=~"app-prod-tenant-<name>-.*"`, across the same windows as `charts/app`. A `ZdpTenantErrorBudgetBurnPage` alert uses the same 14.4×/6× multi-window logic. |
| `values.yaml` | `tenant.name`, `tenant.slo`, an optional `tenant.host`; the shared stack's namespace and TraefikService |
| `Chart.yaml` / `.helmignore` | Chart metadata (published with the app chart's pipeline); `.helmignore` keeps this review out of the package |

**Key decision, per-tenant visibility without changing the black box:** a shared app can't be relied on to label metrics by tenant. Giving each tenant its own *router* at the ingress (one host = one router) yields per-tenant request rate, errors and latency from Traefik alone (`addRoutersLabels: true`).

**Verify:** `helm template t charts/tenant-route --set tenant.name=initech | kubeconform`, then promtool on the rule spec. Both pass.

**Limitations:**
- A shared tenant's latency SLI isn't computed per tenant: router latency histograms exist, but only availability is wired up.
- Noisy-neighbour isolation is the price of the shared tier. Tenants that need isolation go dedicated.

**Label:** RUN-LOCAL (stand-in).
