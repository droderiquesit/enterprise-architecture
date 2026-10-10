output "image" {
  description = "Collector image of the selected distribution (upstream contrib or DDOT, pinned)."
  value       = local.image
}

output "args" {
  description = "Collector arguments (config read from env vars through the env: config provider)."
  value       = local.args
}

output "config_env" {
  description = "Env var name -> collector YAML (base + overlays)."
  value       = local.configs
}

output "config_env_order" {
  description = "Env variables holding the configuration documents, in --config=env: order (OTELCOL_CONFIG_BASE first, later ones override)."
  value       = local.order
}

output "env" {
  description = "Non-secret runtime env."
  value       = local.env
}

output "secret_files" {
  description = "File names (in secrets_dir) the config reads with the confmap file provider; written by dsv-fetch init --format files."
  value       = local.secret_files
}

output "secrets_dir" {
  description = "Directory of the secret files (ephemeral volume shared with the dsv-fetch init container)."
  value       = local.secrets_dir
}

output "ports" {
  description = "Container ports: OTLP gRPC / HTTP, health check, self metrics."
  value       = { otlp_grpc = 4317, otlp_http = 4318, health = 13133, self_metrics = 8888 }
}
