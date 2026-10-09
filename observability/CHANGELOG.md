# Changelog

All notable changes to the observability package. Format: Keep a Changelog; versioning: SemVer (see README section 7).

## [Unreleased]

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
