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

variable "settings" {
  description = "platform-specialized-compute settings. Every capability is off by default (cost/quota)."
  type = object({
    admin_username       = optional(string, "azureuser")
    admin_ssh_public_key = optional(string)
    # Confidential VM (AMD SEV-SNP, DCasv5) running hello-worker.
    confidential_vm = optional(object({
      enabled                  = optional(bool, false)
      size                     = optional(string, "Standard_DC2as_v5")
      identity                 = optional(string, "hello-worker")
      security_encryption_type = optional(string, "VMGuestStateOnly")
      image_offer              = optional(string, "ubuntu-24_04-lts")
      image_sku                = optional(string, "cvm")
    }), {})
    # Dedicated host group + host + one VM placed on it.
    dedicated_host = optional(object({
      enabled  = optional(bool, false)
      host_sku = optional(string, "DSv5-Type1")
      vm_size  = optional(string, "Standard_D2s_v5")
      identity = optional(string, "hello-worker")
    }), {})
    # GPU VM (NCasT4_v3). Requires "Standard NCASv3_T4 Family vCPUs" quota; NVIDIA driver install is
    # an application/deployment concern (GPU driver extension or cloud-init), not done here.
    gpu_vm = optional(object({
      enabled  = optional(bool, false)
      size     = optional(string, "Standard_NC4as_T4_v3")
      identity = optional(string, "hello-worker")
    }), {})
    # Azure Automation account + identity + placeholder schedule; runbook content is owned by
    # applications/deployments/specialized (python3 health-probe runbook).
    automation = optional(object({
      enabled           = optional(bool, false)
      identity          = optional(string, "hello-jobs")
      schedule_interval = optional(number, 1) # hours
    }), {})
    # Azure Machine Learning workspace + CPU compute cluster (scale to zero).
    ml = optional(object({
      enabled          = optional(bool, false)
      cluster_vm_size  = optional(string, "Standard_D2s_v5")
      cluster_max      = optional(number, 1)
      cluster_priority = optional(string, "LowPriority")
    }), {})
    auto_shutdown_time = optional(string, "1900")
  })
  default = {}

  validation {
    condition     = contains(["VMGuestStateOnly", "DiskWithVMGuestState"], var.settings.confidential_vm.security_encryption_type)
    error_message = "confidential_vm.security_encryption_type must be VMGuestStateOnly or DiskWithVMGuestState."
  }
  validation {
    condition     = var.settings.ml.cluster_max >= 1 && var.settings.ml.cluster_max <= 4
    error_message = "ml.cluster_max must be 1-4 (lab ceiling)."
  }
}
