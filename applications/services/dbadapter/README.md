# hello-dbadapter

One codebase, one deployment per database family (`DB_FAMILY`). Every instance exposes the same small records API
so each Azure database service receives real, traced operations. Service name `hello-dbadapter-<family>`
(`DB_SERVICE_NAME` overrides `DD_SERVICE`). All SDKs are in one image but drivers are **imported lazily** — an
instance only loads its own family's module and SDK (asserted by a unit test).

## Endpoints
| Method | Path | Notes |
|---|---|---|
| POST | `/records` `{payload}` | 201 record; `Idempotency-Key` ⇒ deterministic id (uuid5) so a retried POST upserts |
| GET | `/records/{id}`, `/records?limit=20` | |
| PUT | `/records/{id}` `{payload}` | 405 for append-only families (ledger) |
| DELETE | `/records/{id}` | 204; 405 for append-only families |
| POST | `/roundtrip` | write → read → update → delete, `{family, ok, timings_ms{write,read,update,delete}, cache?}`; 502 when not ok |
| POST | `/seed?count=10` | deterministic ids (idempotent; ledger appends only missing entries) |
| GET | `/info`, `/healthz`, `/readyz`, `/version`, `/admin/faults` | |

## Families and drivers
| DB_FAMILY | SDK | Auth | Boundary | Local verification |
|---|---|---|---|---|
| `sql`, `sqlmi`, `sqlvm` | **mssql-python 1.15** (Microsoft's GA driver, bundles ODBC core; Entra modes built in) | `ActiveDirectoryMSI` + `UID=$AZURE_CLIENT_ID` (or SQL auth for SQL VM/local) | schema `adapter`, table `adapter.records` | integration: mssql/server:2022-latest |
| `postgresql`, `horizondb` | psycopg 3 async pool | Entra token as password (`PG_AUTH=entra`) | `adapter.records` (jsonb) | integration: postgres:17-alpine |
| `postgresql-elastic` | psycopg 3 | same | `adapter.records` distributed by `id` via `create_distributed_table` | integration: citusdata/citus:13.0 (distribution asserted) |
| `mysql` | PyMySQL + bounded pool | Entra token as password over TLS (`MYSQL_AUTH=entra`) | db `adapter`, table `records` | integration: mysql:8.4 |
| `cosmos-nosql` | azure-cosmos (async) | Entra RBAC (key only for emulator) | db `adapter` / container `records` (pk `/id`) | unit (fake) |
| `cosmos-mongo`, `documentdb` | pymongo AsyncMongoClient | RU: connection string (no Entra data plane) ; DocumentDB: `MONGO_AUTH=entra` = MONGODB-OIDC with Azure Identity callback | db `adapter` / collection `records` | integration: mongo:8 (wire stand-in) |
| `cosmos-cassandra`, `cassandra-mi` | cassandra-driver 3.30.1 (Apache, cp313 wheel w/ libev — works on 3.13, no fork needed) | username/password (account key / CQL role) | keyspace `adapter` | integration: cassandra:5.0 |
| `cosmos-gremlin` | gremlinpython (GraphSON v2, bindings only) | account key (no Entra on Gremlin wire) | graph `records` | unit (fake) |
| `cosmos-table`, `table-storage` | azure-data-tables (async) | Entra (or connection string) | table `adapterrecords` | integration: Azurite |
| `redis` | redis-py asyncio + redis-entraid | Entra | prefix `adapter:` TTL 300 s, eviction tolerated, roundtrip reports hit/miss | integration: redis:7-alpine |
| `ledger` | azure-confidentialledger | Entra | collection `adapter`, append-only | unit (fake) |
| `blob` | azure-storage-blob (async) | Entra | container `adapter`, `records/<id>.json` | integration: Azurite |
| `adls` | azure-storage-file-datalake (async) | Entra | filesystem `adapter`, `records/` | unit (fake; Azurite has no HNS) |
| `search` | azure-search-documents 12 (async) | Entra or key | index `adapter-records` | unit (fake) |
| `adx` | azure-kusto-data (+ azure-kusto-ingest for `ADX_WRITE_MODE=streaming`) | Entra | table `Records` as append-only version log (`arg_max`) | unit (fake) |
| `memory` | – | – | process memory | unit |

Each driver module's docstring lists its environment variables (e.g. `SQL_SERVER`, `PG_HOST`, `MONGO_URI`,
`CASSANDRA_CONTACT_POINTS`, `TABLES_ENDPOINT`, `LEDGER_ENDPOINT`, `SEARCH_ENDPOINT`, `ADX_CLUSTER_URI` ...).
Pin note: `azure-kusto-ingest` 6.0.4 (latest) pins `azure-storage-blob==12.26.0` exactly, so this service uses blob
12.26.0 and datalake 12.21.0 (newest compatible), not the newest storage SDKs.

## Telemetry
Server spans (FastAPI); client spans from psycopg/redis/pymongo/PyMySQL/azure-core instrumentation and manual
CLIENT spans (`db.system`, `db.operation.name`) for SDKs without OTel instrumentation (mssql-python, cassandra,
gremlin, kusto). Metric `hello.dbadapter.operation.duration{family,operation,outcome}`. `db_error` fault hook in
every driver.

## Run & test
```bash
docker run -p 8080:8080 -e DB_FAMILY=memory hello-dbadapter:dev
pytest                  # 30 unit tests (every driver against an SDK fake via a shared CRUD contract)
pytest -m integration   # 14 tests against real containers (see table)
```
The image installs `libltdl7 libkrb5-3 libgssapi-krb5-2` (mssql-python runtime libs); no msodbcsql needed.
