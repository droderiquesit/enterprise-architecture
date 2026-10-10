# platform/modules/compute-linux-baseline

Shared **code** module that renders the Linux OS-baseline cloud-init used by `platform/compute/vm`,
`platform/compute/vmss` and `platform/compute/specialized`. It only prepares the OS: a `hello`
system user/group, `/opt/hello/{releases,current}`, `/var/log/hello` (the JSON log file the Datadog
Agent tails, ADR-0001 §13 observability 4.0.0) and Python 3.13 from the deadsnakes PPA (Ubuntu 24.04 ships Python 3.12;
needs outbound HTTPS). Applications are installed later by `applications/deployments/vm-workloads`
(VM Run Command); the Datadog Agent is added by the observability `obs-hosts` Azure Policy (VM Application).
Callers set `lifecycle { ignore_changes = [custom_data] }`, so template changes reach new hosts only.

| Input | Default | Notes |
|---|---|---|
| `component` | — | calling component id (written into `/etc/<app_dir>/README`) |
| `app_user` / `app_group` / `app_dir` | `hello` | system account and directory names |
| `install_python` / `python_version` | `true` / `3.13` | deadsnakes PPA install |

Outputs: `cloud_init` (YAML) and `custom_data` (base64).

Validation: `tools/validate/terraform.sh platform/modules/compute-linux-baseline` (fmt + validate; exercised by the
`platform-vm`, `platform-vmss` and `platform-specialized-compute` tests).
