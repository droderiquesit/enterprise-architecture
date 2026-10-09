# modules/fluent-bit

A pure function module with no providers and no resources. For each role, it renders the **validated** Fluent
Bit configs from `observability/config/fluent-bit/`:
`sidecar | sidecar-forward | aggregator | aggregator-forward | k8s-daemonset | linux-host | windows-host`.

Outputs:
* `files`: relative path to content (`fluent-bit.yaml`, `parsers.yaml`, `lua/enterprise_hello.lua`, plus
  `inputs-extra.yaml` for hosts). Mount the files together.
* `env`: the non-secret environment contract (site intake host, TLS on, tags, state dir, exclude paths,
  throttle, canary and metrics intervals, OTLP host for self-metrics, ACA console allow-list).
* `secret_env_names`: variables that must come from a secret store.
* `files_sha256`: change detection, used to roll pods or re-run installers.

`tls = false` is rejected. Only the docker tests point at a plain-HTTP mock intake, and they do so through env
vars, not through this module.

Used by `telemetry-transport` (aggregator), `kubernetes` (DaemonSet) and `host-agents` (VM/VMSS). Tests are in
`tests/render.tftest.hcl`. The functional proof is in `observability/tests/transport/`.
