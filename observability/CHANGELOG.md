# Changelog

All notable changes to the observability package. Format: Keep a Changelog; versioning: SemVer (see README section 6).

## [Unreleased]

## [4.0.0] - 2026-10-10

**BREAKING** (SemVer major): **Datadog Agent deployment v4** - one Datadog collection path per architecture, one
secret path for every Agent (Delinea DSV + the static dsv-fetch binary), no per-host Terraform. See `UPGRADING.md`
"4.0.0". Nothing has been deployed or verified live (status: implemented / locally verified).

### Added
- **dsv-fetch 2.0.0 is a static Go binary** (`images/dsv-fetch`, component `img-dsv-fetch`): same CLI, env, config,
  messages, exit codes and Agent protocol as 1.x; `init --refresh-seconds N [--retry-seconds 30]` (refresher mode);
  `install` copies the running binary (POSIX 0500 + owner, Windows ACL ddagentuser + SYSTEM + Administrators).
  Distroless image (`/opt/dsv-fetch/dsv-fetch`, uid 65532) and a release zip `dsv-fetch-linux-amd64`,
  `dsv-fetch-linux-arm64`, `dsv-fetch-windows-amd64.exe`, `SHA256SUMS` (built by `build.sh`, Go 1.24.13 pinned by
  digest; module path `enterprise-hello/dsv-fetch`, standard library only). The Python conformance suite runs against it.
- **Kubernetes** (`modules/kubernetes`): chart values in **layers** - `values/base.yaml`, a computed fleet layer and
  per-cluster `values_overrides` (applied last; overrides of the secret path are rejected) - and a **Helm
  post-renderer** (`postrender/dsv-fetch-init.sh`, POSIX sh + awk) that adds the `dsv-fetch-install` init container to
  the node Agent, Cluster Agent and cluster-checks runners. Outputs `datadog_values`, `datadog_postrender_args`;
  `dsv.cluster_checks_identity_client_id` (e.g. the DBM identity on `datadog/datadog-cluster-checks`).
- **VM / VMSS via Azure Policy + VM Applications**: `modules/host-agent-package` (Azure Compute Gallery, VM
  Applications `datadog-agent-linux` / `-windows`, versions = dsv-fetch release binary + rendered installer;
  `package_version` promoted dev -> test -> prod, immutable content check), `modules/host-agent-policy`
  (DeployIfNotExists initiative at subscription or management-group scope on hosts tagged `datadog:enabled`,
  remediation ARM deployment that sets `applicationProfile.galleryApplications` + the DSV-reader identity, least-privilege
  custom remediation role, remediation tasks), `modules/host-agents` (`mode = policy` default | `direct`). Linux and
  Windows Agents collect logs (fleet policy `logs.hosts`: files + Windows Event Log channels; per-host `datadog:log_paths`);
  `dsv-fetch.exe agent-backend` on Windows (the key is never written to `datadog.yaml`). Remote updates off (Fleet
  Automation inventory only).
- **ACI Datadog Agent sidecar** (`modules/instrumentation` `aci_sidecar`): traces `localhost:8126`, DogStatsD
  `localhost:8125`, logs tailed from the shared emptyDir file, key via the dsv-fetch binary (init container copy, root
  re-install). **Container Apps serverless-init collects logs** (`DD_LOGS_ENABLED=true`, `DD_SERVERLESS_LOG_PATH`),
  its start wrapper reads the key with dsv-fetch (no Container Apps secret).
- **DBM**: cluster checks whenever a cluster exists (`modules/dbm` `hosting = cluster_checks` default; lab `obs-dbm`
  `settings.hosting = auto`, `obs-kubernetes` `settings.dbm = auto`); the ACI DBM Agent only without a cluster.
- Fleet policy: `logs.collector` per architecture (`agent`, `agent_sidecar`, `serverless_init`, `azure`,
  `fluent_bit`), `logs.hosts.{linux.files, windows.files, windows.event_channels}`, `agent.image` + `agent.version`
  (the single Agent pin), `agent.serverless_init`, `apm.managed_runtime_path = agent_sidecar`.
