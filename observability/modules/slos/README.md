# modules/slos

`datadog_service_level_objective` (availability: metric-based; latency: time-slice) and multi-window burn-rate alerts
(`type = "slo alert"`, `burn_rate("<id>").over(...).long_window(...).short_window(...) > N`). Validates
`0 < N <= 1/(1-target)` (Datadog limit). Docs: https://docs.datadoghq.com/service_management/service_level_objectives/burn_rate/
