# lab/hosts (component `obs-hosts`)

**Owner:** observability. **Purpose:** installs the Datadog Agent and Fluent Bit on the lab VMs and VMSS through
`modules/host-agents`. Separate ARM resources (extensions, run commands) are owned here (ADR §3 rule 3).

* **Consumes:**
  * `obs_telemetry_transport` v2 (datadog_site, api_key_ref, secrets.{tenant, tld, base_url})
  * optional: `platform_vm.vms`, `platform_vmss.scale_sets` (id, name, os_type, workload,
    identity_client_id, log_dir)
  * optional: `platform_db_sqlvm.vm` (Agent only; needs `vm.identity_client_id` or `settings.sqlvm_identity_client_id`, else skipped)
* **Produces:** no contract. Outputs: `setup`, `otlp_endpoint`, `hosts` (log paths).

## Settings
* `agent_version` (7.84.2), `fluent_bit_version` (5.1.3)
* `setup_revision` (bump once after the 2.0 upgrade: removing the 1.x Datadog extension uninstalls the Agent)
* `workload_log_paths`: the default is `hello-worker = ["/var/log/hello-worker/*.log"]` (the worker writes
  `/var/log/hello-worker/worker.log`). Otherwise `<log_dir>/*.log`, or the defaults
  `/var/log/enterprise-hello` and `C:\ProgramData\enterprise-hello\logs`.
* `sqlvm_os_type`, `service_tags`

## Secrets
* No secret in this root or its state. Every host reads `datadog-api-key` from Delinea DSV with its user-assigned
  identity: the Linux Agent via `secret_backend_command` (dsv-fetch `agent-backend`, `api_key: ENC[dsv://...]`), Fluent
  Bit via `ExecStartPre` (tmpfs env file), Windows hosts in the installer (PowerShell). The host identities must be
  DSV users with read on `datadog-api-key` (foundation-identity `identities[*].secrets` + foundation-secrets).

## Cost
Extensions and run commands are free. The Datadog Agent host is billed by Datadog.

## Teardown
Destroy removes the extension and run-command resources. It does **not** uninstall packages from the hosts.

## Private networking
Hosts need egress to `*.datadoghq.com`, `packages.fluentbit.io` (install) `install.datadoghq.com` / `windows-agent.datadoghq.com` (Agent install) and the DSV tenant (`<tenant>.secretsvaultcloud.<tld>`).

## Limitations
* VMSS uses a CustomScript extension, and a scale set allows only one. See the module README.
* The Windows installer is not executed locally.
