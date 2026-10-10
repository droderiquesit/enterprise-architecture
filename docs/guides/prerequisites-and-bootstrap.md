# Prerequisites and bootstrap

What must exist before the two pipelines (`lab-platform`, `lab-applications`) can run, and how the lab gets from "empty subscription" to "pipeline
on private agents". The authoritative procedure is [`bootstrap/README.md`](../../bootstrap/README.md); this page
collects the prerequisites from every layer. None of these steps has been executed from this repository.

## 1. Azure prerequisites

| Requirement | Why | Where it is used |
|---|---|---|
| Subscription with **Owner** (or Contributor + Role Based Access Control Administrator + Resource Policy Contributor) for the operator running bootstrap | bootstrap creates role assignments and the apply identity's constrained RBAC Administrator role | [`bootstrap/`](../../bootstrap/README.md) |
| Entra rights to create app registrations (only when `datadog_integration.enabled = true`) | Datadog Azure integration app + federated credential | bootstrap (azuread provider) |
| `az` >= 2.60, Terraform >= 1.14 (tested 1.16.5), python3 + pyyaml, jq | `bootstrap/scripts/bootstrap.sh` preflight | bootstrap |
| Your public IP in `components.bootstrap.operator_ip_ranges`, your (group) object ID in `operator_principal_ids` | state account firewall default Deny, data-plane RBAC for the migration | `environments/<env>/environment.yaml` |
| Region offering every enabled service | `dev` uses `swedencentral`; Static Web Apps is not offered there, so the SWA uses `swa_location` (default `westeurope`, ADR amendment) | catalog `availability.regions_checked` |

### Resource provider registrations

`bootstrap/scripts/bootstrap.sh` is the only place that registers providers (pipeline identities cannot; every root sets
`resource_provider_registrations = "none"`). It registers:

`Microsoft.Storage, Network, KeyVault (only for the optional Azure ML workspace / APIM), ManagedIdentity, Authorization, Insights, OperationalInsights, AlertsManagement,
Consumption, CostManagement, PolicyInsights, ResourceGraph, App, ContainerService, ContainerRegistry, ContainerInstance,
Web, Compute, Batch, ServiceFabric, RedHatOpenShift, DevOpsInfrastructure, DevCenter, Sql, DBforPostgreSQL, DBforMySQL,
DocumentDB, Cache, ConfidentialLedger, Kusto, Synapse, Search, ServiceBus, EventHub, EventGrid, Logic, ApiManagement, Cdn,
Automation, MachineLearningServices, DurableTask` (all `Microsoft.*`).

Not registered by the script (register yourself when needed): `Microsoft.HorizonDb` (preview access required,
[platform/data/horizondb](../../platform/data/horizondb/README.md)), `Microsoft.Datadog` (only for the Datadog native
resource mode of `observability/modules/azure-integration`), and the `Microsoft.Compute/EncryptionAtHost` feature
(only when `encryption_at_host` settings are enabled).

### Quotas to check before enabling a component

| Component | Quota / prerequisite (from `catalog/services/*.yaml` and root READMEs) |
|---|---|
| VM / VMSS / AKS / deploy agents | regional + per-family vCPU quota (Bsv2, Dsv5) |
| Container Apps | cores per environment; 15 environments per region per subscription (default); dedicated profile node quota |
| Functions Flex Consumption | regional Flex memory quota (default 512 GB per subscription per region) |
| Batch | Batch account per-region quota; dedicated/Spot core quota per account (often 0 by default - request) |
| ARO | 44 vCPUs of the chosen families (Standard DSv5) - default quota is not enough |
| SQL Managed Instance | regional vCore quota; delegated subnet /27 minimum |
| Managed Instance for Apache Cassandra | 3 nodes minimum per datacenter; D8s_v4/v5 vCPU quota |
| Confidential VM / GPU VM | DCasv5 / NCASv3_T4 quota is often 0 by default (support request) |
| Confidential Ledger | 2 standard ledgers per subscription |
| Azure VMware Solution | host quota via support request (cataloged, **blocked**) |

### Licensing

