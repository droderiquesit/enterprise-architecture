mock_provider "azurerm" {
  override_during = plan
  mock_resource "azurerm_container_app" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-dbadapters-dev-sec/providers/Microsoft.App/containerApps/eh-ca-db-x-dev"
    }
  }
  mock_resource "azurerm_linux_web_app" {
    defaults = {
      id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-appsvc/providers/Microsoft.Web/sites/eh-app-dbmysql-dev-abcde"
      default_hostname = "eh-app-dbmysql-dev-abcde.azurewebsites.net"
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
  platform_vmss = {
    resource_group_name = "rg-vmss"
    location            = "swedencentral"
    scale_sets = {
      flexible = {
        id                 = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-vmss/providers/Microsoft.Compute/virtualMachineScaleSets/eh-vmss-vmss-dev-sec-flex"
        name               = "eh-vmss-vmss-dev-sec-flex"
        orchestration_mode = "Flexible"
        upgrade_mode       = "Manual"
        workload           = "hello-worker"
        identity_id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ident/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-worker"
        identity_client_id = "22222222-2222-2222-2222-000000000005"
        app_root           = "/opt/hello"
        log_dir            = "/var/log/hello"
      }
      uniform = {
        id                 = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-vmss/providers/Microsoft.Compute/virtualMachineScaleSets/eh-vmss-vmss-dev-sec-uni"
        name               = "eh-vmss-vmss-dev-sec-uni"
        orchestration_mode = "Uniform"
        upgrade_mode       = "Manual"
        workload           = "hello-dbadapter"
        identity_id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ident/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-dbadapter"
        identity_client_id = "22222222-2222-2222-2222-000000000004"
        app_root           = "/opt/hello"
        log_dir            = "/var/log/hello"
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
  platform_db_sqlmi = {
    enabled = true
    server = {
      fqdn = "eh-sqlmi-data-dev-sec.abc123.database.windows.net"
      port = 1433
    }
    databases = {
      adapter = {
        name = "adapter"
      }
    }
  }
  platform_db_sqlvm = {
    vm = {
      id                 = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-sqlvm/providers/Microsoft.Compute/virtualMachines/eh-vm-sqlvm-dev-sec"
      private_ip_address = "10.41.0.10"
    }
    server = {
      fqdn = "10.41.0.10"
      port = 1433
    }
    databases = {
      adapter = {
        name               = "adapter"
        login              = "dbadapter"
        password_secret_id = "dsv://eh/dev/sqlvm-dbadapter-password#value"
      }
    }
  }
  platform_db_postgresql = {
    server = {
      fqdn = "eh-psql-data-dev-sec.postgres.database.azure.com"
      port = 5432
    }
    databases = {
      catalog = {
        name = "catalog"
        id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-pg/providers/Microsoft.DBforPostgreSQL/flexibleServers/eh-psql-data-dev-sec/databases/catalog"
      }
      adapter = {
        name = "adapter"
        id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-pg/providers/Microsoft.DBforPostgreSQL/flexibleServers/eh-psql-data-dev-sec/databases/adapter"
      }
    }
    elastic_cluster = null
  }
  platform_db_mysql = {
    server = {
      fqdn = "eh-mysql-data-dev-sec.mysql.database.azure.com"
      port = 3306
    }
    databases = {
      adapter = {
        name = "adapter"
      }
    }
  }
  platform_db_cosmos_nosql = {
    account = {
      id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-cosmos/providers/Microsoft.DocumentDB/databaseAccounts/eh-cosmos-nosql-dev-abcde"
      name     = "eh-cosmos-nosql-dev-abcde"
      endpoint = "https://eh-cosmos-nosql-dev-abcde.documents.azure.com:443/"
    }
    auth_mode     = "entra-rbac"
    key_secret_id = null
    databases = {
      inventory = {
        name = "inventory"
        containers = {
          items = {
            name          = "items"
            partition_key = "/sku"
          }
        }
      }
      adapter = {
        name = "adapter"
        containers = {
          records = {
            name          = "records"
            partition_key = "/id"
          }
        }
      }
    }
  }
  platform_db_cosmos_mongo = {
    account = {
      id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-cosmos/providers/Microsoft.DocumentDB/databaseAccounts/eh-cosmos-mongo-dev-abcde"
      name     = "eh-cosmos-mongo-dev-abcde"
      endpoint = "https://eh-cosmos-mongo-dev-abcde.mongo.cosmos.azure.com:443/"
    }
    auth_mode     = "key"
    key_secret_id = "dsv://eh/dev/cosmos-mongo-connection-string#value"
    databases = {
      adapter = {
        name = "adapter"
        containers = {
          records = {
            name          = "records"
            partition_key = "_id"
          }
        }
      }
    }
  }
  platform_db_documentdb = {
    cluster = {
      id   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-docdb/providers/Microsoft.DocumentDB/mongoClusters/eh-docdb-data-dev-sec"
      name = "eh-docdb-data-dev-sec"
      host = "eh-docdb-data-dev-sec.global.mongocluster.cosmos.azure.com"
      port = 10260
    }
    databases = {
      adapter = {
        name = "adapter"
      }
    }
  }
  platform_db_cassandra_mi = {
    enabled = true
    cluster = {
      id                     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-cass/providers/Microsoft.DocumentDB/cassandraClusters/eh-mi-cass-dev-sec"
      datacenter             = "dc1"
      seed_node_ip_addresses = ["10.41.10.4", "10.41.10.5", "10.41.10.6"]
      port                   = 9042
    }
    databases = {
      adapter = {
        name               = "adapter"
        login              = "dbadapter"
        password_secret_id = "dsv://eh/dev/cassandra-mi-dbadapter-password#value"
      }
    }
  }
  platform_db_redis = {
    cache = {
      id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-redis/providers/Microsoft.Cache/redisEnterprise/eh-amr-data-dev-sec"
      hostname = "eh-amr-data-dev-sec.swedencentral.redis.azure.net"
      port     = 10000
    }
  }
  platform_db_table_storage = {
    account = {
      id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-tbl/providers/Microsoft.Storage/storageAccounts/ehsttbldevabcde"
      name     = "ehsttbldevabcde"
      endpoint = "https://ehsttbldevabcde.table.core.windows.net/"
    }
    databases = {
      notifications = {
        name = "notifications"
      }
      adapterrecords = {
        name = "adapterrecords"
      }
    }
  }
  platform_db_ledger = {
    ledger = {
      id                        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ledger/providers/Microsoft.ConfidentialLedger/ledgers/eh-ledger-dev"
      name                      = "eh-ledger-dev"
      ledger_endpoint           = "https://eh-ledger-dev.confidential-ledger.azure.com"
      identity_service_endpoint = "https://identity.confidential-ledger.core.azure.com/ledgerIdentity/eh-ledger-dev"
    }
    databases = {
      "order-audit" = {
        name = "order-audit"
      }
      adapter = {
        name = "adapter"
      }
    }
  }
  platform_data_analytics = {
    blob = {
      id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-da/providers/Microsoft.Storage/storageAccounts/ehstblobdevabcde"
      endpoint  = "https://ehstblobdevabcde.blob.core.windows.net/"
      container = "adapter"
    }
    adls          = null
    data_explorer = null
    search        = null
  }
}
# END FIXTURE

run "all_families" {
  command = plan

  assert {
    condition     = toset(keys(module.aca)) == toset(["sql", "sqlmi", "postgresql", "cosmos-nosql", "cosmos-mongo", "documentdb", "cassandra-mi", "redis", "table-storage", "ledger", "blob"])
    error_message = "One Container App per enabled family hosted on ACA."
  }
  assert {
    condition     = keys(module.appsvc) == ["mysql"] && keys(azurerm_virtual_machine_scale_set_extension.sqlvm_adapter) == ["sqlvm"]
    error_message = "mysql on App Service Linux code, sqlvm on VMSS Uniform (architecture matrix)."
  }
  assert {
    condition     = local.hosting["sqlmi"] == "aca-dedicated" && local.hosting["redis"] == "aca-dedicated" && local.hosting["sql"] == "aca"
    error_message = "sqlmi and redis run on the dedicated-d4 workload profile."
  }
  assert {
    condition     = module.env["sql"].env["DD_SERVICE"] == "hello-dbadapter-sql" && module.env["sql"].env["DB_FAMILY"] == "sql" && module.env["mysql"].env["DD_SERVICE"] == "hello-dbadapter-mysql"
    error_message = "DD_SERVICE=hello-dbadapter-<family>."
  }
  assert {
    condition     = module.env["cosmos-mongo"].env["MONGO_URI"] == "dsv://eh/dev/cosmos-mongo-connection-string#value" && module.env["cosmos-mongo"].secret_env["MONGO_URI"] == "dsv://eh/dev/cosmos-mongo-connection-string#value"
    error_message = "Key-based families get their credential only as a DSV reference (the adapter resolves it at start-up)."
  }
  assert {
    condition     = alltrue([for k, a in module.aca : contains(["init", "refresher"], a.dsv_fetch_mode)]) && anytrue([for k, a in module.aca : a.dsv_fetch_mode == "refresher" && contains(a.container_names, "dsv-fetch")])
    error_message = "Consumption: dsv-fetch init container; Dedicated workload profile: refresher container (init containers get no managed identity there)."
  }
  assert {
    condition     = alltrue([for f, a in module.aca : a.has_sidecar && a.container_names[1] == "fluent-bit"]) && alltrue([for f, e in module.env : e.env["FAULTS_ENABLED"] == "false"])
    error_message = "ACA adapters carry the Fluent Bit sidecar; faults off by default."
  }
  assert {
    condition     = !contains(keys(module.appsvc["mysql"].app_settings), "LOG_FILE_PATH") && module.appsvc["mysql"].app_settings["MYSQL_AUTH"] == "entra"
    error_message = "App Service adapter: no sidecar/log file, Entra auth."
  }
  assert {
    condition     = strcontains(module.vmss_script["sqlvm"].env_file, "SQL_PASSWORD=\"dsv://eh/dev/sqlvm-dbadapter-password#value\"") && !strcontains(module.vmss_script["sqlvm"].script, "vault.azure.net")
    error_message = "VMSS env file carries only the DSV reference of the SQL password (resolved by the adapter)."
  }
  assert {
    condition     = output.contract.adapters["sqlvm"].url == null && output.contract.adapters["mysql"].url == "https://eh-app-dbmysql-dev-abcde.azurewebsites.net" && output.contract.adapters["sql"].id != null
    error_message = "Contract adapters.<family>.{id,url}."
  }
  assert {
    condition     = contains(keys(output.contract.skipped), "cosmos-gremlin") && contains(keys(output.contract.skipped), "adx")
    error_message = "Families without a platform contract are reported as skipped."
  }
}

run "no_optional_producers" {
  command = plan
  variables {
    platform_appservice       = null
    platform_vmss             = null
    platform_db_sql           = null
    platform_db_sqlmi         = null
    platform_db_sqlvm         = null
    platform_db_postgresql    = null
    platform_db_mysql         = null
    platform_db_cosmos_nosql  = null
    platform_db_cosmos_mongo  = null
    platform_db_documentdb    = null
    platform_db_cassandra_mi  = null
    platform_db_redis         = null
    platform_db_table_storage = null
    platform_db_ledger        = null
    platform_data_analytics   = null
  }
  assert {
    condition     = length(module.aca) == 0 && length(module.appsvc) == 0 && length(azurerm_virtual_machine_scale_set_extension.sqlvm_adapter) == 0 && length(output.contract.adapters) == 0
    error_message = "Optional producers null => no adapter resources."
  }
}

run "fallback_and_overrides" {
  command = plan
  variables {
    platform_appservice = null
    settings = {
      families = { "redis" = { hosting = "aca" }, "blob" = { enabled = false } }
    }
  }
  assert {
    condition     = local.hosting["mysql"] == "aca" && local.hosting["redis"] == "aca" && !contains(keys(module.aca), "blob")
    error_message = "No App Service plan => mysql falls back to ACA; settings override hosting / disable families."
  }
}

run "observability_pipelines_serverless_init_every_profile" {
  # observability 4.0.0 default (lab contract switches): serverless-init collects traces, DogStatsD and the app log
  # file; its key is read by the dsv-fetch binary, installed by an identity-free init container - so the Dedicated
  # workload profile needs no refresher container any more.
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
      aggregator = { kind = "observability_pipelines", agent_logs_url = "http://opw:8282" }
      env        = { fleet = { EH_APM_MODE = "datadog", EH_LOG_PIPELINE = "observability_pipelines" } }
    }
  }
  assert {
    condition     = alltrue([for k, a in module.aca : jsonencode(a.container_names) == jsonencode([local.svc, "datadog"]) && jsonencode(a.init_container_names) == jsonencode(["dsv-fetch-install"]) && a.dsv_fetch_mode == "init"])
    error_message = "Every ACA adapter (Consumption and Dedicated): serverless-init only, binary installer init container, no refresher, no Fluent Bit."
  }
  assert {
    condition     = alltrue([for k, a in module.aca : module.env[k].log_collector == "serverless-init"]) && module.env["mysql"].log_collector == "diagnostic-settings"
    error_message = "ACA adapters: serverless-init log collection; App Service adapter: diagnostic settings."
  }
}
