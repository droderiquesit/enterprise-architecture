# Datadog Agent for VMs / VM scale sets as Azure VM Applications (Azure Compute Gallery), one application per OS:
#   package (mediaLink)                     = the dsv-fetch static binary for the OS / architecture (release file,
#                                             checked against SHA256SUMS here and on the host)
#   configuration (defaultConfigurationLink) = the rendered, NON-secret setup script (pinned Agent version, site,
#                                             api_key: ENC[dsv ref], log collection, SSI, OTLP, tags, DSV endpoint
#                                             and the client id of the environment's DSV-reader identity)
# A version is immutable: any content change needs a new var.package_version (guarded below). Publishing reads the
# blobs through the gallery's user-assigned identity (plain blob URLs, no SAS anywhere; storage account without
# shared keys or anonymous access). Which VMs / VMSS get the application is decided by modules/host-agent-policy
# (Azure Policy) or, without policy rights, modules/host-agents mode = "direct".
locals {
  rg_name         = element(split("/", var.resource_group_id), 4)
  gallery_id      = "${var.resource_group_id}/providers/Microsoft.Compute/galleries/${var.names.gallery}"
  versions        = distinct(concat([var.package_version], var.retained_versions))
  replica_regions = length(var.replica_regions) > 0 ? var.replica_regions : [{ name = var.location, regional_replicas = 1, storage_account_type = "Standard_ZRS" }]

  os_of = { linux = "linux", linux_arm64 = "linux", windows = "windows" }
  app_defaults = {
    linux       = { name = "datadog-agent-linux", binary = "dsv-fetch-linux-amd64", package_file = "dsv-fetch", supported_os = "Linux" }
    linux_arm64 = { name = "datadog-agent-linux-arm64", binary = "dsv-fetch-linux-arm64", package_file = "dsv-fetch", supported_os = "Linux" }
    windows     = { name = "datadog-agent-windows", binary = "dsv-fetch-windows-amd64.exe", package_file = "dsv-fetch.exe", supported_os = "Windows" }
  }
  apps = { for k, a in var.applications : k => merge(local.app_defaults[k], {
    name   = coalesce(a.name, local.app_defaults[k].name)
    os     = local.os_of[k]
    config = local.os_of[k] == "linux" ? "datadog-agent-setup.sh" : "datadog-agent-setup.ps1"
  }) }

  # ------------------------------------------------------------------ dsv-fetch release files
  sums_raw      = try(file("${var.dsv_fetch_release_dir}/SHA256SUMS"), "")
  sums          = { for m in regexall("(?m)^([0-9a-fA-F]{64})[ \\t]+\\*?([^\\s]+)[ \\t]*$", local.sums_raw) : m[1] => lower(m[0]) }
  binary_path   = { for k, a in local.apps : k => "${var.dsv_fetch_release_dir}/${a.binary}" }
  binary_sha256 = { for k, a in local.apps : k => try(filesha256(local.binary_path[k]), null) }
}

module "fleet" {
  source       = "../fleet-policy"
  for_each     = toset(distinct([for a in local.apps : a.os]))
  policy       = var.fleet_policy
  architecture = "vm"
  os_type      = each.key
  runtime      = "dotnet" # any tracer runtime: selects the host APM method (SSI on Linux)
  env          = var.env
  overrides    = var.log_pipeline == null ? {} : { log_pipeline = var.log_pipeline }
}

# host-level static tags (environment-wide); per-instance values come from the instance's Azure tags on the host
module "tags" {
  source           = "../tagging"
  policy           = var.tag_policy
  identity         = { env = var.env }
  extra_tags       = var.extra_tags
  enforce_required = false
}

