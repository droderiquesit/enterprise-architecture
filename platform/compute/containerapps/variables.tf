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
    spoke_vnet_id       = string
    hub_vnet_id         = optional(string)
    subnets = map(object({
      id             = string
      name           = string
      address_prefix = string
    }))
  })
}

variable "platform_shared" {
  description = "platform-shared contract v1 (only the fields this root uses)."
  type = object({
    acr_id                     = string
    acr_login_server           = string
    log_analytics_workspace_id = string
  })
}

variable "settings" {
  description = "platform-containerapps settings (environment.yaml components.platform-containerapps)."
  type = object({
    # "external": VNet-integrated environment with a public static IP; each app chooses its own
    #             ingress (only hello-bff/frontend are external, everything else internal-only).
    #             Default because the minimal profile has no Application Gateway / Front Door.
    # "internal": internal load balancer only (enterprise); public entry via foundation-edge AppGW.
    ingress_mode            = optional(string, "external")
    zone_redundancy_enabled = optional(bool, false)
    mutual_tls_enabled      = optional(bool, false)
    # "azure-monitor": system/console logs only flow where diagnostic settings (obs-diagnostics) send
    # them. "log-analytics" uses the platform-shared workspace (requires workspace shared keys).
    logs_destination = optional(string, "azure-monitor")
    dedicated_profile = optional(object({
      enabled   = optional(bool, true)
      name      = optional(string, "dedicated-d4")
      type      = optional(string, "D4")
      min_count = optional(number, 0)
      max_count = optional(number, 1)
    }), {})
    # Internal mode: private DNS zone named after the environment default domain (wildcard + apex
    # A records -> static IP), linked to the spoke (and hub) VNets so apps resolve inside the VNet.
    private_dns_enabled  = optional(bool, true)
    extra_dns_vnet_links = optional(map(string), {})
  })
  default = {}

  validation {
    condition     = contains(["external", "internal"], var.settings.ingress_mode)
    error_message = "ingress_mode must be external or internal."
  }
  validation {
    condition     = contains(["azure-monitor", "log-analytics", "none"], var.settings.logs_destination)
    error_message = "logs_destination must be azure-monitor, log-analytics or none."
  }
  validation {
    condition     = contains(["D4", "D8", "D16", "D32", "E4", "E8", "E16", "E32"], var.settings.dedicated_profile.type)
    error_message = "dedicated_profile.type must be a general-purpose (D*) or memory-optimised (E*) profile."
  }
  validation {
    condition     = var.settings.dedicated_profile.min_count >= 0 && var.settings.dedicated_profile.max_count >= max(1, var.settings.dedicated_profile.min_count) && var.settings.dedicated_profile.max_count <= 10
    error_message = "dedicated_profile: 0 <= min_count <= max_count <= 10 and max_count >= 1."
  }
}
