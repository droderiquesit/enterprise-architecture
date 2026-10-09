# Changelog

All notable changes to the observability package. Format: Keep a Changelog; versioning: SemVer (see README section 7).

## [Unreleased]

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
