mock_provider "azurerm" {
  mock_resource "azurerm_storage_account" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-obshosts-dev-sec/providers/Microsoft.Storage/storageAccounts/ehstvmappdevsecab123" }
  }
  mock_resource "azurerm_storage_container" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-obshosts-dev-sec/providers/Microsoft.Storage/storageAccounts/ehstvmappdevsecab123/blobServices/default/containers/vm-applications" }
  }
  mock_resource "azurerm_storage_blob" {
    defaults = { url = "https://ehstvmappdevsecab123.blob.core.windows.net/vm-applications/blob" }
  }
  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-obshosts-dev-sec/providers/Microsoft.ManagedIdentity/userAssignedIdentities/eh-id-obs-gallery-dev-sec"
      principal_id = "44444444-4444-4444-4444-444444444444"
    }
  }
  mock_resource "azurerm_gallery_application" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-obshosts-dev-sec/providers/Microsoft.Compute/galleries/eh_gal_obshosts_dev_sec/applications/datadog-agent" }
  }
}
mock_provider "azapi" {
  mock_resource "azapi_resource" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-obshosts-dev-sec/providers/Microsoft.Compute/galleries/eh_gal_obshosts_dev_sec" }
  }
}

variables {
  resource_group_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-obshosts-dev-sec"
  location          = "swedencentral"
  names = {
    gallery            = "eh_gal_obshosts_dev_sec"
    storage_account    = "ehstvmappdevsecab123"
    publisher_identity = "eh-id-obs-gallery-dev-sec"
  }
  package_version       = "1.0.0"
  dsv_fetch_release_dir = "./tests/fixtures/dsv-fetch"
  env                   = "dev"
  datadog = {
    site        = "datadoghq.eu"
    api_key_ref = "dsv://eh/dev/datadog-api-key#value"
  }
  dsv = {
    tenant             = "contoso"
    identity_client_id = "33333333-3333-3333-3333-333333333333"
  }
  op_agent_logs_url = "http://eh-obs-dev-opw.internal:8282"
  host_logs = {
    linux   = { files = [{ path = "/var/log/hello-worker/*.log", service = "hello-worker" }, { path = "/var/log/enterprise-hello/*.log" }] }
    windows = { files = [{ path = "C:\\ProgramData\\enterprise-hello\\logs\\*.log" }] }
  }
}

