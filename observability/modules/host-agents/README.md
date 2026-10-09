# modules/host-agents

Installs the Datadog Agent and Fluent Bit on **existing** VMs and VM scale sets (Linux and Windows).

| Kind | Datadog Agent | Fluent Bit + Agent OTLP/logs-off configuration |
|---|---|---|
| `vm` | `azurerm_virtual_machine_extension` (publisher `Datadog.Agent`, type `DatadogLinuxAgent` / `DatadogWindowsAgent`, handler `7.0`, auto minor upgrade) with settings `{site, agentVersion}` | `azurerm_virtual_machine_run_command` `observability-setup` (managed run command; re-runs when the script hash changes) |
| `vmss` | `azurerm_virtual_machine_scale_set_extension` (same type) | `CustomScript` extension (Linux `Microsoft.Azure.Extensions/CustomScript 2.1` with a gzip `script`; Windows `CustomScriptExtension 1.10` with a gzip+base64 PowerShell stub), `provision_after_extensions = [DatadogAgent]`, `force_update_tag` = script hash. New autoscaled instances get it automatically. A Manual upgrade policy needs an instance upgrade. |

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

   The Agent is restarted only on change. The extension cannot set OTLP options, because its settings are only
   `site`, `agentVersion` and an `agentConfiguration` URI.
2. Fluent Bit pinned at `5.1.3` from `packages.fluentbit.io`: apt with a signed-by keyring plus `apt-mark hold`,
   or yum/dnf. The MSI is SHA256-verified. The packaged `fluent-bit.service` is disabled and `fluent-bit-eh.service`
   runs `-c /etc/fluent-bit-eh/fluent-bit.yaml`. The config is staged, checked with `--dry-run`, then swapped,
   and the service restarts only on change.
3. The Datadog API key for Fluent Bit is read **at run time from Key Vault** with the host's user-assigned
   identity (IMDS token, then the Key Vault REST API), so it is never in Terraform state. The fallback is the
   protected run-command parameter `DD_API_KEY`. VMSS instances must use Key Vault, which a precondition
   enforces.

## Agent API key
* Preferred: `datadog.api_key_key_vault = { secret_url (VERSIONED; validation enforces it), source_vault_id }`.
  This uses the extension's `protectedSettingsFromKeyVault`. The secret value must be `{"api_key":"<key>"}` and
  the vault needs `enabled_for_deployment`.
* Fallback: `api_key` (sensitive), which is stored in state as a protected setting.

Inputs: `hosts` (map of `{resource_id, os_type, kind, location, service_tags, log_paths, systemd_unit,
windows_event_log, identity_client_id, install_agent, install_fluent_bit}`), `datadog {site, agent_version
(pinned 7.x.y), extension_version, api_key_secret_id, process_collection, api_key_key_vault}`, `api_key`,
`fluent_bit_version`.
Outputs: `agent_extensions`, `setup`, `otlp_endpoint`, `scripts_sha256`, `installer_scripts`.

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
- https://learn.microsoft.com/azure/virtual-machines/extensions/key-vault-linux (protectedSettingsFromKeyVault)
