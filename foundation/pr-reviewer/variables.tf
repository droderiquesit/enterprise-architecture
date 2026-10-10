# environment + upstream contract variables (ADR-0001 §5, §6).
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

variable "foundation_identity" {
  description = "foundation-identity contract v2 (only the DSV fields this root uses). The pr-reviewer identity itself is created HERE."
  type = object({
    secrets = object({
      tenant        = string
      tld           = string
      base_url      = string
      base_path     = string
      auth_provider = string
    })
  })
}

variable "foundation_network" {
  description = "foundation-network contract v1 (optional; only needed for settings.network_mode = \"vnet\")."
  type = object({
    subnets = map(object({
      id = string
    }))
    private_dns_zones = optional(map(object({
      id = string
    })), {})
    egress = optional(object({
      public_ips = optional(list(string), [])
    }), {})
  })
  default = null
}

variable "settings" {
  description = "foundation-pr-reviewer settings (environment.yaml components.foundation-pr-reviewer). See README."
  type = object({
    # public: Flex app without VNet integration; its runtime storage is reachable publicly but Entra-only (no keys).
    # vnet:   Flex VNet integration (flex-integration subnet) + storage private endpoints (blob, queue, table); the app's
    #         INBOUND endpoint stays public (Azure DevOps service hooks need a public HTTPS URL).
    network_mode = optional(string, "public")
    # Inbound restriction of the function endpoint to the AzureDevOps service tag (+ allowed_ip_ranges, e.g. deploy
    # agent egress IPs for smoke tests). The webhook secret authenticates requests either way.
    restrict_to_azure_devops  = optional(bool, true)
    allowed_ip_ranges         = optional(list(string), [])
    allow_deploy_agent_egress = optional(bool, true)
    maximum_instance_count    = optional(number, 40)
    instance_memory_in_mb     = optional(number, 512)
    storage_replication       = optional(string, "LRS")
    blob_retention_days       = optional(number, 7)
    queue_name                = optional(string, "pr-review")
    # Azure DevOps target of the reviewer (trusted config; the webhook allowlist).
    ado = optional(object({
      organization   = optional(string, "example-org")
      project        = optional(string, "enterprise-hello")
      project_id     = optional(string, "00000000-0000-0000-0000-000000000000")
      repository_ids = optional(list(string), ["00000000-0000-0000-0000-000000000000"])
      account_ids    = optional(list(string), [])
      reviewer_id    = optional(string, "") # ADO identity id of the MI after it is added to the org (else connectionData)
    }), {})
    webhook_username = optional(string, "eh-review")
    # DSV secret names (paths /<prefix>/<env>/<name>, element value). Values are set by operators (dsv CLI).
    webhook_secret_name    = optional(string, "pr-reviewer-webhook-secret")
    ai_enabled             = optional(bool, false)
    anthropic_api_key_name = optional(string, "anthropic-api-key")
    otlp_endpoint          = optional(string, "")
    dsv_marker             = optional(string, "managed-by:foundation-pr-reviewer")
  })
  default = {}

  validation {
    condition     = contains(["public", "vnet"], var.settings.network_mode)
    error_message = "settings.network_mode must be public or vnet."
  }
  validation {
    condition     = var.settings.maximum_instance_count >= 1 && var.settings.maximum_instance_count <= 1000 && contains([512, 2048, 4096], var.settings.instance_memory_in_mb)
    error_message = "maximum_instance_count 1-1000; instance_memory_in_mb one of 512, 2048, 4096."
  }
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{2,62}$", var.settings.queue_name))
    error_message = "queue_name must be a valid storage queue name."
  }
  validation {
    condition     = alltrue([for r in concat([var.settings.ado.project_id], var.settings.ado.repository_ids) : can(regex("^[0-9a-fA-F-]{36}$", r))])
    error_message = "ado.project_id and ado.repository_ids must be GUIDs."
  }
  validation {
    condition     = can(regex("^[a-z0-9:-]{8,40}$", var.settings.dsv_marker)) && var.settings.dsv_marker != "managed-by:foundation-secrets"
    error_message = "dsv_marker must be 8-40 chars of [a-z0-9:-] and differ from foundation-secrets' marker."
  }
}
