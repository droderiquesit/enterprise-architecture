# Azure Policy enrolment of VMs / VM scale sets into the Datadog Agent VM Application (no per-host Terraform):
#   two custom DeployIfNotExists definitions (virtualMachines, virtualMachineScaleSets), parameterised by OS,
#   architecture, application and version -> one initiative (one member per application x kind) -> one assignment
#   at subscription or management-group scope with a user-assigned remediation identity holding a least-privilege
#   custom role (+ Managed Identity Operator on the DSV-reader identity only) -> optional remediation tasks.
# Targets: resources tagged <enrollment_tag.name> = <enrollment_tag.value> with the matching OS. Compliant when the
# model carries the pinned application version AND the per-environment DSV-reader identity. Otherwise the policy
# deploys an ARM template that reads the current model (identity, applicationProfile) and PUTs it back with the
# identity added and the application set to the pinned version (other applications and identities are kept).
# Microsoft Learn: Azure Policy DeployIfNotExists cannot set fields itself - it always deploys a template; the
# `modify` effect can append applicationProfile.galleryApplications but cannot replace an older version of the same
# application, and adding a user-assigned identity with `modify` must run with enforcement disabled
# (see README "Why DeployIfNotExists").
locals {
  mg_scope  = var.scope.type == "management_group"
  gallery_s = element(split("/", var.gallery_id), 2)

  kinds = {
    vm = {
      type       = "Microsoft.Compute/virtualMachines"
      os_alias   = "Microsoft.Compute/virtualMachines/storageProfile.osDisk.osType"
      apps_alias = "Microsoft.Compute/virtualMachines/applicationProfile.galleryApplications[*]"
      display    = "virtual machines"
    }
    vmss = {
      type       = "Microsoft.Compute/virtualMachineScaleSets"
      os_alias   = "Microsoft.Compute/virtualMachineScaleSets/virtualMachineProfile.storageProfile.osDisk.osType"
      apps_alias = "Microsoft.Compute/virtualMachineScaleSets/virtualMachineProfile.applicationProfile.galleryApplications[*]"
      display    = "virtual machine scale sets"
    }
  }
  # 2024-11-01: applicationProfile (treatFailureAsDeploymentFailure) + user-assigned identities on VM and VMSS
  compute_api = "2024-11-01"

  # initiative parameter names per application key
  app_param = { linux = "linux", windows = "windows", linux_arm64 = "linuxArm64" }
  app_arch  = { linux = "amd64", windows = "any", linux_arm64 = "arm64" }
  members = { for p in setproduct(sort(keys(var.applications)), sort(tolist(var.targets))) : "${replace(p[0], "_", "-")}-${p[1]}" => {
    app  = p[0]
    kind = p[1]
  } }

  managed_identity_operator = "f1a07417-d97a-45cb-824c-7a7467783830"
  role_guid                 = uuidv5("url", "${var.scope.id}/${var.name_prefix}/datadog-host-agent-remediation")
  role_definition_ids = [
    "/providers/Microsoft.Authorization/roleDefinitions/${local.role_guid}",
    "/providers/Microsoft.Authorization/roleDefinitions/${local.managed_identity_operator}",
  ]

  # policy-definition parameters (shared by both kinds)
  definition_parameters = {
    effect                          = { type = "String", allowedValues = ["DeployIfNotExists", "AuditIfNotExists", "Disabled"], defaultValue = "DeployIfNotExists", metadata = { displayName = "Effect" } }
    tagName                         = { type = "String", metadata = { displayName = "Enrolment tag name" } }
    tagValue                        = { type = "String", metadata = { displayName = "Enrolment tag value" } }
    osType                          = { type = "String", allowedValues = ["Linux", "Windows"], metadata = { displayName = "OS type" } }
    architecture                    = { type = "String", allowedValues = ["any", "amd64", "arm64"], defaultValue = "any", metadata = { displayName = "CPU architecture (image SKU contains arm64, or the arch tag says arm64)" } }
    archTagName                     = { type = "String", defaultValue = "datadog:arch", metadata = { displayName = "Architecture override tag" } }
    applicationId                   = { type = "String", metadata = { displayName = "Gallery application id (without /versions/...)" } }
    applicationVersion              = { type = "String", metadata = { displayName = "Pinned application version" } }
    agentIdentityId                 = { type = "String", metadata = { displayName = "DSV-reader user-assigned identity id" } }
    order                           = { type = "Integer", defaultValue = 10, metadata = { displayName = "Install order" } }
    treatFailureAsDeploymentFailure = { type = "Boolean", defaultValue = false, metadata = { displayName = "Treat install failure as deployment failure" } }
  }

  is_arm64 = {
    anyOf = [
      { field = "Microsoft.Compute/imageSku", contains = "arm64" },
      { field = "[concat('tags[', parameters('archTagName'), ']')]", equals = "arm64" },
    ]
  }

  policy_rule = { for k, kd in local.kinds : k => {
    if = {
      allOf = [
        { field = "type", equals = kd.type },
        { field = "[concat('tags[', parameters('tagName'), ']')]", equals = "[parameters('tagValue')]" },
        { field = kd.os_alias, equals = "[parameters('osType')]" },
        { anyOf = [
          { value = "[parameters('architecture')]", equals = "any" },
          { allOf = [{ value = "[parameters('architecture')]", equals = "arm64" }, local.is_arm64] },
          { allOf = [{ value = "[parameters('architecture')]", equals = "amd64" }, { not = local.is_arm64 }] },
        ] },
      ]
    }
    then = {
      effect = "[parameters('effect')]"
      details = {
        type              = kd.type
        name              = "[field('name')]"
        evaluationDelay   = "AfterProvisioning"
        roleDefinitionIds = local.role_definition_ids
        existenceCondition = {
          allOf = [
            {
              count = {
                field = kd.apps_alias
                where = {
                  field  = "${kd.apps_alias}.packageReferenceId"
                  equals = "[concat(parameters('applicationId'), '/versions/', parameters('applicationVersion'))]"
                }
              }
              equals = 1
            },
            { field = "identity.userAssignedIdentities", containsKey = "[parameters('agentIdentityId')]" },
          ]
        }
        deployment = {
          properties = {
            mode = "incremental"
            parameters = {
              resourceId                      = { value = "[field('id')]" }
              resourceName                    = { value = "[field('name')]" }
              location                        = { value = "[field('location')]" }
              applicationId                   = { value = "[parameters('applicationId')]" }
              applicationVersion              = { value = "[parameters('applicationVersion')]" }
              agentIdentityId                 = { value = "[parameters('agentIdentityId')]" }
              order                           = { value = "[parameters('order')]" }
              treatFailureAsDeploymentFailure = { value = "[parameters('treatFailureAsDeploymentFailure')]" }
            }
            template = local.templates[k]
          }
        }
      }
    }
  } }

  # ------------------------------------------------------------------ remediation template (ARM)
  # 1. nested deployment `read`: the resource's current model (reference(..., 'Full'): identity + properties)
  # 2. nested deployment `apply` (inner scope): PUT of the resource with ONLY location, identity and the
  #    applicationProfile - Compute keeps every other property (the pattern of the built-in "Assign Built-In
  #    User-Assigned Managed Identity" policies and of the Microsoft Learn VM Application deployment templates).
  model_expr  = "reference(variables('readName')).outputs.model.value"
  app_profile = { applicationProfile = { galleryApplications = "[concat(variables('others'), createArray(variables('ours')))]" } }
  apps_path = {
    vm   = "properties"
    vmss = "properties.virtualMachineProfile"
  }
  templates = { for k, kd in local.kinds : k => {
    "$schema"      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
    contentVersion = "1.0.0.0"
    parameters = {
      resourceId                      = { type = "string" }
      resourceName                    = { type = "string" }
      location                        = { type = "string" }
      applicationId                   = { type = "string" }
      applicationVersion              = { type = "string" }
      agentIdentityId                 = { type = "string" }
      order                           = { type = "int" }
      treatFailureAsDeploymentFailure = { type = "bool" }
    }
    variables = {
      readName  = "[concat('ddReadModel-', uniqueString(deployment().name))]"
      applyName = "[concat('ddApplyModel-', uniqueString(deployment().name))]"
    }
    resources = [
      {
        type       = "Microsoft.Resources/deployments"
        apiVersion = "2022-09-01"
        name       = "[variables('readName')]"
        properties = {
          mode = "Incremental"
          template = {
            "$schema"      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
            contentVersion = "1.0.0.0"
            resources      = []
            outputs = {
              model = { type = "object", value = "[reference(parameters('resourceId'), '${local.compute_api}', 'Full')]" }
            }
          }
        }
      },
      {
        type       = "Microsoft.Resources/deployments"
        apiVersion = "2022-09-01"
        name       = "[variables('applyName')]"
        dependsOn  = ["[variables('readName')]"]
        properties = {
          mode                        = "Incremental"
          expressionEvaluationOptions = { scope = "inner" }
          parameters = {
            resourceName       = { value = "[parameters('resourceName')]" }
            location           = { value = "[parameters('location')]" }
            applicationId      = { value = "[parameters('applicationId')]" }
            packageReferenceId = { value = "[concat(parameters('applicationId'), '/versions/', parameters('applicationVersion'))]" }
            agentIdentityId    = { value = "[parameters('agentIdentityId')]" }
            order              = { value = "[parameters('order')]" }
            treatFailure       = { value = "[parameters('treatFailureAsDeploymentFailure')]" }
            identityType       = { value = "[if(contains(${local.model_expr}, 'identity'), ${local.model_expr}.identity.type, '')]" }
            userAssignedIdentities = {
              value = "[if(and(contains(${local.model_expr}, 'identity'), contains(${local.model_expr}.identity, 'userAssignedIdentities')), ${local.model_expr}.identity.userAssignedIdentities, createObject())]"
            }
            galleryApplications = {
              value = "[if(contains(${local.model_expr}.${local.apps_path[k]}, 'applicationProfile'), if(contains(${local.model_expr}.${local.apps_path[k]}.applicationProfile, 'galleryApplications'), ${local.model_expr}.${local.apps_path[k]}.applicationProfile.galleryApplications, createArray()), createArray())]"
            }
          }
          template = {
            "$schema"      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#"
            contentVersion = "1.0.0.0"
            parameters = {
              resourceName           = { type = "string" }
              location               = { type = "string" }
              applicationId          = { type = "string" }
              packageReferenceId     = { type = "string" }
              agentIdentityId        = { type = "string" }
              order                  = { type = "int" }
              treatFailure           = { type = "bool" }
              identityType           = { type = "string" }
              userAssignedIdentities = { type = "object" }
              galleryApplications    = { type = "array" }
            }
            variables = {
              ours = "[createObject('packageReferenceId', parameters('packageReferenceId'), 'order', parameters('order'), 'treatFailureAsDeploymentFailure', parameters('treatFailure'))]"
              # every other application stays; an older version of THIS application is replaced (one version per VM)
              others            = "[filter(parameters('galleryApplications'), lambda('a', not(startsWith(toLower(lambdaVariables('a').packageReferenceId), toLower(concat(parameters('applicationId'), '/versions/'))))))]"
              identityTypeValue = "[if(contains(parameters('identityType'), 'SystemAssigned'), 'SystemAssigned,UserAssigned', 'UserAssigned')]"
              identities        = "[union(parameters('userAssignedIdentities'), createObject(parameters('agentIdentityId'), createObject()))]"
            }
            resources = [{
              type       = kd.type
              apiVersion = local.compute_api
              name       = "[parameters('resourceName')]"
              location   = "[parameters('location')]"
              identity   = { type = "[variables('identityTypeValue')]", userAssignedIdentities = "[variables('identities')]" }
              # VM: properties.applicationProfile; VMSS: properties.virtualMachineProfile.applicationProfile
              properties = jsondecode(k == "vm" ? jsonencode(local.app_profile) : jsonencode({ virtualMachineProfile = local.app_profile }))
            }]
          }
        }
      },
    ]
  } }

  definition_metadata = jsonencode({ category = "Monitoring", version = "1.0.0", source = "observability/modules/host-agent-policy" })
}

