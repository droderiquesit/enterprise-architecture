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
`AZURE_CREDENTIAL_MODE=managed_identity`, `FAULTS_ENABLED` (false). **Secrets**: ACI has no Key Vault references, so
`FAULT_TOKEN` (app) and `DD_API_KEY` (sidecar) are read with `data.azurerm_key_vault_secret` at plan time and set as
`secure_environment_variables` (sensitive; stored only in the Entra-only, private state account). The plan identity
needs Key Vault Secrets User on those two secrets. `settings.resolve_secrets=false` disables this (no faults, sidecar
cannot ship). Both secrets must live in the foundation Key Vault (precondition).

## Rollback / smoke
Re-apply with the previous digest (the group is updated/recreated; single instance ⇒ brief outage). Smoke from the VNet:
`/healthz`, `/readyz`, `/version` on the private URL.

## Cost
0.75 vCPU / 1.5 GB always on ≈ $35/month (Linux ACI per-second pricing).

## Limitations
No TLS (private HTTP inside the spoke). Restart policy Always.

Docs: https://learn.microsoft.com/azure/container-instances/container-instances-vnet , https://learn.microsoft.com/azure/container-instances/using-azure-container-registry-mi ,
https://learn.microsoft.com/azure/container-instances/container-instances-volume-emptydir
