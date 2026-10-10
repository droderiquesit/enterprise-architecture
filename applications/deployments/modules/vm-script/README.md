# vm-script — Linux install script renderer (pure module)

Owner: applications layer. Used by `vm-workloads` (run command / VMSS Flexible CustomScript), `dbadapters` (VMSS
Uniform CustomScript) and `specialized` (confidential VM run command).

**Purpose**: renders `templates/linux-install.sh.tftpl`: downloads the immutable package with an IMDS token of the host's
user-assigned identity (no SAS), checks its sha256, writes `/etc/<app>/<app>.env` (plain values and `dsv://`
references the service resolves at start-up - never secret values) and either runs the package's own
`deploy/install.sh` (`mode = package-install-sh`, hello-worker) or installs a wheelhouse package into a release venv with
a hardened systemd unit (`mode = python-service`), then health-checks and rolls back on failure.

**Inputs / outputs**: see `variables.tf` and `main.tf` (`script`, `env_file`).

**Tests**: through the consuming roots (their `terraform test` runs assert on the rendered script).
