mock_provider "azurerm" {
  override_during = plan
  mock_data "azurerm_key_vault_secret" {
    defaults = { value = "mock-not-a-real-key" }
  }
}

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
  obs_telemetry_transport = {
    datadog_site      = "datadoghq.com"
    api_key_secret_id = "https://eh-kv-ident-dev-abcde.vault.azure.net/secrets/datadog-api-key"
  }
  foundation_identity = {
    key_vault_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-id/providers/Microsoft.KeyVault/vaults/eh-kv-ident-dev-abcde"
  }
  platform_vm = {
    location = "swedencentral"
    vms = {
      worker = {
        id                 = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-vm/providers/Microsoft.Compute/virtualMachines/eh-vm-worker-dev-sec"
        name               = "eh-vm-worker-dev-sec"
        os_type            = "Linux"
        workload           = "hello-worker"
        identity_client_id = "22222222-2222-2222-2222-222222222222"
      }
      inventory = {
        id                 = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-vm/providers/Microsoft.Compute/virtualMachines/eh-vm-inv-dev-sec"
        name               = "eh-vm-inv-dev-sec"
        os_type            = "Windows"
        workload           = "hello-inventory-api"
        identity_client_id = "22222222-2222-2222-2222-222222222222"
      }
    }
  }
  platform_vmss = {
    scale_sets = {
      worker = {
        id                 = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-vm/providers/Microsoft.Compute/virtualMachineScaleSets/eh-vmss-worker-dev-sec"
        name               = "eh-vmss-worker-dev-sec"
        os_type            = "Linux"
        workload           = "hello-worker"
        identity_client_id = "22222222-2222-2222-2222-222222222222"
        log_dir            = "/opt/enterprise-hello/logs"
      }
    }
  }
  platform_db_sqlvm = {
    vm = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-db/providers/Microsoft.Compute/virtualMachines/eh-vm-sql-dev-sec", name = "eh-vm-sql-dev-sec" }
  }
}

run "lab_hosts" {
  command = plan
  assert {
    condition     = jsonencode(output.hosts["vm-worker"]) == jsonencode(["/var/log/enterprise-hello/*.log"]) && jsonencode(output.hosts["vmss-worker"]) == jsonencode(["/opt/enterprise-hello/logs/*.log"])
    error_message = "Log paths from contract log_dir or defaults."
  }
  assert {
    condition     = jsonencode(output.hosts["sqlvm"]) == jsonencode([]) && length(module.hosts.setup) == 4
    error_message = "SQL VM: Agent only (setup still configures OTLP/logs-off), no Fluent Bit."
  }
  assert {
    condition     = length(module.hosts.agent_extensions) == 4
    error_message = "Agent on every host."
  }
}

run "no_hosts_no_secret_read" {
  command = plan
  variables {
    platform_vm       = null
    platform_vmss     = null
    platform_db_sqlvm = null
  }
  assert {
    condition     = length(data.azurerm_key_vault_secret.api_key) == 0 && length(module.hosts.agent_extensions) == 0
    error_message = "Nothing to do without hosts."
  }
}

run "kv_protected_settings_avoids_state_secret" {
  command = plan
  variables {
    settings = { agent_protected_settings_secret_url = "https://eh-kv-ident-dev-abcde.vault.azure.net/secrets/datadog-agent-protected/0123456789abcdef0123456789abcdef" }
  }
  assert {
    condition     = length(data.azurerm_key_vault_secret.api_key) == 0
    error_message = "No data-source read of the key when the extension pulls it from Key Vault."
  }
}
