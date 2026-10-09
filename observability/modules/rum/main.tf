# Datadog RUM application(s). Create these BEFORE the frontend is deployed: the frontend's runtime
# config.json needs application_id + client_token.
resource "datadog_rum_application" "this" {
  for_each = var.applications

  name = each.value.name
  type = each.value.type
}
