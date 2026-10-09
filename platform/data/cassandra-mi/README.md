# Azure Managed Instance for Apache Cassandra (platform-db-cassandra-mi)

- **Component id:** `platform-db-cassandra-mi` (catalog/components.yaml; catalog refs: `managed-cassandra`)
- **Owner:** platform / data (principal data-platform engineer). Layer `platform`, domain `data`.
- **Status:** `disabled` (ADR-0001 §11). Nothing here has been deployed or verified against Azure.

## Purpose
Cassandra 5.0 managed cluster + datacenter `dc1` (3 × `Standard_D8s_v4`, 1 P30 disk each) in the `cassandra-mi` subnet; keyspace `adapter` for hello-dbadapter-cassandra-mi (created over CQL by `scripts/create-keyspace.cql` — there is no ARM keyspace resource for Managed Instance). **Disabled by default (high cost).**

## Consumed contracts
| Contract | Fields used |
|---|---|
| `foundation-network` v1 | `resource_group_name`, `location`, `spoke_vnet_id`, `subnets[*].id`, `private_dns_zones[*].id` (each zone optional, `lookup`/`try`) |
| `foundation-identity` v1 | `key_vault_id`, `key_vault_uri`, `secret_ids` (optional), `identities[<name>].{principal_id, client_id, name}` |

## Produced contract
`platform-db-cassandra-mi` v1 — schema `catalog/contracts/platform-db-cassandra-mi.v1.schema.json` (output `contract`, no secrets).
`{enabled:false, cluster:null}` when disabled; otherwise cluster id/name/version, seed node IPs, port 9042, admin password secret ID, keyspace boundary, `dbm.supported = false`.

## Settings (`components.platform-db-cassandra-mi` in `environments/<env>/environment.yaml`)
| Key | Default |
|---|---|
| `enabled` | `false` |
| `cassandra_version` | `5.0` |
| `node_count`, `sku_name`, `disk_count` | 3, `Standard_D8s_v4`, 1 |
| `cosmosdb_service_principal_object_id` | required when enabled |
| `network_contributor_scope` | `subnet` (`vnet` matches Microsoft's quickstart) |
| `admin_secret_name`, `secret_version` | `cassandra-mi-admin-password`, 1 |

## Cost at defaults (approximate, USD/month, list prices, not verified against the pricing API)
Disabled: 0. Enabled: roughly USD 1,500+/month (3 × D8s_v4 VMs + P30 disks + service fee); deallocate (NonProduction cluster type) or destroy when idle.

## Private networking
Datacenter VMs are injected into subnet `cassandra-mi` (private IPs only, no public endpoint). The first-party *Azure Cosmos DB* service principal (app ID `a232010e-820c-4083-83bb-3ace5fc29d0b`) needs `Microsoft.Network/virtualNetworks/subnets/join/action`: this root assigns **Network Contributor** to the object ID given in settings (`az ad sp show --id a232010e-820c-4083-83bb-3ace5fc29d0b --query id -o tsv`), scoped to the subnet by default. The apply identity needs User Access Administrator (or RBAC Administrator) on that scope. Outbound rules required by the service must be allowed by foundation-network.

## Authentication and data-plane access
Cassandra native authentication (`authentication_method = Cassandra`); Entra ID is not supported. Admin password: `random_password` (state; no write-only argument) copied write-only to Key Vault. The adapter login `dbadapter` is created by `create-keyspace.cql`; its password is set out-of-band as Key Vault secret `cassandra-mi-dbadapter-password` and substituted into the script by the pipeline.

## Teardown and data retention
Destroy deletes the datacenter and cluster (and the Network Contributor assignment). Snapshot backups (24 h) are deleted with the cluster.
`prevent_destroy` is intentionally **not** set (lab). Destroying the root deletes the resource group and all
synthetic data in it.

## Known limitations / exceptions
- No ARM keyspace resource; CQL bootstrap runs from a private agent.
- SKU list per region varies; verify `Standard_D8s_v4` availability.

## Validation
```bash
terraform init -backend=false && terraform validate && terraform test   # mocked providers, no credentials
python3 platform/data/tests/validate_contracts.py cassandra-mi                 # contract output vs JSON schema
```

## References
- https://learn.microsoft.com/azure/managed-instance-apache-cassandra/create-cluster-cli
- https://learn.microsoft.com/azure/managed-instance-apache-cassandra/add-service-principal
- https://learn.microsoft.com/azure/managed-instance-apache-cassandra/network-rules