locals {
  fleet         = module.fleet[keys(module.fleet)[0]]
  agent         = local.fleet.agent
  agent_version = try(local.agent.version, null)
  op_mode       = local.fleet.log_pipeline == "observability_pipelines"
  libs          = local.fleet.apm.library_versions
  ssi_libraries = join(",", [for lang in sort(keys(local.libs)) : "${lang}:${trimprefix(local.libs[lang], "v")}" if contains(["dotnet", "python", "js", "java"], lang)])
  # host log collection: the caller's host_logs (when set) -> fleet policy logs.hosts (merged section: defaults ->
  # architectures.<arch> -> environments.<env>) -> nothing
  fleet_hosts = try(local.fleet.sections.logs.hosts, {})
  host_logs = {
    linux_files = [for f in coalesce(try(var.host_logs.linux.files, null), try(local.fleet_hosts.linux.files, null), []) : {
      path = f.path, service = try(f.service, null), source = try(f.source, null)
    }]
    windows_files = [for f in coalesce(try(var.host_logs.windows.files, null), try(local.fleet_hosts.windows.files, null), []) : {
      path = f.path, service = try(f.service, null), source = try(f.source, null)
    }]
    event_channels = [for c in coalesce(try(var.host_logs.windows.event_channels, null), try(local.fleet_hosts.windows.event_channels, null), []) : {
      channel = c.channel, source = coalesce(try(c.source, null), "windows.events")
    }]
  }

  # Azure tag key (lower case) -> Datadog key, from the tag policy (azure_tag_keys); env/service/version are read too
  # (Agent `env`, log `service`) but never emitted as host tags
  tag_pairs   = flatten([for az in sort(keys(module.tags.azure_tag_key_map)) : [for dd in module.tags.azure_tag_key_map[az] : { az = az, dd = dd }]])
  static_tags = { for k, v in module.tags.tags : k => v if !contains(["env", "service", "version"], k) && v != "" }

  dsv_config = merge(
    var.dsv.tenant == null ? {} : { DSV_TENANT = var.dsv.tenant },
    var.dsv.tld == null ? {} : { DSV_TLD = var.dsv.tld },
    var.dsv.base_url == null ? {} : { DSV_BASE_URL = var.dsv.base_url },
    { DSV_AUTH = var.dsv.auth, DSV_TIMEOUT_SECONDS = tostring(var.dsv.timeout_seconds), AZURE_CLIENT_ID = var.dsv.identity_client_id },
  )

  installers = { for k, a in local.apps : k => templatefile(
    "${path.module}/scripts/${a.os == "linux" ? "linux-setup.sh.tftpl" : "windows-setup.ps1.tftpl"}",
    {
      application_name     = a.name
      package_version      = var.package_version
      agent_version        = coalesce(local.agent_version, "unset")
      agent_msi_sha256     = lookup(var.agent_msi_sha256, coalesce(local.agent_version, "unset"), "")
      site                 = var.datadog.site
      api_key_ref          = var.datadog.api_key_ref
      env_name             = var.env
      identity_client_id   = var.dsv.identity_client_id
      dsv_config_json      = jsonencode(local.dsv_config)
      dsv_fetch_sha256     = coalesce(local.binary_sha256[k], "missing")
      tag_prefix           = var.metadata_tag_prefix
      tag_pairs            = local.tag_pairs
      static_tags          = local.static_tags
      default_service      = var.default_service
      default_source       = a.os == "linux" ? var.default_source.linux : var.default_source.windows
      logs_enabled         = tostring(local.fleet.log_collector != "none") # also with fluent_bit_direct: no Fluent Bit on VMs in 4.0
      op_logs_url          = local.op_mode ? coalesce(var.op_agent_logs_url, "unset") : ""
      log_files            = a.os == "linux" ? local.host_logs.linux_files : local.host_logs.windows_files
      event_channels       = local.host_logs.event_channels
      apm_ssi              = tostring(a.os == "linux" && module.fleet[a.os].apm.method == "ssi_host")
      ssi_libraries        = local.ssi_libraries
      apm_ignore_resources = local.fleet.agent_apm_ignore_resources
      process_collection   = tostring(try(local.agent.process_collection, false))
      remote_configuration = tostring(try(local.agent.remote_configuration, true))
      remote_updates       = tostring(try(local.agent.remote_updates, false))
    }
  ) }

  manage = { for k, a in local.apps : k => a.os == "linux" ? {
    install = "bash ./${a.config} install"
    update  = "bash ./${a.config} update"
    remove  = "bash ./${a.config} remove"
    } : {
    install = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\\${a.config} -Action install"
    update  = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\\${a.config} -Action update"
    remove  = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\\${a.config} -Action remove"
  } }

  # everything a published version is made of (Azure keeps it immutable)
  content_sha256 = { for k, a in local.apps : k => sha256(jsonencode({
    installer = sha256(local.installers[k]), binary = local.binary_sha256[k], manage = local.manage[k], package_file = a.package_file, config_file = a.config
  })) }
  installer_sha256 = { for k, s in local.installers : k => sha256(s) }

  version_keys = { for p in setproduct(keys(local.apps), local.versions) : "${p[0]}/${p[1]}" => { app = p[0], version = p[1] } }
}

