# Upgrading the observability package

## General procedure (any version)

1. Read the target version's section below and the `CHANGELOG.md`.
2. Update `package.lock.json` (`version`, `sha256`, `url`) or the `?ref=observability-v<version>` of git sources,
   and the `@obs` repository `ref` of the pipeline templates. Keep both on the same version.
3. `./vendor.sh` (checksum verified), then re-render every environment:
   `python3 .vendor/observability-<v>/tools/onboarding/render.py render --manifests manifests --env <env> --out rendered/<env>`.
   Review the diff of `rendered/` - it is the exact change set of tags and telemetry routing.
4. `terraform init -upgrade` (only if the provider constraint changed), `terraform plan -out tfplan`.
   The plan template prints `DESTROY: [...]`. For MINOR/PATCH upgrades this must list no monitored
   infrastructure (the package never manages it) and no collection resource that still exists in the new version.
5. Apply the saved plan. Rollback = previous lock + re-render + apply (README section 5).

## Version-specific notes

### 4.0.0 (from 3.x) - MAJOR: Datadog Agent deployment v4

Nothing in this release was deployed or verified live; plan carefully and roll out per environment.

1. **dsv-fetch 2.x (static binary) is required.** Build/promote `img-dsv-fetch` 2.0.0 (image + release zip) first.
   - Every `fetch_image` input must be the digest-pinned 2.x image (the 1.x image ran Python; 2.x has no shell and
     no interpreter). Refresher containers use `init ... --refresh-seconds 3600` (there is no `--refresh`).
   - Pipeline templates: replace `dsvFetchPath` by `dsvFetch: {package_url, package_sha256}` (the release zip; the
     agent identity needs read on it, or `auth: none` for a SAS / mirror URL). Agents need `curl`, `unzip`, `sha256sum`.
   - `modules/telemetry-transport`: remove `dsv_fetch_source`.
2. **Kubernetes (`modules/kubernetes`)**:
   - Remove `api_key` (incl. `mode = existing` and the synced Secret), `cluster_agent_secret_name`, `resources`,
     `cluster_check_env`, `charts.agent_tag` and `op_worker.api_key_secret_name`. Sizing / tolerations / extra env move
     to `values_overrides` (YAML documents, applied last; the secret path cannot be overridden).
   - `op_worker.secret_env`: `NAME = "dsv://<path>#<element>"` instead of `{secret_name, key}`; the Worker's dsv-fetch
     init container reads them (delete the dsv-k8s syncer Secrets afterwards).
   - `dsv.identity_client_id` is required and `dsv.fetch_image` must be digest-pinned. **Federate** that identity with
     `datadog/datadog`, `datadog/datadog-cluster-agent`, `datadog/datadog-cluster-checks` (or set
     `dsv.cluster_checks_identity_client_id`, e.g. the DBM identity) and, with the Worker on the cluster,
     `<op_worker.namespace>/opw-observability-pipelines-worker`.
   - The deploy agent running `terraform apply` needs `/bin/sh` and `awk` (Helm post-renderer).
   - The Agent image tag comes only from the fleet policy `agent.version`.
   - Expected plan: in-place update of the `datadog` release (new init container, env, volumes); the Cluster Agent
     now authenticates with the API key through dsv-fetch.
3. **VMs / VMSS** (`modules/host-agents`): the run-command / CustomScript path is gone.
   - Default `mode = policy`: inputs `package` (gallery, storage, publisher identity, `version`,
     `dsv_fetch_release_dir` with the unzipped, sha256-verified release), `agent_identity` (per-environment DSV-reader
     identity: read on the API key path only), `policy.scope` (subscription or management group).
   - Tag hosts `datadog:enabled = "true"`. In the hosts' own roots: `lifecycle { ignore_changes = [gallery_application] }`
     and keep the DSV-reader identity in `identity_ids` (or ignore `identity`) - ADR-0001 §3 rule 3 as amended.
   - The apply identity needs Resource Policy Contributor, role-assignment rights (Managed Identity Operator + the
     custom remediation role) and role-definition write at the scope; the publisher identity / apply identity
     upload the packages with Entra ID (`publisher_principal_ids`).
   - Bump `package_version` for every change (Agent pin, installer, dsv-fetch release) and promote the same value
     dev -> test -> prod. Without Azure Policy rights: `mode = direct` (one gallery application assignment per VM).
   - Expected plan: the old run commands / extensions and the Fluent Bit host service are **destroyed**; the policy
     (re)installs the Agent via the VM Application (Linux and Windows; the Agent now collects the logs). VMSS with a
     Manual upgrade policy get it on the next instance update.
4. **ACI / Container Apps** (`modules/instrumentation`): ACI gets a Datadog Agent sidecar and Container Apps a
   serverless-init sidecar that collects logs; the Fluent Bit sidecars are removed (fallback only with
   `log_pipeline = fluent_bit_direct`). App deployment roots must pass the patch's `command` of the sidecars and the
   transport contract's `aggregator` (Worker URL).
5. **DBM**: with a cluster the checks run as cluster checks (`modules/dbm` `hosting = cluster_checks`); keep the ACI
   Agent only without one. Password references must be DSV (`password_ref.kind = dsv`).
