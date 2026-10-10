variable "fleet_policy" {
  description = "Decoded fleet policy (null = package default): agent.upgrade_schedule (enabled, days_of_week, start, duration_minutes, timezone, version_to_latest)."
  type        = any
  default     = null
}

variable "name" {
  description = "Schedule name in Datadog Fleet Automation."
  type        = string
}

variable "host_query" {
  description = "Datadog host query selecting the Agents this schedule upgrades, e.g. env:prod AND managed_by:terraform (use tag-policy tags)."
  type        = string
  validation {
    condition     = length(trimspace(var.host_query)) > 0
    error_message = "host_query must select hosts (Datadog host query, e.g. env:dev)."
  }
}

variable "enabled" {
  description = "Override the policy's agent.upgrade_schedule.enabled (null = policy)."
  type        = bool
  default     = null
}
