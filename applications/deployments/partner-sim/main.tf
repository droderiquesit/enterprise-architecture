# hello-partner-sim (simulated payment API) on Azure Container Instances: private IP in the `aci` subnet,
# user-assigned identity (ACR pull + runtime), Fluent Bit sidecar tailing a shared emptyDir volume
# (ADR-0001 §10), private DNS A record in the lab internal zone.
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
  kv_host  = regex("^https://([^/]+)/", var.foundation_identity.key_vault_uri)[0]

  # Secret env (name -> versionless id) for the app and the sidecar; values resolved below.
  app_secret_ids     = module.env.secret_env
  sidecar            = module.env.aci_sidecar
  sidecar_secret_ids = local.sidecar == null ? {} : local.sidecar.container.secure_environment_variables
  all_secret_ids     = var.settings.resolve_secrets ? merge(local.app_secret_ids, local.sidecar_secret_ids) : {}
  secret_names       = { for k, id in local.all_secret_ids : k => regex("/secrets/([A-Za-z0-9-]+)$", id)[0] }

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

data "azurerm_key_vault_secret" "env" {
  for_each     = local.secret_names
  name         = each.value
  key_vault_id = var.foundation_identity.key_vault_id

  lifecycle {
    precondition {
      condition     = startswith(local.all_secret_ids[each.key], "https://${local.kv_host}/")
      error_message = "ACI secret ${each.key} must live in the foundation Key Vault (${local.kv_host})."
    }
  }
}

resource "azurerm_container_group" "this" {
  #checkov:skip=CKV_AZURE_98:Private IP in the delegated aci subnet (ip_address_type = Private); no public exposure.
  #checkov:skip=CKV_AZURE_235:Secure environment variables come from Key Vault data sources; ACI has no native Key Vault references.
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

    environment_variables        = module.env.env
    secure_environment_variables = { for k in keys(local.app_secret_ids) : k => data.azurerm_key_vault_secret.env[k].value if contains(keys(local.secret_names), k) }

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
      name                         = container.value.name
      image                        = container.value.image
      cpu                          = container.value.cpu
      memory                       = container.value.memory
      commands                     = container.value.commands
      environment_variables        = container.value.environment_variables
      secure_environment_variables = { for k in keys(container.value.secure_environment_variables) : k => data.azurerm_key_vault_secret.env[k].value if contains(keys(local.secret_names), k) }

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
