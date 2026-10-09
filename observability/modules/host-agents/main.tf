# Datadog Agent (VM extension, publisher Datadog.Agent) + Fluent Bit on EXISTING VMs and VM scale sets.
# App logs on hosts: Fluent Bit only (Agent DD_LOGS_ENABLED=false). OTLP: Agent receiver on localhost.
# VM   -> azurerm_virtual_machine_extension + azurerm_virtual_machine_run_command (managed run command)
# VMSS -> azurerm_virtual_machine_scale_set_extension (Datadog agent) + CustomScript extension running the
#         same installer on every instance, including instances created later by autoscale.
locals {
  ext_type = { linux = "DatadogLinuxAgent", windows = "DatadogWindowsAgent" }

  agent_settings = jsonencode({
    site         = var.datadog.site
    agentVersion = var.datadog.agent_version
  })
  agent_protected = var.datadog.api_key_key_vault == null ? jsonencode({ api_key = var.api_key }) : null
}

module "flb" {
  source            = "../fluent-bit"
  for_each          = { for k, h in var.hosts : k => h if h.install_fluent_bit }
  role              = each.value.os_type == "linux" ? "linux-host" : "windows-host"
  datadog_site      = var.datadog.site
  static_tags       = each.value.service_tags
  dd_source         = lookup(each.value.service_tags, "source", null)
  dd_service        = lookup(each.value.service_tags, "service", null)
  log_paths         = each.value.log_paths
  systemd_unit      = each.value.systemd_unit
  windows_event_log = each.value.windows_event_log
}

locals {
  scripts = {
    for k, h in var.hosts : k => templatefile(
      "${path.module}/scripts/${h.os_type == "linux" ? "linux-install.sh.tftpl" : "windows-install.ps1.tftpl"}",
      {
        fb_version         = var.fluent_bit_version
        api_key_secret_id  = var.datadog.api_key_secret_id == null ? "" : var.datadog.api_key_secret_id
        identity_client_id = h.identity_client_id == null ? "" : h.identity_client_id
        configure_agent    = tostring(h.install_agent)
        process_collection = tostring(var.datadog.process_collection)
        agent_tags         = join(" ", [for t in sort(keys(h.service_tags)) : "${t}:${h.service_tags[t]}" if t != "source"])
        files              = h.install_fluent_bit ? { for p, c in module.flb[k].files : p => base64gzip(c) } : {}
        env                = h.install_fluent_bit ? module.flb[k].env : {}
      }
    )
  }

  vms   = { for k, h in var.hosts : k => h if h.kind == "vm" }
  vmsss = { for k, h in var.hosts : k => h if h.kind == "vmss" }

  needs_protected_key = { for k, h in var.hosts : k => (h.install_fluent_bit && (var.datadog.api_key_secret_id == null || h.identity_client_id == null)) }
}

# ---------------------------------------------------------------------------------------------- VMs
resource "azurerm_virtual_machine_extension" "datadog" {
  for_each                   = { for k, h in local.vms : k => h if h.install_agent }
  name                       = "DatadogAgent"
  virtual_machine_id         = each.value.resource_id
  publisher                  = "Datadog.Agent"
  type                       = local.ext_type[each.value.os_type]
  type_handler_version       = var.datadog.extension_version
  auto_upgrade_minor_version = true
  settings                   = local.agent_settings
  protected_settings         = local.agent_protected
  tags                       = var.tags

  dynamic "protected_settings_from_key_vault" {
    for_each = var.datadog.api_key_key_vault == null ? [] : [var.datadog.api_key_key_vault]
    content {
      secret_url      = protected_settings_from_key_vault.value.secret_url
      source_vault_id = protected_settings_from_key_vault.value.source_vault_id
    }
  }

  lifecycle {
    precondition {
      condition     = var.datadog.api_key_key_vault != null || var.api_key != null
      error_message = "The Datadog Agent extension needs datadog.api_key_key_vault (preferred) or api_key."
    }
  }
}

