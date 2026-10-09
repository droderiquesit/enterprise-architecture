# Known limitations

Collected from every layer README, `catalog/services/*.yaml`, `catalog/provider-gaps.yaml` and a review of the code
on 2026-10-09. Each item names its source so it can be re-checked. Status words per
[ADR-0001 section 11](architecture/ADR-0001-design-contract.md#11-testing-levels-and-evidence-vocabulary).

## Nothing is deployed or verified

* No Azure or Datadog credentials existed while the repository was built. **No component is `deployed` or `verified`**;
  `live_validation` is `not-run` for all 101 service-catalog entries; there is no evidence file
  ([evidence/README.md](evidence/README.md)).
* Static validation (Terraform `fmt`/`validate`/`terraform test` with **mock providers**, unit tests, checkov) cannot
  detect Azure-side errors: quota, region/SKU availability, preview gating, API behaviour, RBAC propagation timing,
  private DNS resolution, Datadog API acceptance (platform/data README).
* The universal pipeline has not run in an Azure DevOps organisation (pipelines/README.md); its conditions are tested
  with a simulator (`tests/pipeline`).
## Blocked and disabled services

| Item | Status | Exact prerequisite / reason | Source |
|---|---|---|---|
| ARO (`platform-aro`) | disabled (implemented; prerequisites block enabling) | 44 vCPU quota (Standard DSv5), providers registered (`Microsoft.RedHatOpenShift`, ...), empty `aro-master`/`aro-worker` subnets, ARO RP service principal object id, `version` from `az aro get-versions`, Red Hat pull secret in Key Vault, extra network resource ids for operator roles | platform/compute/aro/README.md |
| HorizonDB (`platform-db-horizondb`) | disabled (implemented; preview access required) | preview access + `Microsoft.HorizonDb` registered, preview region, `entra_admin`, `preview_access_confirmed = true`, private-link group id read after creation; azapi schema validation off | platform/data/horizondb/README.md |
| Azure VMware Solution | blocked (cataloged) | host quota via support request, >= 3 hosts (~USD 25k/month), ExpressRoute/Global Reach, /22 block | platform/compute/specialized/README.md, catalog |
| Oracle Database@Azure | blocked (cataloged) | Marketplace offer purchase, linked OCI tenancy, My Oracle Support registration, policy exemption for the auto-created OracleSubscription | catalog/services/partner-and-fabric.yaml |
| SQL Managed Instance | disabled | cost (~700-800/month), first instance in a subnet takes ~4-6 h | platform/data/sqlmi/README.md |
| Managed Instance for Apache Cassandra | disabled | cost (~1,500+/month); Cosmos DB first-party SP needs Network Contributor on the subnet; keyspace created over CQL from a private agent | platform/data/cassandra-mi/README.md |
| Service Fabric managed cluster | disabled | cost; requires client certificate thumbprint or Entra apps | platform/compute/servicefabric/README.md |
| Confidential VM, dedicated host, GPU VM, Automation, Azure ML | disabled | quota (DCasv5, NCASv3_T4 often 0), cost | platform/compute/specialized/README.md |
| App Service Windows container plan, Logic Apps WS1, Functions EP1 / Y1, Durable Task Scheduler | disabled | cost / optional | platform/compute/appservice, functions READMEs |
| SQL elastic pool, Hyperscale, PostgreSQL elastic cluster, Synapse SQL/Spark, ADX, AI Search | disabled | cost | platform/data READMEs, catalog |
| Managed DevOps Pools (`foundation-deploy-agents` `mode = managed-devops-pool`) | disabled (VMSS agents by default) | organization URL, DevOpsInfrastructure principal, subnet delegation | foundation/deploy-agents/README.md |
| Edge: App Gateway, Front Door, APIM, Firewall, Bastion | disabled | cost; enable per scenario | foundation/edge/README.md |
| 30 catalog entries | cataloged only | retired/retiring (MariaDB, single servers, SQL Edge, Synapse Data Explorer, Neon, Spring Apps, Cloud Services ES, Azure Cache for Redis, Linux Consumption), not recommended (Cosmos DB for PostgreSQL), Fabric items (no ARM API), partner services needing other providers (MongoDB Atlas, Elastic, Confluent), not implemented (Databricks, HDInsight, Stream Analytics, Event Grid, App Configuration, Functions container on Premium, confidential containers, CycleCloud, Arc servers, Synapse serverless) | [coverage matrix](coverage/coverage-matrix.md) |

## Provider gaps (AzAPI)

Listed in `catalog/provider-gaps.yaml` (resolution `azapi`): Durable Task Scheduler (`Microsoft.DurableTask/schedulers`,
`/taskHubs` @2026-02-01), HorizonDB (`Microsoft.HorizonDb/clusters`, `/administrators` @2026-05-01-preview, schema
validation off), Functions on Container Apps (`Microsoft.App/containerApps` @2026-01-01, `kind = functionapp`; 2026-07-01
exists in ARM but is not embedded in azapi 2.13), Cosmos Table data-plane RBAC
(`Microsoft.DocumentDB/databaseAccounts/tableRoleAssignments` @2026-03-15), SQL MI free offer
(`Microsoft.Sql/managedInstances` @2025-01-01, `pricingModel`), Logic Apps managed-identity API connection
(`Microsoft.Web/connections` @2016-06-01, schema validation off), observability telemetry transport
(`Microsoft.App/containerApps` @2025-07-01: `additionalPortMappings` and secret-volume item paths, owner
obs-telemetry-transport) and the Datadog native integration (`Microsoft.Datadog/monitors/monitoredSubscriptions`
@2025-06-11, owner obs-azure-integration, catalog entry `datadog-azure-native-integration`). Catalog-only gaps: Cloud
Services ES, MongoDB Atlas, Confluent (other providers), Fabric items and retired services (not IaC-deployable).

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

The Event Hubs listen secret is written write-only; its `value_wo_version` is the setting
`components.obs-telemetry-transport.eventhub_secret_version` (default 1) - increment it after renewing the rule keys
([secret-rotation.md](runbooks/secret-rotation.md)).

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
* `obs-dbm` ACI hosting runs in foundation-network's delegated `aci` subnet (default `subnet_key = "aci"`, shared with
  partner-sim); database firewalls / NSGs must admit that range.
