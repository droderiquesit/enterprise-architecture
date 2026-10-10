# hello-functions (Python 3.13, v2 model) on three Functions hosting options:
#   premium   - Elastic Premium EP1 Linux: audit (Service Bus topic order-events / subscription audit)
#   dedicated - App Service Linux plan (platform-appservice): cache-warmer (timer)
#   aca       - Functions on Container Apps V2 (Microsoft.App/containerApps kind=functionapp, azapi gap): quote (HTTP)
# Each host disables the functions it does not own with AzureWebJobs.<name>.Disabled.
# Code: premium/dedicated run from the immutable package URL (WEBSITE_RUN_FROM_PACKAGE + managed identity, no
# Azure Files content share); ACA runs the svc-functions container image.
module "meta" {
  source = "../modules/service-meta"
}

locals {
  svc      = "hello-functions"
  meta     = module.meta.services[local.svc]
  artifact = local.meta.artifact
  fx       = var.platform_functions
  rg       = local.fx.resource_group_name
  fx_loc   = coalesce(local.fx.location, local.location)
  identity = var.foundation_identity.identities[try(local.fx.premium.identity, "hello-functions")]
  suffix   = module.naming.suffix
  fn       = var.settings.function_names

  private = var.settings.network_mode == "private-endpoint" || (var.settings.network_mode == "auto" && var.foundation_network != null)
  pe_zone = try(var.foundation_network.private_dns_zones["webapps"].id, null)

  # Host storage for premium + dedicated: the premium plan's runtime storage account (hello-functions has
  # blob/queue/table data roles there, granted by platform-functions).
  host_storage = try(local.fx.premium.storage_account_name, null)

  hosts = merge(
    var.settings.premium_enabled && local.fx.premium != null ? {
      premium = { plan_id = local.fx.premium.plan_id, owns = local.fn.audit, always_on = false, rg = local.rg, arch = "functions-premium" }
    } : {},
    var.settings.dedicated_enabled && var.platform_appservice != null && try(var.platform_appservice.functions_dedicated_plan, null) != null && local.host_storage != null ? {
      dedicated = { plan_id = var.platform_appservice.plans[var.platform_appservice.functions_dedicated_plan].id, owns = local.fn.cache_warmer, always_on = true, rg = var.platform_appservice.resource_group_name, arch = "functions-dedicated" }
    } : {},
  )
  all_functions = [local.fn.audit, local.fn.cache_warmer, local.fn.quote]
  disabled      = { for h, c in local.hosts : h => { for f in local.all_functions : "AzureWebJobs.${f}.Disabled" => "true" if f != c.owns } }

  ledger = var.platform_db_ledger
  table  = var.platform_db_table_storage
  service_env = merge(
    {
      SERVICEBUS_FQDN                               = var.platform_messaging.fqdn
      ServiceBusConnection__fullyQualifiedNamespace = var.platform_messaging.fqdn
      ServiceBusConnection__credential              = "managedidentity"
      ServiceBusConnection__clientId                = local.identity.client_id
      AUDIT_TOPIC                                   = var.platform_messaging.topic.name
      AUDIT_SUBSCRIPTION                            = try(var.platform_messaging.subscriptions["audit"].name, "audit")
      AUDIT_SINK                                    = local.ledger != null ? "ledger" : (local.table != null ? "table" : "log")
      CACHE_WARM_SCHEDULE                           = var.settings.cache_warm_schedule
    },
    local.ledger == null ? {} : { LEDGER_ENDPOINT = local.ledger.ledger.ledger_endpoint, LEDGER_COLLECTION = "order-audit" },
    local.table == null ? {} : { TABLES_ENDPOINT = local.table.account.endpoint, AUDIT_TABLE = "audit" },
    var.settings.catalog_api_url == null ? {} : { CATALOG_API_URL = var.settings.catalog_api_url },
  )
}

module "env" {
  source = "../modules/app-env"
  for_each = merge({ for h in keys(local.hosts) : h => "functions" },
  var.settings.container_apps_enabled && var.platform_containerapps != null && var.platform_shared != null ? { aca = "aca" } : {})

