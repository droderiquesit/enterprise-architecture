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

Passwords are **never literal**:
* `ENC[dsv://<path>#<element>]` (`password_ref.kind = dsv`): resolved by the Agent's `secret_backend_command` =
  dsv-fetch `agent-backend` (Delinea DSV, managed / workload identity)
* `ENC[k8s_secret@ns/name/key]`
* `ENC[file@/path]`
* `%%env_X%%` (cluster checks only)

## Hosting
* `aci`: `azurerm_container_group` running `datadog/agent:7.84.2`, private IP in the given subnet (it must be
  delegated to `Microsoft.ContainerInstance/containerGroups`), with a user-assigned identity.
  * The container group holds **no secret values**. A rendered `datadog.yaml` carries
    `api_key: ENC[<aci.api_key_ref>]`, `secret_backend_command: /opt/dsv-fetch/dsv-fetch` and
    `secret_backend_arguments: [agent-backend, --config, /eh/dsv/dsv.json]`. `dsv_fetch.py` and the non-secret
    `dsv.json` (DSV endpoint, identity client id) are mounted from an ACI secret volume; the start command runs
    `dsv_fetch.py install --dest /opt/dsv-fetch/dsv-fetch --python /opt/datadog-agent/embedded/bin/python3` (root, 0500).
    No init container: ACI init containers cannot use managed identities (Microsoft Learn), the Agent container can
    (IMDS).
  * Check configs are mounted from ACI secret volumes, which contain no secrets, and copied into
    `/etc/datadog-agent` before `/bin/entrypoint.sh`.
  * The image's init script requires a non-empty `DD_API_KEY`, so `DD_API_KEY=ENC[...]` is set. The secret
    backend resolves it.
* `cluster_checks`: the `cluster_check_confd` and `helm_values_snippet` outputs feed `modules/kubernetes`
  (`cluster_checks`). The runners must reach the databases.
* `none`: render only (`confd`).

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
2. Datadog Agent 7.84.2 runs the **rendered** postgres.d / mysql.d configs and the **rendered** ACI `datadog.yaml`
   with the ACI start command: API key and both passwords are `ENC[dsv://...]`, resolved by dsv-fetch against a mock DSV
   (`agent secret`: executable permissions OK, 3 secrets resolved).
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