- Pipeline templates: `dsvFetch` (release zip URL + sha256, `SHA256SUMS` verified, binary installed per job).
- Contract `obs-kubernetes` **v2** (`logs_enabled` per fleet policy, `log_pipeline`, `log_collector`,
  `fluent_bit.enabled`, SSI fields); v1 kept for rollback.

### Changed
- One application-log collector per architecture: Agent (AKS nodes, Linux + Windows VM/VMSS), Agent sidecar (ACI),
  serverless-init (Container Apps), diagnostic settings (App Service, Functions, Logic Apps). **Fluent Bit only** for
  `log_pipeline = fluent_bit_direct` and on Azure Batch nodes.
- Every Agent (node Agent, Cluster Agent, cluster-checks runners, host Agents, ACI sidecar / DBM Agent, APM gateway)
  resolves `ENC[dsv://...]` with the dsv-fetch binary as `secret_backend_command`; refresher containers run
  `init --refresh-seconds 3600`.
- `modules/telemetry-transport`: APM gateway Agent gets the binary from a `dsv-fetch-install` init container (no
  embedded script, no Python); the OP Worker refresher runs the binary's refresher mode.
- `modules/dbm`: passwords only as DSV references (`password_ref.kind = dsv`).
- Agent version: no hard-coded fallbacks; the fleet policy `agent.version` is required (also for the APM gateway,
  whose image is now the fleet pin `agent.image:agent.version`; its Container App gets the `registries` entry the
  `dsv-fetch-install` init container needs for the private dsv-fetch image).
- `modules/fleet-policy`: VM / VMSS hosts always use the Agent - `log_pipeline = fluent_bit_direct` only makes it ship to
  the Datadog intake, and the 3.x `logs.node_collector` key is honoured on AKS only (4.0.0 installs no Fluent Bit on
  hosts; `log_collector` / `node_collector` now say so).
- `modules/fleet-inventory`: the per-resource plan is resolved through `modules/fleet-policy` (architecture, runtime,
  OS); `app_logs` / `apm` / `agent` follow the 4.0.0 paths (`serverless_init`, `datadog_agent_sidecar`,
  `agent_sidecar`, `datadog_agent_vm_application`; App Service and Functions `otel` by policy).
- RUM: `allowedTracingUrls` propagate W3C `tracecontext` only (fleet policy `rum.propagator_types`, ADR-0001 section 10).
- `modules/kubernetes` contract: `agent.cluster_checks` follows `features.cluster_checks_runner`.

### Removed
- **Python dsv-fetch 1.x** (`images/dsv-fetch/dsv_fetch.py`) and every embedding of it (Agent ConfigMap secret
  backends, the transport `dsv_fetch_source` input, refresher stubs, pipeline `dsvFetchPath`).
- `modules/kubernetes`: `api_key` (`mode = existing` / synced Secret), `cluster_agent_secret_name`, the
  unauthenticated Cluster Agent opt-out (`DD_SECRET_BACKEND_COMMAND=""`), `resources`, `cluster_check_env`,
  `charts.agent_tag`, `op_worker.api_key_secret_name`; `op_worker.secret_env` values are `dsv://` references (no
  `{secret_name, key}`).
- `modules/host-agents`: the run-command / CustomScript host path, its `hosts`-driven installer
  (`scripts/linux-install.sh.tftpl`) and the Fluent Bit host service (policy mode needs no per-host Terraform;
  `mode = direct` keeps one gallery application assignment per VM).
- `modules/instrumentation`: the Fluent Bit sidecar as default ACA / ACI log collector (fallback only).
- `modules/dbm`: `k8s_secret`, `file` and `env` password references.
- `modules/instrumentation`: `serverless_init.api_key_secret_name` (ignored since the key comes from DSV).

## [3.0.0] - 2026-10-10

**BREAKING** (SemVer major): the package is now the **collection and tagging** layer of Datadog on Azure. It connects
resources and workloads to Datadog through the most mature Datadog path each type supports, with one tag policy on
every signal. Monitors, SLOs, dashboards, synthetics, the service catalog and notification routing are no longer
part of the package: they exist in your organisation and select on the tags. See `UPGRADING.md` "3.0.0".