# ---------------------------------------------------------------------------------------------- definitions
resource "azurerm_policy_definition" "agent" {
  for_each            = local.kinds
  name                = "${var.name_prefix}-${each.key}"
  display_name        = "Datadog Agent VM Application on tagged ${each.value.display} (${var.name_prefix})"
  description         = "Deploys the pinned Datadog Agent VM Application and the DSV-reader user-assigned identity to ${each.value.display} tagged for Datadog enrolment."
  policy_type         = "Custom"
  mode                = "Indexed"
  management_group_id = local.mg_scope ? var.scope.id : null
  metadata            = local.definition_metadata
  parameters          = jsonencode(local.definition_parameters)
  policy_rule         = jsonencode(local.policy_rule[each.key])
}

locals {
  set_parameters = merge(
    {
      effect                          = { type = "String", allowedValues = ["DeployIfNotExists", "AuditIfNotExists", "Disabled"], defaultValue = "DeployIfNotExists" }
      tagName                         = { type = "String" }
      tagValue                        = { type = "String" }
      archTagName                     = { type = "String", defaultValue = "datadog:arch" }
      agentIdentityId                 = { type = "String" }
      order                           = { type = "Integer", defaultValue = 10 }
      treatFailureAsDeploymentFailure = { type = "Boolean", defaultValue = false }
    },
    merge([for app, p in local.app_param : {
      "${p}ApplicationId" = { type = "String", metadata = { displayName = "${app} gallery application id" } }
      "${p}Version"       = { type = "String", metadata = { displayName = "${app} pinned version (promoted dev -> test -> prod)" } }
    } if contains(keys(var.applications), app)]...),
  )
  member_values = { for ref, m in local.members : ref => jsonencode({
    effect                          = { value = "[parameters('effect')]" }
    tagName                         = { value = "[parameters('tagName')]" }
    tagValue                        = { value = "[parameters('tagValue')]" }
    archTagName                     = { value = "[parameters('archTagName')]" }
    agentIdentityId                 = { value = "[parameters('agentIdentityId')]" }
    order                           = { value = "[parameters('order')]" }
    treatFailureAsDeploymentFailure = { value = "[parameters('treatFailureAsDeploymentFailure')]" }
    osType                          = { value = var.applications[m.app].os == "linux" ? "Linux" : "Windows" }
    architecture                    = { value = local.app_arch[m.app] }
    applicationId                   = { value = "[parameters('${local.app_param[m.app]}ApplicationId')]" }
    applicationVersion              = { value = "[parameters('${local.app_param[m.app]}Version')]" }
  }) }
  # `linux` targets amd64 hosts only (its package is the amd64 dsv-fetch); arm64 Linux hosts (image SKU contains
  # arm64, or the arch tag says arm64) are enrolled only when the linux_arm64 application is published.
  set_name = "${var.name_prefix}-agent"
}

