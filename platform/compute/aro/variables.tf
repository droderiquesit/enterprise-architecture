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
    key_vault_id = string
  })
}

variable "settings" {
  description = "platform-aro settings (environment.yaml components.platform-aro). Blocked by default - see README prerequisites."
  type = object({
    enabled = optional(bool, false)
    # `az aro get-versions --location <region>`; required when enabled (no safe static default).
    version = optional(string)
    domain  = optional(string) # null => "<prefix><env><suffix>" (prefix for *.aroapp.io)
    # Object id of the tenant's "Azure Red Hat OpenShift RP" service principal
    # (`az ad sp list --display-name "Azure Red Hat OpenShift RP" --query "[0].id"`).
    aro_rp_principal_id = optional(string)
    # Versionless Key Vault secret id (foundation Key Vault) holding the Red Hat pull secret JSON.
    pull_secret_secret_id = optional(string)
    api_visibility        = optional(string, "Private")
    ingress_visibility    = optional(string, "Private")
    master_vm_size        = optional(string, "Standard_D8s_v5")
    worker_vm_size        = optional(string, "Standard_D4s_v5")
    worker_count          = optional(number, 3)
    worker_disk_size_gb   = optional(number, 128)
    pod_cidr              = optional(string, "10.128.0.0/14")
    service_cidr          = optional(string, "172.30.0.0/16")
    outbound_type         = optional(string, "Loadbalancer")
    fips_enabled          = optional(bool, false)
    # NSGs / NAT gateways / route tables attached to the ARO subnets also need operator role
    # assignments (Learn: "Understand managed identities in ARO").
    extra_network_resource_ids = optional(list(string), [])
  })
  default = {}

  validation {
    condition     = !var.settings.enabled || (var.settings.version != null && var.settings.aro_rp_principal_id != null)
    error_message = "An enabled ARO cluster needs settings.version and settings.aro_rp_principal_id."
  }
  validation {
    condition     = var.settings.worker_count >= 3 && var.settings.worker_count <= 10
    error_message = "worker_count must be 3-10."
  }
  validation {
    condition     = contains(["Loadbalancer", "UserDefinedRouting"], var.settings.outbound_type)
    error_message = "outbound_type must be Loadbalancer or UserDefinedRouting."
  }
}
