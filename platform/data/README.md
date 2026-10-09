# platform/data — databases and data stores

Owner: platform / data (principal data-platform engineer). Layer `platform`, domain `data`.
Every directory below is an independent Terraform root (ADR-0001 §12) with its own state key
`<env>/<component-id>.tfstate`, `contract` output and mocked `terraform test` suite. Status values follow
ADR-0001 §11; **nothing has been deployed or verified against Azure** (no credentials in the build sandbox).

| Root | Component / contract | Default | Data-plane auth | Private access | DBM block |
|---|---|---|---|---|---|
| `sql` | platform-db-sql | on | Entra-only (contained users via script) | PE `sqlServer` | yes (SQL DB; `fulfillment` excluded: serverless auto-pause) |
| `sqlmi` | platform-db-sqlmi | **disabled** | Entra-only | VNet (`sqlmi`) | yes (managed_instance) |
| `sqlvm` | platform-db-sqlvm | on | SQL login (secret ID) | NIC in `compute`, PRIVATE | yes (self-hosted, password) |
| `postgresql` | platform-db-postgresql | on | Entra-only | VNet (`postgres`) or PE | yes (flexible_server, Entra MI) |
| `mysql` | platform-db-mysql | on | Entra + native (DBM) | VNet (`mysql`) or PE | yes (native password) |
| `cosmos-nosql` | platform-db-cosmos-nosql | on | Entra RBAC, keys off | PE `Sql` | no |
| `cosmos-mongo` | platform-db-cosmos-mongo | on | **keys** (exception) | PE `MongoDB` | no |
| `cosmos-cassandra` | platform-db-cosmos-cassandra | on | **keys** (exception) | PE `Cassandra` | no |
| `cosmos-gremlin` | platform-db-cosmos-gremlin | on | **keys** (exception) | PE `Gremlin` | no |
| `cosmos-table` | platform-db-cosmos-table | on | Entra RBAC (AzAPI), keys off | PE `Table` | no |
| `documentdb` | platform-db-documentdb | on | Entra OIDC (+ native admin) | PE `MongoCluster` | no |
| `cassandra-mi` | platform-db-cassandra-mi | **disabled** | Cassandra native | VNet (`cassandra-mi`) | no |
| `redis` | platform-db-redis | on | Entra access policy, keys off | PE `redisEnterprise` | no |
| `table-storage` | platform-db-table-storage | on | Entra RBAC, shared key off | PE `table` | no |
| `ledger` | platform-db-ledger | on | Entra ledger roles | **none** (exception) | no |
| `horizondb` | platform-db-horizondb | **blocked** (preview) | Entra-only | PE once group ID known | no |
| `analytics` | platform-data-analytics | storage on; ADX/Search/Synapse off | Entra RBAC | PEs per store | no |

Shared code: `platform/modules/data-cosmos-account` (Cosmos account + capabilities + backup + PE) used by the five
`cosmos-*` roots; `foundation/modules/{naming,tags,private-endpoint}`.

## Ownership boundaries (ADR-0001 §3)
- Here: servers/accounts/clusters, logical databases/containers/keyspaces/tables where ARM manages them,
  private endpoints, data-plane RBAC for workload identities, Key Vault secrets this layer generates.
- Not here: diagnostic settings (obs-diagnostics), Datadog resources and DBM users (obs-dbm), app settings,
  business tables (application migrations). Each root's `contract.dbm` tells obs-dbm the engine, deployment
  type, auth mode, host/port, resource ID, Entra admin and database list.
- Post-apply grant scripts (run by the pipeline with an Entra admin token):
  `sql/scripts/grant-db-users.sql` (also used for SQL MI), `postgresql/scripts/grant-db-users.sql`,
  `postgresql/scripts/elastic-distribute.sql`, `mysql/scripts/grant-db-users.sql`,
  `cassandra-mi/scripts/create-keyspace.cql`. `sqlvm/scripts/init-adapter-db.ps1` runs via VM run command.

## Secrets
Contracts never contain secret values — only versionless Key Vault secret IDs. Generated passwords:
MySQL admin and HorizonDB admin are **ephemeral/write-only** (never in state); SQL VM, DocumentDB and
Cassandra MI admin passwords are `random_password` in state (the azurerm arguments have no write-only variant)
and are written write-only to the foundation Key Vault (apply identity needs *Key Vault Secrets Officer*).
Key-based Cosmos APIs (Mongo RU, Cassandra, Gremlin) expect operators to store keys out-of-band (root READMEs).

## AzAPI gaps (to add to catalog/provider-gaps.yaml)
| Resource type | API version | Root | Reason |
|---|---|---|---|
| `Microsoft.DocumentDB/databaseAccounts/tableRoleAssignments` | 2026-03-15 | cosmos-table | no azurerm resource for Table data-plane RBAC |
| `Microsoft.Sql/managedInstances` (pricingModel `Freemium`) | 2025-01-01 | sqlmi (free_offer only) | azurerm cannot set `pricingModel` |
| `Microsoft.HorizonDb/clusters`, `clusters/administrators` | 2026-05-01-preview | horizondb (disabled) | no azurerm support (preview); schema validation off (azapi 2.13 embeds 2026-01-20-preview only) |

## Validation
```bash
for d in platform/data/*/; do (cd $d && terraform init -backend=false && terraform validate && terraform test); done
python3 platform/data/tests/validate_contracts.py        # contract outputs vs catalog/contracts/*.schema.json + static policy
python3 platform/data/tests/gen_contract_schemas.py      # regenerate the contract schemas after contract changes
checkov -d platform/data --framework terraform           # every skip carries an inline justification
```
Mocked tests cannot catch Azure-side errors (quota, region/SKU availability, preview gating, API behaviour).
