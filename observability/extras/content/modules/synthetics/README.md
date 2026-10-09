# modules/synthetics

API tests (GET <url><health_path>, status 200, response time) and browser tests. Private endpoints run only from
`private_location_id`; without it they are skipped (output `skipped`). `paused = true` by default (non-prod).
