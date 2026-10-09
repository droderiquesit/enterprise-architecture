# Pipeline identities (user-assigned managed identities + workload identity federation).
#
#   plan      Reader (subscription) + state lease/write (tfstate) + read contracts + write plans
#   apply     Contributor + constrained RBAC Administrator (+ Resource Policy Contributor) + write all containers
#   validate  NO Azure role assignments. Untrusted PR validation runs on Microsoft-hosted agents without any
#             service connection (fmt/validate/test with mock providers need no credentials).
locals {
  pipeline_identities = merge(
    { plan = "terraform plan (read-only Azure, writes state locks and plan files)", apply = "terraform apply" },
    local.s.create_validate_identity ? { validate = "PR validation (no Azure rights)" } : {}
  )

  role_ids = {
    owner                     = "8e3af657-a8ff-443c-a75c-2fe8c4bcb635"
    user_access_administrator = "18d7d88d-d35e-4fb5-a5c3-7773c20a72d9"
    rbac_administrator        = "f58310d9-a9f6-439a-9e8d-f62e7b41a168"
  }

  # ABAC condition on "Role Based Access Control Administrator" (condition version 2.0), from
  # https://learn.microsoft.com/azure/role-based-access-control/delegate-role-assignments-examples
  privileged_roles = join(", ", [local.role_ids.owner, local.role_ids.user_access_administrator, local.role_ids.rbac_administrator])
  allowlist_roles  = join(", ", local.s.apply_role_allowlist)
  apply_rbac_condition = local.s.apply_rbac_mode == "constrained" ? join(" AND ", [
    "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAllValues:GuidNotEquals {${local.privileged_roles}}))",
    "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAllValues:GuidNotEquals {${local.privileged_roles}}))",
    ]) : join(" AND ", [
    "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${local.allowlist_roles}}))",
    "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${local.allowlist_roles}}))",
  ])

  # (identity, scope key, role) tuples. Scope keys: "subscription" or a container name.
  role_assignments = merge(
    {
      "plan/subscription/Reader"                                   = { identity = "plan", scope = "subscription", role = "Reader" }
      "plan/tfstate/Storage Blob Data Contributor"                 = { identity = "plan", scope = "tfstate", role = "Storage Blob Data Contributor" } # blob lease = state lock
      "plan/contracts/Storage Blob Data Reader"                    = { identity = "plan", scope = "contracts", role = "Storage Blob Data Reader" }
      "plan/deployments/Storage Blob Data Reader"                  = { identity = "plan", scope = "deployments", role = "Storage Blob Data Reader" }
      "plan/plans/Storage Blob Data Contributor"                   = { identity = "plan", scope = "plans", role = "Storage Blob Data Contributor" }
      "apply/subscription/Contributor"                             = { identity = "apply", scope = "subscription", role = "Contributor" }
      "apply/subscription/Role Based Access Control Administrator" = { identity = "apply", scope = "subscription", role = "Role Based Access Control Administrator" }
    },
    { for c in keys(local.containers) : "apply/${c}/Storage Blob Data Contributor" => { identity = "apply", scope = c, role = "Storage Blob Data Contributor" } },
    local.s.apply_policy_contributor ? {
      "apply/subscription/Resource Policy Contributor" = { identity = "apply", scope = "subscription", role = "Resource Policy Contributor" }
    } : {},
    { for r in local.s.plan_extra_role_names : "plan/subscription/${r}" => { identity = "plan", scope = "subscription", role = r } },
  )

  legacy_ado = local.s.azure_devops_legacy == null ? [] : [
    for id, sc in local.s.azure_devops_legacy.service_connections : {
      identity  = id
      name      = "ado-legacy-${sc}"
      issuer    = "https://vstoken.dev.azure.com/${local.s.azure_devops_legacy.organization_id}"
      subject   = "sc://${local.s.azure_devops_legacy.organization_name}/${local.s.azure_devops_legacy.project}/${sc}"
      audiences = ["api://AzureADTokenExchange"]
    }
  ]
  federated_credentials = { for f in concat(local.s.federated_credentials, local.legacy_ado) : "${f.identity}/${f.name}" => f }
}

resource "azurerm_user_assigned_identity" "pipeline" {
  for_each = local.pipeline_identities

  name                = "${var.environment.name_prefix}-id-pipeline-${each.key}-${var.environment.name}-${module.naming.region_short}"
  resource_group_name = azurerm_resource_group.bootstrap.name
  location            = local.location
  tags                = merge(local.tags, { purpose = each.value })
}

resource "azurerm_federated_identity_credential" "pipeline" {
  for_each = local.federated_credentials

  name                      = each.value.name
  user_assigned_identity_id = azurerm_user_assigned_identity.pipeline[each.value.identity].id
  issuer                    = each.value.issuer
  subject                   = each.value.subject
  audience                  = each.value.audiences

  lifecycle {
    precondition {
      condition     = contains(keys(local.pipeline_identities), each.value.identity)
      error_message = "Federated credential ${each.key} targets an identity that is not created (validate identity disabled?)."
    }
  }
}

resource "azurerm_role_assignment" "operators" {
  for_each = {
    for pair in setproduct(local.s.operator_principal_ids, ["tfstate", "contracts"]) : "${pair[0]}/${pair[1]}" => { principal = pair[0], container = pair[1] }
  }

  scope                = azurerm_storage_container.this[each.value.container].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = each.value.principal
  description          = "bootstrap operator / break-glass access to ${each.value.container}"
}

resource "azurerm_role_assignment" "pipeline" {
  for_each = local.role_assignments

  scope                = each.value.scope == "subscription" ? local.subscription : azurerm_storage_container.this[each.value.scope].id
  role_definition_name = each.value.role
  principal_id         = azurerm_user_assigned_identity.pipeline[each.value.identity].principal_id
  principal_type       = "ServicePrincipal"
  condition            = each.value.role == "Role Based Access Control Administrator" ? local.apply_rbac_condition : null
  condition_version    = each.value.role == "Role Based Access Control Administrator" ? "2.0" : null
  description          = "bootstrap: ${each.key}"
}