* `obs-hosts`: destroy removes extensions but does not uninstall packages from hosts. The VM / VMSS identities
  (`hello-worker`, `hello-inventory-api`, `hello-dbadapter`) and the Batch pool identity (`hello-jobs`) read
  `datadog-api-key`; with `secret_scoped_assignments = true` those grants are per secret.
* Batch log collection is set up per **job** (job preparation task): a job created before a change of the
  observability setup keeps the old preparation task until it is deleted and re-created (`submit-batch-job.sh` warns).
  The script travels in a job-preparation environment setting (size limits not verified on Azure).
* `obs-diagnostics`: resource types missing from the allow-lists are skipped; Managed Redis and DocumentDB categories are
  not allow-listed yet.

## Configuration

* Profile `features` are mapped to component settings by `tools/config/render.py` (table in
  [environments/profiles/README.md](../environments/profiles/README.md)); `private_endpoints` and
  `deploy_lab_infrastructure` are documented-only. `app_gateway: true` (profiles `full`, `specialized`) enables
  Application Gateway in foundation-edge, whose validation then requires a Key Vault certificate secret id and backend
  FQDNs in the environment file - plan fails until they are set.
* Upstream URLs are derived from optional contracts (`deploy-durable`: orders/inventory/partner; `deploy-jobs`:
  durable), but AKS-hosted APIs publish Kubernetes-internal URLs that Functions / Container Apps cannot resolve; with
  `deploy-core-aks` only, set `components.deploy-durable.orders_api_url` (e.g. an internal load balancer or App
  Routing host) explicitly.
* Two-pass settings: BFF `cors_allowed_origins` needs the SWA hostname (known after `deploy-frontend`); BFF
  `adapters` must be copied from `deploy-dbadapters` `adapters_json`; firewall egress switch is three applies.
* Budgets alert only; they never cap spend. The dev budget (500) is based on the minimal-profile estimate.

## Application and telemetry limitations

* Orders: no transactional outbox (`PublishFailed` + `/republish`). Durable: a late successful charge after a timeout is
  not refunded; reconciliation reads at most 100 orders per run; Service Bus trigger path not exercised locally (same code
  path via `POST /api/workflows/order`).
* Durable telemetry trade-off: full Durable V2 spans need `OTEL_EXPORTER_OTLP_ENDPOINT`, which also makes the host export
  OTLP logs - the OTel gateway drops OTLP logs; worker log lines in FunctionAppLogs are host-formatted, not the ADR JSON
  shape. The platform `durable_storage` account is unused until `host.json` points at another connection.
* ACA jobs run without a Fluent Bit sidecar (stdout -> ContainerAppConsoleLogs -> Event Hubs -> aggregator, allow-list
  `aca_console_allow`). Batch task stdout is shipped by a Fluent Bit service that the job preparation task installs
  (no Datadog Agent on Batch nodes, so Fluent Bit self-metrics have no local OTLP receiver).
* Python Entra paths (PostgreSQL token auth, Managed Redis credential provider, Service Bus with managed identity) are
  implemented but not exercised (no Azure); systemd units, PowerShell installers, SF/ARO deploy scripts and the Batch
  submission script are syntax-checked only.
* Observability assumptions to confirm (observability/README.md section 9): Service Bus entity tag `entityname`; Azure
  `name` tag of SQL databases = database name; Fluent Bit / OTel collector metric naming; worker operation name
  `servicebus.process`; RUM monitor syntax not validated by the Datadog API; DBM per-node behaviour on PostgreSQL elastic
  clusters unverified; synthetic browser steps limited to simple assertions.
* `telemetry_verify.py` is tested only against recorded API responses.

## Documentation and links

* Monitor runbook links default to `<metadata.repository>?path=/docs/runbooks/alerts/<service>.md#<section>`
  (archetype `runbook_base_url`). The lab manifests' `repository` uses the placeholder organisation `example-org`; set
  it to the real Azure Repos URL (or override `runbook_base_url`) for the links to resolve. Whether Azure Repos scrolls
  to `#<section>` in the file view is not verified; the page itself opens.
* Evidence: the pipeline writes to the `evidence` container; `tools/report/pull_evidence.py` copies a run into
  `docs/evidence/<env>/<run id>/` for a reviewed commit ([evidence/README.md](evidence/README.md)).
