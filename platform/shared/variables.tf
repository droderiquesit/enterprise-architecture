# environment + upstream contract variables (ADR-0001 §5, §6). Root settings follow below.
variable "environment" {
  description = "Environment globals rendered by tools/config/render.py (ADR-0001 §6)."
  type = object({
    name            = string
    location        = string
    subscription_id = string
    tenant_id       = string
    name_prefix     = string
    owner           = string
    team            = string
    cost_center     = string
    expires_on      = string
    tags            = map(string)
  })
}

variable "foundation_network" {
  description = "foundation-network contract v1 (only the fields this root uses)."
  type = object({
    resource_group_name = string
    location            = string
    subnets = map(object({
      id             = string
      name           = string
      address_prefix = string
    }))
    private_dns_zones = optional(map(object({
      id   = string
      name = string
    })), {})
  })
}

variable "foundation_identity" {
  description = "foundation-identity contract v1 (only the fields this root uses)."
  type = object({
    identities = map(object({
      id           = string
      principal_id = string
      client_id    = string
      name         = string
    }))
  })
}

variable "settings" {
  description = "platform-shared settings (environments/<env>/environment.yaml components.platform-shared)."
  type = object({
    # Container registry. Basic/Standard cannot disable public network access or use Private Link;
    # they are reachable publicly but accept Entra ID tokens only (admin user + anonymous pull off).
    # Premium enables private endpoint + public network access disabled (enterprise profile).
    acr_sku                           = optional(string, "Standard")
    acr_private_endpoint_enabled      = optional(bool, false)
    acr_public_network_access_enabled = optional(bool, true)
    acr_zone_redundancy_enabled       = optional(bool, false)
    acr_retention_days                = optional(number, 7) # untagged manifest retention (Premium only)
    # Promotion: downstream environments' build identities import images by digest from this registry.
    acr_pull_principal_ids = optional(list(string), [])
    # Identities (keys of foundation_identity.identities) granted AcrPull / AcrPush on the registry.
    acr_pull_identities = optional(list(string), [
      "hello-bff", "hello-orders-api", "hello-inventory-api", "hello-catalog-api", "hello-dbadapter",
      "hello-worker", "hello-durable", "hello-functions", "hello-jobs", "hello-partner-sim", "hello-traffic",
      "hello-frontend", "obs-collector", "obs-dbm", "aks-kubelet",
    ])
    acr_push_identities = optional(list(string), ["deploy-agent"])
    # Extra principals (e.g. the bootstrap `build` pipeline identity principal id) granted AcrPush.
    acr_push_principal_ids = optional(list(string), [])
    # Log Analytics: only for platform features that require a workspace (AKS Defender/Container
    # Insights opt-ins, ACA "log-analytics" destination). Application logs never go here (ADR §10).
    log_analytics_retention_days     = optional(number, 30)
    log_analytics_daily_quota_gb     = optional(number, 1)
    log_analytics_local_auth_enabled = optional(bool, false)
  })
  default = {}

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.settings.acr_sku)
    error_message = "acr_sku must be Basic, Standard or Premium."
  }
  validation {
    condition     = var.settings.acr_sku == "Premium" || (!var.settings.acr_private_endpoint_enabled && var.settings.acr_public_network_access_enabled)
    error_message = "Private endpoints and disabling public network access require acr_sku = \"Premium\"."
  }
  validation {
    condition     = var.settings.log_analytics_retention_days >= 30 && var.settings.log_analytics_retention_days <= 730
    error_message = "log_analytics_retention_days must be between 30 and 730."
  }
  validation {
    condition     = var.settings.log_analytics_daily_quota_gb == -1 || var.settings.log_analytics_daily_quota_gb >= 0.023
    error_message = "log_analytics_daily_quota_gb must be -1 (unlimited) or >= 0.023."
  }
}
