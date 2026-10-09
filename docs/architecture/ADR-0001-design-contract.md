# ADR-0001 — Repository design contract

- Status: Accepted
- Date: 2026-10-09
- Scope: every directory in this repository

This ADR is the binding contract between layers. Every Terraform root, application,
pipeline template and tool in the repository follows it. When code and this document
disagree, the code is wrong unless this ADR is amended in the same change.

## 1. Repository identity

The repository is **azure-enterprise-observability-lab**. It is hosted in the Git
repository `enterprise-architecture`; all paths below are relative to the repository root.
The sample application is **Enterprise Hello** (`application = "enterprise-hello"`).

## 2. Pinned toolchain and runtimes (verified 2026-10-09)

| Tool / runtime | Version | Constraint used in code | Why |
|---|---|---|---|
| Terraform CLI | 1.16.5 | `required_version = ">= 1.14.0, < 2.0.0"` | latest stable; mock providers + `terraform test` |
| hashicorp/azurerm | 5.9.0 | `~> 5.9` | latest stable 5.x |
| Azure/azapi | 2.13.0 | `~> 2.13` | **only** for gaps listed in `catalog/provider-gaps.yaml` |
| DataDog/datadog | 4.25.0 | `~> 4.25` | latest stable |
| hashicorp/helm | 3.3.0 | `~> 3.3` | Kubernetes agent/Fluent Bit charts |
| hashicorp/kubernetes | 3.3.0 | `~> 3.3` | application manifests on AKS |
| hashicorp/random | 3.9.1 | `~> 3.9` | |
| hashicorp/time | 0.14.2 | `~> 0.14` | expirations |
| hashicorp/azuread | — | bootstrap only, optional | Entra app registration for the Datadog Azure integration (azurerm cannot manage Entra objects) |
| .NET | 10.0 (SDK 10.0.401, LTS, EOS 2028-11-14) | `net10.0` | Functions isolated worker supports .NET 10 on Flex Consumption |
| Python | 3.13 | `python_version = "3.13"` | GA on Functions until Oct 2029; not Linux Consumption (3.12 is last there) |
| Node.js (build only) | 24 LTS (22 accepted locally) | `"engines": {"node": ">=22"}` | browser bundle build |
| React / Vite / TypeScript | 19.x / 8.x / 5.x | lockfile | |
| @datadog/browser-rum | 7.x | lockfile | |
| Fluent Bit | 5.1.3 | image tag `fluent/fluent-bit:5.1.3` | |
| Datadog Agent | 7.84.2 | `gcr.io/datadoghq/agent:7.84.2` or `datadog/agent:7.84.2` | |
| DDOT Collector | 7.84.2 | `datadog/ddot-collector:7.84.2` | |
| OTel Collector Contrib | 0.162.0 | `otel/opentelemetry-collector-contrib:0.162.0` | upstream gateway option |

`versions.yaml` at the repository root is the machine-readable copy of this table and is
checked by `tools/validate/versions.py`.

## 3. Layers, components and canonical ownership

A **component** is the unit of change detection, state, planning and deployment. The
registry is `catalog/components.yaml` (schema `catalog/schemas/component.schema.json`).

| Layer | Directory | Owns | Never owns |
|---|---|---|---|
| bootstrap | `bootstrap/` | state storage, contract/plan/record containers, pipeline identities + federated credentials | anything a workload uses |
| foundation | `foundation/<component>/` | VNets, subnets, NSGs, route tables, NAT, private DNS zones, Key Vault, workload user-assigned identities, budgets, policy, deploy agents, optional edge | compute platforms, databases, app settings |
| platform | `platform/<component>/` | compute *platforms* (AKS cluster, ACA environment, App Service/Functions plans, VM/VMSS hosts, Batch account+pool, SF/ARO clusters), databases/servers/accounts, logical DBs, messaging, storage, private endpoints for those resources, RBAC data-plane grants for workload identities | application settings, container images, app-level resources |
| applications | `applications/services/<svc>/` (source) and `applications/deployments/<deployment>/` (Terraform root) | the *app resource* (container app, web/function app, k8s Deployment, container group, SWA content, VM run-command install, Batch job, Logic App workflow) **and all of its settings/env vars** | platform resources |
| observability | `observability/` (portable package) and `observability/lab/<component>/` (lab roots consuming the package) | Datadog org resources, Azure integration, diagnostic settings, telemetry transport (Fluent Bit aggregator, OTel gateway, Event Hub for log export), agents/extensions on hosts and clusters, DBM checks | application settings (it publishes *integration hooks* the app owner applies) |

