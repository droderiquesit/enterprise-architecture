# platform/compute/vmss — Flexible + Uniform scale sets

| | |
|---|---|
| Component id | `platform-vmss` |
| Owner | platform team (compute) |
| Consumes | `foundation-network` (`subnets.compute`), `foundation-identity` (`hello-worker`, `hello-dbadapter`) |
| Produces | `platform-vmss` v1 |
| Status | `implemented` |

## What it creates

| Scale set | Orchestration | Workload | Instances (default/min/max) | Upgrade |
|---|---|---|---|---|
| `flexible` | Flexible (`azurerm_orchestrated_virtual_machine_scale_set`) | hello-worker | 1 / 1 / 3 | n/a (Flexible: per-VM) |
| `uniform` | Uniform (`azurerm_linux_virtual_machine_scale_set`) | hello-dbadapter-sqlvm | 1 / 1 / 2 | **Manual** |

Ubuntu 24.04, `Standard_B2s_v2`, OS baseline cloud-init (shared module), no public IPs, user-assigned identity,
boot diagnostics, extension operations enabled for observability. `lifecycle.ignore_changes` covers
`instances` (owned by autoscale) and `extension` (Datadog/Fluent Bit extensions are owned by obs-hosts).

**Autoscale** (`azurerm_monitor_autoscale_setting` — a scaling control, not monitoring): CPU > 70 % (5 min) →
+1, CPU < 25 % (10 min) → −1, bounded by `min_instances`/`max_instances` (validated ≤ 10).

### Why `upgrade_mode = "Manual"` for Uniform

A Rolling policy needs a load-balancer health probe or the Application Health extension. This adapter has no
load balancer, and the app is installed *after* the platform (run command) by another root, so a Rolling
policy would gate every platform model change on an application signal the platform does not own. Instead
`deploy-vm-workloads` performs batch-wise rolling reinstalls via run command and applies model updates per
instance (`az vmss update-instances`), which keeps rollouts controlled without coupling the layers.

## Settings

`admin_username`, `admin_ssh_public_key`, `os_disk_type`, `image{}`, `flexible{enabled,sku,identity,instances,min_instances,max_instances,zones}`,
`uniform{…}`, `autoscale{enabled,scale_out_cpu,scale_in_cpu,notification_email}`, `encryption_at_host_enabled`.

## Cost at defaults (approx.)

2 × B2s_v2 Linux 24×7 ≈ USD 70/month + disks ~6. No auto-shutdown for scale sets; use
`az vmss deallocate` or scale `min_instances` to 0 off-hours.

## Docs

- https://learn.microsoft.com/azure/virtual-machine-scale-sets/virtual-machine-scale-sets-orchestration-modes
- https://learn.microsoft.com/azure/virtual-machine-scale-sets/virtual-machine-scale-sets-upgrade-policy
- https://learn.microsoft.com/azure/virtual-machine-scale-sets/virtual-machine-scale-sets-autoscale-overview
