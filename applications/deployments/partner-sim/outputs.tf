locals {
  url = local.fqdn == null ? "http://${azurerm_container_group.this.ip_address}:8080" : "http://${local.fqdn}:8080"
}

output "contract" {
  description = "deploy-partner-sim contract v1 (catalog/contracts/deploy-partner-sim.v1.schema.json). No secrets."
  value = {
    component           = local.component
    architecture        = "container-instances"
    resource_group_name = azurerm_resource_group.this.name
    # Private, VNet-only HTTP endpoint (ACI has no TLS termination; traffic stays in the spoke VNet).
    url = local.url
    container_group = {
      id         = azurerm_container_group.this.id
      name       = azurerm_container_group.this.name
      private_ip = azurerm_container_group.this.ip_address
      dns_name   = local.fqdn
    }
    apps = {
      (local.svc) = {
        id             = azurerm_container_group.this.id
        name           = azurerm_container_group.this.name
        type           = "Microsoft.ContainerInstance/containerGroups"
        service        = local.svc
        architecture   = "aci"
        app_log_route  = module.env.log_route
        sidecar        = local.sidecar != null
        url            = local.url
        urls           = { public = null, private = local.url }
        health_path    = "/healthz"
        readiness_path = "/readyz"
        version_path   = "/version"
        scale_to_zero  = false
        min_replicas   = 1
        max_replicas   = 1
        version        = local.artifact_version[local.artifact]
        image          = try(var.artifacts[local.artifact].image, null)
        identity_name  = local.svc
      }
    }
    endpoints     = { (local.svc) = local.url }
    idle_behavior = { (local.svc) = { scale_to_zero = false } }
    rollback = {
      method = "recreate-previous-digest"
      how    = "re-run the deployment with the previous svc-partner-sim digest: the container group is updated/recreated (brief outage; single instance)"
    }
  }
}
