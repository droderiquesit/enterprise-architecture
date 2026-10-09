# hello-catalog-api

Product catalog for Enterprise Hello (Python 3.13, FastAPI). **Data boundary:** PostgreSQL database `catalog`,
schema `catalog` (table `catalog.products`, migrations in `catalog.schema_migrations`), plus Azure Managed Redis
cache-aside under key prefix `catalog:` (TTL 60 s; the cache is never a source of truth).

## Endpoints
| Method | Path | Notes |
|---|---|---|
| GET | `/products?limit=50&offset=0&category=` | `{"items":[Product], "count": n}` |
| GET | `/products/{sku}` | `Product`; header `X-Cache: HIT\|MISS\|BYPASS`; 404 problem+json |
| POST | `/products` | upsert by `sku` (`Idempotency-Key` optional, replay-safe) |
| POST | `/seed` | deterministic 20 products `SKU-0001..SKU-0020` (idempotent) |
| GET | `/healthz` `/readyz` `/version` | common contract; readiness checks PostgreSQL (+ migration) and Redis (Redis outage = degraded, reads BYPASS, unless `REDIS_REQUIRED=true`) |
| POST/GET/DELETE | `/admin/faults` | fault injection (`FAULTS_ENABLED=true` + `X-Fault-Token`) |

`Product` = `{sku, name, description, unit_price, price, currency, category, active, updated_at}` — `price` equals
`unit_price` (hello-orders-api reads `price`).

## Configuration
| Variable | Default | Purpose |
|---|---|---|
| `PG_HOST`, `PG_PORT`, `PG_DATABASE`, `PG_USER` | localhost, 5432, catalog, postgres | PostgreSQL Flexible Server |
| `PG_AUTH` | `password` | `entra` = Entra access token (scope `https://ossrdbms-aad.database.windows.net/.default`, identity `AZURE_CLIENT_ID`) used as the password for every new pooled connection; connections recycled after 50 min |
| `PG_PASSWORD` | – | local only |
| `PG_SSLMODE` | `require` | `disable` only for local containers |
| `PG_POOL_MIN/MAX`, `PG_CONNECT_TIMEOUT_SECONDS`, `PG_STATEMENT_TIMEOUT_MS` | 1/10, 5, 5000 | psycopg 3 async pool |
| `REDIS_HOST`, `REDIS_PORT` | unset (cache disabled), 10000 | Azure Managed Redis (TLS port 10000) |
| `REDIS_AUTH` | `entra` | `entra` (redis-entraid credential provider, token refreshed in background), `password`, `none` |
| `REDIS_TLS`, `REDIS_CLUSTER`, `REDIS_REQUIRED` | true, false, false | `REDIS_CLUSTER=true` for the OSS cluster policy |
| `CACHE_TTL_SECONDS`, `CACHE_PREFIX` | 60, `catalog:` | |
| `MIGRATE_ON_STARTUP`, `SEED_ON_STARTUP` | true, false | idempotent migration under `pg_advisory_xact_lock` |
| `CATALOG_STORAGE` | `postgres` | `memory` for local UI work / smoke tests |
| common | | `DD_ENV/DD_SERVICE/DD_VERSION`, `OTEL_*`, `LOG_LEVEL`, `LOG_FILE_PATH`, `FAULTS_ENABLED`, `FAULT_TOKEN`, `AZURE_CLIENT_ID`, `PORT` (8080) |

## Telemetry
JSON logs (sample: [`docs/sample-log.json`](docs/sample-log.json), captured from the container running against
real postgres:17-alpine + redis:7-alpine), OTel server spans (FastAPI), client spans for psycopg and redis,
metric `hello.catalog.cache.requests{cache.result}`. Datadog DBM is configured by the observability layer.

## Run & test
```bash
docker build -f services/catalog-api/Dockerfile -t hello-catalog-api:dev applications/      # context = applications/
docker run -p 8080:8080 -e CATALOG_STORAGE=memory hello-catalog-api:dev
pytest                       # unit (7)
pytest -m integration        # real postgres:17-alpine + redis:7-alpine containers (1 end-to-end test)
```
The Entra paths (PostgreSQL token auth, Managed Redis credential provider) are implemented but cannot be exercised
without Azure; status `implemented`, local password paths `locally-verified`.
