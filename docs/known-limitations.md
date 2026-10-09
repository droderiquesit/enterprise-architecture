# Known limitations

Collected from every layer README, `catalog/services/*.yaml`, `catalog/provider-gaps.yaml` and a review of the code
on 2026-10-09. Each item names its source so it can be re-checked. Status words per
[ADR-0001 section 11](architecture/ADR-0001-design-contract.md#11-testing-levels-and-evidence-vocabulary).

## Nothing is deployed or verified

* No Azure or Datadog credentials existed while the repository was built. **No component is `deployed` or `verified`**;
  `live_validation` is `not-run` for all 100 service-catalog entries; there is no evidence file
  ([evidence/README.md](evidence/README.md)).
* Static validation (Terraform `fmt`/`validate`/`terraform test` with **mock providers**, unit tests, checkov) cannot
  detect Azure-side errors: quota, region/SKU availability, preview gating, API behaviour, RBAC propagation timing,
  private DNS resolution, Datadog API acceptance (platform/data README).
* The universal pipeline has not run in an Azure DevOps organisation (pipelines/README.md); its conditions are tested
  with a simulator (`tests/pipeline`).
## Blocked and disabled services

| Item | Status | Exact prerequisite / reason | Source |
|---|---|---|---|
| ARO (`platform-aro`) | blocked by default | 44 vCPU quota (Standard DSv5), providers registered (`Microsoft.RedHatOpenShift`, ...), empty `aro-master`/`aro-worker` subnets, ARO RP service principal object id, `version` from `az aro get-versions`, Red Hat pull secret in Key Vault, extra network resource ids for operator roles | platform/compute/aro/README.md |
| HorizonDB (`platform-db-horizondb`) | blocked (preview) | preview access + `Microsoft.HorizonDb` registered, preview region, `entra_admin`, `preview_access_confirmed = true`, private-link group id read after creation; azapi schema validation off | platform/data/horizondb/README.md |
| Azure VMware Solution | blocked (cataloged) | host quota via support request, >= 3 hosts (~USD 25k/month), ExpressRoute/Global Reach, /22 block | platform/compute/specialized/README.md, catalog |
| Oracle Database@Azure | blocked (cataloged) | Marketplace offer purchase, linked OCI tenancy, My Oracle Support registration, policy exemption for the auto-created OracleSubscription | catalog/services/partner-and-fabric.yaml |
| SQL Managed Instance | disabled | cost (~700-800/month), first instance in a subnet takes ~4-6 h | platform/data/sqlmi/README.md |
| Managed Instance for Apache Cassandra | disabled | cost (~1,500+/month); Cosmos DB first-party SP needs Network Contributor on the subnet; keyspace created over CQL from a private agent | platform/data/cassandra-mi/README.md |
| Service Fabric managed cluster | disabled | cost; requires client certificate thumbprint or Entra apps | platform/compute/servicefabric/README.md |
| Confidential VM, dedicated host, GPU VM, Automation, Azure ML | disabled | quota (DCasv5, NCASv3_T4 often 0), cost | platform/compute/specialized/README.md |
| App Service Windows container plan, Logic Apps WS1, Functions EP1 / Y1, Durable Task Scheduler | disabled | cost / optional | platform/compute/appservice, functions READMEs |
| SQL elastic pool, Hyperscale, PostgreSQL elastic cluster, Synapse SQL/Spark, ADX, AI Search | disabled | cost | platform/data READMEs, catalog |
| Edge: App Gateway, Front Door, APIM, Firewall, Bastion | disabled | cost; enable per scenario | foundation/edge/README.md |
| 31 catalog entries | cataloged only | retired/retiring (MariaDB, single servers, SQL Edge, Synapse Data Explorer, Neon, Spring Apps, Cloud Services ES, Azure Cache for Redis, Linux Consumption), not recommended (Cosmos DB for PostgreSQL), Fabric items (no ARM API), partner services needing other providers (MongoDB Atlas, Elastic, Confluent), not implemented (Databricks, HDInsight, Stream Analytics, Event Grid, App Configuration, Functions container on Premium, confidential containers, CycleCloud, Arc servers, Managed DevOps Pools entry, Synapse serverless) | [coverage matrix](coverage/coverage-matrix.md) |

## Provider gaps (AzAPI)

Listed in `catalog/provider-gaps.yaml` (resolution `azapi`): Durable Task Scheduler (`Microsoft.DurableTask/schedulers`,
`/taskHubs` @2026-02-01), HorizonDB (`Microsoft.HorizonDb/clusters`, `/administrators` @2026-05-01-preview, schema
validation off), Functions on Container Apps (`Microsoft.App/containerApps` @2026-01-01, `kind = functionapp`; 2026-07-01
exists in ARM but is not embedded in azapi 2.13), Cosmos Table data-plane RBAC
(`Microsoft.DocumentDB/databaseAccounts/tableRoleAssignments` @2026-03-15), SQL MI free offer
(`Microsoft.Sql/managedInstances` @2025-01-01, `pricingModel`), Logic Apps managed-identity API connection
(`Microsoft.Web/connections` @2016-06-01, schema validation off). Catalog-only gaps: Cloud Services ES, MongoDB Atlas,
Confluent (other providers), Fabric items and retired services (not IaC-deployable).

**Not listed but used** (ADR-0001 section 2 says azapi only for listed gaps): `observability/modules/telemetry-transport`
uses `Microsoft.App/containerApps@2025-07-01` (no `additionalPortMappings` / secret-volume item paths in azurerm), and
`observability/modules/azure-integration` uses `Microsoft.Datadog/monitors/monitoredSubscriptions@2025-06-11`.

Other provider limitations: DocumentDB Entra user can only get role `root` (least-privilege gap); Managed Redis custom
access policies not modelled (key-prefix boundaries by convention only); Service Fabric managed-cluster NSG rules not
exposed (restrict with `az sf managed-cluster network-security-rule`); no Service Fabric application resources (sfctl
script); no ARM keyspace for Cassandra MI; Confidential Ledger collections not ARM-managed; APIM v2 VNet integration
via `virtual_network_type = "External"` not covered by provider docs; Datadog provider has no DORA/change-event resource
(script `send_deployment_event.py`).

## Secrets in Terraform state

State lives in the private, Entra-only, versioned state account, but these values are in state:

| Value | Root | Why |
|---|---|---|
| admin passwords (`random_password`) of SQL Server VM, DocumentDB, Cassandra MI | platform/data | azurerm arguments have no write-only variant (copied write-only to Key Vault) |
| VM / VMSS / Service Fabric / specialized VM break-glass passwords | platform/compute | used when no SSH key is set |
| Event Hubs authorization rule keys | observability `telemetry-transport` | the rule resource holds its keys; the connection string is written to Key Vault write-only. SAS stays enabled because Fluent Bit's Kafka input cannot get Entra tokens on Container Apps |
| Logic Apps Standard storage access key | `deploy-logicapps` (fallback when `storage_connection_secret_id` is unset) | Azure Files content share has no identity-based access |
| `fault-token`, `datadog-api-key` | `deploy-partner-sim` (read at plan time) | ACI has no Key Vault references (`resolve_secrets = false` disables it) |
| Red Hat pull secret | `platform-aro` (when enabled) | read by reference |
| Datadog Azure integration client secret | `obs-azure-integration` with `app_auth = secret` | read by a data source; use `secretless` to avoid it |
| Datadog API key as VM extension protected setting | `obs-hosts` when `agent_protected_settings_secret_url` is not set | read by a data source and passed as protected setting (encrypted in state) |

The Event Hubs listen secret is written with `value_wo_version = 1` hard-coded in the module, so rotating it needs a
module change (see [secret-rotation.md](runbooks/secret-rotation.md)).

## Public-endpoint and authentication exceptions

| Resource | Exception | Source |
|---|---|---|
| Azure Confidential Ledger | no Private Link support -> public endpoint, Entra/cert auth | foundation/network, platform/data/ledger |
| Service Bus Standard (minimal profile) | private endpoints are Premium-only -> public endpoint, Entra-only (local auth off), optional IP rules | platform/messaging |
| ACR Standard (minimal default) | no private endpoint below Premium -> public endpoint, Entra-only, admin/anonymous off | platform/shared |
| Static Web Apps Free | public static content; private endpoint needs Standard + a platform-owned PE (not created) | deploy-frontend |
| Container Apps `ingress_mode = external` (minimal) | environment has a public IP; only `hello-bff` (and the nginx frontend variant) are external | platform/compute/containerapps |
| Functions Windows Consumption (off) | no VNet integration -> storage public (Entra-only), app with deny-by-default IP restrictions | platform/compute/functions, deploy-durable |
| Event Hubs namespace (telemetry transport) | `public_network_access_enabled = true` with default action Deny + trusted services (diagnostic settings) and a private endpoint for collectors; SAS enabled (above) | observability/modules/telemetry-transport |
| Service Fabric managed cluster | public IP for 19000/19080 (certificate/Entra protected) | platform/compute/servicefabric |
| HorizonDB | public access with IP firewall (no rules) + PE once group id known; no VNet injection | platform/data/horizondb |
| Durable Task Scheduler | `ipAllowlist` defaults to lab egress IPs; empty list falls back to `0.0.0.0/0` (Entra still required) | platform/compute/functions |
| Cosmos DB for MongoDB RU / Cassandra / Gremlin | key authentication kept (no usable Entra data plane for the drivers); keys stored out-of-band | platform/data/cosmos-* |
| MySQL Flexible / SQL Server on VM DBM | SQL auth passwords (no managed-identity auth in the DBM check for these) | foundation/identity |
| Logic Apps Standard storage | shared keys enabled on that one account | platform/compute/appservice |
| AI Search Free tier | no private endpoint -> rejected while PEs are on | platform/data/analytics |
| Synapse private endpoint | created without a DNS zone group (no `synapse_sql` zone key in foundation-network v1) | platform/data/analytics |
| APIM v2 (off) | gateway stays public with outbound VNet integration | foundation/edge |
| `hello-orders-api` `PATCH /orders/{id}/status` | protected by network placement only (internal ingress), no app-level token | applications/services/orders-api |
| hello-durable HTTP functions | `AuthorizationLevel.Anonymous`; app reachable only privately (PE, or deny-by-default restrictions when no foundation-network contract) | applications/services/durable, deploy-durable |
| partner-sim | plain HTTP inside the spoke (no TLS) | deploy-partner-sim |
| AKS internal LB exposure | HTTP only without the app routing add-on (not enabled by platform-aks) | deploy-core-aks |

## Preview and lifecycle items

* HorizonDB (public preview, PostgreSQL 17 only, 7-day backups); Hyperscale serverless auto-pause (preview, default off).
* Functions Windows Consumption is legacy-but-supported; Linux Consumption retires 2028-09-30 (not offered).
* Azure Cache for Redis retiring (not used; Azure Managed Redis instead). Bsv1 VM sizes retire 2028-11-15 (Bsv2 used).
* Kubernetes 1.36 default (EOL Jun 2027); ARO version has no static default.
* Lifecycle watch list: [coverage matrix](coverage/coverage-matrix.md#lifecycle-watch-list-non-ga).

## Region availability not verified

`dev` targets `swedencentral`. Catalog `availability.regions_checked` marks these as `unknown` or `false`:

* `unknown` in swedencentral: Azure Managed Redis, Confidential Ledger (also eastus2/westeurope), Durable Task
  Scheduler (all three), confidential VM (DCasv5), GPU VM, Azure VMware Solution, confidential containers.
* `false`: Static Web Apps in swedencentral (deployed to `swa_location`, default westeurope); HorizonDB in eastus2 and
  westeurope; retired services everywhere.
* Root READMEs add: Managed DevOps Pools image name and `Standard_D2ads_v5`, Batch node agent SKU for Ubuntu 24.04
  (`az batch pool supported-images list`), Cassandra MI `Standard_D8s_v4`, MDP internal range `172.17.0.0/16` must not be
  used by VNets.

## Deployment and networking

* Microsoft-hosted agents cannot reach private endpoints; first foundation runs need a temporary IP allowlist on the state
  account ([bootstrap guide](guides/prerequisites-and-bootstrap.md#5-before-private-agents-exist)).
* Roots needing data-plane access to private resources require VNet-connected agents: Flex deployment container
  uploads, SQL/PostgreSQL/MySQL grant scripts, Cassandra keyspace script, `kubernetes_manifest` (SecretProviderClass) on
  the private AKS API at plan time, Key Vault secret values, smoke tests of internal apps.
* `userAssignedNATGateway` for AKS requires the NAT gateway association on `aks-nodes` before cluster creation.
* Subnets with service association links (ACA, SQL MI, MDP, Flexible Servers) cannot be deleted while the service
  exists; SQL MI subnets release slowly. SQL MI with firewall egress keeps its service-managed route table.
* `track_activity_query_size` (PostgreSQL) and `performance_schema` (MySQL) are static parameters - a server restart is
  needed and not automated; Datadog Query Activity / Wait Events are not supported on MySQL Flexible.
* Key Vault purge protection blocks re-creating the same environment for 7 days after destroy.
* `obs-dbm` with ACI hosting needs the `observability` subnet delegated to `Microsoft.ContainerInstance/containerGroups`;
  foundation-network does not delegate it (ADR section 8 lists no delegation) - set `subnet_key = "aci"` or request the
  delegation (observability/lab/dbm/README.md).
* `obs-hosts`: the VM / VMSS identities need Key Vault Secrets User on `datadog-api-key` for Fluent Bit (foundation
  request); destroy removes extensions but does not uninstall packages from hosts.
* `obs-diagnostics`: resource types missing from the allow-lists are skipped; Managed Redis and DocumentDB categories are
  not allow-listed yet.

## Configuration

* Profile `features` (`bastion`, `app_gateway`, `firewall`, `front_door`, `apim`, `service_bus_sku`, `private_endpoints`,
  `session_replay`, `rum_session_sample_rate`, `trace_sample_rate`, `deploy_lab_infrastructure`) are **not read by any lab
  root**; only `components` and `component_settings` take effect. E.g. `enterprise` declares `bastion: true` and
  `trace_sample_rate: 0.5`, but Bastion stays off and every deployment root samples at `trace_sample_ratio = 1`.
* `deploy-durable` takes `ORDERS_API_URL` / `INVENTORY_API_URL` only from settings (not from `deploy-core-*` contracts);
  without `orders_api_url` orders never leave `Pending` in the UI. `deploy-jobs` `durable_api_url` is likewise a setting.
* Two-pass settings: BFF `cors_allowed_origins` needs the SWA hostname (known after `deploy-frontend`); BFF
  `adapters` must be copied from `deploy-dbadapters` `adapters_json`; firewall egress switch is three applies.
* In `minimal`, Service Bus subscriptions `notifications`, `audit`, `archive` exist without consumers; messages accumulate
  until the 14-day TTL.
* Budgets alert only; they never cap spend.

## Application and telemetry limitations

* Orders: no transactional outbox (`PublishFailed` + `/republish`). Durable: a late successful charge after a timeout is
  not refunded; reconciliation reads at most 100 orders per run; Service Bus trigger path not exercised locally (same code
  path via `POST /api/workflows/order`).
* Durable telemetry trade-off: full Durable V2 spans need `OTEL_EXPORTER_OTLP_ENDPOINT`, which also makes the host export
  OTLP logs - the OTel gateway drops OTLP logs; worker log lines in FunctionAppLogs are host-formatted, not the ADR JSON
  shape. The platform `durable_storage` account is unused until `host.json` points at another connection.
* ACA jobs run without a Fluent Bit sidecar (stdout -> ContainerAppConsoleLogs diagnostic setting); Batch task logs are
  not collected (the platform-batch start task installs only Python 3.13).
* Python Entra paths (PostgreSQL token auth, Managed Redis credential provider, Service Bus with managed identity) are
  implemented but not exercised (no Azure); systemd units, PowerShell installers, SF/ARO deploy scripts and the Batch
  submission script are syntax-checked only.
* Observability assumptions to confirm (observability/README.md section 9): Service Bus entity tag `entityname`; Azure
  `name` tag of SQL databases = database name; Fluent Bit / OTel collector metric naming; worker operation name
  `servicebus.process`; RUM monitor syntax not validated by the Datadog API; DBM per-node behaviour on PostgreSQL elastic
  clusters unverified; synthetic browser steps limited to simple assertions.
* `telemetry_verify.py` is tested only against recorded API responses.

## Documentation and links

* Monitor messages link to `metadata.runbook_url` of each manifest, which is the placeholder
  `https://runbooks.example.com/enterprise-hello/<service>`. The anchors exist in
  [runbooks/alerts/](runbooks/alerts/README.md); point `runbook_url` at the published location of that directory to make
  the links resolve.
* ADR-0001 section 11 places evidence files under `docs/evidence/`; the pipeline writes them to the `evidence` blob
  container - copying them into the repository is a manual step ([evidence/README.md](evidence/README.md)).
* Some layer READMEs lag behind the code (listed in the implementation report): e.g. bootstrap README (no `build`
  identity / `packages` container), platform/messaging README (no `archive` subscription), deployment READMEs that still
  say optional contracts are "not in components.yaml".
