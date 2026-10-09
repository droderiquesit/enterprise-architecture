variable "environment" {
  description = "Environment globals (ADR-0001 §6), rendered by tools/config/render.py."
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
  description = "Component settings (environments/<env>/environment.yaml -> components.foundation-network). See README for every field."
  type = object({
    # "single-spoke" (minimal/low-cost: one VNet, NAT Gateway egress, no hub) or "hub-spoke".
    topology = optional(string, "single-spoke")
    # "nat-gateway" (default) or "firewall" (requires hub-spoke and foundation-edge firewall; see README apply order).
    egress = optional(string, "nat-gateway")

    hub_address_space   = optional(list(string), ["10.40.0.0/20"])
    spoke_address_space = optional(list(string), ["10.41.0.0/16"])

    # Per-subnet overrides keyed by ADR §8 subnet key. Only prefix / enabled / outbound are overridable;
    # delegations, NSGs and routing are fixed by the catalogue in subnets.tf.
    subnets = optional(map(object({
      address_prefix                  = optional(string)
      enabled                         = optional(bool)
      default_outbound_access_enabled = optional(bool)
    })), {})

    # Hub/edge subnets owned here but used by foundation-edge. Off by default (no cost, but keeps plans small).
    bastion_subnet  = optional(bool, false) # AzureBastionSubnet (Basic/Standard Bastion; Developer SKU needs none)
    firewall_subnet = optional(bool, false) # AzureFirewallSubnet + AzureFirewallManagementSubnet (hub-spoke only)
    appgw_subnet    = optional(bool, false) # Application Gateway v2 subnet
    apim_subnet     = optional(bool, false) # API Management v2 outbound VNet integration subnet

    # "vmss" (Azure DevOps VMSS agents, no delegation) or "managed-devops-pool" (delegates deploy-agents to Microsoft.DevOpsInfrastructure/pools).
    deploy_agents_mode = optional(string, "vmss")

    nat_gateway = optional(object({
      idle_timeout_in_minutes = optional(number, 4)
      zones                   = optional(list(string), [])
      public_ip_count         = optional(number, 1)
    }), {})

    # Private DNS zones: defaults cover every Private Link service in the catalogue (see dns.tf).
    private_dns_zones_exclude = optional(list(string), [])
    private_dns_zones_extra   = optional(map(string), {})
    ampls_zones               = optional(bool, false) # Azure Monitor Private Link Scope zones (changes DNS for all Azure Monitor endpoints)

    internal_dns_zone              = optional(string)     # default "<env>.<prefix>.lab.internal"
    internal_dns_zone_registration = optional(bool, true) # VM auto-registration in the spoke

    aks_public_ingress    = optional(bool, false) # allow Internet 80/443 to aks-nodes (public LoadBalancer services)
    appgw_listener_ports  = optional(list(number), [80, 443])
    aro_preconfigured_nsg = optional(bool, false) # attach NSGs to ARO subnets (requires `--enable-preconfigured-nsg`)
  })
  default = {}

  validation {
    condition     = contains(["single-spoke", "hub-spoke"], var.settings.topology)
    error_message = "settings.topology must be single-spoke or hub-spoke."
  }
  validation {
    condition     = contains(["nat-gateway", "firewall"], var.settings.egress)
    error_message = "settings.egress must be nat-gateway or firewall."
  }
  validation {
    condition     = !(var.settings.egress == "firewall" && var.settings.topology != "hub-spoke")
    error_message = "egress = firewall requires topology = hub-spoke (the firewall lives in the hub)."
  }
  validation {
    condition     = !(var.settings.egress == "firewall" && !var.settings.firewall_subnet)
    error_message = "egress = firewall requires firewall_subnet = true."
  }
  validation {
    condition     = contains(["vmss", "managed-devops-pool"], var.settings.deploy_agents_mode)
    error_message = "settings.deploy_agents_mode must be vmss or managed-devops-pool."
  }
  validation {
    condition     = var.settings.nat_gateway.public_ip_count >= 1 && var.settings.nat_gateway.public_ip_count <= 16
    error_message = "nat_gateway.public_ip_count must be 1..16."
  }
}