| Item | Default in this repo |
|---|---|
| Windows Server VMs | license included (PAYG); Azure Hybrid Benefit optional |
| SQL Server on VM | SQL Server 2022 **Developer** image (`sql2022-ws2022` / `sqldev-gen2`) - free, non-production only |
| SQL Managed Instance | `LicenseIncluded` (or `free_offer` via azapi, one per subscription) |
| ARO | OpenShift licence in the ARO price; Red Hat pull secret recommended |
| Datadog | one org/site per environment; the lab uses Infrastructure, APM, Log Management, RUM, Synthetics, DBM - each billed by Datadog per its own unit (RUM sessions, synthetic runs, DBM hosts, ingested/indexed logs) |
| Oracle Database@Azure, partner services | cataloged/blocked; Marketplace purchase and partner accounts required |

## 2. Azure DevOps prerequisites

From [`pipelines/README.md`](../../pipelines/README.md#one-time-azure-devops-setup-checklist):

* Project + Azure Repos repository with this code and **two pipelines**: `lab-platform` (`azure-pipelines.yml`, IaC
  platform + observability package release) and `lab-applications` (`azure-pipelines.applications.yml`, artifacts,
  Helm charts, application deployments; triggered by successful platform runs). Branch policy *Build validation* on
  `main` for **both** (Azure Repos ignores YAML `pr:`).
* Three ARM service connections with **workload identity federation**, one per bootstrap identity:
  `sc-lab-<env>-plan`, `sc-lab-<env>-apply`, `sc-lab-<env>-build`; names and ids in `pipelines/variables/<env>.yml`.
  Create them as *draft*, copy issuer (`https://login.microsoftonline.com/<tenant>/v2.0`) and subject into
  `components.bootstrap.federated_credentials`, re-run bootstrap, then *Verify and save*.
* Environments `lab-<env>` (approvals + exclusive lock) and `lab-<env>-retire` (approvals by a different group), for
  every environment of `environments/promotion.yaml` (dev, test, prod).
* *Required template* check (`pipelines/templates/universal.yml`) on the service connections, environments and the
  deploy agent pool.
* **No variable groups for secrets** (no Key Vault-linked groups, lint SEC001/PL015): every secret a step needs comes
  from Delinea DSV through `tools/secrets/fetch.py` on the self-hosted deploy pool, authenticated with the agents'
  `deploy-agent` managed identity. `pipelines/variables/<env>.yml` carries only identifiers (`dsvTenant`, `dsvTld`,
  `dsvAuthProvider`, equal to `environments/<env>/environment.yaml` `secrets`).
* Agent pool `foundation-deploy-agents` (created in Azure DevOps after `foundation-deploy-agents` applies; VMSS mode:
  *Agent pools -> Add pool -> Azure virtual machine scale set*).

## 3. Datadog prerequisites

* An organisation and site (`environment.yaml datadog.site`, default `datadoghq.com`).
* API key and application key, stored as Delinea DSV secrets `<prefix>/<env>/datadog-api-key` /
  `<prefix>/<env>/datadog-app-key` (names from `datadog.*_secret_name`) - set out-of-band, never in Terraform.
* For the Azure integration with Secretless Auth: issuer + subject from the Datadog Azure tile copied into
  `components.bootstrap.datadog_integration.{federated_issuer,federated_subject}`. Not available on US1-FED/US2-FED or
  sovereign clouds (client secret created out of band instead, see bootstrap README).
* A Datadog private location if synthetic tests must reach private endpoints (`obs-monitoring` setting
  `private_location_id`; not created by this repo).

## 3b. Delinea DevOps Secrets Vault prerequisites

All keys and secrets live in DSV (ADR-0001 section 14); Azure Key Vault is not used for secrets. Full steps:
[bootstrap/README.md "Delinea DSV prerequisites"](../../bootstrap/README.md#delinea-dsv-prerequisites-all-keys-and-secrets).

1. A DSV tenant (`<tenant>.secretsvaultcloud.<tld>`, tld `com`/`eu`/`com.au`/`ca`) and the dsv CLI for operators.
   Set `environments/<env>/environment.yaml` → `secrets: {provider: delinea-dsv, tenant, tld, auth_provider}` and the
   same identifiers in `pipelines/variables/<env>.yml`.
2. The **Azure auth provider** bound to the lab tenant:
   `dsv config auth-provider create --name azure-eh --type azure --azure-tenant-id <tenant-id>`.
3. After `foundation-identity` applies: the **one manual mapping** - DSV user `<prefix>-<env>-deploy-agent` (provider
   `azure-eh`, external id = the `deploy-agent` identity's resource id) with DSV administration rights. From then on the
   pipeline's `foundation-secrets` stage (`tools/secrets/dsv_apply.py`) creates every other user and permission.
4. Seed the operator-owned values (`foundation/identity/secrets.yaml`, `source: operator`), then
   `python3 tools/secrets/check.py --env <env>` (names only). Generated values (`eventhub-fluentbit-listen`, the Event
   Hubs listen connection string read by the Observability Pipelines Worker or, in `fluent_bit_direct` mode, the Fluent
   Bit aggregator) are written by the pipeline after `obs-telemetry-transport` applies.
5. Egress to `<tenant>.secretsvaultcloud.<tld>:443` from every subnet with readers (Azure Firewall default allow-list
   includes `*.secretsvaultcloud.*`).

## 4. Bootstrap sequence (local state first, then migrate)

```bash
az login --tenant <tenant-id>
bootstrap/scripts/bootstrap.sh --env dev            # --plan-only to preview, --skip-providers on re-runs
```

The script (idempotent): checks tools/login/subscription; registers providers; renders `bootstrap/terraform.tfvars.json`;
if `<env>/bootstrap.tfstate` does not exist yet it writes a temporary `backend_override.tf` (`backend "local"`), plans and
(after confirmation) applies with **local state**, waits for data-plane RBAC, removes the override and runs
`terraform init -migrate-state` into the new account, verifies the blob and renames the local state file to
`bootstrap.local.tfstate.migrated-<ts>`. Delete that file once `terraform plan` is clean - it contains state.
Re-runs use the azurerm backend directly.

Result: state account (versioning, soft delete, change feed, shared keys off, `prevent_destroy`, CanNotDelete lock) with
containers `tfstate`, `contracts`, `plans`, `deployments`, `evidence`, `packages`; identities `plan`, `apply`, `build`
(and `validate` with no roles); optional Datadog app registration.

## 5. Before private agents exist

Microsoft-hosted agents are outside the VNet and **cannot reach private endpoints** (diagram:
[foundation](../diagrams/README.md)). The order is therefore:

| Phase | State account network | Who runs | What can be deployed |
|---|---|---|---|
| 1 | public access Enabled, firewall Deny + `operator_ip_ranges` (+ temporary hosted-agent egress IP) | operator workstation; Microsoft-hosted agents with the temporary IP | `bootstrap`, `foundation-network`, `foundation-identity`, `foundation-governance`, `foundation-deploy-agents` (ARM + state blob only) |
| 1b | + `agent_subnet_ids = [deploy-agents subnet]` (service endpoint), temporary IPs removed | private agents (`deployPool`) | everything; set the pool in `pipelines/variables/<env>.yml` |
| 2 | `private_endpoint = {...}` + `public_network_access = "Disabled"` | VNet-connected agents / Bastion only | everything |

Notes:

* `foundation-identity` applies from hosted agents (management plane only). `foundation-secrets` and every component
  with DSV inputs (registry `secret_env`) need the self-hosted deploy pool: `fetch.py` / `dsv_apply.py` authenticate
  with the agents' managed identity (IMDS) - hosted agents have none. Setting secret values is done by operators with
  the dsv CLI from anywhere with access to the DSV tenant (public SaaS endpoint).
* The `minimal` profile has no private agents: ACR stays Standard (public endpoint, Entra-only) so hosted builds can
  push, AKS is not enabled, and roots that need data-plane access to private resources (Flex deployment container,
  SQL grant scripts) require an agent with VNet access - see [known limitations](../known-limitations.md#deployment-and-networking).
* PR validation always stays on Microsoft-hosted agents without any service connection.

## 6. After bootstrap

Continue with [quick-start.md](quick-start.md#phase-2---first-deployment-needs-azure-azure-devops-and-datadog) step 4.
