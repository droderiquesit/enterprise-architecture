# platform/compute/containerapps — Container Apps environment

| | |
|---|---|
| Component id | `platform-containerapps` |
| Owner | platform team (compute) |
| Consumes | `foundation-network` (`subnets.aca-infra` — delegated `Microsoft.App/environments`, /23+, `spoke_vnet_id`, `hub_vnet_id`), `platform-shared` (`log_analytics_workspace_id` only when `logs_destination = "log-analytics"`) |
| Produces | `platform-containerapps` v1 |
| Status | `implemented` |

## What it creates

- Workload-profiles environment injected into `aca-infra` with profiles **`Consumption`** and
  **`dedicated-d4`** (type `D4`, min 0 / max 1 by default).
- `logs_destination = "azure-monitor"`: system/console logs flow only where diagnostic settings send them
  (owned by obs-diagnostics → `ContainerAppSystemLogs`; application logs use the Fluent Bit sidecar, ADR §10).
- Internal mode: a private DNS zone named after the generated `default_domain` with `*` and `@` A records →
  environment static IP, linked to the spoke (and hub) VNets. The zone name only exists after the environment
  is created, so it is owned here (not by foundation-network) and dies with the environment.

Not here: container apps, jobs, Dapr components, secrets (applications/deployments roots), diagnostic settings.

## Ingress decision (`ingress_mode`)

| Mode | Default for | Behaviour |
|---|---|---|
| **`external`** (root default) | minimal profile (no Application Gateway / Front Door) | VNet-integrated environment with a public static IP; **each app chooses**: only `hello-bff` (and the nginx frontend variant) set `external_enabled = true`, every other app/job uses internal ingress (environment-only). Outbound still via the VNet/NAT. |
| `internal` | enterprise (set in `components.platform-containerapps`) | ILB only, `public_network_access = Disabled`; public entry via foundation-edge Application Gateway → environment static IP; private DNS zone created. |

The contract exposes `ingress_mode`, `internal`, `default_domain`, `static_ip_address` so app roots and the
edge can wire themselves.

## Settings

`ingress_mode`, `zone_redundancy_enabled` (false), `mutual_tls_enabled` (false), `logs_destination`
(`azure-monitor` | `log-analytics` | `none`), `dedicated_profile{enabled,name,type,min_count,max_count}`
(validated 0 ≤ min ≤ max ≤ 10), `private_dns_enabled`, `extra_dns_vnet_links`.

## Cost at defaults (approx.)

Consumption profile: pay per use (idle apps with min replicas 0 cost ~0). Dedicated `D4` profile: billed per
running instance (~USD 0.3–0.4/h) plus the Dedicated plan management charge while dedicated profiles exist —
check the ACA pricing page for the region. The obs OTel gateway pinned to `dedicated-d4` keeps one instance
running (~USD 250+/month); keep it on Consumption to avoid that.

## Teardown / retention

Destroy deletes the environment (all apps in it must be destroyed first by their roots), the infrastructure
resource group `…-infra` and the private DNS zone. No persistent data.

## Docs

- https://learn.microsoft.com/azure/container-apps/networking
- https://learn.microsoft.com/azure/container-apps/workload-profiles-overview
- https://learn.microsoft.com/azure/container-apps/private-endpoints-with-dns
- https://learn.microsoft.com/azure/container-apps/log-options
