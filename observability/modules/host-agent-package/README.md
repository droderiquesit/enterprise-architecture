# modules/host-agent-package

Publishes the Datadog Agent for VMs and VM scale sets as **Azure VM Applications** in an Azure Compute Gallery.
There is one application per OS:

| Application | Package file (`mediaLink`, `packageFileName`) | Configuration file (`defaultConfigurationLink`, `configFileName`) |
|---|---|---|
| `datadog-agent-linux` (amd64) | `dsv-fetch` = release file `dsv-fetch-linux-amd64` | `datadog-agent-setup.sh` (rendered `scripts/linux-setup.sh.tftpl`) |
| `datadog-agent-linux-arm64` (optional key `linux_arm64`) | `dsv-fetch` = `dsv-fetch-linux-arm64` | same script |
| `datadog-agent-windows` | `dsv-fetch.exe` = `dsv-fetch-windows-amd64.exe` | `datadog-agent-setup.ps1` (rendered `scripts/windows-setup.ps1.tftpl`) |

The commands are `bash ./datadog-agent-setup.sh install|update|remove` and
`powershell.exe -File .\datadog-agent-setup.ps1 -Action install|update|remove`. They run in the download directory,
where the package and the configuration file sit. Which hosts get the application is decided by
[`host-agent-policy`](../host-agent-policy/README.md) (Azure Policy) or by `modules/host-agents` `mode = "direct"`.

## What the setup script does (Linux and Windows, idempotent)

1. Checks the `dsv-fetch` binary against the SHA256 from the release `SHA256SUMS`. Terraform checks it at plan time;
   the host checks it again before installing.
2. Reads the instance's Azure tags from IMDS (`compute/tags`, `compute/tagsList`). The tag policy `azure_tag_keys`
   map them to Datadog keys:
   * `env` becomes the Agent `env`;
   * `service` becomes the log `service` (never a host tag);
   * `team`, `owner`, `application`, `domain`, `tier`, `region` and the other policy keys become Agent host `tags`;
   * the policy static tags fill keys the instance does not carry.

   The host can also set `datadog:log_paths` (extra log files, comma-separated absolute paths) and `datadog:source`.
3. Writes `datadog.yaml`:
   * `api_key: ENC[dsv://<prefix>/<env>/datadog-api-key#value]`;
   * `secret_backend_command` = the dsv-fetch binary, with `secret_backend_arguments: [agent-backend, --config, <dsv.json>]`;
   * `site`, `env`, `tags`;
   * `logs_enabled: true` and `observability_pipelines_worker.logs.url` (Observability Pipelines mode);
   * the OTLP receiver on `localhost:4317/4318` (OTLP logs off);
   * `apm_config.ignore_resources`;
   * `process_config`, `remote_configuration.enabled` (on) and `remote_updates: false` (fleet policy).

   `dsv.json` holds only non-secret DSV settings and the client id of the environment's DSV-reader identity.
4. Agent log collection (the Agent collects, with no Fluent Bit), in `conf.d/eh-host-logs.d/conf.yaml`:
   * the policy files from `host_logs` (or the fleet policy `logs.hosts.*` when present);
   * the files from the `datadog:log_paths` tag;
   * on Windows, `type: windows_event` for each `event_channels` entry (default `System` and `Application`).
5. Installs the pinned Agent (`agent.version` of the fleet policy, the single pin in `versions.yaml`):
   * **Linux**: the official install script with `DD_INSTALL_ONLY=true` and `DD_AGENT_MINOR_VERSION`. It keeps the
     `datadog.yaml` written in step 3, so no API key is needed. Single Step Instrumentation
     (`DD_APM_INSTRUMENTATION_ENABLED=host`) is added when `apm.mode = datadog`. `DD_REMOTE_UPDATES` is set only when
     the fleet policy turns remote updates on.
   * **Windows**: the pinned MSI, checked against `agent_msi_sha256`, installed without `APIKEY`.
6. Installs the secret backend with `dsv-fetch install --dest <path> --owner <agent user>`:
   * Linux: `/opt/datadog-dsv/dsv-fetch`, mode 0500, owner `dd-agent`;
   * Windows: `C:\Program Files\Datadog\dsv-fetch\dsv-fetch.exe`, restricted ACL (`ddagentuser`, Administrators, SYSTEM).

   This follows the Datadog secrets-management requirements for `secret_backend_command`.
7. Keeps the Agent retrying while the identity is not attached yet or DSV cannot be reached:
   * Linux: a systemd drop-in with `Restart=always`, `RestartSec=30` and `StartLimitIntervalSec=0`;
   * Windows: `sc.exe failure` restart actions.

   It restarts the Agent only on change.

`remove` uninstalls the Agent (and SSI where present) and deletes dsv-fetch and its configuration.

## Immutability, versions and promotion

Azure does not allow changes to a published version's package, configuration link, commands or file names. The
module therefore follows these rules:

* `package_version` is the version this apply publishes. `retained_versions` keeps older ones as rollback targets
  and for instances still on them. Retained versions are frozen (`ignore_changes`) and are never re-published.
* A `terraform_data` record keeps the content hash of each published version. If the installer, the binary or the
  commands change while `package_version` stays the same, the plan fails with "bump package_version".
