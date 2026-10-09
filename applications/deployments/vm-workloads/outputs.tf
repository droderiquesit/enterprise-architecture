locals {
  resource_ids = merge(
    contains(keys(local.hosts), "worker-vm") ? { "worker-vm" = local.linux_vm.id } : {},
    contains(keys(local.hosts), "inventory-vm") ? { "inventory-vm" = local.windows_vm.id } : {},
    contains(keys(local.hosts), "worker-vmss") ? { "worker-vmss" = local.flex.id } : {},
  )
  private_url = {
    "worker-vm"    = try("http://${local.linux_vm.private_ip}:8081", null)
    "inventory-vm" = try("http://${local.windows_vm.private_ip}:8080", null)
    "worker-vmss"  = null
  }
}

output "contract" {
  description = "deploy-vm-workloads contract v1 (catalog/contracts/deploy-vm-workloads.v1.schema.json). No secrets."
  value = {
    component    = local.component
    architecture = "vm"
    apps = {
      for k, h in local.hosts : k => {
        id             = local.resource_ids[k]
        name           = h.host.name
        type           = h.arch == "vmss" ? "Microsoft.Compute/virtualMachineScaleSets" : "Microsoft.Compute/virtualMachines"
        service        = h.svc
        architecture   = h.arch == "vmss" ? "vmss-flexible" : (h.svc == "hello-worker" ? "vm-linux" : "vm-windows")
        app_log_route  = module.env[k].log_route
        sidecar        = false
        url            = local.private_url[k]
        urls           = { public = null, private = local.private_url[k] }
        health_path    = "/healthz"
        readiness_path = "/readyz"
        version_path   = h.svc == "hello-worker" ? null : "/version"
        scale_to_zero  = false
        min_replicas   = 1
        max_replicas   = 1
        version        = local.artifact_version[module.meta.services[h.svc].artifact]
        image          = null
        identity_name  = h.identity
        log_file       = local.log_file[k]
      }
    }
    endpoints     = contains(keys(local.hosts), "inventory-vm") ? { "inventory-vm" = local.private_url["inventory-vm"] } : {}
    idle_behavior = { for k in keys(local.hosts) : k => { scale_to_zero = false } }
    deploy_steps = contains(keys(local.hosts), "worker-vmss") ? [{
      kind           = "vmss-flex-rollout"
      app            = "worker-vmss"
      resource_id    = local.flex.id
      name           = local.flex.name
      resource_group = local.ss.resource_group_name
      package_uri    = try(local.pkg["worker-vmss"].package_url, null)
      package_sha256 = try(local.pkg["worker-vmss"].package_sha256, null)
      slot           = null
    }] : []
    rollback = {
      method = "reinstall-previous-package"
      how    = "re-apply with the previous svc-worker / svc-inventory-api package (run command / extension re-runs; the installers keep previous releases and auto-rollback on failed health checks; worker: install.sh --rollback)"
    }
  }
}

# Not part of the contract: the rendered install script for the VMSS Flexible rollout step
# (scripts/deploy-zip.sh runs it on existing instances with `az vm run-command invoke`). No secret values.
output "vmss_rollout_script" {
  description = "Rendered hello-worker install script for existing VMSS Flexible instances (null when no flex scale set)."
  value       = contains(keys(local.hosts), "worker-vmss") ? module.linux_script["worker-vmss"].script : null
}
