output "contract" {
  description = "deploy-jobs contract v1 (catalog/contracts/deploy-jobs.v1.schema.json). No secrets."
  value = {
    component           = local.component
    architecture        = "container-apps-jobs"
    resource_group_name = azurerm_resource_group.this.name
    jobs = {
      for k, j in azurerm_container_app_job.this : k => {
        id            = j.id
        name          = j.name
        type          = "Microsoft.App/jobs"
        service       = local.jobs[k].svc
        trigger       = local.jobs[k].trigger
        schedule      = try(local.jobs[k].cron, null)
        command       = join(" ", local.jobs[k].args)
        app_log_route = "eventhub" # stdout -> ContainerAppConsoleLogs diagnostic setting (no sidecar on jobs)
        version       = local.artifact_version[module.meta.services[local.jobs[k].svc].artifact]
        image         = try(var.artifacts[module.meta.services[local.jobs[k].svc].artifact].image, null)
      }
    }
    apps = {
      for k, j in azurerm_container_app_job.this : "${local.jobs[k].svc}-${k}" => {
        id             = j.id
        name           = j.name
        type           = "Microsoft.App/jobs"
        service        = local.jobs[k].svc
        architecture   = "container-apps-job-${local.jobs[k].trigger == "event" ? "event" : (local.jobs[k].trigger == "manual" ? "manual" : "scheduled")}"
        app_log_route  = "eventhub"
        sidecar        = false
        url            = null
        urls           = { public = null, private = null }
        health_path    = null
        readiness_path = null
        version_path   = null
        scale_to_zero  = true
        min_replicas   = 0
        max_replicas   = local.jobs[k].trigger == "event" ? var.settings.batch_processor.max_executions : 1
        version        = local.artifact_version[module.meta.services[local.jobs[k].svc].artifact]
        image          = try(var.artifacts[module.meta.services[local.jobs[k].svc].artifact].image, null)
        identity_name  = local.jobs[k].svc
      }
    }
    endpoints     = {}
    idle_behavior = { for k in keys(azurerm_container_app_job.this) : "${local.jobs[k].svc}-${k}" => { scale_to_zero = true } }
    batch = var.platform_batch == null ? null : {
      account_name   = var.platform_batch.account_name
      account_host   = trimprefix(var.platform_batch.account_endpoint, "https://")
      pool_id        = var.platform_batch.pool.name
      job_id         = "hello-jobs-daily-aggregate"
      package_uri    = try(var.artifacts["svc-jobs"].package_url, null)
      package_sha256 = try(var.artifacts["svc-jobs"].package_sha256, null)
      submit_script  = "applications/deployments/jobs/scripts/submit-batch-job.sh"
      identity_id    = var.platform_batch.identity.id
    }
    deploy_steps = var.platform_batch == null ? [] : [{
      kind           = "batch-job"
      app            = "hello-jobs-daily-aggregate"
      resource_id    = null
      name           = var.platform_batch.account_name
      resource_group = null
      package_uri    = try(var.artifacts["svc-jobs"].package_url, null)
      package_sha256 = try(var.artifacts["svc-jobs"].package_sha256, null)
      slot           = null
    }]
    rollback = {
      method = "redeploy-previous-digest"
      how    = "re-apply with the previous svc-jobs / svc-traffic digests; Batch: re-submit with the previous package"
    }
  }
}
