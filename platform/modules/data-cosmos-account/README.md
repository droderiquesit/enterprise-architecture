# platform/modules/data-cosmos-account

Shared **code** module (not a component) for the five Cosmos DB API roots (`platform/data/cosmos-{nosql,mongo,
cassandra,gremlin,table}`); each root owns its account (ADR-0001 §3 rule 1).

Creates one single-region account: API capability (`EnableMongo|EnableCassandra|EnableGremlin|EnableTable`, none for
NoSQL) + `EnableServerless` by default, TLS 1.2, **public network access disabled**, no trusted-service bypass, no key
metadata writes, continuous backup (7-day tier; `Periodic` for Cassandra), and optionally a private endpoint with the
API's Private Link group id (via `foundation/modules/private-endpoint`). Diagnostic settings belong to `obs-diagnostics`.

| Input | Default | Notes |
|---|---|---|
| `name`, `resource_group_name`, `location`, `tags` | — | name: 3-44 lowercase alphanumerics / hyphens |
| `api` | — | `nosql`, `mongo`, `cassandra`, `gremlin`, `table` |
| `capacity_mode` | `serverless` | `provisioned` allows `free_tier_enabled` |
| `local_authentication_enabled` | `false` | `true` only for APIs without Entra data-plane auth (Mongo RU, Cassandra, Gremlin; exceptions in the root READMEs) |
| `backup_type` | `Continuous` | `Periodic` (daily, 7 days, local redundancy) |
| `mongo_server_version`, `consistency_level` | `null`, `Session` | |
| `private_endpoint` | — | `{enabled, subnet_id, private_dns_zone_id, name}` |

Outputs: `id`, `name`, `kind`, `capabilities`, `document_endpoint`, `api_endpoint`, `api_host`, `api_port`,
`private_endpoint_group_id`, `private_endpoint_id`, `private_ip_address`.

Validation: `tools/validate/terraform.sh platform/modules/data-cosmos-account`; behaviour is asserted by the five
`cosmos-*` root tests.
