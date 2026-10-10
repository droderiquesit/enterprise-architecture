# Enterprise Hello core services on Azure Container Apps (minimal profile):
#   hello-bff (external ingress when the environment is external), hello-orders-api, hello-catalog-api (internal).
module "meta" {
  source = "../modules/service-meta"
}

resource "azurerm_resource_group" "this" {
  name     = local.names.resource_group
  location = local.location
  tags     = local.tags
}

locals {
  ids      = var.foundation_identity.identities
  meta     = module.meta.services
  aca      = var.platform_containerapps
  external = local.aca.ingress_mode == "external"

  short = { "hello-bff" = "bff", "hello-orders-api" = "orders", "hello-catalog-api" = "catalog" }
  apps  = { for k, a in var.settings.apps : k => a if a.enabled }

  # Internal service URLs inside the environment (https://<app>.internal.<default domain>).
  internal_url = { for k, s in local.short : k => "https://${local.prefix}-ca-${s}-${local.env_name}.internal.${local.aca.default_domain}" }

  sql_db  = var.platform_db_sql.databases["orders"]
  pg_db   = var.platform_db_postgresql.databases["catalog"]
  redis   = var.platform_db_redis
  sb_fqdn = var.platform_messaging.fqdn

  service_env = {
    "hello-bff" = merge(
      {
        CATALOG_API_URL      = local.internal_url["hello-catalog-api"]
        ORDERS_API_URL       = local.internal_url["hello-orders-api"]
        ADAPTERS_JSON        = jsonencode(var.settings.adapters)
        CORS_ALLOWED_ORIGINS = join(",", var.settings.cors_allowed_origins)
        AUTH_MODE            = var.settings.auth_mode
      },
      var.settings.inventory_api_url == null ? {} : { INVENTORY_API_URL = var.settings.inventory_api_url },
      var.settings.auth_mode == "entra" ? { ENTRA_TENANT_ID = var.environment.tenant_id, ENTRA_AUDIENCE = coalesce(var.settings.entra_audience, "api://hello-bff") } : {},
    )
    "hello-orders-api" = {
      SQL_CONNECTION_STRING    = "Server=tcp:${var.platform_db_sql.server.fqdn},${var.platform_db_sql.server.port};Database=${local.sql_db.name};Encrypt=True"
      SQL_USE_AZURE_CREDENTIAL = "true" # token from AzureCredentialFactory (workload/managed identity); no password
      CATALOG_API_URL          = local.internal_url["hello-catalog-api"]
      MESSAGING_MODE           = "servicebus"
      SERVICEBUS_FQDN          = local.sb_fqdn
      SERVICEBUS_TOPIC         = var.platform_messaging.topic.name
    }
    "hello-catalog-api" = merge(
      {
        PG_HOST           = var.platform_db_postgresql.server.fqdn
        PG_PORT           = tostring(var.platform_db_postgresql.server.port)
        PG_DATABASE       = local.pg_db.name
        PG_USER           = "hello-catalog-api"
        PG_AUTH           = "entra"
        CACHE_TTL_SECONDS = tostring(var.settings.redis_cache_ttl_seconds)
      },
      local.redis == null ? { REDIS_AUTH = "none" } : {
        REDIS_HOST                       = local.redis.cache.hostname
        REDIS_PORT                       = tostring(local.redis.cache.port)
        REDIS_AUTH                       = "entra"
      },
    )
  }
}

module "env" {
  source   = "../modules/app-env"
  for_each = local.apps

  service = {
    name    = each.key
    version = local.artifact_version[local.meta[each.key].artifact]
    commit  = local.artifact_commit[local.meta[each.key].artifact]
    env     = local.env_name
    team    = local.meta[each.key].team
    owner   = local.meta[each.key].owner
    domain  = local.meta[each.key].domain
    tier    = local.meta[each.key].tier
    region  = local.location
  }
  runtime            = local.meta[each.key].runtime
  architecture       = "aca"
  telemetry          = local.telemetry
  serverless_init    = { subscription_id = var.environment.subscription_id, resource_group = azurerm_resource_group.this.name }
  identity_client_id = local.ids[each.key].client_id
  faults = {
    enabled   = var.settings.faults_enabled
    token_ref = lookup(var.foundation_identity.secrets.refs, "fault-token", null)
  }
  log_level          = var.settings.log_level
  trace_sample_ratio = var.settings.trace_sample_ratio
  extra_env          = local.service_env[each.key]
}

module "app" {
  source   = "../modules/container-app"
  for_each = local.apps

  name                = "${local.prefix}-ca-${local.short[each.key]}-${local.env_name}"
  resource_group_name = azurerm_resource_group.this.name
  environment_id      = local.aca.environment_id
  tags                = merge(local.tags, { service = each.key, version = local.artifact_version[local.meta[each.key].artifact] }, module.env[each.key].azure_tags)
  identity            = { id = local.ids[each.key].id, client_id = local.ids[each.key].client_id }
  registry_server     = var.platform_shared.acr_login_server

  container = {
    name   = each.key
    image  = try(var.artifacts[local.meta[each.key].artifact].image, null)
    cpu    = each.value.cpu
    memory = each.value.memory
  }
  env           = module.env[each.key].env
  sidecar_patch = module.env[each.key].container_app_patch

  ingress = {
    external     = each.key == "hello-bff" && local.external
    target_port  = 8080
    cors_origins = each.key == "hello-bff" ? var.settings.cors_allowed_origins : []
  }
  scale = {
    min_replicas     = each.value.min_replicas
    max_replicas     = each.value.max_replicas
    http_concurrency = each.value.http_concurrency
  }
  revisions = {
    mode                     = var.settings.revision_mode
    latest_weight            = try(var.settings.traffic[each.key].latest_weight, 100)
    previous_revision_suffix = try(var.settings.traffic[each.key].previous_revision_suffix, null)
  }
}

check "artifacts_present" {
  assert {
    condition     = alltrue([for k in keys(local.apps) : try(var.artifacts[local.meta[k].artifact].image != null, false)])
    error_message = "Every enabled app needs a digest-pinned image in var.artifacts (svc-bff, svc-orders-api, svc-catalog-api)."
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
