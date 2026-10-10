# platform/compute/vm — Linux + Windows VM hosts

| | |
|---|---|
| Component id | `platform-vm` |
| Owner | platform team (compute) |
| Consumes | `foundation-network` (`subnets.compute`), `foundation-identity` (`hello-worker`, `hello-inventory-api`, `obs-host-agent`) |
| Produces | `platform-vm` v1 — consumed by `deploy-vm-workloads` (run command install) and `obs-hosts` (Datadog Agent Azure Policy scope) |
| Status | `implemented` |

## What it creates

| VM | Image | Size | Identity | Prepared by platform |
|---|---|---|---|---|
| `linux` | Canonical `ubuntu-24_04-lts` / `server` (Gen2, Trusted Launch) | `Standard_B2s_v2` | hello-worker (UAI) | cloud-init from `platform/modules/compute-linux-baseline`: `hello` user, `/opt/hello`, `/var/log/hello`, **Python 3.13 from the deadsnakes PPA** (Ubuntu 24.04 ships 3.12) |
| `windows` | `MicrosoftWindowsServer/WindowsServer/2025-datacenter-azure-edition` (hotpatch) | `Standard_B2s_v2` | hello-inventory-api (UAI) | OS only — the .NET 10 Hosting Bundle and service install are the app deployment's job |

- NICs in `compute`, **no public IPs**; egress via foundation NAT/firewall.
- Microsoft **Entra ID login** extensions (`AADSSHLoginForLinux`, `AADLoginForWindows`; access, not monitoring)
  + system-assigned identity they require; `admin_login_principal_ids` / `user_login_principal_ids` get
  *Virtual Machine Administrator/User Login*. Break-glass local credentials: SSH key if
  `admin_ssh_public_key` is set, otherwise `random_password` kept **only in state** (never output).
- `patch_mode = AutomaticByPlatform`, boot diagnostics (managed storage), `allow_extension_operations = true`
  (the Entra login extension and VM Applications need the VM agent).
- **Datadog Agent enrolment** (observability 4.0.0, ADR-0001 §3 rule 3 amendment): hosts carry the tag
  `datadog:enabled = "true"` and keep the DSV-reader identity `obs-host-agent` in `identity_ids`; the `obs-hosts`
  Azure Policy (DeployIfNotExists) adds the pinned Datadog Agent VM Application, which this root ignores
  (`lifecycle.ignore_changes = [gallery_application]`). `datadog.enabled = false` opts the hosts out.
- **Auto-shutdown** (`azurerm_dev_test_global_vm_shutdown_schedule`) daily **19:00 UTC** (no auto-start).

Bsv2 is used because B-series v1 retires 2028-11-15 (Learn retirement list); switch to `Standard_D2s_v5` via
`size` if burstable credits are a problem.

## Settings

`linux_vm{enabled,size,identity,admin_username,admin_ssh_public_key,os_disk_type,zone,image{}}`,
`windows_vm{…,hotpatching,image{}}`, `auto_shutdown{enabled,time,timezone}`, `entra_login_enabled`,
`admin_login_principal_ids`, `user_login_principal_ids`, `encryption_at_host_enabled`,
`datadog{enabled,tag_name,identity_key}`.

## Cost at defaults (approx., USD/month)

24×7: B2s_v2 Linux ~35 + B2s_v2 Windows ~65 + StandardSSD OS disks (~3 + ~10). With the 19:00 shutdown and
manual starts, compute drops proportionally; disks are always billed.

## Teardown / retention

Destroy deletes VMs, NICs and OS disks (no data disks; app state lives in Table Storage/Cosmos).

## Validation

```bash
tools/validate/terraform.sh platform/compute/vm   # fmt, init -backend=false, validate, terraform test (mock providers, no credentials)
```

## Docs

- https://learn.microsoft.com/azure/virtual-machines/linux/using-cloud-init
- https://learn.microsoft.com/entra/identity/devices/howto-vm-sign-in-azure-ad-linux
- https://learn.microsoft.com/entra/identity/devices/howto-vm-sign-in-azure-ad-windows
- https://learn.microsoft.com/azure/virtual-machines/windows/run-command
- https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/retirements-and-capacity-restrictions
