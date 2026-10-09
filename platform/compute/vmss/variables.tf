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
  description = "platform-vmss settings (environment.yaml components.platform-vmss)."
  type = object({
    admin_username       = optional(string, "azureuser")
    admin_ssh_public_key = optional(string) # public key; null => random break-glass password in state only
    os_disk_type         = optional(string, "StandardSSD_LRS")
    image = optional(object({
      publisher = optional(string, "Canonical")
      offer     = optional(string, "ubuntu-24_04-lts")
      sku       = optional(string, "server")
      version   = optional(string, "latest")
    }), {})
    # Flexible orchestration: hello-worker (Service Bus notifications consumer).
    flexible = optional(object({
      enabled       = optional(bool, true)
      sku           = optional(string, "Standard_B2s_v2")
      identity      = optional(string, "hello-worker")
      instances     = optional(number, 1)
      min_instances = optional(number, 1)
      max_instances = optional(number, 3)
      zones         = optional(list(string), [])
    }), {})
    # Uniform orchestration: hello-dbadapter-sqlvm. Manual upgrade policy (see README).
    uniform = optional(object({
      enabled       = optional(bool, true)
      sku           = optional(string, "Standard_B2s_v2")
      identity      = optional(string, "hello-dbadapter")
      instances     = optional(number, 1)
      min_instances = optional(number, 1)
      max_instances = optional(number, 2)
      zones         = optional(list(string), [])
    }), {})
    autoscale = optional(object({
      enabled            = optional(bool, true)
      scale_out_cpu      = optional(number, 70)
      scale_in_cpu       = optional(number, 25)
      notification_email = optional(list(string), [])
    }), {})
    encryption_at_host_enabled = optional(bool, false)
  })
  default = {}

  validation {
    condition = alltrue([for s in [var.settings.flexible, var.settings.uniform] :
    s.min_instances >= 0 && s.min_instances <= s.instances && s.instances <= s.max_instances && s.max_instances <= 10])
    error_message = "VMSS: 0 <= min_instances <= instances <= max_instances <= 10 (lab ceiling)."
  }
  validation {
    condition     = var.settings.autoscale.scale_in_cpu < var.settings.autoscale.scale_out_cpu
    error_message = "scale_in_cpu must be lower than scale_out_cpu."
  }
}
