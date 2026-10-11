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
    location      = string
    spoke_vnet_id = string
    subnets       = map(object({ id = string, name = string }))
  })
}

# Application workload identities (federated below with the cluster's OIDC issuer, as platform-aks does on AKS).
variable "foundation_identity" {
  description = "foundation-identity contract v2 (only the fields this root uses)."
  type = object({
    identities = map(object({
      id        = string
      client_id = string
      name      = string
    }))
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
    api_visibility      = optional(string, "Private")
    ingress_visibility  = optional(string, "Private")
    master_vm_size      = optional(string, "Standard_D8s_v5")
    worker_vm_size      = optional(string, "Standard_D4s_v5")
    worker_count        = optional(number, 3)
    worker_disk_size_gb = optional(number, 128)
    pod_cidr            = optional(string, "10.128.0.0/14")
    service_cidr        = optional(string, "172.30.0.0/16")
    outbound_type       = optional(string, "Loadbalancer")
    fips_enabled        = optional(bool, false)
    # NSGs / NAT gateways / route tables attached to the ARO subnets also need operator role
    # assignments (Learn: "Understand managed identities in ARO").
    extra_network_resource_ids = optional(list(string), [])
    # Application workload identity federation (ADR-0001 section 3: the credential binds a foundation identity to THIS
    # cluster's OIDC issuer, so it lives with the cluster - same rule as platform-aks): identity key => namespace /
    # service account. deploy-specialized runs hello-catalog-api under this service account and reads Delinea DSV
    # with the federated token the OpenShift pod-identity webhook injects.
    workload_identities = optional(map(object({
      namespace       = string
      service_account = string
      })), {
      "hello-catalog-api" = { namespace = "hello", service_account = "hello-catalog-api" }
    })
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

# Red Hat pull secret JSON from Delinea DSV (aro-pull-secret; pipeline: tools/secrets/fetch.py -> TF_VAR_pull_secret,
# optional). cluster_profile.pull_secret has no write-only form in azurerm 5.9, so the value is stored in state.
variable "pull_secret" {
  description = "Red Hat pull secret JSON (optional; DSV aro-pull-secret)."
  type        = string
  default     = null
  sensitive   = true
  validation {
    condition     = var.pull_secret == null || can(jsondecode(var.pull_secret).auths)
    error_message = "pull_secret must be the Red Hat pull secret JSON ({\"auths\": {...}})."
  }
}
