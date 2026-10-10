mock_provider "azurerm" {}

variables {
  name_prefix                  = "eh-dd-hosts-dev"
  scope                        = { type = "subscription", id = "/subscriptions/00000000-0000-0000-0000-000000000000" }
  location                     = "swedencentral"
  identity_resource_group_name = "eh-rg-obshosts-dev-sec"
  agent_identity               = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-identity-dev-sec/providers/Microsoft.ManagedIdentity/userAssignedIdentities/eh-id-obs-host-agent-dev-sec" }
  gallery_id                   = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-obshosts-dev-sec/providers/Microsoft.Compute/galleries/eh_gal_obshosts_dev_sec"
  applications = {
    linux   = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-obshosts-dev-sec/providers/Microsoft.Compute/galleries/eh_gal_obshosts_dev_sec/applications/datadog-agent-linux", version = "1.2.0", os = "linux" }
    windows = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/eh-rg-obshosts-dev-sec/providers/Microsoft.Compute/galleries/eh_gal_obshosts_dev_sec/applications/datadog-agent-windows", version = "1.2.0", os = "windows" }
  }
}

run "subscription_scope_initiative" {
  command = plan

  assert {
    condition     = length(azurerm_policy_definition.agent) == 2 && azurerm_policy_definition.agent["vm"].mode == "Indexed" && azurerm_policy_definition.agent["vm"].management_group_id == null
    error_message = "Two custom definitions (VM, VMSS) in the subscription."
  }
  assert {
    condition = (jsondecode(azurerm_policy_definition.agent["vm"].policy_rule).then.effect == "[parameters('effect')]"
      && jsondecode(azurerm_policy_definition.agent["vm"].policy_rule).if.allOf[1].field == "[concat('tags[', parameters('tagName'), ']')]"
    && jsondecode(azurerm_policy_definition.agent["vmss"].policy_rule).if.allOf[2].field == "Microsoft.Compute/virtualMachineScaleSets/virtualMachineProfile.storageProfile.osDisk.osType")
    error_message = "Targets tagged resources of the requested OS; effect is a parameter (DeployIfNotExists by default)."
  }
  assert {
    condition = (jsondecode(azurerm_policy_definition.agent["vm"].policy_rule).then.details.existenceCondition.allOf[0].count.where.equals == "[concat(parameters('applicationId'), '/versions/', parameters('applicationVersion'))]"
    && jsondecode(azurerm_policy_definition.agent["vm"].policy_rule).then.details.existenceCondition.allOf[1].containsKey == "[parameters('agentIdentityId')]")
    error_message = "Compliant only with the pinned version AND the DSV-reader identity."
  }
  assert {
    condition = (contains(keys(jsondecode(azurerm_policy_definition.agent["vm"].policy_rule).then.details.deployment.properties.template.resources[1].properties.template.resources[0].properties), "applicationProfile")
    && contains(keys(jsondecode(azurerm_policy_definition.agent["vmss"].policy_rule).then.details.deployment.properties.template.resources[1].properties.template.resources[0].properties), "virtualMachineProfile"))
    error_message = "Remediation PUTs only identity + applicationProfile (VMSS: virtualMachineProfile.applicationProfile)."
  }
  assert {
    condition     = strcontains(azurerm_policy_definition.agent["vm"].policy_rule, "filter(parameters('galleryApplications'), lambda('a'") && strcontains(azurerm_policy_definition.agent["vm"].policy_rule, "union(parameters('userAssignedIdentities')")
    error_message = "Other applications and identities on the resource are kept; only an older version of this application is replaced."
  }
  assert {
    condition     = contains(jsondecode(azurerm_policy_definition.agent["vm"].policy_rule).then.details.roleDefinitionIds, "/providers/Microsoft.Authorization/roleDefinitions/f1a07417-d97a-45cb-824c-7a7467783830")
    error_message = "roleDefinitionIds: the custom remediation role + Managed Identity Operator."
  }
  assert {
    condition     = length(azurerm_policy_set_definition.agent[0].policy_definition_reference) == 4 && length(azurerm_management_group_policy_set_definition.agent) == 0
    error_message = "Initiative: linux/windows x vm/vmss."
  }
  assert {
    condition = (jsondecode(azurerm_policy_set_definition.agent[0].policy_definition_reference[0].parameter_values).osType.value == "Linux"
      && jsondecode(azurerm_policy_set_definition.agent[0].policy_definition_reference[0].parameter_values).architecture.value == "amd64"
    && jsondecode(azurerm_policy_set_definition.agent[0].policy_definition_reference[2].parameter_values).osType.value == "Windows")
    error_message = "Members carry OS + architecture; application id / version come from assignment parameters."
  }
  assert {
    condition = (jsondecode(azurerm_subscription_policy_assignment.agent[0].parameters).linuxVersion.value == "1.2.0"
      && jsondecode(azurerm_subscription_policy_assignment.agent[0].parameters).tagName.value == "datadog:enabled"
      && jsondecode(azurerm_subscription_policy_assignment.agent[0].parameters).agentIdentityId.value == var.agent_identity.id
    && azurerm_subscription_policy_assignment.agent[0].identity[0].type == "UserAssigned")
    error_message = "Assignment pins the version per environment, the enrolment tag and the DSV-reader identity; user-assigned remediation identity."
  }
  assert {
    condition = (!anytrue([for a in azurerm_role_definition.remediation.permissions[0].actions : strcontains(a, "*") || startswith(a, "Microsoft.Authorization/")])
      && contains(azurerm_role_definition.remediation.permissions[0].actions, "Microsoft.Compute/virtualMachineScaleSets/write")
    && !contains(azurerm_role_definition.remediation.permissions[0].actions, "Microsoft.Compute/virtualMachines/delete"))
    error_message = "Least-privilege custom role: no wildcards, no Authorization writes, no deletes."
  }
  assert {
    condition     = azurerm_role_assignment.assign_agent_identity.scope == var.agent_identity.id && azurerm_role_assignment.assign_agent_identity.role_definition_name == "Managed Identity Operator" && length(azurerm_role_assignment.remediation_gallery) == 0
    error_message = "assign/action only on the DSV-reader identity; gallery inside the scope needs no extra grant."
  }
  assert {
    condition     = length(azurerm_subscription_policy_remediation.agent) == 4 && azurerm_subscription_policy_remediation.agent["linux-vm"].name == "eh-dd-hosts-dev-linux-vm-1-2-0" && azurerm_subscription_policy_remediation.agent["linux-vm"].policy_definition_reference_id == "linux-vm"
    error_message = "One remediation task per member; the name carries the version (a bump re-remediates)."
  }
}

