mock_provider "azurerm" {
  mock_resource "azurerm_storage_container" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/ehstvmapp/blobServices/default/containers/vm-applications" }
  }
  mock_resource "azurerm_gallery_application" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/galleries/g/applications/datadog-agent" }
  }
}
mock_provider "azapi" {
  mock_resource "azapi_resource" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/galleries/g" }
  }
}

variables {
  env = "dev"
  package = {
    resource_group_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg"
    location              = "swedencentral"
    names                 = { gallery = "eh_gal_obshosts_dev_sec", storage_account = "ehstvmappdev", publisher_identity = "eh-id-obs-gallery-dev-sec" }
    version               = "1.0.0"
    dsv_fetch_release_dir = "../host-agent-package/tests/fixtures/dsv-fetch"
  }
  datadog           = { site = "datadoghq.eu", api_key_ref = "dsv://eh/dev/datadog-api-key#value" }
  dsv               = { tenant = "contoso" }
  agent_identity    = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/eh-id-obs-host-agent-dev-sec", client_id = "33333333-3333-3333-3333-333333333333" }
  op_agent_logs_url = "http://eh-obs-dev-opw.internal:8282"
  policy = {
    name_prefix                  = "eh-dd-hosts-dev"
    scope                        = { type = "subscription", id = "/subscriptions/00000000-0000-0000-0000-000000000000" }
    identity_resource_group_name = "rg"
  }
}

run "policy_mode_default" {
  command = plan

  assert {
    condition     = length(module.policy) == 1 && length(azurerm_virtual_machine_gallery_application_assignment.direct) == 0 && output.enrollment_tag.name == "datadog:enabled"
    error_message = "Default: Azure Policy enrolment, no per-host resources."
  }
  assert {
    condition     = output.applications["linux"].version == "1.0.0" && output.agent_version == "7.84.2" && strcontains(output.installers["windows"], "33333333-3333-3333-3333-333333333333")
    error_message = "Package pinned; the DSV-reader identity client id reaches dsv-fetch on the hosts."
  }
  assert {
    condition     = length(output.vmss_gallery_applications) == 0 && output.policy != null
    error_message = "Policy mode publishes no per-VMSS blocks."
  }
}

run "direct_mode_escape_hatch" {
  command = plan
  variables {
    mode   = "direct"
    policy = null
    hosts = {
      worker = { resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm-worker", os_type = "linux" }
      inv    = { resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm-inv", os_type = "windows" }
      ss     = { resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachineScaleSets/vmss-worker", os_type = "linux", kind = "vmss" }
    }
  }
  assert {
    condition     = length(module.policy) == 0 && length(azurerm_virtual_machine_gallery_application_assignment.direct) == 2 && output.policy == null
    error_message = "direct: one gallery application assignment per VM, no policy."
  }
  assert {
    condition     = keys(output.vmss_gallery_applications) == ["ss"] && output.vmss_gallery_applications["ss"].order == 10
    error_message = "direct: VMSS get the gallery_application block for their platform root."
  }
}

run "direct_arm64_needs_arm64_application" {
  command = plan
  variables {
    mode = "direct"
    hosts = {
      a = { resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm-a", os_type = "linux", arch = "arm64" }
    }
  }
  expect_failures = [azurerm_virtual_machine_gallery_application_assignment.direct["a"]]
}

run "reject_kind_mismatch" {
  command = plan
  variables {
    mode = "direct"
    hosts = {
      w = { resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachineScaleSets/vmss", os_type = "linux", kind = "vm" }
    }
  }
  expect_failures = [var.hosts]
}

run "reject_literal_api_key" {
  command = plan
  variables {
    datadog = { site = "datadoghq.com", api_key_ref = "0123456789abcdef0123456789abcdef" }
  }
  expect_failures = [var.datadog]
}
