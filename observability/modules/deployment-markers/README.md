# modules/deployment-markers

No Terraform resource exists for DORA deployment events in DataDog/datadog 4.25, so markers are sent by the pipeline with
`tools/markers/send_deployment_event.py` (`POST https://api.<site>/api/v2/dora/deployment`). This module renders the
per-service command lines (output `commands`). It creates nothing.
