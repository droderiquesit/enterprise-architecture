mock_provider "azurerm" {
  mock_resource "azurerm_resource_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-obshosts-dev-sec" }
  }
  mock_resource "azurerm_storage_container" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-obshosts-dev-sec/providers/Microsoft.Storage/storageAccounts/ehst/blobServices/default/containers/vm-applications" }
  }
}
mock_provider "azapi" {}

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
  settings = {
    dsv_fetch_release_dir = "../../modules/host-agent-package/tests/fixtures/dsv-fetch"
  }
  obs_telemetry_transport = {
    datadog_site = "datadoghq.com"
    api_key_ref  = "dsv://eh/dev/datadog-api-key#value"
    secrets      = { tenant = "contoso", tld = "com", base_url = "https://contoso.secretsvaultcloud.com/v1" }
    aggregator   = { kind = "observability_pipelines", fqdn = "eh-obs-dev-opw.internal.example.io", agent_logs_url = "http://eh-obs-dev-opw.internal.example.io:8282" }
    env          = { fleet = { EH_LOG_PIPELINE = "observability_pipelines", EH_APM_MODE = "datadog", EH_PROFILING_ENABLED = "true" } }
  }
  foundation_identity = {
    identities = {
      "obs-host-agent" = {
        id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-identity-dev-sec/providers/Microsoft.ManagedIdentity/userAssignedIdentities/eh-id-obs-host-agent-dev-sec"
        client_id = "66666666-6666-6666-6666-666666666666"
      }
    }
  }
  # present in the environment but not needed in policy mode
  platform_vm = {
    vms = {
      worker = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-vm/providers/Microsoft.Compute/virtualMachines/eh-vm-worker-dev-sec", os_type = "Linux" }
    }
  }
}

run "policy_mode_no_per_host_resources" {
  command = plan

  assert {
    condition     = module.hosts.mode == "policy" && length(module.hosts.assignments) == 0 && output.enrollment_tag.name == "datadog:enabled" && output.enrollment_tag.value == "true"
    error_message = "Default: Azure Policy on datadog:enabled; no per-host Terraform even with platform-vm present."
  }
  assert {
    condition     = output.applications["linux"].name == "datadog-agent-linux" && output.applications["windows"].version == "1.0.0" && output.agent_version == "7.84.2"
    error_message = "VM Applications pinned per environment."
  }
  assert {
    condition     = strcontains(module.hosts.installers["linux"], "66666666-6666-6666-6666-666666666666") && strcontains(module.hosts.installers["linux"], "url: \"http://eh-obs-dev-opw.internal.example.io:8282\"") && strcontains(module.hosts.installers["linux"], "SSI='true'")
    error_message = "Hosts read DSV with the obs-host-agent identity; Agent logs -> OP Worker; SSI from the transport fleet switches."
  }
  assert {
    condition     = strcontains(module.hosts.installers["windows"], "channel_path: 'System'")
    error_message = "Windows: Event Log channels collected by the Agent."
  }
  assert {
    condition     = alltrue([for s in values(module.hosts.installers) : strcontains(s, "dsv://eh/dev/datadog-api-key#value") && !strcontains(s, "vault.azure.net")])
    error_message = "Every installer carries the DSV reference only."
  }
  assert {
    condition     = jsonencode(output.host_log_paths.linux) == jsonencode(["/var/log/hello-worker/*.log", "/var/log/enterprise-hello/*.log"])
    error_message = "Lab default host log files (hello-worker writes /var/log/hello-worker/worker.log)."
  }
  assert {
    condition     = module.hosts.policy != null && length(module.hosts.policy.remediations) == 4
    error_message = "Existing lab VMs / VMSS are remediated (one task per OS x kind)."
  }
}

run "management_group_scope" {
  command = plan
  variables {
    settings = {
      dsv_fetch_release_dir = "../../modules/host-agent-package/tests/fixtures/dsv-fetch"
      scope                 = { type = "management_group", id = "/providers/Microsoft.Management/managementGroups/eh-lab" }
    }
  }
  assert {
    condition     = length(module.hosts.policy.remediations) == 4
    error_message = "Management-group scope supported from settings."
  }
}

run "direct_mode" {
  command = plan
  variables {
    settings = {
      mode                  = "direct"
      dsv_fetch_release_dir = "../../modules/host-agent-package/tests/fixtures/dsv-fetch"
    }
    platform_vmss = {
      scale_sets = {
        worker = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-vm/providers/Microsoft.Compute/virtualMachineScaleSets/eh-vmss-worker-dev-sec", os_type = "Linux" }
      }
    }
    platform_db_sqlvm = { vm = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-db/providers/Microsoft.Compute/virtualMachines/eh-vm-sql-dev-sec" } }
  }
  assert {
    condition     = length(module.hosts.assignments) == 2 && keys(output.vmss_gallery_applications) == ["vmss-worker"] && output.policy == null
    error_message = "direct: VM + SQL VM assignments, VMSS block for platform-vmss, no policy."
  }
}

run "missing_release_fails" {
  command = plan
  variables {
    settings = {}
  }
  expect_failures = [azurerm_resource_group.hosts]
}
