# service-meta — Enterprise Hello service metadata (pure module)

Owner: applications layer. Static map `services` (output): service id -> `{team, domain, tier, owner, runtime, artifact,
identity}`, mirroring `observability/onboarding/<env>/*.yaml` so telemetry tags and Datadog onboarding agree. No inputs.
Change it together with the onboarding files. Tested through every deployment root's `terraform test`.
