# Azure Batch log collection (ADR-0001 §13 amendment): observability owns the Fluent Bit setup content for Batch
# nodes and publishes it in this contract (`batch_log_setup`). The application deployment root that submits the
# Batch job (deploy-jobs, scripts/submit-batch-job.sh) runs it as the job's *job preparation task* (elevated,
# once per node per job, re-run after reboot). Batch pools have no VM extensions and platform-batch is upstream
# of this root, so neither the pool start task nor platform-batch reference observability (no dependency cycle).
#
# The script is the Batch-specific installer scripts/batch-log-setup.sh.tftpl (package 4.0.0; pinned Fluent Bit from
# packages.fluentbit.io, systemd unit fluent-bit-eh, linux-host config; no Datadog Agent - Batch is, with
# log_pipeline = fluent_bit_direct, the only place Fluent Bit remains). Values only known on the node are passed as
# job-preparation environment:
#   EH_IDENTITY_CLIENT_ID - pool user-assigned identity (a DSV user with read on datadog-api-key)
#   EH_LOG_PATHS          - "$AZ_BATCH_NODE_ROOT_DIR/workitems/*/job-*/*/stdout.txt" (Batch task stdout files)
# No secret is rendered. With Observability Pipelines the node forwards to the Worker and needs no key. Otherwise the
# static dsv-fetch binary (release zip of artifacts["img-dsv-fetch"], sha256-pinned, downloaded with the pool identity)
# reads the Datadog API key from Delinea DSV on the node (IMDS) when fluent-bit-eh starts (ExecStartPre -> tmpfs file).
module "batch_flb" {
  source       = "../../modules/fluent-bit"
  count        = var.settings.batch_log_setup_enabled ? 1 : 0
  role         = "linux-host"
  datadog_site = var.settings.datadog_site
  static_tags = {
    env         = var.environment.name
    service     = "hello-jobs"
    application = "enterprise-hello"
    team        = var.environment.team
    managed_by  = "terraform"
    source      = "python"
  }
  dd_source = "python"
  # package 3.0.0: with Observability Pipelines the nodes forward to the Worker (in-VNet, no API key on the node)
  log_destination = local.batch_op ? "observability_pipelines" : "datadog"
  op_endpoint     = local.batch_op ? { host = module.transport.contract.aggregator.fqdn, port = 24224 } : null
  # Placeholder; the job preparation task overrides it with EH_LOG_PATHS (the node root differs per VM size).
  log_paths = ["/mnt/batch/tasks/workitems/*/job-*/*/stdout.txt"]
}

locals {
  batch_op          = try(module.transport.contract.aggregator.kind, "") == "observability_pipelines"
  batch_flb_version = "5.1.3"
  batch_needs_key   = var.settings.batch_log_setup_enabled ? length(module.batch_flb[0].secret_env_names) > 0 : false
  # static dsv-fetch release (img-dsv-fetch zip-package: dsv-fetch-linux-{amd64,arm64}, dsv-fetch-windows-amd64.exe,
  # SHA256SUMS); downloaded by the node with the pool identity only when Fluent Bit needs the API key
  batch_dsv_fetch = {
    url     = try(var.artifacts[var.settings.fetch_artifact].package_url, null)
    sha256  = try(var.artifacts[var.settings.fetch_artifact].package_sha256, null)
    version = try(coalesce(var.artifacts[var.settings.fetch_artifact].version, ""), "")
  }
  batch_setup_script = var.settings.batch_log_setup_enabled ? templatefile("${path.module}/scripts/batch-log-setup.sh.tftpl", {
    fb_version               = local.batch_flb_version
    api_key_ref              = local.api_key_ref
    dsv_config_json          = jsonencode(merge(local.dsv.tenant == null ? {} : { DSV_TENANT = local.dsv.tenant }, { DSV_TLD = coalesce(local.dsv.tld, "com"), DSV_BASE_URL = local.dsv.base_url, DSV_AUTH = "azure", DSV_TIMEOUT_SECONDS = "10" }))
    dsv_fetch_package_url    = local.batch_dsv_fetch.url == null ? "" : local.batch_dsv_fetch.url
    dsv_fetch_package_sha256 = local.batch_dsv_fetch.sha256 == null ? "" : local.batch_dsv_fetch.sha256
    dsv_fetch_version        = split("+", local.batch_dsv_fetch.version)[0]
    files                    = { for p, c in module.batch_flb[0].files : p => base64gzip(c) }
    env                      = module.batch_flb[0].env
    secrets_file             = module.batch_flb[0].secrets_env_file
    fb_needs_key             = local.batch_needs_key
  }) : null

  batch_log_setup = var.settings.batch_log_setup_enabled ? {
    script_gzip_base64 = base64gzip(local.batch_setup_script)
    script_sha256      = sha256(local.batch_setup_script)
    fluent_bit_version = local.batch_flb_version
    log_paths_template = "$AZ_BATCH_NODE_ROOT_DIR/workitems/*/job-*/*/stdout.txt"
    identity_env       = "EH_IDENTITY_CLIENT_ID"
    log_paths_env      = "EH_LOG_PATHS"
    run_elevated       = true
  } : null
}