resource "azurerm_policy_set_definition" "agent" {
  count        = local.mg_scope ? 0 : 1
  name         = local.set_name
  display_name = "Datadog Agent on tagged VMs / VMSS (${var.name_prefix})"
  description  = "Datadog Agent VM Application + DSV-reader identity on every VM / VMSS tagged ${var.enrollment_tag.name}=${var.enrollment_tag.value}."
  policy_type  = "Custom"
  metadata     = local.definition_metadata
  parameters   = jsonencode(local.set_parameters)

  dynamic "policy_definition_reference" {
    for_each = local.members
    content {
      reference_id         = policy_definition_reference.key
      policy_definition_id = azurerm_policy_definition.agent[policy_definition_reference.value.kind].id
      parameter_values     = local.member_values[policy_definition_reference.key]
    }
  }
}

resource "azurerm_management_group_policy_set_definition" "agent" {
  count               = local.mg_scope ? 1 : 0
  name                = local.set_name
  management_group_id = var.scope.id
  display_name        = "Datadog Agent on tagged VMs / VMSS (${var.name_prefix})"
  description         = "Datadog Agent VM Application + DSV-reader identity on every VM / VMSS tagged ${var.enrollment_tag.name}=${var.enrollment_tag.value}."
  policy_type         = "Custom"
  metadata            = local.definition_metadata
  parameters          = jsonencode(local.set_parameters)

  dynamic "policy_definition_reference" {
    for_each = local.members
    content {
      reference_id         = policy_definition_reference.key
      policy_definition_id = azurerm_policy_definition.agent[policy_definition_reference.value.kind].id
      parameter_values     = local.member_values[policy_definition_reference.key]
    }
  }
}

