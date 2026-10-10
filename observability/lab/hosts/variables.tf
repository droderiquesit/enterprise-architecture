variable "settings" {
  description = "obs-hosts settings (environments/<env>/environment.yaml components.obs-hosts)."
  type = object({
    # policy (default): Azure Policy enrols every VM / VMSS tagged enrollment_tag; direct: one gallery application
    # assignment per platform-vm VM (environments without Azure Policy rights)
    mode = optional(string, "policy")
    # VM Application version of THIS environment. The pipeline bumps it when the Agent pin / installer / dsv-fetch
    # release changes and promotes the same value dev -> test -> prod; retained_versions keeps rollback targets.
    package_version   = optional(string, "1.0.0")
    retained_versions = optional(list(string), [])
    applications      = optional(map(object({ name = optional(string) })), { linux = {}, windows = {} })
    # staged by the pipeline from the img-dsv-fetch zip-package (dsv-fetch-* binaries + SHA256SUMS); relative to
    # this root
    dsv_fetch_release_dir = optional(string, ".dsv-fetch-release")
    replica_regions = optional(list(object({
      name                 = string
      regional_replicas    = optional(number, 1)
      storage_account_type = optional(string, "Standard_ZRS")
    })), [])
    publisher_principal_ids = optional(list(string), []) # e.g. the apply identity (upload with Entra ID)
    package_network = optional(object({
      public_network_access_enabled = optional(bool, true)
      ip_rules                      = optional(list(string), [])
      subnet_ids                    = optional(list(string), [])
    }), {})
    # policy scope: null = the environment subscription; management_group: /providers/Microsoft.Management/managementGroups/<name>
    scope = optional(object({
      type       = string
      id         = string
      not_scopes = optional(list(string), [])
    }))
    enrollment_tag = optional(object({
      name  = optional(string, "datadog:enabled")
      value = optional(string, "true")
    }), {})
    effect      = optional(string, "DeployIfNotExists")
    targets     = optional(set(string), ["vm", "vmss"])
    remediation = optional(any, {})
    # Agent log collection on the hosts (files per OS + Windows Event Log channels); hosts add files with the
    # Azure tag datadog:log_paths
    host_logs = optional(any, {
      linux = { files = [
        { path = "/var/log/hello-worker/*.log" },
        { path = "/var/log/enterprise-hello/*.log" },
      ] }
      windows = {
        files          = [{ path = "C:\\ProgramData\\enterprise-hello\\logs\\*.log" }]
        event_channels = [{ channel = "System" }, { channel = "Application" }]
      }
    })
    agent_identity_key = optional(string, "obs-host-agent")
    # direct mode: the SQL Server VM of platform-db-sqlvm (Agent only) and its OS
    sqlvm_os_type = optional(string, "windows")
  })
  default = {}
  validation {
    condition     = contains(["policy", "direct"], var.settings.mode)
    error_message = "settings.mode must be policy or direct."
  }
}

variable "obs_telemetry_transport" {
  description = "obs-telemetry-transport contract (fields used)."
  type = object({
    datadog_site = string
    api_key_ref  = string
    aggregator = optional(object({
      kind           = optional(string)
      fqdn           = optional(string)
      agent_logs_url = optional(string)
    }))
    env = optional(object({
      fleet = optional(map(string))
    }))
    secrets = object({
      tenant   = optional(string)
      tld      = optional(string)
      base_url = string
    })
  })
}

variable "foundation_identity" {
  description = "foundation-identity contract v2 (fields used): the per-environment DSV-reader identity of the host Agents (identities[\"obs-host-agent\"])."
  type = object({
    identities = map(object({
      id        = string
      client_id = string
    }))
  })
}

variable "artifacts" {
  description = "Immutable build outputs (tools/deploy/artifacts.py tfvars); img-dsv-fetch version / package_sha256 are recorded on the package for traceability."
  type = map(object({
    name           = optional(string)
    version        = optional(string)
    package_url    = optional(string)
    package_sha256 = optional(string)
    commit         = optional(string)
  }))
  default = {}
}

# direct mode only (settings.mode = direct): the hosts to assign. In policy mode these contracts are not needed - the
# platform roots tag their VMs / VMSS with datadog:enabled = true.
variable "platform_vm" {
  description = "platform-vm contract (optional; direct mode)."
  type = object({
    vms = map(object({
      id      = string
      os_type = string
    }))
  })
  default = null
}

variable "platform_vmss" {
  description = "platform-vmss contract (optional; direct mode: output vmss_gallery_applications for the platform root)."
  type = object({
    scale_sets = map(object({
      id      = string
      os_type = string
    }))
  })
  default = null
}

variable "platform_db_sqlvm" {
  description = "platform-db-sqlvm contract (optional; direct mode): the SQL Server VM gets the Agent."
  type = object({
    vm = object({
      id = string
    })
  })
  default = null
}
