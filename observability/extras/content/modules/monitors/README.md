# modules/monitors

`datadog_monitor` for each resolved monitor spec. Appends notification handles per state
(`{{#is_alert}}`, `{{#is_warning}}`, `{{#is_no_data}}`, `{{#is_recovery}}`) from route keys; rejects specs without a
runbook link or alert route; fails the plan (precondition) on route keys missing from the routing.