Rules:

1. One Azure resource ⇒ exactly one Terraform root. Shared modules are code reuse, not ownership.
2. App settings are owned only by the application deployment root. Observability publishes an
   `instrumentation` contract (env vars, sidecar spec, secret *references*); app roots consume it.
3. VM extensions (Datadog Agent, Fluent Bit) are separate ARM resources owned by observability.
   Platform VM roots set `lifecycle { ignore_changes = [...] }` on nothing observability touches.
4. Diagnostic settings are owned by observability (`obs-diagnostics`) only.
   Platform roots must not create `azurerm_monitor_diagnostic_setting`.
5. Lab-shared Terraform modules live in `foundation/modules/` (naming, tags, private endpoint).
   The observability package **must not** reference anything outside `observability/`.

## 4. State

- Backend `azurerm` with Entra ID auth (`use_azuread_auth = true`, `use_oidc = true`) and
  blob-lease locking. Partial configuration: each root has `backend "azurerm" {}`; the pipeline
  passes `-backend-config` values. Key: `<environment>/<component-id>.tfstate`.
- Bootstrap starts with local state and migrates (`bootstrap/README.md`).
- Storage account: versioning, soft delete (containers + blobs), change feed, `shared_access_key_enabled = false`,
  public network access disabled after private agents exist, `prevent_destroy`, resource lock `CanNotDelete`.
- Containers: `tfstate`, `contracts`, `plans` (plan files; sensitive; RBAC restricted to the apply identity),
  `deployments` (component deployment records), `evidence`.

## 5. Output contracts

Each root that has consumers outputs `contract` (non-sensitive). The pipeline wraps it in an envelope and
uploads it to `contracts/<env>/<contract-name>/v<major>.json`:

```json
{
  "contract": "foundation-network",
  "version": "1.0.0",
  "environment": "dev",
  "produced_by": {"component": "foundation-network", "commit": "<sha>", "run_id": "<id>"},
  "data": { "...": "the root's contract output" }
}
```

- Schemas: `catalog/contracts/<contract-name>.v<major>.schema.json` (JSON Schema 2020-12). `tools/contracts/validate.py`
  validates outputs; `tools/contracts/materialize.py` downloads/assembles consumer inputs into
  `<root>/contracts.auto.tfvars.json` as one variable per upstream contract (variable name = contract name with `-`→`_`).
- Consumers declare `variable "<contract_name>"` with an explicit `object({...})` type listing only the fields they use.
- **No secrets in contracts.** Secrets travel as Key Vault secret *versionless IDs* (`*_secret_id`).
- Breaking change ⇒ new major version (`v2`) published alongside `v1` until consumers move.
- `terraform_remote_state` is forbidden.

## 6. Configuration

- `environments/<env>/environment.yaml` — globals (subscription, tenant, location, prefix, owners, budget,
  expiry, network ranges, profile) and `components.<id>` settings blocks.
- `environments/profiles/<profile>.yaml` — enabled components + feature flags. Profiles: `minimal`,
  `enterprise`, `full`, `specialized`, `observability-only`, `custom`.
- `tools/config/render.py --env <env> --component <id>` writes `<root>/terraform.tfvars.json` containing
  `environment` (globals subset declared by the component) and `settings` (its block). The component
  fingerprint hashes only those values, so changing one component's settings selects only that component.
- Every root declares at least:

```hcl
variable "environment" {
  type = object({
    name            = string           # dev, test, ...
    location        = string
    subscription_id = string
    tenant_id       = string
    name_prefix     = string           # default "eh"
    owner           = string
    team            = string
    cost_center     = string
    expires_on      = string           # YYYY-MM-DD
    tags            = map(string)
  })
}
variable "settings" { type = any  default = {} }   # or a typed object in mature roots
```

## 7. Naming and tagging

- Module `foundation/modules/naming`: `name("<type>", "<workload>")` →
  `<prefix>-<type>-<workload>-<env>-<regionShort>` (CAF abbreviations), with a deterministic 5-char
  suffix `substr(sha1("${subscription_id}/${prefix}/${env}"), 0, 5)` for globally unique names
  (storage, ACR, Key Vault, Cosmos, etc.). Never use `random_*` for names.
