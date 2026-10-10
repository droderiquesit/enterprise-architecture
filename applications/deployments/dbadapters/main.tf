# hello-dbadapter-<family>: one instance per enabled DB family (catalog/architecture-matrix.yaml):
#   Container Apps consumption (default) | Container Apps dedicated-d4 (sqlmi, redis) |
#   App Service Linux code (mysql) | VMSS Uniform CustomScript (sqlvm).
module "meta" {
  source = "../modules/service-meta"
}

resource "azurerm_resource_group" "this" {
  name     = local.names.resource_group
  location = local.location
  tags     = local.tags
}

locals {
  svc      = "hello-dbadapter"
  meta     = module.meta.services[local.svc]
  artifact = local.meta.artifact
  identity = var.foundation_identity.identities[local.svc]
  suffix   = module.naming.suffix

  private = var.settings.network_mode == "private-endpoint" || (var.settings.network_mode == "auto" && var.foundation_network != null)
  pe = local.private ? {
    subnet_id   = var.foundation_network.subnets["private-endpoints"].id
    dns_zone_id = try(var.foundation_network.private_dns_zones["webapps"].id, null)
  } : null

  arch = { aca = "aca", "aca-dedicated" = "aca", appservice = "appservice", vmss = "vmss" }
}

module "env" {
  source   = "../modules/app-env"
  for_each = local.enabled

  service = {
    name    = "${local.svc}-${each.key}"
    version = local.artifact_version[local.artifact]
    commit  = local.artifact_commit[local.artifact]
    env     = local.env_name
    team    = local.meta.team
    owner   = local.meta.owner
    domain  = local.meta.domain
    tier    = local.meta.tier
    region  = local.location
  }
  runtime            = "python"
  architecture       = local.arch[local.hosting[each.key]]
  telemetry          = local.telemetry
  identity_client_id = local.identity.client_id
  faults = {
    enabled   = var.settings.faults_enabled
    token_ref = lookup(var.foundation_identity.secrets.refs, "fault-token", null)
  }
  port               = local.hosting[each.key] == "appservice" ? 8000 : 8080
  log_level          = var.settings.log_level
  trace_sample_ratio = var.settings.trace_sample_ratio
  extra_env          = merge(each.value.env, { DB_FAMILY = each.key, DB_SERVICE_NAME = "${local.svc}-${each.key}" })
  secret_env         = each.value.secrets
}

# ---------------------------------------------------------------- Container Apps
module "aca" {
  source   = "../modules/container-app"
  for_each = local.aca_families

  name                  = "${local.prefix}-ca-db-${each.value.short}-${local.env_name}"
  resource_group_name   = azurerm_resource_group.this.name
  environment_id        = var.platform_containerapps.environment_id
  workload_profile_name = local.hosting[each.key] == "aca-dedicated" ? local.dedicated_profile : "Consumption"
  tags                  = merge(local.tags, { service = "${local.svc}-${each.key}", version = local.artifact_version[local.artifact] }, module.env[each.key].azure_tags)
  identity              = { id = local.identity.id, client_id = local.identity.client_id }
  registry_server       = var.platform_shared.acr_login_server
  container = {
    name   = local.svc
    image  = try(var.artifacts[local.artifact].image, null)
    cpu    = 0.5
    memory = "1Gi"
  }
  env           = module.env[each.key].env
  sidecar_patch = module.env[each.key].container_app_patch
  ingress       = { external = false, target_port = 8080 }
  scale = {
    min_replicas = try(var.settings.families[each.key].min_replicas, 0)
    max_replicas = try(var.settings.families[each.key].max_replicas, 2)
  }
  revisions = { mode = "Single" }
}

# ---------------------------------------------------------------- App Service Linux code (mysql)
module "appsvc" {
  source   = "../modules/web-app"
  for_each = local.appsvc_family

