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

variable "foundation_network" {
  description = "foundation-network contract v1 (fields used here)."
  type = object({
    spoke_vnet_id = string
    subnets = map(object({
      id         = string
      delegation = optional(string)
    }))
  })
}

variable "foundation_identity" {
  description = "foundation-identity contract v1 (fields used here)."
  type = object({
    identities = map(object({
      id           = string
      client_id    = string
      principal_id = string
    }))
  })
}

variable "settings" {
  description = "Component settings (components.foundation-deploy-agents). See README."
  type = object({
    # "vmss" (Azure DevOps 'Azure Virtual Machine Scale Set agents', default) or "managed-devops-pool".
    mode = optional(string, "vmss")

    vmss = optional(object({
      sku            = optional(string, "Standard_D2s_v5")
      admin_username = optional(string, "azdevops")
      # Required in vmss mode. Password auth is disabled; Azure DevOps manages the agents, nobody logs in
      # except for break-glass via Bastion. Never commit a private key.
      admin_ssh_public_key = optional(string, "")
      os_disk_type         = optional(string, "StandardSSD_LRS")
      os_disk_size_gb      = optional(number, 128)
      zones                = optional(list(string), [])
      encryption_at_host   = optional(bool, false) # requires Microsoft.Compute/EncryptionAtHost feature registration
      image = optional(object({
        publisher = optional(string, "Canonical")
        offer     = optional(string, "ubuntu-24_04-lts")
        sku       = optional(string, "server")
        version   = optional(string, "latest")
      }), {})
    }), {})

    managed_devops_pool = optional(object({
      organization_url = optional(string, "") # https://dev.azure.com/<org>
      projects         = optional(list(string), [])
      parallelism      = optional(number, 1)
      max_concurrency  = optional(number, 2)
      sku_name         = optional(string, "Standard_D2ads_v5")
      image_name       = optional(string, "ubuntu-24.04/latest") # MDP well-known image
      # Object ID of the tenant's "DevOpsInfrastructure" service principal:
      #   az ad sp list --display-name DevOpsInfrastructure --query "[].id" -o tsv
      devops_infrastructure_principal_id = optional(string, "")
    }), {})
  })
  default = {}

  validation {
    condition     = contains(["vmss", "managed-devops-pool"], var.settings.mode)
    error_message = "settings.mode must be vmss or managed-devops-pool."
  }
  validation {
    condition     = var.settings.mode != "vmss" || can(regex("^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256) ", var.settings.vmss.admin_ssh_public_key))
    error_message = "vmss mode requires settings.vmss.admin_ssh_public_key (an OpenSSH public key)."
  }
  validation {
    condition = var.settings.mode != "managed-devops-pool" || (
      can(regex("^https://dev\\.azure\\.com/[^/]+/?$", var.settings.managed_devops_pool.organization_url)) &&
      can(regex("^[0-9a-f-]{36}$", var.settings.managed_devops_pool.devops_infrastructure_principal_id))
    )
    error_message = "managed-devops-pool mode requires organization_url (https://dev.azure.com/<org>) and devops_infrastructure_principal_id."
  }
}