### Added
- **Tag policy** (core product): `config/tag-policy.yaml` + `schemas/tag-policy.v1.schema.json` and
  `modules/tagging`, the single tagging function used on every path:
  - Agent `DD_TAGS`, UST labels, `ad.datadoghq.com/tags`, `podLabelsAsTags`;
  - tracer `DD_*` variables;
  - the OTel gateway `transform/eh_tag_policy`, Fluent Bit Lua and the Observability Pipelines VRL;
  - Azure resource tags and the RUM global context.

  `tools/tags/tag_policy.py` is the Python mirror (parity tested).
- **Tag tools** (read-only Datadog client; GET plus documented search POSTs only; offline fixtures):
  - `tools/tags/derive_from_monitors.py` proposes a tag policy from existing monitors and SLOs;
  - `tools/tags/check_coverage.py` reports monitored scopes that miss policy tags in live logs, spans and hosts;
  - `tools/tags/query_tags.py`.
- **Fleet policy** (`config/fleet-policy.yaml`, `modules/fleet-policy`) and one fleet inventory input
  (`modules/fleet-inventory`). Together they give one authoritative collector per resource and signal
  (`modules/README-transport.md`, `docs/guides/datadog-fleet-collection.md`).
- **Observability Pipelines as the default log pipeline** (`log_pipeline = observability_pipelines`):
  - `modules/observability-pipeline` (`datadog_observability_pipeline`). Sources: fluent, Datadog Agent, Event Hubs
    over Kafka. VRL tag policy and Azure shaping, Sensitive Data Scanner redaction, dedupe, sampling, quotas. Datadog
    Logs destination with a disk buffer (`when_full = block`); optional Azure Storage archive.
  - The Worker runs as a Container App with internal TCP ingress, probes and scale rules (`modules/telemetry-transport`),
    or on AKS through Helm chart 2.22.0 as a StatefulSet with PVCs (`modules/kubernetes` `op_worker`). Its secrets
    come from DSV and the Worker fails closed without them.
- **Datadog APM** (`apm.mode = datadog`, default):
  - AKS: Single Step Instrumentation (Cluster Agent admission controller, target namespaces, `ddTraceVersions`,
    init-container securityContext for the restricted PSS).
  - Linux VMs/VMSS: host SSI.
  - Managed runtimes: the library in the image plus the in-VNet **Datadog Agent APM gateway** on Container Apps
    (API key `ENC[dsv://]`).
  - ACA can opt in to serverless-init (`managed_runtime_path = serverless_init`).
  - Library contract: `TELEMETRY_SDK=datadog`, `DD_TRACE_OTEL_ENABLED=true`,
    `DD_TRACE_REMOVE_INTEGRATION_SERVICE_NAMES_ENABLED=true`, log injection, DogStatsD target,
    `DD_METRICS_OTEL_ENABLED=false`, sampling, `DD_DBM_PROPAGATION_MODE=full`, DSM for .NET Service Bus. Never any
    `OTEL_*` variable in this mode.
  - `apm.mode = otel` keeps the 2.x OpenTelemetry path. Azure Functions and Durable Functions stay on it by policy;
    Windows services fall back to it.
- **Continuous Profiler fleet-wide** (`profiling` in the fleet policy and in `modules/instrumentation` outputs):
  - .NET: CPU, wall time, exceptions, GC (lock, allocation and heap opt-in; allocation and heap are preview), code
    hotspots, endpoint profiling.
  - Python: stack, lock, memory, heap, timeline.
  - `DD_PROFILING_ENABLED=auto` under SSI.
  - Profiles carry UST + `DD_TAGS` and upload through the same Agent as the traces.
  - Unsupported combinations report a reason: .NET Function Apps, Python on Functions (preview), Windows hosts in
    otel mode, otel mode in general except the opt-in Python preview.
- **RUM back in core**: `modules/rum` creates an application or adopts an existing one. `browser_config` sets
  `allowedTracingUrls` with `propagatorTypes [datadog, tracecontext]`, session replay 0, and `globalContext` from the
  tag policy.