- Module `foundation/modules/tags`: required tags on every taggable resource:
  `env, application, service, version, team, owner, domain, tier, region, managed_by, component, layer,
  cost_center, expires_on, data_classification=synthetic, repository`.
  `service`/`version` default to `"platform"`/`"n/a"` for infrastructure.
- Datadog unified tags on telemetry: `env, service, version` plus `team, owner, application, domain, tier,
  region, managed_by`.

## 8. Network defaults

Hub `10.40.0.0/20`, workload spoke `10.41.0.0/16` (configurable). Low-cost profile collapses to a single spoke
with no Firewall (NAT Gateway for egress). Subnet catalogue (names fixed, prefixes configurable):

| Subnet key | Purpose | Delegation |
|---|---|---|
| `compute` | VMs, VMSS | — |
| `aks-nodes` | AKS nodes (Azure CNI overlay) | — |
| `aca-infra` | Container Apps environment (workload profiles, /23 min) | `Microsoft.App/environments` |
| `appsvc-integration` | App Service / Functions VNet integration | `Microsoft.Web/serverFarms` |
| `flex-integration` | Flex Consumption VNet integration | `Microsoft.App/environments` |
| `aci` | Container Instances | `Microsoft.ContainerInstance/containerGroups` |
| `private-endpoints` | Private endpoints | — |
| `postgres` | PostgreSQL Flexible (VNet injection) | `Microsoft.DBforPostgreSQL/flexibleServers` |
| `mysql` | MySQL Flexible (VNet injection) | `Microsoft.DBforMySQL/flexibleServers` |
| `sqlmi` | SQL Managed Instance | `Microsoft.Sql/managedInstances` |
| `cassandra-mi` | Managed Instance for Apache Cassandra | — |
| `batch` | Batch pool | — |
| `deploy-agents` | Self-hosted pipeline agents / Managed DevOps Pools | (`Microsoft.DevOpsInfrastructure/pools` when MDP) |
| `observability` | collectors, private synthetics location, DBM agent | — |
| `sfmc`, `aro-master`, `aro-worker` | specialized | — |
| `AzureBastionSubnet`, `AzureFirewallSubnet`, `appgw` | hub / edge (optional) | — |

Databases, Key Vault, storage, registries, Service Bus Premium and management endpoints are private by default
(`public_network_access_enabled = false`) when the SKU supports it; exceptions are recorded per component in its
README and in `catalog/services/*.yaml` (`networking.private_support`).

## 9. Applications (Enterprise Hello)

| Service id | Language | Data boundary (owner) | Primary architecture |
|---|---|---|---|
| `hello-frontend` | React/TypeScript | none (browser) | Static Web Apps; nginx container variant |
| `hello-bff` | .NET 10 | none | AKS |
| `hello-orders-api` | .NET 10 | Azure SQL DB `orders` schema `orders` | AKS |
| `hello-inventory-api` | .NET 10 | Cosmos DB NoSQL db `inventory` | App Service (Windows code) / ACA |
| `hello-catalog-api` | Python 3.13 FastAPI | PostgreSQL db `catalog` + Managed Redis cache-aside | AKS / App Service Linux |
| `hello-dbadapter-<family>` | Python 3.13 FastAPI | one boundary per family | ACA / App Service / VM (mapping in `catalog/architecture-matrix.yaml`) |
| `hello-worker` | Python 3.13 | consumes `notifications` queue; writes Table Storage | VMSS / VM / AKS |
| `hello-durable` | .NET 10 isolated Durable Functions | SQL schema `fulfillment`; Durable runtime storage separate | Functions Flex Consumption |
| `hello-partner-sim` | Python 3.13 | none (simulated external API) | ACI |
| `hello-jobs` | Python 3.13 | reconciliation summaries in SQL `fulfillment.reconciliation` | ACA Jobs, Azure Batch |
| `hello-traffic` | Python 3.13 (+Playwright) | none | ACA scheduled job |

User journey (vertical slice): browser → `hello-bff` `/api/orders` → `hello-orders-api` → `hello-catalog-api`
(price, Redis cache) → SQL write/read → Service Bus `orders` → `hello-durable` OrderProcessing orchestration →
`hello-partner-sim` → SQL `fulfillment` status → frontend polls `/api/orders/{id}` and renders status.

