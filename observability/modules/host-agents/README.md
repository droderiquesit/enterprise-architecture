# modules/host-agents

Installs the Datadog Agent on VMs and VM scale sets, Linux and Windows (observability 4.0.0). It uses **Azure VM
Applications** and **Azure Policy**. There is no per-host Terraform: no run commands, no CustomScript extensions,
no `for_each` over hosts.

| Piece | Module | What it creates |
|---|---|---|
| Package | [`host-agent-package`](../host-agent-package/README.md) | Compute Gallery, VM Applications `datadog-agent-linux` / `datadog-agent-windows` (optional `-linux-arm64`), one immutable version per `package.version`, private package storage (managed identity, no SAS) |
| Enrolment (default `mode = "policy"`) | [`host-agent-policy`](../host-agent-policy/README.md) | DeployIfNotExists initiative on VMs / VMSS tagged `datadog:enabled = true`: attaches the per-environment **DSV-reader identity** and the **pinned version**; least-privilege custom role; remediation tasks |
| Escape hatch `mode = "direct"` | this module | for environments **without Azure Policy rights**: one `azurerm_virtual_machine_gallery_application_assignment` per VM in `hosts` (same application, same version). Scale sets have no assignment resource in azurerm, so `vmss_gallery_applications` gives each one's `gallery_application {version_id, order}` block for its platform root. In this mode the hosts must already carry the DSV-reader identity. |

## Why VM Applications instead of run command / CustomScript

* A scale set can carry only one CustomScript extension, which conflicts with application owners. VM Applications
  are separate entries in `applicationProfile`, up to 25 per VM, with an install `order`.