# ---------------------------------------------------------------------------------------------- package storage
resource "azurerm_storage_account" "packages" {
  #checkov:skip=CKV2_AZURE_1:Microsoft-managed keys are sufficient for non-secret installer packages (no CMK).
  #checkov:skip=CKV2_AZURE_33:No private endpoint: the gallery reads through its managed identity as a trusted service; publishers are admitted by ip_rules / subnet_ids.
  #checkov:skip=CKV2_AZURE_21:Blob service logging is a diagnostic setting owned by obs-diagnostics (ADR-0001 §3 rule 4).
  #checkov:skip=CKV_AZURE_33:Queue service is not used.
  #checkov:skip=CKV_AZURE_59:network_rules default_action = Deny (only ip_rules / subnet_ids / trusted Azure services); public_network_access is a caller setting for publishers without VNet access.
  #checkov:skip=CKV_AZURE_206:ZRS is replicated (3 zones); geo-redundancy comes from the gallery replicas (replica_regions), not the package source.
  name                             = var.names.storage_account
  resource_group_name              = local.rg_name
  location                         = var.location
  account_tier                     = "Standard"
  account_kind                     = "StorageV2"
  account_replication_type         = "ZRS"
  min_tls_version                  = "TLS1_2"
  https_traffic_only_enabled       = true
  shared_access_key_enabled        = false # no account keys -> no SAS can be minted from keys
  default_to_oauth_authentication  = true
  allow_nested_items_to_be_public  = false
  public_network_access            = var.network.public_network_access_enabled ? "Enabled" : "Disabled"
  local_user_enabled               = false
  sftp_enabled                     = false
  cross_tenant_replication_enabled = false
  tags                             = var.tags

  network_rules {
    default_action             = "Deny"
    bypass                     = ["AzureServices"]
    ip_rules                   = var.network.ip_rules
    virtual_network_subnet_ids = var.network.subnet_ids
  }

  blob_properties {
    versioning_enabled = true
    delete_retention_policy {
      days = 7
    }
    container_delete_retention_policy {
      days = 7
    }
  }
}

resource "azurerm_storage_container" "packages" {
  #checkov:skip=CKV2_AZURE_21:Blob service logging is a diagnostic setting owned by obs-diagnostics (ADR-0001 §3 rule 4).
  name                  = var.names.container
  storage_account_id    = azurerm_storage_account.packages.id
  container_access_type = "private"
}

resource "azurerm_role_assignment" "publisher_upload" {
  for_each             = toset(var.publisher_principal_ids)
  scope                = azurerm_storage_container.packages.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = each.value
  description          = "Upload Datadog VM Application packages (Entra ID, no shared key)"
}

# ---------------------------------------------------------------------------------------------- gallery
resource "azurerm_user_assigned_identity" "publisher" {
  name                = var.names.publisher_identity
  resource_group_name = local.rg_name
  location            = var.location
  tags                = merge(var.tags, { purpose = "Azure Compute Gallery publisher (reads Datadog VM Application packages)" })
}

# Microsoft Learn (vm-applications-publish-with-managed-identity): the gallery identity needs Storage Blob Data
# Contributor on the package storage; scoped here to the one container.
resource "azurerm_role_assignment" "gallery_reads_packages" {
  scope                = azurerm_storage_container.packages.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.publisher.principal_id
  principal_type       = "ServicePrincipal"
  description          = "Azure Compute Gallery publishes VM Application versions from plain blob URLs (no SAS)"
}

resource "azapi_resource" "gallery" {
  type      = "Microsoft.Compute/galleries@2025-12-03"
  name      = var.names.gallery
  parent_id = var.resource_group_id
  location  = var.location
  tags      = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.publisher.id]
  }

  body = {
    properties = {
      description = "Datadog Agent VM Applications (observability package, Delinea DSV secret backend)"
    }
  }
}

resource "azurerm_gallery_application" "agent" {
  for_each          = local.apps
  name              = each.value.name
  gallery_id        = azapi_resource.gallery.id
  location          = var.location
  supported_os_type = each.value.supported_os
  description       = "Datadog Agent ${each.value.os} (${each.key == "linux_arm64" ? "arm64" : "amd64"}): pinned Agent, dsv-fetch secret backend, Agent log collection"
  tags              = var.tags
}

