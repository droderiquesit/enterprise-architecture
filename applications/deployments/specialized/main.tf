# Specialized compute workloads:
#   Service Fabric managed cluster  hello-inventory-api guest executable  (azurerm has no SF application resources:
#                                   manifests rendered here, deployed by scripts/deploy-sf.sh with sfctl)
#   ARO                             hello-catalog-api                    (manifests rendered here, scripts/deploy-aro.sh, oc)
#   Confidential VM                 hello-worker                         (managed run command)
#   Automation                      python3 health-probe runbook          (azurerm_automation_runbook + job schedule)
module "meta" {
  source = "../modules/service-meta"
}

locals {
  sf   = var.platform_servicefabric
  aro  = var.platform_aro
  spec = var.platform_specialized_compute
  ids  = try(var.foundation_identity.identities, {})

  sf_enabled  = try(local.sf.enabled, false)
  aro_enabled = try(local.aro.enabled, false)
  cvm         = var.settings.cvm_worker ? try(local.spec.vms["cvm"], null) : null
  cvm_enabled = local.cvm != null && contains(keys(local.ids), try(local.cvm.workload, ""))
  automation  = try(local.spec.automation, null)

  inv_version = lookup(local.artifact_version, "svc-inventory-api", "unknown")
  cat_version = lookup(local.artifact_version, "svc-catalog-api", "unknown")
}

module "env" {
  source = "../modules/app-env"
  for_each = merge(
    local.sf_enabled ? { sf = { svc = "hello-inventory-api", arch = "vm", extra = var.settings.sf_inventory_env } } : {},
    local.aro_enabled ? { aro = { svc = "hello-catalog-api", arch = "aks", extra = var.settings.aro_catalog_env } } : {},
    local.cvm_enabled ? { cvm = { svc = "hello-worker", arch = "vm", extra = var.settings.cvm_env } } : {},
  )
  service = {
    name    = each.value.svc
    version = lookup(local.artifact_version, module.meta.services[each.value.svc].artifact, "unknown")
    commit  = lookup(local.artifact_commit, module.meta.services[each.value.svc].artifact, "unknown")
    env     = local.env_name
    team    = module.meta.services[each.value.svc].team
    owner   = module.meta.services[each.value.svc].owner
    domain  = module.meta.services[each.value.svc].domain
    tier    = module.meta.services[each.value.svc].tier
    region  = local.location
  }
  runtime            = module.meta.services[each.value.svc].runtime
  architecture       = each.value.arch
  telemetry          = var.obs_telemetry_transport
  identity_client_id = try(local.ids[each.value.svc == "hello-worker" ? local.cvm.workload : each.value.svc].client_id, null)
  faults             = { enabled = false }
  port               = each.value.svc == "hello-worker" ? 8081 : 8080
  log_level          = var.settings.log_level
  extra_env          = each.value.extra
}

# ---------------------------------------------------------------- Service Fabric (rendered manifests)
locals {
  sf_type_version = coalesce(var.settings.sf_app_type_version, replace(local.inv_version, "/[^0-9A-Za-z.]/", "."))
  sf_env          = local.sf_enabled ? merge(module.env["sf"].env, { PORT = tostring(try(local.sf.app_port, 8080)), LOG_FILE_PATH = "D:\\SvcFab\\Log\\hello\\inventory-api.log" }) : {}
  sf_service_manifest = local.sf_enabled ? templatefile("${path.module}/templates/ServiceManifest.xml.tftpl", {
    version = local.sf_type_version
    port    = try(local.sf.app_port, 8080)
    env     = local.sf_env
  }) : null
  sf_app_manifest = local.sf_enabled ? templatefile("${path.module}/templates/ApplicationManifest.xml.tftpl", {
    version = local.sf_type_version
  }) : null
}

