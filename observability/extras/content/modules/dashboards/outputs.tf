output "service_dashboard_urls" {
  description = "Service -> dashboard URL path."
  value       = { for k, d in datadog_dashboard_json.service : k => d.url }
}

output "overview_url" {
  description = "Overview dashboard URL path (null when disabled)."
  value       = try(datadog_dashboard_json.overview[0].url, null)
}

output "rendered" {
  description = "Rendered dashboard JSON documents (review/tests)."
  value = merge(
    { for k, s in var.services : k => templatefile("${path.module}/templates/service.json.tftpl", { title = k, description = "", env = s.env, widgets = local.service_widgets[k] }) },
    { "__overview__" = templatefile("${path.module}/templates/overview.json.tftpl", { title = var.overview.title, description = "", env = var.overview.env, widgets = local.overview_widgets }) },
  )
}
