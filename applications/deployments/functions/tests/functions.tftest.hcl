mock_provider "azurerm" {
  override_during = plan
  mock_resource "azurerm_linux_function_app" {
    defaults = {
      id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-func/providers/Microsoft.Web/sites/eh-func-hello-dev-abcde"
      default_hostname = "eh-func-hello-dev-abcde.azurewebsites.net"
    }
  }
  mock_resource "azurerm_resource_group" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-functions-dev-sec"
    }
  }
}

mock_provider "azapi" {
  override_during = plan
  mock_resource "azapi_resource" {
    defaults = {
      id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-functions-dev-sec/providers/Microsoft.App/containerApps/eh-ca-func-quote-dev"
      output = { properties = { configuration = { ingress = { fqdn = "eh-ca-func-quote-dev.internal.kindstone-12345678.swedencentral.azurecontainerapps.io" } } } }
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
  platform_functions = {
    resource_group_name        = "rg-func"
    location                   = "swedencentral"
    flex_integration_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-flex-integration"
    integration_subnet_id      = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-appsvc-integration"
    flex = {
      durable = {
        plan_id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-func/providers/Microsoft.Web/serverFarms/eh-asp-func-dev-sec-flex-durable"
        identity                 = "hello-durable"
        storage_account_name     = "ehstfuncdevabcdedur"
        blob_endpoint            = "https://ehstfuncdevabcdedur.blob.core.windows.net/"
        queue_endpoint           = "https://ehstfuncdevabcdedur.queue.core.windows.net/"
        table_endpoint           = "https://ehstfuncdevabcdedur.table.core.windows.net/"
        deployment_container_url = "https://ehstfuncdevabcdedur.blob.core.windows.net/deploy-durable"
      }
    }
    durable_storage = {
      storage_account_name = "ehstfuncdevabcdedts"
      blob_endpoint        = "https://ehstfuncdevabcdedts.blob.core.windows.net/"
      queue_endpoint       = "https://ehstfuncdevabcdedts.queue.core.windows.net/"
      table_endpoint       = "https://ehstfuncdevabcdedts.table.core.windows.net/"
    }
    premium = {
      plan_id              = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-func/providers/Microsoft.Web/serverFarms/eh-asp-func-dev-sec-premium"
      storage_account_name = "ehstfuncdevabcdeprm"
      identity             = "hello-functions"
    }
    consumption_windows = null
  }
  platform_messaging = {
    namespace_id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-msg/providers/Microsoft.ServiceBus/namespaces/eh-sbns-msg-dev-sec"
    namespace_name = "eh-sbns-msg-dev-sec"
    fqdn           = "eh-sbns-msg-dev-sec.servicebus.windows.net"
    topic = {
      name = "order-events"
      id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-msg/providers/Microsoft.ServiceBus/namespaces/eh-sbns-msg-dev-sec/topics/order-events"
    }
    subscriptions = {
      fulfillment = {
        name = "fulfillment"
        id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-msg/providers/Microsoft.ServiceBus/namespaces/eh-sbns-msg-dev-sec/topics/order-events/subscriptions/fulfillment"
      }
      notifications = {
        name = "notifications"
        id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-msg/providers/Microsoft.ServiceBus/namespaces/eh-sbns-msg-dev-sec/topics/order-events/subscriptions/notifications"
      }
      audit = {
        name = "audit"
        id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-msg/providers/Microsoft.ServiceBus/namespaces/eh-sbns-msg-dev-sec/topics/order-events/subscriptions/audit"
      }
    }
    queues = {
      "batch-items" = {
        name = "batch-items"
        id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-msg/providers/Microsoft.ServiceBus/namespaces/eh-sbns-msg-dev-sec/queues/batch-items"
      }
    }
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
  platform_appservice = {
    resource_group_name   = "rg-appsvc"
    location              = "swedencentral"
    integration_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-spoke/subnets/snet-appsvc-integration"
    plans = {
      linux = {
        id      = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-appsvc/providers/Microsoft.Web/serverFarms/eh-asp-appsvc-dev-sec-lin"
        name    = "eh-asp-appsvc-dev-sec-lin"
        os_type = "Linux"
        sku     = "P0v3"
      }
      windows = {
        id      = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-appsvc/providers/Microsoft.Web/serverFarms/eh-asp-appsvc-dev-sec-win"
        name    = "eh-asp-appsvc-dev-sec-win"
        os_type = "Windows"
        sku     = "P0v3"
      }
      logicapps = {
        id      = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-appsvc/providers/Microsoft.Web/serverFarms/eh-asp-appsvc-dev-sec-logic"
        name    = "eh-asp-appsvc-dev-sec-logic"
        os_type = "Windows"
        sku     = "WS1"
      }
    }
    functions_dedicated_plan = "linux"
    logicapps_storage = {
      id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-appsvc/providers/Microsoft.Storage/storageAccounts/ehstappsvcdevabcdelogic"
      name          = "ehstappsvcdevabcdelogic"
      blob_endpoint = "https://ehstappsvcdevabcdelogic.blob.core.windows.net/"
    }
  }
  platform_containerapps = {
    resource_group_name    = "rg-aca"
    location               = "swedencentral"
    environment_id         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aca/providers/Microsoft.App/managedEnvironments/eh-cae-aca-dev-sec"
    default_domain         = "kindstone-12345678.swedencentral.azurecontainerapps.io"
    ingress_mode           = "external"
    workload_profiles      = ["Consumption", "dedicated-d4"]
    dedicated_profile_name = "dedicated-d4"
  }
  platform_shared = {
    acr_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shared/providers/Microsoft.ContainerRegistry/registries/ehcrshareddevabcde"
    acr_login_server = "ehcrshareddevabcde.azurecr.io"
  }
}
# END FIXTURE

run "three_hosts" {
  command = plan

  assert {
    condition     = length(azurerm_linux_function_app.this) == 2 && length(azapi_resource.quote) == 1
    error_message = "premium + dedicated function apps and the ACA (kind=functionapp) quote app."
  }
  assert {
    condition     = azurerm_linux_function_app.this["premium"].app_settings["AzureWebJobs.cache_warmer.Disabled"] == "true" && azurerm_linux_function_app.this["premium"].app_settings["AzureWebJobs.quote.Disabled"] == "true" && !contains(keys(azurerm_linux_function_app.this["premium"].app_settings), "AzureWebJobs.audit.Disabled")
    error_message = "Premium hosts only audit."
  }
  assert {
    condition     = azurerm_linux_function_app.this["dedicated"].app_settings["AzureWebJobs.audit.Disabled"] == "true" && azurerm_linux_function_app.this["dedicated"].site_config[0].always_on
    error_message = "Dedicated hosts only cache-warmer with always_on."
  }
  assert {
    condition     = azurerm_linux_function_app.this["premium"].site_config[0].application_stack[0].python_version == "3.13"
    error_message = "Python 3.13."
  }
  assert {
    condition     = azurerm_linux_function_app.this["premium"].app_settings["AUDIT_SINK"] == "log" && !contains(keys(azurerm_linux_function_app.this["premium"].app_settings), "AUDIT_STORE")
    error_message = "AUDIT_SINK (the variable hello_functions reads) is set; without ledger/table contracts it is log."
  }
  assert {
    condition     = alltrue([for h, a in azurerm_linux_function_app.this : a.app_settings["FAULTS_ENABLED"] == "false" && startswith(a.app_settings["FAULT_TOKEN"], "@Microsoft.KeyVault(SecretUri=") && !contains(keys(a.app_settings), "LOG_FILE_PATH")])
    error_message = "Faults off, Key Vault reference for FAULT_TOKEN, no sidecar/log file on Functions."
  }
  assert {
    condition     = azapi_resource.quote[0].body.kind == "functionapp" && length(azapi_resource.quote[0].body.properties.template.containers) == 2 && azapi_resource.quote[0].body.properties.template.containers[1].name == "fluent-bit"
    error_message = "Functions on Container Apps V2 (kind=functionapp) with the Fluent Bit sidecar (ACA log route)."
  }
  assert {
    condition     = alltrue([for s in azapi_resource.quote[0].body.properties.configuration.secrets : !can(s.value) || startswith(s.name, "flb-")])
    error_message = "Only non-secret Fluent Bit config is stored as plain ACA secret values; real secrets are Key Vault references."
  }
  assert {
    condition     = output.contract.function_apps["premium"].id != null && output.contract.apps["hello-functions-premium"].app_log_route == "eventhub" && output.contract.apps["hello-functions-aca"].app_log_route == "sidecar"
    error_message = "Contract exposes function_apps.premium.id and log routes."
  }
}

run "premium_only" {
  command = plan
  variables {
    platform_appservice    = null
    platform_containerapps = null
  }
  assert {
    condition     = keys(azurerm_linux_function_app.this) == ["premium"] && length(azapi_resource.quote) == 0 && length(azurerm_resource_group.aca) == 0
    error_message = "Optional producers absent => no dedicated / ACA resources."
  }
}

run "rejects_mutable_tags" {
  command = plan
  variables {
    artifacts = { "svc-functions" = { image = "ehcrshareddevabcde.azurecr.io/hello-functions:dev" } }
  }
  expect_failures = [var.artifacts]
}
