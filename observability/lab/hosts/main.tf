module "tags" {
  source      = "../../../foundation/modules/tags"
  environment = var.environment
  component   = "obs-hosts"
  layer       = "observability"
  service     = "host-agents"
  domain      = "observability"
}

locals {
  base_tags = { env = var.environment.name, team = var.environment.team, application = "enterprise-hello" }

  vm_hosts = var.platform_vm == null ? {} : { for k, v in var.platform_vm.vms : "vm-${k}" => {
    resource_id        = v.id
    os_type            = lower(v.os_type)
    kind               = "vm"
    location           = coalesce(var.platform_vm.location, var.environment.location)
    identity_client_id = v.identity_client_id
    log_dir            = coalesce(v.log_dir, lower(v.os_type) == "windows" ? var.settings.default_windows_log_dir : var.settings.default_linux_log_dir)
    service            = coalesce(v.workload, v.name)
    install_fluent_bit = true
  } }
  vmss_hosts = var.platform_vmss == null ? {} : { for k, v in var.platform_vmss.scale_sets : "vmss-${k}" => {
    resource_id        = v.id
    os_type            = lower(v.os_type)
    kind               = "vmss"
    location           = coalesce(var.platform_vmss.location, var.environment.location)
    identity_client_id = v.identity_client_id
    log_dir            = coalesce(v.log_dir, var.settings.default_linux_log_dir)
    service            = coalesce(v.workload, v.name)
    install_fluent_bit = true
  } }
  # The SQL Server VM gets the Agent only; it needs a user-assigned identity mapped to DSV (contract field
  # vm.identity_client_id, else settings.sqlvm_identity_client_id) - without one it is skipped.
  sqlvm_identity = try(coalesce(try(var.platform_db_sqlvm.vm.identity_client_id, null), var.settings.sqlvm_identity_client_id), null)
  sqlvm_hosts = var.platform_db_sqlvm == null || local.sqlvm_identity == null ? {} : { "sqlvm" = {
    resource_id        = var.platform_db_sqlvm.vm.id
    os_type            = var.settings.sqlvm_os_type
    kind               = "vm"
    location           = var.environment.location
    identity_client_id = local.sqlvm_identity
    log_dir            = ""
    service            = "sql-server"
    install_fluent_bit = false
  } }
  all = merge(local.vm_hosts, local.vmss_hosts, local.sqlvm_hosts)

  hosts = { for k, h in local.all : k => {
    resource_id        = h.resource_id
    os_type            = h.os_type
    kind               = h.kind
    location           = h.location
    identity_client_id = h.identity_client_id
    service_tags       = merge(local.base_tags, { service = h.service, source = h.os_type == "windows" ? "csharp" : "python" }, lookup(var.settings.service_tags, k, {}))
    log_paths = !h.install_fluent_bit ? [] : lookup(var.settings.workload_log_paths, h.service,
    [h.os_type == "windows" ? "${h.log_dir}\\${var.settings.linux_log_glob}" : "${h.log_dir}/${var.settings.linux_log_glob}"])
    install_fluent_bit = h.install_fluent_bit
  } }
}

module "hosts" {
  source = "../../modules/host-agents"
  hosts  = local.hosts
  # every host reads the key from Delinea DSV itself (Agent secret backend / Fluent Bit ExecStartPre); no data
  # source, nothing secret in this root's state
  datadog = {
    site          = var.obs_telemetry_transport.datadog_site
    agent_version = var.settings.agent_version
    api_key_ref   = var.obs_telemetry_transport.api_key_ref
  }
  secrets = {
    tenant   = var.obs_telemetry_transport.secrets.tenant
    tld      = var.obs_telemetry_transport.secrets.tld
    base_url = var.obs_telemetry_transport.secrets.base_url
  }
  setup_revision     = var.settings.setup_revision
  fluent_bit_version = var.settings.fluent_bit_version
  tags               = module.tags.tags
}
