# platform/shared — container registry + platform Log Analytics

| | |
|---|---|
| Component id | `platform-shared` (state `<env>/platform-shared.tfstate`) |
| Owner | platform team (compute) |
| Consumes | `foundation-network` (`subnets.private-endpoints`, `private_dns_zones.acr`), `foundation-identity` (`identities.*.principal_id`) |
| Produces | `platform-shared` v1 — `catalog/contracts/platform-shared.v1.schema.json` |
| Status | `implemented` (fmt/validate/mock tests); not deployed |

## What it creates

- Resource group `<prefix>-rg-shared-<env>-<region>`.
- **Azure Container Registry** (`azurerm_container_registry`), Entra ID only: `admin_enabled = false`,
  `anonymous_pull_enabled = false`. `AcrPull` for every workload identity + `aks-kubelet`, `AcrPush` for
  `deploy-agent` (identities missing from the contract are skipped and listed in the contract).
- **Log Analytics workspace** (30-day retention, 1 GB/day cap, shared-key auth off) for platform
  features that require one (AKS Defender opt-in, ACA `log-analytics` destination). Application logs never
  go here (ADR-0001 §10: Fluent Bit → Datadog).

Not here: diagnostic settings (obs-diagnostics), images (application builds).

## ACR SKU decision (minimal vs enterprise)

| | Basic / **Standard (default)** | Premium |
|---|---|---|
| Private endpoint / `public_network_access_enabled = false` | not supported | supported (`acr_private_endpoint_enabled`, `acr_public_network_access_enabled = false`) |
| Auth | Entra ID tokens only (admin + anonymous off) | same |
| Zone redundancy, retention policy, dedicated data endpoints | no | yes (settings) |
| Approx. cost | ~USD 20/month (Standard) | ~USD 50/month + PE ~USD 7/month |

Minimal profile: no self-hosted agents in the VNet, so hosted CI must push images over the public endpoint →
Standard + Entra-only is the pragmatic default. Enterprise profile: set `acr_sku = "Premium"`,
`acr_private_endpoint_enabled = true`, `acr_public_network_access_enabled = false` (requires
`foundation-deploy-agents` for pushes). Validations reject PE/private settings on non-Premium SKUs.

## Settings (`components.platform-shared`)

| Setting | Default | Notes |
|---|---|---|
| `acr_sku` | `Standard` | Basic/Standard/Premium |
| `acr_private_endpoint_enabled` / `acr_public_network_access_enabled` | `false` / `true` | Premium only |
| `acr_zone_redundancy_enabled`, `acr_retention_days` | `false`, `7` | Premium only |
| `acr_pull_identities` | all workload identities + `aks-kubelet` | foundation identity keys |
| `acr_push_identities` | `["deploy-agent"]` | |
| `log_analytics_retention_days` / `log_analytics_daily_quota_gb` | `30` / `1` | |
| `log_analytics_local_auth_enabled` | `false` | enable only for ACA `log-analytics` destination |

## Cost at defaults (approx., swedencentral, USD/month)

ACR Standard ~20 + Log Analytics ingestion (near zero expected; worst case at the 1 GB/day cap ≈ 30 GB
× ~2.3 ≈ 70). Assumes no geo-replication and no Defender plans.

## Teardown / retention

`terraform destroy` deletes the registry (all images — rebuildable from source) and the workspace (soft-deleted
workspaces can be recovered for 14 days). No `prevent_destroy`: everything here is reproducible.

## Private networking

Standard/Basic registries are public endpoints protected by Entra ID RBAC. Premium + PE uses the
`acr` private DNS zone from foundation-network (zone group omitted if the key is absent).

## Known limitations

- Image vulnerability scanning is Microsoft Defender for Containers (subscription plan), not configured here.
- Checkov findings on registry hardening are justified inline (`#checkov:skip`).

## Docs

- https://learn.microsoft.com/azure/container-registry/container-registry-skus
- https://learn.microsoft.com/azure/container-registry/container-registry-private-link
- https://learn.microsoft.com/azure/container-registry/container-registry-authentication-managed-identity
- https://learn.microsoft.com/azure/azure-monitor/logs/daily-cap
