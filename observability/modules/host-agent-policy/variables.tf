variable "name_prefix" {
  description = "Prefix of the policy definitions, initiative, assignment, custom role and remediation names (e.g. eh-dd-hosts-dev). One environment = one prefix."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,40}$", var.name_prefix))
    error_message = "name_prefix: lowercase letters, digits and '-', at most 41 characters."
  }
}

variable "scope" {
  description = <<-EOT
    Where the definitions live and the initiative is assigned:
      type = subscription      -> id = /subscriptions/<id>
      type = management_group  -> id = /providers/Microsoft.Management/managementGroups/<name>
    not_scopes excludes child scopes (e.g. a resource group of another environment).
  EOT
  type = object({
    type       = string
    id         = string
    not_scopes = optional(list(string), [])
  })
  validation {
    condition = (
      (var.scope.type == "subscription" && can(regex("^/subscriptions/[0-9a-fA-F-]{36}$", var.scope.id))) ||
      (var.scope.type == "management_group" && can(regex("^/providers/Microsoft.Management/managementGroups/[^/]+$", var.scope.id)))
    )
    error_message = "scope.type subscription (id /subscriptions/<guid>) or management_group (id /providers/Microsoft.Management/managementGroups/<name>)."
  }
}

variable "location" {
  description = "Region of the assignment identity and (for remediation) the deployments metadata."
  type        = string
}

variable "identity_resource_group_name" {
  description = "Resource group for the policy assignment's user-assigned identity (remediation identity)."
  type        = string
}

variable "enrollment_tag" {
  description = "Azure tag that enrols a VM / VMSS (name and value, exact match, case-insensitive value)."
  type = object({
    name  = optional(string, "datadog:enabled")
    value = optional(string, "true")
  })
  default = {}
  validation {
    condition     = can(regex("^[^<>%&\\\\?/]{1,512}$", var.enrollment_tag.name)) && length(var.enrollment_tag.value) > 0
    error_message = "enrollment_tag.name must be a valid Azure tag name (no < > % & \\ ? /)."
  }
}

variable "arch_tag_name" {
  description = "Azure tag that marks an arm64 host whose image SKU does not say so (value arm64)."
  type        = string
  default     = "datadog:arch"
}

variable "agent_identity" {
  description = "Per-environment DSV-reader user-assigned identity attached to every enrolled VM / VMSS (foundation-identity identities[\"obs-host-agent\"]). DSV grants it read on the ingest-only Datadog API key ONLY."
  type = object({
    id = string
  })
  validation {
    condition     = can(regex("(?i)^/subscriptions/[^/]+/resourcegroups/[^/]+/providers/Microsoft.ManagedIdentity/userAssignedIdentities/[^/]+$", var.agent_identity.id))
    error_message = "agent_identity.id must be a user-assigned identity resource id."
  }
}

variable "gallery_id" {
  description = "Azure Compute Gallery id (host-agent-package output gallery.id); the remediation identity gets read on it."
  type        = string
}

variable "applications" {
  description = <<-EOT
    VM Applications to enforce (host-agent-package output `applications`): key linux | windows | linux_arm64 ->
    {id (gallery application id), version (pinned per environment; bumping it re-remediates every host), os}.
  EOT
  type = map(object({
    id      = string
    version = string
    os      = string
  }))
  validation {
    condition     = alltrue([for k, a in var.applications : contains(["linux", "windows", "linux_arm64"], k) && contains(["linux", "windows"], a.os) && can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", a.version))])
    error_message = "applications: keys linux | windows | linux_arm64, os linux | windows, version Major.Minor.Patch."
  }
}

variable "targets" {
  description = "Resource kinds the initiative covers: vm (Microsoft.Compute/virtualMachines) and/or vmss (Microsoft.Compute/virtualMachineScaleSets)."
  type        = set(string)
  default     = ["vm", "vmss"]
  validation {
    condition     = length(var.targets) > 0 && alltrue([for t in var.targets : contains(["vm", "vmss"], t)])
    error_message = "targets: vm and/or vmss."
  }
}

variable "effect" {
  description = "DeployIfNotExists (enforce) | AuditIfNotExists (report only) | Disabled."
  type        = string
  default     = "DeployIfNotExists"
  validation {
    condition     = contains(["DeployIfNotExists", "AuditIfNotExists", "Disabled"], var.effect)
    error_message = "effect: DeployIfNotExists, AuditIfNotExists or Disabled."
  }
}

variable "application_order" {
  description = "VM Application install order (lower first); other applications on the host keep theirs."
  type        = number
  default     = 10
}

variable "treat_failure_as_deployment_failure" {
  description = "Mark the VM / VMSS deployment failed when the Agent install fails (Microsoft Learn: treatFailureAsDeploymentFailure). Off by default: an Agent failure must not fail the workload's own deployment."
  type        = bool
  default     = false
}

variable "remediation" {
  description = <<-EOT
    Remediation tasks for EXISTING resources (new / updated resources are remediated automatically). One task per
    initiative member; its name includes the application version, so a version bump starts a new task.
  EOT
  type = object({
    enabled              = optional(bool, true)
    location_filters     = optional(list(string), [])
    parallel_deployments = optional(number, 10)
    resource_count       = optional(number, 500)
    failure_percentage   = optional(number, 0.1)
  })
  default = {}
}

variable "extra_role_actions" {
  description = "Additional actions for the remediation role (e.g. Microsoft.Network/networkInterfaces/join/action if a tenant's linked-access checks require it). Keep empty unless a remediation fails with AuthorizationFailed."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Azure resource tags (identity)."
  type        = map(string)
  default     = {}
}
