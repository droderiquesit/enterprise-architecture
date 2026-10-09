output "env" {
  description = "Environment the routing applies to."
  value       = var.routing.metadata.env
}

output "route_handles" {
  description = "Route key -> list of @-handles."
  value       = { for k, r in var.routing.routes : k => r.handles }
}

output "route_keys" {
  description = "Defined route keys."
  value       = sort(keys(var.routing.routes))
}

output "webhook_names" {
  description = "Names of webhooks created (reference as @webhook-<name>)."
  value       = sort(keys(datadog_webhook.this))
}
