# modules/observability-pipeline

The central log pipeline: one `datadog_observability_pipeline` (DataDog provider `~> 4.25`) per environment, plus
everything a Worker needs to run it. Section 2 of `../README-transport.md` describes the sources, processors and
destinations.

* **Sources:** `fluent_bit` (24224), `datadog_agent` (8282), `kafka` for the Event Hubs (`sources.eventhub`,
  `eventhub_bootstrap = <namespace>.servicebus.windows.net:9093`), optional `opentelemetry`.
* **Processors:** VRL programs from `config/observability-pipelines/*.vrl`, each prefixed with
  `cfg = <json settings>`, plus Sensitive Data Scanner redaction, split, filter, dedupe, sample and quota.
* **Destinations:** `datadog_logs` with a disk buffer (`buffer.disk_max_bytes`, minimum 256 MiB;
  `when_full = block`) and an optional `azure_storage` archive.
* **Secrets:** `secret_refs` takes DSV references only. `worker_secret_refs` maps the env names to `dsv://...`
  (`DD_API_KEY`, `DD_OP_SOURCE_KAFKA_SASL_PASSWORD`, archive connection string).
* **Worker interface:**
  * `worker_env`: the non-secret bootstrap.
  * `worker_command`: waits up to 120 s for the dsv-fetch dotenv file `secrets_file`, fails closed, gives each
    replica its own data dir, then execs the Worker.
  * `ports`.

Where the Worker runs:

* Container Apps: `modules/telemetry-transport` (`log_pipeline = observability_pipelines`).
* AKS: `modules/kubernetes` `op_worker`, with `env = worker_env` and `secret_env = worker_secret_refs` (DSV references
  resolved by the Worker's dsv-fetch init container; no Kubernetes Secret).

The Worker needs a live Datadog organisation at start-up: it validates the API key and pulls the pipeline by
`DD_OP_PIPELINE_ID` through Remote Configuration. The VRL programs and the Fluent Bit forward path are tested locally
with the Vector CLI and Vector's `fluent` source (`tests/transport/test_observability_pipelines.py`).

## Test
`terraform init -backend=false && terraform test` in this directory (mock providers, no credentials): `tests/pipeline.tftest.hcl`. The VRL programs and the forward path run in `observability/tests/transport/test_observability_pipelines.py` (docker).
