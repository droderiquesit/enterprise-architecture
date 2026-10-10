# obs-hosts publishes no contract; outputs are evidence for the deployment record.
output "mode" {
  description = "policy | direct."
  value       = module.hosts.mode
}

output "enrollment_tag" {
  description = "Tag the platform roots set on VMs / VMSS (policy mode): name = value."
  value       = module.hosts.enrollment_tag
}

output "applications" {
  description = "VM Applications and the version this environment pins (promotion = bump settings.package_version)."
  value       = module.hosts.applications
}

output "agent_version" {
  description = "Datadog Agent version of the pinned package (fleet policy agent.version)."
  value       = module.hosts.agent_version
}

output "policy" {
  description = "Policy assignment / initiative / remediation identity and tasks (policy mode)."
  value       = module.hosts.policy
}

output "assignments" {
  description = "direct mode: VM -> gallery application assignment id."
  value       = module.hosts.assignments
}

output "vmss_gallery_applications" {
  description = "direct mode: VMSS -> gallery_application block for the platform-vmss root."
  value       = module.hosts.vmss_gallery_applications
}

output "otlp_endpoint" {
  description = "OTLP endpoint of the host Agents for otel-mode workloads on the hosts."
  value       = module.hosts.otlp_endpoint
}

output "host_log_paths" {
  description = "Log files the Agent tails on every enrolled host (app deployments write LOG_FILE_PATH there); hosts add more with the datadog:log_paths tag."
  value = {
    linux   = [for f in try(var.settings.host_logs.linux.files, []) : f.path]
    windows = [for f in try(var.settings.host_logs.windows.files, []) : f.path]
  }
}
