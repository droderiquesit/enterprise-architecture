# Maps route keys (used by manifests) to Datadog notification handles for one environment.
# Manifests never contain raw handles, so the same manifest can page in prod and only e-mail in dev.
resource "datadog_webhook" "this" {
  for_each = var.create_webhooks ? var.routing.webhooks : {}

  name      = each.key
  url       = each.value.url
  encode_as = each.value.encode_as
  payload   = each.value.payload
}
