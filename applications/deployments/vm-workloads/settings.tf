variable "settings" {
  description = "deploy-vm-workloads settings (environments/<env>/environment.yaml components.deploy-vm-workloads)."
  type = object({
    faults_enabled     = optional(bool, false)
    log_level          = optional(string, "info")
    trace_sample_ratio = optional(number, 1)
    linux_worker       = optional(bool, true)  # hello-worker on the platform-vm Linux VM (run command)
    windows_inventory  = optional(bool, true)  # hello-inventory-api Windows service on the platform-vm Windows VM
    vmss_worker        = optional(bool, true)  # hello-worker on the platform-vmss Flexible scale set (extension)
    package_force      = optional(string, "1") # bump to force re-run of run commands / extensions
    worker_concurrency = optional(number, 8)
  })
  default = {}
}