  name                = "${local.prefix}-app-db${each.value.short}-${local.env_name}-${local.suffix}"
  resource_group_name = var.platform_appservice.resource_group_name
  location            = coalesce(var.platform_appservice.location, local.location)
  tags                = merge(local.tags, { service = "${local.svc}-${each.key}", version = local.artifact_version[local.artifact] }, module.env[each.key].azure_tags)
  service_plan        = { id = local.linux_plan.id, sku = local.linux_plan.sku }
  os_type             = "Linux"
  mode                = "code"
  stack               = { python_version = "3.13" }
  identity            = { id = local.identity.id, client_id = local.identity.client_id }
  # Wheelhouse package (wheels/, requirements.txt): offline install into a venv on /home, then run the app.
  startup_command = "bash -c 'set -e; V=/home/site/venv-$(cat VERSION); [ -x $V/bin/python ] || { python -m venv $V && $V/bin/pip install -q --no-index --find-links wheels -r requirements.txt && $V/bin/pip install -q --no-index --no-deps --find-links wheels hello-common hello-dbadapter; }; exec $V/bin/python -m hello_dbadapter'"
  app_settings = merge(module.env[each.key].app_settings, {
    WEBSITES_PORT                  = "8000"
    SCM_DO_BUILD_DURING_DEPLOYMENT = "false"
  })
  integration_subnet_id = var.platform_appservice.integration_subnet_id
  private_endpoint      = local.pe
  allowed_ip_ranges     = var.settings.allowed_ip_ranges
  staging_slot          = true
}

# ---------------------------------------------------------------- VMSS Uniform (sqlvm)
module "vmss_script" {
  source   = "../modules/vm-script"
  for_each = local.vmss_family

  component     = local.component
  app           = "${local.svc}-${each.key}"
  mode          = "python-service"
  python_module = "hello_dbadapter"
  pip_packages  = ["hello-common", "hello-dbadapter"]
  health_url    = "http://127.0.0.1:8080/healthz"
  client_id     = coalesce(local.uniform_vmss.identity_client_id, local.identity.client_id)
  version_label = local.artifact_version[local.artifact]
  package = {
    url    = try(var.artifacts[local.artifact].package_url, "")
    sha256 = try(var.artifacts[local.artifact].package_sha256, "")
  }
  env        = merge(module.env[each.key].env, { LOG_FILE_PATH = "${local.uniform_vmss.log_dir}/${local.svc}-${each.key}.log" })
  secret_env = module.env[each.key].secret_env
}

# Model-level extension: a new package version / force tag changes the VMSS model; with upgrade_mode Manual the
# pipeline rolls instances with `az vmss update-instances` (deploy step kind vmss-update-instances).
resource "azurerm_virtual_machine_scale_set_extension" "sqlvm_adapter" {
  for_each                     = local.vmss_family
  name                         = "${local.svc}-${each.key}"
  virtual_machine_scale_set_id = local.uniform_vmss.id
  publisher                    = "Microsoft.Azure.Extensions"
  type                         = "CustomScript"
  type_handler_version         = "2.1"
  auto_upgrade_minor_version   = true
  force_update_tag             = "${local.artifact_version[local.artifact]}-${var.settings.vmss_package_force}"
  # The script carries no secret values (secret settings are dsv:// references the service resolves itself), but CustomScript
  # scripts belong in protected settings.
  protected_settings = jsonencode({
    script = base64gzip(module.vmss_script[each.key].script)
  })
}

check "dbadapter_artifact" {
  assert {
    condition     = length(local.aca_families) == 0 || can(regex("@sha256:[a-f0-9]{64}$", var.artifacts[local.artifact].image))
    error_message = "svc-dbadapter image (digest-pinned) is required for Container Apps families."
  }
}

# dsv-fetch (sidecar key init/refresher container): this root's registry artifact img-dsv-fetch (digest-pinned) wins
# over the image published in the transport contract (ADR-0001 section 14).
locals {
  telemetry = merge(var.obs_telemetry_transport, {
    secrets = merge(var.obs_telemetry_transport.secrets, {
      fetch_image = try(coalesce(try(var.artifacts["img-dsv-fetch"].image, null), var.obs_telemetry_transport.secrets.fetch_image), null)
    })
  })
}
