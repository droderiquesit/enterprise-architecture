# Host workloads (ADR-0001 §13, observability 4.0.0: the host Datadog Agent - enrolled by the observability Azure
# Policy + VM Application, not by this root - tails the app log file and receives OTLP on localhost:4317; Fluent Bit
# host service only with log_pipeline = fluent_bit_direct):
#   platform-vm linux    hello-worker          managed run command (worker package deploy/install.sh)
#   platform-vm windows  hello-inventory-api   managed run command (scripts/install-windows-service.ps1.tftpl)
#   platform-vmss flex   hello-worker          CustomScript extension on the scale-set model
# Packages are read with the host's user-assigned identity from the packages container (no SAS in state);
# secret settings are dsv:// references the services resolve from Delinea DSV at start-up (no secret values in state).
module "meta" {
  source = "../modules/service-meta"
}

locals {
  ids = var.foundation_identity.identities
  vm  = var.platform_vm
  ss  = var.platform_vmss
  tbl = var.platform_db_table_storage

  linux_vm   = var.settings.linux_worker ? try(local.vm.vms["linux"], null) : null
  windows_vm = var.settings.windows_inventory ? try(local.vm.vms["windows"], null) : null
  flex       = var.settings.vmss_worker ? try(local.ss.scale_sets["flexible"], null) : null

  worker_env = merge(
    {
      MESSAGING_MODE  = "servicebus"
      SERVICEBUS_FQDN = var.platform_messaging.fqdn
      SB_TOPIC        = var.platform_messaging.topic.name
      SB_SUBSCRIPTION = var.platform_messaging.subscriptions["notifications"].name
      MAX_CONCURRENCY = tostring(var.settings.worker_concurrency)
      TABLE_MODE      = local.tbl == null ? "memory" : "table"
    },
    local.tbl == null ? {} : { TABLES_ENDPOINT = local.tbl.account.endpoint, TABLE_NAME = "notifications" },
  )
  cosmos = var.platform_db_cosmos_nosql
  inventory_env = merge(
    { STORAGE_MODE = local.cosmos == null ? "memory" : "cosmos", COSMOS_CONNECTION_MODE = "gateway" },
    local.cosmos == null ? {} : { COSMOS_ENDPOINT = local.cosmos.account.endpoint, COSMOS_DATABASE = "inventory", COSMOS_CONTAINER = "items" },
  )

  hosts = merge(
    local.linux_vm == null ? {} : { "worker-vm" = { svc = "hello-worker", arch = "vm", host = local.linux_vm, identity = local.linux_vm.workload, port = 8081, env = local.worker_env } },
    local.windows_vm == null ? {} : { "inventory-vm" = { svc = "hello-inventory-api", arch = "vm", host = local.windows_vm, identity = local.windows_vm.workload, port = 8080, env = local.inventory_env } },
    local.flex == null ? {} : { "worker-vmss" = { svc = "hello-worker", arch = "vmss", host = local.flex, identity = local.flex.workload, port = 8081, env = local.worker_env } },
  )
}

module "env" {
  source   = "../modules/app-env"
  for_each = local.hosts

  service = {
    name    = each.value.svc
    version = local.artifact_version[module.meta.services[each.value.svc].artifact]
    commit  = local.artifact_commit[module.meta.services[each.value.svc].artifact]
    env     = local.env_name
    team    = module.meta.services[each.value.svc].team
    owner   = module.meta.services[each.value.svc].owner
    domain  = module.meta.services[each.value.svc].domain
    tier    = module.meta.services[each.value.svc].tier
    region  = local.location
  }
  runtime            = module.meta.services[each.value.svc].runtime
  architecture       = each.value.arch
  telemetry          = var.obs_telemetry_transport
  identity_client_id = local.ids[each.value.identity].client_id
  faults = {
    enabled   = var.settings.faults_enabled
    token_ref = each.value.svc == "hello-worker" ? null : lookup(var.foundation_identity.secrets.refs, "fault-token", null)
  }
  port               = each.value.port
  log_level          = var.settings.log_level
  trace_sample_ratio = var.settings.trace_sample_ratio
  extra_env          = each.value.env
}

