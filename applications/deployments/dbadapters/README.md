# deploy-dbadapters — hello-dbadapter-<family>

- **Owner**: applications layer. **Status**: implemented (mock tests).
- **Purpose**: one adapter instance per DB family whose platform contract is present (optional producers) and enabled in
  settings; `DB_FAMILY=<family>`, `DD_SERVICE=DB_SERVICE_NAME=hello-dbadapter-<family>`, identity `hello-dbadapter`.
- **Hosting** (catalog/architecture-matrix.yaml; override per family with `settings.families.<f>.hosting`):

| Family | Default hosting | Config (drivers/*.py docstrings) |
|---|---|---|
| sql | ACA consumption | `SQL_SERVER`, `SQL_DATABASE=adapter`, `SQL_AUTH=entra` |
| sqlmi | ACA dedicated-d4 | same, MI FQDN |
| sqlvm | VMSS Uniform (CustomScript) | `SQL_AUTH=password`, `SQL_USER`, `SQL_PASSWORD` (`dsv://` reference in the env file, resolved by the adapter), `SQL_TRUST_SERVER_CERTIFICATE=yes` |
| postgresql / postgresql-elastic / horizondb | ACA | `PG_HOST/PORT/DATABASE`, `PG_USER=hello-dbadapter`, `PG_AUTH=entra` |
| mysql | App Service Linux code (zip) | `MYSQL_HOST/PORT/DATABASE/USER`, `MYSQL_AUTH=entra`, `MYSQL_SSL=true` |
| cosmos-nosql | ACA | `COSMOS_ENDPOINT`, `COSMOS_AUTH=entra` |
| cosmos-mongo | ACA | `MONGO_URI` (`dsv://` reference; RU API has no Entra data plane) |
| documentdb | ACA | `MONGO_URI=mongodb+srv://<host>/?...authMechanism=MONGODB-OIDC`, `MONGO_AUTH=entra` |
| cosmos-cassandra | ACA | contact point/port 10350, `CASSANDRA_USERNAME`, `CASSANDRA_PASSWORD` (`dsv://` reference), `CASSANDRA_LOCAL_DC` (region display name) |
| cassandra-mi | ACA | seed IPs, 9042, `CASSANDRA_PASSWORD` (`dsv://` reference), DC `dc1` |
| cosmos-gremlin | ACA | `GREMLIN_ENDPOINT`, `GREMLIN_KEY` (`dsv://` reference) |
| cosmos-table / table-storage | ACA | `TABLES_ENDPOINT`, `TABLES_AUTH=entra`, `TABLES_TABLE=adapterrecords` |
| redis | ACA dedicated-d4 | `REDIS_HOST/PORT=10000`, `REDIS_AUTH=entra`, `REDIS_PREFIX=adapter:` |
| ledger | ACA | `LEDGER_ENDPOINT`, `LEDGER_IDENTITY_URL` |
| blob / adls / search / adx | ACA | `*_ACCOUNT_URL` / `SEARCH_ENDPOINT` / `ADX_CLUSTER_URI`, Entra |

Fallbacks: dedicated profile absent ⇒ consumption; no Linux App Service plan ⇒ ACA; no uniform scale set ⇒ skipped
(reported in `contract.skipped`).

- **Consumed contracts**: platform-containerapps, platform-shared, obs-telemetry-transport, foundation-identity; optional
  platform-appservice, all platform-db-*, platform-data-analytics, **platform-vmss and foundation-network (not yet in
  catalog/components.yaml)**.
- **Produced contract**: `deploy-dbadapters`: `adapters.<family>.{id,url,hosting,...}`, `apps` (keyed by DD service),
  `skipped`, `adapters_json` (paste into deploy-core-* `settings.adapters` for the BFF `ADAPTERS_JSON`), `deploy_steps`.

## Rollback
ACA: re-apply previous digest (single revision). App Service: staging slot swap back. VMSS Uniform: previous package
version ⇒ model update + `az vmss update-instances` (upgrade policy Manual; deploy step `vmss-update-instances`).

## Cost
Consumption apps scale to zero (≈ $0 idle). dedicated-d4 profile is billed by platform-containerapps. mysql shares the P0v3 plan.

## Limitations
- sqlvm adapter on VMSS has no load balancer ⇒ `url = null` (monitoring presence_ref `adapters.sqlvm.url` stays absent).
- The adapter on the VMSS needs the scale set identity (`hello-dbadapter`) to be a DSV user with read on `sqlvm-dbadapter-password`.
- The dbadapter Container Apps run on a Dedicated workload profile: the Fluent Bit key is written by a dsv-fetch **refresher** container (init containers get no managed identity there).
- The mysql App Service startup builds a venv from the wheelhouse on first start (slow cold start).

Docs: https://learn.microsoft.com/azure/container-apps/workload-profiles-overview , https://learn.microsoft.com/azure/virtual-machines/extensions/custom-script-linux
