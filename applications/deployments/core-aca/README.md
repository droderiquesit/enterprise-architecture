# deploy-core-aca — core services on Azure Container Apps

- **Owner**: applications layer. **Status**: implemented (static validation + mock tests only).
- **Purpose**: minimal-profile journey on Container Apps: `hello-bff` (external ingress when
  `platform-containerapps.ingress_mode = external`, else internal), `hello-orders-api`, `hello-catalog-api` (internal).
- **Consumed contracts**: platform-containerapps, platform-shared (ACR), platform-messaging, platform-db-sql (`orders`),
  platform-db-postgresql (`catalog`), obs-telemetry-transport, foundation-identity; optional platform-db-redis
  (catalog cache; absent ⇒ `REDIS_AUTH=none`, cache bypass).
- **Produced contract**: `deploy-core-aca` (`catalog/contracts/deploy-core-aca.v1.schema.json`): `apps.<svc>.{id,url,...}`,
  `public_api.origin` (consumed by deploy-frontend/deploy-jobs), `endpoints`, `idle_behavior`, `apps.<svc>.revision_suffix`.
- **Resources**: resource group, 3 × `azurerm_container_app` (module `container-app`), each with user-assigned
  identity, ACR pull by identity, Key Vault secret refs (`fault-token`, Datadog API key for the sidecar), Fluent Bit
  sidecar + EmptyDir, startup/liveness `/healthz`, readiness `/readyz`, HTTP concurrency scale rule.

## App settings (owned here)
| Service | Settings |
|---|---|
| all | `DD_ENV/SERVICE/VERSION`, `OTEL_*` (gateway, `http/protobuf`), `LOG_FILE_PATH=/var/log/app/app.log`, `LOG_LEVEL`, `PORT=8080`, `AZURE_CLIENT_ID`, `FAULTS_ENABLED` (false), `FAULT_TOKEN` (Key Vault ref), `GIT_COMMIT` |
| hello-bff | `CATALOG_API_URL`, `ORDERS_API_URL` (internal FQDNs), `INVENTORY_API_URL` (setting), `ADAPTERS_JSON`, `CORS_ALLOWED_ORIGINS`, `AUTH_MODE` (+ `ENTRA_*`) |
| hello-orders-api | `SQL_CONNECTION_STRING` (no password, no `Authentication=`), `SQL_USE_AZURE_CREDENTIAL=true`, `CATALOG_API_URL`, `MESSAGING_MODE=servicebus`, `SERVICEBUS_FQDN`, `SERVICEBUS_TOPIC` |
| hello-catalog-api | `PG_HOST/PORT/DATABASE`, `PG_USER=hello-catalog-api`, `PG_AUTH=entra`, `REDIS_HOST/PORT/AUTH`, `CACHE_TTL_SECONDS`, `AZURE_CREDENTIAL_MODE=managed_identity` |

## Settings (`components.deploy-core-aca`)
`faults_enabled` (false), `log_level`, `trace_sample_ratio`, `replica_ceiling` (5), `apps.<svc>.{enabled,min_replicas (0),
max_replicas (3), cpu, memory, http_concurrency}`, `cors_allowed_origins`, `auth_mode`, `entra_audience`,
`inventory_api_url`, `adapters` (ADAPTERS_JSON; copy from deploy-dbadapters `adapters_json`), `revision_mode`
(Multiple), `traffic.<svc>.{latest_weight, previous_revision_suffix}`, `redis_cache_ttl_seconds`.

**Two-pass CORS**: the SWA hostname is known only after deploy-frontend (which consumes this contract). Set
`cors_allowed_origins = ["https://<swa host or custom domain>"]` after the first frontend deploy and re-apply.

## Rollback
Multiple revision mode; every template change creates revision `r<hash>` (contract `revision_suffix`). Roll back
with `traffic.<svc> = { latest_weight = 0, previous_revision_suffix = "<last good suffix>" }` (or canary 90/10)
and re-apply. Re-applying the previous image digest also works.

## Smoke
`scripts/smoke.sh --contract <contract>`: `/healthz`, `/readyz`, `/version` on each app URL (internal apps only from
inside the environment/VNet); `tools/smoke/smoke.py` uses `endpoints`.

## Cost (defaults, approx.)
Consumption profile, scale to zero: idle ≈ $0; active ≈ $0.000024/vCPU-s + $0.000003/GiB-s ⇒ ~3 apps × (0.75 vCPU incl.
sidecar) at 10% duty ≈ $15–20/month. No extra cost for revisions.

## Teardown / data
`terraform destroy` removes the apps and resource group; no data is stored here (data lives in platform databases).

## Networking
Apps live in the VNet-injected environment; only hello-bff may be external (environment `external` mode).
OTLP and Fluent Bit forward stay internal (gateway/aggregator internal ingress).

## Limitations
- Container Apps CORS needs explicit origins (no wildcards here).
- `FAULT_TOKEN` requires the app identities to read `fault-token` (foundation-identity grants it).

Docs: https://learn.microsoft.com/azure/container-apps/revisions , https://learn.microsoft.com/azure/container-apps/manage-secrets ,
https://learn.microsoft.com/azure/container-apps/health-probes