  service = {
    name    = local.svc
    version = local.artifact_version[local.artifact]
    commit  = local.artifact_commit[local.artifact]
    env     = local.env_name
    team    = local.meta.team
    owner   = local.meta.owner
    domain  = local.meta.domain
    tier    = local.meta.tier
    region  = local.fx_loc
  }
  runtime      = "python"
  architecture = each.value
  # Functions on Container Apps stay on OpenTelemetry like every Functions host (ADR-0001 §13, 2026-10-10)
  apm                = each.value == "aca" ? { mode = "otel" } : null
  telemetry          = var.obs_telemetry_transport
  identity_client_id = local.identity.client_id
  faults = {
    enabled   = var.settings.faults_enabled
    token_ref = lookup(var.foundation_identity.secrets.refs, "fault-token", null)
  }
  port               = each.value == "aca" ? 80 : null
  log_level          = var.settings.log_level
  trace_sample_ratio = var.settings.trace_sample_ratio
  otlp_protocol      = "http/protobuf"
  extra_env          = merge(local.service_env, { FUNCTIONS_HOST = each.key })
}

resource "azurerm_linux_function_app" "this" {
  #checkov:skip=CKV_AZURE_221:Public access is disabled in private-endpoint mode; restricted mode denies by default.
  #checkov:skip=CKV_AZURE_56:No Easy Auth: Service Bus/timer triggers only on these hosts; HTTP is denied by network rules.
  for_each            = local.hosts
  name                = "${local.prefix}-func-hello-${each.key}-${local.env_name}-${local.suffix}"
  resource_group_name = each.value.rg
  location            = local.fx_loc
  service_plan_id     = each.value.plan_id
  tags                = merge(local.tags, { service = local.svc, version = local.artifact_version[local.artifact] }, module.env[each.key].azure_tags)

  https_only                                     = true
  public_network_access_enabled                  = !local.private
  builtin_logging_enabled                        = false
  functions_extension_version                    = "~4"
  ftp_publish_basic_authentication_enabled       = false
  webdeploy_publish_basic_authentication_enabled = false
  virtual_network_subnet_id                      = each.key == "dedicated" ? var.platform_appservice.integration_subnet_id : local.fx.integration_subnet_id
  storage_account_name                           = local.host_storage
  storage_uses_managed_identity                  = true
  content_share_force_disabled                   = true

  identity {
    type         = "UserAssigned"
    identity_ids = [local.identity.id]
  }

  app_settings = merge(module.env[each.key].app_settings, local.disabled[each.key], {
    AzureWebJobsStorage__credential              = "managedidentity"
    AzureWebJobsStorage__clientId                = local.identity.client_id
    WEBSITE_RUN_FROM_PACKAGE                     = try(var.artifacts[local.artifact].package_url, "")
    WEBSITE_RUN_FROM_PACKAGE_BLOB_MI_RESOURCE_ID = local.identity.id
  })

  site_config {
    always_on                        = each.value.always_on
    minimum_tls_version              = "1.2"
    http2_enabled                    = true
    vnet_route_all_enabled           = true
    runtime_scale_monitoring_enabled = each.key == "premium" ? true : null
    elastic_instance_minimum         = each.key == "premium" ? 1 : null
    app_scale_limit                  = each.key == "premium" ? var.settings.premium_max_scale_out : null
    ip_restriction_default_action    = local.private ? null : "Deny"
    application_stack {
      python_version = var.settings.python_version
    }
    dynamic "ip_restriction" {
      for_each = local.private ? [] : var.settings.allowed_ip_ranges
      content {
        name       = "allow-${ip_restriction.key}"
        action     = "Allow"
        ip_address = ip_restriction.value
        priority   = 100 + ip_restriction.key
      }
    }
  }
}

module "private_endpoint" {
  source   = "../../../foundation/modules/private-endpoint"
  for_each = local.private ? local.hosts : {}

  name                 = "${local.names.private_endpoint}-func-${each.key}"
  resource_group_name  = each.value.rg
  location             = local.fx_loc
  subnet_id            = var.foundation_network.subnets["private-endpoints"].id
  target_resource_id   = azurerm_linux_function_app.this[each.key].id
  subresource_names    = ["sites"]
  private_dns_zone_ids = local.pe_zone == null ? [] : [local.pe_zone]
  tags                 = local.tags
}

# ---------------------------------------------------------------- Functions on Container Apps (V2, azapi gap)
resource "azurerm_resource_group" "aca" {
  count    = contains(keys(module.env), "aca") ? 1 : 0
  name     = local.names.resource_group
  location = local.location
  tags     = local.tags
}

