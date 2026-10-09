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

### 2.0.0 (from 1.x) - MAJOR: Key Vault -> Delinea DSV
Secrets move from Azure Key Vault to Delinea DevOps Secrets Vault. Nothing secret passes through Terraform any more.

1. **Put the secrets into DSV** (operators: `dsv secret create --path <base>/<name> --data '{"value":"..."}'`):
   `datadog-api-key`, `datadog-app-key` (pipelines), `fluentbit-shared-key`, `eventhub-fluentbit-listen` (written after
   the first 2.0 apply from the sensitive output `generated_secrets`), optional `otlp-bearer-token` / `otlp-headers`,
   DBM passwords. Create a DSV Azure auth provider and one DSV user per managed identity (`external-id` = identity
   resource id) with read on exactly its paths: collectors (aggregator/gateway, Agents, Fluent Bit), every app identity,
   host identities, the self-hosted pipeline agent identity.
2. **Contract**: consumers of `obs-telemetry-transport` must move to v2 (field renames + `secrets` block, see
   CHANGELOG). Publish v2 before switching consumers.
3. **Inputs** (rename / replace):
   | 1.x | 2.0 |
   |---|---|
   | `telemetry-transport.datadog.api_key_secret_id` | `datadog.api_key_ref` + `secrets {tenant, tld, base_url, fetch_image}` |
   | `telemetry-transport.key_vault`, `event_hub.listen_*` | removed; `event_hub.listen_connection_string_ref` |
   | `aggregator.forward_shared_key_secret_id`, `forward_tls.{cert,key}_secret_id` | `forward_shared_key_ref`, `forward_tls.{cert,key}_ref` |
   | `gateway.auth.{token_secret_id, client_headers_secret_id}` | `gateway.auth.{token_ref, client_headers_ref}` |
   | `instrumentation.key_vault_identity_id` | `identity_client_id` (+ `telemetry` v2) |
   | `host-agents.api_key`, `datadog.{api_key_key_vault, api_key_secret_id, extension_version}` | `datadog.api_key_ref`, `secrets`; `hosts[*].identity_client_id` required |
   | `kubernetes.api_key = {mode = "write_only"}`, `api_key_wo` | `api_key.mode = "dsv_secret_backend"` (default) + `dsv {...}`, or `existing` (dsv-k8s syncer) |
   | `dbm.password_ref.kind = "key_vault"`, `aci.{key_vault_uri, api_key_secret_name}` | `kind = "dsv"` + `name = "dsv://..."`, `aci.{api_key_ref, dsv}` |
   | pipeline `keyVaultName` / `datadog*KeySecret` | `dsv`, `datadogApiKeyRef`, `datadogAppKeyRef`, `dsvFetchPath`; self-hosted pool with a managed identity |
4. **Expected plan diffs** (review before applying):
   - destroyed: `azurerm_key_vault_secret.fluentbit_listen`, `azurerm_role_assignment.kv_secrets_user`, the Datadog VM /
     VMSS extensions (**removing the extension uninstalls the Agent**: after the apply, bump `host-agents.setup_revision`
     and apply again so the run command / CustomScript re-installs the pinned Agent with the DSV secret backend),
     `kubernetes_secret_v1.api_key` (both namespaces);
   - updated in place: aggregator / gateway Container Apps (new revision with dsv-fetch init containers and EmptyDir;
     Container Apps secrets now hold only config files), app Container Apps / ACI groups using the instrumentation patch,
     Helm releases (Datadog: `apiKey: ENC[...]` + secret backend; Fluent Bit: init container, no `DD_API_KEY` env),
     VM run commands / VMSS CustomScript (new installer).
   - **ACA init containers need the Consumption profile of a workload-profiles environment** (Microsoft Learn: no
     managed identity for init containers in consumption-only environments or on Dedicated profiles). The package
     falls back to a refresher container on Dedicated profiles (`refresher_containers`).
5. **AKS workload identity**: federate the collector identity with `datadog/datadog`, `datadog/datadog-cluster-checks`
   and `fluent-bit/fluent-bit` (the lab root `obs-kubernetes` does it). That DSV accepts AKS workload-identity tokens is
   **not verified**; if it does not, use `api_key.mode = "existing"` with the Delinea dsv-k8s syncer.
6. **State hygiene**: after 2.0 the Datadog API key is no longer in Terraform state. Rotate the API key once (1.x states
   may contain it as a protected setting / data-source value) and purge old state versions per your retention policy.

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
