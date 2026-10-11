# Implementation checklist

Requirement list of the original brief, grouped in sections 1-14, with status per
[ADR-0001 section 11](architecture/ADR-0001-design-contract.md#11-testing-levels-and-evidence-vocabulary) and links to
the implementing files. The requirement wording below is a summary reconstructed from the ADR and the layer READMEs.

Columns: **Status** (`implemented`, `disabled` = implemented but off by default, `blocked`, `cataloged`, `partial`),
**Static validation** and **Local integration** (current numbers: [validation results](evidence/validation-results.md);
"per README" = reported by the owner's README). **Live verification is `not-run` for every row**: nothing has been
deployed ([evidence](evidence/README.md)).

## 1. Service catalog and coverage

| # | Requirement | Status | Implementing files | Static validation | Local integration |
|---|---|---|---|---|---|
| 1.1 | Machine-readable Azure service catalog (compute, serverless, databases, analytics, messaging, partner, Fabric, specialized) with lifecycle, availability, networking, IaC, workload, telemetry, cost | implemented (counts: [README status summary](../README.md#status-summary)) | [catalog/services/](../catalog/services/), [catalog/schemas/service.schema.json](../catalog/schemas/service.schema.json) | pass (`tools/catalog/validate.py`) | n/a |
| 1.2 | Architecture -> workload mapping without Cartesian product; every DB family exercised by an owner | implemented | [catalog/architecture-matrix.yaml](../catalog/architecture-matrix.yaml), [architecture deployment matrix](guides/architecture-deployment-matrix.md) | pass | partial: orders/catalog/inventory/durable/worker/partner-sim + dbadapter-postgresql exercised ([e2e](evidence/local/LATEST.md)); dbadapter families run against local containers in their own integration tests |
| 1.3 | Telemetry capability matrix per architecture and DB family | implemented | [catalog/telemetry-capabilities.yaml](../catalog/telemetry-capabilities.yaml), [docs/coverage/telemetry-capability-matrix.md](coverage/telemetry-capability-matrix.md) | pass (`render_coverage.py --check`) | n/a |
| 1.4 | Provider gaps recorded; AzAPI only for listed gaps | implemented (incl. observability `Microsoft.App/containerApps@2025-07-01` and `Microsoft.Datadog/monitors/monitoredSubscriptions@2025-06-11`) | [catalog/provider-gaps.yaml](../catalog/provider-gaps.yaml) | pass (`tools/catalog/validate.py`) | n/a |
| 1.5 | Generated coverage documents, live validation shown as not-run | implemented | [tools/catalog/render_coverage.py](../tools/catalog/render_coverage.py), [coverage matrix](coverage/coverage-matrix.md) | pass | n/a |

## 2. Repository structure, ownership, state and contracts

| # | Requirement | Status | Implementing files | Static validation | Local integration |
|---|---|---|---|---|---|
| 2.1 | Binding design contract (layers, ownership, state, contracts, naming, telemetry paths, status vocabulary) | implemented | [ADR-0001](architecture/ADR-0001-design-contract.md) | n/a | n/a |
| 2.2 | Component registry = unit of change detection, state and deployment | implemented | [catalog/components.yaml](../catalog/components.yaml), [component ownership](guides/component-ownership.md) | pass (`tools.changeset graph`, `ownership.py`) | n/a |
| 2.3 | One state file per root `<env>/<id>.tfstate`, azurerm backend with Entra auth, no `terraform_remote_state` | implemented | `*/backend.tf`, [pipelines/scripts/tf-init.sh](../pipelines/scripts/tf-init.sh) | pass | n/a |
| 2.4 | Versioned output contracts with JSON schemas, envelopes, materialization into consumer variables; no secrets | implemented | [catalog/contracts/](../catalog/contracts/), [tools/contracts/](../tools/contracts/) | pass (`tests/tools`, contract schema checks in root tests) | n/a |
| 2.5 | Environment + profile configuration, per-component rendered tfvars and fingerprints | implemented (profile `features` mapped to component settings: [profiles README](../environments/profiles/README.md)) | [environments/](../environments/), [tools/config/](../tools/config/) | pass (`tests/tools`) | n/a |
| 2.6 | Naming and tagging modules used by every lab root | implemented | [foundation/modules/naming](../foundation/modules/naming/main.tf), [foundation/modules/tags](../foundation/modules/tags/main.tf) | pass | n/a |
| 2.7 | Pinned toolchain / provider versions checked | implemented | [versions.yaml](../versions.yaml), [tools/validate/versions.py](../tools/validate/versions.py) | pass | n/a |

## 3. Bootstrap and foundation

| # | Requirement | Status | Implementing files | Static validation | Local integration |
|---|---|---|---|---|---|
| 3.1 | State storage (versioning, soft delete, keys off, lock), containers, local-state-first bootstrap with migration | implemented | [bootstrap/](../bootstrap/README.md), [bootstrap/scripts/bootstrap.sh](../bootstrap/scripts/bootstrap.sh) | pass | n/a (Azure-only; bootstrap script syntax-checked) |
| 3.2 | Least-privilege pipeline identities with workload identity federation (plan / apply / build / validate) | implemented | [bootstrap/identities.tf](../bootstrap/identities.tf) | pass | n/a |
| 3.3 | Hub/spoke or single-spoke network, subnet catalogue with delegations, NSGs, explicit egress (NAT / firewall), private DNS zones | implemented | [foundation/network/](../foundation/network/README.md) | pass | n/a |
| 3.4 | Workload identities + Delinea DSV secret model (contract v2: per-identity secret lists, `dsv://` refs); DSV users/least-privilege permissions rendered by `foundation-secrets` and converged by `tools/secrets/dsv_apply.py`; values set out-of-band (no Key Vault) | implemented | [foundation/identity/](../foundation/identity/README.md), [foundation/secrets/](../foundation/secrets/README.md), [tools/secrets](../tools/secrets/dsv_apply.py) | pass (+ `test_no_secret_values.py`, `tests/tools/test_secrets_tools.py` against the mock DSV) | n/a |
| 3.5 | Budget, policy, expiry tags, expired-resource finder | implemented | [foundation/governance/](../foundation/governance/README.md) | pass | n/a |
| 3.6 | Private deployment agents (VMSS or Managed DevOps Pool) | implemented | [foundation/deploy-agents/](../foundation/deploy-agents/README.md) | pass | n/a |
| 3.7 | Optional edge: App Gateway WAF, Front Door, APIM v2, Firewall, Bastion | disabled (all off by default) | [foundation/edge/](../foundation/edge/README.md) | pass | n/a |

## 4. Platform (compute, data, messaging)

| # | Requirement | Status | Implementing files | Static validation | Local integration |
|---|---|---|---|---|---|
| 4.1 | Shared ACR + platform Log Analytics | implemented | [platform/shared/](../platform/shared/README.md) | pass | n/a |
| 4.2 | Service Bus topic `order-events` (fulfillment, notifications, audit, archive) + queue `batch-items`, entity-scoped RBAC | implemented | [platform/messaging/](../platform/messaging/README.md) | pass | n/a |
| 4.3 | Compute platforms: AKS, Container Apps, App Service, Functions (Flex/EP/Y1/DTS), VM, VMSS, Batch | implemented (EP1, Y1, DTS, Windows container, WS1 disabled) | [platform/compute/](../platform/README.md) | pass | n/a |
| 4.4 | Service Fabric managed cluster, specialized compute | disabled | [servicefabric](../platform/compute/servicefabric/README.md), [specialized](../platform/compute/specialized/README.md) | pass | n/a |
| 4.5 | ARO; AVS | ARO disabled (implemented, off by default; prerequisites in README; managed OIDC issuer + application workload identity federation, contract 1.1.0 `workload_identities`); AVS blocked | [aro](../platform/compute/aro/README.md) | pass (ARO root) | n/a |
| 4.6 | Databases: SQL, SQL VM, PostgreSQL, MySQL, Cosmos (5 APIs), DocumentDB, Managed Redis, Table Storage, Ledger, analytics stores | implemented | [platform/data/](../platform/data/README.md) | pass | n/a |
| 4.7 | SQL MI, Cassandra MI, elastic pool, Hyperscale, PostgreSQL elastic cluster, Synapse/ADX/Search | disabled | [platform/data/](../platform/data/README.md) | pass | n/a |
| 4.8 | HorizonDB (preview) | disabled (implemented, off by default; preview access required) | [platform/data/horizondb](../platform/data/horizondb/README.md) | pass | n/a |
| 4.9 | Private by default; public exceptions recorded | implemented (exceptions listed) | root READMEs, [known limitations](known-limitations.md#public-endpoint-and-authentication-exceptions) | pass (checkov per owner READMEs) | n/a |

## 5. Applications (Enterprise Hello)

| # | Requirement | Status | Implementing files | Static validation | Local integration |
|---|---|---|---|---|---|
| 5.1 | Frontend SPA with RUM (`allowedTracingUrls`, tracecontext), runtime `config.json` | implemented | [applications/services/frontend](../applications/services/frontend/README.md), [deployments/frontend](../applications/deployments/frontend/README.md) | per README (vitest, Playwright e2e) | pass: RUM view/resource/action captured, traceparent on API calls ([e2e](evidence/local/LATEST.md) #1-2) |
| 5.2 | BFF, orders-api, inventory-api (.NET 10) | implemented | [bff](../applications/services/bff/README.md), [orders-api](../applications/services/orders-api/README.md), [inventory-api](../applications/services/inventory-api/README.md) | per README (`dotnet test`) | pass: real SQL Server + Service Bus emulator; inventory in memory mode ([e2e](evidence/local/LATEST.md)) |
| 5.3 | catalog-api, dbadapter, worker, partner-sim, functions, traffic (Python 3.13) | implemented | [applications/services/](../applications/python/README.md) | per README (`pytest`) | pass: catalog (Postgres+Redis), worker (SB emulator+Azurite), partner-sim, dbadapter-postgresql ([e2e](evidence/local/LATEST.md)); functions/traffic container smoke per README |
| 5.4 | Common service contract: `/healthz`, `/readyz`, `/version`, JSON logs with trace correlation, timeouts, bounded retries, idempotency | implemented | [applications/shared/](../applications/shared/python/hello_common/README.md), [applications/dotnet](../applications/dotnet/README.md) | per README | pass: health/ready/version, JSON logs with trace ids, idempotency replay ([e2e](evidence/local/LATEST.md) #5, #10) |
| 5.5 | Deployment roots own app resources and all settings; digest-pinned images; Delinea DSV references (`dsv://`; ARO hello-catalog-api reads DSV directly with workload identity, chart `secretsMode: dsv`, no synced Secret) | implemented | [applications/deployments/](../applications/deployments/README.md) | pass | n/a |
| 5.6 | One owner per data boundary (DB per service) | implemented | [architecture deployment matrix](guides/architecture-deployment-matrix.md#databases-owner-service-and-data-boundary) | pass | pass for SQL orders/fulfillment, Postgres catalog, Table notifications ([e2e](evidence/local/LATEST.md)) |
| 5.7 | Fault injection: authenticated, limited, auto-expiring, default-disabled | implemented | [fault-injection runbook](runbooks/fault-injection.md) | per README (unit tests) | pass: 403 wrong token, 404 disabled, auto-expiry recovery ([e2e](evidence/local/LATEST.md) #9) |
| 5.8 | Audit function sink selection from deployment settings | implemented (`deploy-functions` sets `AUDIT_SINK` = ledger / table / log) | [deployments/functions/main.tf](../applications/deployments/functions/main.tf), [handlers.py](../applications/services/functions/hello_functions/handlers.py) | pass (each side separately) | n/a (deployment setting; unit-tested) |

## 6. Durable workflows and jobs

| # | Requirement | Status | Implementing files | Static validation | Local integration |
|---|---|---|---|---|---|
| 6.1 | OrderProcessing orchestration with retries, timer, compensation; idempotent activities; separate runtime storage vs business DB | implemented | [applications/services/durable](../applications/services/durable/README.md) | per README (`dotnet test`) | pass: order Fulfilled via Service Bus emulator -> OrderProcessing, spans in browser trace ([e2e](evidence/local/LATEST.md) #3) |
| 6.2 | BatchProcessing fan-out/fan-in, Reconciliation, history purge | implemented | same | per README | pass in local Functions host run (Azurite + SQL Server) per durable README; not in e2e |
| 6.3 | Workflow metrics `hello.workflow.completed` / `duration` (replay-safe) | implemented | same | per README (`WorkflowMetricsTests`) | unit tests only (metrics not asserted in e2e) |
| 6.4 | Durable on Flex Consumption (+ Windows Consumption Reconciliation) | implemented | [deployments/durable](../applications/deployments/durable/README.md) | pass | n/a |
| 6.5 | Status updates from durable to orders-api wired automatically | implemented (`ORDERS_API_URL` / `INVENTORY_API_URL` / `PARTNER_API_URL` from optional deploy contracts, settings override; jobs `DURABLE_API_URL` from deploy-durable) | [deployments/durable/main.tf](../applications/deployments/durable/main.tf) | pass | n/a |
| 6.6 | Jobs: ACA manual / scheduled / event-driven (KEDA with managed identity), Azure Batch daily aggregate, traffic generator | implemented | [applications/services/jobs](../applications/services/jobs/README.md), [deployments/jobs](../applications/deployments/jobs/README.md), [traffic](../applications/services/traffic/README.md) | pass / per README | jobs batch-item processor against SB emulator + Azurite (jobs integration test); ACA/Batch scheduling Azure-only |
| 6.7 | Logic Apps Consumption + Standard (archive workflow) | implemented | [deployments/logicapps](../applications/deployments/logicapps/README.md), [services/logicapps](../applications/services/logicapps/README.md) | pass | n/a (Azure-only; workflow JSON schema-tested) |

## 7. Portable observability package

| # | Requirement | Status | Implementing files | Static validation | Local integration |
|---|---|---|---|---|---|
| 7.1 | Versioned package, self-contained (no references outside `observability/`), release tarball + sha256 | implemented (4.1.0) | [observability/README.md](../observability/README.md), [tools/release/package.sh](../observability/tools/release/package.sh), [tests/portability](../observability/tests/portability/test_portability.py) | pass (module tests in `all_terraform`) | pass: package built + vendored outside the repo (observability/tests/portability) |
| 7.2 | One-manifest onboarding with schemas, deterministic committed render (v2: identity, tags, resources, telemetry; v1 archetypes only in extras) | implemented | [observability/schemas](../observability/schemas/), [tools/onboarding](../observability/tools/onboarding/), [extras archetypes](../observability/extras/content/archetypes/) | pass (`validate --strict`, `render --check`) | n/a |
| 7.3 | Existing-environment example (vendored release, no lab dependency, fault injection disabled) | implemented | [examples/existing-environment](../observability/examples/existing-environment/README.md) | per README (`terraform test` after vendoring) | pass: plan with mock providers from an isolated copy (portability tests) |
| 7.4 | Upgrade / rollback / removal procedures preserving infrastructure and data | implemented | [UPGRADING.md](../observability/UPGRADING.md), [observability/README.md](../observability/README.md#5-upgrade-rollback-removal) | n/a | n/a |
| 7.5 | Instrumentation hook (integration contract) for application owners | implemented | [modules/instrumentation](../observability/modules/instrumentation/main.tf), [deployments/modules/app-env](../applications/deployments/modules/app-env/main.tf) | pass | n/a |

## 8. Telemetry collection

| # | Requirement | Status | Implementing files | Static validation | Local integration |
|---|---|---|---|---|---|
| 8.1 | App logs, one collector per architecture (ADR §13 2026-10-10, 4.0.0): Datadog Agent on AKS nodes and Linux/Windows VM/VMSS, Agent sidecar in ACI, serverless-init on Container Apps, Event Hubs (App Service/Functions/Logic Apps/ACA jobs) -> Observability Pipelines Worker (central log pipeline); Fluent Bit only for `fluent_bit_direct` and Batch | implemented (Batch: job preparation task runs the observability-published Fluent Bit setup with the static dsv-fetch release, ADR §13) | [observability/config/fluent-bit](../observability/config/fluent-bit/), [config/observability-pipelines](../observability/config/observability-pipelines/), [modules/observability-pipeline](../observability/modules/observability-pipeline/README.md), [modules/fluent-bit](../observability/modules/fluent-bit/main.tf), [modules/telemetry-transport](../observability/modules/telemetry-transport/), [lab/telemetry-transport](../observability/lab/telemetry-transport/README.md) | pass | pass: sidecar route for 8 apps ([e2e](evidence/local/LATEST.md) #5-6); Kafka/Event Hubs-style aggregator path ([transport tests](../observability/tests/transport/)); DaemonSet dry-run only (`observability/tests/transport`) |
| 8.2 | Traces/metrics: Datadog tracers (`TELEMETRY_SDK=datadog`: SSI on AKS/Linux hosts; Container Apps serverless-init sidecar with DogStatsD, key from DSV; APM gateway for ACI/ACA jobs; App Service, Functions/Durable on OTel) or OTel SDK -> Agent OTLP / OTel gateway (`otel` mode) | implemented (DogStatsD gaps: [known limitations](known-limitations.md#application-and-telemetry-limitations)) | [config/fleet-policy.yaml](../observability/config/fleet-policy.yaml), [modules/instrumentation](../observability/modules/instrumentation/README.md), [config/otel](../observability/config/otel/gateway.yaml), [modules/otel-collector](../observability/modules/otel-collector/main.tf) | pass | pass: OTLP -> gateway -> datadog exporter -> mock intake ([e2e](evidence/local/LATEST.md) #11) |
| 8.3 | Agents (4.0.0; 4.1.0: ARO via `obs-kubernetes-aro` with `distribution = openshift`, Service Fabric managed cluster node types via `vmApplications`): Kubernetes Helm with layered values + dsv-fetch post-renderer (node Agent + Cluster Agent + cluster-checks runners, one DSV secret path); VM/VMSS via Azure Policy (DeployIfNotExists) + Azure VM Applications (Linux + Windows, no per-host Terraform); ACI Agent sidecar; dsv-fetch static Go binary 2.0.0 | implemented | [lab/kubernetes](../observability/lab/kubernetes/README.md), [lab/kubernetes-aro](../observability/lab/kubernetes-aro/README.md), [lab/hosts](../observability/lab/hosts/README.md), [modules/host-agent-policy](../observability/modules/host-agent-policy/README.md), [images/dsv-fetch](../observability/images/dsv-fetch/README.md) | pass | pass: helm template of datadog 3.253.2 through the post-renderer ([tests/kubernetes](../observability/tests/kubernetes/test_datadog_chart.py)); VM Application Linux installer in ubuntu:24.04 ([host-agent-package tests](../observability/modules/host-agent-package/tests/test_installers.py)); ACI sidecar + ACA serverless-init in docker ([test_agent_sidecar.py](../observability/tests/transport/test_agent_sidecar.py)); dsv-fetch conformance suite (Go binary). No cluster (AKS or ARO), no Azure Policy, no Windows host / Service Fabric node run |
| 8.4 | Datadog Azure integration (app registration / Secretless / native) | implemented | [lab/azure-integration](../observability/lab/azure-integration/README.md), [modules/azure-integration](../observability/modules/azure-integration/main.tf) | pass | n/a |
| 8.5 | Diagnostic settings owned only by `obs-diagnostics`, resource discovery from contracts | implemented | [lab/diagnostics](../observability/lab/diagnostics/README.md), [modules/diagnostic-settings](../observability/modules/diagnostic-settings/main.tf) | pass | n/a |
| 8.6 | Database Monitoring from the spoke (AKS cluster checks whenever a cluster exists - `obs-dbm` hosting auto; ACI Agent in the delegated `aci` subnet only without a cluster) | implemented | [lab/dbm](../observability/lab/dbm/README.md), [modules/dbm](../observability/modules/dbm/main.tf) | pass | pass: Agent 7.84.2 runs rendered DBM checks vs local Postgres/MySQL ([transport tests](../observability/tests/transport/)) (`tests/transport/test_dbm_local.py`) |
| 8.7 | Browser RUM with first-party trace propagation; tag policy as RUM global context (`setGlobalContextProperty`) | implemented | [lab/prereqs](../observability/lab/prereqs/README.md), [modules/rum](../observability/modules/rum/README.md) | pass | pass: tracecontext to first-party origin only ([e2e](evidence/local/LATEST.md) #1-2) |
| 8.8 | No double shipping (one collector per signal) | implemented by design | [ADR section 10](architecture/ADR-0001-design-contract.md#10-telemetry-paths-authoritative) as amended in [section 13](architecture/ADR-0001-design-contract.md#13-amendments) (4.0.0), [telemetry diagram](diagrams/README.md) | pass | pass: unique marker once per service; OTLP logs dropped at gateway ([e2e](evidence/local/LATEST.md) #6, #11) |

## 9. Monitoring as code

Since observability package 3.0.0 this content is **optional** and not part of the package or release tarball: it lives in
[observability/extras/content](../observability/extras/content/README.md) (version 2.0.0) and the `obs-monitoring` root is an
optional component that no profile enables by default.

| # | Requirement | Status | Implementing files | Static validation | Local integration |
|---|---|---|---|---|---|
| 9.1 | Monitors per archetype (APM, logs, platforms, data, messaging, pipeline) with runbook links and routing | implemented | [modules/monitors](../observability/extras/content/modules/monitors/README.md), [archetypes](../observability/extras/content/archetypes/) | pass | n/a |
| 9.2 | SLOs + burn-rate alerts | implemented | [modules/slos](../observability/extras/content/modules/slos/README.md) | pass | n/a |
| 9.3 | Synthetics (API, browser, private locations), dashboards, Software Catalog, downtimes | implemented (synthetics created paused) | [modules/synthetics](../observability/extras/content/modules/synthetics/README.md), [dashboards](../observability/extras/content/modules/dashboards/README.md), [service-catalog](../observability/extras/content/modules/service-catalog/README.md) | pass | n/a |
| 9.4 | Missing telemetry vs intentional idleness (canary, scale-to-zero) | implemented | [observability/README.md](../observability/README.md) section 1.4 | pass | n/a |
| 9.5 | Lab onboarding of every service (32 rendered services) | implemented (v2 manifests in the package; v1 content manifests in extras, `obs-monitoring` optional) | [observability/onboarding](../observability/onboarding/dev/), [extras onboarding](../observability/extras/content/onboarding/dev/), [lab/monitoring](../observability/extras/content/lab/monitoring/README.md) | pass | n/a |
| 9.6 | Alert runbooks referenced by monitors | implemented (archetype `runbook_base_url` -> `docs/runbooks/alerts/<service>.md` in the repository named by `metadata.repository`; lab repository URL is a placeholder org) | [runbooks/alert-response.md](runbooks/alert-response.md), [runbooks/alerts/](runbooks/alerts/README.md) | `tools/docs/generate.py --check` | n/a |

## 10. Pipeline and delivery

| # | Requirement | Status | Implementing files | Static validation | Local integration |
|---|---|---|---|---|---|
| 10.1 | Change detection by fingerprints vs deployment records (+ upstream contract hashes); modes pr/deploy/manual/reconcile/drift/retire/promote | implemented | [tools/changeset](../tools/changeset/), [pipelines/README.md](../pipelines/README.md) | pass (`tests/changeset`) | n/a |
| 10.2 | Generated plan (P_) and apply (C_) stages per component in dependency order with correct conditions, one file per pipeline scope | implemented | [tools/pipeline/generate.py](../tools/pipeline/generate.py), [platform-stages.yml](../pipelines/generated/platform-stages.yml), [applications-stages.yml](../pipelines/generated/applications-stages.yml) | pass (`--check`, `tests/pipeline` simulator) | n/a |
| 10.3 | Validate + Security on hosted agents without credentials; PR builds never get credentials | implemented | [azure-pipelines.yml](../azure-pipelines.yml), [azure-pipelines.applications.yml](../azure-pipelines.applications.yml), [universal-stages.yml](../pipelines/templates/universal-stages.yml), [templates/validate.yml](../pipelines/templates/validate.yml), [templates/security-scan.yml](../pipelines/templates/security-scan.yml) | pass (`pipeline_lint.py`) | n/a |
| 10.4 | Build once, push by digest, SBOM + provenance | implemented | [templates/build-artifact.yml](../pipelines/templates/build-artifact.yml), [tools/deploy/artifacts.py](../tools/deploy/artifacts.py) | pass (`tests/tools`) | local docker builds of all images; ACR push/SBOM Azure-only |
| 10.5 | Plan bound to inputs, plan policy for protected deletions, apply only on changes behind approvals | implemented | [templates/terraform-plan.yml](../pipelines/templates/terraform-plan.yml), [terraform-apply.yml](../pipelines/templates/terraform-apply.yml), [plan_policy.py](../tools/validate/plan_policy.py) | pass | n/a |
| 10.6 | Contracts published, deployment records written, resumable partial deployments | implemented | [tools/contracts/publish.py](../tools/contracts/publish.py), [tools/deploy/record.py](../tools/deploy/record.py) | pass | n/a |
| 10.7 | Retirement only with explicit approval, consumers first | implemented | [tools/deploy/retire.py](../tools/deploy/retire.py), [templates/retire.yml](../pipelines/templates/retire.yml), [teardown runbook](runbooks/teardown.md) | pass | n/a |
| 10.8 | Drift detection (nightly, both pipelines) | implemented | [templates/drift.yml](../pipelines/templates/drift.yml) | pass | n/a |
| 10.9 | Exactly two pipelines (platform IaC, applications) as thin `extends` of one governed template (Required template check); applications re-planned after platform runs (resource trigger + contract hashes, waiting, stale-plan binding) | implemented | [universal.yml](../pipelines/templates/universal.yml), [tools/changeset/select.py](../tools/changeset/select.py), [pipelines/README.md](../pipelines/README.md) | pass (`tests/changeset/test_scopes_promotion.py`, `pipeline_templates.py`) | n/a |
| 10.10 | Multi-environment promotion dev -> test -> prod (`mode: promote`, same digests, source-environment gate) | implemented | [environments/promotion.yaml](../environments/promotion.yaml), [tools/config/promotion.py](../tools/config/promotion.py), [tools/deploy/artifacts.py](../tools/deploy/artifacts.py) | pass (`tests/changeset`, `tests/tools`) | n/a |
| 10.11 | Observability package release on `observability-v*` tags (tests, tarball, sha256, Universal Package, release notes) | implemented | [observability-release.yml](../pipelines/templates/observability-release.yml), [tools/report/release_notes.py](../tools/report/release_notes.py) | pass (`tests/tools`, `tests/pipeline`) | package built locally |
| 10.12 | Template-contract and ADO-limit lint; Helm chart lint/package/OCI push | implemented | [tools/validate/pipeline_templates.py](../tools/validate/pipeline_templates.py), [tools/deploy/charts.py](../tools/deploy/charts.py) | pass | helm 4.3.0 lint/package locally |

## 11. Cost and lifecycle

| # | Requirement | Status | Implementing files | Static validation | Local integration |
|---|---|---|---|---|---|
| 11.1 | Small default SKUs, scaling ceilings, expensive services off | implemented | [cost controls](guides/deployment-profiles.md#cost-controls) | pass (variable validations) | n/a |
| 11.2 | Budgets (alerts only), expiry tags, expired-resource finder | implemented | [foundation/governance](../foundation/governance/README.md) | pass | n/a |
| 11.3 | Auto-shutdown / auto-pause / schedules | implemented (VM, SQL serverless, SQL MI, ADX; AKS/VMSS manual) | root READMEs | pass | n/a |
| 11.4 | Retention and sampling controls | implemented (profile `trace_sample_rate` / RUM sample flags mapped to settings) | [retention and sampling](guides/deployment-profiles.md#retention-and-sampling) | pass | n/a |
| 11.5 | Teardown in reverse dependency order, data deletion documented, tag-scoped cleanup | implemented | [teardown runbook](runbooks/teardown.md) | n/a | n/a |

## 12. Verification and evidence

| # | Requirement | Status | Implementing files | Static validation | Local integration |
|---|---|---|---|---|---|
| 12.1 | Bounded HTTP smoke tests from contract endpoints | implemented | [tools/smoke/smoke.py](../tools/smoke/smoke.py), [deployments/scripts/smoke.sh](../applications/deployments/scripts/smoke.sh) | pass (`tests/tools`) | smoke.sh exercised against a local HTTP server |
| 12.2 | End-to-end telemetry verification (RUM -> trace -> logs, no duplicates, tags, infra metrics) | implemented | [telemetry_verify.py](../observability/tools/verify/telemetry_verify.py) | pass (recorded responses, `observability/tests/content`) | local analogue passed against mock intake ([e2e](evidence/local/LATEST.md)); Datadog API verifier unit-tested with recorded responses |
| 12.3 | Deployment report + evidence.json, DORA deployment events; copy of a run's evidence into `docs/evidence/<env>/<run id>/` | implemented | [tools/report](../tools/report/report.py), [pull_evidence.py](../tools/report/pull_evidence.py), [templates/evidence.yml](../pipelines/templates/evidence.yml) | pass (`tests/tools`) | n/a |
| 12.4 | No `deployed`/`verified` claim without evidence | implemented (no claims made) | [evidence/README.md](evidence/README.md) | n/a | n/a |

## 13. Security and secrets

| # | Requirement | Status | Implementing files | Static validation | Local integration |
|---|---|---|---|---|---|
| 13.1 | No secrets in contracts; Delinea DSV references only; secret values out-of-band (DSV), workloads read DSV with their managed / workload identity (AKS and ARO: no Kubernetes Secret), pipelines fetch with the deploy agent identity, no Key Vault / variable groups (lint SEC001, PL015, OWN008) | implemented (state exceptions listed) | [foundation/identity](../foundation/identity/README.md), [known limitations](known-limitations.md#secrets-in-terraform-state) | pass | n/a |
| 13.2 | Entra-only auth where supported (SQL, PostgreSQL, Service Bus, Storage, Cosmos NoSQL/Table, Redis, ACR, Batch) | implemented (key-auth exceptions: Cosmos Mongo/Cassandra/Gremlin, Event Hubs SAS for the Kafka consumer - Observability Pipelines Worker, or the Fluent Bit aggregator with `fluent_bit_direct`) | platform READMEs | pass | n/a |
| 13.3 | Secret scanning, IaC scanning, container scanning in the pipeline | implemented | [templates/security-scan.yml](../pipelines/templates/security-scan.yml) | pass (lint) | n/a |
| 13.4 | Secret rotation and break-glass procedures | implemented | [secret-rotation](runbooks/secret-rotation.md), [break-glass](runbooks/break-glass.md) | n/a | n/a |

## 14. Documentation

| # | Requirement | Status | Implementing files | Static validation | Local integration |
|---|---|---|---|---|---|
| 14.1 | README with layers, profiles, quick start, map, status | implemented | [README.md](../README.md) | `tools/docs/check_links.py` | n/a |
| 14.2 | Diagrams (foundation, platform, application, telemetry, delivery) as source + rendered SVG with staleness check | implemented | [docs/diagrams](diagrams/README.md), [render_diagrams.sh](../tools/docs/render_diagrams.sh) | pass (`--check`) | n/a |
| 14.3 | Guides (getting started, profiles and cost, ownership, observability, delivery) and the documentation index | implemented | [docs/README.md](README.md), [docs/guides](guides/) | pass (links) | n/a |
| 14.4 | Runbooks: rotation, rollback, teardown, break-glass, lock recovery, quarantine, CI speed, alert response, fault injection | implemented | [docs/runbooks](runbooks/README.md) | pass (links, generated check) | n/a |
| 14.5 | Known limitations, implementation checklist, evidence README | implemented | [known-limitations.md](known-limitations.md), this file, [evidence](evidence/README.md) | pass (links) | n/a |
| 14.6 | Per-root README (owner, purpose, contracts, settings, cost, teardown, networking, limitations, docs) | implemented (cross-layer reconciliation 2026-10-09 fixed the READMEs listed as stale) | `*/README.md` | n/a | n/a |
