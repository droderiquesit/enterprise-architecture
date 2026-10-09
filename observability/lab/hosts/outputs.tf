# obs-hosts publishes no contract; outputs are evidence for the deployment record.
output "setup" {
  value = module.hosts.setup
}

output "otlp_endpoint" {
  value = module.hosts.otlp_endpoint
}

output "hosts" {
  description = "Host key -> log paths tailed by Fluent Bit (app deployments must write LOG_FILE_PATH there)."
  value       = { for k, h in local.hosts : k => h.log_paths }
}
