# modules/dbm

Renders Datadog **Database Monitoring** check configs for supported Azure engines and runs them from inside the
VNet.

| engine | deployment_type | auth |
|---|---|---|
| `postgres` | `flexible_server` | password (`ENC[...]`) or Entra managed identity (`azure.managed_authentication`) |
| `mysql` | `flexible_server` | password only. The MySQL DBM integration has no Entra managed-identity auth. |
| `sqlserver` | `sql_database` (one instance per database), `managed_instance`, `virtual_machine` | password or managed identity (`managed_identity.client_id`, ODBC Driver 18) |

Any other engine is rejected by validation. That includes Cosmos DB, MariaDB, Redis and Cassandra, which are
covered by integrations and APM, not DBM.

Every instance has:
* `dbm: true`
* `azure.deployment_type` + `azure.fully_qualified_domain_name`
* tags
* TLS (`ssl: require` for PostgreSQL; the CA bundle for MySQL; `Encrypt=yes;TrustServerCertificate=no` for SQL
  Server)
* PostgreSQL extras: `database_autodiscovery` and `collect_schemas`

Passwords are **never literal** and have one source: `password_ref = {kind = "dsv", name = "dsv://<path>#<element>"}`
renders `ENC[dsv://...]`, resolved by the Agent's `secret_backend_command` = the static dsv-fetch binary
(`agent-backend`, Delinea DSV with the managed / workload identity). `k8s_secret`, `file` and `env` references were
removed in observability 4.0.0 (they bypass DSV, and `ENC[file@]` / `ENC[k8s_secret@]` do not work with the dsv-fetch
backend anyway).

## Hosting
* `cluster_checks` (**default**; whenever a cluster exists): `cluster_check_confd` feeds `modules/kubernetes`
  (`cluster_checks`). The Cluster Agent dispatches the checks to the cluster-checks runners; their dsv-fetch secret
  backend resolves the `ENC[dsv://...]` passwords. Run the runners as the DBM identity
  (`modules/kubernetes` `dsv.cluster_checks_identity_client_id`, federated with `datadog/datadog-cluster-checks`): it
  reads the password paths in DSV and logs in to Entra-enabled databases - the Agent's PostgreSQL and SQL Server
  checks use `azure.identity.ManagedIdentityCredential(client_id)`, which uses AKS workload identity when
  `AZURE_FEDERATED_TOKEN_FILE` is set (azure-identity 1.25.3 in Agent 7.84.2, checked in the image; not verified live).
  The runners must reach the databases.
* `aci` (only when there is no cluster): `azurerm_container_group` running the fleet policy Agent image
  (`<agent.image>:<agent.version>`, e.g. `gcr.io/datadoghq/agent:7.84.2`; `aci.image` overrides), private IP in the
  given subnet (delegated to `Microsoft.ContainerInstance/containerGroups`), user-assigned identity.
  * Init container `dsv-fetch-install` (`aci.fetch_image`, digest-pinned dsv-fetch image >= 2.0.0) copies the static
    binary into the shared emptyDir `/eh/bin` (`dsv-fetch install`; no identity needed there - ACI init containers
    cannot use managed identities). The Agent container's start command re-installs it as root with mode 0500
    (`/eh/bin/dsv-fetch install --dest /opt/dsv-fetch/dsv-fetch`), copies the rendered `datadog.yaml` and check configs
    and runs `/bin/entrypoint.sh`. No Python involved.
  * `datadog.yaml`: `api_key: ENC[<aci.api_key_ref>]`, `secret_backend_command: /opt/dsv-fetch/dsv-fetch`,
    `secret_backend_arguments: [agent-backend, --config, /eh/dsv/dsv.json]`; `dsv.json` (DSV endpoint, identity client
    id - not secret) and the check configs come from ACI secret volumes that contain no secrets.
  * The image's init script requires a non-empty `DD_API_KEY`, so `DD_API_KEY=ENC[...]` is set and resolved.
  * **To verify on Azure**: that the non-root init container (distroless uid 65532) can write into the ACI emptyDir
    (Microsoft Learn documents it as writable by every container of the group; not verified for non-root users).
* `none`: render only (`confd`).

`contracts/` (submodule, pure): platform-db-* contracts (`dbm` blocks) -> `databases`; used by both lab roots so the
ACI (obs-dbm) and cluster-check (obs-kubernetes) paths render identical instances.

## SQL setup scripts (`sql/`, idempotent, from Datadog docs)
| File | Notes |
|---|---|
| `postgres-flexible.sql` + `postgres-flexible-per-database.sql` | psql `-v dd_password=` from Delinea DSV; `pg_monitor`; `datadog` schema; `explain_statement` |
| `postgres-flexible-entra.sql` | `pgaadauth_create_principal` |
| `mysql-flexible.sql` | `__DATADOG_PASSWORD__` substituted at execution; `explain_statement` procedure |
| `sqlserver-sql-database[-entra].sql` | `##MS_ServerStateReader##`, `##MS_DefinitionReader##` |
| `sqlserver-managed-instance[-entra].sql`, `sqlserver-virtual-machine.sql` | `CONNECT ANY DATABASE`, `VIEW SERVER STATE`, `VIEW ANY DEFINITION` |

Platform prerequisites, owned by the database platform roots: PostgreSQL `azure.extensions=PG_STAT_STATEMENTS`,
`pg_stat_statements.track=ALL`, `track_activity_query_size=4096`; MySQL `performance_schema=ON`.

## Local verification (`observability/tests/transport/test_dbm_local.py`, **locally-verified**)
1. Real PostgreSQL 17 and MySQL 8.4 containers run the SQL scripts twice, which shows they are idempotent.
2. The dsv-fetch image installs its binary into a shared directory (init container stand-in, non-root, read-only,
   no capabilities); Datadog Agent 7.84.2 runs the **rendered** ACI start command, `datadog.yaml` and check configs: API
   key and both passwords are `ENC[dsv://...]`, resolved by the binary against a mock DSV (`agent secret`: executable
   permissions OK, 3 secrets resolved).
3. Result: `can_connect` OK, 0 errors, and DBM event-platform payloads such as metadata samples.

Deviations from Azure: no TLS on the local servers; DSV auth with `client_credentials` against the mock instead of the
group's managed identity (IMDS).

References:
- https://docs.datadoghq.com/database_monitoring/setup_postgres/azure/
- https://docs.datadoghq.com/database_monitoring/setup_mysql/azure/
- https://docs.datadoghq.com/database_monitoring/setup_sql_server/azure/
- https://docs.datadoghq.com/database_monitoring/guide/managed_authentication/
- https://docs.datadoghq.com/agent/configuration/secrets-management/
- https://docs.datadoghq.com/containers/cluster_agent/clusterchecks/