locals {
  # Host log files tailed by the observability host log collector (Datadog Agent; Fluent Bit with fluent_bit_direct). The worker unit (package) restricts writes
  # to /var/log/hello-worker, so its LOG_FILE_PATH is that directory; Windows uses the platform log_dir.
  log_file = {
    "worker-vm"    = "/var/log/hello-worker/worker.log"
    "worker-vmss"  = "/var/log/hello-worker/worker.log"
    "inventory-vm" = try("${local.windows_vm.log_dir}\\inventory-api.log", "C:\\hello\\logs\\inventory-api.log")
  }
  host_env = { for k in keys(local.hosts) : k => merge(module.env[k].env, { LOG_FILE_PATH = local.log_file[k] }) }
  pkg      = { for k, h in local.hosts : k => try(var.artifacts[module.meta.services[h.svc].artifact], null) }
}

module "linux_script" {
  source   = "../modules/vm-script"
  for_each = { for k, h in local.hosts : k => h if h.svc == "hello-worker" }

  component     = local.component
  app           = "hello-worker"
  mode          = "package-install-sh"
  health_url    = "http://127.0.0.1:8081/healthz"
  client_id     = local.ids[each.value.identity].client_id
  version_label = local.artifact_version["svc-worker"]
  package = {
    url    = try(local.pkg[each.key].package_url, "")
    sha256 = try(local.pkg[each.key].package_sha256, "")
  }
  env        = local.host_env[each.key]
  secret_env = module.env[each.key].secret_env
}

resource "azurerm_virtual_machine_run_command" "worker" {
  count              = contains(keys(local.hosts), "worker-vm") ? 1 : 0
  name               = "install-hello-worker"
  location           = coalesce(local.vm.location, local.location)
  virtual_machine_id = local.linux_vm.id
  tags               = merge(local.tags, { service = "hello-worker", version = local.artifact_version["svc-worker"], force = var.settings.package_force }, module.env["worker-vm"].azure_tags)

  source {
    script = module.linux_script["worker-vm"].script
  }
}

resource "azurerm_virtual_machine_run_command" "inventory" {
  count              = contains(keys(local.hosts), "inventory-vm") ? 1 : 0
  name               = "install-hello-inventory-api"
  location           = coalesce(local.vm.location, local.location)
  virtual_machine_id = local.windows_vm.id
  tags               = merge(local.tags, { service = "hello-inventory-api", version = local.artifact_version["svc-inventory-api"], force = var.settings.package_force }, module.env["inventory-vm"].azure_tags)

  source {
    script = templatefile("${path.module}/scripts/install-windows-service.ps1.tftpl", {
      service        = "hello-inventory-api"
      client_id      = local.ids[local.hosts["inventory-vm"].identity].client_id
      package_url    = try(local.pkg["inventory-vm"].package_url, "")
      package_sha256 = try(local.pkg["inventory-vm"].package_sha256, "")
      version        = local.artifact_version["svc-inventory-api"]
      app_root       = "${coalesce(local.windows_vm.app_root, "C:\\hello")}\\inventory-api"
      log_dir        = coalesce(local.windows_vm.log_dir, "C:\\hello\\logs")
      exe            = "Hello.InventoryApi.exe"
      health_url     = "http://127.0.0.1:8080/healthz"
      env            = local.host_env["inventory-vm"]
    })
  }
}

resource "azurerm_virtual_machine_scale_set_extension" "worker" {
  count                        = contains(keys(local.hosts), "worker-vmss") ? 1 : 0
  name                         = "hello-worker"
  virtual_machine_scale_set_id = local.flex.id
  publisher                    = "Microsoft.Azure.Extensions"
  type                         = "CustomScript"
  type_handler_version         = "2.1"
  auto_upgrade_minor_version   = true
  force_update_tag             = "${local.artifact_version["svc-worker"]}-${var.settings.package_force}"
  protected_settings = jsonencode({
    script = base64gzip(module.linux_script["worker-vmss"].script)
  })
}

check "host_packages" {
  assert {
    condition     = alltrue([for k, p in local.pkg : try(p.package_url != null && p.package_sha256 != null, false)])
    error_message = "VM/VMSS workloads need zip packages (svc-worker, svc-inventory-api) with sha256."
  }
}