* Versions are immutable and promoted dev -> test -> prod by bumping the version per environment. One version of an
  application per VM; update and remove commands exist (Microsoft Learn,
  https://learn.microsoft.com/azure/virtual-machines/vm-applications).
* New VMSS instances get the application from the scale-set model, and new VMs get it from the policy.
* Packages come from Azure-managed replicas, so hosts need no access to the package storage.

## Secrets (ADR-0001 §14)

* `datadog.yaml` on every host holds `api_key: ENC[dsv://<prefix>/<env>/datadog-api-key#value]`.
* The **dsv-fetch static binary** (the VM Application package) is the Agent `secret_backend_command`
  (`agent-backend --config <dsv.json>`) on **Linux and Windows**:
  * Linux: owner `dd-agent`, mode 0500;
  * Windows: `dsv-fetch.exe`, ACL `ddagentuser` + Administrators + SYSTEM.
* The key is read from DSV at Agent start with the environment's DSV-reader user-assigned identity, through IMDS. It
  is never written to disk, `datadog.yaml`, the VM model, the gallery, the policy or Terraform state.
* `dsv.json` holds only non-secret settings (tenant, base URL, auth, identity client id).

### Accepted risk: the DSV-reader identity on the host

Every process on an enrolled VM can request a token for the attached user-assigned identity from IMDS, and could
therefore read what that identity can read in DSV. This is accepted because:

* the identity (`foundation-identity` `identities["obs-host-agent"]`, one per environment) is mapped by
  `foundation-secrets` to one DSV policy with `read` on **exactly** `/<prefix>/<env>/datadog-api-key`;
* that key is an **ingest-only** Datadog API key: it can submit telemetry, but it cannot read data or change the
  org (it is not an application key);
* a process that can already run on the host can already send telemetry through the local Agent (DogStatsD, OTLP,
  APM on localhost).

Mitigations:

* rotate the key in DSV; the Agent reloads it on restart (`secret_refresh_interval` is not used);
* review Datadog Audit Trail for API key usage;
* keep the identity out of every other DSV policy and RBAC role.

The same identity on every host of an environment is a deliberate choice: one DSV user per environment instead of
one per host, which per-host Terraform would need.

## Logs: the Agent collects on Linux and Windows (no Fluent Bit)

* Files: `host_logs.linux.files` / `host_logs.windows.files` (the fleet policy `logs.hosts.*` wins when present),
  plus the `datadog:log_paths` tag of the instance. `service` comes from the instance's `service` tag, `source` from
  the entry, the `datadog:source` tag or the per-OS default.
* Windows Event Log: `host_logs.windows.event_channels` (default `System`, `Application`; add `Security` if
  needed) as `type: windows_event`.
* Destination: the Observability Pipelines Worker (`observability_pipelines_worker.logs.url`) in
  `observability_pipelines` mode, otherwise the Datadog intake. With `log_pipeline = fluent_bit_direct` hosts still
  use the Agent; Fluent Bit is not installed on VMs in 4.0.
* Migration from 3.x: the setup script disables and removes the 3.x `fluent-bit-eh` service, the 3.x
  `eh-observability.conf` drop-ins (Linux) or Machine `DD_*` variables (Windows) that would override
  `datadog.yaml`, and the old `eh-applogs.d` config. This keeps one collector per log line.

## Traces and metrics

* OTLP receiver on `localhost:4317/4318` (OTLP logs off).
* Single Step Instrumentation on Linux when `apm.mode = datadog`. Windows services stay on OpenTelemetry, because
  Windows SSI covers IIS only.
* DogStatsD on `localhost:8125`.
* `apm_config.ignore_resources` from the fleet policy.

## Fleet management

* The Agent version is the fleet policy `agent.version` (the single pin, `versions.yaml`). It has no fallback in
  code. Bumping it changes the installer, which needs a new `package.version`; the plan says so.
* Remote Configuration is on. Remote updates are **off** (`remote_updates: false`); Fleet Automation is used for
  inventory only.
* Tags come from the instance's Azure tags (tag policy `azure_tag_keys` -> Datadog keys) at install / update time.
  The Datadog Azure integration also puts Azure resource tags on the host's metrics.

## Golden image (optional)

The VM Application is the supported path. To pre-bake the Agent into an image, for example to cut first-boot time or
for air-gapped builds:

1. Put `output.installers["linux"]` (or `["windows"]`) and the matching dsv-fetch release binary into a directory
   of the image build.
2. Run `bash ./datadog-agent-setup.sh install` (or `-Action install`) there.

The image then carries the pinned Agent and dsv-fetch, and no key. Keep the VMs tagged: the policy still attaches the
DSV-reader identity and the application. Install is idempotent, so the Agent is not reinstalled when the versions
match. Rebuild images when `package.version` changes, or let the application update them.

## Inputs

* `mode`, `env`.
* `package {resource_group_id, location, names, version, retained_versions, applications, dsv_fetch_release_dir,
  replica_regions, publisher_principal_ids, network, agent_msi_sha256}`.
* `datadog {site, api_key_ref}`, `dsv {tenant, tld, base_url, auth}`, `agent_identity {id, client_id}`.
* `policy {name_prefix, scope {type, id, not_scopes}, identity_resource_group_name, enrollment_tag, arch_tag_name,
  effect, targets, application_order, remediation, extra_role_actions}`.
* `hosts` (direct mode).
* `fleet_policy`, `tag_policy`, `extra_tags`, `log_pipeline`, `op_agent_logs_url`, `host_logs`, `default_service`,
  `metadata_tag_prefix`, `tags`.

Outputs: `mode`, `gallery`, `applications`, `agent_version`, `enrollment_tag`, `policy`, `assignments`,
`vmss_gallery_applications`, `installers`, `otlp_endpoint`.

## Platform owners

* Set the tag `datadog:enabled = "true"` on the VMs and VMSS that should run the Agent. The instance tags `env`,
  `service`, `team`, `owner`, ... become Datadog tags.
* On `azurerm_*_virtual_machine` / `*_virtual_machine_scale_set`, set
  `lifecycle { ignore_changes = [gallery_application] }`, because the policy owns that entry. Either add the
  DSV-reader identity (foundation-identity `obs-host-agent`) to `identity.identity_ids` or ignore `identity`, so
  that the next platform apply does not remove what the policy attached.
* VMSS: an `Automatic` or `Rolling` upgrade policy rolls the model change out. With `Manual` the change applies on
  instance upgrade or reimage.

## Tests

* `tests/hosts.tftest.hcl` (mock providers): policy mode by default; direct mode (VM assignments, VMSS blocks);
  arm64 without an arm64 application; resource-id / kind validation; literal API key.
* The package and policy modules have their own tests (installer execution in ubuntu:24.04 and pwsh, policy rule and
  RBAC).

Status: implemented (static validation, mock-provider tests, local installer runs). Not deployed or verified live.
