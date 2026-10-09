# Desired Delinea DSV state for one environment (ADR-0001 section 14), rendered from the identity contract.
#   auth provider  : type azure, tenantId = Entra tenant (created at bootstrap; dsv_apply verifies / creates)
#   users          : one per managed identity that reads secrets: <provider>:<prefix>-<env>-<identity>,
#                    externalId = the user-assigned identity RESOURCE ID (what DSV matches: xms_mirid claim)
#   policy         : ONE policy at path secrets:<prefix>:<env> (DSV validates permission resources against the policy
#                    path and a path holds one policy, so per-identity least privilege is one *permission* per user)
#                    - read on exactly the identity's secret paths; publisher: create/update on generated paths.
locals {
  base_path   = var.foundation_identity.secrets.base_path
  path_prefix = "secrets:${replace(local.base_path, "/", ":")}"
  provider    = var.foundation_identity.secrets.auth_provider
  marker      = var.settings.marker

  catalogue = yamldecode(file("${path.module}/../identity/secrets.yaml")).secrets
  generated = sort([for name, s in local.catalogue : name if s.source == "generated" && contains(keys(var.foundation_identity.secrets.refs), name)])

  readers = {
    for k, v in var.foundation_identity.identities : k => v
    if length(v.secrets) > 0 && !contains(var.settings.excluded_identities, k)
  }
  username = { for k, _ in local.readers : k => "${var.environment.name_prefix}-${var.environment.name}-${k}" }

  users = {
    for k, v in local.readers : local.username[k] => {
      username     = local.username[k]
      qualified    = "${local.provider}:${local.username[k]}"
      provider     = local.provider
      external_id  = v.id
      identity     = k
      display_name = "${local.marker} ${local.base_path} ${k}"
    }
  }

  read_permissions = [
    for k, v in local.readers : {
      key         = "read:${k}"
      description = "${local.marker} ${local.base_path} read ${k}"
      subjects    = ["users:<${local.provider}:${local.username[k]}>"]
      effect      = "allow"
      actions     = ["read"]
      resources   = [for s in sort(distinct(v.secrets)) : "${local.path_prefix}:${s}"]
    }
  ]
  publisher_permissions = length(local.generated) == 0 || !contains(keys(local.readers), var.settings.publisher_identity) ? [] : [{
    key         = "publish:${var.settings.publisher_identity}"
    description = "${local.marker} ${local.base_path} publish ${var.settings.publisher_identity}"
    subjects    = ["users:<${local.provider}:${local.username[var.settings.publisher_identity]}>"]
    effect      = "allow"
    actions     = ["create", "update"]
    resources   = [for s in local.generated : "${local.path_prefix}:${s}"]
  }]

  # tools/secrets/check.py verifies that required paths exist with metadata-only calls (describe/search, never data):
  # the checker gets `list` on the environment's paths, not `read`.
  checker_permissions = !contains(keys(local.readers), var.settings.checker_identity) ? [] : [{
    key         = "list:${var.settings.checker_identity}"
    description = "${local.marker} ${local.base_path} list ${var.settings.checker_identity}"
    subjects    = ["users:<${local.provider}:${local.username[var.settings.checker_identity]}>"]
    effect      = "allow"
    actions     = ["list"]
    resources   = ["${local.path_prefix}:<.*>"]
  }]

  desired_state = {
    schema_version = 1
    marker         = local.marker
    environment    = var.environment.name
    base_url       = var.foundation_identity.secrets.base_url
    base_path      = local.base_path
    auth_provider = {
      name      = local.provider
      type      = "azure"
      tenant_id = var.environment.tenant_id
    }
    users = local.users
    policy = {
      path        = local.path_prefix
      permissions = concat(local.read_permissions, local.publisher_permissions, local.checker_permissions)
    }
    secrets = {
      for name, ref in var.foundation_identity.secrets.refs : name => {
        path      = "${local.base_path}/${name}"
        ref       = ref
        source    = try(local.catalogue[name].source, "operator")
        publisher = try(local.catalogue[name].publisher, null)
        readers   = sort([for k, v in local.readers : k if contains(v.secrets, name)])
      }
    }
  }
}

# The state of this root is the rendered desired state; terraform_data makes a change visible in the plan
# (plan stage: tools/secrets/dsv_apply.py plan prints the DSV diff next to it).
resource "terraform_data" "desired_state" {
  input = sha256(jsonencode(local.desired_state))

  lifecycle {
    precondition {
      condition     = alltrue([for k, v in local.readers : can(regex("^/subscriptions/[^/]+/resource[gG]roups/[^/]+/providers/Microsoft\\.ManagedIdentity/userAssignedIdentities/[^/]+$", v.id))])
      error_message = "DSV users map to user-assigned identity RESOURCE IDs; every identity id must be one."
    }
    precondition {
      condition     = alltrue([for k, v in local.readers : alltrue([for s in v.secrets : contains(keys(var.foundation_identity.secrets.refs), s)])])
      error_message = "Every identity secret must have a reference in foundation_identity.secrets.refs."
    }
    precondition {
      condition     = alltrue([for u in keys(local.users) : can(regex("^[a-zA-Z0-9@+._-]{1,100}$", u))])
      error_message = "DSV usernames may contain only letters, digits, @ + . _ - (dsv-cli ValidateUsername)."
    }
  }
}
