variable "mode" {
  description = <<-EOT
    How VMs / VMSS get the Datadog Agent VM Application:
      policy : (default) Azure Policy DeployIfNotExists enrols every VM / VMSS tagged <enrollment_tag> in the scope -
               no per-host Terraform; new VMSS instances and new VMs get it automatically (modules/host-agent-policy).
      direct : escape hatch for environments WITHOUT Azure Policy rights: one
               azurerm_virtual_machine_gallery_application_assignment per VM in var.hosts (same VM Application, same
               version); VMSS models are set by their platform root from output vmss_gallery_applications; the hosts
               must already carry the DSV-reader identity (agent_identity).
  EOT
  type        = string
  default     = "policy"
  validation {
    condition     = contains(["policy", "direct"], var.mode)
    error_message = "mode must be policy or direct."
  }
}

variable "env" {
  description = "Environment name."
  type        = string
}

variable "package" {
  description = "VM Application package (modules/host-agent-package): gallery + storage names, version (bumped per release, promoted dev -> test -> prod), dsv-fetch release directory, regions."
  type = object({
    resource_group_id = string
    location          = string
    names = object({
      gallery            = string
      storage_account    = string
      publisher_identity = string
      container          = optional(string, "vm-applications")
    })
    version               = string
    retained_versions     = optional(list(string), [])
    applications          = optional(map(object({ name = optional(string) })), { linux = {}, windows = {} })
    dsv_fetch_release_dir = string
    replica_regions = optional(list(object({
      name                 = string
      regional_replicas    = optional(number, 1)
      storage_account_type = optional(string, "Standard_ZRS")
    })), [])
    publisher_principal_ids = optional(list(string), [])
    network = optional(object({
      public_network_access_enabled = optional(bool, true)
      ip_rules                      = optional(list(string), [])
      subnet_ids                    = optional(list(string), [])
    }), {})
    agent_msi_sha256 = optional(map(string))
  })
}

variable "datadog" {
  description = "Datadog site and the Delinea DSV reference of the ingest-only API key (never the key)."
  type = object({
    site        = string
    api_key_ref = string
  })
  validation {
    condition     = can(regex("^dsv://[A-Za-z0-9._/-]+(#[A-Za-z0-9._-]+)?$", var.datadog.api_key_ref))
    error_message = "datadog.api_key_ref must be a Delinea DSV reference (dsv://<path>#<element>), never a key."
  }
}

variable "dsv" {
  description = "Delinea DSV endpoint (non-secret) for dsv-fetch on the hosts."
  type = object({
    tenant   = optional(string)
    tld      = optional(string, "com")
    base_url = optional(string)
    auth     = optional(string, "azure")
  })
}

variable "agent_identity" {
  description = <<-EOT
    Per-environment DSV-reader user-assigned identity (foundation-identity identities["obs-host-agent"]): the policy
    attaches it to every enrolled VM / VMSS, dsv-fetch on the host uses its client id. DSV grants it read on the
    ingest-only Datadog API key and nothing else (accepted risk: any process on an enrolled host can use it).
  EOT
  type = object({
    id        = string
    client_id = string
  })
}

variable "policy" {
  description = "mode = policy: assignment scope (subscription | management_group), names, enrolment tag, effect, targets, remediation."
  type = object({
    name_prefix                  = string
    scope                        = object({ type = string, id = string, not_scopes = optional(list(string), []) })
    identity_resource_group_name = string
    enrollment_tag               = optional(object({ name = optional(string, "datadog:enabled"), value = optional(string, "true") }), {})
    arch_tag_name                = optional(string, "datadog:arch")
    effect                       = optional(string, "DeployIfNotExists")
    targets                      = optional(set(string), ["vm", "vmss"])
    application_order            = optional(number, 10)
    remediation = optional(object({
      enabled              = optional(bool, true)
      location_filters     = optional(list(string), [])
      parallel_deployments = optional(number, 10)
      resource_count       = optional(number, 500)
      failure_percentage   = optional(number, 0.1)
    }), {})
    extra_role_actions = optional(list(string), [])
  })
  default = null
}

variable "hosts" {
  description = "mode = direct only: VMs / VMSS (key -> resource_id, os_type linux | windows, kind vm | vmss, arch amd64 | arm64). Ignored in policy mode."
  type = map(object({
    resource_id = string
    os_type     = string
    kind        = optional(string, "vm")
    arch        = optional(string, "amd64")
  }))
  default = {}
  validation {
    condition = alltrue([for h in values(var.hosts) : contains(["linux", "windows"], h.os_type) && contains(["vm", "vmss"], h.kind) && contains(["amd64", "arm64"], h.arch) && (
      h.kind == "vm" ? can(regex("(?i)/providers/Microsoft.Compute/virtualMachines/[^/]+$", h.resource_id)) : can(regex("(?i)/providers/Microsoft.Compute/virtualMachineScaleSets/[^/]+$", h.resource_id))
    )])
    error_message = "hosts[*]: os_type linux|windows, kind vm|vmss with a matching resource id, arch amd64|arm64."
  }
}

variable "fleet_policy" {
  description = "Decoded fleet policy (null = package default)."
  type        = any
  default     = null
}

variable "tag_policy" {
  description = "Decoded tag policy (null = package default)."
  type        = any
  default     = null
}

variable "extra_tags" {
  description = "Additional static Datadog host tags."
  type        = map(string)
  default     = {}
}

variable "log_pipeline" {
  description = "Override the fleet policy log_pipeline (observability_pipelines | fluent_bit_direct)."
  type        = string
  default     = null
}

variable "op_agent_logs_url" {
  description = "Observability Pipelines Worker Datadog Agent source URL (transport contract aggregator.agent_logs_url)."
  type        = string
  default     = null
}

variable "host_logs" {
  description = "Host log collection by the Agent (see modules/host-agent-package var.host_logs)."
  type        = any
  default     = {}
}

variable "default_service" {
  description = "Agent log `service` when the instance has no service tag."
  type        = string
  default     = "platform"
}

variable "metadata_tag_prefix" {
  description = "Prefix of the per-host Azure tags read on the host (<prefix>log_paths, <prefix>source)."
  type        = string
  default     = "datadog:"
}

variable "tags" {
  description = "Azure resource tags."
  type        = map(string)
  default     = {}
}