resource "azurerm_virtual_machine_run_command" "setup" {
  for_each           = { for k, h in local.vms : k => h if h.install_fluent_bit || h.install_agent }
  name               = "eh-observability-setup"
  location           = each.value.location
  virtual_machine_id = each.value.resource_id
  tags               = var.tags

  source {
    script = local.scripts[each.key]
  }

  dynamic "protected_parameter" {
    for_each = local.needs_protected_key[each.key] ? [1] : []
    content {
      name  = "DD_API_KEY"
      value = var.api_key
    }
  }

  depends_on = [azurerm_virtual_machine_extension.datadog]

  lifecycle {
    precondition {
      condition     = !local.needs_protected_key[each.key] || var.api_key != null
      error_message = "Fluent Bit needs the API key: set datadog.api_key_secret_id + hosts[*].identity_client_id (preferred) or api_key."
    }
  }
}

# ---------------------------------------------------------------------------------------------- VMSS
resource "azurerm_virtual_machine_scale_set_extension" "datadog" {
  for_each                     = { for k, h in local.vmsss : k => h if h.install_agent }
  name                         = "DatadogAgent"
  virtual_machine_scale_set_id = each.value.resource_id
  publisher                    = "Datadog.Agent"
  type                         = local.ext_type[each.value.os_type]
  type_handler_version         = var.datadog.extension_version
  auto_upgrade_minor_version   = true
  settings                     = local.agent_settings
  protected_settings           = local.agent_protected

  dynamic "protected_settings_from_key_vault" {
    for_each = var.datadog.api_key_key_vault == null ? [] : [var.datadog.api_key_key_vault]
    content {
      secret_url      = protected_settings_from_key_vault.value.secret_url
      source_vault_id = protected_settings_from_key_vault.value.source_vault_id
    }
  }
}

locals {
  windows_cse_command = {
    # gzip+base64 payload decompressed by a one-line stub (an -EncodedCommand of the full script would
    # exceed the 32K command-line limit)
    for k, h in local.vmsss : k => join("", [
      "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \"",
      "$b='${base64gzip(local.scripts[k])}';",
      "$i=New-Object IO.MemoryStream(,[Convert]::FromBase64String($b));",
      "$g=New-Object IO.Compression.GZipStream($i,[IO.Compression.CompressionMode]::Decompress);",
      "$r=New-Object IO.StreamReader($g);Invoke-Expression $r.ReadToEnd()\"",
    ])
    if h.os_type == "windows"
  }
}

# A scale set can carry only ONE CustomScript extension; if the app owner already uses one, bake the
# installer into the image or set install_fluent_bit = false and call scripts/ from that extension.
resource "azurerm_virtual_machine_scale_set_extension" "setup" {
  for_each                     = { for k, h in local.vmsss : k => h if h.install_fluent_bit || h.install_agent }
  name                         = "eh-observability-setup"
  virtual_machine_scale_set_id = each.value.resource_id
  publisher                    = each.value.os_type == "linux" ? "Microsoft.Azure.Extensions" : "Microsoft.Compute"
  type                         = each.value.os_type == "linux" ? "CustomScript" : "CustomScriptExtension"
  type_handler_version         = each.value.os_type == "linux" ? "2.1" : "1.10"
  auto_upgrade_minor_version   = true
  provision_after_extensions   = each.value.install_agent ? ["DatadogAgent"] : []
  # re-run on every instance when the installer (configs included) changes
  force_update_tag = sha256(local.scripts[each.key])
  protected_settings = each.value.os_type == "linux" ? jsonencode({
    script = base64gzip(local.scripts[each.key])
    }) : jsonencode({
    commandToExecute = local.windows_cse_command[each.key]
  })

  depends_on = [azurerm_virtual_machine_scale_set_extension.datadog]

  lifecycle {
    precondition {
      condition     = each.value.os_type == "linux" || length(local.windows_cse_command[each.key]) < 32000
      error_message = "Windows CustomScriptExtension command exceeds the Windows command-line limit; trim log paths/config."
    }
    precondition {
      condition     = !local.needs_protected_key[each.key]
      error_message = "VMSS instances must read the API key from Key Vault (datadog.api_key_secret_id + hosts[*].identity_client_id); CustomScript has no protected parameters per instance."
    }
  }
}
