# modules/host-agent-policy

Enrols VMs and VM scale sets into the Datadog Agent VM Application with **Azure Policy**. No per-host Terraform is
needed.

* Two custom definitions with the `DeployIfNotExists` effect:
  * `<prefix>-vm` for `Microsoft.Compute/virtualMachines`;
  * `<prefix>-vmss` for `Microsoft.Compute/virtualMachineScaleSets`.

  Both are parameterised by OS, architecture, application id, version and identity.
* One **initiative** `<prefix>-agent` with one member per application and resource kind: `linux-vm`, `linux-vmss`,
  `windows-vm`, `windows-vmss`, plus `linux-arm64-*` when that application exists.
* One **assignment** at subscription or management-group scope (`scope.type`). It has a **user-assigned remediation
  identity** and carries the environment's values: the version per application, the enrolment tag, the DSV-reader
  identity id and the effect.
* Optional **remediation tasks**, one per member, for resources that exist already. Each task name contains the
  version, so a version bump starts new tasks. New and updated resources are remediated automatically.

## What the policy does

* **Targets:** `type` = VM / VMSS, `tags[<enrollment_tag.name>] == <enrollment_tag.value>` (default
  `datadog:enabled = true`) and the OS disk type. Architecture rules:
  * `linux` targets amd64 hosts only;
  * `linux_arm64` targets hosts whose `Microsoft.Compute/imageSku` contains `arm64`, or whose `datadog:arch` tag is
    `arm64`.
* **Compliant** when the model's `applicationProfile.galleryApplications` contains exactly
  `<application id>/versions/<pinned version>` **and** `identity.userAssignedIdentities` contains the DSV-reader
  identity.
* **Remediation:** an ARM deployment in the resource's resource group, with two nested deployments:
  1. `read`: `reference(<id>, '2024-11-01', 'Full')` reads the current model, with its identity and application
     profile.
  2. `apply`: a PUT of the resource with **only** `location`, `identity` and the application profile:
     * the identity type is kept and `UserAssigned` added (`SystemAssigned,UserAssigned` when needed);
     * the existing identities are kept and the DSV-reader identity added;
     * every other gallery application is kept, an older version of *this* application is removed (only one version
       of an application per VM), and the pinned version is added with `order` and `treatFailureAsDeploymentFailure`.

  Compute keeps every other property of a VM / VMSS on such a partial PUT. Microsoft uses the same pattern in its
  VM Application deployment templates and in the built-in "Assign Built-In User-Assigned Managed Identity" policies.
* VMSS: the model changes. Instances with an *Automatic* or *Rolling* upgrade policy follow on their own; with
  *Manual* they follow on an instance upgrade or reimage. New instances get the application immediately.
  Flexible-orchestration VMs are `virtualMachines`: they need the tag themselves.

### Why DeployIfNotExists (verified on Microsoft Learn)

* **DeployIfNotExists cannot set fields directly.** It always deploys an ARM template. This module deploys a
  template that sets `applicationProfile.galleryApplications` and the identity (see above).
* **`modify` can append to `applicationProfile.galleryApplications`.** Microsoft documents it in "Inject VM
  Applications" with the alias as modifiable. It is not used here, for three reasons:
  * `modify` can only *add* the application. It cannot replace an older version of the same application on a version
    bump: a VM holds one version of an application, and `[*]` operations would rewrite every entry.
  * Adding a **user-assigned identity** with `modify` must be assigned with enforcement *DoNotEnforce* (Microsoft
    Learn tutorial), so it would not apply at create time.
  * `modify` runs with the caller's permissions at create time. The creator would then need `assign/action` on the
    DSV-reader identity. DeployIfNotExists runs with the assignment identity instead.
* DeployIfNotExists runs after provisioning (`evaluationDelay: AfterProvisioning`). New resources are remediated
  minutes after creation, existing ones through remediation tasks.

## RBAC (least privilege)

The remediation identity (`<prefix>-policy`) gets:

