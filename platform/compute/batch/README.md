# platform/compute/batch — Batch account + pool

| | |
|---|---|
| Component id | `platform-batch` |
| Owner | platform team (compute) |
| Consumes | `foundation-network` (`subnets.batch`, `subnets.private-endpoints`, `private_dns_zones.{batch,blob}`), `foundation-identity` (`hello-jobs`, `deploy-agent`), `platform-shared` (`acr_login_server`) |
| Produces | `platform-batch` v1 (no account keys) |
| Status | `implemented` |

## What it creates

- Batch account, `pool_allocation_mode = BatchService`, **public network access disabled**, Entra-only API
  (`allowed_authentication_modes = ["AAD"]` — no shared keys; task authentication tokens are not supported in
  no-public-IP pools anyway), user-assigned identity `hello-jobs`.
- Private endpoints **`batchAccount`** (API/job submission) and **`nodeManagement`** (simplified node
  communication). Learn: with public access disabled or no-public-IP pools, the nodeManagement endpoint is
  required; classic node communication retired 2026-03-31. DNS zone `privatelink.batch.azure.com` is looked up
  as `private_dns_zones["batch"]` — **not yet in the foundation zone list** (see platform/README requests).
- **Auto-storage** with identity auth (`storage_account_authentication_mode = BatchAccountManagedIdentity`,
  `storage_account_node_identity = hello-jobs`), shared keys off, blob PE, containers `jobs-packages`,
  `jobs-output`.
- Pool `hello-jobs`: Ubuntu 24.04 (`canonical/ubuntu-24_04-lts/server`, node agent `batch.node.ubuntu 24.04` —
  confirm with `az batch pool supported-images list` per region), `Standard_D2s_v5`,
  **`target_node_communication_mode = Simplified`**, **`NoPublicIPAddresses`** in the `batch` subnet,
  autoscale formula from 0 to `max_dedicated_nodes` (2) on pending tasks, start task installs **Python 3.13**
  (deadsnakes PPA; needs outbound HTTPS via NAT/firewall).
- *Azure Batch Job Submitter* for `deploy-agent` and `hello-jobs`.

Not here: Batch jobs/tasks/schedules (deploy-jobs).

## Cost at defaults

Account free; pool idles at 0 nodes; D2s_v5 ~USD 0.10/h while tasks run. 3 private endpoints ≈ USD 22/month,
storage ~1.

## Validation

```bash
tools/validate/terraform.sh platform/compute/batch   # fmt, init -backend=false, validate, terraform test (mock providers, no credentials)
```

## Docs

- https://learn.microsoft.com/azure/batch/simplified-compute-node-communication
- https://learn.microsoft.com/azure/batch/simplified-node-communication-pool-no-public-ip
- https://learn.microsoft.com/azure/batch/private-connectivity
- https://learn.microsoft.com/azure/batch/batch-automatic-scaling
- https://learn.microsoft.com/azure/batch/batch-role-based-access-control
