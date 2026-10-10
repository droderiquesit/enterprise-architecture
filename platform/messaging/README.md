# platform/messaging — Service Bus

| | |
|---|---|
| Component id | `platform-messaging` |
| Owner | platform team (messaging) |
| Consumes | `foundation-network` (`subnets.private-endpoints`, `private_dns_zones.servicebus`, `egress.public_ips`), `foundation-identity` (`identities`) |
| Produces | `platform-messaging` v1 — `catalog/contracts/platform-messaging.v1.schema.json` (no keys/connection strings) |
| Status | `implemented` |

## What it creates

- Service Bus namespace (`Standard` default), **`local_auth_enabled = false`** (no SAS), TLS 1.2 minimum.
- Topic `order-events` (duplicate detection 10 min — publishers set `MessageId` = order id) with subscriptions
  (`settings.subscriptions`, default all four) `fulfillment` (hello-durable, lock 2 min), `notifications`
  (hello-worker), `audit` (hello-functions), `archive` (hello-logicapps Standard audit-archive workflow):
  max delivery 10, dead-letter on expiry and on filter errors, TTL 14 days. The `minimal` profile
  (`component_settings`) creates only `fulfillment`, because no other consumer is deployed there.
- Queue `batch-items` (hello-jobs; max delivery 5, lock 5 min, DLQ on expiry, duplicate detection).
- Data-plane RBAC at entity scope (least privilege):

| Identity | Role | Scope |
|---|---|---|
| hello-orders-api, hello-durable | Azure Service Bus Data Sender | topic `order-events` |
| hello-durable, `logic_app_identities` (default `hello-logicapps`) | Data Sender | queue `batch-items` |
| hello-durable / hello-worker / hello-functions / hello-logicapps | Data Receiver | subscriptions fulfillment / notifications / audit / archive (only the subscriptions that exist) |
| hello-jobs | Data Receiver + **Data Owner** | queue `batch-items` (KEDA `azure-servicebus` scaler needs Manage rights to read counts) |

Grants whose identity is absent from the identity contract are skipped and reported in `skipped_grants`
(foundation-identity publishes every catalogue identity, including `hello-logicapps`).

## SKU / networking decision

| | **Standard (minimal)** | Premium (enterprise, `sku = "Premium"`) |
|---|---|---|
| Private endpoint, VNet rules | **not supported** (Premium only — verified on Learn) | PE (`namespace`) + `public_network_access_enabled = false` by default |
| IP firewall | supported via ARM (`allowed_ip_ranges`, `allow_egress_ips`) — no trusted-services bypass | supported + trusted services |
| Auth | Entra ID only | Entra ID only |

## Settings

`sku`, `premium_capacity` (1), `premium_partitions` (1), `private_endpoint_enabled` (true, Premium),
`public_network_access_enabled` (false, Premium), `allowed_ip_ranges` ([]), `allow_egress_ips` (false),
`topic_name`, `subscriptions` (map: consumer, max_delivery_count, lock_duration), `queue_*`,
`topic_sender_identities`, `queue_sender_identities`, `logic_app_identities`, `queue_scaler_owner_enabled`.

## Cost at defaults

Standard: ~USD 10/month base + operations (13M ops included) — effectively ~10. Premium: ~USD 680/month per
messaging unit + PE ~7.

## Teardown / retention

Destroy deletes the namespace and all in-flight/dead-lettered messages (synthetic data). Entities are
recreated empty.

## Known limitations

- Standard namespaces are reachable publicly (Entra ID required). Use Premium for private-only access.
- CMK / double encryption not used (justified inline for checkov).

## Validation

```bash
tools/validate/terraform.sh platform/messaging   # fmt, init -backend=false, validate, terraform test (mock providers, no credentials)
```

## Docs

- https://learn.microsoft.com/azure/service-bus-messaging/network-security
- https://learn.microsoft.com/azure/service-bus-messaging/service-bus-ip-filtering
- https://learn.microsoft.com/azure/service-bus-messaging/service-bus-managed-service-identity
- https://keda.sh/docs/latest/scalers/azure-service-bus/
