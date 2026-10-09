# Datadog Agent + Fluent Bit on EXISTING VMs and VM scale sets, with every secret read from Delinea DSV ON THE HOST
# by the host's user-assigned managed identity (ADR-0001 §14). No API key in Terraform variables, state, VM extension
# protected settings or run-command parameters:
#   Linux  : Agent installed by the managed run command / CustomScript (official install script, DD_INSTALL_ONLY,
#            pinned version) with api_key: ENC[dsv://...] and secret_backend_command = dsv-fetch agent-backend
#            (owned by dd-agent, 0500); Fluent Bit reads the key from a tmpfs env-yaml file written by dsv-fetch in
#            the unit's ExecStartPre.
#   Windows: pinned MSIs; the installer reads the key from DSV (PowerShell, IMDS) and writes it into datadog.yaml /
#            the Fluent Bit env-yaml include (ACL-restricted files). The Agent cannot run a script as secret backend
#            on Windows (Win32 executable required), so the key refreshes when the installer re-runs.
# App logs on hosts: Fluent Bit only (Agent DD_LOGS_ENABLED=false). OTLP: Agent receiver on localhost.
# VM   -> azurerm_virtual_machine_run_command (managed run command)
# VMSS -> CustomScript extension running the same installer on every instance, including later autoscaled ones.
locals {
  dsv_fetch_source = coalesce(var.dsv_fetch_source, "${path.module}/../../images/dsv-fetch/dsv_fetch.py")
  dsv_fetch_gz     = base64gzip(file(local.dsv_fetch_source))
  dsv_base_url     = coalesce(var.secrets.base_url, "https://${coalesce(var.secrets.tenant, "unset")}.secretsvaultcloud.${coalesce(var.secrets.tld, "com")}/v1")
  dsv_config = merge(
    var.secrets.tenant == null ? {} : { DSV_TENANT = var.secrets.tenant },
    var.secrets.tld == null ? {} : { DSV_TLD = var.secrets.tld },
    { DSV_BASE_URL = local.dsv_base_url, DSV_AUTH = var.secrets.auth, DSV_TIMEOUT_SECONDS = "10" },
  )
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
        fb_version            = var.fluent_bit_version
        agent_version         = var.datadog.agent_version
        site                  = var.datadog.site
        api_key_ref           = var.datadog.api_key_ref
        identity_client_id    = h.identity_client_id == null ? "" : h.identity_client_id
        dsv_config_json       = jsonencode(local.dsv_config)
        dsv_fetch_gz          = h.os_type == "linux" ? local.dsv_fetch_gz : ""
        install_agent         = tostring(h.install_agent)
        configure_agent       = tostring(h.install_agent)
        install_fluent_bit    = tostring(h.install_fluent_bit)
        process_collection    = tostring(var.datadog.process_collection)
        agent_tags            = join(" ", [for t in sort(keys(h.service_tags)) : "${t}:${h.service_tags[t]}" if t != "source"])
        files                 = h.install_fluent_bit ? { for p, c in module.flb[k].files : p => base64gzip(c) } : {}
        env                   = h.install_fluent_bit ? module.flb[k].env : {}
        secrets_file          = h.install_fluent_bit ? module.flb[k].secrets_env_file : ""
        agent_msi_sha256      = var.windows_msi_sha256.agent
        fluent_bit_msi_sha256 = var.windows_msi_sha256.fluent_bit
        setup_revision        = var.setup_revision
      }
    )
  }

  vms   = { for k, h in var.hosts : k => h if h.kind == "vm" }
  vmsss = { for k, h in var.hosts : k => h if h.kind == "vmss" }
}

# ---------------------------------------------------------------------------------------------- VMs
resource "azurerm_virtual_machine_run_command" "setup" {
  for_each           = { for k, h in local.vms : k => h if h.install_fluent_bit || h.install_agent }
  name               = "observability-setup"
  location           = each.value.location
  virtual_machine_id = each.value.resource_id
  tags               = var.tags

  source {
    script = local.scripts[each.key]
  }

  lifecycle {
    precondition {
      condition     = each.value.identity_client_id != null
      error_message = "hosts[*].identity_client_id is required: the installer reads the Datadog API key from DSV with the host's user-assigned managed identity."
    }
  }
}

# ---------------------------------------------------------------------------------------------- VMSS
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
# installer into the image or call the rendered installer (installer_scripts output) from theirs.
resource "azurerm_virtual_machine_scale_set_extension" "setup" {
  for_each                     = { for k, h in local.vmsss : k => h if h.install_fluent_bit || h.install_agent }
  name                         = "observability-setup"
  virtual_machine_scale_set_id = each.value.resource_id
  publisher                    = each.value.os_type == "linux" ? "Microsoft.Azure.Extensions" : "Microsoft.Compute"
  type                         = each.value.os_type == "linux" ? "CustomScript" : "CustomScriptExtension"
  type_handler_version         = each.value.os_type == "linux" ? "2.1" : "1.10"
  auto_upgrade_minor_version   = true
  # re-run on every instance when the installer (configs included) changes
  force_update_tag = sha256(local.scripts[each.key])
  # protected only to keep the (non-secret) script out of the instance view; it contains no secret
  protected_settings = each.value.os_type == "linux" ? jsonencode({
    script = base64gzip(local.scripts[each.key])
    }) : jsonencode({
    commandToExecute = local.windows_cse_command[each.key]
  })

  lifecycle {
    precondition {
      condition     = each.value.os_type == "linux" || length(local.windows_cse_command[each.key]) < 32000
      error_message = "Windows CustomScriptExtension command exceeds the Windows command-line limit; trim log paths/config."
    }
    precondition {
      condition     = each.value.identity_client_id != null
      error_message = "hosts[*].identity_client_id is required: every instance reads the Datadog API key from DSV with the scale set's user-assigned managed identity."
    }
  }
}
