# foundation/modules/private-endpoint

Shared **code** module (ADR-0001 §3 rule 5): one private endpoint (custom NIC name `<name>-nic`, connection
`<name>-psc`, auto-approved) plus a `default` private DNS zone group. The zones are owned by `foundation-network`
and passed in by id (`private_dns_zones.<key>.id` of its contract); the endpoint is owned by the calling root.

| Input | Notes |
|---|---|
| `name`, `resource_group_name`, `location`, `tags` | |
| `subnet_id` | normally `foundation_network.subnets["private-endpoints"].id` |
| `target_resource_id` | the Private Link resource |
| `subresource_names` | Private Link group ids, e.g. `["blob"]`, `["sqlServer"]`, `["Sql"]` (Cosmos NoSQL) |
| `private_dns_zone_ids` | empty list = no zone group |

Outputs: `id`, `private_ip_address`. Interface frozen.

Validation: `tools/validate/terraform.sh foundation/modules/private-endpoint`; exercised by the tests of every root
that creates private endpoints (e.g. `bootstrap`, `platform/data/*`).
