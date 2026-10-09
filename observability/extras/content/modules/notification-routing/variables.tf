variable "routing" {
  description = "Decoded NotificationRouting document (schemas/notification-routing.v1.schema.json), e.g. yamldecode(file(\"routing/prod.yaml\"))."
  type = object({
    apiVersion = optional(string, "observability/v1")
    kind       = optional(string, "NotificationRouting")
    metadata   = object({ env = string, description = optional(string, "") })
    routes = map(object({
      description = optional(string, "")
      handles     = list(string)
    }))
    webhooks = optional(map(object({
      url       = string
      encode_as = optional(string, "json")
      payload   = optional(string)
    })), {})
  })

  validation {
    condition     = alltrue(flatten([for r in values(var.routing.routes) : [for h in r.handles : can(regex("^@[A-Za-z0-9_.@+-]+$", h))]]))
    error_message = "Every handle must be a Datadog @-mention such as @slack-channel, @pagerduty-service, @webhook-name or @user@example.com."
  }
  validation {
    condition     = alltrue([for w in values(var.routing.webhooks) : startswith(w.url, "https://")])
    error_message = "Webhook URLs must use https."
  }
}

variable "create_webhooks" {
  description = "Create datadog_webhook resources for routing.webhooks (requires an app key with webhook write permission)."
  type        = bool
  default     = false
}
