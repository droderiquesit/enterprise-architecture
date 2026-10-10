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

variable "platform_shared" {
  description = "platform-shared contract v1 (only the fields this root uses)."
  type = object({
    acr_id                     = string
    acr_login_server           = string
    log_analytics_workspace_id = string
  })
}

variable "settings" {
  description = "platform-batch settings (environment.yaml components.platform-batch)."
  type = object({
    identity                      = optional(string, "hello-jobs") # pool + auto-storage node identity
    public_network_access_enabled = optional(bool, false)          # false => batchAccount + nodeManagement private endpoints
    job_submitter_identities      = optional(list(string), ["deploy-agent", "hello-jobs"])
    pool = optional(object({
      name                = optional(string, "hello-jobs")
      vm_size             = optional(string, "Standard_D2s_v5")
      max_dedicated_nodes = optional(number, 2)
      max_tasks_per_node  = optional(number, 1)
      node_agent_sku_id   = optional(string, "batch.node.ubuntu 24.04")
      image = optional(object({
        publisher = optional(string, "canonical")
        offer     = optional(string, "ubuntu-24_04-lts")
        sku       = optional(string, "server")
        version   = optional(string, "latest")
      }), {})
      python_version = optional(string, "3.13")
    }), {})
    storage_replication = optional(string, "LRS")
  })
  default = {}

  validation {
    condition     = var.settings.pool.max_dedicated_nodes >= 1 && var.settings.pool.max_dedicated_nodes <= 10
    error_message = "pool.max_dedicated_nodes must be 1-10 (lab ceiling)."
  }
  validation {
    # Interpolated into the start task's shell command line.
    condition     = can(regex("^3\\.[0-9]{1,2}$", var.settings.pool.python_version))
    error_message = "pool.python_version must look like 3.13."
  }
}