# ---------------------------------------------------------------- ARO (rendered manifests)
locals {
  aro_env = local.aro_enabled ? module.env["aro"].env : {}
  aro_manifest = local.aro_enabled ? join("\n---\n", [
    yamlencode({
      apiVersion = "apps/v1", kind = "Deployment"
      metadata   = { name = "hello-catalog-api", namespace = var.settings.aro_namespace, labels = module.env["aro"].k8s_patch_object.metadata.labels }
      spec = {
        replicas = 2
        selector = { matchLabels = { "app.kubernetes.io/name" = "hello-catalog-api" } }
        template = {
          metadata = { labels = merge(module.env["aro"].k8s_patch_object.spec.template.metadata.labels, { "app.kubernetes.io/name" = "hello-catalog-api" }) }
          spec = {
            securityContext = { runAsNonRoot = true, seccompProfile = { type = "RuntimeDefault" } }
            containers = [{
              name  = "hello-catalog-api"
              image = try(var.artifacts["svc-catalog-api"].image, null)
              ports = [{ containerPort = 8080, name = "http" }]
              env = concat(
                [{ name = "DD_AGENT_HOST", valueFrom = { fieldRef = { fieldPath = "status.hostIP" } } }],
                [for k in sort(keys(local.aro_env)) : { name = k, value = local.aro_env[k] }],
              )
              resources       = { requests = { cpu = "100m", memory = "192Mi" }, limits = { cpu = "500m", memory = "512Mi" } }
              livenessProbe   = { httpGet = { path = "/healthz", port = 8080 }, periodSeconds = 15 }
              readinessProbe  = { httpGet = { path = "/readyz", port = 8080 }, periodSeconds = 10 }
              securityContext = { allowPrivilegeEscalation = false, readOnlyRootFilesystem = true, capabilities = { drop = ["ALL"] } }
              volumeMounts    = [{ name = "tmp", mountPath = "/tmp" }]
            }]
            volumes = [{ name = "tmp", emptyDir = { sizeLimit = "256Mi" } }]
          }
        }
      }
    }),
    yamlencode({
      apiVersion = "v1", kind = "Service"
      metadata   = { name = "hello-catalog-api", namespace = var.settings.aro_namespace }
      spec       = { selector = { "app.kubernetes.io/name" = "hello-catalog-api" }, ports = [{ name = "http", port = 80, targetPort = "http" }] }
    }),
    yamlencode({
      apiVersion = "route.openshift.io/v1", kind = "Route"
      metadata   = { name = "hello-catalog-api", namespace = var.settings.aro_namespace }
      spec       = { to = { kind = "Service", name = "hello-catalog-api" }, port = { targetPort = "http" }, tls = { termination = "edge", insecureEdgeTerminationPolicy = "Redirect" } }
    }),
  ]) : null
}

# ---------------------------------------------------------------- Confidential VM worker
module "cvm_script" {
  source = "../modules/vm-script"
  count  = local.cvm_enabled ? 1 : 0

  component     = local.component
  app           = "hello-worker"
  mode          = "package-install-sh"
  health_url    = "http://127.0.0.1:8081/healthz"
  client_id     = local.ids[local.cvm.workload].client_id
  version_label = lookup(local.artifact_version, "svc-worker", "unknown")
  package = {
    url    = try(var.artifacts["svc-worker"].package_url, "")
    sha256 = try(var.artifacts["svc-worker"].package_sha256, "")
  }
  env = merge(module.env["cvm"].env, { LOG_FILE_PATH = "/var/log/hello-worker/worker.log" }, var.platform_messaging == null ? { MESSAGING_MODE = "memory" } : {
    MESSAGING_MODE                                          = "servicebus"
    SERVICEBUS_FQDN                                         = var.platform_messaging.fqdn
    SB_TOPIC                                                = var.platform_messaging.topic.name
    SB_SUBSCRIPTION                                         = var.platform_messaging.subscriptions["notifications"].name
    }, var.platform_db_table_storage == null ? { TABLE_MODE = "memory" } : {
    TABLE_MODE                                              = "table"
    TABLES_ENDPOINT                                         = var.platform_db_table_storage.account.endpoint
    TABLE_NAME                                              = "notifications"
  })
}

resource "azurerm_virtual_machine_run_command" "cvm_worker" {
  count              = local.cvm_enabled ? 1 : 0
  name               = "install-hello-worker-cvm"
  location           = local.location
  virtual_machine_id = local.cvm.id
  tags               = merge(local.tags, { service = "hello-worker", version = lookup(local.artifact_version, "svc-worker", "unknown") })
  source {
    script = module.cvm_script[0].script
  }
}

# ---------------------------------------------------------------- Automation runbook
resource "azurerm_automation_runbook" "health_probe" {
  count                   = local.automation != null ? 1 : 0
  name                    = "hello-health-probe"
  location                = local.location
  resource_group_name     = local.spec.resource_group_name
  automation_account_name = local.automation.account_name
  runbook_type            = "Python3"
  log_progress            = false
  log_verbose             = false
  description             = "Enterprise Hello health probe (/healthz + /readyz on settings.probe_urls)"
  content                 = file("${path.module}/templates/health-probe.py")
  tags                    = merge(local.tags, { service = "hello-health-probe" })
}

resource "azurerm_automation_job_schedule" "health_probe" {
  count                   = local.automation != null && length(var.settings.probe_urls) > 0 ? 1 : 0
  resource_group_name     = local.spec.resource_group_name
  automation_account_name = local.automation.account_name
  runbook_name            = azurerm_automation_runbook.health_probe[0].name
  schedule_name           = local.automation.schedule_name
  parameters              = { probe_urls = join(",", var.settings.probe_urls) }
}
