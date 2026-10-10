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
  description = "foundation-identity contract v2 (only the fields this root uses)."
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
  description = "platform-appservice settings (environment.yaml components.platform-appservice)."
  type = object({
    # Linux code/container plan: hello-dbadapter-mysql, hello-catalog-api (container, optional) and
    # Functions on a Dedicated plan (hello-functions cache-warmer). P0v3 = smallest SKU with slots + VNet integration.
    linux_plan = optional(object({
      enabled        = optional(bool, true)
      sku            = optional(string, "P0v3")
      worker_count   = optional(number, 1)
      zone_balancing = optional(bool, false)
    }), {})
    # Windows code plan: hello-inventory-api (.NET 10).
    windows_plan = optional(object({
      enabled        = optional(bool, true)
      sku            = optional(string, "P0v3")
      worker_count   = optional(number, 1)
      zone_balancing = optional(bool, false)
    }), {})
    # Windows containers need Premium v3 (P1v3 is the smallest Windows-container SKU) - off by default.
    windows_container_plan = optional(object({
      enabled        = optional(bool, false)
      sku            = optional(string, "P1v3")
      worker_count   = optional(number, 1)
      zone_balancing = optional(bool, false)
    }), {})
    # Logic Apps Standard (Workflow Standard WS1, elastic) + its runtime storage account.
    logicapps_plan = optional(object({
      enabled             = optional(bool, false)
      sku                 = optional(string, "WS1")
      max_elastic_workers = optional(number, 3)
      storage_replication = optional(string, "LRS")
      storage_private     = optional(bool, true)
    }), {})
  })
  default = {}

  validation {
    condition = alltrue([for p in [var.settings.linux_plan, var.settings.windows_plan, var.settings.windows_container_plan] :
    can(regex("^(B[1-3]|S[1-3]|P[0-3]v[34]|P[1-5]mv[34]|I[1-6]v2)$", p.sku)) && p.worker_count >= 1 && p.worker_count <= 10])
    error_message = "plan SKUs must be B/S/Pv3/Pv4/Pmv3/Pmv4/Iv2 and worker_count 1-10."
  }
  validation {
    condition     = can(regex("^P[1-5]m?v[34]$", var.settings.windows_container_plan.sku))
    error_message = "Windows containers require a Premium v3/v4 SKU of at least P1."
  }
  validation {
    condition     = contains(["WS1", "WS2", "WS3"], var.settings.logicapps_plan.sku) && var.settings.logicapps_plan.max_elastic_workers >= 1 && var.settings.logicapps_plan.max_elastic_workers <= 20
    error_message = "logicapps_plan.sku must be WS1-WS3 and max_elastic_workers 1-20."
  }
}
