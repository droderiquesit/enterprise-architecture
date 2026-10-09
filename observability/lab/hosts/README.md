# lab/hosts (component `obs-hosts`)

**Owner:** observability. **Purpose:** installs the Datadog Agent and Fluent Bit on the lab VMs and VMSS through
`modules/host-agents`. Separate ARM resources (extensions, run commands) are owned here (ADR §3 rule 3).

* **Consumes:**
  * `obs_telemetry_transport` (datadog_site, api_key_secret_id)
  * `foundation_identity.key_vault_id`
  * optional: `platform_vm.vms`, `platform_vmss.scale_sets` (id, name, os_type, workload,
    identity_client_id, log_dir)
  * optional: `platform_db_sqlvm.vm` (Agent only)
* **Produces:** no contract. Outputs: `agent_extensions`, `setup`, `otlp_endpoint`, `hosts` (log paths).

## Settings
* `agent_version` (7.84.2), `fluent_bit_version` (5.1.3)
* `agent_protected_settings_secret_url` (VERSIONED; preferred)
* `workload_log_paths`: the default is `hello-worker = ["/var/log/hello-worker/*.log"]` (the worker writes
  `/var/log/hello-worker/worker.log`). Otherwise `<log_dir>/*.log`, or the defaults
  `/var/log/enterprise-hello` and `C:\ProgramData\enterprise-hello\logs`.
* `sqlvm_os_type`, `service_tags`

## Secrets
* Fluent Bit reads `datadog-api-key` from Key Vault at run time with the host's user-assigned identity, so
  nothing lands in state. The VM and VMSS identities (`hello-worker`, `hello-inventory-api`, `hello-dbadapter`) get Key Vault Secrets User for `datadog-api-key` from foundation-identity.
* For the Agent extension, without `agent_protected_settings_secret_url` the key is read by a data source and
  passed as a protected setting. That is stored, encrypted, in state: a documented exception.

## Cost
Extensions and run commands are free. The Datadog Agent host is billed by Datadog.

## Teardown
Destroy removes the extension and run-command resources. It does **not** uninstall packages from the hosts.

## Private networking
Hosts need egress to `*.datadoghq.com`, `packages.fluentbit.io` (install) and Key Vault (private endpoint).

## Limitations
* VMSS uses a CustomScript extension, and a scale set allows only one. See the module README.
* The Windows installer is not executed locally.