run "linux_and_windows_applications" {
  command = plan

  assert {
    condition     = length(azurerm_gallery_application.agent) == 2 && azurerm_gallery_application.agent["linux"].name == "datadog-agent-linux" && azurerm_gallery_application.agent["windows"].supported_os_type == "Windows"
    error_message = "One VM Application per OS: datadog-agent-linux / datadog-agent-windows."
  }
  assert {
    condition = (azurerm_gallery_application_version.agent["linux/1.0.0"].package_file == "dsv-fetch"
      && azurerm_gallery_application_version.agent["linux/1.0.0"].config_file == "datadog-agent-setup.sh"
      && azurerm_gallery_application_version.agent["windows/1.0.0"].package_file == "dsv-fetch.exe"
    && azurerm_gallery_application_version.agent["linux/1.0.0"].exclude_from_latest)
    error_message = "Package = dsv-fetch binary, configuration = setup script; never `latest` (environments pin versions)."
  }
  assert {
    condition = (azurerm_gallery_application_version.agent["linux/1.0.0"].manage_action[0].install == "bash ./datadog-agent-setup.sh install"
    && strcontains(azurerm_gallery_application_version.agent["windows/1.0.0"].manage_action[0].remove, "-File .\\datadog-agent-setup.ps1 -Action remove"))
    error_message = "Install / update / remove commands run the setup script from the download directory."
  }
  assert {
    condition = (strcontains(output.installers["linux"], "api_key: ENC[$API_KEY_REF]")
      && strcontains(output.installers["linux"], "API_KEY_REF='dsv://eh/dev/datadog-api-key#value'")
      && strcontains(output.installers["linux"], "secret_backend_command: $DSV_BIN")
      && strcontains(output.installers["linux"], "install --dest \"$DSV_BIN\" --owner dd-agent")
    && strcontains(output.installers["windows"], "install --dest $DsvBin --owner ddagentuser"))
    error_message = "Both OSes: api_key is an ENC[] DSV reference resolved by the dsv-fetch binary (Agent secret backend)."
  }
  assert {
    condition = (strcontains(output.installers["linux"], "\"AZURE_CLIENT_ID\":\"33333333-3333-3333-3333-333333333333\"")
      && strcontains(output.installers["linux"], "\"DSV_TENANT\":\"contoso\"")
    && strcontains(output.installers["windows"], "\"AZURE_CLIENT_ID\":\"33333333-3333-3333-3333-333333333333\""))
    error_message = "Non-secret DSV settings + the DSV-reader identity client id are rendered for dsv-fetch."
  }
  assert {
    condition = (strcontains(output.installers["linux"], "DSV_SHA256='b9c69a5c3a4df62259e99bedbed9d5b9a62bfc68a45662dfefd8fdaa406afc6e'")
    && strcontains(output.installers["windows"], "$DsvSha256 = '3680aa6090d68e7cd6b63854bd34e692a7ec78d5196ef7770a75b94dda1bec1c'"))
    error_message = "The host verifies the dsv-fetch binary against the release checksum."
  }
  assert {
    condition     = strcontains(output.installers["linux"], "AGENT_VERSION='7.84.2'") && strcontains(output.installers["windows"], "$AgentMsiSha256 = '9ebecc6f16fad77df6dd14cf55d7edf84587cdf43f259442301bd6f2671b0b86'") && output.agent_version == "7.84.2"
    error_message = "Agent version from the fleet policy pin; Windows MSI hash pinned."
  }
  assert {
    condition     = strcontains(output.installers["linux"], "SSI='true'") && strcontains(output.installers["linux"], "SSI_LIBRARIES='dotnet:3,java:1,js:5,python:4'") && !strcontains(output.installers["windows"], "APM_INSTRUMENTATION")
    error_message = "Single Step Instrumentation on Linux only."
  }
  assert {
    condition     = strcontains(output.installers["linux"], "url: \"http://eh-obs-dev-opw.internal:8282\"") && strcontains(output.installers["windows"], "url: \"http://eh-obs-dev-opw.internal:8282\"") && strcontains(output.installers["linux"], "logs_enabled: true")
    error_message = "Agent logs -> Observability Pipelines Worker on both OSes."
  }
  assert {
    condition = (strcontains(output.installers["linux"], "'/var/log/hello-worker/*.log' \"hello-worker\"")
      && strcontains(output.installers["linux"], "'/var/log/enterprise-hello/*.log' \"$HOST_SERVICE\"")
      && strcontains(output.installers["windows"], "channel_path: 'System'")
    && strcontains(output.installers["windows"], "path: 'C:\\ProgramData\\enterprise-hello\\logs\\*.log'"))
    error_message = "Agent log collection: files on Linux and Windows, Windows Event Log channels (no Fluent Bit)."
  }
  assert {
    condition     = strcontains(output.installers["linux"], "endpoint: localhost:4317") && strcontains(output.installers["linux"], "remote_updates: false") && strcontains(output.installers["linux"], "enabled: true\nremote_updates")
    error_message = "OTLP on localhost; Remote Configuration on; remote updates off by default."
  }
  assert {
    condition     = strcontains(output.installers["linux"], "\nservice|service\n") && strcontains(output.installers["linux"], "\nteam|team\n") && strcontains(output.installers["windows"], "@('environment', 'env')")
    error_message = "Instance Azure tags are mapped to Datadog host tags through the tag policy azure_tag_keys."
  }
  assert {
    condition     = alltrue([for s in values(output.installers) : !strcontains(s, "vault.azure.net") && !strcontains(lower(s), "sig=") && !strcontains(s, "DD_API_KEY=")])
    error_message = "No Key Vault, no SAS, no API key anywhere in the package."
  }
  assert {
    condition     = azurerm_storage_account.packages.shared_access_key_enabled == false && azurerm_storage_account.packages.allow_nested_items_to_be_public == false && azurerm_storage_container.packages.container_access_type == "private"
    error_message = "Private package storage without shared keys (gallery publishes with its managed identity, plain blob URLs)."
  }
  assert {
    condition     = azapi_resource.gallery.identity[0].type == "UserAssigned" && azurerm_role_assignment.gallery_reads_packages.role_definition_name == "Storage Blob Data Contributor"
    error_message = "Gallery user-assigned identity reads the packages (Microsoft Learn: publish with managed identity)."
  }
  assert {
    condition     = endswith(azurerm_storage_blob.package["linux"].name, "/dsv-fetch") && azurerm_storage_blob.package["windows"].source == "./tests/fixtures/dsv-fetch/dsv-fetch-windows-amd64.exe"
    error_message = "Package blobs are the dsv-fetch release binaries."
  }
}

