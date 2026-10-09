mock_provider "azurerm" {
  override_during = plan
  mock_resource "azurerm_function_app_flex_consumption" {
    defaults = {
      id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-func/providers/Microsoft.Web/sites/eh-func-durable-dev-abcde"
      default_hostname = "eh-func-durable-dev-abcde.azurewebsites.net"
    }
  }
  mock_resource "azurerm_windows_function_app" {
    defaults = {
      id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-func/providers/Microsoft.Web/sites/eh-func-durrec-dev-abcde"
      default_hostname = "eh-func-durrec-dev-abcde.azurewebsites.net"
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
  platform_db_sql = {
    server = {
      fqdn = "eh-sql-data-dev-sec.database.windows.net"
      port = 1433
    }
    databases = {
      orders = {
        name = "orders"
        id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-sql/providers/Microsoft.Sql/servers/eh-sql-data-dev-sec/databases/orders"
      }
      fulfillment = {
        name = "fulfillment"
        id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-sql/providers/Microsoft.Sql/servers/eh-sql-data-dev-sec/databases/fulfillment"
      }
      adapter = {
        name = "adapter"
        id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-sql/providers/Microsoft.Sql/servers/eh-sql-data-dev-sec/databases/adapter"
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
}
# END FIXTURE

run "flex_private" {
  command = plan

  assert {
    condition     = azurerm_function_app_flex_consumption.this.runtime_name == "dotnet-isolated" && azurerm_function_app_flex_consumption.this.runtime_version == "10.0"
    error_message = "hello-durable runs .NET 10 isolated on Flex Consumption."
  }
  assert {
    condition     = azurerm_function_app_flex_consumption.this.storage_authentication_type == "UserAssignedIdentity" && azurerm_function_app_flex_consumption.this.storage_container_endpoint == var.platform_functions.flex["durable"].deployment_container_url
    error_message = "Deployment storage uses the user-assigned identity (no keys)."
  }
  assert {
    condition     = azurerm_function_app_flex_consumption.this.app_settings["AzureWebJobsStorage__credential"] == "managedidentity" && azurerm_function_app_flex_consumption.this.app_settings["ServiceBusConnection__fullyQualifiedNamespace"] == var.platform_messaging.fqdn
    error_message = "Identity-based AzureWebJobsStorage and Service Bus connection."
  }
  assert {
    condition     = azurerm_function_app_flex_consumption.this.app_settings["DURABLE_TASK_HUB"] == "hellodurabledev" && azurerm_function_app_flex_consumption.this.app_settings["RECONCILE_SCHEDULE"] == "0 */30 * * * *"
    error_message = "Required %...% settings DURABLE_TASK_HUB and RECONCILE_SCHEDULE."
  }
  assert {
    condition     = azurerm_function_app_flex_consumption.this.app_settings["FAULTS_ENABLED"] == "false" && azurerm_function_app_flex_consumption.this.app_settings["FAULT_TOKEN"] == "dsv://eh/dev/fault-token#value" && azurerm_function_app_flex_consumption.this.app_settings["DSV_AUTH"] == "azure" && !anytrue([for k, v in azurerm_function_app_flex_consumption.this.app_settings : startswith(v, "@Microsoft.KeyVault(")]) && !contains(keys(azurerm_function_app_flex_consumption.this.app_settings), "FAULT_ACTIVITY_FAILURE_RATE")
    error_message = "Faults off by default; FAULT_TOKEN only as a DSV reference (no Key Vault references)."
  }
  assert {
    condition     = !contains(keys(azurerm_function_app_flex_consumption.this.app_settings), "LOG_FILE_PATH") && !contains(keys(azurerm_function_app_flex_consumption.this.app_settings), "WEBSITE_RUN_FROM_PACKAGE") && !contains(keys(azurerm_function_app_flex_consumption.this.app_settings), "FUNCTIONS_WORKER_RUNTIME")
    error_message = "No sidecar/log file on Functions (diagnostic settings route); Flex forbids run-from-package / worker runtime settings."
  }
  assert {
    condition     = azurerm_function_app_flex_consumption.this.app_settings["OTEL_EXPORTER_OTLP_ENDPOINT"] == var.obs_telemetry_transport.otlp.http_endpoint && azurerm_function_app_flex_consumption.this.app_settings["OTEL_EXPORTER_OTLP_PROTOCOL"] == "http/protobuf" && azurerm_function_app_flex_consumption.this.app_settings["OTEL_SERVICE_NAME"] == "hello-durable"
    error_message = "OTLP over HTTP to the gateway."
  }
  assert {
    condition     = azurerm_function_app_flex_consumption.this.app_settings["SQL_USE_AZURE_CREDENTIAL"] == "true" && !strcontains(azurerm_function_app_flex_consumption.this.app_settings["SQL_CONNECTION_STRING"], "Password")
    error_message = "SQL via managed identity token, no password."
  }
  assert {
    condition     = azurerm_function_app_flex_consumption.this.public_network_access_enabled == true && length(module.private_endpoint) == 0 && azurerm_function_app_flex_consumption.this.site_config[0].ip_restriction_default_action == "Deny"
    error_message = "Without foundation-network: restricted public endpoint (deny by default)."
  }
  assert {
    condition     = length(azurerm_windows_function_app.reconciliation) == 0 && output.contract.reconciliation_app == null
    error_message = "No Y1 plan => no Reconciliation app."
  }
  assert {
    condition     = output.contract.function_app.id != null && output.contract.deploy_steps[0].kind == "functionapp-flex" && output.contract.apps["hello-durable"].app_log_route == "eventhub"
    error_message = "Contract: function_app.id, deploy step, log route eventhub."
  }
}

run "private_endpoint_and_y1" {
  command = plan
  variables {
    foundation_network = {
      resource_group_name = "rg-net"
      location            = "swedencentral"
      private_dns_zones   = { webapps = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/privateDnsZones/privatelink.azurewebsites.net", name = "privatelink.azurewebsites.net" } }
      subnets             = { "private-endpoints" = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/v/subnets/pe", name = "pe", address_prefix = "10.41.6.0/24" } }
    }
    platform_functions = {
      resource_group_name        = "rg-func"
      flex_integration_subnet_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/v/subnets/flex"
      flex                       = { durable = { plan_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-func/providers/Microsoft.Web/serverFarms/flex", identity = "hello-durable", storage_account_name = "stflex", deployment_container_url = "https://stflex.blob.core.windows.net/deploy-durable" } }
      consumption_windows        = { plan_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-func/providers/Microsoft.Web/serverFarms/y1", storage_account_name = "sty1", identity = "hello-durable" }
    }
    settings = { faults_enabled = true }
  }
  assert {
    condition     = azurerm_function_app_flex_consumption.this.public_network_access_enabled == false && length(module.private_endpoint) == 1
    error_message = "With foundation-network the app is private (private endpoint)."
  }
  assert {
    condition     = length(azurerm_windows_function_app.reconciliation) == 1 && azurerm_windows_function_app.reconciliation[0].app_settings["AzureWebJobs.OrderEventsStarter.Disabled"] == "true" && azurerm_function_app_flex_consumption.this.app_settings["AzureWebJobs.ReconciliationTimer.Disabled"] == "true"
    error_message = "Y1 app runs only Reconciliation; Flex disables its reconciliation timer."
  }
  assert {
    condition     = azurerm_function_app_flex_consumption.this.app_settings["FAULT_ACTIVITY_FAILURE_RATE"] == "0.1"
    error_message = "Lab fault rate only when faults are enabled."
  }
}

run "upstream_urls_from_contracts" {
  command = plan
  variables {
    deploy_core_aks    = { apps = { "hello-orders-api" = { url = "http://hello-orders-api.hello.svc.cluster.local" } } }
    deploy_core_aca    = { apps = { "hello-orders-api" = { url = "https://hello-orders-api.internal.example.azurecontainerapps.io" } } }
    deploy_appservice  = { apps = { "hello-inventory-api" = { service = "hello-inventory-api", url = "https://app-inv.azurewebsites.net" } } }
    deploy_partner_sim = { url = "http://partner.hello.internal:8080" }
  }

  assert {
    condition     = azurerm_function_app_flex_consumption.this.app_settings["ORDERS_API_URL"] == "https://hello-orders-api.internal.example.azurecontainerapps.io" && azurerm_function_app_flex_consumption.this.app_settings["INVENTORY_API_URL"] == "https://app-inv.azurewebsites.net" && azurerm_function_app_flex_consumption.this.app_settings["PARTNER_API_URL"] == "http://partner.hello.internal:8080"
    error_message = "Upstream URLs are derived from the optional deploy contracts."
  }
  assert {
    condition     = output.contract.endpoints["hello-durable"] == "https://${azurerm_function_app_flex_consumption.this.default_hostname}/api" && output.contract.apps["hello-durable"].readiness_path == "/api/readyz"
    error_message = "Smoke endpoint is the /api base path (healthz/readyz/version)."
  }
}

run "upstream_url_settings_override_and_cluster_local_ignored" {
  command = plan
  variables {
    deploy_core_aks = { apps = { "hello-orders-api" = { url = "http://hello-orders-api.hello.svc.cluster.local" } } }
    settings        = { inventory_api_url = "https://inventory.override.example" }
  }

  assert {
    condition     = !contains(keys(azurerm_function_app_flex_consumption.this.app_settings), "ORDERS_API_URL") && azurerm_function_app_flex_consumption.this.app_settings["INVENTORY_API_URL"] == "https://inventory.override.example" && !contains(keys(azurerm_function_app_flex_consumption.this.app_settings), "PARTNER_API_URL")
    error_message = "Cluster-local URLs are ignored; settings override the contracts."
  }
}
