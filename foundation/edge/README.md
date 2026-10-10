# foundation-edge

- **Owner:** platform-engineering · **Component id:** `foundation-edge` · **State key:** `<env>/foundation-edge.tfstate`
- **Purpose:** optional ingress/egress edge services. **Everything is off by default** (zero resources, zero cost; even the
  resource group is only created when one component is enabled).
- **Consumes:** `foundation-network` (`topology`, `spoke_vnet_id`, `spoke_address_space`, `subnets[appgw|apim|AzureBastionSubnet|AzureFirewallSubnet|AzureFirewallManagementSubnet]`).
  Secret inputs (registry `secret_env`, Delinea DSV via `tools/secrets/fetch.py`): `TF_VAR_tls_certificate_pfx` /
  `TF_VAR_tls_certificate_password` from `appgw-tls-pfx` (elements `value` = base64 PFX, `password`) - optional.
- **Produces:** `foundation-edge` v1 ([schema](../../catalog/contracts/foundation-edge.v1.schema.json)) incl. `public_endpoints`.
- **Status:** implemented (validate + mock tests); every component **disabled** by default. Not deployed.

| Component | Setting | Defaults / notes | Network prerequisite |
|---|---|---|---|
| Application Gateway **WAF_v2** | `app_gateway.enabled` | autoscale 0–2, WAF policy `Microsoft_DefaultRuleSet 2.1` + `Microsoft_BotManagerRuleSet 1.1` in Prevention, TLS policy `AppGwSslPolicy20220101`, HTTPS listener with the PFX certificate from Delinea DSV (`ssl_certificate.data`/`password` from the pipeline inputs `tls_certificate_pfx`/`tls_certificate_password`), HTTP→HTTPS redirect, backend pool = `backend_fqdns`, probe `/healthz`; no identity (no Key Vault) | `appgw_subnet = true` |
| Front Door Standard/Premium | `front_door.enabled` | WAF policy (rate-limit custom rule; Premium adds DRS 2.1 + Bot Manager), endpoint, origin group (probe `/healthz`), origins from `front_door.origins`, HTTPS-only forwarding; **Private Link origins** (`origins[].private_link`) need Premium and must be approved on the origin | none |
| API Management | `apim.enabled` | `StandardV2_1`; v2 tiers are BasicV2 / StandardV2 / PremiumV2 (GA). `vnet_integration` = StandardV2/PremiumV2 *outbound* integration into the `apim` subnet (delegated `Microsoft.Web/serverFarms`, NSG allows KeyVault 443); gateway stays public. Full injection = PremiumV2 only. `Developer_1` (classic) is accepted too | `apim_subnet = true` when integrated |
| Azure Firewall Basic/Standard | `firewall.enabled` | policy (threat intel Alert on Basic — only mode Basic supports — Deny on Standard), app rules: HTTPS to `allowed_fqdns` + FQDN tag `AzureKubernetesService`; network rules NTP + AzureMonitor 443; Basic adds management IP config | `topology = hub-spoke`, `firewall_subnet = true`; then network `egress = firewall` (two-pass, see network README) |
| Azure Bastion | `bastion.enabled` | `Developer` SKU (free; no subnet/public IP; attaches to the spoke VNet; limited regions, no peering) — `Basic`/`Standard` use `AzureBastionSubnet` + public IP | `bastion_subnet = true` for Basic/Standard |

## Cost when enabled (approximate list prices, USD/month, Oct 2026; verify with the pricing calculator)

| Component | Fixed | Variable |
|---|---|---|
| App Gateway WAF_v2 | ≈ 325 (gateway hours, min capacity 0) | capacity units ≈ 0.0144/CU-h, data |
| Front Door Standard / Premium | ≈ 35 / ≈ 330 base | requests + data transfer |
| APIM BasicV2 / StandardV2 | ≈ 150 / ≈ 700 per unit | extra requests over included quota |
| Firewall Basic / Standard | ≈ 290 / ≈ 910 | 0.065 / 0.016 per GB processed |
| Bastion Developer / Basic / Standard | 0 / ≈ 140 / ≈ 210 | outbound data |

Front Door, App Gateway and APIM are the expensive parts of the `enterprise`/`full` profiles; enable only what a scenario needs.

## Teardown and data retention

No application data. App Gateway/Front Door/APIM/Firewall delete in 5–30 minutes; APIM v2 is soft-deleted for 48 h
(re-create with the same name requires purge: `az apim deletedservice purge`). Switch network `egress` back to
`nat-gateway` **before** destroying the firewall, otherwise spoke egress breaks.

## Private networking notes

- App Gateway backends are typically internal FQDNs (ACA internal environment, AKS internal ingress) resolved through the
  private DNS zones linked to the VNet hosting the gateway (hub in hub-spoke — zones are linked to both VNets).
- Front Door Premium private link origins avoid exposing origins publicly; Standard origins must be public — restrict
  them to the `AzureFrontDoor.Backend` service tag and the `X-Azure-FDID` header (`contract.front_door.front_door_id`).

## Known limitations

- APIM v2 VNet integration through `virtual_network_type = "External"` in azurerm 5.9 is not covered by provider docs for
  v2 SKUs; validated only by `terraform validate` + mocks — confirm on first deploy (status stays `implemented`).
- No custom domains/certificates for Front Door (uses the `*.azurefd.net` endpoint).
- Firewall rules are a lab baseline; extend `allowed_fqdns` per platform component (AKS, ARO, SQL MI have documented egress lists).

## TLS certificate (Delinea DSV)

Key Vault certificate references are no longer available (ADR-0001 section 14: all secrets live in Delinea DSV). The
App Gateway listener certificate is the DSV secret `<prefix>/<env>/appgw-tls-pfx` (element `value` = base64 PFX,
element `password` = PFX password), fetched by the pipeline (`tools/secrets/fetch.py exec`, deploy agent identity) and
passed as `TF_VAR_tls_certificate_pfx` / `TF_VAR_tls_certificate_password` to the terraform process only.
**azurerm 5.9 has no write-only form of `ssl_certificate.data` / `password`** (checked with tfschema), so the PFX and
its password **are stored in Terraform state and in the saved plan** (both in the protected bootstrap containers,
`docs/known-limitations.md`). Rotation = update the DSV secret, re-run foundation-edge (plan shows the certificate change).

**Recommended instead:** Front Door (`front_door.enabled`) — its default `*.azurefd.net` endpoint uses a
Microsoft-managed certificate and custom domains can use Front Door managed certificates
(`azurerm_cdn_frontdoor_custom_domain` `tls { certificate_type = "ManagedCertificate" }`), so no certificate secret
exists at all. Use App Gateway only when you need regional WAF in the VNet.

## Validation

```bash
tools/validate/terraform.sh foundation/edge   # fmt, init -backend=false, validate, terraform test (mock providers, no credentials)
```

## References

- App Gateway infrastructure + NSG: https://learn.microsoft.com/azure/application-gateway/configuration-infrastructure
- App Gateway SSL certificates (`ssl_certificate` data/password): https://learn.microsoft.com/azure/application-gateway/ssl-overview
- Front Door managed certificates: https://learn.microsoft.com/azure/frontdoor/domain
- Front Door private link origins: https://learn.microsoft.com/azure/frontdoor/private-link
- API Management v2 tiers: https://learn.microsoft.com/azure/api-management/v2-service-tiers-overview
- APIM VNet integration (v2): https://learn.microsoft.com/azure/api-management/integrate-vnet-outbound
- Azure Firewall Basic: https://learn.microsoft.com/azure/firewall/basic-features
- Bastion SKUs: https://learn.microsoft.com/azure/bastion/configuration-settings
