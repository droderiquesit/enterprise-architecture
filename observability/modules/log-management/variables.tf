variable "env" {
  description = "Environment name (dashboard default template variable, tags)."
  type        = string
}

variable "scope_query" {
  description = "Log query that selects the Azure platform / control-plane logs shipped by the Fluent Bit aggregator (ddsource azure.*; application categories carry azure_log_type:application and are excluded)."
  type        = string
  default     = "source:azure* -azure_log_type:application"
}

variable "index" {
  description = <<-EOT
    OPTIONAL dedicated log index for Azure platform logs (enabled = false by default: many organisations manage
    indexes centrally). IMPORTANT - index ORDER: a log is stored in the FIRST index whose filter matches. Assume an
    index created through the API lands behind existing ones (placement is not documented); with a catch-all index
    (filter "*", usually "main") in front it receives nothing. Either set index_order.manage = true (this module
    then owns the org-wide order) or check/move the index in Logs > Configuration > Indexes.
    exclusion_filters: sample_rate = fraction EXCLUDED from indexing (0.9 keeps 10 %). Log-based metrics and
    archives still see 100 % of the logs.
  EOT
  type = object({
    enabled                                  = optional(bool, false)
    name                                     = optional(string, "azure-platform")
    retention_days                           = optional(number, 15)
    flex_retention_days                      = optional(number)
    daily_limit                              = optional(number)
    daily_limit_warning_threshold_percentage = optional(number, 80)
    daily_limit_reset_time                   = optional(string, "00:00")
    daily_limit_reset_utc_offset             = optional(string, "+00:00")
    default_exclusions                       = optional(bool, true)
    exclusion_filters = optional(list(object({
      name        = string
      query       = string
      sample_rate = number
      enabled     = optional(bool, true)
    })), [])
  })
  default = {}
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,63}$", var.index.name))
    error_message = "index.name: lower-case letters, digits and dashes, starting with a letter."
  }
  validation {
    condition     = contains([3, 7, 15, 30, 45, 60, 90, 180, 360], var.index.retention_days)
    error_message = "index.retention_days must be a Datadog retention option (3, 7, 15, 30, 45, 60, 90, 180, 360)."
  }
  validation {
    condition     = alltrue([for f in var.index.exclusion_filters : f.sample_rate >= 0 && f.sample_rate <= 1])
    error_message = "exclusion_filters[*].sample_rate is the excluded fraction, 0..1."
  }
}

variable "index_order" {
  description = "Opt-in: manage the ORG-WIDE index order (datadog_logs_index_order). indexes must list EVERY index of the org in the desired order, including index.name (behaviour for unlisted indexes is not documented by Datadog)."
  type = object({
    manage  = optional(bool, false)
    indexes = optional(list(string), [])
  })
  default = {}
}

variable "pipeline" {
  description = <<-EOT
    OPTIONAL custom pipeline for Activity Log records (azure_log_type:activity). Datadog's Azure integration
    pipelines already remap operationName/resultType for most sources (e.g. azure.activedirectory, verified); enable
    this only when Logs > Pipelines shows no Azure pipeline for your Activity Log sources. All remappers preserve the
    source attribute and never override an existing target.
  EOT
  type = object({
    enabled = optional(bool, false)
    name    = optional(string, "Azure Activity Log enrichment (observability package)")
  })
  default = {}
}

variable "metrics" {
  description = "OPTIONAL log-based metrics (computed on 100 % of ingested logs, before index exclusion filters). Tags are bounded (subscription, resource group, resource name, source, category)."
  type = object({
    enabled = optional(bool, false)
    prefix  = optional(string, "azure.logs")
  })
  default = {}
  validation {
    condition     = can(regex("^[a-z][a-z0-9_.]{0,100}$", var.metrics.prefix))
    error_message = "metrics.prefix: lower-case metric namespace."
  }
}

variable "archive" {
  description = <<-EOT
    OPTIONAL Datadog log archive into an EXISTING Azure storage account container (off by default). Prerequisite:
    the Entra app of the Datadog Azure integration (client_id / tenant_id) holds Storage Blob Data Contributor on
    the container. Archives receive every log matching query, including logs excluded from indexing.
  EOT
  type = object({
    enabled         = optional(bool, false)
    name            = optional(string, "azure-platform-logs")
    query           = optional(string)
    storage_account = optional(string)
    container       = optional(string)
    path            = optional(string, "datadog/azure-platform")
    client_id       = optional(string)
    tenant_id       = optional(string)
    include_tags    = optional(bool, true)
  })
  default = {}
  validation {
    condition     = !var.archive.enabled || (var.archive.storage_account != null && var.archive.container != null && var.archive.client_id != null && var.archive.tenant_id != null)
    error_message = "archive.enabled requires storage_account, container, client_id and tenant_id."
  }
}

variable "dashboard" {
  description = "\"Azure platform logs\" dashboard (activity log, Entra ID, Key Vault, AKS audit, volume by source)."
  type = object({
    enabled = optional(bool, true)
    title   = optional(string)
    entra   = optional(bool, false) # add the Entra ID widgets (only meaningful when Entra logs are exported)
  })
  default = {}
}
