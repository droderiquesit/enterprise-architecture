# Runbook: break-glass

Use only when the pipeline or the private agents are unavailable and a change cannot wait. Every break-glass action
must be recorded (change record + a note in the `evidence` container) and followed by a normal pipeline run that
re-establishes provenance. Procedures are implemented in scripts and documented by their owners; none has been
exercised against Azure.

State procedures (corrupted or deleted state file or container, stuck lock, emergency local apply, lost bootstrap
state) are in [`bootstrap/README.md`](../../bootstrap/README.md#break-glass); stuck locks also in
[lock-recovery.md](lock-recovery.md).

Pipeline-level break-glass ([`pipelines/README.md`](../../pipelines/README.md#operating)):

1. Prefer the pipeline in `manual` mode for the single component (`components: <id>`, optionally `withConsumers`).
2. If the pipeline itself is unavailable, an operator with the bootstrap break-glass rights runs the same steps locally:
   ```bash
   python3 tools/config/render.py --env <env> --component <id>
   python3 tools/contracts/materialize.py --env <env> --component <id> --source https://<sa>.blob.core.windows.net/contracts
   pipelines/scripts/tf-init.sh ...          # or terraform init with the backend config above
   terraform plan -out tfplan && terraform apply tfplan
   python3 tools/contracts/publish.py ...    # publish the contract envelope for consumers
   python3 tools/deploy/record.py write --env <env> --component <id> --status succeeded --store https://<sa>.blob.core.windows.net/deployments --note "break-glass <change ref>"
   ```
   Without the record the next pipeline run re-selects the component (which is safe: it plans to no changes).

Other break-glass access paths, each owned by its root:

| Need | How |
|---|---|
| Secret values (Delinea DSV) | dsv CLI as a DSV administrator from any host with access to the tenant; see [secret rotation - break-glass](secret-rotation.md#break-glass) |
| AKS (private API server) | `az aks command invoke` (`run_command_enabled = true`, Entra-authorised); `kubectl rollout undo` for an urgent app rollback |
| VMs | Entra login extensions (`Virtual Machine Administrator Login`); local break-glass credentials: SSH key if configured, otherwise a `random_password` that exists only in Terraform state |
| MySQL admin | write-only password: reset with `az mysql flexible-server update --admin-password` |
| State account unreachable from agents | add the operator IP to `operator_ip_ranges` and re-apply bootstrap from the workstation |
| Plans of a protected deletion | add an unexpired `allow_destroy` entry in `environments/<env>/approvals.yaml` (reviewed), not a policy bypass |