locals {
  aca_enabled = contains(keys(module.env), "aca")
  aca_env     = local.aca_enabled ? module.env["aca"] : null
  aca_patch   = local.aca_enabled ? local.aca_env.container_app_patch : null
  # ACA secrets: only the (non-secret) Fluent Bit config files; secret settings are dsv:// env values (ADR-0001 §14)
  aca_secrets = local.aca_enabled ? [for s in local.aca_patch.secrets : { name = s.name, value = s.value }] : []
  aca_init = local.aca_enabled ? [for c in local.aca_patch.init_containers : {
    name         = c.name
    image        = c.image
    args         = c.args
    resources    = { cpu = c.cpu, memory = c.memory }
    env          = [for e in c.env : { name = e.name, value = e.value }]
    volumeMounts = [for m in c.volume_mounts : { volumeName = m.name, mountPath = m.path }]
  }] : []
  aca_app_env = local.aca_enabled ? concat(
    [for k in sort(keys(local.aca_env.env)) : { name = k, value = local.aca_env.env[k] }],
    [{ name = "AzureWebJobsStorage__accountName", value = coalesce(local.host_storage, "unset") },
      { name = "AzureWebJobsStorage__credential", value = "managedidentity" },
    { name = "AzureWebJobsStorage__clientId", value = local.identity.client_id }],
    [for f in local.all_functions : { name = "AzureWebJobs.${f}.Disabled", value = "true" } if f != local.fn.quote],
  ) : []
}

resource "azapi_resource" "quote" {
  count     = local.aca_enabled ? 1 : 0
  type      = "Microsoft.App/containerApps@2026-01-01"
  name      = "${local.prefix}-ca-func-quote-${local.env_name}"
  parent_id = azurerm_resource_group.aca[0].id
  location  = local.location
  tags      = merge(local.tags, { service = local.svc, version = local.artifact_version[local.artifact] })

  identity {
    type         = "UserAssigned"
    identity_ids = [local.identity.id]
  }

  body = {
    kind = "functionapp"
    properties = {
      environmentId       = var.platform_containerapps.environment_id
      workloadProfileName = "Consumption"
      configuration = {
        activeRevisionsMode = "Single"
        ingress = {
          external      = false
          targetPort    = 80
          transport     = "auto"
          allowInsecure = false
        }
        registries = [{ server = var.platform_shared.acr_login_server, identity = local.identity.id }]
        secrets    = local.aca_secrets
      }
      template = {
        # dsv-fetch writes the Fluent Bit sidecar's key (Consumption profile: init containers have managed identity)
        initContainers = local.aca_init
        containers = concat(
          [{
            name         = local.svc
            image        = try(var.artifacts[local.artifact].image, null)
            resources    = { cpu = 0.5, memory = "1Gi" }
            env          = local.aca_app_env
            volumeMounts = [for m in local.aca_patch.app_container.volume_mounts : { volumeName = m.name, mountPath = m.path }]
          }],
          [for s in local.aca_patch.sidecars : {
            name         = s.name
            image        = s.image
            args         = s.args
            resources    = { cpu = s.cpu, memory = s.memory }
            env          = [for e in s.env : { name = e.name, value = e.value }]
            volumeMounts = [for m in s.volume_mounts : m.sub_path == null ? { volumeName = m.name, mountPath = m.path } : { volumeName = m.name, mountPath = m.path, subPath = m.sub_path }]
          }],
        )
        volumes = [for v in local.aca_patch.volumes : { name = v.name, storageType = v.storage_type }]
        scale   = { minReplicas = 0, maxReplicas = var.settings.aca_max_replicas }
      }
    }
  }
  response_export_values = ["properties.configuration.ingress.fqdn", "properties.latestRevisionName"]

  lifecycle {
    precondition {
      condition     = can(regex("@sha256:[a-f0-9]{64}$", var.artifacts[local.artifact].image))
      error_message = "svc-functions container image must be digest-pinned."
    }
  }
}

check "functions_artifact" {
  assert {
    condition     = length(local.hosts) == 0 || try(var.artifacts[local.artifact].package_url != null, false)
    error_message = "svc-functions zip package is required for the premium/dedicated hosts."
  }
}
