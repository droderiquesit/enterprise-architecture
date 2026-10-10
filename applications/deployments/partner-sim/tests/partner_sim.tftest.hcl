mock_provider "azurerm" {
  override_during = plan
  mock_resource "azurerm_container_group" {
    defaults = {
      id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-partner-dev-sec/providers/Microsoft.ContainerInstance/containerGroups/eh-ci-partner-dev-sec"
      ip_address = "10.41.1.4"
    }
  }
}

# BEGIN FIXTURE (generated): upstream contract shapes with valid Azure IDs.
variables {
  environment = {
    name            = "dev"
    location        = "swedencentral"
    subscription_id = "00000000-0000-0000-0000-000000000000"
    tenant_id       = "00000000-0000-0000-0000-000000000000"
    name_prefix     = "eh"
    owner           = "platform-team@example.com"
    team            = "platform-engineering"
    cost_center     = "lab-0001"
    expires_on      = "2026-12-31"
    tags            = {}
  }
  artifacts = {
    "img-dsv-fetch" = { image = "ehcrshareddevabcde.azurecr.io/dsv-fetch@sha256:5555555555555555555555555555555555555555555555555555555555555555" }
    "svc-frontend" = {
      tag            = "src-111111111111111111111111"
      commit         = "0123abc"
      package_url    = "https://ehstbootdevabcde.blob.core.windows.net/packages/hello-frontend/src-111111111111111111111111.zip"
      package_sha256 = "1111111111111111111111111111111111111111111111111111111111111111"
    }
    "svc-bff" = {
      image  = "ehcrshareddevabcde.azurecr.io/hello-bff@sha256:2222222222222222222222222222222222222222222222222222222222222222"
      tag    = "src-222222222222222222222222"
      commit = "0123abc"
    }
    "svc-orders-api" = {
      image   = "ehcrshareddevabcde.azurecr.io/hello-orders-api@sha256:3333333333333333333333333333333333333333333333333333333333333333"
      tag     = "src-333333333333333333333333"
      commit  = "0123abc"
      version = "1.4.2"
    }
    "svc-inventory-api" = {
      image          = "ehcrshareddevabcde.azurecr.io/hello-inventory-api@sha256:4444444444444444444444444444444444444444444444444444444444444444"
      tag            = "src-444444444444444444444444"
      commit         = "0123abc"
      package_url    = "https://ehstbootdevabcde.blob.core.windows.net/packages/hello-inventory-api/src-444444444444444444444444.zip"
      package_sha256 = "4444444444444444444444444444444444444444444444444444444444444444"
    }
    "svc-catalog-api" = {
      image          = "ehcrshareddevabcde.azurecr.io/hello-catalog-api@sha256:5555555555555555555555555555555555555555555555555555555555555555"
      tag            = "src-555555555555555555555555"
      commit         = "0123abc"
      package_url    = "https://ehstbootdevabcde.blob.core.windows.net/packages/hello-catalog-api/src-555555555555555555555555.zip"
      package_sha256 = "5555555555555555555555555555555555555555555555555555555555555555"
    }
    "svc-dbadapter" = {
      image          = "ehcrshareddevabcde.azurecr.io/hello-dbadapter@sha256:6666666666666666666666666666666666666666666666666666666666666666"
      tag            = "src-666666666666666666666666"
      commit         = "0123abc"
      package_url    = "https://ehstbootdevabcde.blob.core.windows.net/packages/hello-dbadapter/src-666666666666666666666666.zip"
      package_sha256 = "6666666666666666666666666666666666666666666666666666666666666666"
    }
    "svc-worker" = {
      image          = "ehcrshareddevabcde.azurecr.io/hello-worker@sha256:7777777777777777777777777777777777777777777777777777777777777777"
      tag            = "src-777777777777777777777777"
      commit         = "0123abc"
      package_url    = "https://ehstbootdevabcde.blob.core.windows.net/packages/hello-worker/src-777777777777777777777777.zip"
      package_sha256 = "7777777777777777777777777777777777777777777777777777777777777777"
    }
    "svc-partner-sim" = {
      image  = "ehcrshareddevabcde.azurecr.io/hello-partner-sim@sha256:8888888888888888888888888888888888888888888888888888888888888888"
      tag    = "src-888888888888888888888888"
      commit = "0123abc"
    }
    "svc-durable" = {
      image          = "ehcrshareddevabcde.azurecr.io/hello-durable@sha256:9999999999999999999999999999999999999999999999999999999999999999"
      tag            = "src-999999999999999999999999"
      commit         = "0123abc"
      package_url    = "https://ehstbootdevabcde.blob.core.windows.net/packages/hello-durable/src-999999999999999999999999.zip"
      package_sha256 = "9999999999999999999999999999999999999999999999999999999999999999"
    }
    "svc-functions" = {
      image          = "ehcrshareddevabcde.azurecr.io/hello-functions@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      tag            = "src-aaaaaaaaaaaaaaaaaaaaaaaa"
      commit         = "0123abc"
      package_url    = "https://ehstbootdevabcde.blob.core.windows.net/packages/hello-functions/src-aaaaaaaaaaaaaaaaaaaaaaaa.zip"
      package_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
    "svc-jobs" = {
      image          = "ehcrshareddevabcde.azurecr.io/hello-jobs@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      tag            = "src-bbbbbbbbbbbbbbbbbbbbbbbb"
      commit         = "0123abc"
      package_url    = "https://ehstbootdevabcde.blob.core.windows.net/packages/hello-jobs/src-bbbbbbbbbbbbbbbbbbbbbbbb.zip"
      package_sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
    "svc-traffic" = {
      image  = "ehcrshareddevabcde.azurecr.io/hello-traffic@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
      tag    = "src-cccccccccccccccccccccccc"
      commit = "0123abc"
    }
    "svc-logicapps" = {
      image          = "ehcrshareddevabcde.azurecr.io/hello-logicapps@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
      tag            = "src-dddddddddddddddddddddddd"
      commit         = "0123abc"
      package_url    = "https://ehstbootdevabcde.blob.core.windows.net/packages/hello-logicapps/src-dddddddddddddddddddddddd.zip"
      package_sha256 = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    }
  }
  foundation_network = {
    resource_group_name = "rg-net"
    location            = "swedencentral"
    internal_dns_zone   = "lab.internal"
    private_dns_zones = {
      webapps = {
        id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.azurewebsites.net"
        name = "privatelink.azurewebsites.net"
      }
    }
    internal_dns_zone_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/lab.internal"
    subnets = {
      compute = {
        id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-compute"
        name           = "snet-compute"
        address_prefix = "10.41.0.0/24"
      }
      aci = {
        id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aci"
        name           = "snet-aci"
        address_prefix = "10.41.1.0/24"
      }
      "private-endpoints" = {
        id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-private-endpoints"
        name           = "snet-private-endpoints"
        address_prefix = "10.41.2.0/24"
      }
      "aca-infra" = {
        id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-aca-infra"
        name           = "snet-aca-infra"
        address_prefix = "10.41.3.0/24"
      }
      "appsvc-integration" = {
        id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-appsvc-integration"
        name           = "snet-appsvc-integration"
        address_prefix = "10.41.4.0/24"
      }
      "flex-integration" = {
        id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-flex-integration"
        name           = "snet-flex-integration"
        address_prefix = "10.41.5.0/24"
      }
      observability = {
        id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-observability"
        name           = "snet-observability"
        address_prefix = "10.41.6.0/24"
      }
    }
  }
  platform_shared = {
    acr_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shared/providers/Microsoft.ContainerRegistry/registries/ehcrshareddevabcde"
    acr_login_server = "ehcrshareddevabcde.azurecr.io"
  }
  obs_telemetry_transport = {
    datadog_site = "datadoghq.com"
    api_key_ref  = "dsv://eh/dev/datadog-api-key#value"
    secrets = {
      provider    = "delinea-dsv"
      tenant      = "contoso"
      tld         = "com"
      base_url    = "https://contoso.secretsvaultcloud.com/v1"
      fetch_image = "ehacrdev.azurecr.io/dsv-fetch@sha256:2222222222222222222222222222222222222222222222222222222222222222"
    }
    otlp = {
      grpc_endpoint    = "http://eh-ca-otelgw.internal.kindstone-12345678.swedencentral.azurecontainerapps.io:4317"
      http_endpoint    = "https://eh-ca-otelgw.internal.kindstone-12345678.swedencentral.azurecontainerapps.io"
      headers_ref      = null
      default_protocol = "http/protobuf"
    }
    fluentbit = {
      forward_host           = "eh-ca-flbagg.internal.kindstone-12345678.swedencentral.azurecontainerapps.io"
      forward_port           = 24224
      sidecar_image          = "fluent/fluent-bit:5.1.3"
      sidecar_config         = <<-EOT
        service:
          flush: 1
        pipeline:
          inputs: []
      EOT
      sidecar_forward_config = <<-EOT
        service:
          flush: 1
      EOT
      sidecar_parsers        = <<-EOT
        parsers: []
      EOT
      sidecar_lua            = <<-EOT
        -- lua
      EOT
      sidecar_mode           = "datadog"
      logs_intake_host       = "http-intake.logs.datadoghq.com"
    }
    env = {
      common = {
        DD_SITE                    = "datadoghq.com"
        OTEL_EXPORTER_OTLP_TIMEOUT = "10000"
      }
      dotnet = {
        OTEL_DOTNET_AUTO_LOGS_ENABLED = "false"
      }
      python = {
        OTEL_PYTHON_LOG_CORRELATION = "true"
      }
    }
  }
  foundation_identity = {
    identities = {
      "hello-bff" = {
        id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ident/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-bff"
        principal_id = "11111111-1111-1111-1111-000000000000"
        client_id    = "22222222-2222-2222-2222-000000000000"
        name         = "id-hello-bff"
      }
      "hello-orders-api" = {
        id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ident/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-orders-api"
        principal_id = "11111111-1111-1111-1111-000000000001"
        client_id    = "22222222-2222-2222-2222-000000000001"
        name         = "id-hello-orders-api"
      }
      "hello-inventory-api" = {
        id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ident/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-inventory-api"
        principal_id = "11111111-1111-1111-1111-000000000002"
        client_id    = "22222222-2222-2222-2222-000000000002"
        name         = "id-hello-inventory-api"
      }
      "hello-catalog-api" = {
        id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ident/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-catalog-api"
        principal_id = "11111111-1111-1111-1111-000000000003"
        client_id    = "22222222-2222-2222-2222-000000000003"
        name         = "id-hello-catalog-api"
      }
      "hello-dbadapter" = {
        id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ident/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-dbadapter"
        principal_id = "11111111-1111-1111-1111-000000000004"
        client_id    = "22222222-2222-2222-2222-000000000004"
        name         = "id-hello-dbadapter"
      }
      "hello-worker" = {
        id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ident/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-worker"
        principal_id = "11111111-1111-1111-1111-000000000005"
        client_id    = "22222222-2222-2222-2222-000000000005"
        name         = "id-hello-worker"
      }
      "hello-durable" = {
        id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ident/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-durable"
        principal_id = "11111111-1111-1111-1111-000000000006"
        client_id    = "22222222-2222-2222-2222-000000000006"
        name         = "id-hello-durable"
      }
      "hello-functions" = {
        id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ident/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-functions"
        principal_id = "11111111-1111-1111-1111-000000000007"
        client_id    = "22222222-2222-2222-2222-000000000007"
        name         = "id-hello-functions"
      }
      "hello-jobs" = {
        id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ident/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-jobs"
        principal_id = "11111111-1111-1111-1111-000000000008"
        client_id    = "22222222-2222-2222-2222-000000000008"
        name         = "id-hello-jobs"
      }
      "hello-partner-sim" = {
        id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ident/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-partner-sim"
        principal_id = "11111111-1111-1111-1111-000000000009"
        client_id    = "22222222-2222-2222-2222-000000000009"
        name         = "id-hello-partner-sim"
      }
      "hello-traffic" = {
        id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ident/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-traffic"
        principal_id = "11111111-1111-1111-1111-000000000010"
        client_id    = "22222222-2222-2222-2222-000000000010"
        name         = "id-hello-traffic"
      }
      "hello-frontend" = {
        id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ident/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-frontend"
        principal_id = "11111111-1111-1111-1111-000000000011"
        client_id    = "22222222-2222-2222-2222-000000000011"
        name         = "id-hello-frontend"
      }
      "hello-logicapps" = {
        id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ident/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-logicapps"
        principal_id = "11111111-1111-1111-1111-000000000012"
        client_id    = "22222222-2222-2222-2222-000000000012"
        name         = "id-hello-logicapps"
      }
      "obs-collector" = {
        id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ident/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-obs-collector"
        principal_id = "11111111-1111-1111-1111-000000000013"
        client_id    = "22222222-2222-2222-2222-000000000013"
        name         = "id-obs-collector"
      }
      "obs-dbm" = {
        id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ident/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-obs-dbm"
        principal_id = "11111111-1111-1111-1111-000000000014"
        client_id    = "22222222-2222-2222-2222-000000000014"
        name         = "id-obs-dbm"
      }
      "aks-control-plane" = {
        id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ident/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-aks-control-plane"
        principal_id = "11111111-1111-1111-1111-000000000015"
        client_id    = "22222222-2222-2222-2222-000000000015"
        name         = "id-aks-control-plane"
      }
      "aks-kubelet" = {
        id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ident/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-aks-kubelet"
        principal_id = "11111111-1111-1111-1111-000000000016"
        client_id    = "22222222-2222-2222-2222-000000000016"
        name         = "id-aks-kubelet"
      }
      "deploy-agent" = {
        id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ident/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-deploy-agent"
        principal_id = "11111111-1111-1111-1111-000000000017"
        client_id    = "22222222-2222-2222-2222-000000000017"
        name         = "id-deploy-agent"
      }
    }
    secrets = {
      provider      = "delinea-dsv"
      tenant        = "contoso"
      tld           = "com"
      base_url      = "https://contoso.secretsvaultcloud.com/v1"
      base_path     = "eh/dev"
      auth_provider = "azure-eh"
      refs = {
        "datadog-api-key"      = "dsv://eh/dev/datadog-api-key#value"
        "datadog-app-key"      = "dsv://eh/dev/datadog-app-key#value"
        "fault-token"          = "dsv://eh/dev/fault-token#value"
        "datadog-client-token" = "dsv://eh/dev/datadog-client-token#value"
      }
    }
  }
}
# END FIXTURE

run "defaults" {
  command = plan

  assert {
    condition     = azurerm_container_group.this.ip_address_type == "Private" && one(azurerm_container_group.this.subnet_ids) == var.foundation_network.subnets["aci"].id
    error_message = "Partner-sim runs on a private IP in the aci subnet."
  }
  assert {
    condition     = jsonencode([for c in azurerm_container_group.this.container : c.name]) == jsonencode(["hello-partner-sim", "fluent-bit", "dsv-fetch"]) && length(azurerm_container_group.this.init_container) == 0
    error_message = "fluent_bit_direct fallback (mock contract without fleet switches): app, Fluent Bit sidecar and the dsv-fetch refresher (no init container: ACI init containers have no managed identity)."
  }
  assert {
    condition     = azurerm_container_group.this.image_registry_credential[0].user_assigned_identity_id == var.foundation_identity.identities["hello-partner-sim"].id
    error_message = "ACR pull with the user-assigned identity (no registry password)."
  }
  assert {
    condition     = azurerm_container_group.this.container[0].environment_variables["FAULTS_ENABLED"] == "false" && azurerm_container_group.this.container[0].environment_variables["FAULT_TOKEN"] == "dsv://eh/dev/fault-token#value" && azurerm_container_group.this.container[0].environment_variables["DSV_AUTH"] == "azure"
    error_message = "FAULTS_ENABLED false by default; FAULT_TOKEN is a dsv:// reference resolved by the app."
  }
  assert {
    condition     = alltrue([for c in azurerm_container_group.this.container : try(length(c.secure_environment_variables), 0) == 0]) && !strcontains(jsonencode(azurerm_container_group.this.container), "vault.azure.net")
    error_message = "No secret values in the container group (nothing secret in state)."
  }
  assert {
    condition     = contains(azurerm_container_group.this.container[2].commands, "DD_API_KEY=dsv://eh/dev/datadog-api-key#value") && azurerm_container_group.this.container[2].image == "ehcrshareddevabcde.azurecr.io/dsv-fetch@sha256:5555555555555555555555555555555555555555555555555555555555555555" && azurerm_container_group.this.container[2].environment_variables["AZURE_CLIENT_ID"] == var.foundation_identity.identities["hello-partner-sim"].client_id
    error_message = "dsv-fetch refresher (artifacts img-dsv-fetch) writes the sidecar's key with the group identity."
  }
  assert {
    condition     = anytrue([for v in azurerm_container_group.this.container[1].volume : v.name == "dsv-secrets" && v.mount_path == "/dsv-secrets"]) && anytrue([for v in azurerm_container_group.this.container[2].volume : v.name == "dsv-secrets"])
    error_message = "Fluent Bit and dsv-fetch share the dsv-secrets emptyDir."
  }
  assert {
    condition     = azurerm_container_group.this.container[0].environment_variables["LOG_FILE_PATH"] == "/var/log/app/app.log" && azurerm_container_group.this.container[0].volume[0].mount_path == "/var/log/app"
    error_message = "App writes the shared log file on the emptyDir tailed by the sidecar."
  }
  assert {
    condition     = length(azurerm_private_dns_a_record.this) == 1 && output.contract.url == "http://partner-sim.lab.internal:8080"
    error_message = "Private DNS A record in the lab internal zone and contract URL."
  }
  assert {
    condition     = output.contract.container_group.id != null && output.contract.apps["hello-partner-sim"].app_log_route == "sidecar"
    error_message = "Contract exposes container_group.id and log route."
  }
}

run "datadog_agent_sidecar_observability_pipelines" {
  # observability 4.0.0 default (lab contract switches datadog + observability_pipelines): Datadog Agent sidecar,
  # no Fluent Bit; the Agent resolves its key with the dsv-fetch binary the init container installs.
  command = plan
  variables {
    obs_telemetry_transport = {
      datadog_site = "datadoghq.com"
      api_key_ref  = "dsv://eh/dev/datadog-api-key#value"
      secrets = {
        tenant      = "contoso"
        base_url    = "https://contoso.secretsvaultcloud.com/v1"
        fetch_image = "ehacrdev.azurecr.io/dsv-fetch@sha256:2222222222222222222222222222222222222222222222222222222222222222"
      }
      otlp       = { grpc_endpoint = "http://gw:4317", http_endpoint = "https://gw" }
      fluentbit  = { forward_host = "opw", forward_port = 24224, sidecar_mode = "forward" }
      aggregator = { kind = "observability_pipelines", agent_logs_url = "http://eh-ca-opw.internal.example:8282" }
      env        = { fleet = { EH_APM_MODE = "datadog", EH_LOG_PIPELINE = "observability_pipelines" } }
    }
    settings = { agent_sidecar = { cpu = 0.5 } }
  }
  assert {
    condition     = jsonencode([for c in azurerm_container_group.this.container : c.name]) == jsonencode(["hello-partner-sim", "datadog-agent"]) && jsonencode([for c in azurerm_container_group.this.init_container : c.name]) == jsonencode(["dsv-fetch-install"])
    error_message = "ACI group: app + Datadog Agent sidecar; one init container installs the dsv-fetch binary."
  }
  assert {
    condition     = azurerm_container_group.this.init_container[0].image == "ehcrshareddevabcde.azurecr.io/dsv-fetch@sha256:5555555555555555555555555555555555555555555555555555555555555555" && jsonencode(azurerm_container_group.this.init_container[0].commands) == jsonencode(["/opt/dsv-fetch/dsv-fetch", "install", "--dest", "/eh/dsv-bin/dsv-fetch"])
    error_message = "dsv-fetch-install uses this root's img-dsv-fetch artifact (static binary)."
  }
  assert {
    condition = alltrue([
      azurerm_container_group.this.container[1].image == "gcr.io/datadoghq/agent:7.84.2",
      azurerm_container_group.this.container[1].cpu == 0.5,
      azurerm_container_group.this.container[1].memory == 0.5,
      azurerm_container_group.this.container[1].environment_variables["DD_API_KEY"] == "ENC[dsv://eh/dev/datadog-api-key#value]",
      azurerm_container_group.this.container[1].environment_variables["DD_HOSTNAME"] == azurerm_container_group.this.name,
      azurerm_container_group.this.container[1].environment_variables["DD_OBSERVABILITY_PIPELINES_WORKER_LOGS_URL"] == "http://eh-ca-opw.internal.example:8282",
      jsonencode(azurerm_container_group.this.container[1].liveness_probe[0].exec) == jsonencode(["agent", "health"]),
    ])
    error_message = "Pinned Agent image, sizing override, ENC[] reference only, hostname = group name, logs -> OP Worker, health probe."
  }
  assert {
    condition     = azurerm_container_group.this.container[0].environment_variables["DD_DOGSTATSD_URL"] == "udp://localhost:8125" && azurerm_container_group.this.container[0].environment_variables["TELEMETRY_SDK"] == "datadog" && azurerm_container_group.this.container[0].environment_variables["LOG_FILE_PATH"] == "/var/log/app/app.log"
    error_message = "App: Datadog tracer -> localhost, DogStatsD to the sidecar, JSON log file on the shared emptyDir."
  }
  assert {
    condition     = anytrue([for v in azurerm_container_group.this.container[1].volume : v.name == "app-logs" && v.mount_path == "/var/log/app"]) && anytrue([for v in azurerm_container_group.this.container[1].volume : v.name == "agent-config" && v.read_only])
    error_message = "Agent tails the app-logs emptyDir; config from a read-only secret volume (non-secret files)."
  }
  assert {
    condition     = alltrue([for c in azurerm_container_group.this.container : try(length(c.secure_environment_variables), 0) == 0]) && output.contract.apps["hello-partner-sim"].sidecar
    error_message = "No secret values in the container group."
  }
}

run "rejects_mutable_tags" {
  command = plan
  variables {
    artifacts = { "svc-partner-sim" = { image = "docker.io/library/partner:latest" } }
  }
  expect_failures = [var.artifacts]
}
