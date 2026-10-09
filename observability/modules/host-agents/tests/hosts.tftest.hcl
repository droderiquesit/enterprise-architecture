mock_provider "azurerm" {
  override_during = plan
}

variables {
  datadog = {
    site              = "datadoghq.eu"
    api_key_secret_id = "https://kv-obs.vault.azure.net/secrets/datadog-api-key"
    api_key_key_vault = {
      secret_url      = "https://kv-obs.vault.azure.net/secrets/datadog-agent-protected-settings/0123456789abcdef0123456789abcdef"
      source_vault_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv-obs"
    }
  }
  hosts = {
    worker = {
      resource_id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm-worker"
      os_type            = "linux"
      location           = "swedencentral"
      service_tags       = { env = "dev", service = "hello-worker", version = "1.0.0", source = "python" }
      log_paths          = ["/var/log/enterprise-hello/*.log"]
      identity_client_id = "22222222-2222-2222-2222-222222222222"
    }
    inventory_win = {
      resource_id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm-inv"
      os_type            = "windows"
      location           = "swedencentral"
      service_tags       = { env = "dev", service = "hello-inventory-api", version = "1.0.0", source = "csharp" }
      log_paths          = ["C:\\ProgramData\\enterprise-hello\\logs\\*.log"]
      identity_client_id = "22222222-2222-2222-2222-222222222222"
      windows_event_log  = true
    }
    worker_vmss = {
      resource_id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachineScaleSets/vmss-worker"
      os_type            = "linux"
      kind               = "vmss"
      location           = "swedencentral"
      service_tags       = { env = "dev", service = "hello-worker", version = "1.0.0" }
      log_paths          = ["/var/log/enterprise-hello/*.log"]
      identity_client_id = "22222222-2222-2222-2222-222222222222"
    }
  }
}

run "vm_and_vmss" {
  command = plan

  assert {
    condition     = azurerm_virtual_machine_extension.datadog["worker"].type == "DatadogLinuxAgent" && azurerm_virtual_machine_extension.datadog["inventory_win"].type == "DatadogWindowsAgent" && azurerm_virtual_machine_extension.datadog["worker"].publisher == "Datadog.Agent"
    error_message = "Datadog.Agent extension types per OS."
  }
  assert {
    condition     = jsondecode(azurerm_virtual_machine_extension.datadog["worker"].settings).agentVersion == "7.84.2" && jsondecode(azurerm_virtual_machine_extension.datadog["worker"].settings).site == "datadoghq.eu"
    error_message = "Pinned agent version and site in public settings."
  }
  assert {
    condition     = azurerm_virtual_machine_extension.datadog["worker"].protected_settings == null && length(azurerm_virtual_machine_extension.datadog["worker"].protected_settings_from_key_vault) == 1
    error_message = "API key comes from Key Vault, not Terraform."
  }
  assert {
    condition     = !strcontains(azurerm_virtual_machine_extension.datadog["worker"].settings, "api_key")
    error_message = "API key must never be in public settings."
  }
  assert {
    condition     = strcontains(azurerm_virtual_machine_run_command.setup["worker"].source[0].script, "DD_LOGS_ENABLED=false") && strcontains(azurerm_virtual_machine_run_command.setup["worker"].source[0].script, "localhost:4317")
    error_message = "Agent configured with OTLP on localhost and log collection disabled."
  }
  assert {
    condition     = strcontains(azurerm_virtual_machine_run_command.setup["worker"].source[0].script, "FB_VERSION='5.1.3'") && length(azurerm_virtual_machine_run_command.setup["worker"].protected_parameter) == 0
    error_message = "Pinned Fluent Bit; no protected parameter when Key Vault identity is used."
  }
  assert {
    condition     = strcontains(azurerm_virtual_machine_run_command.setup["inventory_win"].source[0].script, "fluent-bit-eh") && strcontains(azurerm_virtual_machine_run_command.setup["inventory_win"].source[0].script, "msiexec")
    error_message = "Windows installer."
  }
  assert {
    condition     = azurerm_virtual_machine_scale_set_extension.setup["worker_vmss"].type == "CustomScript" && contains(azurerm_virtual_machine_scale_set_extension.setup["worker_vmss"].provision_after_extensions, "DatadogAgent")
    error_message = "VMSS: CustomScript after the Datadog extension."
  }
  assert {
    condition     = azurerm_virtual_machine_scale_set_extension.datadog["worker_vmss"].type == "DatadogLinuxAgent"
    error_message = "VMSS Datadog extension."
  }
  assert {
    condition     = length(azurerm_virtual_machine_run_command.setup) == 2 && length(azurerm_virtual_machine_scale_set_extension.setup) == 1
    error_message = "Run command for VMs only; CustomScript for VMSS."
  }
}

run "protected_parameter_fallback" {
  command = plan
  variables {
    api_key = "mock-not-real"
    datadog = { site = "datadoghq.com" }
    hosts = {
      worker = {
        resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm-worker"
        os_type     = "linux"
        location    = "swedencentral"
        log_paths   = ["/var/log/app/*.log"]
      }
    }
  }
  assert {
    condition     = length(azurerm_virtual_machine_run_command.setup["worker"].protected_parameter) == 1 && azurerm_virtual_machine_extension.datadog["worker"].protected_settings != null
    error_message = "Without Key Vault identity the key is passed as protected values."
  }
}

run "reject_vmss_without_key_vault_identity" {
  command = plan
  variables {
    api_key = "mock-not-real"
    datadog = { site = "datadoghq.com" }
    hosts = {
      w = {
        resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachineScaleSets/vmss"
        os_type     = "linux"
        kind        = "vmss"
        location    = "swedencentral"
        log_paths   = ["/var/log/app/*.log"]
      }
    }
  }
  expect_failures = [azurerm_virtual_machine_scale_set_extension.setup["w"]]
}

run "reject_kind_mismatch" {
  command = plan
  variables {
    hosts = {
      w = {
        resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachineScaleSets/vmss"
        os_type     = "linux"
        kind        = "vm"
        location    = "swedencentral"
        log_paths   = ["/var/log/app/*.log"]
      }
    }
  }
  expect_failures = [var.hosts]
}

run "reject_latest_agent" {
  command = plan
  variables {
    datadog = { site = "datadoghq.com", agent_version = "latest" }
  }
  expect_failures = [var.datadog]
}
