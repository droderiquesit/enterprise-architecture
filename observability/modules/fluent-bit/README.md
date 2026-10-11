# modules/fluent-bit

> **Fallback only.** Datadog collectors handle application logs everywhere (`config/fleet-policy.yaml`
> `logs.collector`); these configs are used only with `log_pipeline = fluent_bit_direct` and on Batch nodes.

A pure function module with no providers and no resources. For each role, it renders the **validated** Fluent
Bit configs from `observability/config/fluent-bit/`:
`sidecar | sidecar-forward | aggregator | aggregator-forward | k8s-daemonset | linux-host | windows-host`.

Outputs:
* `files`: relative path to content (`fluent-bit.yaml`, `parsers.yaml`, `lua/enterprise_hello.lua`, plus
  `inputs-extra.yaml` for hosts). Mount the files together.
* `env`: the non-secret environment contract (site intake host, TLS on, tags, state dir, exclude paths,
  throttle, canary and metrics intervals, OTLP host for self-metrics, ACA console allow-list).
* `secret_env_names`: variables whose values come from Delinea DSV. They are never env vars or platform secrets:
  `dsv-fetch init --format env-yaml` writes them into an `env:` YAML file that every main config includes
  (`secrets_env_file`: `/dsv-secrets/fluentbit-env.yaml` in containers, `/run/fluent-bit-eh/fluentbit-env.yaml`
  on Linux hosts, `C:/ProgramData/fluent-bit-eh/secrets/fluentbit-env.yaml` on Windows). The `${DD_API_KEY}`
  style references in the configs are unchanged; a missing include file stops Fluent Bit at start (verified
  with Fluent Bit 5.1.3: the included `env:` section feeds `${VAR}` substitution and wins over process env).
* `secrets_env_file`: that path for the role.
* `files_sha256`: change detection, used to roll pods or re-run installers.

`tls = false` is rejected. Only the docker tests point at a plain-HTTP mock intake, and they do so through env
vars, not through this module.

Used by `telemetry-transport` (aggregator) and `kubernetes` (DaemonSet). Functional tests: `observability/tests/transport/`.
