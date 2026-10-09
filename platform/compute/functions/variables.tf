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
    egress = optional(object({
      type       = string
      public_ips = optional(list(string), [])
    }), { type = "nat-gateway", public_ips = [] })
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
  description = "platform-functions settings (environment.yaml components.platform-functions)."
  type = object({
    # Private endpoints for runtime storage (VNet-integrated plans only). When false the accounts
    # stay Entra-only but reachable publicly (no shared keys either way).
    private_endpoints_enabled = optional(bool, true)
    storage_replication       = optional(string, "LRS")
    # Flex Consumption: one app per plan (FC1). key => {identity (foundation key), storage suffix}.
    flex_apps = optional(map(object({
      identity       = string
      storage_suffix = string
      })), {
      durable = { identity = "hello-durable", storage_suffix = "dur" }
    })
    # Durable Functions runtime state (task hub) - separate from the business database (SQL
    # fulfillment schema) and from the host/deployment storage.
    durable_storage = optional(object({
      enabled        = optional(bool, true)
      identity       = optional(string, "hello-durable")
      storage_suffix = optional(string, "dts")
    }), {})
    # Elastic Premium (Linux) for hello-functions (Service Bus audit trigger). Off by default (cost).
    premium_plan = optional(object({
      enabled             = optional(bool, false)
      sku                 = optional(string, "EP1")
      max_elastic_workers = optional(number, 3)
      identity            = optional(string, "hello-functions")
      storage_suffix      = optional(string, "ep")
    }), {})
    # Windows Consumption (Y1) for the .NET isolated Reconciliation function. Legacy-but-supported;
    # Linux Consumption retires 2028-09-30 and is not offered. No VNet integration => its storage
    # is public (Entra-only, shared keys off; app runs from a package URL without Azure Files).
    consumption_windows_plan = optional(object({
      enabled        = optional(bool, false)
      identity       = optional(string, "hello-durable")
      storage_suffix = optional(string, "y1")
    }), {})
    # Durable Task Scheduler (managed backend, azapi - no azurerm resource yet).
    durable_task_scheduler = optional(object({
      enabled          = optional(bool, false)
      sku              = optional(string, "Consumption")
      capacity         = optional(number)
      task_hub         = optional(string, "hello-durable")
      identity         = optional(string, "hello-durable")
      ip_allowlist     = optional(list(string), [])
      allow_egress_ips = optional(bool, true)
    }), {})
  })
  default = {}

  validation {
    condition     = alltrue([for a in values(var.settings.flex_apps) : can(regex("^[a-z0-9]{1,6}$", a.storage_suffix))])
    error_message = "storage_suffix must be 1-6 lowercase alphanumerics."
  }
  validation {
    condition     = contains(["EP1", "EP2", "EP3"], var.settings.premium_plan.sku) && var.settings.premium_plan.max_elastic_workers >= 1 && var.settings.premium_plan.max_elastic_workers <= 20
    error_message = "premium_plan.sku must be EP1-EP3 and max_elastic_workers 1-20."
  }
  validation {
    condition     = contains(["Consumption", "Dedicated"], var.settings.durable_task_scheduler.sku)
    error_message = "durable_task_scheduler.sku must be Consumption or Dedicated."
  }
}
