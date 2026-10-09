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
    egress = object({
      type                = string
      public_ips          = optional(list(string), [])
      firewall_private_ip = optional(string)
    })
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

variable "platform_shared" {
  description = "platform-shared contract v1 (only the fields this root uses)."
  type = object({
    acr_id                     = string
    acr_login_server           = string
    log_analytics_workspace_id = string
  })
}

variable "settings" {
  description = "platform-aks settings (environment.yaml components.platform-aks)."
  type = object({
    # Supported, non-preview, non-LTS minor (AKS calendar: 1.36 GA Jun 2026, EOL Jun 2027). Patch
    # is chosen by AKS; automatic_upgrade_channel = "patch" keeps it current.
    kubernetes_version        = optional(string, "1.36")
    sku_tier                  = optional(string, "Free") # "Standard" for uptime SLA (enterprise)
    automatic_upgrade_channel = optional(string, "patch")
    node_os_upgrade_channel   = optional(string, "NodeImage")
    maintenance = optional(object({
      day_of_week = optional(string, "Sunday")
      start_time  = optional(string, "02:00")
      utc_offset  = optional(string, "+00:00")
      duration    = optional(number, 4)
    }), {})
    # API server exposure. Private by default: deploy agents in the VNet (foundation-deploy-agents)
    # or `az aks command invoke` (run_command_enabled) are required to reach it.
    private_cluster_enabled  = optional(bool, true)
    private_dns_zone_id      = optional(string, "System")
    authorized_ip_ranges     = optional(list(string), [])
    run_command_enabled      = optional(bool, true)
    admin_group_object_ids   = optional(list(string), [])
    cluster_admin_identities = optional(list(string), ["deploy-agent"]) # foundation identity keys
    cluster_admin_principals = optional(list(string), [])               # extra Entra object ids (pipeline SP)
    # Networking: Azure CNI overlay + Cilium data plane. CIDRs must not overlap VNet/hub ranges.
    pod_cidr       = optional(string, "192.168.0.0/16")
    service_cidr   = optional(string, "10.0.0.0/16")
    dns_service_ip = optional(string, "10.0.0.10")
    outbound_type  = optional(string, "auto") # auto => from foundation egress (NAT gateway / firewall UDR)
    # Node pools
    system_pool = optional(object({
      vm_size   = optional(string, "Standard_D2s_v5")
      min_count = optional(number, 1)
      max_count = optional(number, 2)
      os_sku    = optional(string, "AzureLinux")
      zones     = optional(list(string), [])
    }), {})
    user_pool = optional(object({
      enabled   = optional(bool, false)
      vm_size   = optional(string, "Standard_D2s_v5")
      min_count = optional(number, 0)
      max_count = optional(number, 2)
      os_sku    = optional(string, "AzureLinux")
      zones     = optional(list(string), [])
    }), {})
    azure_policy_enabled               = optional(bool, false)
    image_cleaner_enabled              = optional(bool, true)
    defender_enabled                   = optional(bool, false) # Defender sensor uses the platform-shared workspace
    host_encryption_enabled            = optional(bool, false) # needs Microsoft.Compute/EncryptionAtHost registration
    key_vault_secrets_provider_enabled = optional(bool, true)  # Secrets Store CSI driver with rotation
    # Workload identity federation: identity key => Kubernetes namespace/service account.
    workload_identities = optional(map(object({
      namespace       = string
      service_account = string
      })), {
      "hello-bff"         = { namespace = "hello", service_account = "hello-bff" }
      "hello-orders-api"  = { namespace = "hello", service_account = "hello-orders-api" }
      "hello-catalog-api" = { namespace = "hello", service_account = "hello-catalog-api" }
      "hello-worker"      = { namespace = "hello", service_account = "hello-worker" }
      "obs-collector"     = { namespace = "datadog", service_account = "datadog-agent" }
    })
  })
  default = {}

  validation {
    condition     = can(regex("^1\\.[0-9]+(\\.[0-9]+)?$", var.settings.kubernetes_version))
    error_message = "kubernetes_version must look like 1.36 or 1.36.2."
  }
  validation {
    condition     = contains(["Free", "Standard", "Premium"], var.settings.sku_tier)
    error_message = "sku_tier must be Free, Standard or Premium."
  }
  validation {
    condition     = contains(["patch", "stable", "rapid", "node-image", "none"], var.settings.automatic_upgrade_channel)
    error_message = "automatic_upgrade_channel must be patch, stable, rapid, node-image or none."
  }
  validation {
    condition     = contains(["auto", "loadBalancer", "userDefinedRouting", "managedNATGateway", "userAssignedNATGateway"], var.settings.outbound_type)
    error_message = "outbound_type must be auto, loadBalancer, userDefinedRouting, managedNATGateway or userAssignedNATGateway."
  }
  validation {
    condition     = var.settings.private_cluster_enabled || length(var.settings.authorized_ip_ranges) > 0
    error_message = "A public API server requires at least one authorized_ip_ranges entry."
  }
  validation {
    condition     = var.settings.system_pool.min_count >= 1 && var.settings.system_pool.max_count >= var.settings.system_pool.min_count && var.settings.system_pool.max_count <= 10
    error_message = "system pool: 1 <= min_count <= max_count <= 10."
  }
  validation {
    condition     = var.settings.user_pool.min_count >= 0 && var.settings.user_pool.max_count >= var.settings.user_pool.min_count && var.settings.user_pool.max_count <= 20
    error_message = "user pool: 0 <= min_count <= max_count <= 20."
  }
}
