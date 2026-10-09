# Cost controls and lifecycle

Only controls that exist in code are listed; each names the setting and the root that owns it. Prices are the
approximate list prices quoted in the root READMEs (USD/month, Oct 2026, not verified against the pricing API).
Per-profile estimates: [deployment-profiles.md](deployment-profiles.md). Nothing has been billed yet - no environment
has been deployed.

## 1. Guard rails

| Control | Where | Behaviour |
|---|---|---|
| Monthly budget | `foundation-governance` `budget.*` (environment `budget.monthly_amount` — dev 500 —, root fallback 300, monthly) | actual 50/80/100 %, forecast 80/100 % e-mail + action group; filter `application=enterprise-hello` and `env=<env>`. **Alerts only - Azure budgets never stop or cap spend**; cost data lags up to ~24 h |
| `expires_on` tag | `environment.expires_on` -> `foundation/modules/tags` on every taggable resource (also `env, application, owner, component, layer, cost_center, data_classification=synthetic, repository, ...`) | informational; nothing deletes on expiry automatically |
| Expired-resource finder | [`foundation/governance/scripts/find-expired.sh`](../../foundation/governance/scripts/find-expired.sh) | Resource Graph query scoped to `application == enterprise-hello` **and** `repository == azure-enterprise-observability-lab` and `expires_on < now`; `--print-delete-commands` prints (never runs) `az group delete` commands |
| Required RG tags policy | `foundation-governance` `policy.required_rg_tags` (`env, owner, expires_on`) | **audit** by default (platform-managed RGs would be denied) |
| Allowed locations | `foundation-governance` `policy.allowed_locations` | **enforced** at subscription scope (`[environment.location]`) |
| Profile confirmation | `expensive: true` / `requires_confirmation: true` in `full` and `specialized` | descriptive flags in the profile files |
| Cost warnings in plans | `tools/validate/plan_policy.py` | creation of expensive types and SKU/size/capacity changes flagged as warnings in the plan summary |

## 2. Small default SKUs and scaling ceilings

| Resource | Default | Ceiling (validated in `variables.tf`) |
|---|---|---|
| AKS | Free tier, system pool 1-2 x D2s_v5 | `system_pool`/`user_pool` max <= 10 / 20 |
| Container Apps | Consumption, min replicas 0 (`deploy-core-aca`); `dedicated-d4` min 0 max 1 | `replica_ceiling` 5 (ACA) / 6 (AKS deployments); dedicated profile 0 <= min <= max <= 10 |
| App Service | P0v3 Linux + Windows; Windows container P1v3 and WS1 off | WS1 elastic <= 3 |
| Functions | Flex FC1 on demand (no always-ready); EP1, Y1, Durable Task Scheduler off | EP1 elastic <= 3 |
| VM | B2s_v2 Linux + Windows | - |
| VMSS | Flexible 1/1/3, Uniform 1/1/2; CPU autoscale | `max_instances` <= 10 |
| Batch | pool autoscale 0 -> 2 nodes on pending tasks | `max_dedicated_nodes` |
| Deploy agents | VMSS at 0 instances (Azure DevOps scales); MDP `max_concurrency` 2 | - |
| SQL | S0 (`orders`), serverless GP_S_Gen5_1 min 0.5 vCore auto-pause 60 min (`fulfillment`), Basic (`adapter`) | elastic pool / Hyperscale disabled |
| PostgreSQL / MySQL | B1ms burstable, no HA, no geo backup | elastic cluster disabled |
| Cosmos DB | serverless accounts | - |
| Managed Redis | Balanced_B0, HA off, no persistence | - |
| Service Bus | Standard (minimal); Premium 1 MU in enterprise/full/specialized (~680) | `premium_capacity` |
| ACR | Standard; Premium only with private endpoint | - |
| Telemetry transport | Event Hubs Standard, 2 partitions, 1-day retention; aggregator 1-2 replicas, gateway 1-3 replicas on Consumption | aggregator max <= 10; tail sampling requires a single gateway replica |
| Traffic generator | ACA scheduled job, `rps` 0.2, `duration_seconds` 300 | `TRAFFIC_DURATION_SECONDS` <= 600; replica timeout = duration + 120 s |
| Partner simulator | ACI 0.75 vCPU / 1.5 GB always on (~35) | - |
| Expensive optional services | Service Fabric, SQL MI, Cassandra MI, ARO, CVM/GPU/dedicated host, AML, Synapse, ADX, Search, Hyperscale, elastic pool, App Gateway, Front Door, APIM, Firewall | all `enabled = false` by default; ARO and HorizonDB blocked |

## 3. Schedules and auto-stop