run "fluent_bit_direct_skips_worker" {
  command = plan
  variables {
    log_pipeline      = "fluent_bit_direct"
    op_agent_logs_url = null
  }
  assert {
    condition     = !strcontains(output.installers["linux"], "observability_pipelines_worker") && strcontains(output.installers["linux"], "logs_enabled: true")
    error_message = "fluent_bit_direct: the Agent still collects (no Fluent Bit on hosts) and ships to the Datadog intake."
  }
}

run "host_logs_default_from_fleet_policy" {
  command = plan
  variables {
    host_logs = {}
  }
  assert {
    condition     = strcontains(output.installers["linux"], "/var/log/enterprise-hello/*.log") && !strcontains(output.installers["linux"], "/var/log/hello-worker/*.log") && strcontains(output.installers["windows"], "System") && strcontains(output.installers["windows"], "Application") && strcontains(output.installers["windows"], "enterprise-hello")
    error_message = "No host_logs input: the fleet policy logs.hosts defaults (Linux/Windows files, Windows System + Application channels) are rendered."
  }
}

run "op_mode_needs_worker_url" {
  command = plan
  variables {
    op_agent_logs_url = null
  }
  expect_failures = [azurerm_storage_blob.installer["linux"], azurerm_storage_blob.installer["windows"]]
}

run "tampered_binary_is_rejected" {
  command = plan
  variables {
    dsv_fetch_release_dir = "./tests/fixtures/dsv-fetch-bad"
  }
  expect_failures = [azurerm_storage_blob.package["linux"]]
}

run "missing_release_is_rejected" {
  command = plan
  variables {
    dsv_fetch_release_dir = "./tests/fixtures/does-not-exist"
  }
  expect_failures = [azurerm_storage_blob.package["linux"], azurerm_storage_blob.package["windows"]]
}

run "reject_literal_api_key" {
  command = plan
  variables {
    datadog = { site = "datadoghq.com", api_key_ref = "0123456789abcdef0123456789abcdef" }
  }
  expect_failures = [var.datadog]
}

run "reject_bad_version" {
  command = plan
  variables {
    package_version = "1.0"
  }
  expect_failures = [var.package_version]
}

run "arm64_and_retained_versions" {
  command = plan
  variables {
    applications      = { linux = {}, linux_arm64 = {}, windows = {} }
    retained_versions = ["0.9.0"]
  }
  assert {
    condition     = length(azurerm_gallery_application_version.agent) == 6 && jsonencode(output.versions["linux_arm64"]) == jsonencode(["0.9.0", "1.0.0"])
    error_message = "Current + retained versions per application; arm64 Linux application."
  }
  assert {
    condition     = strcontains(output.installers["linux_arm64"], "DSV_SHA256='93fad5b6fc2aa9d2e090a9db102a8e4299ee9961d26d825896cad310fa74d633'")
    error_message = "arm64 application carries the arm64 dsv-fetch binary."
  }
}

# Published versions are immutable: publish 1.0.0, then change the content without a version bump -> plan fails.
run "publish_1_0_0" {
  command = apply
}

run "content_change_without_bump_fails" {
  command = plan
  variables {
    default_service = "changed"
  }
  expect_failures = [azurerm_gallery_application_version.agent["linux/1.0.0"], azurerm_gallery_application_version.agent["windows/1.0.0"]]
}

run "content_change_with_bump_passes" {
  command = plan
  variables {
    default_service   = "changed"
    package_version   = "1.1.0"
    retained_versions = ["1.0.0"]
  }
  assert {
    condition     = output.applications["linux"].version == "1.1.0" && length(azurerm_gallery_application_version.agent) == 4
    error_message = "New version published; 1.0.0 retained (frozen) for rollback."
  }
}
