# deploy-specialized — Service Fabric, ARO, confidential VM, Automation

- **Owner**: applications layer. **Status**: implemented (mock tests); SF/ARO deploy scripts syntax-checked only.
- **Service Fabric managed cluster** — `hello-inventory-api` guest executable. azurerm 5.9 has **no** Service Fabric
  application/application-type resources, so Terraform renders `ApplicationManifest.xml` / `ServiceManifest.xml` (env vars,
  endpoint port from platform-servicefabric `app_port`) into the contract and `scripts/deploy-sf.sh` uploads/provisions/
  upgrades with `sfctl` (monitored upgrade, FailureAction=Rollback). The cluster admin client certificate is fetched by the
  pipeline at deploy time (not in state).
- **ARO** — `hello-catalog-api` Deployment/Service/Route manifests rendered into the contract (`aro.manifests`); applied by
  `scripts/deploy-aro.sh` (`oc apply`, rollout status). PG/Redis env comes from `settings.aro_catalog_env`.
- **Confidential VM** — `hello-worker` via managed run command (`install-hello-worker-cvm`, same `vm-script` as vm-workloads).
- **Automation** — `azurerm_automation_runbook` `hello-health-probe` (`Python3`, stdlib-only script in `templates/health-probe.py`)
  + `azurerm_automation_job_schedule` on the platform schedule with `probe_urls`.
- **Consumed contracts**: obs-telemetry-transport; optional platform-servicefabric, platform-aro, platform-specialized-compute;
  also optional foundation-identity, platform-messaging, platform-db-table-storage (**not in components.yaml — requested**;
  without foundation-identity the CVM worker is `blocked`).
- **Produced contract**: `deploy-specialized`: `service_fabric`, `aro`, `apps`, `status`.

## Rollback
SF: `sfctl application upgrade` to the previous type version (auto-rollback on health failure). ARO: `oc rollout undo` or
re-apply previous digest. CVM: previous package. Runbook: previous commit.

## Cost
No billable resources of its own beyond the runbook (Automation free minutes cover an hourly probe).

Docs: https://learn.microsoft.com/azure/service-fabric/service-fabric-guest-executables-introduction , https://learn.microsoft.com/azure/openshift/ ,
https://learn.microsoft.com/azure/automation/automation-runbook-types
