variable "component" {
  description = "Deployment root (component id) named in the rendered script header."
  type        = string
  default     = "applications"
}

variable "version_label" {
  description = "Release version shown in the script header and logs."
  type        = string
  default     = "unknown"
}

locals {
  # systemd EnvironmentFile lines: KEY="value" with backslashes and quotes escaped.
  # secret settings are dsv:// references (not secrets): the service resolves them at start-up from Delinea DSV with
  # the VM's managed identity (hello_common / Hello.Common), so the env file never holds a secret value.
  all_env   = merge(var.env, var.secret_env)
  env_lines = join("", [for k in sort(keys(local.all_env)) : "${k}=\"${replace(replace(local.all_env[k], "\\", "\\\\"), "\"", "\\\"")}\"\n"])

  script = templatefile("${path.module}/templates/linux-install.sh.tftpl", {
    component      = var.component
    app            = var.app
    version        = var.version_label
    client_id      = var.client_id
    package_url    = var.package.url
    package_sha256 = var.package.sha256
    env_b64        = base64encode(local.env_lines)
    mode           = var.mode
    health_url     = var.health_url
    python_module  = coalesce(var.python_module, "x")
    pip_packages   = join(" ", var.pip_packages)
  })
}

output "script" {
  description = "Rendered bash install script (no secret values; secret settings are dsv:// references the service resolves)."
  value       = local.script
}

output "env_file" {
  description = "Rendered EnvironmentFile content (plain values and dsv:// references; no secret values)."
  value       = local.env_lines
}
