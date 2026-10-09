output "files" {
  description = "Config files keyed by path relative to the config directory; mount them together (main file: fluent-bit.yaml)."
  value       = local.files
}

output "main_config" {
  value = local.files["fluent-bit.yaml"]
}

output "env" {
  description = "Non-secret environment for this role."
  value       = local.env
}

output "secret_env_names" {
  description = "Variable names whose values dsv-fetch must write into secrets_env_file (Fluent Bit env-yaml include), from Delinea DSV."
  value       = local.secret_env
}

output "files_sha256" {
  description = "Hash over all files (use to roll pods / re-run installers when config changes)."
  value       = sha256(join("\n", [for k in sort(keys(local.files)) : "${k}:${sha256(local.files[k])}"]))
}

output "secrets_env_file" {
  description = "Absolute path of the dsv-fetch env-yaml file the main config includes (must exist before Fluent Bit starts)."
  value       = local.secrets_file
}
