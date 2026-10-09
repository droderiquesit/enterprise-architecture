variable "component" {
  type    = string
  default = "applications"
}

variable "version_label" {
  type    = string
  default = "unknown"
}

locals {
  # systemd EnvironmentFile lines: KEY="value" with backslashes and quotes escaped.
  env_lines = join("", [for k in sort(keys(var.env)) : "${k}=\"${replace(replace(var.env[k], "\\", "\\\\"), "\"", "\\\"")}\"\n"])

  script = templatefile("${path.module}/templates/linux-install.sh.tftpl", {
    component      = var.component
    app            = var.app
    version        = var.version_label
    client_id      = var.client_id
    package_url    = var.package.url
    package_sha256 = var.package.sha256
    env_b64        = base64encode(local.env_lines)
    secrets        = var.secret_env
    mode           = var.mode
    health_url     = var.health_url
    python_module  = coalesce(var.python_module, "x")
    pip_packages   = join(" ", var.pip_packages)
  })
}

output "script" {
  description = "Rendered bash install script (no secret values; secrets are fetched on the host)."
  value       = local.script
}

output "env_file" {
  value = local.env_lines
}
