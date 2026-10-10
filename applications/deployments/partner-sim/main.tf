# hello-partner-sim (simulated payment API) on Azure Container Instances: private IP in the `aci` subnet,
# user-assigned identity (ACR pull + runtime), private DNS A record in the lab internal zone.
# Observability (observability 4.0.0, modules/instrumentation aci_sidecar): a Datadog Agent SIDECAR in the container
# group - traces on localhost:8126, DogStatsD on udp://localhost:8125, and the app's log file on the shared app-logs
# emptyDir, shipped to the Observability Pipelines Worker. With log_pipeline = fluent_bit_direct (fallback) a Fluent
# Bit sidecar + dsv-fetch refresher collect the logs instead.
# Secrets (ADR-0001 §14): nothing secret in this root or its state. The app resolves its dsv:// settings (FAULT_TOKEN)
# at start-up with its managed identity; the Agent resolves api_key ENC[dsv://...] itself through the dsv-fetch binary
# (secret_backend_command) with the group's identity. ACI init containers cannot use managed identities (Microsoft
# Learn), so the dsv-fetch-install init container only copies the binary into the dsv-bin emptyDir.
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
  # one Datadog host per container group (Agent hostname = the group name)
  agent_sidecar = merge(var.settings.agent_sidecar, { hostname = local.names.container_group })
  extra_env = {
    LATENCY_MS_MEAN      = tostring(var.settings.latency_ms_mean)
    PARTNER_FAILURE_RATE = tostring(var.settings.partner_failure_rate)
  }
}

resource "azurerm_container_group" "this" {
  #checkov:skip=CKV_AZURE_98:Private IP in the delegated aci subnet (ip_address_type = Private); no public exposure.
  #checkov:skip=CKV_AZURE_235:Secret settings are dsv:// references resolved by the app at start-up (ADR-0001 §14); no secret value is in environment_variables, and secure_environment_variables would only hide references.
  name                = local.names.container_group
  resource_group_name = azurerm_resource_group.this.name
  location            = local.location
  os_type             = "Linux"
  ip_address_type     = "Private"
  subnet_ids          = [var.foundation_network.subnets["aci"].id]
  restart_policy      = "Always"
  tags                = merge(local.tags, { service = local.svc, version = local.artifact_version[local.artifact] }, module.env.azure_tags)

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
      for_each = try(local.sidecar.app_volume_mounts, [])
      content {
        name       = volume.value.name
        mount_path = volume.value.mount_path
        empty_dir  = true
      }
    }
  }

  # dsv-fetch-install (observability instrumentation hook): copies the dsv-fetch binary into the dsv-bin emptyDir
  # before the containers start (no identity needed - ACI init containers have none).
  dynamic "init_container" {
    for_each = try(local.sidecar.init_containers, [])
    content {
      name                  = init_container.value.name
      image                 = init_container.value.image
      commands              = init_container.value.commands
      environment_variables = init_container.value.environment_variables

      dynamic "volume" {
        for_each = init_container.value.volumes
        content {
          name       = volume.value.name
          mount_path = volume.value.mount_path
          empty_dir  = true
        }
      }
    }
  }

  # Observability sidecars: datadog-agent (default); fluent-bit + dsv-fetch refresher with log_pipeline =
  # fluent_bit_direct. Values only - the Agent's DD_API_KEY is an ENC[dsv://...] reference.
  dynamic "container" {
    for_each = try(local.sidecar.containers, []) # tuple: Agent, Fluent Bit and refresher shapes differ
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
          read_only  = volume.value.read_only
        }
      }

      dynamic "liveness_probe" {
        for_each = container.value.liveness_exec == null ? [] : [container.value.liveness_exec]
        content {
          exec                  = liveness_probe.value
          initial_delay_seconds = 60
          period_seconds        = 30
          failure_threshold     = 5
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