- **Fleet management**:
  - Agent version pinned (7.84.2) and Remote Configuration on everywhere.
  - Remote updates optional, plus an optional `datadog_fleet_schedule` (`modules/fleet-automation`).
  - `apm.ignore_resources` (health probes) on every Agent.
- `modules/kubernetes`: the node Agent collects container logs to the Worker (no Fluent Bit DaemonSet), SSI targets,
  `podLabelsAsTags`, Remote Configuration, an optional OP Worker.
- `modules/host-agents`: the Agent collects application logs on Linux hosts, host SSI, `DD_REMOTE_UPDATES`, and
  Fluent Bit forwards to the Worker on Windows.
- `modules/fluent-bit`: `log_destination = observability_pipelines` (forward, acknowledged, filesystem buffer,
  metadata-free so the Worker's fluent source accepts it), plus the Kubernetes label map, the Azure tag map and scope
  tags.
- Onboarding manifest **v2** (`schemas/onboarding-manifest.v2.schema.json`, `rendered-service.v2`): identity + tags +
  resources + telemetry routing. `tools/onboarding/migrate_v1.py` converts v1 manifests.
- `tools/verify/telemetry_verify.py`: `--tag-policy`, `--fleet-policy`, `--expected-tags-dir`; the pipeline tag
  follows `log_pipeline`.
- Local docker tests:
  - VRL programs (Vector CLI);
  - Fluent Bit 5.1.3 -> fluent source;
  - Worker 2.22.0 bootstrap (fail closed);
  - APM gateway Agent 7.84.2 (DSV secret backend, non-local traces, health).

### Changed
- Contract `obs-telemetry-transport` v2 (same schema, new values inside open objects):
  - `aggregator.{kind, pipeline_id, agent_logs_url}`;
  - `env.apm_gateway.DD_TRACE_AGENT_URL`;
  - `env.fleet` (`EH_LOG_PIPELINE`, `EH_APM_MODE`, `EH_PROFILING_ENABLED`);
  - `fluentbit.forward_host` is the Worker in OP mode and `sidecar_mode` is `forward`.
- `modules/instrumentation` takes `tag_policy`, `fleet_policy`, `apm`, `profiling`, `os_type`, `serverless_init` and
  the identity keys (`application`, `owner`, `region`, `managed_by`, `cost_center`, `component`, `extra`). New
  outputs: `tags`, `azure_tags`, `k8s_labels`, `k8s_annotations`, `apm`, `profiling`, `log_collector`,
  `app_requirements`, `rum_global_context`.
- Runtime metrics of Datadog libraries are enabled only next to an Agent (DogStatsD has no TCP transport).
- `pipelines/templates/validate-onboarding.yml` takes a `tagPolicy` parameter; `routingFile` and `archetypesDir` are
  ignored. `telemetry-verify.yml` takes `tagPolicy`, `fleetPolicy` and `expectedTagsDir`, and `pipelineTag` now
  defaults to the fleet policy.
- `examples/existing-environment` rewritten: fleet inventory, Observability Pipelines with the Worker on AKS, RUM,
  tags. It creates no monitoring content.

### Removed
- From the release (moved to `extras/content/`, optional, version 2.0.0 content, not packaged):
  - `modules/{monitors,slos,dashboards,synthetics,service-catalog,notification-routing,onboarding,log-management}`;
  - `archetypes/`, the v1 manifest / archetype / routing schemas and `tests/content` (content tests);
  - the lab root `obs-monitoring` (source repository only).
- `modules/fluent-bit` Lua `static_tags_without_env` (replaced by the tag-policy aware `eh_finalize`).

### Verification status
- Implemented and tested offline (terraform test with mock providers, pytest, docker).
- Not deployed and not verified against a live Datadog organisation.

## [2.0.0] - 2026-10-09

**BREAKING** (SemVer major): Azure Key Vault is no longer used for any secret. Every secret is a Delinea DevOps Secrets
Vault (DSV) reference `dsv://<path>#<element>` and is read at run time by the workload itself with its managed
identity (ADR-0001 section 14 of the source repository). See `UPGRADING.md` "2.0.0".

### Changed
- Contract `obs-telemetry-transport` **v2** (`catalog/contracts/obs-telemetry-transport.v2.schema.json`; v1 removed):
  `api_key_secret_id` -> `api_key_ref`, `otlp.headers_secret_id` -> `otlp.headers_ref`,
  `fluentbit.forward_shared_key_secret_id` -> `fluentbit.forward_shared_key_ref`; new required `secrets`
  `{provider: delinea-dsv, tenant, tld, base_url, auth, fetch_image, env_file}`; `additionalProperties: false`.
- Fluent Bit configs (`config/fluent-bit/*.yaml`): every main config `includes:` a dsv-fetch env-yaml file
  (`/dsv-secrets/fluentbit-env.yaml` in containers, `/run/fluent-bit-eh/fluentbit-env.yaml` on Linux hosts,
  `C:/ProgramData/fluent-bit-eh/secrets/fluentbit-env.yaml` on Windows); `${DD_API_KEY}`, `${FLB_FORWARD_SHARED_KEY}`,
  `${EVENTHUB_CONNECTION_STRING}` resolve from it. A missing file aborts start-up (fail closed).
- OTel gateway (`config/otel/gateway*.yaml`): `api.key: ${file:/dsv-secrets/dd-api-key}`, bearer token
  `${file:/dsv-secrets/otlp-bearer-token}` (no secret env vars). `modules/otel-collector`: output `secret_env_names`
  replaced by `secret_files` + `secrets_dir`.
- `modules/instrumentation`: input `telemetry` v2 shape; `key_vault_identity_id` -> `identity_client_id`; `env` /
  `app_settings` now include the DSV runtime env (`DSV_TENANT`, `DSV_TLD`, `DSV_BASE_URL`, `DSV_AUTH`,
  `AZURE_CLIENT_ID`) and secret settings whose VALUE is the `dsv://` reference (no `@Microsoft.KeyVault(...)`);
  `container_app_patch` gains `init_containers` (dsv-fetch, Consumption profile) and `refresher_containers`
  (Dedicated profiles), an EmptyDir `dsv-secrets`, and its `secrets` carry only the non-secret sidecar config files;
  `aci_sidecar` gains `fetcher` (dsv-fetch refresher container: ACI init containers cannot use managed identity) and
  has empty `secure_environment_variables`. New outputs `dsv_env`, `sidecar_secret_refs`, `fetch_args`.
- `modules/telemetry-transport`: `datadog.api_key_secret_id` -> `datadog.api_key_ref`; new `secrets` input; removed
  `key_vault`, `azurerm_key_vault_secret.fluentbit_listen`, the Key Vault role assignment and
  `event_hub.{listen_connection_string_secret_id, listen_secret_key_vault_id, listen_secret_name, listen_secret_version}`
  (-> `event_hub.listen_connection_string_ref`); `aggregator.forward_shared_key_ref`, `aggregator.forward_tls.{cert_ref,
  key_ref}`, `gateway.auth.{token_ref, client_headers_ref}`. Aggregator and gateway get dsv-fetch init containers
  (EmptyDir, collector identity, image pulled from `secrets.fetch_image`'s registry with that identity). New sensitive
  output `generated_secrets` (`eventhub-fluentbit-listen` = generated Listen connection string) for
  `tools/secrets/publish.py` (source repository) or your own DSV writer.
- `modules/host-agents`: no Datadog VM extension any more (resources `azurerm_virtual_machine_extension.datadog`,
  `azurerm_virtual_machine_scale_set_extension.datadog` and output `agent_extensions` removed). The installer (run
  command / CustomScript) installs the pinned Agent itself (Linux: official install script, `DD_INSTALL_ONLY`, with
  `datadog.yaml` `api_key: ENC[<dsv ref>]` + `secret_backend_command` = dsv-fetch `agent-backend`, owned by dd-agent,
  0500; Windows: pinned-SHA256 MSI, key read from DSV in PowerShell). Fluent Bit: `ExecStartPre` = dsv-fetch into the
  unit's tmpfs `RuntimeDirectory`. Inputs: `datadog.api_key_ref` (required), `secrets`, `dsv_fetch_source`,
  `windows_msi_sha256`, `setup_revision`; removed `api_key`, `datadog.{api_key_secret_id, api_key_key_vault,
  extension_version}`; `hosts[*].identity_client_id` is required.
- `modules/kubernetes`: `api_key.mode` `write_only` (and input `api_key_wo`) removed. Default `dsv_secret_backend`:
  `datadog.apiKey = ENC[<dsv ref>]`, `datadog.secretBackend` = `/opt/dsv-fetch/dsv-fetch agent-backend`
  (ConfigMap-mounted script, mode 0500) on Agents and cluster-checks runners, workload identity on the service accounts
  `datadog` and `datadog-cluster-checks` (dedicated), Fluent Bit DaemonSet with a dsv-fetch init container (in-memory
  emptyDir). Input `dsv` (`api_key_ref`, endpoint, `fetch_image`, `identity_client_id`). Mode `existing` = Secret
  maintained by the Delinea dsv-k8s syncer. `api_key.cluster_agent_secret_name` for the Cluster Agent (its image has
  no Python interpreter).
- `modules/dbm`: `password_ref.kind = key_vault` -> `dsv` (`name = dsv://...`, rendered `ENC[dsv://...]`); ACI host:
  `aci.{key_vault_uri, api_key_secret_name}` -> `aci.{api_key_ref, dsv}`; the Agent container installs dsv-fetch as its
  `secret_backend_command` at start (no `azure.keyvault` backend).
- `modules/azure-integration`: `app_registration.auth` default `secret` -> `secretless`.
- Pipeline templates: `AzureKeyVault@2` replaced by `templates/dsv-secrets.yml` (dsv-fetch on a self-hosted agent with
  a managed identity -> masked variables). Parameters `keyVaultName`, `datadogApiKeySecret`, `datadogAppKeySecret`
  -> `dsv`, `datadogApiKeyRef`, `datadogAppKeyRef`, `dsvFetchPath`.
- `modules/host-agents` Windows: pinned MSI SHA256 (the 1.x check downloaded a non-existent `.sha256` file).

### Added
- `images/dsv-fetch` (from the source repository's builder) is part of the package and referenced by
  `modules/{host-agents,kubernetes,dbm}` (embedded script) and by the container patterns (image `dsv-fetch`).

### Removed
- Every Key Vault resource, data source, reference and input.

## [1.1.0] - 2026-10-09

### Added
- Azure platform / control-plane logs to Datadog (guide `docs/guides/azure-logs-to-datadog.md` in the source repository):
  - `modules/azure-logs`: subscription Activity Log (subscription-scoped diagnostic setting per subscription, all 8
    categories configurable) and optional Microsoft Entra ID logs (`azurerm_monitor_aad_diagnostic_setting`,
    precondition-guarded by `entra.acknowledge_prerequisites`); exclusivity input `native_log_forwarding`.
  - `modules/diagnostic-settings`: maintained category policy `category-policy.json` (28 resource types, tiers
    `security` / `standard` / `verbose`, cost notes, Microsoft Learn page per type, `supersedes`), inputs
    `platform_log_tier`, `platform_log_allowlist_overrides`, `category_policy`, per-resource `tier`; outputs
    `platform_log_tiers`, `self_referencing_resources` (the destination Event Hubs namespace never streams into itself).
  - `modules/telemetry-transport`: `event_hub.activity_logs_hub` (default `activity-logs`, own consumer group; `""`
    shares the platform hub); contract field `event_hub.activity_logs_hub` (optional); aggregator env
    `FLB_EVENTHUB_APP_TOPIC`.
  - `modules/log-management`: "Azure platform logs" dashboard; opt-in log index (retention, daily quota, sampled
    exclusion filters), index order, Activity Log custom pipeline (preserve-source remappers), 8 log-based metrics,
    Azure archive.
  - `modules/azure-integration`: `eventhub_log_forwarding` (plan fails when native log forwarding duplicates the
    Event Hubs path), output `native_log_forwarding`.
  - Archetype profile `azure-platform-logs` (9 log monitors: deletes in protected resource groups, RBAC changes,
    diagnostic setting deleted, Policy deny spike, Service Health, Key Vault 401/403, AKS exec/port-forward/attach,
    Entra sign-in failures (opt-in), no Azure platform logs).
  - Fluent Bit aggregator (`lua/enterprise_hello.lua` `eh_azure_split`): Datadog Azure forwarder record shape
    (`ddsource` azure.<provider> / azure.subscription / azure.resourcegroup / azure.activedirectory, `service:azure`,
    `ddsourcecategory:azure`, tags `subscription_id`, `resource_group`, `tenant`, `resource_type`, `resource_name`,
    `region`, `category`, `azure_log_type`, `env`), `aks_audit.*` fields, redelivery dedup cache, 1 MB size guard,
    drop of application categories on non-app hubs; env `FLB_AZURE_SERVICE`, `FLB_AZURE_ENV_BY_SUBSCRIPTION`,
    `FLB_AZURE_MAX_RECORD_BYTES`, `FLB_AZURE_DEDUP_CACHE`.
- Archetype key `runbook_base_url` (global defaults; placeholders `[[service]]`, `[[env]]`, `[[team]]`,
  `[[repository]]`): default for `metadata.runbook_url`, which is now optional in `onboarding-manifest.v1`.
- `modules/telemetry-transport`: `event_hub.listen_secret_version` (write-only `value_wo_version` of the listen
  secret; increment to rotate). Previously hard-coded to 1.
- `modules/host-agents` Linux installer: runtime overrides `EH_IDENTITY_CLIENT_ID` / `EH_LOG_PATHS` (used by the lab's
  Azure Batch job preparation task). Rendered scripts change once (VM run commands / VMSS CustomScript re-run).

### Changed
- Azure **platform** log records: `service` is now `azure` (was the resource name) and `level` keeps Azure's casing;
  a JSON `properties.log` (kube-audit) is no longer copied into `message` / lifted to the top level. Application
  categories are unchanged.
- Redaction keeps Azure / Entra / Kubernetes metadata (token type/name/status/identifier/hash fields,
  `authorization.k8s.io/*`, claims `pwd_exp`/`pwd_url`, `{"key","value"}` labels).
- `modules/diagnostic-settings` default platform categories come from the `standard` tier (superset of the 1.0
  allow-list: adds e.g. AKS `kube-apiserver`, SQL `DevOpsOperationsAudit`, Service Bus `VNetAndIPFilteringLogs`,
  Event Hubs runtime/Kafka error logs, Redis `MSEntraAuthenticationAuditLog`, ACR repository events, Batch, Azure
  Firewall, NSG event logs); see UPGRADING.

## [1.0.0] - 2026-10-09

### Added
- Manifest-driven onboarding: `schemas/onboarding-manifest.v1.schema.json` (ServiceOnboarding), `archetype.v1`,
  `notification-routing.v1`.
- Archetypes: global defaults; platforms `aks` (+ARO), `aca`, `appservice`, `functions`, `vm` (+VMSS, SF managed),
  `aci`, `logicapp`; resources `database-sql`, `database-postgresql`, `database-mysql`, `database-cosmos`,
  `database-storage`, `messaging` (Service Bus, Event Hubs), `cache` (Managed Redis, Azure Cache for Redis);
  profiles `http-api`, `frontend`, `worker`, `durable-workflow`, `job`, `db-adapter`, `telemetry-pipeline`.
- `tools/onboarding/render.py` (deterministic merge + `--check`, `references`) and `validate.py` (schema + semantic).
- Terraform modules: `onboarding`, `monitors`, `slos` (metric + time-slice SLOs, multi-window burn-rate alerts),
  `synthetics` (API + browser, private locations, paused by default), `dashboards` (per service + application
  overview with journey, databases, queues/durable workflows and telemetry pipeline sections), `service-catalog`
  (entity v3), `rum`, `notification-routing`, `deployment-markers`.
- `tools/verify/telemetry_verify.py` (RUM -> APM -> logs correlation, duplicate detection, required tags,
  infrastructure metrics; bounded polling; JSON evidence), `tools/markers/send_deployment_event.py` (DORA API).
- `tools/release/package.sh` (deterministic tarball, sha256, portability gate).
- Azure DevOps templates (validate, plan, apply saved plan, telemetry verification, deployment markers).
- `examples/existing-environment` consumer root vendoring a versioned release.
