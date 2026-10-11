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
    location = string
    subnets  = map(object({ id = string, name = string }))
  })
}

variable "foundation_identity" {
  description = "foundation-identity contract v2 (fields used): the DSV-reader identity of the host Agents (identities[settings.datadog.identity_key]) attached to the node type."
  type = object({
    identities = map(object({ id = string, name = string }))
  })
}

variable "settings" {
  description = "platform-servicefabric settings (environment.yaml components.platform-servicefabric)."
  type = object({
    enabled = optional(bool, false) # disabled by default: 3 x Windows nodes ~ USD 250+/month
    sku     = optional(string, "Basic")
    # Client authentication: at least one of a client certificate thumbprint or an Entra app pair.
    client_certificate_thumbprint  = optional(string)
    client_certificate_common_name = optional(string)
    entra_cluster_application_id   = optional(string)
    entra_client_application_id    = optional(string)
    # Object id of the tenant's "Azure Service Fabric Resource Provider" service principal. Needed for BYO VNet (Network
    # Contributor on the sfmc subnet) and for the Datadog DSV-reader identity on the node type (Managed Identity Operator
    # on that identity). byo_vnet: null => BYO VNet whenever the principal id is set (pre-4.1 behaviour); false =>
    # managed cluster VNet even with the principal id.
    sf_resource_provider_principal_id = optional(string)
    byo_vnet                          = optional(bool)
    node_type = optional(object({
      name              = optional(string, "nt1")
      vm_size           = optional(string, "Standard_D2s_v5")
      instance_count    = optional(number, 3) # Basic SKU minimum (primary node type)
      data_disk_size_gb = optional(number, 128)
      data_disk_type    = optional(string, "StandardSSD_LRS")
      image_sku         = optional(string, "2022-datacenter-azure-edition")
      application_ports = optional(string, "20000-30000")
      ephemeral_ports   = optional(string, "49152-65534")
      # Azure tags of the node type (e.g. service = hello-inventory-api; the host Agent maps instance tags it can read
      # from IMDS to Datadog host tags) and Service Fabric placement properties
      tags                 = optional(map(string), {})
      placement_properties = optional(map(string), {})
    }), {})
    # Datadog Agent on the nodes (observability 4.1.0): this root attaches the DSV-reader identity and tags the node
    # type; obs-hosts adds the datadog-agent-windows VM Application to the node type (Azure Policy cannot reach node
    # types). tag_name = obs-hosts settings.enrollment_tag.name.
    datadog = optional(object({
      enabled      = optional(bool, true)
      tag_name     = optional(string, "datadog:enabled")
      identity_key = optional(string, "obs-host-agent")
    }), {})
    app_port = optional(number, 8080) # hello-inventory-api guest executable (load-balancer rule)
  })
  default = {}

  validation {
    condition     = contains(["Basic", "Standard"], var.settings.sku)
    error_message = "sku must be Basic or Standard."
  }
  validation {
    condition     = var.settings.node_type.instance_count >= (var.settings.sku == "Basic" ? 3 : 5) && var.settings.node_type.instance_count <= 10
    error_message = "primary node type needs >= 3 nodes (Basic) or >= 5 (Standard); lab ceiling 10."
  }
  validation {
    condition     = !var.settings.enabled || var.settings.client_certificate_thumbprint != null || (var.settings.entra_cluster_application_id != null && var.settings.entra_client_application_id != null)
    error_message = "An enabled cluster needs a client certificate thumbprint or an Entra cluster/client application pair."
  }
  validation {
    condition     = !var.settings.enabled || !var.settings.datadog.enabled || var.settings.sf_resource_provider_principal_id != null
    error_message = "settings.datadog.enabled needs sf_resource_provider_principal_id (the Service Fabric Resource Provider gets Managed Identity Operator on the DSV-reader identity); or set datadog.enabled = false."
  }
  validation {
    condition     = alltrue([for r in [var.settings.node_type.application_ports, var.settings.node_type.ephemeral_ports] : can(regex("^[0-9]+-[0-9]+$", r))])
    error_message = "node_type.application_ports / ephemeral_ports must be <start>-<end>."
  }
}
