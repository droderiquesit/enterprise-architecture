# lab/hosts (component `obs-hosts`)

**Owner:** observability.

**Purpose:** puts the Datadog Agent on the lab VMs and VMSS, Linux and Windows, through
[`modules/host-agents`](../../modules/host-agents/README.md) (observability 4.0.0). It publishes the VM Applications
`datadog-agent-linux` / `datadog-agent-windows` in this environment's Compute Gallery. An **Azure Policy**
initiative, assigned at the subscription by default, enrols every VM / VMSS tagged `datadog:enabled = true`. There is
no per-host Terraform and no run command or CustomScript.

## Contracts

* **Consumes:**
  * `obs_telemetry_transport`: `datadog_site`, `api_key_ref`, `secrets.{tenant, tld, base_url}`,
    `aggregator.{kind, agent_logs_url}` and `env.fleet`.
  * `foundation_identity` v2: `identities["obs-host-agent"].{id, client_id}`, the per-environment DSV-reader identity
    that the policy attaches to every enrolled host.
  * Artifact `img-dsv-fetch` (zip-package): the dsv-fetch release files are the VM Application packages.
* **Optional (`settings.mode = direct` only):**
  * `platform_vm.vms[*].{id, os_type}`;
  * `platform_vmss.scale_sets[*].{id, os_type}`;
  * `platform_db_sqlvm.vm.id`.

  In policy mode these contracts are not read: hosts are enrolled by tag.
* **Produces:** no contract. Outputs: `mode`, `enrollment_tag`, `applications` (pinned version), `agent_version`,
  `policy`, `assignments`, `vmss_gallery_applications`, `otlp_endpoint`, `host_log_paths`.

## Before plan (pipeline)

The release is staged automatically: `pipelines/scripts/tf-prepare.sh` runs `tools/deploy/artifacts.py unpack`
(registry `UNPACK`: `obs-hosts` <- `img-dsv-fetch`) before every plan and apply of this root. It resolves
`artifacts["img-dsv-fetch"]` exactly like `tfvars` (recorded artifact of the platform pipeline, current source
fingerprint), downloads `package_url` from the packages store with the deploy identity (Entra ID), verifies
`package_sha256` and every line of the zip's `SHA256SUMS`, and extracts `dsv-fetch-linux-amd64`,
`dsv-fetch-linux-arm64`, `dsv-fetch-windows-amd64.exe` and `SHA256SUMS` into `observability/lab/hosts/.dsv-fetch-release/`
(git-ignored). The plan fails with a clear message when the files are missing (local runs: unzip the release there
yourself). Terraform checks every binary against `SHA256SUMS` again, and the host checks it once more.

## Apply identity RBAC (document for the environment owner)

The pipeline apply identity of this root needs at the policy scope (`settings.policy.scope`):

* **Resource Policy Contributor** - policy definitions, initiative, assignment, remediation tasks. Bootstrap grants
  it at subscription scope (`apply_policy_contributor`, default true); a management-group scope needs it there.
* **Role assignments** of the custom remediation role and **Managed Identity Operator** (on the DSV-reader identity
  only) to the assignment's remediation identity. Bootstrap's *Role Based Access Control Administrator* with the
  ABAC condition (`apply_rbac_mode = constrained`: never Owner / User Access Administrator / RBAC Administrator)
  covers this at subscription scope.
* **Role definition write** (`Microsoft.Authorization/roleDefinitions/write`) for the custom remediation role - **not**
  in bootstrap's apply rights (Contributor excludes `Microsoft.Authorization/*/write`; RBAC Administrator only manages
  assignments). Grant it once at the scope, e.g. **User Access Administrator** restricted by an Azure ABAC
  role-assignment condition (delegated role assignment management: `roleAssignments/write|delete` only when
  `@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId]` is Managed Identity Operator
  `f1a07417-d97a-45cb-824c-7a7467783830` or the custom remediation role, and `PrincipalType` is `ServicePrincipal`),
  or have an operator create the role definition with the same name/GUID before the first apply. Deliberately not
  added to bootstrap: role-definition write plus role-assignment rights would let the apply identity mint and assign
  an arbitrary custom role. Not verified in a live tenant (docs/known-limitations.md).
