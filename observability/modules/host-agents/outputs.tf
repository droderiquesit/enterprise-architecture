output "agent_extensions" {
  description = "host key -> extension id."
  value = merge(
    { for k, e in azurerm_virtual_machine_extension.datadog : k => e.id },
    { for k, e in azurerm_virtual_machine_scale_set_extension.datadog : k => e.id },
  )
}

output "setup" {
  description = "host key -> run command / CustomScript extension id."
  value = merge(
    { for k, r in azurerm_virtual_machine_run_command.setup : k => r.id },
    { for k, r in azurerm_virtual_machine_scale_set_extension.setup : k => r.id },
  )
}

output "otlp_endpoint" {
  description = "OTLP endpoint apps on these hosts use (Agent receiver on localhost)."
  value       = { grpc = "http://localhost:4317", http = "http://localhost:4318" }
}

output "scripts_sha256" {
  value = { for k, s in local.scripts : k => sha256(s) }
}

output "installer_scripts" {
  description = "Rendered installers (no secrets: the API key is fetched at run time). Useful for image baking."
  value       = local.scripts
}