Common service contract (all HTTP services):

- `GET /healthz` (liveness), `GET /readyz` (dependencies), `GET /version` (`{service, version, commit, build_time}`).
- Env vars: `DD_ENV`, `DD_SERVICE`, `DD_VERSION`, `OTEL_SERVICE_NAME`, `OTEL_RESOURCE_ATTRIBUTES`,
  `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_EXPORTER_OTLP_PROTOCOL`, `LOG_FILE_PATH` (optional shared-file log sink),
  `FAULTS_ENABLED` (default `false`), `FAULT_TOKEN_SECRET_ID`/`FAULT_TOKEN` (lab only).
- Logs: one JSON object per line with `timestamp, level, message, logger, service, env, version,
  trace_id (32 hex), span_id (16 hex), dd.trace_id, dd.span_id (decimal low 64 bits), dd.service, dd.env, dd.version`.
  Secrets are never logged.
- Timeouts on every outbound call, pooled clients, bounded retries with jitter, idempotency keys (`Idempotency-Key`).
- Fault injection: `POST /admin/faults` with header `X-Fault-Token`; body `{type, rate, duration_seconds<=900}`;
  rejected when `FAULTS_ENABLED != true`; faults expire automatically.

## 10. Telemetry paths (authoritative)

- **Application logs → Fluent Bit → Datadog** (HTTP output, TLS, `DD_SITE`). No other collector may ship the same
  application logs. Container stdout collection by the Datadog Agent is **disabled** where Fluent Bit collects.
  - AKS: Fluent Bit DaemonSet tails `/var/log/containers`.
  - VM/VMSS: Fluent Bit service tails the app log file.
  - ACA / ACI: Fluent Bit sidecar tails a shared `EmptyDir`/volume file written by the app (`LOG_FILE_PATH`).
  - App Service, Functions, Logic Apps Standard: diagnostic settings (`AppServiceConsoleLogs`, `FunctionAppLogs`,
    `WorkflowRuntime`) → Event Hubs (Kafka endpoint) → Fluent Bit aggregator (`kafka` input) → Datadog.
- **Traces/metrics**: OpenTelemetry SDKs → OTLP → Datadog Agent OTLP receiver (AKS DaemonSet, VM agent) or the
  observability OTel gateway (DDOT/upstream collector on ACA, internal ingress only) for managed runtimes.
- **Browser**: Datadog Browser RUM with `allowedTracingUrls` (W3C `tracecontext`) for first-party API origins only.
- **Azure platform metrics/control-plane**: Datadog Azure integration (+ diagnostic settings for platform logs
  that are *not* application logs, e.g. `ContainerAppSystemLogs`, SQL audit).
- **Databases**: Azure platform metrics (integration) ≠ client spans (OTel) ≠ DB logs (diag settings) ≠
  Database Monitoring (Agent DBM check from the `observability` subnet). Coverage is reported per signal.

## 11. Testing levels and evidence vocabulary

| Status | Meaning |
|---|---|
| `cataloged` | entry exists, nothing implemented |
| `implemented` | code exists and passes static validation (`fmt`, `validate`, `terraform test` with mocks, unit tests) |
| `locally-verified` | exercised in local integration tests (docker) |
| `deployed` | applied to a real Azure subscription (evidence file under `docs/evidence/`) |
| `verified` | deployed **and** smoke + telemetry verification passed (evidence file) |
| `disabled` | implemented but off by default (cost/preview/retired) |
| `blocked` | cannot be implemented/deployed; exact prerequisite recorded |

Nothing may be reported `deployed` or `verified` without an evidence file produced by the pipeline or tools.

## 12. Terraform root layout

```
<root>/
  README.md               owner, purpose, inputs (contracts), outputs (contract), cost, teardown
  versions.tf             terraform + required_providers (pins above)
  backend.tf              backend "azurerm" {}
  providers.tf            provider config (subscription from var.environment, storage_use_azuread = true)
  variables.tf            environment, settings, upstream contract variables
  main.tf / *.tf
  outputs.tf              output "contract"
  .terraform.lock.hcl     committed
  tests/*.tftest.hcl      mock_provider based plan tests
```

Run checks with `tools/validate/terraform.sh <root>` (fmt -check, init -backend=false, validate, test).
