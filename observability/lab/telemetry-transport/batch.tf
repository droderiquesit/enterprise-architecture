# Azure Batch log collection (ADR-0001 §13 amendment): observability owns the Fluent Bit setup content for Batch
# nodes and publishes it in this contract (`batch_log_setup`). The application deployment root that submits the
# Batch job (deploy-jobs, scripts/submit-batch-job.sh) runs it as the job's *job preparation task* (elevated,
# once per node per job, re-run after reboot). Batch pools have no VM extensions and platform-batch is upstream
# of this root, so neither the pool start task nor platform-batch reference observability (no dependency cycle).
#
# The script is the host-agents Linux installer (pinned Fluent Bit from packages.fluentbit.io, systemd unit
# fluent-bit-eh, linux-host config). Values only known on the node are passed as job-preparation environment:
#   EH_IDENTITY_CLIENT_ID - pool user-assigned identity (Key Vault Secrets User on datadog-api-key)
#   EH_LOG_PATHS          - "$AZ_BATCH_NODE_ROOT_DIR/workitems/*/job-*/*/stdout.txt" (Batch task stdout files)
# No secret is rendered: the Datadog API key is read from Key Vault on the node through IMDS.
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
  # Placeholder; the job preparation task overrides it with EH_LOG_PATHS (the node root differs per VM size).
  log_paths = ["/mnt/batch/tasks/workitems/*/job-*/*/stdout.txt"]
}

locals {
  batch_flb_version = "5.1.3"
  batch_setup_script = var.settings.batch_log_setup_enabled ? templatefile("${path.module}/../../modules/host-agents/scripts/linux-install.sh.tftpl", {
    fb_version         = local.batch_flb_version
    api_key_secret_id  = local.api_key_secret_id
    identity_client_id = ""
    configure_agent    = "false"
    install_fluent_bit = "true"
    process_collection = "false"
    agent_tags         = ""
    files              = { for p, c in module.batch_flb[0].files : p => base64gzip(c) }
    env                = module.batch_flb[0].env
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
