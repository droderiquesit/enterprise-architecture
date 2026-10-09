# modules/rum

`datadog_rum_application` per key. Output `applications` = {application_id, client_token, name, type}. The client token is
Datadog's browser-facing credential (shipped in the frontend's config.json), therefore non-sensitive. Create before the
frontend deploys.
