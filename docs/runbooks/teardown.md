# Runbook: teardown

Remove lab components in **reverse dependency order**, through the pipeline wherever possible. Not executed against
Azure yet. Data deletion behaviour per component: [cost-and-lifecycle.md](../guides/cost-and-lifecycle.md#5-teardown-order-and-data-deletion).

## Option A - pipeline retire mode (preferred)

The pipeline never destroys anything implicitly. A component that has a deployment record but is no longer enabled is
reported `retire-pending`.

1. Remove the components from the environment: change `profile` / `custom_components`, or set
   `profile: custom` with an empty or reduced `custom_components`.
2. Approve each retirement in `environments/<env>/retirements.yaml` (schema `environments/schema/retirements.schema.json`):
   ```yaml
   retirements:
     - component: deploy-jobs
       confirm: deploy-jobs            # must repeat the id
       approved_by: lead@example.com
       reason: lab teardown
       change_ref: CHG-1234            # optional
   ```
3. Run the pipeline in `retire` mode. Selection marks entries `retire-scheduled`, or `retire-blocked` when an enabled
   component still depends on them. The **Retire** stage (environment `lab-<env>-retire`, separate approval group)
   runs `tools/deploy/retire.py`: for each scheduled component, consumers first, it checks out the commit recorded in its
   deployment record, renders config, materializes contracts, `terraform plan -destroy` + apply, deletes its published
   contract envelopes and writes record status `retired`. It stops at the first failure.
4. Repeat in waves until only foundation remains (each wave can only retire components nobody enabled still consumes).

Reverse dependency order (from `python3 -m tools.changeset graph`, layer 8 -> 0; artifact components `img-*` /
`svc-*` and `docs` have no Azure resources and are not retired):

```
8  obs-diagnostics, obs-monitoring
7  deploy-jobs
6  deploy-durable, deploy-frontend
5  deploy-core-aks
4  deploy-appservice, deploy-core-aca, deploy-dbadapters, deploy-functions, deploy-logicapps, deploy-partner-sim,
   deploy-specialized, deploy-vm-workloads, obs-dbm, obs-hosts, obs-kubernetes
3  obs-telemetry-transport
2  foundation-edge, platform-aks, platform-aro, platform-batch, platform-containerapps, platform-db-cassandra-mi,
   platform-db-documentdb, platform-db-sqlvm
1  foundation-deploy-agents, foundation-pr-reviewer, foundation-secrets, platform-* (data, messaging, functions,
   appservice, vm, vmss, shared, ...)
0  foundation-identity, foundation-network, foundation-governance (last), obs-prereqs, obs-azure-integration
   bootstrap (manual only)
```

Notes before specific waves:

* `foundation-edge` with a firewall: set network `egress = nat-gateway` and apply **before** retiring the firewall.
* `foundation-deploy-agents`: delete the Azure DevOps agent pool first; once agents are gone the pipeline needs the
  hosted-agent access of [bootstrap phase 1](../guides/prerequisites-and-bootstrap.md#5-before-private-agents-exist)
  (or break-glass local runs) to retire the remaining foundation components.
* Protected resource types (databases, storage, Key Vault, VNets, registries, clusters, identities ...) are checked by
  `tools/validate/plan_policy.py` on normal plans; retire runs destroy the approved component regardless of type.

## Option B - per-root `terraform destroy` (break-glass)

From an operator host that can reach the state account ([break-glass](break-glass.md)):

```bash
cd <root>
python3 tools/config/render.py --env <env> --component <id>                       # from the repo root
python3 tools/contracts/materialize.py --env <env> --component <id> --source https://<sa>.blob.core.windows.net/contracts
terraform init -reconfigure -backend-config=resource_group_name=<rg> -backend-config=storage_account_name=<sa> \
  -backend-config=container_name=tfstate -backend-config=key=<env>/<id>.tfstate -backend-config=use_azuread_auth=true
terraform plan -destroy -out destroy.tfplan && terraform apply destroy.tfplan
python3 tools/deploy/record.py write --env <env> --component <id> --status retired \
  --store https://<sa>.blob.core.windows.net/deployments --note "manual destroy <change ref>"
```

Same order as above. Disable the component in the profile in the same change, or the next deploy run recreates it.

## What is retained

| Item | Why | How to remove (full teardown only) |
|---|---|---|
| State storage account + containers (`tfstate`, `contracts`, `plans`, `deployments`, `evidence`, `packages`) | `prevent_destroy`, CanNotDelete lock, blob versioning + 30-day soft delete | bootstrap README "Removing the state account": delete the lock, `lock_enabled = false`, remove `prevent_destroy` locally, `terraform destroy`; soft-deleted blobs recoverable for 30 days unless purged |
| Delinea DSV objects | `foundation-secrets` destroy and `dsv_apply.py` never delete DSV users, permissions or secrets | after the environment is gone: `dsv user delete` for `<prefix>-<env>-*` users, remove the managed permissions (`dsv policy edit secrets:<prefix>:<env>`) and the secrets under `<prefix>/<env>/` |
| APIM v2 | soft-deleted 48 h | `az apim deletedservice purge` |
| Log Analytics workspace | soft delete 14 days | `az monitor log-analytics workspace delete --force` if needed |
| Deleted SQL databases | restorable from backup until the server is deleted | delete the server |
| Telemetry in Datadog | Datadog retention | not deleted by destroy |
| Policy compliance history | Azure Policy retention | - |
| Resource providers, provider features, quotas | subscription-level; never unregistered by this repo | manual |
| Entra app registration for Datadog (bootstrap) | owned by bootstrap | bootstrap destroy |

## Scoped cleanup (leftovers)

Use the lab tags, never name patterns: `foundation/governance/scripts/find-expired.sh` (scope `application =
enterprise-hello` and `repository = azure-enterprise-observability-lab`, `expires_on < now`) prints - never runs -
`az group delete` commands with `--print-delete-commands`. Review each before running. Resource-provider-managed
groups (`MC_*`, Container Apps / Functions infrastructure RGs, ARO cluster RG) are removed with their parent resource.
