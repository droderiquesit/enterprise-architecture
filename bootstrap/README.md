# bootstrap

- **Owner:** platform-engineering · **Component id:** `bootstrap` · **Pipeline:** `manual` (never applied by the universal pipeline)
- **Purpose:** the things every other root depends on and that cannot depend on anything: Terraform state storage
  (`tfstate`, `contracts`, `plans`, `deployments`, `packages`, `evidence` containers), the pipeline identities (`plan`,
  `apply`, `build`, `validate`) with workload identity federation for Azure DevOps, and (optional) the Entra app
  registration for the Datadog Azure integration.
- **Consumes:** nothing (phase-2 private endpoint values are copied by hand from the `foundation-network` contract).
- **Produces:** `bootstrap` v1 ([schema](../catalog/contracts/bootstrap.v1.schema.json)) + output `backend_config`.
- **Status:** implemented (validate + mock tests + checkov). Not deployed.

## What gets created

| Resource | Details |
|---|---|
| Resource group | `<prefix>-rg-tfstate-<env>-<region>` |
| Storage account | `module.naming.unique.storage` (e.g. `ehsttfstatedev<5hex>`), StorageV2 Standard **ZRS** (`replication_type`), TLS 1.2, HTTPS only, `shared_access_key_enabled = false`, `default_to_oauth_authentication = true`, infrastructure (double) encryption, no public blobs, no local users/SFTP, no cross-tenant replication; blob **versioning**, **change feed** (90 d), blob soft delete 30 d, container soft delete 30 d; firewall default **Deny**, bypass AzureServices/Logging/Metrics, `operator_ip_ranges`, `agent_subnet_ids`; `lifecycle.prevent_destroy`; management lock **CanNotDelete** |
| Containers | `tfstate`, `contracts`, `plans`, `deployments`, `packages` (immutable zip/static packages by sha256), `evidence` (private, `prevent_destroy`) |
| Private endpoint (phase 2) | `blob` PE in `private-endpoints` + `privatelink.blob.core.windows.net` (via `foundation/modules/private-endpoint`) |
| Identities | user-assigned `…-id-pipeline-{plan,apply,build,validate}-…` + federated credentials |
| Datadog app (optional) | `azuread_application` + service principal + federated credential (Secretless Auth) + Monitoring Reader |

## Pipeline identities and least privilege

| Identity | Azure RBAC | Data plane (containers) | Used by |
|---|---|---|---|
| `plan` | **Reader** (subscription) (+ `plan_extra_role_names`) | `tfstate` Blob Data **Contributor** (blob lease = state lock; Reader cannot lock), `contracts` Reader, `deployments` **Contributor** (no-change plans write their own deployment record), `plans` Contributor (writes the plan file), `evidence` Contributor (evidence stage upload) | plan, select and evidence stages |
| `apply` | **Contributor** + **Role Based Access Control Administrator with ABAC condition** + Resource Policy Contributor | Blob Data Contributor on all six containers | apply stages |
| `build` | none at subscription scope (AcrPush is granted by platform-shared on the registry) | `packages` Contributor (uploads zip/static packages by sha256), `deployments` Reader (artifact reuse lookups) | build stage |
| `validate` | **none** | none | nothing in Azure — see below |
| operators (`operator_principal_ids`) | (their own) | `tfstate` + `contracts` Contributor | first-run migration, break-glass |

