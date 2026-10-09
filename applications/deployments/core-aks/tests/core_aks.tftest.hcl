mock_provider "azurerm" {
  override_during = plan
  mock_data "azurerm_kubernetes_cluster" {
    defaults = {
      kube_config = [{
        host                   = "https://eh-aks-aks-dev-sec-abc.privatelink.swedencentral.azmk8s.io:443"
        cluster_ca_certificate = "Y2E="
        client_certificate     = ""
        client_key             = ""
        password               = ""
        username               = "clusterUser"
      }]
    }
  }
}

mock_provider "kubernetes" {
  override_during = plan
}

mock_provider "helm" {
  override_during = plan
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
  platform_aks = {
    resource_group_name = "rg-aks"
    cluster_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks/providers/Microsoft.ContainerService/managedClusters/eh-aks-aks-dev-sec"
    cluster_name        = "eh-aks-aks-dev-sec"
    oidc_issuer_url     = "https://swedencentral.oic.prod-aks.azure.com/tenant/guid/"
    access = {
      private_cluster     = true
      fqdn                = null
      private_fqdn        = "eh-aks-aks-dev-sec-abc.privatelink.swedencentral.azmk8s.io"
      entra_server_app_id = "6dae42f8-4368-4678-94ff-3960e28e3630"
    }
    workload_identities = {
      "hello-bff" = {
        namespace       = "hello"
        service_account = "hello-bff"
        client_id       = "33333333-3333-3333-3333-000000000000"
      }
      "hello-orders-api" = {
        namespace       = "hello"
        service_account = "hello-orders-api"
        client_id       = "33333333-3333-3333-3333-000000000001"
      }
      "hello-catalog-api" = {
        namespace       = "hello"
        service_account = "hello-catalog-api"
        client_id       = "33333333-3333-3333-3333-000000000002"
      }
      "hello-worker" = {
        namespace       = "hello"
        service_account = "hello-worker"
        client_id       = "33333333-3333-3333-3333-000000000003"
      }
    }
    key_vault_secrets_provider = {
      client_id    = "44444444-4444-4444-4444-444444444444"
      principal_id = "55555555-5555-5555-5555-555555555555"
    }
  }
  platform_shared = {
    acr_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-shared/providers/Microsoft.ContainerRegistry/registries/ehcrshareddevabcde"
    acr_login_server = "ehcrshareddevabcde.azurecr.io"
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
  variables {
    platform_db_redis = null
  }

  assert {
    condition     = length(helm_release.app) == 4 && kubernetes_namespace_v1.hello.metadata[0].name == "hello" && alltrue([for k, r in helm_release.app : r.name == k && r.namespace == "hello" && !r.create_namespace])
    error_message = "One Helm release per workload (bff, orders-api, catalog-api, worker) in namespace hello (namespace owned by this root)."
  }
  assert {
    condition     = alltrue([for k, r in helm_release.app : r.atomic && r.wait && r.cleanup_on_fail && r.timeout == 600 && r.max_history == 10 && r.lint && !r.take_ownership])
    error_message = "Releases are atomic, wait for readiness, clean up on failure, keep bounded history for rollback and lint at plan."
  }
  assert {
    condition     = alltrue([for k, r in helm_release.app : endswith(r.chart, "applications/charts/hello-service") && r.repository == null]) && local.chart.version == null
    error_message = "Default chart source is the repository chart applications/charts/hello-service."
  }
  assert {
    condition     = alltrue([for k, r in helm_release.app : yamldecode(r.values[0]).identity.clientId == var.platform_aks.workload_identities[k].client_id && yamldecode(r.values[0]).identity.workloadIdentity && yamldecode(r.values[0]).serviceAccount.name == var.platform_aks.workload_identities[k].service_account])
    error_message = "Workload identity: ServiceAccount name and client id from the platform-aks contract."
  }
  assert {
    condition     = alltrue([for k, r in helm_release.app : can(regex("^sha256:[a-f0-9]{64}$", yamldecode(r.values[0]).image.digest)) && !can(yamldecode(r.values[0]).image.tag) && "${yamldecode(r.values[0]).image.repository}@${yamldecode(r.values[0]).image.digest}" == var.artifacts[local.meta[k].artifact].image])
    error_message = "Images must be digest-pinned (repository + sha256 digest, no tag)."
  }
  assert {
    condition     = alltrue([for k, r in helm_release.app : yamldecode(r.values[0]).telemetry.agentHostFromHostIP && yamldecode(r.values[0]).telemetry.disableAgentLogCollection && !yamldecode(r.values[0]).logFile.enabled && !contains(keys(yamldecode(r.values[0]).env), "DD_AGENT_HOST")])
    error_message = "DD_AGENT_HOST from status.hostIP is rendered by the chart (first env var); no file logging/sidecar on AKS (Fluent Bit DaemonSet)."
  }
  assert {
    condition     = yamldecode(helm_release.app["hello-bff"].values[0]).env["OTEL_EXPORTER_OTLP_ENDPOINT"] == "http://$(DD_AGENT_HOST):4317" && yamldecode(helm_release.app["hello-bff"].values[0]).env["OTEL_EXPORTER_OTLP_PROTOCOL"] == "grpc"
    error_message = "AKS OTLP goes to the node-local agent over gRPC."
  }
  assert {
    condition     = alltrue([for k, r in helm_release.app : !yamldecode(r.values[0]).faults.enabled && length(setintersection(keys(yamldecode(r.values[0]).env), ["FAULTS_ENABLED", "FAULT_TOKEN", "LOG_FILE_PATH", "DD_ENV", "DD_SERVICE", "DD_VERSION", "AZURE_CLIENT_ID", "PORT"])) == 0]) && alltrue([for k, e in module.env : e.env["FAULTS_ENABLED"] == "false"])
    error_message = "Faults disabled by default; chart-owned env (FAULTS_ENABLED, DD_*, AZURE_CLIENT_ID, PORT) and FAULT_TOKEN never in plain env."
  }
  assert {
    condition     = alltrue([for k, r in helm_release.app : alltrue([for n, v in yamldecode(r.values[0]).env : !can(regex("(PASSWORD|SECRET|TOKEN|API_KEY|ACCESS_KEY)$", n))]) && alltrue([for n, id in yamldecode(r.values[0]).secretEnv : can(regex("^https://[^/]+/secrets/[A-Za-z0-9-]+$", id))])])
    error_message = "No plaintext secrets: secret env carries versionless Key Vault ids only."
  }
  assert {
    condition     = length([for k, r in helm_release.app : k if yamldecode(r.values[0]).keyVault.enabled]) == 3 && local.kv_name == "eh-kv-ident-dev-abcde" && !yamldecode(helm_release.app["hello-worker"].values[0]).keyVault.enabled && yamldecode(helm_release.app["hello-bff"].values[0]).secretEnv["FAULT_TOKEN"] == var.foundation_identity.secret_ids["fault-token"]
    error_message = "SecretProviderClass (chart keyVault.enabled) per HTTP app reading fault-token (worker has no fault token)."
  }
  assert {
    condition     = yamldecode(helm_release.app["hello-bff"].values[0]).k8sService.type == "LoadBalancer" && yamldecode(helm_release.app["hello-bff"].values[0]).k8sService.internalLoadBalancer && !yamldecode(helm_release.app["hello-bff"].values[0]).ingress.enabled && length(data.kubernetes_service_v1.bff) == 1 && yamldecode(helm_release.app["hello-orders-api"].values[0]).k8sService.type == "ClusterIP"
    error_message = "Without the app routing add-on the BFF is exposed on an internal load balancer."
  }
  assert {
    condition     = alltrue([for k, r in helm_release.app : yamldecode(r.values[0]).autoscaling.maxReplicas <= var.settings.replica_ceiling || yamldecode(r.values[0]).autoscaling.maxReplicas <= 6]) && alltrue([for k, r in helm_release.app : yamldecode(r.values[0]).podDisruptionBudget.enabled])
    error_message = "HPA ceilings and PDBs for every Deployment."
  }
  assert {
    condition     = yamldecode(helm_release.app["hello-worker"].values[0]).kind == "worker" && yamldecode(helm_release.app["hello-worker"].values[0]).port == 8081 && yamldecode(helm_release.app["hello-bff"].values[0]).kind == "deployment"
    error_message = "Worker uses the worker kind (health port 8081, no Service); HTTP services the deployment kind."
  }
  assert {
    condition     = alltrue([for k, r in helm_release.app : yamldecode(r.values[0]).service.name == k && yamldecode(r.values[0]).service.env == "dev" && yamldecode(r.values[0]).service.version == local.artifact_version[local.meta[k].artifact]]) && yamldecode(helm_release.app["hello-orders-api"].values[0]).service.version == "1.4.2" && yamldecode(helm_release.app["hello-catalog-api"].values[0]).service.logsSource == "python"
    error_message = "Unified service tagging values (env/service/version) for the chart labels and DD_* env."
  }
  assert {
    condition     = output.contract.apps["hello-worker"].app_log_route == "daemonset" && !output.contract.apps["hello-worker"].scale_to_zero && output.contract.apps["hello-bff"].type == "Kubernetes/Deployment" && !output.contract.apps["hello-bff"].sidecar && output.contract.apps["hello-bff"].id == "${var.platform_aks.cluster_id}/namespaces/hello/deployments/hello-bff"
    error_message = "Contract per app unchanged: log route daemonset, no sidecar, no scale-to-zero, Deployment id."
  }
  assert {
    condition     = output.contract.helm.chart == "hello-service" && length(output.contract.helm.releases) == 4
    error_message = "Contract lists the Helm releases."
  }
}

run "app_routing_and_no_csi" {
  command = plan
  variables {
    platform_aks = {
      resource_group_name = "rg-aks"
      cluster_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-aks/providers/Microsoft.ContainerService/managedClusters/aks"
      cluster_name        = "aks"
      oidc_issuer_url     = "https://oidc.example/"
      access              = { private_cluster = true, private_fqdn = "aks.privatelink.swedencentral.azmk8s.io" }
      workload_identities = {
        "hello-bff"         = { namespace = "hello", service_account = "hello-bff", client_id = "c1" }
        "hello-orders-api"  = { namespace = "hello", service_account = "hello-orders-api", client_id = "c2" }
        "hello-catalog-api" = { namespace = "hello", service_account = "hello-catalog-api", client_id = "c3" }
        "hello-worker"      = { namespace = "hello", service_account = "hello-worker", client_id = "c4" }
      }
      key_vault_secrets_provider = null
    }
    settings = {
      faults_enabled = true
      exposure       = { mode = "app-routing", host = "api.hello.example.com", tls_cert_keyvault_id = "https://kv.vault.azure.net/certificates/hello-api" }
    }
  }
  assert {
    condition     = yamldecode(helm_release.app["hello-bff"].values[0]).ingress.enabled && yamldecode(helm_release.app["hello-bff"].values[0]).ingress.host == "api.hello.example.com" && yamldecode(helm_release.app["hello-bff"].values[0]).ingress.tls.keyVaultCertificateUri == "https://kv.vault.azure.net/certificates/hello-api" && yamldecode(helm_release.app["hello-bff"].values[0]).k8sService.type == "ClusterIP" && length(data.kubernetes_service_v1.bff) == 0
    error_message = "app-routing mode uses the managed NGINX ingress with TLS from Key Vault."
  }
  assert {
    condition     = alltrue([for k, r in helm_release.app : !yamldecode(r.values[0]).keyVault.enabled && length(yamldecode(r.values[0]).secretEnv) == 0 && !yamldecode(r.values[0]).faults.enabled]) && output.contract.public_api.origin == "https://api.hello.example.com"
    error_message = "No CSI driver => no SecretProviderClass and no FAULT_TOKEN, so faults stay disabled; public origin from the ingress host."
  }
}

run "oci_chart_and_network_policy" {
  command = plan
  variables {
    settings = {
      helm                       = { chart_repository = "oci://ehcrshareddevabcde.azurecr.io/helm", chart_version = "1.0.0", take_ownership = true }
      network_policy_enabled     = true
      network_policy_allow_cidrs = ["10.20.0.0/16"]
      apps                       = { "hello-bff" = { max_replicas = 4 }, "hello-orders-api" = {}, "hello-catalog-api" = {}, "hello-worker" = { enabled = false } }
    }
  }
  assert {
    condition     = length(helm_release.app) == 3 && !contains(keys(helm_release.app), "hello-worker") && alltrue([for k, r in helm_release.app : r.chart == "hello-service" && r.repository == "oci://ehcrshareddevabcde.azurecr.io/helm" && r.version == "1.0.0" && r.take_ownership])
    error_message = "OCI chart from ACR (published by the applications pipeline) with an explicit chart version; only enabled apps get releases."
  }
  assert {
    condition     = yamldecode(helm_release.app["hello-bff"].values[0]).networkPolicy.enabled && yamldecode(helm_release.app["hello-bff"].values[0]).networkPolicy.allowFromCIDRs == ["10.20.0.0/16"] && yamldecode(helm_release.app["hello-catalog-api"].values[0]).networkPolicy.allowFromCIDRs == [] && yamldecode(helm_release.app["hello-bff"].values[0]).autoscaling.maxReplicas == 4
    error_message = "NetworkPolicy values (LB client CIDRs only for the BFF) and per-app HPA ceiling."
  }
}

run "rejects_oci_without_version" {
  command = plan
  variables {
    settings = { helm = { chart_repository = "oci://ehcrshareddevabcde.azurecr.io/helm" } }
  }
  expect_failures = [var.settings]
}

run "rejects_mutable_tags" {
  command = plan
  variables {
    artifacts = { "svc-bff" = { image = "ehcrshareddevabcde.azurecr.io/hello-bff:1.0" } }
  }
  expect_failures = [var.artifacts]
}