# ---------------------------------------------------------------------------------------------- blobs (current version)
# Content-addressed names: a new binary / installer is a new blob; the gallery keeps its own replicas, so blobs of
# older versions may be removed (Microsoft Learn: the source blob can be deleted after replication).
resource "azurerm_storage_blob" "package" {
  for_each             = local.apps
  name                 = "${each.value.name}/${var.package_version}/${substr(coalesce(local.binary_sha256[each.key], "0000000000000000"), 0, 16)}/${each.value.package_file}"
  storage_container_id = azurerm_storage_container.packages.id
  type                 = "Block"
  source               = local.binary_path[each.key]
  content_type         = "application/octet-stream"

  lifecycle {
    precondition {
      condition     = local.binary_sha256[each.key] != null
      error_message = "dsv-fetch release file ${local.binary_path[each.key]} not found: stage the dsv-fetch release (binaries + SHA256SUMS) into dsv_fetch_release_dir."
    }
    precondition {
      condition     = lookup(local.sums, each.value.binary, "") == coalesce(local.binary_sha256[each.key], "-")
      error_message = "${each.value.binary} does not match its SHA256SUMS entry (or the entry is missing)."
    }
  }
}

resource "azurerm_storage_blob" "installer" {
  for_each             = local.apps
  name                 = "${each.value.name}/${var.package_version}/${substr(local.installer_sha256[each.key], 0, 16)}/${each.value.config}"
  storage_container_id = azurerm_storage_container.packages.id
  type                 = "Block"
  source_content       = local.installers[each.key]
  content_type         = "text/plain"

  lifecycle {
    precondition {
      condition     = local.agent_version != null && can(regex("^7\\.[0-9]+\\.[0-9]+$", coalesce(local.agent_version, "x")))
      error_message = "The fleet policy must pin agent.version (7.x.y; versions.yaml is the single source) - no fallback."
    }
    precondition {
      condition     = each.value.os != "windows" || lookup(var.agent_msi_sha256, coalesce(local.agent_version, "unset"), "") != ""
      error_message = "agent_msi_sha256 has no SHA256 for the Windows Agent MSI ${coalesce(local.agent_version, "unset")}: add it together with the Agent version bump."
    }
    precondition {
      condition     = !local.op_mode || var.op_agent_logs_url != null
      error_message = "log_pipeline = observability_pipelines needs op_agent_logs_url (transport contract aggregator.agent_logs_url)."
    }
    precondition {
      condition     = alltrue([for m in values(local.manage[each.key]) : length(m) <= 4096])
      error_message = "VM Application install/update/remove commands are limited to 4096 characters."
    }
  }
}

# Records what each version was published with; ignore_changes keeps the first value, so a later plan can tell that
# the content changed under an already published version name.
resource "terraform_data" "published" {
  for_each = { for k, a in local.apps : "${k}/${var.package_version}" => k }
  input    = local.content_sha256[each.value]

  lifecycle {
    ignore_changes = [input]
  }
}

resource "azurerm_gallery_application_version" "agent" {
  for_each               = local.version_keys
  name                   = each.value.version
  gallery_application_id = azurerm_gallery_application.agent[each.value.app].id
  location               = var.location
  # never `latest`: every environment pins its version through host-agent-policy (promotion = version bump)
  exclude_from_latest = true
  package_file        = local.apps[each.value.app].package_file
  config_file         = local.apps[each.value.app].config
  tags = merge(var.tags, {
    "agent-version"  = coalesce(local.agent_version, "unset")
    "content-sha256" = local.content_sha256[each.value.app]
  })

  manage_action {
    install = local.manage[each.value.app].install
    update  = local.manage[each.value.app].update
    remove  = local.manage[each.value.app].remove
  }

  source {
    media_link                 = azurerm_storage_blob.package[each.value.app].url
    default_configuration_link = azurerm_storage_blob.installer[each.value.app].url
  }

  dynamic "target_region" {
    for_each = local.replica_regions
    content {
      name                   = target_region.value.name
      regional_replica_count = target_region.value.regional_replicas
      storage_account_type   = target_region.value.storage_account_type
    }
  }

  depends_on = [azurerm_role_assignment.gallery_reads_packages]

  lifecycle {
    # a published version is frozen (Azure rejects changes to its package, configuration, commands or file names)
    ignore_changes = [source, manage_action, package_file, config_file, tags]
    precondition {
      condition     = each.value.version != var.package_version || terraform_data.published["${each.value.app}/${var.package_version}"].output == local.content_sha256[each.value.app]
      error_message = "The ${each.value.app} installer or dsv-fetch binary changed but package_version ${var.package_version} is already published: bump package_version (published versions are immutable)."
    }
    precondition {
      condition     = contains([for r in local.replica_regions : r.name], var.location)
      error_message = "replica_regions must include the gallery location."
    }
  }
}
