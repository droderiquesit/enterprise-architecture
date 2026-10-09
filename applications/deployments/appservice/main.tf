# App Service workloads:
#   hello-inventory-api  Windows code (self-contained win-x64 zip, deployed to the staging slot and swapped)
#   hello-inventory-api  Windows container variant (disabled by default)
#   hello-catalog-api    Linux container variant (optional)
# Logs: AppServiceConsoleLogs diagnostic settings -> Event Hubs (obs-diagnostics) - no sidecars here.
module "meta" {
  source = "../modules/service-meta"
}

locals {
  ids    = var.foundation_identity.identities
  meta   = module.meta.services
  as     = var.platform_appservice
  rg     = local.as.resource_group_name
  as_loc = coalesce(local.as.location, local.location)
  suffix = module.naming.suffix

  private = var.settings.network_mode == "private-endpoint" || (var.settings.network_mode == "auto" && var.foundation_network != null)
  pe = local.private ? {
    subnet_id   = var.foundation_network.subnets["private-endpoints"].id
    dns_zone_id = try(var.foundation_network.private_dns_zones["webapps"].id, null)
  } : null

  cosmos = var.platform_db_cosmos_nosql
  inv_db = try(local.cosmos.databases["inventory"], null)
  inv_env = merge(
    { STORAGE_MODE = local.cosmos == null ? "memory" : "cosmos" },
    local.cosmos == null ? {} : {
      COSMOS_ENDPOINT        = local.cosmos.account.endpoint
      COSMOS_DATABASE        = try(local.inv_db.name, "inventory")
      COSMOS_CONTAINER       = try(local.inv_db.containers["items"].name, "items")
      COSMOS_CONNECTION_MODE = "gateway" # HTTPS/443 only through VNet integration + private endpoint
    },
  )
  pg    = var.platform_db_postgresql
  redis = var.platform_db_redis
  cat_env = merge(
    local.pg == null ? {} : {
      PG_HOST     = local.pg.server.fqdn
      PG_PORT     = tostring(local.pg.server.port)
      PG_DATABASE = local.pg.databases["catalog"].name
      PG_USER     = "hello-catalog-api"
      PG_AUTH     = "entra"
    },
    local.redis == null ? { REDIS_AUTH = "none" } : { REDIS_HOST = local.redis.cache.hostname, REDIS_PORT = tostring(local.redis.cache.port), REDIS_AUTH = "entra" },
    { CACHE_TTL_SECONDS = tostring(var.settings.redis_cache_ttl_seconds) },
  )

  windows_plan   = try(local.as.plans["windows"], null)
  wincont_plan   = try(local.as.plans["windows_container"], null)
  linux_plan     = try(local.as.plans["linux"], null)
  inventory_code = var.settings.inventory.enabled && local.windows_plan != null
  inventory_cont = var.settings.inventory.container_enabled && local.wincont_plan != null
  catalog_cont   = var.settings.catalog_container_enabled && local.linux_plan != null && local.pg != null

  apps = merge(
    local.inventory_code ? { "hello-inventory-api" = { svc = "hello-inventory-api", plan = local.windows_plan, os = "Windows", mode = "code", short = "inv", port = null, env = local.inv_env, arch = "app-service-windows-code" } } : {},
    local.inventory_cont ? { "hello-inventory-api-wincontainer" = { svc = "hello-inventory-api", plan = local.wincont_plan, os = "Windows", mode = "container", short = "invc", port = 8080, env = local.inv_env, arch = "app-service-windows-container" } } : {},
    local.catalog_cont ? { "hello-catalog-api-container" = { svc = "hello-catalog-api", plan = local.linux_plan, os = "Linux", mode = "container", short = "catc", port = 8080, env = local.cat_env, arch = "app-service-linux-container" } } : {},
  )
}

module "env" {
  source   = "../modules/app-env"
  for_each = local.apps

  service = {
    name    = each.value.svc
    version = local.artifact_version[local.meta[each.value.svc].artifact]
    commit  = local.artifact_commit[local.meta[each.value.svc].artifact]
    env     = local.env_name
    team    = local.meta[each.value.svc].team
    owner   = local.meta[each.value.svc].owner
    domain  = local.meta[each.value.svc].domain
    tier    = local.meta[each.value.svc].tier
    region  = local.as_loc
  }
  runtime            = local.meta[each.value.svc].runtime
  architecture       = "appservice"
  telemetry          = var.obs_telemetry_transport
  identity_client_id = local.ids[each.value.svc].client_id
  faults = {
    enabled         = var.settings.faults_enabled
    token_secret_id = lookup(var.foundation_identity.secret_ids, "fault-token", null)
  }
  port               = each.value.port
  log_level          = var.settings.log_level
  trace_sample_ratio = var.settings.trace_sample_ratio
  extra_env          = each.value.env
}

module "app" {
  source   = "../modules/web-app"
  for_each = local.apps

  name                = "${local.prefix}-app-${each.value.short}-${local.env_name}-${local.suffix}"
  resource_group_name = local.rg
  location            = local.as_loc
  tags                = merge(local.tags, { service = each.value.svc, version = local.artifact_version[local.meta[each.value.svc].artifact] })
  service_plan        = { id = each.value.plan.id, sku = each.value.plan.sku }
  os_type             = each.value.os
  mode                = each.value.mode
  stack               = each.value.os == "Windows" ? { dotnet_version = "v10.0" } : { python_version = "3.13" }
  image               = each.value.mode == "container" ? try(var.artifacts[local.meta[each.value.svc].artifact].image, null) : null
  identity            = { id = local.ids[each.value.svc].id, client_id = local.ids[each.value.svc].client_id }
  # Code apps run the zip mounted read-only (deployed by scripts/deploy-zip.sh to the staging slot).
  app_settings          = merge(module.env[each.key].app_settings, each.value.mode == "code" ? { WEBSITE_RUN_FROM_PACKAGE = "1" } : {})
  integration_subnet_id = local.as.integration_subnet_id
  health_check_path     = "/healthz"
  private_endpoint      = local.pe
  allowed_ip_ranges     = var.settings.allowed_ip_ranges
  staging_slot          = var.settings.inventory.staging_slot
}
