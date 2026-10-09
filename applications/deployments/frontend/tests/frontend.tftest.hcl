mock_provider "azurerm" {
  override_during = plan
  mock_resource "azurerm_static_web_app" {
    defaults = {
      id                = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-frontend-dev-sec/providers/Microsoft.Web/staticSites/eh-stapp-frontend-dev-sec"
      default_host_name = "gentle-sky-0123456.azurestaticapps.net"
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
  obs_prereqs = {
    datadog_site = "datadoghq.com"
    rum = {
      applications = {
        "hello-frontend" = {
          application_id             = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
          client_token               = "pub0123456789abcdef0123456789abcdef"
          site                       = "datadoghq.com"
          service                    = "hello-frontend"
          session_sample_rate        = 100
          session_replay_sample_rate = 0
          default_privacy_level      = "mask-user-input"
          track_user_interactions    = true
        }
      }
    }
  }
  foundation_identity = {
    key_vault_id  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ident/providers/Microsoft.KeyVault/vaults/eh-kv-ident-dev-abcde"
    key_vault_uri = "https://eh-kv-ident-dev-abcde.vault.azure.net/"
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
    secret_ids = {
      "datadog-api-key"      = "https://eh-kv-ident-dev-abcde.vault.azure.net/secrets/datadog-api-key"
      "datadog-app-key"      = "https://eh-kv-ident-dev-abcde.vault.azure.net/secrets/datadog-app-key"
      "fault-token"          = "https://eh-kv-ident-dev-abcde.vault.azure.net/secrets/fault-token"
      "datadog-client-token" = "https://eh-kv-ident-dev-abcde.vault.azure.net/secrets/datadog-client-token"
    }
  }
}
# END FIXTURE

run "aca_api" {
  command = plan
  variables {
    deploy_core_aca = { public_api = { origin = "https://eh-ca-bff-dev.kindstone-12345678.swedencentral.azurecontainerapps.io", base_path = "/api" } }
  }
  assert {
    condition     = azurerm_static_web_app.this.location == "westeurope" && azurerm_static_web_app.this.sku_tier == "Free"
    error_message = "SWA in westeurope (not offered in swedencentral), Free by default."
  }
  assert {
    condition     = jsondecode(output.contract.runtime_files["config.json"]).apiBaseUrl == "https://eh-ca-bff-dev.kindstone-12345678.swedencentral.azurecontainerapps.io"
    error_message = "apiBaseUrl comes from deploy-core-aca."
  }
  assert {
    condition     = jsondecode(output.contract.runtime_files["config.json"]).rum.allowedTracingUrls == ["https://eh-ca-bff-dev.kindstone-12345678.swedencentral.azurecontainerapps.io"] && jsondecode(output.contract.runtime_files["config.json"]).rum.sessionReplaySampleRate == 0
    error_message = "RUM traces only first-party API origins; session replay off."
  }
  assert {
    condition     = strcontains(jsondecode(output.contract.runtime_files["staticwebapp.config.json"]).globalHeaders["Content-Security-Policy"], "connect-src 'self' https://eh-ca-bff-dev.kindstone-12345678.swedencentral.azurecontainerapps.io https://browser-intake-datadoghq.com")
    error_message = "CSP connect-src must allow the API origin and the Datadog browser intake."
  }
  assert {
    condition     = output.contract.url == "https://gentle-sky-0123456.azurestaticapps.net" && !strcontains(jsonencode(output.contract), "deployment_token")
    error_message = "Contract has the site URL and never a deployment token."
  }
  assert {
    condition     = output.contract.deploy_steps[0].kind == "swa" && output.contract.deploy_steps[0].package_sha256 != null
    error_message = "Content upload is a pipeline step with the svc-frontend package."
  }
}

run "aks_api_eu_site" {
  command = plan
  variables {
    deploy_core_aks = { public_api = { origin = "https://api.hello.example.com" } }
    obs_prereqs = {
      datadog_site = "us3.datadoghq.com"
      rum          = { applications = { "hello-frontend" = { application_id = "app", client_token = "pubtoken", site = "us3.datadoghq.com", session_sample_rate = 50, session_replay_sample_rate = 0 } } }
    }
  }
  assert {
    condition     = jsondecode(output.contract.runtime_files["config.json"]).apiBaseUrl == "https://api.hello.example.com" && strcontains(jsondecode(output.contract.runtime_files["staticwebapp.config.json"]).globalHeaders["Content-Security-Policy"], "https://browser-intake-us3-datadoghq.com")
    error_message = "AKS origin used when ACA is absent; intake host follows the Datadog site."
  }
}

run "no_api_contract" {
  command = plan
  assert {
    condition     = jsondecode(output.contract.runtime_files["config.json"]).apiBaseUrl == "https://api.invalid"
    error_message = "Optional producers absent => placeholder origin and a failing check (warning)."
  }
  expect_failures = [check.api_origin_known]
}
