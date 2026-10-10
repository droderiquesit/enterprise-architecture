---
applyTo: "observability/config/**,observability/schemas/**,observability/tools/tags/**"
---
# Observability configs (tag policy, Fluent Bit, OTel collector, pipelines)

- Tag policy (`observability/config/tag-policy.yaml`) must keep the required unified tags (`env`, `service`,
  `version`, `team`, `owner`, `application`, `domain`, `tier`, `region`, `managed_by`); flag removals.
- One application-log collector per architecture (`observability/config/fleet-policy.yaml`
  `architectures.<arch>.logs.collector`, ADR-0001 section 13, package 4.0.0): Datadog Agent on AKS nodes and VM/VMSS
  hosts, Agent sidecar on ACI, serverless-init on Container Apps, diagnostic settings -> Event Hubs for App Service /
  Functions / Logic Apps; Fluent Bit only for `log_pipeline = fluent_bit_direct` and on Batch nodes. Flag a second
  shipper for the same logs.
- Agent/collector/Fluent Bit images pinned per `versions.yaml`; API keys only via DSV references, TLS on outputs.
- Avoid high-cardinality metric attributes (ids, user data); keep sampling and batching bounded.
