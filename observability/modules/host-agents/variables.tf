variable "hosts" {
  description = <<-EOT
    Existing VMs / VM scale sets (keyed by a stable name).
      resource_id        : VM or VMSS resource id
      os_type            : linux | windows
      kind               : vm | vmss
      location           : region (required by run commands)
      service_tags       : unified tags for the host (env/service/version/team/...) -> Agent DD_TAGS + Fluent Bit ddtags
      log_paths          : application log files tailed by Fluent Bit (the app writes JSON lines there)
      identity_client_id : client id of the host's user-assigned managed identity, mapped to a DSV user with read on
                           the API key path (required; the key is read on the host, never in Terraform state)
      install_agent      : install + configure the Datadog Agent (pinned datadog.agent_version)
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
    site, agent_version (pinned 7.x.y) and the Delinea DSV reference of the API key (never the key):
      api_key_ref : dsv://<path>#<element>; Linux Agents resolve it through secret_backend_command (dsv-fetch
                    agent-backend), Fluent Bit through the dsv-fetch env-yaml file; Windows installers read it at run time.
  EOT
  type = object({
    site               = string
    agent_version      = optional(string, "7.84.2")
    api_key_ref        = string
    process_collection = optional(bool, false)
  })
  validation {
    condition     = can(regex("^7\\.[0-9]+\\.[0-9]+$", var.datadog.agent_version))
    error_message = "datadog.agent_version must be a pinned 7.x.y version (no 'latest')."
  }
  validation {
    condition     = can(regex("^dsv://[A-Za-z0-9._/-]+(#[A-Za-z0-9._-]+)?$", var.datadog.api_key_ref))
    error_message = "datadog.api_key_ref must be a Delinea DSV reference (dsv://<path>#<element>), never a key."
  }
}

variable "secrets" {
  description = "Delinea DSV endpoint for the on-host reader (non-secret): tenant/tld or base_url, auth (azure = managed identity via IMDS)."
  type = object({
    tenant   = optional(string)
    tld      = optional(string, "com")
    base_url = optional(string)
    auth     = optional(string, "azure")
  })
  validation {
    condition     = (var.secrets.tenant != null || var.secrets.base_url != null) && contains(["azure", "client_credentials"], var.secrets.auth)
    error_message = "secrets needs tenant or base_url; auth azure (hosts) or client_credentials (tests only)."
  }
}

variable "dsv_fetch_source" {
  description = "Path of dsv_fetch.py embedded into the Linux installer (null = observability/images/dsv-fetch/dsv_fetch.py of this package)."
  type        = string
  default     = null
}

variable "windows_msi_sha256" {
  description = "Pinned SHA256 of the Windows MSIs (vendors publish no checksum files). Values computed 2026-10-09 for agent 7.84.2 / Fluent Bit 5.1.3; update together with the versions."
  type = object({
    agent      = optional(string, "9ebecc6f16fad77df6dd14cf55d7edf84587cdf43f259442301bd6f2671b0b86")
    fluent_bit = optional(string, "334685284bfd830a61d04161406473bf2174dd1ac14df9f459e26819ab874944")
  })
  default = {}
}

variable "setup_revision" {
  description = "Bump to force the installer to re-run everywhere (e.g. after removing the 1.x Datadog VM extension, or to refresh a rotated key on Windows)."
  type        = number
  default     = 1
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
