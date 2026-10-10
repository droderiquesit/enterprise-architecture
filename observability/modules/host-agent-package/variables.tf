variable "resource_group_id" {
  description = "Existing resource group (ARM id) for the gallery, the package storage account and the gallery publisher identity."
  type        = string
  validation {
    condition     = can(regex("^/subscriptions/[^/]+/resource[gG]roups/[^/]+$", var.resource_group_id))
    error_message = "resource_group_id must be /subscriptions/<id>/resourceGroups/<name>."
  }
}

variable "location" {
  description = "Region of the gallery, the storage account and the source of every application version."
  type        = string
}

variable "names" {
  description = <<-EOT
    Resource names (callers use their naming module):
      gallery            : Azure Compute Gallery (letters, digits, '.', '_'; no '-')
      storage_account    : package storage account (3-24 lowercase letters/digits, globally unique)
      publisher_identity : user-assigned identity attached to the gallery (reads the package blobs at publish time)
      container          : blob container for packages (default vm-applications)
  EOT
  type = object({
    gallery            = string
    storage_account    = string
    publisher_identity = string
    container          = optional(string, "vm-applications")
  })
  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._]{0,79}$", var.names.gallery)) && can(regex("^[a-z0-9]{3,24}$", var.names.storage_account))
    error_message = "names.gallery: letters, digits, '.', '_' (no '-'); names.storage_account: 3-24 lowercase letters/digits."
  }
}

variable "package_version" {
  description = <<-EOT
    VM Application version published by this apply (Major.Minor.Patch, int32 each). A version is immutable once
    published (Azure forbids changing its package, configuration or commands): ANY change of the rendered installer
    or the dsv-fetch binary needs a new package_version (the plan fails otherwise). The pipeline bumps it and
    promotes the same value dev -> test -> prod (environments/<env>/environment.yaml).
  EOT
  type        = string
  validation {
    condition     = can(regex("^(0|[1-9][0-9]{0,8})\\.(0|[1-9][0-9]{0,8})\\.(0|[1-9][0-9]{0,8})$", var.package_version))
    error_message = "package_version must be Major.Minor.Patch (non-negative integers, no leading zeros)."
  }
}

variable "retained_versions" {
  description = "Previously published versions to keep in the gallery (rollback targets, instances still on them). Kept as they are (frozen); never re-published with new content."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for v in var.retained_versions : can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", v))])
    error_message = "retained_versions entries must be Major.Minor.Patch."
  }
}

variable "applications" {
  description = <<-EOT
    VM Applications to publish (key -> settings). Keys: linux (amd64), windows (amd64), linux_arm64 (optional).
    The application name is what the VM sees; the package file is the dsv-fetch binary for that OS / architecture.
  EOT
  type = map(object({
    name = optional(string)
  }))
  default = { linux = {}, windows = {} }
  validation {
    condition     = length(var.applications) > 0 && alltrue([for k in keys(var.applications) : contains(["linux", "windows", "linux_arm64"], k)])
    error_message = "applications keys must be linux, windows or linux_arm64."
  }
}

variable "dsv_fetch_release_dir" {
  description = <<-EOT
    Directory with the dsv-fetch release files (dsv-fetch-linux-amd64, dsv-fetch-linux-arm64,
    dsv-fetch-windows-amd64.exe, SHA256SUMS) staged by the pipeline from the dsv-fetch release. Every binary used is
    checked against SHA256SUMS at plan time and again on the host before it is installed.
  EOT
  type        = string
}

variable "replica_regions" {
  description = "Target regions of every version (each region where enrolled VMs / VMSS run; must include location). Empty = [location]."
  type = list(object({
    name                 = string
    regional_replicas    = optional(number, 1)
    storage_account_type = optional(string, "Standard_ZRS")
  }))
  default = []
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
  description = <<-EOT
    Delinea DSV endpoint (non-secret) and the CLIENT ID of the per-environment DSV-reader user-assigned identity that
    host-agent-policy attaches to every enrolled VM / VMSS (foundation-identity identities["obs-host-agent"]).
  EOT
  type = object({
    tenant             = optional(string)
    tld                = optional(string, "com")
    base_url           = optional(string)
    auth               = optional(string, "azure")
    timeout_seconds    = optional(number, 10)
    identity_client_id = string
  })
  validation {
    condition     = (var.dsv.tenant != null || var.dsv.base_url != null) && contains(["azure", "client_credentials"], var.dsv.auth)
    error_message = "dsv needs tenant or base_url; auth azure (hosts) or client_credentials (tests only)."
  }
  validation {
    condition     = can(regex("^[0-9a-fA-F-]{36}$", var.dsv.identity_client_id))
    error_message = "dsv.identity_client_id must be the client id (GUID) of the DSV-reader identity."
  }
}

