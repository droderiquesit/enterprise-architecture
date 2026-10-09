# One Container App with: user-assigned identity (ACR pull + Key Vault references), digest-pinned image,
# env + Key Vault secret references, /healthz + /readyz probes, HTTP scale rule, optional Fluent Bit sidecar
# tailing a shared EmptyDir (ADR-0001 §10), multiple-revision traffic weights for rollback.
locals {
  patch       = var.sidecar_patch
  has_sidecar = local.patch != null && try(length(local.patch.sidecars), 0) > 0

  app_secrets = {
    for k, id in var.secret_env : var.secret_names[k] => { key_vault_secret_id = id, value = null }
  }
  patch_secrets = local.has_sidecar ? {
    for s in local.patch.secrets : s.name => { key_vault_secret_id = s.key_vault_secret_id, value = s.value }
  } : {}
  secrets = merge(local.patch_secrets, local.app_secrets)

  volumes       = local.has_sidecar ? local.patch.volumes : []
  app_mounts    = local.has_sidecar ? local.patch.app_container.volume_mounts : []
  sidecars      = local.has_sidecar ? local.patch.sidecars : []
  sorted_env    = sort(keys(var.env))
  sorted_secret = sort(keys(var.secret_env))

  # Deterministic revision suffix: changes whenever the template changes, so every template change
  # creates a new, addressable revision (rollback target). Lowercase alphanumerics, starts with a letter.
  revision_suffix = "r${substr(sha1(jsonencode({
    image   = var.container.image
    env     = var.env
    secrets = var.secret_env
    cpu     = var.container.cpu
    memory  = var.container.memory
    scale   = var.scale
    sidecar = local.sidecars
  })), 0, 9)}"

  traffic = concat(
    [{ latest = true, suffix = null, weight = var.revisions.latest_weight }],
    var.revisions.latest_weight < 100 ? [{ latest = false, suffix = var.revisions.previous_revision_suffix, weight = 100 - var.revisions.latest_weight }] : [],
  )
}

resource "azurerm_container_app" "this" {
  name                         = var.name
  resource_group_name          = var.resource_group_name
  container_app_environment_id = var.environment_id
  revision_mode                = var.revisions.mode
  max_inactive_revisions       = var.revisions.max_inactive
  workload_profile_name        = var.workload_profile_name
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [var.identity.id]
  }

  registry {
    server   = var.registry_server
    identity = var.identity.id
  }

  dynamic "secret" {
    for_each = local.secrets
    content {
      name                = secret.key
      key_vault_secret_id = secret.value.key_vault_secret_id
      identity            = secret.value.key_vault_secret_id == null ? null : var.identity.id
      value               = secret.value.value
    }
  }

  dynamic "ingress" {
    for_each = var.ingress == null ? [] : [var.ingress]
    content {
      external_enabled           = ingress.value.external
      target_port                = ingress.value.target_port
      transport                  = ingress.value.transport
      allow_insecure_connections = false

      dynamic "cors" {
        for_each = length(ingress.value.cors_origins) > 0 ? [1] : []
        content {
          allowed_origins = ingress.value.cors_origins
          allowed_methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]
          # Browser RUM (allowedTracingUrls) adds W3C + Datadog headers to first-party API calls.
          allowed_headers           = ["content-type", "idempotency-key", "traceparent", "tracestate", "x-datadog-origin", "x-datadog-parent-id", "x-datadog-sampling-priority", "x-datadog-trace-id"]
          exposed_headers           = ["traceparent"]
          max_age_in_seconds        = 600
          allow_credentials_enabled = false
        }
      }

      dynamic "traffic_weight" {
        for_each = local.traffic
        content {
          latest_revision = traffic_weight.value.latest ? true : null
          revision_suffix = traffic_weight.value.suffix
          percentage      = traffic_weight.value.weight
        }
      }
    }
  }

  template {
    min_replicas                     = var.scale.min_replicas
    max_replicas                     = var.scale.max_replicas
    revision_suffix                  = var.revisions.mode == "Multiple" ? local.revision_suffix : null
    termination_grace_period_seconds = 30

    dynamic "http_scale_rule" {
      for_each = var.ingress == null ? [] : [1]
      content {
        name                = "http-concurrency"
        concurrent_requests = tostring(var.scale.http_concurrency)
      }
    }

    container {
      name    = var.container.name
      image   = var.container.image
      cpu     = var.container.cpu
      memory  = var.container.memory
      command = var.container.command
      args    = var.container.args

      dynamic "env" {
        for_each = local.sorted_env
        content {
          name  = env.value
          value = var.env[env.value]
        }
      }
      dynamic "env" {
        for_each = local.sorted_secret
        content {
          name        = env.value
          secret_name = var.secret_names[env.value]
        }
      }

      startup_probe {
        transport               = "HTTP"
        port                    = var.probes.port
        path                    = var.probes.health_path
        interval_seconds        = 5
        failure_count_threshold = 24
      }
      liveness_probe {
        transport               = "HTTP"
        port                    = var.probes.port
        path                    = var.probes.health_path
        initial_delay           = var.probes.initial_wait
        interval_seconds        = 15
        failure_count_threshold = 3
      }
      readiness_probe {
        transport               = "HTTP"
        port                    = var.probes.port
        path                    = var.probes.ready_path
        interval_seconds        = 10
        failure_count_threshold = 3
        success_count_threshold = 1
      }

      dynamic "volume_mounts" {
        for_each = local.app_mounts
        content {
          name     = volume_mounts.value.name
          path     = volume_mounts.value.path
          sub_path = volume_mounts.value.sub_path
        }
      }
    }

    # Fluent Bit sidecar (ADR-0001 §10): tails LOG_FILE_PATH on the shared EmptyDir volume.
    dynamic "container" {
      for_each = local.sidecars
      content {
        name   = container.value.name
        image  = container.value.image
        cpu    = container.value.cpu
        memory = container.value.memory
        args   = container.value.args

        dynamic "env" {
          for_each = container.value.env
          content {
            name        = env.value.name
            value       = env.value.value
            secret_name = env.value.secret_name
          }
        }
        dynamic "volume_mounts" {
          for_each = container.value.volume_mounts
          content {
            name     = volume_mounts.value.name
            path     = volume_mounts.value.path
            sub_path = volume_mounts.value.sub_path
          }
        }
        liveness_probe {
          transport = container.value.liveness_probe.transport
          port      = container.value.liveness_probe.port
          path      = container.value.liveness_probe.path
        }
      }
    }

    dynamic "volume" {
      for_each = local.volumes
      content {
        name         = volume.value.name
        storage_type = volume.value.storage_type
      }
    }
  }
}