run "version_bump_new_remediation" {
  command = plan
  variables {
    applications = {
      linux = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/galleries/g/applications/datadog-agent-linux", version = "1.3.0", os = "linux" }
    }
    targets = ["vmss"]
  }
  assert {
    condition     = keys(azurerm_subscription_policy_remediation.agent) == ["linux-vmss"] && azurerm_subscription_policy_remediation.agent["linux-vmss"].name == "eh-dd-hosts-dev-linux-vmss-1-3-0"
    error_message = "Promotion = version bump -> new remediation task."
  }
}

run "management_group_scope" {
  command = plan
  variables {
    scope = { type = "management_group", id = "/providers/Microsoft.Management/managementGroups/eh-landingzones" }
    applications = {
      linux       = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/galleries/g/applications/datadog-agent-linux", version = "1.2.0", os = "linux" }
      linux_arm64 = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/galleries/g/applications/datadog-agent-linux-arm64", version = "1.2.0", os = "linux" }
    }
  }
  assert {
    condition     = length(azurerm_management_group_policy_assignment.agent) == 1 && length(azurerm_subscription_policy_assignment.agent) == 0 && length(azurerm_management_group_policy_assignment.agent[0].name) <= 24
    error_message = "Management-group assignment (name <= 24 characters)."
  }
  assert {
    condition     = azurerm_policy_definition.agent["vm"].management_group_id == var.scope.id && length(azurerm_management_group_policy_remediation.agent) == 4 && azurerm_role_definition.remediation.scope == var.scope.id
    error_message = "Definitions, role and remediation at the management group."
  }
  assert {
    condition     = jsondecode(azurerm_management_group_policy_assignment.agent[0].parameters).linuxArm64Version.value == "1.2.0" && jsondecode(one([for r in azurerm_management_group_policy_set_definition.agent[0].policy_definition_reference : r.parameter_values if r.reference_id == "linux-arm64-vm"])).architecture.value == "arm64"
    error_message = "arm64 Linux application targets arm64 hosts."
  }
}

run "audit_only_no_remediation" {
  command = plan
  variables {
    effect = "AuditIfNotExists"
  }
  assert {
    condition     = length(azurerm_subscription_policy_remediation.agent) == 0 && jsondecode(azurerm_subscription_policy_assignment.agent[0].parameters).effect.value == "AuditIfNotExists"
    error_message = "Audit mode reports only."
  }
}

run "gallery_in_other_subscription" {
  command = plan
  variables {
    gallery_id = "/subscriptions/11111111-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/galleries/g"
  }
  assert {
    condition     = length(azurerm_role_assignment.remediation_gallery) == 1 && contains(azurerm_role_definition.remediation.assignable_scopes, "/subscriptions/11111111-0000-0000-0000-000000000000")
    error_message = "A gallery outside the subscription scope gets its own read grant."
  }
}

run "reject_bad_scope" {
  command = plan
  variables {
    scope = { type = "subscription", id = "/providers/Microsoft.Management/managementGroups/x" }
  }
  expect_failures = [var.scope]
}
