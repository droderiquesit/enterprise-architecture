# hello-frontend on Azure Static Web Apps. Terraform owns the SWA resource and RENDERS the runtime
# configuration (config.json + staticwebapp.config.json); the content upload is a pipeline step
# (applications/deployments/scripts/deploy-swa.sh) that fetches the deployment token at deploy time with
# `az staticwebapp secrets list` - the token is never a Terraform output or state value of this root.
resource "azurerm_resource_group" "this" {
  name     = local.names.resource_group
  location = local.location
  tags     = local.tags
}

resource "azurerm_static_web_app" "this" {
  #checkov:skip=CKV_AZURE_244:Free SKU has no private endpoint support; the content is public static files by design.
  name                               = local.names.static_web_app
  resource_group_name                = azurerm_resource_group.this.name
  location                           = var.settings.swa_location
  sku_tier                           = var.settings.sku
  sku_size                           = var.settings.sku
  configuration_file_changes_enabled = true
  preview_environments_enabled       = false
  # Azure tags = the frontend's tag-policy identity (Datadog Azure integration imports them onto the SWA metrics)
  tags = merge(local.tags, module.rum_tags.azure_tags)
}

# Tag policy (observability/modules/tagging): the same tag set on the SWA resource and in the RUM SDK global context.
module "meta" {
  source = "../modules/service-meta"
}

module "rum_tags" {
  source = "../../../observability/modules/tagging"
  identity = {
    env         = local.env_name
    service     = "hello-frontend"
    version     = local.version
    team        = module.meta.services["hello-frontend"].team
    owner       = module.meta.services["hello-frontend"].owner
    domain      = module.meta.services["hello-frontend"].domain
    tier        = module.meta.services["hello-frontend"].tier
    application = "enterprise-hello"
    region      = local.location
    managed_by  = "terraform"
    component   = "deploy-frontend"
  }
}

locals {
  artifact = "svc-frontend"
  version  = lookup(local.artifact_version, local.artifact, "unknown")

  aca_origin = try(var.deploy_core_aca.public_api.origin, null)
  aks_origin = try(var.deploy_core_aks.public_api.origin, null)
  api_origin = coalesce(
    var.settings.api_origin,
    var.settings.prefer_api == "aca" ? local.aca_origin : local.aks_origin,
    local.aca_origin, local.aks_origin, "https://api.invalid",
  )
  api_configured = var.settings.api_origin != null || local.aca_origin != null || local.aks_origin != null

  rum      = var.obs_prereqs.rum.applications[var.settings.rum_app_key]
  rum_site = coalesce(local.rum.site, var.obs_prereqs.datadog_site)
  # Browser intake host per Datadog site: datadoghq.com -> browser-intake-datadoghq.com,
  # us3.datadoghq.com -> browser-intake-us3-datadoghq.com, datadoghq.eu -> browser-intake-datadoghq.eu.
  site_parts    = split(".", local.rum_site)
  intake_origin = length(local.site_parts) > 2 ? "https://browser-intake-${local.site_parts[0]}-${join(".", slice(local.site_parts, 1, length(local.site_parts)))}" : "https://browser-intake-${local.rum_site}"

  tracing_urls = distinct(concat([local.api_origin], var.settings.extra_tracing))

  site_url = coalesce(
    try(var.foundation_edge.front_door.enabled ? "https://${var.foundation_edge.front_door.endpoint_hostname}" : null, null),
    "https://${azurerm_static_web_app.this.default_host_name}",
  )

  # /config.json loaded by the SPA at startup (applications/services/frontend). Non-secret: the RUM client
  # token is a browser-facing credential by design (obs-prereqs README).
  config = {
    env        = local.env_name
    service    = "hello-frontend"
    version    = local.version
    apiBaseUrl = local.api_origin
    rum = {
      applicationId           = local.rum.application_id
      clientToken             = local.rum.client_token
      site                    = local.rum_site
      service                 = coalesce(local.rum.service, "hello-frontend")
      env                     = local.env_name
      version                 = local.version
      sessionSampleRate       = local.rum.session_sample_rate
      sessionReplaySampleRate = 0
      trackUserInteractions   = local.rum.track_user_interactions
      defaultPrivacyLevel     = "mask-user-input"
      # First-party API origins only; the SPA injects W3C tracecontext headers there (ADR-0001 §10; config.ts
      # tracingMatchers - it has no propagator setting, so none is rendered here)
      allowedTracingUrls = local.tracing_urls
      # tag policy keys besides env/service/version: datadogRum.setGlobalContextProperty(k, v) for each entry
      globalContext = module.rum_tags.rum_global_context
    }
  }

  csp = join("; ", [
    "default-src 'self'",
    "script-src 'self'",
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data:",
    "connect-src 'self' ${join(" ", local.tracing_urls)} ${local.intake_origin}",
    "worker-src 'self' blob:",
    "frame-ancestors 'none'",
    "base-uri 'self'",
    "object-src 'none'",
  ])

  # staticwebapp.config.json: SPA fallback, security headers, no-cache for runtime config, and rewrites so the
  # common smoke contract (/healthz, /readyz, /version) works on a static site (files written by deploy-swa.sh).
  swa_config = {
    navigationFallback = {
      rewrite = "/index.html"
      exclude = ["/assets/*", "/config.json", "/version.json", "/healthz.json"]
    }
    routes = [
      { route = "/config.json", headers = { "Cache-Control" = "no-store" } },
      { route = "/healthz", rewrite = "/healthz.json" },
      { route = "/readyz", rewrite = "/healthz.json" },
      { route = "/version", rewrite = "/version.json" },
    ]
    globalHeaders = {
      "Content-Security-Policy"   = local.csp
      "X-Content-Type-Options"    = "nosniff"
      "Referrer-Policy"           = "strict-origin-when-cross-origin"
      "Strict-Transport-Security" = "max-age=31536000"
      "Permissions-Policy"        = "camera=(), microphone=(), geolocation=()"
    }
    mimeTypes = { ".json" = "application/json" }
  }

  version_doc = {
    service    = "hello-frontend"
    version    = local.version
    commit     = lookup(local.artifact_commit, local.artifact, "unknown")
    build_time = "n/a"
    runtime    = "static-web-apps"
  }
}

check "api_origin_known" {
  assert {
    condition     = local.api_configured
    error_message = "No API origin: deploy-core-aca/deploy-core-aks contracts are absent and settings.api_origin is unset (config.json points to https://api.invalid)."
  }
}
