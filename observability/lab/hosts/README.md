# lab/hosts (component `obs-hosts`)

**Owner:** observability.

**Purpose:** puts the Datadog Agent on the lab VMs and VMSS, Linux and Windows, through
[`modules/host-agents`](../../modules/host-agents/README.md) (observability 4.0.0). It publishes the VM Applications
`datadog-agent-linux` / `datadog-agent-windows` in this environment's Compute Gallery. An **Azure Policy**
initiative, assigned at the subscription by default, enrols every VM / VMSS tagged `datadog:enabled = true`. There is
no per-host Terraform and no run command or CustomScript.

## Contracts

* **Consumes:**
  * `obs_telemetry_transport`: `datadog_site`, `api_key_ref`, `secrets.{tenant, tld, base_url}`,
    `aggregator.{kind, agent_logs_url}` and `env.fleet`.
  * `foundation_identity` v2: `identities["obs-host-agent"].{id, client_id}`, the per-environment DSV-reader identity
    that the policy attaches to every enrolled host.
  * Artifact `img-dsv-fetch` (zip-package): the dsv-fetch release files are the VM Application packages.
* **Optional (`settings.mode = direct` only):**
  * `platform_vm.vms[*].{id, os_type}`;
  * `platform_vmss.scale_sets[*].{id, os_type}`;
  * `platform_db_sqlvm.vm.id`.

  In policy mode these contracts are not read: hosts are enrolled by tag.
* **Produces:** no contract. Outputs: `mode`, `enrollment_tag`, `applications` (pinned version), `agent_version`,
  `policy`, `assignments`, `vmss_gallery_applications`, `otlp_endpoint`, `host_log_paths`.

## Before plan (pipeline)

Stage the img-dsv-fetch release into `observability/lab/hosts/.dsv-fetch-release/`:
`dsv-fetch-linux-amd64`, `dsv-fetch-linux-arm64`, `dsv-fetch-windows-amd64.exe` and `SHA256SUMS`. The steps are:
download `artifacts["img-dsv-fetch"].package_url`, verify `package_sha256`, then unzip. The plan fails with a clear
message when the files are missing. Terraform checks every binary against `SHA256SUMS`, and the host checks it again.

## Settings (`components.obs-hosts`)

* **Mode and version:**
  * `mode` = `policy` (default) | `direct`.
  * `package_version` (default `1.0.0`): bump it for every change of the Agent pin, the installer or the dsv-fetch
    release. Promote it dev -> test -> prod.
  * `retained_versions`: rollback targets.
* **Policy:**
  * `scope`: null = this subscription, or `{type = "management_group", id = "/providers/Microsoft.Management/managementGroups/<mg>"}`.
  * `enrollment_tag {name, value}` (default `datadog:enabled` / `true`), `effect` (`DeployIfNotExists`), `targets`
    (`vm`, `vmss`), `remediation {...}`.
* **Agent logs:** `host_logs`, by default:
  * Linux: `/var/log/hello-worker/*.log` and `/var/log/enterprise-hello/*.log`;
  * Windows: `C:\ProgramData\enterprise-hello\logs\*.log` plus the Event Log channels `System` and `Application`.

  Hosts add files with the `datadog:log_paths` tag.
* **Package details:** `applications` (add `linux_arm64` for arm64 hosts), `dsv_fetch_release_dir`, `replica_regions`,
  `publisher_principal_ids` (apply identity: blob upload with Entra ID), `package_network`.
* **Other:** `agent_identity_key` (`obs-host-agent`), `sqlvm_os_type` (direct mode).

## Secrets

This root and its state hold no secret. Every host reads `datadog-api-key` from Delinea DSV at Agent start. The
Agent's secret backend is the dsv-fetch binary, which uses the `obs-host-agent` identity. DSV grants that identity
read on the **ingest-only** API key only. Accepted risk: any process on an enrolled host can use the identity. See
the module README.

## Requests to platform owners

The platform roots tag their VMs and VMSS with `datadog:enabled = "true"`. Then:

* add `lifecycle { ignore_changes = [gallery_application] }`;
* add the `obs-host-agent` identity to `identity_ids`, or ignore `identity`.

This keeps their next apply from removing what the policy attached.

## Cost

VM Applications and Azure Policy are free. The package storage (ZRS, a few MB per version) and the gallery replicas
cost almost nothing. Datadog bills the Agent hosts.

## Teardown

Destroy removes the policy assignment, initiative, definitions, custom role, gallery and storage. Agents already
installed stay on the hosts until the application is removed from their model (the `remove` script uninstalls the
Agent). Remove the `datadog:enabled` tags first if hosts should be cleaned up.

## Private networking

Hosts need egress to:

* `*.datadoghq.com` (or the site), or the Observability Pipelines Worker in the VNet;
* `install.datadoghq.com`, `apt.datadoghq.com` / `yum.datadoghq.com` and `windows-agent.datadoghq.com` (Agent
  install);
* the DSV tenant (`<tenant>.secretsvaultcloud.<tld>`).

The package storage needs no host access.

## Limitations

* Not deployed or verified live from this change.
* The Windows installer is parse-checked and its configuration part executed under pwsh on Linux; it was not run on
  Windows.
* The remediation template's lambda functions and the partial-body PUT of VMSS models follow Microsoft Learn but were
  not exercised against Azure.
