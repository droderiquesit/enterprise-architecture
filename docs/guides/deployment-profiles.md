# Deployment profiles and cost

A profile ([`environments/profiles/<profile>.yaml`](../../environments/profiles/)) lists the components an environment
enables, high-level `features` and `component_settings`. Schema, settings precedence and the feature -> setting
mapping: [environments/profiles/README.md](../../environments/profiles/README.md#feature-mapping).
`tools/config/resolve.py --env <env>` prints the resolved set; for `custom` it adds hard dependencies automatically,
for every other profile it fails with an explanation when one is missing.

Prices are approximate list prices from the root READMEs (USD/month, Oct 2026, not checked against the pricing API);
nothing has been billed - no environment has been deployed.

## Profiles at a glance

| Profile | Components | Topology / egress | Notable settings | `expensive` / confirmation |
|---|---:|---|---|---|
| [`minimal`](../../environments/profiles/minimal.yaml) | 29 | single spoke, NAT Gateway | Container Apps `ingress_mode: external`; Service Bus Standard; ACR Standard (root default) | no / no |
| [`enterprise`](../../environments/profiles/enterprise.yaml) | 51 | hub-spoke, NAT Gateway | ACA internal; Service Bus Premium; ACR Premium + private endpoint, public access off; private deploy agents | no / no |
| [`full`](../../environments/profiles/full.yaml) | 63 | hub-spoke, NAT Gateway | as enterprise + Batch, Service Fabric, SQL VM, all Cosmos APIs, DocumentDB, Ledger, analytics, Logic Apps; deployed in groups | yes / yes |
| [`specialized`](../../environments/profiles/specialized.yaml) | 22 | hub-spoke | SF, ARO, specialized compute, SQL MI, Cassandra MI, HorizonDB - each still gated by its own `enabled` setting and prerequisites | yes / yes |
| [`observability-only`](../../environments/profiles/observability-only.yaml) | 2 | none | `obs-prereqs`, `obs-azure-integration` only | no / no |
| [`custom`](../../environments/profiles/custom.yaml) | `custom_components` | per settings | dependencies auto-added | per selection |

Counts are the `components:` lists of the profile files (artifact builds included); membership per component:
[component-ownership.md](component-ownership.md) ("Profiles" column). Optional components (`optional: true`, currently
`obs-monitoring`) are in no built-in profile; enable them with `custom`.

## minimal

Smallest end-to-end slice: Static Web Apps frontend -> BFF / orders / catalog on Container Apps -> Azure SQL +
PostgreSQL, Service Bus Standard (only the `fulfillment` subscription), Durable Functions on Flex Consumption,
partner-sim on ACI, ACA jobs, telemetry transport, diagnostics and DBM. Monitoring content is not in the profile.

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
budget: {enabled: false, currency: USD, contact_emails: [platform-team@example.com]}   # dev: no consumption budget
components:
  bootstrap:
    operator_ip_ranges: ["203.0.113.10"]
    operator_principal_ids: ["<group object id>"]
    federated_credentials: []
```

| Component | Estimate | Main driver |
|---|---:|---|
| foundation-network | ~50 | NAT Gateway (~33) + public IP + ~27 private DNS zones |
| foundation-identity, foundation-secrets | 0 | managed identities only; Delinea DSV is a separate subscription |
| platform-shared | ~20 | ACR Standard; Log Analytics capped at 1 GB/day |
| platform-messaging | ~10 | Service Bus Standard |
| platform-containerapps | ~0 idle | Consumption profile; `dedicated-d4` min 0 |
| platform-functions | ~46 | 6 private endpoints (~44) + 2 storage accounts; Flex on demand |
| platform-db-sql | ~35-50 | S0 + Basic + serverless (auto-pause 60 min) + private endpoint |
| platform-db-postgresql | ~17 | B1ms + 32 GB |
| deploy-core-aca | ~15-20 | scale to zero, 10 % duty assumption |
| deploy-partner-sim | ~46 | ACI 0.75 vCPU / 1.5 GB always on (~35) + Datadog Agent sidecar 0.25 vCPU / 0.5 GB (~11) |
| deploy-jobs | ~15 | traffic job 1 vCPU x 7 min x 48/day |
| deploy-frontend | 0 | SWA Free |
| obs-telemetry-transport | ~305 | Event Hubs Standard 1 TU (~22) + private endpoint (~7.5) + always-on Container Apps: OP Worker 2 x 1 vCPU / 2 GiB (~158), APM gateway 1 vCPU / 2 GiB (~79), OTel gateway 0.5 vCPU / 1 GiB (~40) |
| obs-dbm | ~45 | Datadog Agent on ACI, 1 vCPU / 2 GB always on |
| Datadog | billed by Datadog | RUM sessions, synthetic runs (created **paused**), APM/infra hosts, logs, DBM |

Order of magnitude: USD 600-650/month before Datadog charges; the Worker dominates (`op_worker` sizing in the fleet
policy).

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

Adds (approx.): AKS ~110, App Service plans ~150 (P0v3 Linux + Windows), VM hosts ~110 24x7 (less with the 19:00 UTC
auto-shutdown), VMSS ~76, MySQL ~15, Cosmos NoSQL < 5 + PE, Managed Redis ~15-25, Table Storage ~8, Service Bus
**Premium ~680 per messaging unit** + PE, ACR Premium ~50 + PE, Functions EP1 ~150 when enabled for `deploy-functions`.
Service Bus Premium dominates; `components.platform-messaging.sku: Standard` is cheaper (no private endpoint then).

## full

Every implemented and eligible catalog entry; `requires_confirmation: true`. Deploy it **in groups** (`g1-foundation`,
`g2-core-platform`, `g3-compute`, `g4-data`, `g5-apps`, `g6-observability`) to bound blast radius and cost:

1. Start from `profile: custom` with `custom_components` = the components of `g1` (+ `g2`), run the pipeline.
2. Add the next group's components, run again; repeat to `g6`.
3. Switch to `profile: full` (selection finds no differences for applied components: fingerprints match their records).

Service Fabric (`platform-servicefabric`, ~USD 460/month) is in `full` but defaults to `enabled = false`; set
`components.platform-servicefabric.enabled: true` plus certificate/Entra settings to create the cluster.

## specialized

Expensive, restricted, partner or preview services; every root still requires `enabled = true` and its prerequisites
([known limitations](../known-limitations.md#blocked-and-disabled-services)): ARO (> USD 2,000/month), SQL MI
(~700-800/month, first deploy 4-6 h), Cassandra MI (~1,500+), HorizonDB (preview access), confidential / dedicated-host /
GPU VMs, Automation, Azure ML. With defaults these roots create nothing (or report `status = blocked`).

## observability-only and custom

`observability-only` applies `obs-prereqs` (RUM application) and `obs-azure-integration` to existing resources. For an
adoption outside this lab use a package release directly ([service onboarding](service-onboarding-tutorial.md)).

```yaml
profile: custom
custom_components: [deploy-core-aca, deploy-durable, obs-monitoring]
```

`resolve.py` adds every hard dependency (`consumes`) transitively; optional producers are used only when enabled.

## Cost controls

Only controls that exist in code.

| Control | Where | Behaviour |
|---|---|---|
| Monthly budget | `foundation-governance` `budget.*` (environment `budget.enabled` / `monthly_amount`, root fallback enabled / 300; overridable per component) | actual 50/80/100 %, forecast 80/100 % e-mail + action group, filter `application=enterprise-hello` and `env=<env>`. **Alerts only - Azure budgets never stop spend**; cost data lags ~24 h. dev has no budget (`enabled: false`); test and prod do |
| `expires_on` tag | `environment.expires_on` -> `foundation/modules/tags` on every taggable resource | informational; nothing deletes on expiry |
| Expired-resource finder | [`find-expired.sh`](../../foundation/governance/scripts/find-expired.sh) | Resource Graph query on `application == enterprise-hello` **and** `repository == azure-enterprise-observability-lab` and `expires_on < now`; `--print-delete-commands` prints (never runs) `az group delete` |
| Required RG tags / allowed locations | `foundation-governance` `policy.*` | tags **audit** (platform-managed RGs would be denied); locations **enforced** |
| Cost warnings in plans | `tools/validate/plan_policy.py` | expensive types and SKU/size/capacity changes flagged in the plan summary |

### Default SKUs and ceilings

| Resource | Default | Ceiling (validated in `variables.tf`) |
|---|---|---|
| AKS | Free tier, system pool 1-2 x D2s_v5 | `system_pool`/`user_pool` max <= 10 / 20 |
| Container Apps | Consumption, min replicas 0; `dedicated-d4` min 0 max 1 | `replica_ceiling` 5 (ACA) / 6 (AKS deployments); dedicated 0 <= min <= max <= 10 |
| App Service / Functions | P0v3 Linux + Windows; Flex FC1 on demand; Windows container P1v3, WS1, EP1, Y1, Durable Task Scheduler off | WS1 / EP1 elastic <= 3 |
| VM / VMSS | B2s_v2; VMSS Flexible 1/1/3, Uniform 1/1/2, CPU autoscale | `max_instances` <= 10 |
| Batch | pool autoscale 0 -> 2 nodes on pending tasks | `max_dedicated_nodes` |
| Deploy agents | VMSS at 0 instances (Azure DevOps scales); MDP `max_concurrency` 2 | - |
| SQL | S0 (`orders`), serverless GP_S_Gen5_1 auto-pause 60 min (`fulfillment`), Basic (`adapter`) | elastic pool / Hyperscale disabled |
| PostgreSQL / MySQL | B1ms burstable, no HA, no geo backup | elastic cluster disabled |
| Cosmos DB / Managed Redis | serverless accounts / Balanced_B0, HA off, no persistence | - |
| Service Bus / ACR | Standard (minimal); Premium 1 MU / Premium + PE in enterprise and above | `premium_capacity` |
| Telemetry transport | Event Hubs Standard, 2 partitions, 1-day retention; OP Worker min 2 replicas, APM gateway 1, OTel gateway 1-3 | `*_max_replicas` <= 5; tail sampling needs a single gateway replica |
| Traffic generator | ACA scheduled job, `rps` 0.2, 300 s | `TRAFFIC_DURATION_SECONDS` <= 600 |
| Expensive optional services | Service Fabric, SQL MI, Cassandra MI, ARO, CVM/GPU/dedicated host, AML, Synapse, ADX, Search, Hyperscale, elastic pool, App Gateway, Front Door, APIM, Firewall | `enabled = false` by default; ARO and HorizonDB blocked |

### Schedules and auto-stop

| Mechanism | Where | Notes |
|---|---|---|
| VM auto-shutdown 19:00 UTC | `platform-vm`, `platform-specialized-compute`, `platform-db-sqlvm` | no auto-start (start SQL VM before deploys); disks keep billing |
| SQL MI weekday stop/start 07:00-19:00 UTC | `platform-db-sqlmi` `stop_schedule_enabled` | compute ~35 % of hours; storage billed |
| Azure SQL serverless auto-pause 60 min | `platform-db-sql` | `fulfillment` is excluded from DBM so DBM does not keep it awake |
| ADX auto-stop | `platform-data-analytics` | ADX disabled by default |
| Scale to zero | ACA apps and jobs, Flex Consumption, Batch pool, deploy-agent VMSS | - |
| AKS / VMSS | manual `az aks stop` / `az vmss deallocate` or `min_instances = 0` | not automated |

### Retention and sampling

| Data | Retention / sampling | Owner |
|---|---|---|
| Log Analytics (platform features only) | 30 days, 1 GB/day cap | `platform-shared` |
| Application logs | not stored in Azure (Event Hubs buffer for PaaS logs only); Datadog index retention | ADR sections 10 and 13 |
| Event Hubs buffer | 1 day (`message_retention_days`, max 7) | `obs-telemetry-transport` |
| Traces | Datadog tracers: Agent-side (adaptive / remote) unless `apm.sample_rate`; OpenTelemetry workloads: `trace_sample_ratio` (1.0) + gateway `sampling_percentage` (100) | fleet policy / deploy roots / transport |
| RUM | `session_sample_rate` 100, replay 0 | `obs-prereqs` |
| Durable history | purged after `DURABLE_HISTORY_RETENTION_DAYS` (7) | hello-durable |
| SQL PITR / PostgreSQL / Cosmos Cassandra backups | 7 days | platform-db roots |
| ACR untagged manifests | 7 days (Premium only) | `platform-shared` |
| State storage | versioning + 30-day soft delete + 90-day change feed | `bootstrap` |

Profile features `trace_sample_rate` (OpenTelemetry workloads only), `rum_session_sample_rate` and `session_replay`
set these per profile (`minimal` 1.0 / 100; `enterprise`, `full`, `specialized` 0.5 / 50); environment
`components.<id>` settings still win. Teardown order and what each destroy deletes: [teardown runbook](../runbooks/teardown.md).