* `settings.publisher_principal_ids`: the apply identity's **principal (object) id** - the package module grants it
  Storage Blob Data Contributor on the package storage account so the apply can upload the VM Application packages
  with Entra ID (no shared keys).

## Settings (`components.obs-hosts`)

* **Mode and version:**
  * `mode` = `policy` (default) | `direct`.
  * `package_version` (default `1.0.0`): bump it for every change of the Agent pin, the installer or the dsv-fetch
    release. Promote it dev -> test -> prod.
  * `retained_versions`: rollback targets.
* **Policy:**
  * `scope`: null = this subscription, or `{type = "management_group", id = "/providers/Microsoft.Management/managementGroups/<mg>"}`.
  * `enrollment_tag {name, value}` (default `datadog:enabled` / `true`), `effect` (`DeployIfNotExists`), `targets`
    (`vm`, `vmss`), `remediation {...}`.
* **Agent logs:** `host_logs`, by default:
  * Linux: `/var/log/hello-worker/*.log` and `/var/log/enterprise-hello/*.log`;
  * Windows: `C:\ProgramData\enterprise-hello\logs\*.log` plus the Event Log channels `System` and `Application`.

  Hosts add files with the `datadog:log_paths` tag.
* **Package details:** `applications` (add `linux_arm64` for arm64 hosts), `dsv_fetch_release_dir`, `replica_regions`,
  `publisher_principal_ids` (apply identity: blob upload with Entra ID), `package_network`.
* **Other:** `agent_identity_key` (`obs-host-agent`), `sqlvm_os_type` (direct mode).

## Secrets

This root and its state hold no secret. Every host reads `datadog-api-key` from Delinea DSV at Agent start. The
Agent's secret backend is the dsv-fetch binary, which uses the `obs-host-agent` identity. DSV grants that identity
read on the **ingest-only** API key only. Accepted risk: any process on an enrolled host can use the identity. See
the module README.

## Platform roots (done in 4.0.0)

`platform-vm`, `platform-vmss` and `platform-db-sqlvm` tag their VMs / VMSS with `datadog:enabled = "true"`
(`settings.datadog.tag_name`, keep it equal to `settings.policy.enrollment_tag.name` here), keep the `obs-host-agent`
identity from the foundation-identity contract in `identity_ids` and set
`lifecycle { ignore_changes = [gallery_application] }` (azurerm has no such block on orchestrated / Flexible scale
sets; the policy's partial PUT is invisible to Terraform there). Their next apply does not remove what the policy
attached (ADR-0001 §3 rule 3 as amended). The uniform VMSS keeps `upgrade_mode = Manual` (no health probe; the
deployment root's per-instance update rolls the model out); new instances get the application at once.

## Cost

VM Applications and Azure Policy are free. The package storage (ZRS, a few MB per version) and the gallery replicas
cost almost nothing. Datadog bills the Agent hosts.

## Teardown

Destroy removes the policy assignment, initiative, definitions, custom role, gallery and storage. Agents already
installed stay on the hosts until the application is removed from their model (the `remove` script uninstalls the
Agent). Remove the `datadog:enabled` tags first if hosts should be cleaned up.

## Private networking

Hosts need egress to:

* `*.datadoghq.com` (or the site), or the Observability Pipelines Worker in the VNet;
* `install.datadoghq.com`, `apt.datadoghq.com` / `yum.datadoghq.com` and `windows-agent.datadoghq.com` (Agent
  install);
* the DSV tenant (`<tenant>.secretsvaultcloud.<tld>`).

The package storage needs no host access.

## Limitations

* Not deployed or verified live from this change.
* The Windows installer is parse-checked and its configuration part executed under pwsh on Linux; it was not run on
  Windows.
* The remediation template's lambda functions and the partial-body PUT of VMSS models follow Microsoft Learn but were
  not exercised against Azure.

## Test
`terraform init -backend=false && terraform test` in this directory (mock providers, no credentials): `tests/lab.tftest.hcl`. From the repository root: `python3 tools/validate/all_terraform.py --only obs-hosts` (fmt, validate, test).
