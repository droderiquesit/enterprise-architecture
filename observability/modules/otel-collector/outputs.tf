output "image" {
  value = local.image
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
  value = local.order
}

output "env" {
  description = "Non-secret runtime env."
  value       = local.env
}

output "secret_env_names" {
  value = local.secret_env
}

output "ports" {
  value = { otlp_grpc = 4317, otlp_http = 4318, health = 13133, self_metrics = 8888 }
}
