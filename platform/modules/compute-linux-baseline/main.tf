# Shared code module: renders the Linux OS-baseline cloud-init used by platform VM/VMSS roots.
terraform {
  required_version = ">= 1.14.0, < 2.0.0"
}

variable "component" {
  description = "Calling component id (written into the host README)."
  type        = string
}

variable "app_user" {
  description = "System user that owns the application files."
  type        = string
  default     = "hello"
}

variable "app_group" {
  description = "Primary group of app_user."
  type        = string
  default     = "hello"
}

variable "app_dir" {
  description = "Directory name under /opt, /etc and /var/log."
  type        = string
  default     = "hello"
}

variable "install_python" {
  description = "Install Python from the deadsnakes PPA (needs outbound HTTPS)."
  type        = bool
  default     = true
}

variable "python_version" {
  description = "Python version to install (ADR-0001 section 2: 3.13)."
  type        = string
  default     = "3.13"
}

locals {
  rendered = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    component      = var.component
    app_user       = var.app_user
    app_group      = var.app_group
    app_dir        = var.app_dir
    install_python = var.install_python
    python_version = var.python_version
  })
}

output "cloud_init" {
  description = "Rendered cloud-init YAML."
  value       = local.rendered
}

output "custom_data" {
  description = "base64-encoded cloud-init for custom_data."
  value       = base64encode(local.rendered)
}
