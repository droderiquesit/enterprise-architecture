# Runbooks

Operational procedures for the lab. They describe what the code and scripts in this repository do; none has been
executed against a live Azure subscription or Datadog organisation yet.

| Runbook | Use when |
|---|---|
| [secret-rotation.md](secret-rotation.md) | rotating Datadog keys, fault token, DBM / database passwords, Event Hubs listen key, Cosmos keys |
| [rollback.md](rollback.md) | a release must be reverted: automatic application rollback, per architecture (revisions, slots, digests, packages); infrastructure via reviewed change only |
| [lock-recovery.md](lock-recovery.md) | a Terraform state lock is stuck (what the pipeline breaks automatically, and the manual path) |
| [quarantine.md](quarantine.md) | a component is quarantined by the pipeline circuit breaker (triage, how to clear) |
| [ci-speed.md](ci-speed.md) | a PR build is slow, a suite was skipped unexpectedly, or a cached pass is suspect |
| [teardown.md](teardown.md) | removing components or a whole environment (pipeline retire mode, per-root destroy, what is retained, scoped cleanup) |
| [break-glass.md](break-glass.md) | pipeline or agents unavailable; state recovery (links the bootstrap break-glass procedures) |
| [alert-response.md](alert-response.md) | a Datadog monitor of the optional monitoring content (`observability/extras/content`, component `obs-monitoring`) fired: one section per runbook anchor (generated from the archetypes) |
| [alerts/README.md](alerts/README.md) | per-service pages with the monitors behind each anchor (generated from the rendered onboarding files) |
| [fault-injection.md](fault-injection.md) | exercising monitors safely: authenticated, limited, auto-expiring, disabled by default |

Regenerate the generated pages after changing archetypes or onboarding manifests: `python3 tools/docs/generate.py`.