| Mechanism | Where | Notes |
|---|---|---|
| VM auto-shutdown 19:00 UTC daily | `platform-vm` `auto_shutdown`, `platform-specialized-compute` (`auto_shutdown_time` "1900") | no auto-start; disks keep billing |
| SQL Server on VM auto-shutdown | `platform-db-sqlvm` | the pipeline or an operator must start the VM before deploys |
| SQL MI weekday stop/start 07:00-19:00 UTC | `platform-db-sqlmi` `stop_schedule_enabled` (true) | cuts compute to ~35 % of hours; storage still billed |
| Azure SQL serverless auto-pause | `platform-db-sql` `auto_pause_delay_in_minutes` 60 | the `fulfillment` database is excluded from DBM because DBM connections would keep it awake |
| ADX auto-stop | `platform-data-analytics` `auto_stop_enabled` (true) | ADX disabled by default |
| Scale to zero | ACA apps and jobs, Flex Consumption, Batch pool, deploy-agent VMSS | `apm.no_traffic` monitors are not created for scale-to-zero services |
| AKS stop/start | manual `az aks stop` / `az aks start` (README) | not automated |
| VMSS | manual `az vmss deallocate` or `min_instances = 0` | no schedule |

## 4. Retention and sampling

| Data | Retention / sampling | Owner |
|---|---|---|
| Log Analytics (platform features only) | 30 days, 1 GB/day cap, shared-key auth off | `platform-shared` |
| Application logs | not stored in Azure; Fluent Bit -> Datadog (Datadog index retention applies) | ADR section 10 |
| Event Hubs buffer | 1 day (`message_retention_days`, max 7) | `obs-telemetry-transport` |
| Traces | SDK `parentbased_traceidratio`, `trace_sample_ratio` 1.0 in every deployment root; gateway probabilistic sampling 100 % by default (`gateway.sampling_percentage`) | deploy roots / transport |
| RUM | `session_sample_rate` 100, session replay 0 (`obs-prereqs`; the frontend forces replay to 0) | `obs-prereqs` |
| Synthetics | created **paused** (`synthetics_paused = true`) | `obs-monitoring` |
| Durable history | `PurgeHistory` timer purges completed instances older than `DURABLE_HISTORY_RETENTION_DAYS` (7) | hello-durable |
| SQL PITR | 7 days (1-35) | `platform-db-sql` |
| PostgreSQL backups | 7 days | `platform-db-postgresql` |
| Cosmos Cassandra API | periodic backup 24 h interval, 7 days | `platform-db-cosmos-cassandra` |
| ACR untagged manifests | 7 days (Premium only) | `platform-shared` |
| State storage | versioning + 30-day blob/container soft delete + 90-day change feed | `bootstrap` |
| Key Vault | 7-day soft delete, purge protection on | `foundation-identity` |

The profile `features.trace_sample_rate` (-> `trace_sample_ratio` of every deploy root), `rum_session_sample_rate` and
`session_replay` (-> `obs-prereqs` RUM sample rates) set these defaults per profile (`minimal` 1.0 / 100, `enterprise`,
`full`, `specialized` 0.5 / 50); environment `components.<id>` settings still win
([profiles README](../../environments/profiles/README.md#feature-mapping)).

## 5. Teardown order and data deletion

Teardown is the reverse of the dependency order (`python3 -m tools.changeset graph` prints the layers). Procedure with
the pipeline retire mode or per-root `terraform destroy`: [runbooks/teardown.md](../runbooks/teardown.md).

| Order | Components | Data behaviour on destroy |
|---|---|---|
| 1 | `obs-monitoring`, `obs-diagnostics` | Datadog objects / diagnostic settings only; ingested telemetry stays in Datadog |
| 2 | `deploy-jobs`, `deploy-frontend`, `deploy-core-aks`, `deploy-durable`, other `deploy-*`, `obs-hosts`, `obs-kubernetes`, `obs-dbm` | app resources only; no data (data lives in platform databases) |
| 3 | `obs-telemetry-transport` | Event Hubs buffer (<= 1 day) lost |
| 4 | `platform-aks`, `platform-containerapps`, `platform-batch` | no persistent data in clusters/environments |
| 5 | `platform-db-*`, `platform-data-analytics`, `platform-messaging`, `platform-functions`, `platform-shared`, other platform roots | **databases deleted** (synthetic data; SQL deleted databases restorable from backup until server deletion); Service Bus in-flight/dead-lettered messages lost; ACR images deleted (rebuildable); Log Analytics workspace soft-deleted 14 days; Functions packages and Durable task hub deleted; Key Vault secrets created by data roots deleted (vault soft delete applies) |
| 6 | `foundation-edge`, `foundation-deploy-agents` | switch network egress back to NAT **before** destroying the firewall; remove the Azure DevOps agent pool first; APIM v2 soft-deleted 48 h |
| 7 | `foundation-identity` | Key Vault soft-deleted 7 days and **not purgeable** (purge protection) - its deterministic name blocks re-creation of the same environment for 7 days |
| 8 | `foundation-network` | no data; subnets with service association links (ACA, SQL MI, MDP, Flexible Servers) release slowly |
| 9 | `foundation-governance` | last, so budget alerts cover the teardown |
| 10 | `bootstrap` | **retained by design**: `prevent_destroy` + CanNotDelete lock; removal is a manual, local procedure (bootstrap README) |

## 6. Cleanup scoped by tags

Never clean up by name pattern alone. The tag pair `application = enterprise-hello` + `repository =
azure-enterprise-observability-lab` (+ `env`) identifies lab resources; `find-expired.sh` uses exactly that scope and
only prints delete commands. Resource-provider-managed groups (`MC_*`, ACA/Functions infrastructure RGs, ARO cluster RG)
do not carry the lab tags; they disappear with their parent resource.
