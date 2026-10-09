mock_provider "azurerm" {
  override_during = plan
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
    datadog_site = "datadoghq.com"
    api_key_ref  = "dsv://eh/dev/datadog-api-key#value"
    secrets      = { tenant = "contoso", tld = "com", base_url = "https://contoso.secretsvaultcloud.com/v1" }
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
    vm = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-db/providers/Microsoft.Compute/virtualMachines/eh-vm-sql-dev-sec", name = "eh-vm-sql-dev-sec", identity_client_id = "55555555-5555-5555-5555-555555555555" }
  }
}

run "lab_hosts" {
  command = plan
  assert {
    condition     = jsonencode(output.hosts["vm-worker"]) == jsonencode(["/var/log/hello-worker/*.log"]) && jsonencode(output.hosts["vmss-worker"]) == jsonencode(["/var/log/hello-worker/*.log"]) && jsonencode(output.hosts["vm-inventory"]) == jsonencode(["C:\\ProgramData\\enterprise-hello\\logs\\*.log"])
    error_message = "Log paths: per-workload map (hello-worker -> /var/log/hello-worker/worker.log*), else contract log_dir, else defaults."
  }
  assert {
    condition     = jsonencode(output.hosts["sqlvm"]) == jsonencode([]) && length(module.hosts.setup) == 4
    error_message = "SQL VM: Agent only (setup still configures OTLP/logs-off), no Fluent Bit."
  }
  assert {
    condition     = alltrue([for k, s in module.hosts.installer_scripts : strcontains(s, "dsv://eh/dev/datadog-api-key#value") && !strcontains(s, "vault.azure.net")])
    error_message = "Every installer reads the key from DSV (reference only)."
  }
}

run "no_hosts" {
  command = plan
  variables {
    platform_vm       = null
    platform_vmss     = null
    platform_db_sqlvm = null
  }
  assert {
    condition     = length(module.hosts.setup) == 0
    error_message = "Nothing to do without hosts."
  }
}

run "sqlvm_without_identity_is_skipped" {
  command = plan
  variables {
    platform_db_sqlvm = { vm = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-db/providers/Microsoft.Compute/virtualMachines/eh-vm-sql-dev-sec", name = "eh-vm-sql-dev-sec" } }
  }
  assert {
    condition     = !contains(keys(output.hosts), "sqlvm") && length(module.hosts.setup) == 3
    error_message = "A SQL VM without a DSV-mapped identity is skipped (it could not read the key)."
  }
}
