---
applyTo: "applications/charts/**"
---
# Helm charts

- Images by digest; `securityContext` non-root, read-only root filesystem, no privilege escalation, drop ALL caps.
- Resource requests/limits, liveness `/healthz`, readiness `/readyz` probes.
- Secrets only as `dsv://` references resolved by the `dsv-fetch` init container; no Kubernetes Secret literals in values.
- Unified service tags (`env`, `service`, `version`) as labels and env vars; no duplicate log shipping (Fluent Bit only).
