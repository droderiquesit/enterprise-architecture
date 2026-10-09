mock_provider "azurerm" {
  override_during = plan
  mock_resource "azurerm_container_app_job" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-jobs-dev-sec/providers/Microsoft.App/jobs/eh-caj-seed-dev"
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
    batch_log_setup = {
      script_gzip_base64 = "H4sIAAAAAAAA/0tMSlYoyS9JLCpRSM7PS8ss4uUCAA8i5CsRAAAA"
      script_sha256      = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
      fluent_bit_version = "5.1.3"
      log_paths_template = "$AZ_BATCH_NODE_ROOT_DIR/workitems/*/job-*/*/stdout.txt"
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

run "jobs_minimal" {
  command = plan

  assert {
    condition     = alltrue([for k, j in azurerm_container_app_job.this : length(j.secret) == 0 && alltrue([for e in j.template[0].container[0].env : e.secret_name == null])])
    error_message = "Jobs carry no Container Apps secrets / Key Vault references; secret settings are dsv:// env values."
  }

  assert {
    condition     = toset(keys(azurerm_container_app_job.this)) == toset(["seed", "reconcile", "batchitems"])
    error_message = "seed, reconcile and the event-driven processor; traffic needs deploy-frontend."
  }
  assert {
    condition     = length(azurerm_container_app_job.this["seed"].manual_trigger_config) == 1 && azurerm_container_app_job.this["reconcile"].schedule_trigger_config[0].cron_expression == "15 * * * *"
    error_message = "Manual seed and scheduled reconcile-trigger."
  }
  assert {
    condition     = azurerm_container_app_job.this["batchitems"].event_trigger_config[0].scale[0].rules[0].custom_rule_type == "azure-servicebus" && azurerm_container_app_job.this["batchitems"].event_trigger_config[0].scale[0].rules[0].identity_id == var.foundation_identity.identities["hello-jobs"].id && length(azurerm_container_app_job.this["batchitems"].event_trigger_config[0].scale[0].rules[0].authentication) == 0
    error_message = "KEDA azure-servicebus scaler authenticated with the workload identity (no connection string)."
  }
  assert {
    condition     = alltrue([for k, j in azurerm_container_app_job.this : length(j.template[0].container) == 1 && !contains([for e in j.template[0].container[0].env : e.name], "LOG_FILE_PATH")])
    error_message = "Jobs run without a sidecar and log to stdout."
  }
  assert {
    condition     = output.contract.jobs["seed"].id != null && output.contract.batch == null && length(output.contract.deploy_steps) == 0
    error_message = "Contract jobs.seed.id; no Batch without platform-batch."
  }
}

run "traffic_and_batch" {
  command = plan
  variables {
    deploy_frontend = { url = "https://gentle-sky-0123456.azurestaticapps.net" }
    deploy_core_aca = { public_api = { origin = "https://bff.example" }, apps = { "hello-catalog-api" = { url = "https://catalog.internal.example" } } }
    deploy_core_aks = { apps = { "hello-orders-api" = { url = "http://hello-orders-api.hello.svc.cluster.local" } } }
    deploy_durable  = { function_app = { hostname = "eh-func-durable-dev.azurewebsites.net" } }
    platform_batch = {
      account_name     = "ehbabatchdevabcde"
      account_endpoint = "https://ehbabatchdevabcde.swedencentral.batch.azure.com"
      pool             = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-batch/providers/Microsoft.Batch/batchAccounts/b/pools/hello", name = "hello" }
      identity         = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ident/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-jobs", client_id = "c" }
      auto_storage     = { name = "st", blob_endpoint = "https://st.blob.core.windows.net/", packages_container = "jobs-packages", output_container = "jobs-output" }
    }
  }
  assert {
    condition     = contains(keys(azurerm_container_app_job.this), "traffic") && azurerm_container_app_job.this["traffic"].replica_timeout_in_seconds == 420
    error_message = "Traffic job bounded by duration + margin."
  }
  assert {
    condition     = contains([for e in azurerm_container_app_job.this["reconcile"].template[0].container[0].env : "${e.name}=${e.value}"], "DURABLE_API_URL=https://eh-func-durable-dev.azurewebsites.net") && !contains([for e in azurerm_container_app_job.this["seed"].template[0].container[0].env : e.name], "ORDERS_API_URL")
    error_message = "DURABLE_API_URL derived from deploy-durable; cluster-local AKS URLs are not used by ACA jobs."
  }
  assert {
    condition     = output.contract.batch.pool_id == "hello" && output.contract.deploy_steps[0].kind == "batch-job"
    error_message = "Batch submission described in the contract (pipeline script)."
  }
  assert {
    condition     = output.contract.batch.job_preparation.script_sha256 == var.obs_telemetry_transport.batch_log_setup.script_sha256 && output.contract.batch.job_preparation.environment["EH_IDENTITY_CLIENT_ID"] == "c" && output.contract.batch.job_preparation.environment["EH_LOG_PATHS"] == "$AZ_BATCH_NODE_ROOT_DIR/workitems/*/job-*/*/stdout.txt"
    error_message = "Batch job preparation task carries the observability Fluent Bit setup with the pool identity and the Batch task stdout paths."
  }
}
