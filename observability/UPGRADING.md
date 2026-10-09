# Upgrading the observability package

## General procedure (any version)

1. Read the target version's section below and the `CHANGELOG.md`.
2. Update `package.lock.json` (`version`, `sha256`, `url`) or the `?ref=observability-v<version>` of git sources,
   and the `@obs` repository `ref` of the pipeline templates. Keep both on the same version.
3. `./vendor.sh` (checksum verified), then re-render every environment:
   `python3 .vendor/observability-<v>/tools/onboarding/render.py render --manifests manifests --env <env> --out rendered/<env>`.
   Review the diff of `rendered/` - it is the exact change set of monitoring content.
4. `terraform init -upgrade` (only if the provider constraint changed), `terraform plan -out tfplan`.
   The plan template prints `DESTROY: [...]`. For MINOR/PATCH upgrades this must list no monitored
   infrastructure (the package never manages it) and no monitor whose key still exists.
5. Apply the saved plan. Rollback = previous lock + re-render + apply (README section 5).

## Version-specific notes

### 1.1.0 (from 1.0.x)
MINOR: new modules and optional inputs; no monitor key renamed, no rendered schema change. Expect these plan diffs:

1. **Diagnostic settings** (`modules/diagnostic-settings`): when you did NOT pass `platform_log_allowlist`, the
   categories now come from `category-policy.json` at `platform_log_tier = "standard"`. Existing
   `<prefix>-platform-logs` settings are **updated in place** and gain categories (e.g. AKS `kube-apiserver`, SQL
   `DevOpsOperationsAudit`). Log volume, and therefore cost, rises accordingly. To keep 1.0 behaviour exactly, pass
   your 1.0 allow-list as `platform_log_allowlist` (it replaces the policy) or choose `platform_log_tier = "security"`.
   Resources of newly covered types (Batch, Azure Firewall, NSG, Managed Redis databases, Cosmos vCore, Storage
   table/queue/file) get a **new** setting where they previously had none. If you pass the destination Event Hubs
   namespace itself as a resource, its setting is now skipped (`self_referencing_resources`).
2. **Event hubs** (`modules/telemetry-transport`, `event_hub.mode = create`): a third hub `activity-logs` and its
   consumer group are **created**, and the aggregator's `EVENTHUB_TOPICS` gains it (new Container App revision). To
   avoid the new hub, set `event_hub.activity_logs_hub = ""`. With `mode = existing`, create the hub and consumer
   group yourself or set `""`.
3. **Activity Log / Entra**: nothing is created until you add `modules/azure-logs`. The lab root `obs-diagnostics`
   now exports the Activity Log of the environment subscription by default (`settings.activity_log.enabled`). Entra
   stays off. If the Azure Native integration already forwards subscription logs for that subscription, the plan
   **fails** by design: disable one path.
4. **Datadog records** (aggregator Lua, delivered by `telemetry-transport` as a Container App secret, so a new
   revision is rolled): platform logs now arrive with `service:azure` (was the resource name) and new tags. Update
   saved views, monitors or log-based metrics that filtered Azure platform logs on `service:<resource-name>`; use
   `resource_name:<name>` instead. Application logs (`azure_log_type:application`) are unchanged.
5. **Monitors**: new profile `azure-platform-logs`. Nothing changes unless you onboard a manifest with it. Its log
   monitors are multi-alert (`by(...)`) except `azlogs.logs_missing` (`new_group_delay: 0`).
6. **Datadog log management**: `modules/log-management` is new. Index, index order, pipeline and archive are opt-in.
   Read its README before enabling the index (index order).
7. The consumer example (`examples/existing-environment`) gained `azure_logs` / `log_management` variables and the
   manifest `azure-platform-logs`. Re-render `rendered/<env>`.

### 1.0.0
Initial release. No migration.

## Compatibility promises

* Monitor keys (`<service>/<monitor_key>[@role]`) are part of the public interface; renaming one is a MAJOR change
  because it recreates the monitor (history and mute state are lost).
* `rendered-service/v1` is consumed by `modules/onboarding`; a new rendered schema is a MAJOR change and the
  previous major is accepted for one release.
* Manifest `apiVersion: observability/v1` stays valid for every 1.x release; new optional fields may be added.