# ---------------------------------------------------------------------------------------------- identity + RBAC
resource "azurerm_user_assigned_identity" "remediation" {
  name                = "${var.name_prefix}-policy"
  resource_group_name = var.identity_resource_group_name
  location            = var.location
  tags                = merge(var.tags, { purpose = "Azure Policy remediation: Datadog Agent VM Application on tagged VMs / VMSS" })
}

# Least privilege (instead of Contributor / Virtual Machine Contributor): read + write the VM / VMSS model (identity,
# applicationProfile), run the remediation deployment, read the gallery application versions it references.
resource "azurerm_role_definition" "remediation" {
  name               = "${var.name_prefix} Datadog host agent remediation"
  role_definition_id = local.role_guid
  scope              = var.scope.id
  description        = "Azure Policy remediation of the Datadog Agent VM Application: VM / VMSS model write (identity + applicationProfile), template deployments, gallery application read."
  assignable_scopes  = distinct(concat([var.scope.id], local.mg_scope || startswith(lower(var.gallery_id), lower("${var.scope.id}/")) ? [] : ["/subscriptions/${local.gallery_s}"]))

  permissions {
    actions = concat([
      "Microsoft.Compute/virtualMachines/read",
      "Microsoft.Compute/virtualMachines/write",
      "Microsoft.Compute/virtualMachineScaleSets/read",
      "Microsoft.Compute/virtualMachineScaleSets/write",
      "Microsoft.Compute/galleries/read",
      "Microsoft.Compute/galleries/applications/read",
      "Microsoft.Compute/galleries/applications/versions/read",
      "Microsoft.Resources/deployments/read",
      "Microsoft.Resources/deployments/write",
      "Microsoft.Resources/deployments/validate/action",
      "Microsoft.Resources/deployments/operations/read",
      "Microsoft.Resources/deployments/operationstatuses/read",
      "Microsoft.Resources/subscriptions/resourceGroups/read",
    ], var.extra_role_actions)
    not_actions = []
  }
}

