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
    # Phase 1 (bootstrap, Microsoft-hosted agents): "Enabled" + firewall default Deny + operator_ip_ranges.
    # Phase 2 (private agents exist): "Disabled" + private_endpoint set. See README "Network phases".
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
    # Entra object IDs (user or group) of operators who run bootstrap/break-glass. They get Storage Blob Data
    # Contributor on tfstate + contracts: needed for `terraform init -migrate-state` with Entra auth (Owner has no
    # data-plane rights) and for state restore. Use a group; scripts/bootstrap.sh checks you are covered.
    operator_principal_ids = optional(list(string), [])
    # Promotion (environments/promotion.yaml): principal ids of DOWNSTREAM environments' pipeline identities
    # (e.g. test/prod build + apply) that read this environment's deployment records and packages to promote
    # the exact artifacts. The registry side is granted by platform-shared settings.acr_pull_principal_ids.
    promotion_reader_principal_ids = optional(list(string), [])

    # ---------------------------------------------------------------- pipeline identities
    create_validate_identity = optional(bool, true)
    # Federated credentials for Azure DevOps workload identity federation. Copy issuer + subject from the
    # service connection ("App registration or Managed identity (manual)" -> Workload identity federation).
    # New connections use the Entra issuer: https://login.microsoftonline.com/<tenant-id>/v2.0 with subject
    # "<entra-prefix>/sc/<organization-id>/<service-connection-id>".
    federated_credentials = optional(list(object({
      identity  = string # plan | apply | validate
      name      = string
      issuer    = string
      subject   = string
      audiences = optional(list(string), ["api://AzureADTokenExchange"])
    })), [])
    # Legacy Azure DevOps issuer (https://vstoken.dev.azure.com/<org-id>, subject sc://<org>/<project>/<sc>).
    # Deprecated by Microsoft, retires 2027-07-01; only for existing connections not yet converted.
    azure_devops_legacy = optional(object({
      organization_name   = string
      organization_id     = string
      project             = string
      service_connections = map(string) # identity key (plan|apply) => service connection name
    }))
    # Apply identity role-assignment rights: "constrained" = Role Based Access Control Administrator with an ABAC
    # condition that forbids assigning/removing Owner, User Access Administrator and RBAC Administrator;
    # "allowlist" = only the role definition GUIDs in apply_role_allowlist may be assigned.
    apply_rbac_mode      = optional(string, "constrained")
    apply_role_allowlist = optional(list(string), [])
    # foundation-governance assigns Azure Policy: Contributor cannot, so apply also gets Resource Policy Contributor.
    apply_policy_contributor = optional(bool, true)
    # Extra roles for the plan identity at subscription scope (e.g. a custom role with specific listKeys actions
    # when a root's refresh needs it). Default none: Reader only.
    plan_extra_role_names = optional(list(string), [])

    # ---------------------------------------------------------------- Datadog Azure integration (optional)
    datadog_integration = optional(object({
      enabled      = optional(bool, false)
      display_name = optional(string)
      owners       = optional(list(string), []) # Entra object IDs of app owners
      # Datadog "Secretless Auth" (recommended): issuer + subject shown in the Datadog Azure integration tile.
      # When empty, no federated credential is created and a client secret must be created out-of-band
      # (az ad app credential reset ... | az keyvault secret set ...) - never through Terraform.
      federated_issuer  = optional(string, "")
      federated_subject = optional(string, "")
      # Additional subscription IDs to grant Monitoring Reader on (the lab subscription is always included).
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
