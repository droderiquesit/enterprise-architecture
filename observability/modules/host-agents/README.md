# modules/host-agents

Installs the Datadog Agent and Fluent Bit on **existing** VMs and VM scale sets (Linux and Windows).

| Kind | Datadog Agent | Fluent Bit + Agent OTLP/logs-off configuration |
|---|---|---|
| `vm` | installed by the setup script (pinned; see below) | `azurerm_virtual_machine_run_command` `observability-setup` (managed run command; re-runs when the script hash changes) |
| `vmss` | installed by the setup script | `CustomScript` extension (Linux `Microsoft.Azure.Extensions/CustomScript 2.1` with a gzip `script`; Windows `CustomScriptExtension 1.10` with a gzip+base64 PowerShell stub), `force_update_tag` = script hash. New autoscaled instances get it automatically. A Manual upgrade policy needs an instance upgrade. |

Why CustomScript for VMSS: managed run commands are per VM instance (`virtualMachineScaleSets/virtualMachines/
runCommands`). Instance ids change with autoscale, and the resource is not in azurerm. Constraint: a scale set
can have only **one** CustomScript extension. If the app owner already uses one, set
`install_fluent_bit = false` and call the rendered installer (`installer_scripts` output) from theirs, or bake
it into the image.

## Installer (scripts/*.tftpl, idempotent)
1. Agent: a systemd drop-in (Linux) or machine env vars (Windows) set:
   * `DD_OTLP_CONFIG_RECEIVER_PROTOCOLS_GRPC_ENDPOINT=localhost:4317` and `..._HTTP_ENDPOINT=localhost:4318`
   * `DD_LOGS_ENABLED=false` and `DD_OTLP_CONFIG_LOGS_ENABLED=false`
   * `DD_TAGS`

   The Agent is restarted only on change.
2. Fluent Bit pinned at `5.1.3` from `packages.fluentbit.io`: apt with a signed-by keyring plus `apt-mark hold`,
   or yum/dnf. The MSI is verified against a pinned SHA256. The packaged `fluent-bit.service` is disabled and `fluent-bit-eh.service`
   runs `-c /etc/fluent-bit-eh/fluent-bit.yaml`. The config is staged, checked with `--dry-run`, then swapped,
   and the service restarts only on change.
3. Secrets (Delinea DSV; nothing secret in Terraform, extension settings or run-command parameters): the installer
   embeds `images/dsv-fetch/dsv_fetch.py` and installs it twice with `dsv-fetch install` - `/opt/eh-dsv-fetch/dsv-fetch`
   (root, 0500) and `/opt/eh-dsv-fetch/agent/dsv-fetch` (owned by `dd-agent`, 0500, as the Agent requires of a
   `secret_backend_command`), interpreter = the Agent's embedded Python 3.13 (else the OS `python3` >= 3.11). Non-secret
   DSV settings + the host identity client id go to `/etc/eh-dsv/dsv.json`.
   * **Agent (Linux)**: installed by the installer itself (no Datadog VM extension: its `api_key` would be a protected
     setting). `datadog.yaml` is written first (`api_key: ENC[<datadog.api_key_ref>]`, `secret_backend_command`,
     `secret_backend_arguments: [agent-backend, --config, /etc/eh-dsv/dsv.json]`), then the official install script runs
     with `DD_INSTALL_ONLY=true` and the pinned `DD_AGENT_MINOR_VERSION` (it keeps an existing `datadog.yaml`, so no
     `DD_API_KEY` is needed).
   * **Fluent Bit (Linux)**: `fluent-bit-eh.service` has `RuntimeDirectory=fluent-bit-eh` (tmpfs, 0700) and
     `ExecStartPre=dsv-fetch init ... --format env-yaml` writing `/run/fluent-bit-eh/fluentbit-env.yaml` (0400), which
     `linux-host.yaml` includes. Every (re)start re-reads DSV (rotation = restart).
   * **Windows**: the Agent cannot use a script as secret backend (Win32 executable required), so the PowerShell
     installer reads the key from DSV itself (IMDS token -> `POST /v1/token` -> `GET /v1/secrets/<path>`) and writes it
     into `C:\ProgramData\Datadog\datadog.yaml` and the Fluent Bit include `C:\ProgramData\fluent-bit-eh\secrets\fluentbit-env.yaml`
     (ACL: SYSTEM, Administrators, ddagentuser read). Rotation = re-run (`setup_revision`). MSIs are verified against
     pinned SHA256 values (`windows_msi_sha256`; neither vendor publishes checksum files).

Inputs: `hosts` (map of `{resource_id, os_type, kind, location, service_tags, log_paths, systemd_unit,
windows_event_log, identity_client_id (required), install_agent, install_fluent_bit}`), `datadog {site, agent_version
(pinned 7.x.y), api_key_ref (dsv://), process_collection}`, `secrets {tenant, tld, base_url, auth}`, `dsv_fetch_source`,
`windows_msi_sha256`, `setup_revision`, `fluent_bit_version`.
Outputs: `setup`, `otlp_endpoint`, `scripts_sha256`, `installer_scripts`.

Verification:
* `tests/hosts.tftest.hcl` (mock providers).
* `observability/tests/transport/test_host_installer.py` runs the rendered Linux installer twice in
  `ubuntu:24.04` with systemd stubbed, using a real package download. It shows that `fluent-bit 5.1.3` gets
  installed, the dry-run passes, the env file is 0600, the drop-in is written, the second run makes no change,
  and an agent-only host works. **locally-verified**.
* The Windows script is rendered and length-checked only, not executed.

References:
- https://docs.datadoghq.com/integrations/guide/powershell-command-to-install-azure-datadog-extension/ and https://docs.datadoghq.com/integrations/guide/azure-programmatic-management
- https://docs.datadoghq.com/opentelemetry/setup/otlp_ingest_in_the_agent/
- https://docs.fluentbit.io/manual/installation/downloads/linux/ubuntu and https://docs.fluentbit.io/manual/installation/downloads/windows
- https://learn.microsoft.com/azure/virtual-machines/run-command-overview ; https://learn.microsoft.com/azure/virtual-machines/extensions/custom-script-linux
- https://docs.datadoghq.com/agent/configuration/secrets-management/ (secret_backend_command requirements)