resource "azurerm_role_assignment" "remediation_scope" {
  scope              = var.scope.id
  role_definition_id = azurerm_role_definition.remediation.role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.remediation.principal_id
  principal_type     = "ServicePrincipal"
  description        = "Datadog host agent policy: VM / VMSS model update + deployments"
}

# the gallery outside the assignment scope (subscription scope only; under a management group it is a descendant)
resource "azurerm_role_assignment" "remediation_gallery" {
  count              = local.mg_scope || startswith(lower(var.gallery_id), lower("${var.scope.id}/")) ? 0 : 1
  scope              = var.gallery_id
  role_definition_id = azurerm_role_definition.remediation.role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.remediation.principal_id
  principal_type     = "ServicePrincipal"
  description        = "Datadog host agent policy: read the gallery application versions"
}

# assign/action on exactly ONE identity: the DSV-reader identity the policy attaches
resource "azurerm_role_assignment" "assign_agent_identity" {
  scope                = var.agent_identity.id
  role_definition_name = "Managed Identity Operator"
  principal_id         = azurerm_user_assigned_identity.remediation.principal_id
  principal_type       = "ServicePrincipal"
  description          = "Datadog host agent policy: attach the DSV-reader identity to enrolled VMs / VMSS"
}

# ---------------------------------------------------------------------------------------------- assignment
locals {
  set_id = local.mg_scope ? azurerm_management_group_policy_set_definition.agent[0].id : azurerm_policy_set_definition.agent[0].id
  assignment_parameters = jsonencode(merge(
    {
      effect                          = { value = var.effect }
      tagName                         = { value = var.enrollment_tag.name }
      tagValue                        = { value = var.enrollment_tag.value }
      archTagName                     = { value = var.arch_tag_name }
      agentIdentityId                 = { value = var.agent_identity.id }
      order                           = { value = var.application_order }
      treatFailureAsDeploymentFailure = { value = var.treat_failure_as_deployment_failure }
    },
    merge([for app, a in var.applications : {
      "${local.app_param[app]}ApplicationId" = { value = a.id }
      "${local.app_param[app]}Version"       = { value = a.version }
    }]...),
  ))
  # management-group assignment names are limited to 24 characters
  assignment_name = local.mg_scope ? substr(replace(var.name_prefix, "/-+$/", ""), 0, 24) : "${var.name_prefix}-agent"
  assignment_id   = local.mg_scope ? azurerm_management_group_policy_assignment.agent[0].id : azurerm_subscription_policy_assignment.agent[0].id
  non_compliance  = "Tagged ${var.enrollment_tag.name}=${var.enrollment_tag.value}: the Datadog Agent VM Application (pinned version) and the DSV-reader identity are deployed by remediation."
}

