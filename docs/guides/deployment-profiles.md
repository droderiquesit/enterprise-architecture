# Deployment profiles

A profile ([`environments/profiles/<profile>.yaml`](../../environments/profiles/)) lists the components an environment
enables, high-level `features`, and `component_settings` that are deep-merged under the environment's own
`components.<id>` blocks. `tools/config/resolve.py --env <env>` prints the resolved set; for `custom` it adds required
upstream dependencies automatically, for every other profile it fails with an explanation when a hard dependency is
missing.

**Features are effective.** `tools/config/render.py` maps each profile feature to component settings
(`tools/config/features.py`; table in [environments/profiles/README.md](../../environments/profiles/README.md#feature-mapping)):
`topology`/`egress`/`firewall`/`app_gateway` -> foundation-network, `firewall`/`bastion`/`app_gateway`/`front_door`/`apim`
-> foundation-edge toggles, `service_bus_sku` -> platform-messaging `sku`, `rum_session_sample_rate`/`session_replay` ->
obs-prereqs RUM sample rates, `trace_sample_rate` -> `trace_sample_ratio` of every deploy root that declares it.
`private_endpoints` and `deploy_lab_infrastructure` are documented-only; any other key is rejected. Example:
`enterprise` says `bastion: true`, so foundation-edge renders `bastion.enabled = true` (Developer SKU, no subnet needed).

Precedence for a root's `settings`: root `variables.tf` defaults < profile `features` (mapped) < profile
`component_settings.<id>` < `environments/<env>/environment.yaml components.<id>`.

## Profiles at a glance

| Profile | Components | Topology / egress | Notable settings | `expensive` / confirmation |
|---|---:|---|---|---|
| [`minimal`](../../environments/profiles/minimal.yaml) | 28 | single spoke, NAT Gateway | Container Apps `ingress_mode: external`; Service Bus Standard; ACR Standard (root default) | no / no |
| [`enterprise`](../../environments/profiles/enterprise.yaml) | 48 | hub-spoke, NAT Gateway | ACA internal; Service Bus Premium; ACR Premium + private endpoint, public access off; private deploy agents | no / no |
| [`full`](../../environments/profiles/full.yaml) | 60 | hub-spoke, NAT Gateway | as enterprise + Batch, Service Fabric, SQL VM, all Cosmos APIs, DocumentDB, Ledger, analytics, Logic Apps; deployed in groups | yes / yes |
| [`specialized`](../../environments/profiles/specialized.yaml) | 21 | hub-spoke | SF, ARO, specialized compute, SQL MI, Cassandra MI, HorizonDB - each still gated by its own `enabled` setting and prerequisites | yes / yes |
| [`observability-only`](../../environments/profiles/observability-only.yaml) | 3 | none | `obs-prereqs`, `obs-azure-integration`, `obs-monitoring` only | no / no |
| [`custom`](../../environments/profiles/custom.yaml) | `custom_components` | per settings | dependencies auto-added | per selection |

Counts are the `components:` lists of the profile files (artifact builds included). Exact membership per component:
[component-ownership.md](component-ownership.md) ("Profiles" column).

## minimal

Smallest end-to-end slice: Static Web Apps frontend -> BFF / orders / catalog on Container Apps -> Azure SQL + PostgreSQL,
Service Bus Standard, Durable Functions on Flex Consumption, partner-sim on ACI, ACA jobs (seed, reconcile, traffic,
batch-items), telemetry transport, diagnostics, DBM and monitoring.

```yaml
# environments/dev/environment.yaml
environment:
  name: dev
  location: swedencentral
  subscription_id: "<subscription guid>"
  tenant_id: "<tenant guid>"
  name_prefix: eh
  owner: platform-team@example.com
  team: platform-engineering
  cost_center: lab-0001
  expires_on: "2026-12-31"
  tags: {}
profile: minimal
custom_components: []
datadog: {site: datadoghq.com, api_key_secret_name: datadog-api-key, app_key_secret_name: datadog-app-key}
network: {hub_address_space: 10.40.0.0/20, spoke_address_space: 10.41.0.0/16}
budget: {monthly_amount: 500, currency: USD, contact_emails: [platform-team@example.com]}
components:
  bootstrap:
    operator_ip_ranges: ["203.0.113.10"]
    operator_principal_ids: ["<group object id>"]
    federated_credentials: []
```

Cost assumptions (approximate list prices, USD/month, at root defaults, from each root README; verify with the Azure
pricing calculator - nothing here has been billed):

| Component | Estimate | Main driver |
|---|---:|---|
| foundation-network | ~50 | NAT Gateway (~33) + public IP + ~27 private DNS zones |
| foundation-identity | ~8 | Key Vault private endpoint |
| platform-shared | ~20 | ACR Standard; Log Analytics capped at 1 GB/day |
| platform-messaging | ~10 | Service Bus Standard |
| platform-containerapps | ~0 idle | Consumption profile; `dedicated-d4` min 0 |
| platform-functions | ~46 | 6 private endpoints (~44) + 2 storage accounts; Flex on demand |
| platform-db-sql | ~35-50 | S0 + Basic + serverless (auto-pause 60 min) + private endpoint |
| platform-db-postgresql | ~17 | B1ms + 32 GB |
| deploy-core-aca | ~15-20 | scale to zero, 10 % duty assumption |
| deploy-partner-sim | ~35 | ACI 0.75 vCPU / 1.5 GB always on |
| deploy-jobs | ~15 | traffic job 1 vCPU x 7 min x 48/day |
| deploy-frontend | 0 | SWA Free |
| obs-telemetry-transport | ~110 | Event Hubs Standard 1 TU (~22) + two always-on 0.5 vCPU / 1 GiB Container Apps (~80) + private endpoint |
| obs-dbm | ~45 | Datadog Agent on ACI, 1 vCPU / 2 GB always on |
| Datadog | billed by Datadog | RUM sessions, synthetic runs (tests created **paused**), APM/infra hosts, logs, DBM |

Order of magnitude: roughly USD 400-450/month before Datadog charges. `environments/dev/environment.yaml` therefore sets
`budget.monthly_amount: 500` (estimate + ~10 % headroom); foundation-governance reads that global (`var.budget`) unless
`components.foundation-governance.budget.amount` overrides it (root fallback 300). The minimal profile creates only
the `fulfillment` Service Bus subscription (the only `order-events` consumer in the profile).

## enterprise

Common enterprise patterns on hub-spoke with private deploy agents.

```yaml
profile: enterprise
components:
  foundation-network:
    bastion_subnet: true          # only if you also enable Bastion Basic/Standard in foundation-edge
  foundation-deploy-agents:
    vmss: {admin_ssh_public_key: "ssh-ed25519 AAAA..."}   # required in vmss mode
  # foundation-edge bastion.enabled comes from the profile feature `bastion: true` (Developer SKU)
```

Adds (approx., per root READMEs): AKS ~110, App Service plans ~150 (P0v3 Linux + Windows), VM hosts ~110 24x7 (less
with the 19:00 UTC auto-shutdown), VMSS ~76, MySQL ~15, Cosmos NoSQL < 5 + PE, Managed Redis ~15-25, Table Storage ~8,
Service Bus **Premium ~680 per messaging unit** + PE, ACR Premium ~50 + PE, Functions EP1 ~150 when the premium host
is enabled for `deploy-functions`. Service Bus Premium dominates; switch `components.platform-messaging.sku: Standard`
for a cheaper enterprise lab (private endpoint then not possible).

## full

Every implemented and eligible catalog entry. `requires_confirmation: true`. Deploy it **in groups** - the profile
lists `groups` `g1-foundation`, `g2-core-platform`, `g3-compute`, `g4-data`, `g5-apps`, `g6-observability`. The
pipeline itself orders stages by dependency; groups are an operator procedure to bound blast radius and cost:

1. Start from `profile: custom` with `custom_components` = the components of `g1` (+ `g2`), run the pipeline.
2. Add the next group's components to `custom_components`, run again; repeat to `g6`.
3. Switch to `profile: full` when everything is applied (selection then finds no differences for already-applied
   components because fingerprints match their records).

Service Fabric (`platform-servicefabric`) is in `full` but its root defaults to `enabled = false`; set
`components.platform-servicefabric.enabled: true` plus certificate/Entra settings to create the cluster (~USD 460/month).

## specialized

Expensive, restricted, partner or preview services; every root still requires its own `enabled = true` and documented
prerequisites ([known limitations](../known-limitations.md#blocked-and-disabled-services)): ARO (44 vCPU quota, RP
service principal, version, pull secret; > USD 2,000/month), SQL MI (~700-800/month, first deploy 4-6 h), Cassandra MI
(~1,500+), HorizonDB (preview access), confidential/dedicated-host/GPU VMs, Automation, Azure ML. With defaults these
roots create nothing (or only report `status = blocked`).

## observability-only

Applies Datadog content to existing resources: `obs-prereqs` (RUM application), `obs-azure-integration`,
`obs-monitoring`. Use it with manifests that reference existing resource IDs. For a separate organisation-level adoption
outside this lab, use the package release directly: [observability-production-adoption.md](observability-production-adoption.md).

## custom

```yaml
profile: custom
custom_components: [deploy-core-aca, deploy-durable, obs-monitoring]
```

`resolve.py` adds every hard dependency (`consumes`) transitively; optional producers are used only when enabled.

## Budgets do not cap spend

`foundation-governance` creates a monthly consumption budget (environment `budget.monthly_amount`, root fallback 300; filter `application=enterprise-hello` and
`env=<env>`) with actual 50/80/100 % and forecast 80/100 % notifications. **Azure budgets only alert; resources keep
running and keep costing money**, and cost data lags by up to about 24 hours. Stopping spend is a human decision (or
automation you add). Cost controls that are implemented: [cost-and-lifecycle.md](cost-and-lifecycle.md).