*Why RBAC Administrator rather than User Access Administrator:* platform roots must create role assignments (AcrPull,
SQL/Cosmos/Service Bus data roles, Network Contributor for AKS/ARO/MDP). RBAC Administrator only
has `roleAssignments/write|delete` (+ read), and the condition (version 2.0, from Microsoft's
[delegation examples](https://learn.microsoft.com/azure/role-based-access-control/delegate-role-assignments-examples))
forbids assigning or removing **Owner**, **User Access Administrator** and **RBAC Administrator** — so the apply identity
cannot escalate itself. `apply_rbac_mode = "allowlist"` switches to an explicit allowlist of role GUIDs
(`ForAnyOfAnyValues:GuidEquals`) for stricter environments. Contributor cannot write policy assignments, hence
Resource Policy Contributor (`apply_policy_contributor`) for `foundation-governance`.

*Plans are sensitive:* ADR §4 says `plans` is restricted to the apply identity; in practice the plan stage must *write* the
plan file, so `plan` has Contributor on `plans` and `apply` reads it. `validate` and humans (except operators) have no access.

*Plan identity and listKeys:* some resources call `listKeys` during refresh (e.g. Service Bus/Event Hubs authorization rules,
Cosmos DB keys, Redis access keys). Reader cannot; if a root's plan fails with `AuthorizationFailed ... listKeys`, prefer
Entra-only auth on that resource; otherwise add a narrowly scoped custom role via `plan_extra_role_names` (documented per root).

*Untrusted PR validation* runs `terraform fmt/validate/test` (mock providers) on **Microsoft-hosted agents without any
service connection** — no Azure credentials exist in that job. The `validate` identity exists only so a trusted
"validate with real provider schemas" job can authenticate without rights; it has **zero** role assignments (tested).

### Federated credentials (Azure DevOps workload identity federation)

Verified on Microsoft Learn 2026-10-09 ([troubleshooting table](https://learn.microsoft.com/azure/devops/pipelines/release/troubleshoot-workload-identity#check-the-issuer-url-for-accuracy)):

| | Azure DevOps issuer (**deprecated, retires 2027-07-01**) | Microsoft Entra issuer (default for new connections) |
|---|---|---|
| Issuer | `https://vstoken.dev.azure.com/<organization-id>` | `https://login.microsoftonline.com/<tenant-id>/v2.0` |
| Subject | `sc://<organization>/<project>/<service-connection>` | `<entra-prefix>/sc/<organization-id>/<service-connection-id>` |
| Audience | `api://AzureADTokenExchange` | `api://AzureADTokenExchange` |

Create the service connection as *Azure Resource Manager → App registration or Managed identity (manual) → Workload
identity federation*, "Keep as draft", copy **Issuer** and **Subject identifier** into `settings.federated_credentials`
(`identity = plan|apply|build`), apply bootstrap, then "Verify and save". Use one service connection per identity
(e.g. `sc-eh-dev-plan`, `sc-eh-dev-apply`, `sc-eh-dev-build`), authorize pipelines individually (never "grant access to all pipelines"), and
protect the apply connection with an environment approval. `azure_devops_legacy` generates the deprecated-issuer form
only for connections not yet converted.

## Datadog Azure integration app registration (optional)

`datadog_integration.enabled = true` creates the app registration + service principal and grants **Monitoring Reader** on
the lab subscription (+ `extra_subscription_ids`). Finding (Datadog docs, [manual setup](https://docs.datadoghq.com/integrations/guide/azure-manual-setup/),
checked 2026-10-09): Datadog supports **Secretless Auth** — an Entra federated identity credential trusting Datadog's OIDC
issuer (audience `api://AzureADTokenExchange`), marked *recommended*, requires azuread provider ≥ 3.7.0 (we pin `~> 3.10`;
3.10.0 published 2026-09-24). Copy issuer + subject from the Datadog Azure integration tile into
`federated_issuer`/`federated_subject`; Datadog's side (`datadog_integration_azure` with `secretless_auth_enabled = true`,
`client_id`/`tenant_name` from this contract) is owned by `obs-azure-integration`.
Secretless Auth is not available on US1-FED/US2-FED or sovereign clouds. There, create the secret **out of band** so it
never enters Terraform state, straight into Delinea DSV (ADR-0001 section 14; path `<prefix>/<env>/datadog-azure-client-secret`):

```bash
APP_ID=$(terraform output -json contract | jq -r .datadog_integration.client_id)
az ad app credential reset --id "$APP_ID" --display-name datadog --years 1 --query password -o tsv \
  | (read -r s; printf '{"value":"%s"}' "$s" > /dev/shm/dd.json; chmod 600 /dev/shm/dd.json
     dsv secret create --path eh/dev/datadog-azure-client-secret --data @/dev/shm/dd.json >/dev/null; rm -f /dev/shm/dd.json)
```

## Delinea DSV prerequisites (all keys and secrets)

All lab keys and secrets live in **Delinea DevOps Secrets Vault** (ADR-0001 section 14); Azure Key Vault is not used for
secrets. Workloads and pipelines authenticate to DSV with their own **user-assigned managed identity** (Azure auth
provider: the Entra token's `xms_mirid` = identity resource id is matched to a DSV user's `externalId`), so no bootstrap
secret exists anywhere. One-time operator steps per environment (DSV CLI `dsv`, signed in as a DSV administrator):

1. **Tenant.** A DSV tenant `<tenant>.secretsvaultcloud.<tld>` (tld `com`, `eu`, `com.au`, `ca`). Put its name in
   `environments/<env>/environment.yaml` → `secrets: {provider: delinea-dsv, tenant, tld, auth_provider}` and the same
   identifiers in `pipelines/variables/<env>.yml` (`dsvTenant`, `dsvTld`, `dsvAuthProvider`; lint checks they match).
2. **Azure auth provider** (name = `secrets.auth_provider`, e.g. `azure-eh`) bound to the lab's Entra tenant:
   `dsv config auth-provider create --name azure-eh --type azure --azure-tenant-id <environment.tenant_id>`.
   (`foundation-secrets` verifies it and would create it if missing, but the admin mapping in step 3 needs it first.)
3. **Pipeline admin mapping (the only manual mapping).** After `foundation-identity` is applied, map the
   `deploy-agent` identity (contract `identities.deploy-agent.id`) to a DSV user and give that user DSV administration
   rights for this environment's objects (users, `config:auth`, `config:policies:secrets:<prefix>:<env>`, and
   `secrets:<prefix>:<env>:<.*>`):
   ```bash
   dsv user create --username <prefix>-<env>-deploy-agent --provider azure-eh \
     --external-id /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/<prefix>-id-deploy-agent-<env>-<region>
   dsv config edit --encoding yaml   # add the subject below to the administrative policy, e.g. the Default Admin Policy
   #   subjects: [..., 'users:<azure-eh:<prefix>-<env>-deploy-agent>']
   ```
   This is exactly Delinea's documented Azure flow ("Authentication: Azure"); Delinea notes that the Default Admin
   Policy is broad, so prefer a dedicated admin policy limited to `users`, `config:auth:<azure-eh>`,
   `config:policies:secrets:<prefix>:<env>` and `secrets:<prefix>:<env>:<.*>` if your tenant has one.
   The username must be exactly `<prefix>-<env>-deploy-agent`: `foundation-secrets` then recognises it as the same user
   (it never modifies or deletes users it did not create). `tools/secrets/dsv_apply.py` (plan stage = diff, apply stage
   = converge) runs with this identity on the self-hosted deploy pool and creates every other DSV user and the
   least-privilege permissions. Narrow or extend the admin policy to your tenant's conventions; DSV validates policy
   resources against the policy path (Delinea "Policy" docs).
4. **Seed the operator-owned values** listed in [`foundation/identity/secrets.yaml`](../foundation/identity/secrets.yaml)
   (`source: operator`): `datadog-api-key`, `datadog-app-key`, `datadog-client-token`, `fault-token`,
   `fluentbit-shared-key`, the adapter/DBM passwords of enabled engines and the platform apply inputs
   (`sqlvm-admin-password`, `documentdb-admin-password`, `cassandra-mi-admin-password`, optional
   `mysql-admin-password`, `appgw-tls-pfx`, `aro-pull-secret`). Element `value` (plus `password` for `appgw-tls-pfx`):
   ```bash
   umask 077; printf '{"value":"%s"}' "$(openssl rand -base64 36)" > /dev/shm/v.json
   dsv secret create --path <prefix>/<env>/fault-token --data @/dev/shm/v.json; rm -f /dev/shm/v.json
   ```
   `python3 tools/secrets/check.py --env <env>` lists what is still missing (names only, never values); the pipeline
   runs it after `foundation-secrets` and in the Verify stage. Generated values (`eventhub-fluentbit-listen`) are
   written by `tools/secrets/publish.py` after `obs-telemetry-transport` applies.
5. **Egress.** Every reader needs HTTPS to `<tenant>.secretsvaultcloud.<tld>` (the Azure Firewall default allow-list of
   `foundation-edge` includes `*.secretsvaultcloud.*`; NAT-only spokes reach it directly).

Rotation and break-glass: [docs/runbooks/secret-rotation.md](../docs/runbooks/secret-rotation.md).

## First run (local state → migrate)

Prerequisites: `az` ≥ 2.60, terraform ≥ 1.14, python3 + pyyaml, jq, curl; **Owner** (or Contributor + RBAC Administrator +
Resource Policy Contributor) on the subscription; Entra rights to create app registrations if Datadog is enabled.

1. In `environments/<env>/environment.yaml` set real `subscription_id`/`tenant_id` and add:
   ```yaml
   components:
     bootstrap:
       operator_ip_ranges: ["203.0.113.10"]          # your public IP
       operator_principal_ids: ["<your group object id>"]
       federated_credentials: []                     # fill after creating the draft service connections (step 4)
   ```
2. `az login --tenant <tenant-id>` then `bootstrap/scripts/bootstrap.sh --env <env>`. The script:
   checks login/subscription/tenant, registers resource providers, renders `bootstrap/terraform.tfvars.json`,
   writes a temporary `backend_override.tf` (`backend "local"`), `terraform init` + plan + (confirm) apply with local state,
   waits for data-plane RBAC, deletes the override and runs
   `terraform init -migrate-state -force-copy -backend-config=resource_group_name=… -backend-config=storage_account_name=… -backend-config=container_name=tfstate -backend-config=key=<env>/bootstrap.tfstate -backend-config=use_azuread_auth=true`,
   verifies the blob exists, renames the local state file to `bootstrap.local.tfstate.migrated-<ts>` and runs a drift check.
3. Delete the `.migrated-*` file once `terraform plan` is clean (it contains state).
4. Create the draft service connections, put their issuer/subject into `federated_credentials`, re-run the script
   (it now finds the state blob and uses the azurerm backend directly), then "Verify and save" in Azure DevOps.
5. Every other root initialises with `terraform output -json backend_config` values + `key=<env>/<component>.tfstate`.

Re-running the script is idempotent: provider registration skips registered namespaces; an existing state blob means
"init remote + plan + confirm apply".

## Network phases of the state account

| Phase | Settings | Who can reach state |
|---|---|---|
| 1 (bootstrap, hosted agents) | `public_network_access = "Enabled"`, firewall Deny, `operator_ip_ranges` (+ temporary hosted-agent IPs) | listed IPs |
| 1b (private agents exist) | + `agent_subnet_ids = [deploy-agents subnet id]` (service endpoint `Microsoft.Storage`), remove temporary IPs | listed IPs + agent subnet |
| 2 (private only) | `private_endpoint = {subnet_id, private_dns_zone_id}` + `public_network_access = "Disabled"` (validation requires the PE) | VNet only (agents, Bastion) |

## Break-glass

**Restore a corrupted/deleted state file (blob versioning + soft delete):**
```bash
SA=<state account>; KEY=<env>/<component>.tfstate
az storage blob list --auth-mode login --account-name $SA -c tfstate --prefix "$KEY" --include v d \
  --query "[].{version:versionId, current:isCurrentVersion, deleted:deleted, modified:properties.lastModified}" -o table
# deleted blob: undelete first (restores soft-deleted versions)
az storage blob undelete --auth-mode login --account-name $SA -c tfstate -n "$KEY"
# promote a previous version to current (server-side copy of that version onto the base blob)
az storage blob copy start --auth-mode login --account-name $SA -c tfstate -b "$KEY" \
  --source-uri "https://$SA.blob.core.windows.net/tfstate/$KEY?versionId=<versionId>"
terraform plan   # in the component root: confirm the restored state matches reality
```
A deleted container is restored with `az storage container restore --name tfstate --deleted-version <v>` within 30 days.

**Stuck state lock (blob lease):** first make sure no pipeline run is active, then
`terraform force-unlock <lock-id>` (lock ID from the error) or, if Terraform cannot, break the lease directly:
`az storage blob lease break --auth-mode login --account-name $SA -c tfstate -b "$KEY"`.

**Emergency local apply (pipeline/agents unavailable):** from an operator host that can reach the account (IP in
`operator_ip_ranges`, or temporarily `public_network_access = Enabled` via `az storage account update --public-network-access Enabled`
and re-apply bootstrap afterwards to restore the declared state):
```bash
cd <root>; az login
terraform init -reconfigure -backend-config=resource_group_name=<rg> -backend-config=storage_account_name=$SA \
  -backend-config=container_name=tfstate -backend-config=key=<env>/<component>.tfstate -backend-config=use_azuread_auth=true
terraform plan -out=emergency.tfplan && terraform apply emergency.tfplan
```
Record what was done in `evidence/` and re-run the pipeline afterwards to re-establish provenance.

**Bootstrap state lost but resources exist:** re-run with local state and `terraform import` the resource group,
storage account, containers, lock, identities and role assignments before applying (never let it create duplicates).

**Removing the state account (full teardown only):** delete the management lock (`az lock delete`), set
`lock_enabled = false`, remove `prevent_destroy` in a local branch, `terraform destroy`. Soft-deleted blobs/containers
remain recoverable for 30 days unless purged.

## Settings (`components.bootstrap`)

`replication_type` (ZRS), `public_network_access` (Enabled), `operator_ip_ranges`, `agent_subnet_ids`, `private_endpoint`,
`blob_soft_delete_days` (30), `container_soft_delete_days` (30), `change_feed_retention_days` (90), `lock_enabled` (true),
`operator_principal_ids`, `create_validate_identity` (true), `federated_credentials`, `azure_devops_legacy`,
`apply_rbac_mode` (constrained), `apply_role_allowlist`, `apply_policy_contributor` (true), `plan_extra_role_names`,
`datadog_integration.{enabled, display_name, owners, federated_issuer, federated_subject, extra_subscription_ids}`.

## Cost at defaults

≈ USD 1–3/month: a few MB of ZRS hot blobs + versions + change feed + transactions; identities, RBAC and the lock are free.
Phase 2 adds a private endpoint (≈ 7.3/month).

## Known limitations

- State account names come from the naming module (subscription hash suffix); changing `name_prefix` or environment name
  means a new account and a state migration.
- Checkov skips (documented inline): CMK (CKV2_AZURE_1), queue logging (CKV_AZURE_33), private endpoint in phase 1
  (CKV2_AZURE_33), public network in phase 1 (CKV_AZURE_59), SAS expiry with keys disabled (CKV2_AZURE_41), replication
  variable (CKV_AZURE_206), blob read logging owned by observability diagnostics (CKV2_AZURE_21), GitHub OIDC check on the
  Datadog credential (CKV_AZURE_249).

## Validation

```bash
tools/validate/terraform.sh bootstrap   # fmt, init -backend=false, validate, terraform test (mock providers, no credentials)
```

## References

- Terraform azurerm backend: https://developer.hashicorp.com/terraform/language/backend/azurerm
- Workload identity service connections: https://learn.microsoft.com/azure/devops/pipelines/release/configure-workload-identity
- Blob versioning restore: https://learn.microsoft.com/azure/storage/blobs/versioning-overview
- Delegated role assignment conditions: https://learn.microsoft.com/azure/role-based-access-control/delegate-role-assignments-overview
- Datadog Azure manual setup / Secretless Auth: https://docs.datadoghq.com/integrations/guide/azure-manual-setup/
- Delinea DSV Azure authentication: https://docs.delinea.com/dsv/current/usage/auth-general/authazure
- Delinea DSV policies: https://docs.delinea.com/online-help/devops-secrets-vault/tutorials/policy.htm

### Promotion readers (multi-environment)

When `environments/promotion.yaml` promotes artifacts from this environment to a downstream one, list the downstream
environment's pipeline identity principal ids in `settings.promotion_reader_principal_ids`: they get **Storage Blob Data
Reader** on `deployments` and `packages` only. Image import by digest additionally needs `AcrPull` on this
environment's registry: set `platform-shared` `settings.acr_pull_principal_ids` to the same principal ids.
