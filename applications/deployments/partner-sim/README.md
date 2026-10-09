# deploy-partner-sim — hello-partner-sim on Azure Container Instances

- **Owner**: applications layer. **Status**: implemented (mock tests).
- **Resources**: resource group, `azurerm_container_group` (Linux, `ip_address_type = Private`, subnet `aci`,
  user-assigned identity `hello-partner-sim`, ACR pull with `image_registry_credential.user_assigned_identity_id`),
  app container + Fluent Bit sidecar sharing an `emptyDir` volume (`/var/log/app`, ADR §10), config files as secret
  volumes, liveness `/healthz` + readiness `/readyz`; `azurerm_private_dns_a_record` `partner-sim` in the lab internal zone.
- **Consumed contracts**: foundation-network (aci subnet, internal zone id), platform-shared, obs-telemetry-transport,
  foundation-identity.
- **Produced contract**: `deploy-partner-sim`: `url` (`http://partner-sim.<zone>:8080`), `container_group.{id,name,private_ip,dns_name}`, `apps`, `endpoints`.

## App settings
Common OTel/DD env (gateway), `LOG_FILE_PATH`, `LATENCY_MS_MEAN`, `PARTNER_FAILURE_RATE` (lab), `AZURE_CLIENT_ID`,
`AZURE_CREDENTIAL_MODE=managed_identity`, `FAULTS_ENABLED` (false). **Secrets** (Delinea DSV, ADR-0001 §14): no secret value
in this root, its plan or its state (the 1.x Key Vault data source and `secure_environment_variables` are gone).
`FAULT_TOKEN` is a plain env var holding its `dsv://` reference, resolved by the app at start-up with the group's
user-assigned identity (IMDS) - `DSV_*` env is set. The Fluent Bit sidecar's `DD_API_KEY` is written by a third
container, **dsv-fetch** (image `artifacts["img-dsv-fetch"]`), into the shared emptyDir `/dsv-secrets/fluentbit-env.yaml`
and refreshed hourly; it is a regular container because ACI init containers cannot use managed identities (Microsoft
Learn). Fluent Bit fails fast until the file exists and is restarted by `restart_policy = Always` (first start may
show one or two Fluent Bit restarts). `settings.resolve_secrets` was removed. ACI emptyDir is disk-backed (not tmpfs):
the file is 0400 and lives only as long as the container group.

## Rollback / smoke
Re-apply with the previous digest (the group is updated/recreated; single instance ⇒ brief outage). Smoke from the VNet:
`/healthz`, `/readyz`, `/version` on the private URL.

## Cost
0.75 vCPU / 1.5 GB always on ≈ $35/month (Linux ACI per-second pricing).

## Limitations
No TLS (private HTTP inside the spoke). Restart policy Always.

Docs: https://learn.microsoft.com/azure/container-instances/container-instances-vnet , https://learn.microsoft.com/azure/container-instances/using-azure-container-registry-mi ,
https://learn.microsoft.com/azure/container-instances/container-instances-volume-emptydir
