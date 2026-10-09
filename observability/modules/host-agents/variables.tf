variable "hosts" {
  description = <<-EOT
    Existing VMs / VM scale sets (keyed by a stable name).
      resource_id        : VM or VMSS resource id
      os_type            : linux | windows
      kind               : vm | vmss
      location           : region (required by run commands)
      service_tags       : unified tags for the host (env/service/version/team/...) -> Agent DD_TAGS + Fluent Bit ddtags
      log_paths          : application log files tailed by Fluent Bit (the app writes JSON lines there)
      identity_client_id : user-assigned identity on the host with "Key Vault Secrets User" (Fluent Bit API key
                           fetched at install time; nothing secret in Terraform state). Null = protected parameter.
  EOT
  type = map(object({
    resource_id        = string
    os_type            = string
    kind               = optional(string, "vm")
    location           = string
    service_tags       = optional(map(string), {})
    log_paths          = list(string)
    systemd_unit       = optional(string)
    windows_event_log  = optional(bool, false)
    identity_client_id = optional(string)
    install_agent      = optional(bool, true)
    install_fluent_bit = optional(bool, true)
  }))
  validation {
    condition     = alltrue([for h in values(var.hosts) : contains(["linux", "windows"], h.os_type) && contains(["vm", "vmss"], h.kind)])
    error_message = "hosts[*].os_type must be linux|windows and kind vm|vmss."
  }
  validation {
    condition = alltrue([for h in values(var.hosts) : (
      h.kind == "vm" ? can(regex("(?i)/providers/Microsoft.Compute/virtualMachines/[^/]+$", h.resource_id)) : can(regex("(?i)/providers/Microsoft.Compute/virtualMachineScaleSets/[^/]+$", h.resource_id))
    )])
    error_message = "hosts[*].resource_id must be a virtualMachines id for kind = vm and a virtualMachineScaleSets id for kind = vmss."
  }
  validation {
    condition     = alltrue([for h in values(var.hosts) : length(h.log_paths) > 0 || !h.install_fluent_bit])
    error_message = "hosts[*].log_paths must list at least one application log file when Fluent Bit is installed."
  }
}

variable "datadog" {
  description = <<-EOT
    site, agent_version (pinned) and how the Agent extension gets the API key:
      api_key_key_vault = { secret_url, source_vault_id } -> protectedSettingsFromKeyVault; the secret VALUE
                          must be the JSON {"api_key":"<key>"} (preferred, nothing in state; vault needs
                          enabled_for_deployment). Otherwise api_key (sensitive variable) is used.
    api_key_secret_id : versionless Key Vault id of the plain API key, read by the Fluent Bit installer.
  EOT
  type = object({
    site               = string
    agent_version      = optional(string, "7.84.2")
    extension_version  = optional(string, "7.0")
    api_key_secret_id  = optional(string)
    process_collection = optional(bool, false)
    api_key_key_vault = optional(object({
      secret_url      = string
      source_vault_id = string
    }))
  })
  validation {
    condition     = var.datadog.api_key_key_vault == null || can(regex("^https://[^/]+/secrets/[^/]+/[0-9a-fA-F]{32}$", try(var.datadog.api_key_key_vault.secret_url, "")))
    error_message = "datadog.api_key_key_vault.secret_url must be a VERSIONED Key Vault secret URL (the compute extension API requires a version)."
  }
  validation {
    condition     = can(regex("^7\\.[0-9]+\\.[0-9]+$", var.datadog.agent_version))
    error_message = "datadog.agent_version must be a pinned 7.x.y version (no 'latest')."
  }
}

variable "api_key" {
  description = "Datadog API key (only when datadog.api_key_key_vault / identity-based Key Vault reads are not available). Sensitive; ends up in state as a protected setting."
  type        = string
  default     = null
  sensitive   = true
}

variable "fluent_bit_version" {
  type    = string
  default = "5.1.3"
  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.fluent_bit_version))
    error_message = "fluent_bit_version must be pinned (x.y.z)."
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}
