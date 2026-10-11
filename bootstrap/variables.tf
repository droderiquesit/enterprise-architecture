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

variable "settings" {
  description = "Bootstrap settings (components.bootstrap in environments/<env>/environment.yaml). See README."
  type = object({
    # ---------------------------------------------------------------- state storage
    replication_type = optional(string, "ZRS") # Standard_ZRS by default; GZRS/RAGZRS for regional DR
    # "Enabled" (phase 1, firewall default Deny) or "Disabled" + private_endpoint (phase 2); README "Network phases".
    public_network_access = optional(string, "Enabled")
    operator_ip_ranges    = optional(list(string), []) # public IPs/CIDRs of operators / temporary hosted-agent IPs
    agent_subnet_ids      = optional(list(string), []) # deploy-agents subnet (needs Microsoft.Storage service endpoint)
    private_endpoint = optional(object({
      subnet_id           = string # foundation-network contract subnets["private-endpoints"].id
      private_dns_zone_id = string # foundation-network contract private_dns_zones["blob"].id
    }))
    blob_soft_delete_days      = optional(number, 30)
    container_soft_delete_days = optional(number, 30)
    change_feed_retention_days = optional(number, 90)
    lock_enabled               = optional(bool, true)
    # Operators (prefer a group) get data-plane access for `init -migrate-state` and state restore (Owner has none).
    operator_principal_ids = optional(list(string), [])
    # Downstream environments' pipeline identities that promote this environment's artifacts (README "Promotion readers").
    promotion_reader_principal_ids = optional(list(string), [])

    # ---------------------------------------------------------------- pipeline identities
    create_validate_identity = optional(bool, true)
    # Issuer + subject copied from each Azure DevOps service connection (README "Federated credentials").
    federated_credentials = optional(list(object({
      identity  = string # plan | apply | build | validate
      name      = string
      issuer    = string
      subject   = string
      audiences = optional(list(string), ["api://AzureADTokenExchange"])
    })), [])
    # "constrained": RBAC Administrator that cannot grant Owner/UAA/RBAC Admin; "allowlist": only apply_role_allowlist GUIDs.
    apply_rbac_mode      = optional(string, "constrained")
    apply_role_allowlist = optional(list(string), [])
    # foundation-governance assigns Azure Policy: Contributor cannot, so apply also gets Resource Policy Contributor.
    apply_policy_contributor = optional(bool, true)
    # Extra subscription-scope roles for the plan identity (e.g. a narrow listKeys custom role); default Reader only.
    plan_extra_role_names = optional(list(string), [])

    # ---------------------------------------------------------------- Datadog Azure integration (optional)
    datadog_integration = optional(object({
      enabled      = optional(bool, false)
      display_name = optional(string)
      owners       = optional(list(string), []) # Entra object IDs of app owners
      # Datadog "Secretless Auth" issuer/subject; empty = client secret created out-of-band into DSV, never by Terraform.
      federated_issuer  = optional(string, "")
      federated_subject = optional(string, "")
      # Monitoring Reader on these besides the lab subscription.
      extra_subscription_ids = optional(list(string), [])
    }), {})
  })
  default = {}

  validation {
    condition     = contains(["LRS", "ZRS", "GRS", "GZRS", "RAGRS", "RAGZRS"], var.settings.replication_type)
    error_message = "replication_type must be one of LRS, ZRS, GRS, GZRS, RAGRS, RAGZRS."
  }
  validation {
    condition     = contains(["Enabled", "Disabled"], var.settings.public_network_access)
    error_message = "public_network_access must be Enabled or Disabled."
  }
  validation {
    condition     = var.settings.public_network_access == "Enabled" || var.settings.private_endpoint != null
    error_message = "Disabling public network access requires settings.private_endpoint (otherwise nothing can reach the state)."
  }
  validation {
    condition     = alltrue([for f in var.settings.federated_credentials : contains(["plan", "apply", "build", "validate"], f.identity) && can(regex("^https://", f.issuer)) && length(f.subject) > 0])
    error_message = "federated_credentials entries need identity in plan|apply|build|validate, an https issuer and a subject."
  }
  validation {
    condition     = contains(["constrained", "allowlist"], var.settings.apply_rbac_mode)
    error_message = "apply_rbac_mode must be constrained or allowlist."
  }
  validation {
    condition     = var.settings.apply_rbac_mode != "allowlist" || length(var.settings.apply_role_allowlist) > 0
    error_message = "apply_rbac_mode = allowlist requires apply_role_allowlist (role definition GUIDs)."
  }
  validation {
    condition     = var.settings.blob_soft_delete_days >= 7 && var.settings.container_soft_delete_days >= 7
    error_message = "soft delete retention must be >= 7 days for state recovery."
  }
}
