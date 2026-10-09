variable "app" {
  description = "Service / systemd unit name, e.g. hello-worker."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,40}$", var.app))
    error_message = "app must be a lowercase unit name."
  }
}

variable "mode" {
  description = "package-install-sh: run deploy/install.sh shipped in the package (hello-worker). python-service: generic wheelhouse install + systemd unit running `python -m <module>`."
  type        = string
  validation {
    condition     = contains(["package-install-sh", "python-service"], var.mode)
    error_message = "mode must be package-install-sh or python-service."
  }
}

variable "python_module" {
  description = "python-service mode: module run with `python -m` (e.g. hello_dbadapter)."
  type        = string
  default     = null
}

variable "pip_packages" {
  description = "python-service mode: distributions installed from the wheelhouse (e.g. [hello-common, hello-dbadapter])."
  type        = list(string)
  default     = []
}

variable "health_url" {
  type    = string
  default = "http://127.0.0.1:8080/healthz"
}

variable "client_id" {
  description = "User-assigned identity client id used for IMDS tokens (storage + Key Vault)."
  type        = string
}

variable "package" {
  description = "Immutable package: https blob URL (read with the identity, no SAS) + sha256."
  type = object({
    url    = string
    sha256 = string
  })
}

variable "env" {
  description = "Non-secret environment written to /etc/<app>/<app>.env."
  type        = map(string)
}

variable "secret_env" {
  description = "Secret environment: name -> versionless Key Vault secret id, resolved ON THE HOST via IMDS (never in state)."
  type        = map(string)
  default     = {}
}
