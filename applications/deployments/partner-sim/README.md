# deploy-partner-sim — hello-partner-sim on Azure Container Instances

- **Owner**: applications layer. **Status**: implemented (mock tests).
- **Resources**: resource group, `azurerm_container_group` (Linux, `ip_address_type = Private`, subnet `aci`,
  user-assigned identity `hello-partner-sim`, ACR pull with `image_registry_credential.user_assigned_identity_id`),
  app container + **Datadog Agent sidecar** (observability 4.0.0, `modules/instrumentation` `aci_sidecar`): traces on
  `localhost:8126`, DogStatsD on `udp://localhost:8125`, and the app's JSON log file on the shared `app-logs` emptyDir
  (`/var/log/app`) tailed by the Agent and shipped to the Observability Pipelines Worker; Agent config files (non-secret)
  as a secret volume; init container `dsv-fetch-install`; liveness `/healthz` + readiness `/readyz` (app) and
  `agent health` (Agent); `azurerm_private_dns_a_record` `partner-sim` in the lab internal zone. With
  `log_pipeline = fluent_bit_direct` (fallback) a Fluent Bit sidecar + dsv-fetch refresher collect the logs and the
  Agent keeps traces / DogStatsD only.
- **Consumed contracts**: foundation-network (aci subnet, internal zone id), platform-shared, obs-telemetry-transport,
  foundation-identity.
- **Produced contract**: `deploy-partner-sim`: `url` (`http://partner-sim.<zone>:8080`), `container_group.{id,name,private_ip,dns_name}`, `apps`, `endpoints`.

## App settings
Common OTel/DD env (gateway), `LOG_FILE_PATH`, `LATENCY_MS_MEAN`, `PARTNER_FAILURE_RATE` (lab), `AZURE_CLIENT_ID`,
`AZURE_CREDENTIAL_MODE=managed_identity`, `FAULTS_ENABLED` (false). **Secrets** (Delinea DSV, ADR-0001 §14): no secret value
in this root, its plan or its state (the 1.x Key Vault data source and `secure_environment_variables` are gone).
`FAULT_TOKEN` is a plain env var holding its `dsv://` reference, resolved by the app at start-up with the group's
user-assigned identity (IMDS) - `DSV_*` env is set. The Agent sidecar's `api_key` (and `DD_API_KEY`) is the reference
`ENC[dsv://.../datadog-api-key#value]`, resolved by the Agent itself through its `secret_backend_command` - the
**dsv-fetch** static binary (image `artifacts["img-dsv-fetch"]`, 2.0.0), authenticating with the group's identity and
re-read hourly (`secret_refresh_interval`). ACI init containers cannot use managed identities (Microsoft Learn), so the
init container only copies the binary into the `dsv-bin` emptyDir; the Agent's start command installs it root-owned
0500 (Agent secret-backend permission check) and execs the image entrypoint. Fallback: the Fluent Bit sidecar's key is
written by a dsv-fetch refresher container (`init --refresh-seconds 3600`) into `/dsv-secrets/fluentbit-env.yaml` (ACI emptyDir
is disk-backed, file 0400, lives as long as the group). `settings.agent_sidecar = {image, cpu, memory_gb}` overrides
the Agent image (e.g. an ACR mirror) and sizing (default 0.25 vCPU / 0.5 GB); the Agent hostname is the group name.

## Rollback / smoke
Re-apply with the previous digest (the group is updated/recreated; single instance ⇒ brief outage). Smoke from the VNet:
`/healthz`, `/readyz`, `/version` on the private URL.

## Cost
App 0.5 vCPU / 1 GB + Agent sidecar 0.25 vCPU / 0.5 GB = 0.75 vCPU / 1.5 GB always on ≈ $35/month (Linux ACI
per-second pricing; the sidecar's share ≈ $11/month). Datadog: the group reports as one infrastructure host and, with
traces, one APM host (Datadog host-based billing) - see docs/guides/datadog-fleet-collection.md.

## Limitations
No TLS (private HTTP inside the spoke). Restart policy Always.

## Test
`bash tools/validate/terraform.sh applications/deployments/partner-sim` (fmt -check, init -backend=false, validate,
`terraform test` with mock providers: `tests/partner_sim.tftest.hcl`).

Docs: https://learn.microsoft.com/azure/container-instances/container-instances-vnet , https://learn.microsoft.com/azure/container-instances/using-azure-container-registry-mi ,
https://learn.microsoft.com/azure/container-instances/container-instances-volume-emptydir
