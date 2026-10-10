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
  description = "platform-vm settings (environment.yaml components.platform-vm)."
  type = object({
    # Linux host for hello-worker (systemd). Bsv2 replaces B-series v1 (retiring 2028-11-15).
    linux_vm = optional(object({
      enabled              = optional(bool, true)
      size                 = optional(string, "Standard_B2s_v2")
      identity             = optional(string, "hello-worker")
      admin_username       = optional(string, "azureuser")
      admin_ssh_public_key = optional(string) # public key (not a secret); null => random break-glass password in state only
      os_disk_type         = optional(string, "StandardSSD_LRS")
      zone                 = optional(string)
      image = optional(object({
        publisher = optional(string, "Canonical")
        offer     = optional(string, "ubuntu-24_04-lts")
        sku       = optional(string, "server")
        version   = optional(string, "latest")
      }), {})
    }), {})
    # Windows host for hello-inventory-api (Windows service). .NET 10 Hosting Bundle is installed by the app deployment.
    windows_vm = optional(object({
      enabled        = optional(bool, true)
      size           = optional(string, "Standard_B2s_v2")
      identity       = optional(string, "hello-inventory-api")
      admin_username = optional(string, "azureadmin")
      os_disk_type   = optional(string, "StandardSSD_LRS")
      zone           = optional(string)
      hotpatching    = optional(bool, true)
      image = optional(object({
        publisher = optional(string, "MicrosoftWindowsServer")
        offer     = optional(string, "WindowsServer")
        sku       = optional(string, "2025-datacenter-azure-edition")
        version   = optional(string, "latest")
      }), {})
    }), {})
    auto_shutdown = optional(object({
      enabled  = optional(bool, true)
      time     = optional(string, "1900") # HHmm
      timezone = optional(string, "UTC")
    }), {})
    # Microsoft Entra ID login (AADSSHLoginForLinux / AADLoginForWindows) - access, not monitoring.
    entra_login_enabled        = optional(bool, true)
    admin_login_principal_ids  = optional(list(string), [])
    user_login_principal_ids   = optional(list(string), [])
    encryption_at_host_enabled = optional(bool, false) # needs Microsoft.Compute/EncryptionAtHost feature registration
    # Datadog Agent via the obs-hosts Azure Policy (observability 4.0.0): enrolment tag (= obs-hosts
    # settings.policy.enrollment_tag) and the foundation-identity key of the DSV-reader identity the policy attaches
    datadog = optional(object({
      enabled      = optional(bool, true)
      tag_name     = optional(string, "datadog:enabled")
      identity_key = optional(string, "obs-host-agent")
    }), {})
  })
  default = {}

  validation {
    condition     = can(regex("^([01][0-9]|2[0-3])[0-5][0-9]$", var.settings.auto_shutdown.time))
    error_message = "auto_shutdown.time must be HHmm (24h)."
  }
  validation {
    condition     = var.settings.linux_vm.admin_ssh_public_key == null || can(regex("^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256) ", coalesce(var.settings.linux_vm.admin_ssh_public_key, "x")))
    error_message = "admin_ssh_public_key must be an OpenSSH public key."
  }
}