6. **Fleet policy**: `logs.collector` per architecture replaces the global switch (`logs.node_collector` is still
   honoured on aks; VM / VMSS hosts always use the Agent); host log files and Windows Event Log channels are
   `logs.hosts`. RUM `rum.propagator_types` defaults to `[tracecontext]` (was `[datadog, tracecontext]`): the
   first-party APIs receive only `traceparent` from the browser.
7. **Contracts**: consumers of `obs-kubernetes` read **v2** (`agent.logs_enabled` is true when the Agent collects).
8. **Fleet inventory** (`modules/fleet-inventory` `plan` / `matrix`): values follow 4.0.0 (`serverless_init`,
   `datadog_agent_sidecar`, `agent_sidecar`, `datadog_agent_vm_application`); update reports that matched the 3.x
   values (`fluent_bit_sidecar`, `datadog_agent_installer`).
9. `modules/instrumentation`: drop `serverless_init.api_key_secret_name` (removed; it was ignored).


### 3.0.0 (from 2.x) - MAJOR: collection + tagging package; monitoring content moves out

**What the package now is.** It connects resources to Datadog and makes the tags consistent. It no longer manages
monitors, SLOs, dashboards, synthetics, catalog entities or notification routing.

1. **Keep your monitoring content alive before you upgrade.** Monitors and SLOs created by 2.x are in your Terraform
   state. Pick one option:
   - (a) Keep managing them with the 2.0.0 content modules from `extras/content/` of the source repository. They are
     unchanged; vendor them next to the 3.0.0 package and point the module sources there, so their state addresses
     stay the same.
   - (b) Hand them over to the team that owns alerting: `terraform state rm 'module.onboarding'` (no destroy), then
     import them in their root.

   Do not simply delete `module "onboarding"`. The plan would destroy every monitor.
2. **Adopt the tag policy from your monitors.** Run `tools/tags/derive_from_monitors.py` (read-only, DD_API_KEY /
   DD_APP_KEY from DSV). It proposes `config/tag-policy.yaml` keys, aliases and value maps your existing monitors and
   SLOs already filter on. Review the proposal, commit it as your policy, and pass it with `--tag-policy` / `tag_policy`.
   Then run `tools/tags/check_coverage.py` to see which monitored scopes lack which tags in live data.
3. **Migrate manifests to v2:** `python3 tools/onboarding/migrate_v1.py --in manifests/<env> --out manifests-v2/<env> --region <azure-region>`.
   It keeps identity, resources and telemetry routing and drops monitors, notifications, catalog, SLOs and
   endpoints. Add the now-required tags (`application`, `domain`, `tier`, `region`; `owner` and `team` as before).
   Validate with `--strict` and re-render. v1 manifests are rejected with a migration hint.
4. **Choose the collection paths** (`config/fleet-policy.yaml`, overridable per environment / architecture):
   - `log_pipeline: observability_pipelines` (default) needs the Worker. Use `modules/telemetry-transport` on Container
     Apps or `modules/kubernetes` `op_worker` on AKS. The transport root now needs the **datadog provider**
     (`DD_API_KEY` / `DD_APP_KEY` in the pipeline). With `fluent_bit_direct` everything stays as in 2.x.
   - `apm.mode: datadog` (default) needs Datadog libraries in managed-runtime images (`app_requirements` output of
     `modules/instrumentation`). AKS and Linux hosts get SSI. Your apps must read `TELEMETRY_SDK` and never start the
     OpenTelemetry SDK next to the Datadog tracer. Set `apm.mode: otel` (per environment or per workload) until they
     do.
   - Profiling is on wherever supported. Turn it off with `profiling.enabled: false`.
5. **Agents:** on AKS and Linux hosts the Datadog Agent now collects the application logs (the Fluent Bit DaemonSet
   and host service are removed by the plan). That is expected; the logs move to the Agent, with no gap beyond
   the restart. `logs.node_collector: fluent_bit` keeps Fluent Bit.
6. **RUM:** `modules/rum` takes `applications.<k>.mode = existing` with `application_id` + `client_token` to adopt the
   RUM application created by 2.x without recreating it. Alternatively `terraform state mv` it into the new module
   address.
7. **Pipelines:** `validate-onboarding.yml` ignores `routingFile` / `archetypesDir` (a warning is printed). Pass
   `tagPolicy` for your own policy.

Plan review for 3.0.0:

* **Expected destroys:**
  * the Fluent Bit aggregator Container App (OP mode);
  * the Fluent Bit DaemonSet / host services where the Agent takes over;
  * the 2.x content objects, if you did not keep them (step 1).
* **Not expected:** any destroy of monitored infrastructure (the package never manages it).

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

* The rendered schema (`rendered-service/v2`, `schemas/rendered-service.v2.schema.json`) and the manifest
  `apiVersion` (`observability/v2`) are public interfaces; a new rendered schema or manifest version is a MAJOR change.
  New optional manifest fields may be added in MINOR releases.
* Module inputs / outputs and the fleet / tag policy schemas follow README section 6 (versioning policy).
* The optional 2.x monitoring content (`extras/content/`, monitor keys `<service>/<monitor_key>[@role]`, manifest
  `observability/v1`, `rendered-service/v1`) keeps its own 2.0.0 promises; renaming a monitor key there recreates the
  monitor (history and mute state are lost).
