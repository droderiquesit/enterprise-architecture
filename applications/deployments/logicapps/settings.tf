variable "settings" {
  description = "deploy-logicapps settings (environments/<env>/environment.yaml components.deploy-logicapps)."
  type = object({
    consumption_enabled   = optional(bool, true)
    consumption_frequency = optional(string, "Hour")
    consumption_interval  = optional(number, 1)
    batch_items           = optional(number, 10) # items per hourly batch request (<= 50)
    # Actions of the Consumption workflow (JSON object of Logic Apps actions); default ships in workflows/.
    actions_file      = optional(string)
    standard_enabled  = optional(bool, true)
    archive_container = optional(string, "audit-archive")
    # Service Bus subscription read by the Standard audit-archive workflow (platform-messaging must provide it;
    # sharing `audit` with hello-functions would split messages between consumers).
    archive_subscription = optional(string, "archive")
    network_mode         = optional(string, "auto")
    allowed_ip_ranges    = optional(list(string), [])
  })
  default = {}

  validation {
    condition     = var.settings.batch_items >= 1 && var.settings.batch_items <= 50 && contains(["Minute", "Hour", "Day"], var.settings.consumption_frequency)
    error_message = "batch_items 1..50; consumption_frequency Minute|Hour|Day."
  }
}
