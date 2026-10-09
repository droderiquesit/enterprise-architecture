locals {
  bff_lb_ip  = try(data.kubernetes_service_v1.bff[0].status[0].load_balancer[0].ingress[0].ip, null)
  bff_origin = var.settings.exposure.mode == "app-routing" ? "https://${var.settings.exposure.host}" : (local.bff_lb_ip == null ? null : "http://${local.bff_lb_ip}")
}

output "contract" {
  description = "deploy-core-aks contract v1 (catalog/contracts/deploy-core-aks.v1.schema.json). No secrets."
  value = {
    component    = local.component
    architecture = "aks"
    cluster_id   = var.platform_aks.cluster_id
    namespace    = local.ns
    apps = {
      for k, r in helm_release.app : k => {
        id              = "${var.platform_aks.cluster_id}/namespaces/${local.ns}/deployments/${k}"
        name            = k
        type            = "Kubernetes/Deployment"
        service         = k
        architecture    = "aks"
        app_log_route   = module.env[k].log_route
        sidecar         = false
        url             = k == "hello-bff" ? local.bff_origin : (contains(keys(local.http), k) ? local.svc_url[k] : null)
        urls            = { public = k == "hello-bff" ? local.bff_origin : null, private = contains(keys(local.http), k) ? local.svc_url[k] : null }
        health_path     = "/healthz"
        readiness_path  = "/readyz"
        version_path    = contains(keys(local.http), k) ? "/version" : null
        scale_to_zero   = false
        min_replicas    = local.apps[k].min_replicas
        max_replicas    = min(local.apps[k].max_replicas, var.settings.replica_ceiling)
        version         = local.artifact_version[local.meta[k].artifact]
        image           = try(var.artifacts[local.meta[k].artifact].image, null)
        identity_name   = k
        service_account = local.wi[k].service_account
        otlp_target     = module.env[k].otlp_target
      }
    }
    # Smoke (tools/smoke/smoke.py): only the BFF is reachable from the deploy agents; in-cluster services
    # are probed by applications/deployments/scripts/smoke.sh through `az aks command invoke`.
    endpoints     = local.bff_origin == null ? {} : { "hello-bff" = local.bff_origin }
    public_api    = { origin = local.bff_origin, base_path = "/api", external = var.settings.exposure.mode == "app-routing" }
    idle_behavior = { for k in keys(local.apps) : k => { scale_to_zero = false } }
    secrets = {
      mechanism = local.csi ? "secrets-store-csi-driver (workload identity)" : "none (key_vault_secrets_provider disabled on platform-aks: FAULT_TOKEN not injected)"
    }
    exposure = var.settings.exposure.mode
    # Helm releases (one per workload) - for rollback tooling and drift checks. No values (they are in state only).
    helm = {
      chart         = "hello-service"
      chart_source  = var.settings.helm.chart_repository == null ? "repository:applications/charts/hello-service" : "${var.settings.helm.chart_repository}/hello-service:${var.settings.helm.chart_version}"
      releases      = { for k, r in helm_release.app : k => { name = r.name, namespace = r.namespace } }
      chart_version = var.settings.helm.chart_version
    }
    rollback = {
      method = "redeploy-previous-digest"
      how    = "re-run the deployment with the previous artifacts (image digest) -> helm upgrade (atomic, RollingUpdate maxUnavailable 0); break-glass: helm rollback <svc> [<revision>] -n ${local.ns} --wait (history: helm history <svc> -n ${local.ns}), then re-apply the previous digest so Terraform state matches"
    }
  }
}
