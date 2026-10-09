mock_provider "azurerm" {
  override_during = plan
}

variables {
  datadog = {
    site        = "datadoghq.eu"
    api_key_ref = "dsv://eh/dev/datadog-api-key#value"
  }
  secrets = {
    tenant = "contoso"
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
    condition     = strcontains(azurerm_virtual_machine_run_command.setup["worker"].source[0].script, "DD_LOGS_ENABLED=false") && strcontains(azurerm_virtual_machine_run_command.setup["worker"].source[0].script, "localhost:4317")
    error_message = "Agent configured with OTLP on localhost and log collection disabled."
  }
  assert {
    condition     = strcontains(azurerm_virtual_machine_run_command.setup["worker"].source[0].script, "FB_VERSION='5.1.3'") && strcontains(azurerm_virtual_machine_run_command.setup["worker"].source[0].script, "AGENT_VERSION='7.84.2'") && length(azurerm_virtual_machine_run_command.setup["worker"].protected_parameter) == 0
    error_message = "Pinned Fluent Bit + Agent; no protected parameters."
  }
  assert {
    condition = (strcontains(azurerm_virtual_machine_run_command.setup["worker"].source[0].script, "api_key: ENC[$API_KEY_REF]")
      && strcontains(azurerm_virtual_machine_run_command.setup["worker"].source[0].script, "API_KEY_REF='dsv://eh/dev/datadog-api-key#value'")
      && strcontains(azurerm_virtual_machine_run_command.setup["worker"].source[0].script, "secret_backend_command: $DSV_DIR/agent/dsv-fetch")
    && strcontains(azurerm_virtual_machine_run_command.setup["worker"].source[0].script, "--owner dd-agent"))
    error_message = "Linux Agent: api_key is an ENC[] DSV reference resolved by dsv-fetch agent-backend owned by dd-agent."
  }
  assert {
    condition     = strcontains(azurerm_virtual_machine_run_command.setup["worker"].source[0].script, "ExecStartPre=$DSV_DIR/dsv-fetch init --config $DSV_CONF --out /run/fluent-bit-eh --format env-yaml") && strcontains(azurerm_virtual_machine_run_command.setup["worker"].source[0].script, "RuntimeDirectory=fluent-bit-eh")
    error_message = "Fluent Bit: dsv-fetch writes the env-yaml into the tmpfs RuntimeDirectory at service start."
  }
  assert {
    condition     = strcontains(azurerm_virtual_machine_run_command.setup["worker"].source[0].script, "\"DSV_TENANT\":\"contoso\"") && strcontains(azurerm_virtual_machine_run_command.setup["worker"].source[0].script, "IDENTITY_CLIENT_ID='22222222-2222-2222-2222-222222222222'")
    error_message = "Non-secret DSV settings + host identity rendered for the on-host reader."
  }
  assert {
    condition     = !strcontains(azurerm_virtual_machine_run_command.setup["worker"].source[0].script, "vault.azure.net") && !strcontains(azurerm_virtual_machine_run_command.setup["inventory_win"].source[0].script, "vault.azure.net")
    error_message = "No Key Vault anywhere."
  }
  assert {
    condition     = strcontains(azurerm_virtual_machine_run_command.setup["inventory_win"].source[0].script, "fluent-bit-eh") && strcontains(azurerm_virtual_machine_run_command.setup["inventory_win"].source[0].script, "msiexec") && strcontains(azurerm_virtual_machine_run_command.setup["inventory_win"].source[0].script, "grant_type = 'azure'") && strcontains(azurerm_virtual_machine_run_command.setup["inventory_win"].source[0].script, "334685284bfd830a61d04161406473bf2174dd1ac14df9f459e26819ab874944")
    error_message = "Windows installer reads DSV with the managed identity and verifies pinned MSI hashes."
  }
  assert {
    condition     = azurerm_virtual_machine_scale_set_extension.setup["worker_vmss"].type == "CustomScript" && length(coalesce(azurerm_virtual_machine_scale_set_extension.setup["worker_vmss"].provision_after_extensions, [])) == 0
    error_message = "VMSS: CustomScript installs Agent + Fluent Bit (no Datadog VM extension)."
  }
  assert {
    condition     = length(azurerm_virtual_machine_run_command.setup) == 2 && length(azurerm_virtual_machine_scale_set_extension.setup) == 1
    error_message = "Run command for VMs only; CustomScript for VMSS."
  }
  assert {
    condition     = output.scripts_sha256["worker"] == sha256(output.installer_scripts["worker"])
    error_message = "Script hash output."
  }
}

run "setup_revision_changes_script" {
  command = plan
  variables {
    setup_revision = 2
  }
  assert {
    condition     = strcontains(output.installer_scripts["worker"], "# setup revision: 2")
    error_message = "Bumping setup_revision re-renders the installer (re-run)."
  }
}

run "reject_host_without_identity" {
  command = plan
  variables {
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

run "reject_literal_api_key" {
  command = plan
  variables {
    datadog = { site = "datadoghq.com", api_key_ref = "0123456789abcdef0123456789abcdef" }
  }
  expect_failures = [var.datadog]
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
    datadog = { site = "datadoghq.com", agent_version = "latest", api_key_ref = "dsv://eh/dev/datadog-api-key" }
  }
  expect_failures = [var.datadog]
}