variable "env" {
  description = "Environment name (Agent `env` when the instance has no env tag)."
  type        = string
}

variable "fleet_policy" {
  description = "Decoded fleet policy (null = package default): Agent version pin, log pipeline / collector, SSI and library versions, Remote Configuration / remote updates, process collection."
  type        = any
  default     = null
}

variable "tag_policy" {
  description = "Decoded tag policy (null = package default): which Azure instance tags become which Datadog host tags, static tags."
  type        = any
  default     = null
}

variable "extra_tags" {
  description = "Additional static Datadog host tags (used when the instance has no Azure tag for that key)."
  type        = map(string)
  default     = {}
}

variable "log_pipeline" {
  description = "Override the fleet policy log_pipeline (observability_pipelines | fluent_bit_direct). On hosts the Agent collects either way; fluent_bit_direct only skips the OP Worker."
  type        = string
  default     = null
}

variable "op_agent_logs_url" {
  description = "Observability Pipelines Worker Datadog Agent source URL (transport contract aggregator.agent_logs_url); required in observability_pipelines mode."
  type        = string
  default     = null
}

variable "host_logs" {
  description = <<-EOT
    Host log collection by the Agent. Default (null fields): the fleet policy `logs.hosts` section (package defaults
    in config/fleet-policy.yaml; per-environment via environments.<env>.logs.hosts). A field set here wins over the
    policy. Per OS: `files` (path, optional service / source; null service = the instance's service tag) and, on
    Windows, Event Log `event_channels`. Hosts add files with the Azure tag <metadata_tag_prefix>log_paths.
  EOT
  type = object({
    linux = optional(object({
      files = optional(list(object({
        path    = string
        service = optional(string)
        source  = optional(string)
      })))
    }), {})
    windows = optional(object({
      files = optional(list(object({
        path    = string
        service = optional(string)
        source  = optional(string)
      })))
      event_channels = optional(list(object({
        channel = string
        source  = optional(string, "windows.events")
      })))
    }), {})
  })
  default = {}
  validation {
    condition = alltrue(concat(
      [for f in coalesce(var.host_logs.linux.files, []) : startswith(f.path, "/") && !strcontains(f.path, "'") && !strcontains(f.path, "\"")],
      [for f in coalesce(var.host_logs.windows.files, []) : can(regex("^[A-Za-z]:\\\\", f.path)) && !strcontains(f.path, "'") && !strcontains(f.path, "\"")],
      [for c in coalesce(var.host_logs.windows.event_channels, []) : can(regex("^[A-Za-z0-9 ._/-]+$", c.channel))],
    ))
    error_message = "host_logs: Linux paths absolute, Windows paths drive-rooted (C:\\...), no quotes; event channels [A-Za-z0-9 ._/-]."
  }
}

variable "default_service" {
  description = "Agent log `service` when the instance has no service tag."
  type        = string
  default     = "platform"
}

variable "default_source" {
  description = "Agent log `source` per OS when neither the file entry nor the <metadata_tag_prefix>source tag sets one."
  type = object({
    linux   = optional(string, "python")
    windows = optional(string, "csharp")
  })
  default = {}
}

variable "metadata_tag_prefix" {
  description = "Prefix of the per-host Azure tags the installer reads (<prefix>log_paths, <prefix>source); the enrolment tag is <prefix>enabled by default."
  type        = string
  default     = "datadog:"
}

variable "agent_msi_sha256" {
  description = "Pinned SHA256 of the Windows Agent MSI per Agent version (Datadog publishes no checksum file). Value for 7.84.2 computed 2026-10-09; add the new version's hash together with the version bump."
  type        = map(string)
  nullable    = false
  default = {
    "7.84.2" = "9ebecc6f16fad77df6dd14cf55d7edf84587cdf43f259442301bd6f2671b0b86"
  }
}

variable "publisher_principal_ids" {
  description = "Principals (e.g. the pipeline apply identity) granted Storage Blob Data Contributor on the package container so Terraform can upload the blobs with Entra ID (storage_use_azuread). Empty when granted elsewhere."
  type        = list(string)
  default     = []
}

variable "network" {
  description = "Package storage account network access: default deny; the gallery reads through its managed identity as a trusted service. ip_rules / subnet_ids admit the publishing pipeline agents."
  type = object({
    public_network_access_enabled = optional(bool, true)
    ip_rules                      = optional(list(string), [])
    subnet_ids                    = optional(list(string), [])
  })
  default = {}
}

variable "tags" {
  description = "Azure resource tags."
  type        = map(string)
  default     = {}
}
