---
applyTo: "observability/config/**,observability/schemas/**,observability/tools/tags/**"
---
# Observability configs (tag policy, Fluent Bit, OTel collector, pipelines)

- Tag policy (`observability/config/tag-policy.yaml`) must keep the required unified tags (`env`, `service`,
  `version`, `team`, `owner`, `application`, `domain`, `tier`, `region`, `managed_by`); flag removals.
- Application logs go Fluent Bit -> Datadog only; flag a second shipper for the same logs.
- Collector/Fluent Bit images pinned per `versions.yaml`; API keys only via DSV references, TLS on outputs.
- Avoid high-cardinality metric attributes (ids, user data); keep sampling and batching bounded.