* A custom role `<prefix> Datadog host agent remediation` at the assignment scope (assignable there and, when needed,
  at the gallery's subscription). Its actions are:
  * `Microsoft.Compute/virtualMachines/{read,write}` and `Microsoft.Compute/virtualMachineScaleSets/{read,write}`;
  * `Microsoft.Compute/galleries/read`, `galleries/applications/read` and `galleries/applications/versions/read`;
  * `Microsoft.Resources/deployments/{read,write,validate/action,operations/read,operationstatuses/read}`;
  * `Microsoft.Resources/subscriptions/resourceGroups/read`.

  It has no wildcards, no deletes and no `Microsoft.Authorization` actions. This replaces *Virtual Machine
  Contributor*, which the Learn samples use, and *Contributor*.
* **Managed Identity Operator** on exactly **one** identity, the DSV-reader identity. This gives
  `userAssignedIdentities/*/assign/action`, which is needed to attach it.
* `roleDefinitionIds` in the definitions lists both roles, as the remediation docs require. The assignments are
  created by Terraform: Microsoft Learn says SDK / IaC assignments must grant the roles themselves.
* `extra_role_actions` exists only for tenants whose linked-access checks reject the PUT, for example
  `Microsoft.Network/networkInterfaces/join/action`. The default is empty.

Whoever applies this module needs Resource Policy Contributor and User Access Administrator (role definitions and
assignments) at the scope. Policy evaluation of a create or update uses the caller's identity; remediation uses the
assignment identity.

## Inputs

* `name_prefix`, `scope {type, id, not_scopes}`, `location`, `identity_resource_group_name`.
* `enrollment_tag {name, value}`, `arch_tag_name`, `agent_identity {id}`, `gallery_id`.
* `applications` (from host-agent-package `applications`: `id`, `version`, `os`), `targets` (`vm`, `vmss`).
* `effect` (`DeployIfNotExists` | `AuditIfNotExists` | `Disabled`).
* `application_order` (10), `treat_failure_as_deployment_failure` (false: an Agent failure must not fail the
  workload deployment).
* `remediation {enabled, location_filters, parallel_deployments, resource_count, failure_percentage}`.
* `extra_role_actions`, `tags`.

Outputs: `assignment_id`, `policy_set_definition_id`, `policy_definition_ids`, `members`, `remediation_identity`,
`remediations`, `enrollment_tag`.

Promotion: the same definitions and initiative in every environment. Only the assignment parameter
`<app>Version` differs. The pipeline bumps it in dev, then test, then prod.

Tests: `tests/policy.tftest.hcl` (mock provider) covers:

* the rule shape;
* the existence condition;
* the remediation template (VM `properties.applicationProfile`, VMSS
  `properties.virtualMachineProfile.applicationProfile`);
* the preserved applications and identities;
* the least-privilege role;
* subscription and management-group scope;
* arm64;
* audit mode;
* a gallery in another subscription;
* a version bump creating a new remediation task.

Not verified live: no Azure deployment from this change.

## References (Microsoft Learn, checked 2026-10-10)

* VM Applications and Azure Policy (audit; `modify` inject with Virtual Machine Contributor; gradual remediation per
  region): https://learn.microsoft.com/azure/virtual-machines/vm-applications-inject-with-policy
* Deploy VM Applications (partial-body PUT of `applicationProfile` for VM and VMSS):
  https://learn.microsoft.com/azure/virtual-machines/vm-applications-how-to
* DeployIfNotExists effect (template deployment; nested templates only):
  https://learn.microsoft.com/azure/governance/policy/concepts/effect-deploy-if-not-exists
* Modify effect (only `identity.type` and modifiable aliases):
  https://learn.microsoft.com/azure/governance/policy/concepts/effect-modify
* Adding user-assigned identities with Azure Policy (enforcement DoNotEnforce):
  https://learn.microsoft.com/azure/governance/policy/tutorials/modify-virtual-machine-identity
* Remediation (`roleDefinitionIds`, manual grants for SDK assignments, identity used for deployments):
  https://learn.microsoft.com/azure/governance/policy/how-to/remediate-resources
* Assignment identity: https://learn.microsoft.com/azure/governance/policy/concepts/assignment-structure#identity
* Built-in reference pattern: `Managed Identity/VM_UAI_DINE.json` (Azure/azure-policy on GitHub).