* `exclude_from_latest = true`: nothing uses `latest`. Each environment pins its version through the policy
  assignment. Promotion means bumping `package_version` in `environments/<env>/environment.yaml`, in the order
  dev -> test -> prod.
* Blob names contain the content hash. The gallery keeps its own replicas, so old blobs may go: Microsoft Learn says
  the source blob can be deleted after replication. A later *update* of such a version would need the blob again.

## Package storage: no SAS

* The storage account has `shared_access_key_enabled = false`, no anonymous access and network default `Deny`
  (bypass `AzureServices`). The container is private.
* The gallery has a **user-assigned identity** with *Storage Blob Data Contributor* on the container. This is the
  role Microsoft Learn names; the module scopes it to the one container. The versions use **plain blob URLs**.
  Microsoft Learn: "SAS URL - the SAS token is stored as plain text in the application version resource"; with a
  managed identity the gallery reads private, network-restricted storage as a trusted service.
* azurerm 5.9 cannot set the gallery identity. The gallery is therefore an `azapi_resource`
  `Microsoft.Compute/galleries@2025-12-03` (`catalog/provider-gaps.yaml`, service `vm-applications`). Applications
  and versions stay on azurerm.
* Terraform uploads the blobs with Entra ID (`storage_use_azuread = true`). `publisher_principal_ids` grants the
  apply identity *Storage Blob Data Contributor* on the container. Self-hosted agents reach the account through
  `network.ip_rules` / `subnet_ids`.
* The VM itself downloads from Azure-managed replicas. It has no storage access and no SAS.

Nothing in the package is secret: the API key reference, the DSV endpoint and the identity client id are not secrets
(ADR-0001 §14). The tests assert that no `sig=` / SAS, no `DD_API_KEY=` and no Key Vault appear.

## Inputs (main)

* `resource_group_id`, `location`, `names {gallery, storage_account, publisher_identity, container}`.
* `package_version`, `retained_versions`, `applications` (`linux`, `windows`, `linux_arm64`).
* `dsv_fetch_release_dir`: the staged release files `dsv-fetch-linux-amd64`, `dsv-fetch-linux-arm64`,
  `dsv-fetch-windows-amd64.exe` and `SHA256SUMS`. The plan fails when a file is missing or does not match.
* `datadog {site, api_key_ref}`, `dsv {tenant, tld, base_url, auth, identity_client_id}`, `env`.
* `fleet_policy`, `tag_policy`, `extra_tags`, `log_pipeline`, `op_agent_logs_url` (required in
  `observability_pipelines` mode).
* `host_logs`, `default_service`, `default_source`, `metadata_tag_prefix` (`datadog:`).
* `agent_msi_sha256` (per Agent version), `replica_regions`, `publisher_principal_ids`, `network`, `tags`.

Outputs: `gallery`, `applications` (`id`, `version`, `version_id`, composed and therefore known at plan), `versions`,
`agent_version`, `content_sha256`, `installers` (for golden images), `otlp_endpoint`, `storage`.

## Tests

* `tests/package.tftest.hcl` (mock providers): the content assertions above, plus:
  * `fluent_bit_direct`;
  * a missing Worker URL;
  * a tampered or missing release;
  * a literal key;
  * arm64 and retained versions;
  * the immutability guard (publish, change the content without a bump, then bump).
* `tests/test_installers.py` (pytest):
  * renders both scripts and checks them for secret material;
  * runs `bash -n` and shellcheck on the Linux script;
  * runs the Linux script twice in `ubuntu:24.04` without network (stubbed IMDS, install script and systemd; fake
    dsv-fetch fixture) and checks `datadog.yaml`, the log config, permissions, idempotency, the checksum guard and
    `remove`;
  * runs the PowerShell parser on the Windows script and executes its configuration part under `pwsh`, checking the
    rendered `datadog.yaml` and the Event Log config. This is not executed on Windows.

## References (Microsoft Learn, checked 2026-10-10)

* VM Applications overview: limits, `packageFileName` / `configFileName`, download directory, `order`, update
  semantics, `treatFailureAsDeploymentFailure`, deleting the SAS after replication:
  https://learn.microsoft.com/azure/virtual-machines/vm-applications
* Create and deploy: install / remove commands are strings of at most 4,096 characters, run in the download
  directory, and deploy with a PUT of `applicationProfile` on the VM / VMSS:
  https://learn.microsoft.com/azure/virtual-machines/vm-applications-how-to
* Publish with a managed identity: plain blob URLs, Storage Blob Data Contributor, trusted service, works only for
  publishing: https://learn.microsoft.com/azure/virtual-machines/vm-applications-publish-with-managed-identity
* Gallery ARM schema (identity in 2025-12-03): https://learn.microsoft.com/azure/templates/microsoft.compute/galleries
* Datadog: secrets management (`secret_backend_command` permissions on Linux and Windows):
  https://docs.datadoghq.com/agent/configuration/secrets-management/
* Datadog: OTLP ingest in the Agent: https://docs.datadoghq.com/opentelemetry/setup/otlp_ingest_in_the_agent/
* Datadog: Windows Event Log collection (`type: windows_event`, `channel_path`):
  https://docs.datadoghq.com/integrations/win32_event_log/
