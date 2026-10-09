variable "environment" {
  description = "Environment globals (ADR-0001 §6)."
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
  description = "foundation-network contract v1 (fields used here)."
  type = object({
    topology            = optional(string, "single-spoke")
    hub_vnet_id         = optional(string)
    spoke_vnet_id       = string
    spoke_address_space = optional(list(string), ["10.41.0.0/16"])
    subnets = map(object({
      id      = string
      vnet_id = optional(string)
    }))
    egress = optional(object({
      type                = string
      firewall_private_ip = optional(string)
    }))
  })
}

variable "foundation_identity" {
  description = "foundation-identity contract v1 (fields used here)."
  type = object({
    key_vault_id = string
  })
}

variable "settings" {
  description = "Component settings (components.foundation-edge). Everything is off by default. See README."
  type = object({
    app_gateway = optional(object({
      enabled      = optional(bool, false)
      min_capacity = optional(number, 0)
      max_capacity = optional(number, 2)
      zones        = optional(list(string), [])
      waf_mode     = optional(string, "Prevention")
      # Versionless Key Vault *secret* id of the TLS certificate (https://<vault>.vault.azure.net/secrets/<cert>).
      key_vault_certificate_secret_id = optional(string, "")
      listener_host_name              = optional(string)
      backend_fqdns                   = optional(list(string), [])
      backend_port                    = optional(number, 443)
      backend_protocol                = optional(string, "Https")
      probe_path                      = optional(string, "/healthz")
    }), {})

    front_door = optional(object({
      enabled  = optional(bool, false)
      sku_name = optional(string, "Standard_AzureFrontDoor") # Premium_AzureFrontDoor for managed WAF rules + Private Link origins
      waf_mode = optional(string, "Prevention")
      origins = optional(list(object({
        name               = string
        host_name          = string
        origin_host_header = optional(string)
        # Premium only: private link origin (App Service, internal LB PLS, storage, APIM, ACA environment ...).
        private_link = optional(object({
          target_id   = string
          location    = string
          target_type = optional(string) # e.g. "sites", "blob", "managedEnvironments"; null for Private Link Service
        }))
      })), [])
      probe_path = optional(string, "/healthz")
    }), {})

    apim = optional(object({
      enabled          = optional(bool, false)
      sku_name         = optional(string, "StandardV2_1") # BasicV2_1 | StandardV2_1 | PremiumV2_1 | Developer_1
      publisher_name   = optional(string, "Enterprise Hello Lab")
      publisher_email  = optional(string)      # default environment.owner
      vnet_integration = optional(bool, false) # StandardV2/PremiumV2 outbound integration into the `apim` subnet
    }), {})

    firewall = optional(object({
      enabled  = optional(bool, false)
      sku_tier = optional(string, "Basic") # Basic | Standard
      zones    = optional(list(string), [])
      # Outbound application rules from the spoke (HTTPS). Keep tight; extend per component README.
      allowed_fqdns = optional(list(string), [
        "*.datadoghq.com", "*.datadoghq.eu", "*.azurecr.io", "*.blob.core.windows.net", "mcr.microsoft.com", "*.data.mcr.microsoft.com",
        "management.azure.com", "login.microsoftonline.com", "*.ubuntu.com", "packages.microsoft.com", "dev.azure.com", "*.dev.azure.com",
        "*.vsassets.io", "vstsagentpackage.azureedge.net", "*.vstoken.visualstudio.com", "github.com", "*.githubusercontent.com",
        "registry-1.docker.io", "auth.docker.io", "production.cloudflare.docker.com", "pypi.org", "files.pythonhosted.org",
        "api.nuget.org", "registry.npmjs.org",
      ])
      allowed_fqdn_tags = optional(list(string), ["AzureKubernetesService"])
    }), {})

    bastion = optional(object({
      enabled = optional(bool, false)
      sku     = optional(string, "Developer") # Developer (free, no subnet/public IP, limited regions) | Basic | Standard
    }), {})
  })
  default = {}

  validation {
    condition     = contains(["Standard_AzureFrontDoor", "Premium_AzureFrontDoor"], var.settings.front_door.sku_name)
    error_message = "front_door.sku_name must be Standard_AzureFrontDoor or Premium_AzureFrontDoor."
  }
  validation {
    condition     = var.settings.front_door.sku_name == "Premium_AzureFrontDoor" || alltrue([for o in var.settings.front_door.origins : o.private_link == null])
    error_message = "Private Link origins require Premium_AzureFrontDoor."
  }
  validation {
    condition     = can(regex("^(BasicV2|StandardV2|PremiumV2|Developer|Basic|Standard|Premium)_[0-9]+$", var.settings.apim.sku_name))
    error_message = "apim.sku_name must look like StandardV2_1."
  }
  validation {
    condition     = contains(["Basic", "Standard"], var.settings.firewall.sku_tier)
    error_message = "firewall.sku_tier must be Basic or Standard (Premium is out of scope for the lab)."
  }
  validation {
    condition     = contains(["Developer", "Basic", "Standard"], var.settings.bastion.sku)
    error_message = "bastion.sku must be Developer, Basic or Standard."
  }
  validation {
    condition     = !var.settings.app_gateway.enabled || (can(regex("^https://[^/]+/secrets/[^/]+/?$", var.settings.app_gateway.key_vault_certificate_secret_id)) && length(var.settings.app_gateway.backend_fqdns) > 0)
    error_message = "app_gateway requires key_vault_certificate_secret_id (versionless secret id) and at least one backend FQDN."
  }
  validation {
    condition     = !var.settings.front_door.enabled || length(var.settings.front_door.origins) > 0
    error_message = "front_door requires at least one origin."
  }
}
