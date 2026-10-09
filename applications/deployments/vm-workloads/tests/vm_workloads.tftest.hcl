mock_provider "azurerm" {
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
  platform_vm = {
    resource_group_name = "rg-vm"
    location            = "swedencentral"
    vms = {
      linux = {
        id                 = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-vm/providers/Microsoft.Compute/virtualMachines/eh-vm-vm-dev-sec-lin"
        name               = "eh-vm-vm-dev-sec-lin"
        os_type            = "Linux"
        private_ip         = "10.41.0.4"
        workload           = "hello-worker"
        identity_id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ident/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-worker"
        identity_client_id = "22222222-2222-2222-2222-000000000005"
        app_root           = "/opt/hello"
        log_dir            = "/var/log/hello"
      }
      windows = {
        id                 = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-vm/providers/Microsoft.Compute/virtualMachines/eh-vm-vm-dev-sec-win"
        name               = "eh-vm-vm-dev-sec-win"
        os_type            = "Windows"
        private_ip         = "10.41.0.5"
        workload           = "hello-inventory-api"
        identity_id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ident/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-hello-inventory-api"
        identity_client_id = "22222222-2222-2222-2222-000000000002"
        app_root           = "C:\\hello"
        log_dir            = "C:\\hello\\logs"
      }
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
}
# END FIXTURE

run "all_hosts" {
  command = plan

  assert {
    condition     = length(azurerm_virtual_machine_run_command.worker) == 1 && length(azurerm_virtual_machine_run_command.inventory) == 1 && length(azurerm_virtual_machine_scale_set_extension.worker) == 1
    error_message = "Linux worker run command, Windows inventory run command and VMSS Flexible extension."
  }
  assert {
    condition     = strcontains(azurerm_virtual_machine_run_command.worker[0].source[0].script, "deploy/install.sh") && strcontains(azurerm_virtual_machine_run_command.worker[0].source[0].script, "https%3A%2F%2Fstorage.azure.com%2F")
    error_message = "Worker installed by its package install.sh; package read with the managed identity (no SAS)."
  }
  assert {
    condition     = !strcontains(azurerm_virtual_machine_run_command.worker[0].source[0].script, "sig=") && !strcontains(azurerm_virtual_machine_run_command.inventory[0].source[0].script, "sig=")
    error_message = "No SAS tokens in scripts/state."
  }
  assert {
    condition     = strcontains(azurerm_virtual_machine_run_command.inventory[0].source[0].script, "$envVars['FAULT_TOKEN'] = 'dsv://eh/dev/fault-token#value'") && !strcontains(azurerm_virtual_machine_run_command.inventory[0].source[0].script, "vault.azure.net") && strcontains(azurerm_virtual_machine_run_command.inventory[0].source[0].script, "$envVars['FAULTS_ENABLED'] = 'false'")
    error_message = "Inventory FAULT_TOKEN is a dsv:// reference resolved by the service; faults off by default; no Key Vault."
  }
  assert {
    condition     = module.env["worker-vm"].env["OTEL_EXPORTER_OTLP_ENDPOINT"] == "http://localhost:4317" && module.env["worker-vm"].log_route == "host" && local.host_env["worker-vm"]["TABLE_MODE"] == "table"
    error_message = "Host route: local agent OTLP, Fluent Bit host service, Table Storage via identity."
  }
  assert {
    condition     = output.contract.apps["inventory-vm"].type == "Microsoft.Compute/virtualMachines" && output.contract.deploy_steps[0].kind == "vmss-flex-rollout"
    error_message = "Contract per host and VMSS rollout step."
  }
}

run "no_hosts" {
  command = plan
  variables {
    platform_vm   = null
    platform_vmss = null
  }
  assert {
    condition     = length(azurerm_virtual_machine_run_command.worker) + length(azurerm_virtual_machine_run_command.inventory) + length(azurerm_virtual_machine_scale_set_extension.worker) == 0 && length(output.contract.apps) == 0
    error_message = "Optional producers null => no resources."
  }
}