resource "azurerm_subscription_policy_assignment" "agent" {
  count                = local.mg_scope ? 0 : 1
  name                 = local.assignment_name
  subscription_id      = var.scope.id
  policy_definition_id = local.set_id
  display_name         = "Datadog Agent on tagged VMs / VMSS (${var.name_prefix})"
  location             = var.location
  not_scopes           = var.scope.not_scopes
  parameters           = local.assignment_parameters

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.remediation.id]
  }

  non_compliance_message {
    content = local.non_compliance
  }

  depends_on = [azurerm_role_assignment.remediation_scope, azurerm_role_assignment.assign_agent_identity, azurerm_role_assignment.remediation_gallery]
}

resource "azurerm_management_group_policy_assignment" "agent" {
  count                = local.mg_scope ? 1 : 0
  name                 = local.assignment_name
  management_group_id  = var.scope.id
  policy_definition_id = local.set_id
  display_name         = "Datadog Agent on tagged VMs / VMSS (${var.name_prefix})"
  location             = var.location
  not_scopes           = var.scope.not_scopes
  parameters           = local.assignment_parameters

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.remediation.id]
  }

  non_compliance_message {
    content = local.non_compliance
  }

  depends_on = [azurerm_role_assignment.remediation_scope, azurerm_role_assignment.assign_agent_identity]
}

# ---------------------------------------------------------------------------------------------- remediation
locals {
  remediations = var.remediation.enabled && var.effect == "DeployIfNotExists" ? { for ref, m in local.members : ref => {
    name = "${var.name_prefix}-${ref}-${replace(var.applications[m.app].version, ".", "-")}"
  } } : {}
}

resource "azurerm_subscription_policy_remediation" "agent" {
  for_each                       = local.mg_scope ? {} : local.remediations
  name                           = each.value.name
  subscription_id                = var.scope.id
  policy_assignment_id           = local.assignment_id
  policy_definition_reference_id = each.key
  resource_discovery_mode        = "ReEvaluateCompliance"
  location_filters               = var.remediation.location_filters
  parallel_deployments           = var.remediation.parallel_deployments
  resource_count                 = var.remediation.resource_count
  failure_percentage             = var.remediation.failure_percentage
}

resource "azurerm_management_group_policy_remediation" "agent" {
  for_each                       = local.mg_scope ? local.remediations : {}
  name                           = each.value.name
  management_group_id            = var.scope.id
  policy_assignment_id           = local.assignment_id
  policy_definition_reference_id = each.key
  location_filters               = var.remediation.location_filters
  parallel_deployments           = var.remediation.parallel_deployments
  resource_count                 = var.remediation.resource_count
  failure_percentage             = var.remediation.failure_percentage
}
