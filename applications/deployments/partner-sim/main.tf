# hello-partner-sim (simulated payment API) on Azure Container Instances: private IP in the `aci` subnet,
# user-assigned identity (ACR pull + runtime), Fluent Bit sidecar tailing a shared emptyDir volume
# (ADR-0001 §10), private DNS A record in the lab internal zone.
# Secrets (ADR-0001 §14): nothing secret in this root or its state. The app resolves its dsv:// settings (FAULT_TOKEN)
# at start-up with its managed identity; the Fluent Bit sidecar's Datadog key is written into the shared emptyDir by a
# dsv-fetch REFRESHER container (ACI init containers cannot use managed identities - Microsoft Learn).
module "meta" {
  source = "../modules/service-meta"
}

resource "azurerm_resource_group" "this" {
  name     = local.names.resource_group
  location = local.location
  tags     = local.tags
}

locals {
  svc      = "hello-partner-sim"
  meta     = module.meta.services[local.svc]
  identity = var.foundation_identity.identities[local.svc]
  artifact = local.meta.artifact
  sidecar  = module.env.aci_sidecar
  fetcher  = local.sidecar == null ? null : local.sidecar.fetcher

  dns_zone = var.foundation_network.internal_dns_zone_id == null ? null : var.foundation_network.internal_dns_zone
  fqdn     = local.dns_zone == null ? null : "${var.settings.dns_record_name}.${local.dns_zone}"
}

module "env" {
  source = "../modules/app-env"
  service = {
    name    = local.svc
    version = local.artifact_version[local.artifact]
    commit  = local.artifact_commit[local.artifact]
    env     = local.env_name
    team    = local.meta.team
    owner   = local.meta.owner
    domain  = local.meta.domain
    tier    = local.meta.tier
    region  = local.location
  }
  runtime            = "python"
  architecture       = "aci"
  telemetry          = local.telemetry
  identity_client_id = local.identity.client_id
  faults = {
    enabled   = var.settings.faults_enabled
    token_ref = lookup(var.foundation_identity.secrets.refs, "fault-token", null)
  }
  log_level          = var.settings.log_level
  trace_sample_ratio = var.settings.trace_sample_ratio
  extra_env = {
    LATENCY_MS_MEAN      = tostring(var.settings.latency_ms_mean)
    PARTNER_FAILURE_RATE = tostring(var.settings.partner_failure_rate)
  }
}

resource "azurerm_container_group" "this" {
  #checkov:skip=CKV_AZURE_98:Private IP in the delegated aci subnet (ip_address_type = Private); no public exposure.
  name                = local.names.container_group
  resource_group_name = azurerm_resource_group.this.name
  location            = local.location
  os_type             = "Linux"
  ip_address_type     = "Private"
  subnet_ids          = [var.foundation_network.subnets["aci"].id]
  restart_policy      = "Always"
  tags                = merge(local.tags, { service = local.svc, version = local.artifact_version[local.artifact] })

  identity {
    type         = "UserAssigned"
    identity_ids = [local.identity.id]
  }

  image_registry_credential {
    server                    = var.platform_shared.acr_login_server
    user_assigned_identity_id = local.identity.id
  }

  container {
    name   = local.svc
    image  = try(var.artifacts[local.artifact].image, null)
    cpu    = var.settings.cpu
    memory = var.settings.memory_gb

    ports {
      port     = 8080
      protocol = "TCP"
    }

    # plain values + dsv:// references (resolved by the app); no secure_environment_variables
    environment_variables = module.env.env

    liveness_probe {
      http_get {
        path   = "/healthz"
        port   = 8080
        scheme = "http"
      }
      initial_delay_seconds = 10
      period_seconds        = 15
      failure_threshold     = 3
    }
    readiness_probe {
      http_get {
        path   = "/readyz"
        port   = 8080
        scheme = "http"
      }
      period_seconds    = 10
      failure_threshold = 3
    }

    dynamic "volume" {
      for_each = local.sidecar == null ? [] : local.sidecar.app_volume_mounts
      content {
        name       = volume.value.name
        mount_path = volume.value.mount_path
        empty_dir  = true
      }
    }
  }

  # Fluent Bit sidecar (observability instrumentation hook): tails LOG_FILE_PATH on the shared emptyDir.
  dynamic "container" {
    for_each = local.sidecar == null ? [] : [local.sidecar.container]
    content {
      name                  = container.value.name
      image                 = container.value.image
      cpu                   = container.value.cpu
      memory                = container.value.memory
      commands              = container.value.commands
      environment_variables = container.value.environment_variables

      dynamic "volume" {
        for_each = container.value.volumes
        content {
          name       = volume.value.name
          mount_path = volume.value.mount_path
          empty_dir  = volume.value.empty_dir ? true : null
          secret     = volume.value.secret
          read_only  = volume.value.empty_dir ? false : true
        }
      }
    }
  }

  # dsv-fetch refresher (ACI init containers have no managed identity): writes /dsv-secrets/fluentbit-env.yaml from
  # DSV with the group's identity (IMDS), re-fetches hourly; Fluent Bit restarts until the file exists.
  dynamic "container" {
    for_each = local.fetcher == null ? [] : [local.fetcher]
    content {
      name                  = container.value.name
      image                 = container.value.image
      cpu                   = container.value.cpu
      memory                = container.value.memory
      commands              = container.value.commands
      environment_variables = container.value.environment_variables

      dynamic "volume" {
        for_each = container.value.volumes
        content {
          name       = volume.value.name
          mount_path = volume.value.mount_path
          empty_dir  = true
        }
      }
    }
  }
}

resource "azurerm_private_dns_a_record" "this" {
  count               = local.dns_zone == null ? 0 : 1
  name                = var.settings.dns_record_name
  private_dns_zone_id = var.foundation_network.internal_dns_zone_id
  ttl                 = 60
  records             = [azurerm_container_group.this.ip_address]
  tags                = local.tags
}

# dsv-fetch (sidecar key init/refresher container): this root's registry artifact img-dsv-fetch (digest-pinned) wins
# over the image published in the transport contract (ADR-0001 section 14).
locals {
  telemetry = merge(var.obs_telemetry_transport, {
    secrets = merge(var.obs_telemetry_transport.secrets, {
      fetch_image = try(coalesce(try(var.artifacts["img-dsv-fetch"].image, null), var.obs_telemetry_transport.secrets.fetch_image), null)
    })
  })
}
