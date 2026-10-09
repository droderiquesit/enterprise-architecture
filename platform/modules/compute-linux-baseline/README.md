# platform/modules/compute-linux-baseline

Shared **code** module that renders the Linux OS-baseline cloud-init used by `platform/compute/vm`,
`platform/compute/vmss` and `platform/compute/specialized`. It only prepares the OS: a `hello`
system user/group, `/opt/hello/{releases,current}`, `/var/log/hello` (the JSON log file Fluent Bit
tails, ADR-0001 §10) and Python 3.13 from the deadsnakes PPA (Ubuntu 24.04 ships Python 3.12;
needs outbound HTTPS). Applications are installed later by `applications/deployments/vm-workloads`
(VM Run Command); agents/extensions belong to observability.

Outputs: `cloud_init` (YAML) and `custom_data` (base64).
