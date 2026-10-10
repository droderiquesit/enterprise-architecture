# dsv-fetch — Delinea DSV references for containers and agents without our code

Component `img-dsv-fetch` (layer observability, scope platform; image name `dsv-fetch`). Owner: application security /
observability platform. Part of the portable observability package. Decision record: ADR-0001 §14.

Fluent Bit, the OpenTelemetry Collector and the Datadog Agent cannot read Delinea DevOps Secrets Vault (DSV) themselves.
`dsv-fetch` reads `dsv://<path>#<element>` references with the workload's **Azure managed identity** (no bootstrap secret)
and hands the values over in the form each consumer understands:

| Consumer | Pattern | Command |
|---|---|---|
| OTel collector (ACA/ACI/AKS) | init container → in-memory volume, `api.key: ${file:/dsv-secrets/DD_API_KEY}` | `init --format files` |
| Fluent Bit (sidecar / aggregator) | init container → in-memory volume, main config `includes: [/dsv-secrets/fluentbit-env.yaml]`, `${DD_API_KEY}` | `init --format env-yaml` |
| systemd units / anything reading env files | `EnvironmentFile=/run/dsv/.env` | `init --format dotenv` |
| Datadog Agent (VM/VMSS, AKS) | `secret_backend_command`, `api_key: ENC[dsv://eh/dev/datadog-api-key#value]` | `agent-backend` (installed by `install`) |

**2.x is a static Go binary** (no interpreter, no libc: `CGO_ENABLED=0`, Go standard library only — `go.mod` has no
`require`, enforced by `tests/test_stdlib_only.py`). Same CLI, environment, config file, output formats, messages, exit
codes, timeouts/retries and Agent protocol as the 1.x Python script `dsv_fetch.py`; the Python test suite under `tests/`
is the black-box **conformance suite** and runs against both (see *Build, test*). The binary runs in the distroless image,
copied into the Datadog Agent container (any distro), on Linux VMs (amd64/arm64) and as a Win32 executable on Windows.

## Distribution contract (2.0.0 — other components rely on it)

| Deliverable | Where | Details |
|---|---|---|
| Container image `dsv-fetch` (component `img-dsv-fetch`, `VERSION` 2.0.0) | platform pipeline → ACR, deployed **by digest** (`artifacts["img-dsv-fetch"].image`) | multi-arch index linux/amd64 + linux/arm64; base `gcr.io/distroless/static-debian13:nonroot` pinned by digest; binary **`/opt/dsv-fetch/dsv-fetch`** (0555); `ENTRYPOINT ["/opt/dsv-fetch/dsv-fetch"]`, `CMD ["version"]`; user 65532:65532; no shell, no Python |
| Release files | same build job, zip-package → packages store (`artifacts["img-dsv-fetch"].package_url`, `.package_sha256`) | `dsv-fetch-linux-amd64`, `dsv-fetch-linux-arm64`, `dsv-fetch-windows-amd64.exe`, `SHA256SUMS` (`sha256sum` format) at the zip root; the host installer (VM Application package) carries them |
| Reproducibility | `build.sh` | `CGO_ENABLED=0 go build -trimpath -buildvcs=false -ldflags "-s -w -buildid= -X main.version=<VERSION>"` with Go 1.24.13 (`golang:1.24.13-bookworm@sha256:1a6d…77ac`); the image's `/opt/dsv-fetch/dsv-fetch` is byte-identical to `dsv-fetch-linux-<arch>` (checked by the pipeline for amd64) |

Pins live in `versions.yaml` (`images.dsv_fetch`, `images.dsv_fetch_builder`, `images.dsv_fetch_base`) and are kept equal
to `VERSION`, the `Dockerfile` and `build.sh` by `tests/test_pins.py`.

Consumers:

* **Kubernetes / ACI / ACA (Agent secret backend)**: an init container from the image runs
  `dsv-fetch install --dest /dsv-bin/dsv-fetch` (as the Agent's uid — root in the Agent container — or with
  `--owner <user>` as root) into a shared in-memory volume (`emptyDir: {medium: Memory}`; must not be `noexec`), the Agent
  container mounts it read-only and sets `DD_SECRET_BACKEND_COMMAND=/dsv-bin/dsv-fetch`,
  `DD_SECRET_BACKEND_ARGUMENTS=agent-backend`. The image has no `cp`; `install` copies the running binary itself.
* **Init containers for third-party tools** (Fluent Bit, OTel collector, serverless-init): `dsv-fetch init ...`
  (entrypoint is the binary; `args: ["init", ...]`). **Refresher container** (ACI, ACA dedicated profiles: init
  containers get no managed identity): `args: ["init", ..., "--refresh-seconds", "3600"]` keeps running and re-resolves
  every hour (after a failure every `--retry-seconds`, default 30) with a fresh token — replaces the 1.x Python stub
  (`python3 -c "...subprocess.call([...dsv_fetch.py...])"`), which cannot run in the 2.x image (no Python).
* **Linux VM/VMSS**: as root `./dsv-fetch-linux-<arch> install --dest /opt/dsv-fetch/dsv-fetch --owner dd-agent`
  (verify `sha256sum --check --ignore-missing SHA256SUMS` first).
* **Windows**: as Administrator `dsv-fetch-windows-amd64.exe install --dest "C:\ProgramData\dsv-fetch\dsv-fetch.exe" [--owner ddagentuser]`
  then `secret_backend_command: C:\ProgramData\dsv-fetch\dsv-fetch.exe`, `secret_backend_arguments: [agent-backend, --config, ...]`,
  `api_key: ENC[dsv://...]` — the key is never written into `datadog.yaml`.

## Interface (stable — deployments and modules rely on it)

```
dsv-fetch init --out DIR --format files|env-yaml|dotenv
               [--map NAME=dsv://path#element]... [--map-file FILE.json] [--from-env]
               [--env-yaml-name fluentbit-env.yaml] [--dotenv-name .env] [--file-mode 0400|0440|0444] [--config FILE.json]
               [--refresh-seconds N [--retry-seconds 30]]                                    (2.x addition)
dsv-fetch agent-backend [--config FILE.json]
dsv-fetch install --dest PATH [--owner dd-agent] [--python IGNORED]
dsv-fetch version
```

* `--map NAME=ref` (repeatable), `--map-file` (JSON object `{"NAME": "dsv://..."}`) and `--from-env` (every env var whose
  value starts with `dsv://`, except `DSV_*`) are merged; later wins. NAME: `[A-Za-z_][A-Za-z0-9_]*` for env-yaml/dotenv,
  `[A-Za-z0-9_][A-Za-z0-9_.-]*` for files.
* **files**: `DIR/NAME`, exact bytes (no trailing newline), mode `--file-mode` (default **0400**).
* **env-yaml**: `DIR/fluentbit-env.yaml` = `env:` mapping `{NAME: "value"}` (JSON-escaped double-quoted YAML scalars).
* **dotenv**: `DIR/.env` = `NAME="value"` lines (`\ " $ \`` escaped; a value containing a newline is rejected).
* Every reference is resolved **before** anything is written; one failure → exit 1, nothing written. Writes are atomic
  (temp file in DIR + rename), so a restarted init container replaces its 0400 files. DIR is created 0700 if missing.
* stderr: one JSON summary line on success (`names`, `files`, `mode` — never values); `dsv-fetch: NAME: <reason>` per
  failure (reason = status/error class, e.g. `DSV secret read failed (access denied, HTTP 403)`).
* **agent-backend** implements the Datadog Agent secret-backend protocol (verified on docs.datadoghq.com
  "Secrets Management", 2026-10-09): stdin `{"version": "1.0", "secrets": ["<handle>", ...]}` → stdout
  `{"<handle>": {"value": "<secret>"|null, "error": null|"<message>"}}`. Handles are the text inside `ENC[...]`, i.e.
  `dsv://...` references. Per-handle failures are returned in `error` with exit 0 (the Agent ignores only the affected
  settings); a malformed request exits 1 with a value-free stderr line. Nothing is ever written to stderr that contains a
  secret (the Agent logs stderr of failing commands).
* **install** copies the running binary to `--dest` (temp file in the same directory + rename, so re-installing
  replaces a 0500 file atomically): **POSIX** mode **0500**, owned by `--owner` (needs root; user name from `/etc/passwd` —
  the static binary does not use NSS/LDAP — or a numeric uid; without `--owner` the caller owns it); **Windows** an ACL
  with inheritance removed and exactly three grants — `--owner` (default `ddagentuser`) read+execute, SYSTEM and
  Administrators full control — set with `icacls.exe` (`/inheritance:r /grant:r <owner>:(RX) *S-1-5-18:(F) *S-1-5-32-544:(F)`;
  `icacls` instead of `golang.org/x/sys/windows` keeps the module standard-library only) on the temp file before the
  rename; needs an elevated installer. `--python` is accepted and **ignored** (1.x compatibility). stderr: one JSON line
  `{"dsv_fetch": "install", "dest": ..., "mode": "0500"|"acl", "owner": <name or uid>}`. Unknown user: exit 2.
* Exit codes: `0` ok, `1` resolution failure / malformed Agent request, `2` usage or configuration error.

### Configuration (environment; `--config FILE.json` with the same keys fills what the environment lacks)

| Variable | Meaning |
|---|---|
| `DSV_AUTH` | `azure` (default) or `client_credentials` (local/test only: `DSV_CLIENT_ID`, `DSV_CLIENT_SECRET`) |
| `DSV_TENANT`, `DSV_TLD` | base URL `https://{DSV_TENANT}.secretsvaultcloud.{DSV_TLD:-com}/v1` |
| `DSV_BASE_URL` | override (mock server). `http://` only for loopback hosts or with `DSV_ALLOW_INSECURE_HTTP=true` (docker tests) |
| `DSV_TIMEOUT_SECONDS` / `DSV_MAX_ATTEMPTS` | per request (5) / attempts for connection errors, timeouts, 429, 5xx (3); 401/403/404 never retried; full-jitter backoff ≤ 2 s |
| `AZURE_CLIENT_ID` | user-assigned managed identity (omit = system-assigned) |

Managed identity token for `https://management.azure.com/` — first match wins, Go `net/http` only:

1. `AZURE_FEDERATED_TOKEN_FILE` + `AZURE_TENANT_ID` (+ `AZURE_AUTHORITY_HOST`, default `https://login.microsoftonline.com/`):
   AKS workload identity client-assertion exchange (`POST {authority}{tenant}/oauth2/v2.0/token`, `scope=https://management.azure.com/.default`).
   **To verify:** DSV maps Azure users by the identity's resource id (`xms_mirid`); a token obtained through workload-identity
   federation for the same user-assigned identity is expected to carry it, but this is **not verified** against DSV.
   Fallback if DSV rejects it: run the agent/DaemonSet with the node pool's kubelet identity via IMDS, or the Delinea
   dsv-k8s syncer (documented, not implemented).
2. `IDENTITY_ENDPOINT` + `IDENTITY_HEADER`: App Service, Functions, Container Apps (`api-version=2019-08-01`, `X-IDENTITY-HEADER`).
3. IMDS `http://169.254.169.254/metadata/identity/oauth2/token` (`api-version=2018-02-01`, `Metadata: true`; 404/410/429/5xx
   retried): VM, VMSS, Batch, ACI, AKS node. `AZURE_POD_IDENTITY_AUTHORITY_HOST` overrides the IMDS base (tests).

IMDS and `IDENTITY_ENDPOINT` are always called without a proxy; DSV and Entra honour `HTTPS_PROXY`/`NO_PROXY`. Redirects are
never followed. Azure Arc's challenge flow (`IMDS_ENDPOINT` + `IDENTITY_ENDPOINT` with a key file) is not supported.

## Init-container pattern (ACA, ACI, AKS)

```yaml
# ACA (azapi/azurerm container app template), shared volume: storageType EmptyDir (replica-scoped)
initContainers:
  - name: dsv-fetch
    image: <acr>/dsv-fetch@sha256:...
    args: ["init", "--out", "/dsv-secrets", "--format", "env-yaml", "--map", "DD_API_KEY=dsv://eh/dev/datadog-api-key#value"]
    env: [{name: DSV_TENANT, value: <tenant>}, {name: AZURE_CLIENT_ID, value: <uami client id>}]
    volumeMounts: [{volumeName: dsv-secrets, mountPath: /dsv-secrets}]
containers:
  - name: fluent-bit          # main config: includes: [/dsv-secrets/fluentbit-env.yaml]; apikey: ${DD_API_KEY}
    volumeMounts: [{volumeName: dsv-secrets, mountPath: /dsv-secrets}]
```

* Kubernetes: `emptyDir: {medium: Memory, sizeLimit: 1Mi}`; ACI: `emptyDir` volume; ACA: `EmptyDir` storage type.
* **File ownership.** Files are owned by the init container's uid with mode 0400. Run the init container with the
  **consumer's uid**: Fluent Bit 5.1.3 image runs as root (0) → any uid works (root bypasses DAC; also verified running
  Fluent Bit as 65532 with files owned by 65532); OTel collector-contrib image runs as **10001** → `runAsUser: 10001`
  for dsv-fetch (verified). Alternative for a different uid: `--file-mode 0440` + shared `fsGroup`.
* The init container needs no writable root filesystem (`readOnlyRootFilesystem: true` verified), no capabilities, no shell.
* Fluent Bit facts verified with `fluent/fluent-bit:5.1.3` (docker, 2026-10-09): a YAML file holding only an `env:` section
  can be listed under `includes:` (top or bottom of the main file — position does not matter) and `${DD_API_KEY}` anywhere
  in the main config resolves from it; the included `env:` value **wins over a process environment variable of the same
  name**; `includes:` paths are **not** variable-expanded (`${VAR}` in an include path → "No such file or directory");
  a missing or unreadable included file aborts start-up ("configuration file contains errors"), so the sidecar fails
  closed when the init container did not run; a Lua `script:` path in an *included* file resolves against the
  **main** config's directory (observed when wrapping `sidecar.yaml` from another directory).
* OTel collector 0.162.0: `${file:/dsv-secrets/DD_API_KEY}` resolves at start-up (datadog exporter series/sketches carried
  that key — verified with a header-hashing fake intake).
* Docker Compose caveat (local tests only): a `tmpfs`-backed named volume loses its content when the last container using
  it exits, so a compose stack needs a long-running holder container on the volume (a pod's emptyDir lives as long as the pod).

## Datadog Agent `secret_backend_command`

Agent requirements (docs.datadoghq.com "Secrets Management", re-read 2026-10-10): Linux — the executable must belong to
the user running the Agent (`dd-agent`, or `root` inside a container), have **no rights for group or other**, and at least
execute for the owner; Windows — a valid **Win32 application**, read or execute for `ddagentuser`, and no rights for any
other user or group except Administrators and LocalSystem. `dsv-fetch install` produces exactly that:

* **VM / VMSS (Linux)**: bootstrap (as root):
  `dsv-fetch-linux-amd64 install --dest /opt/dsv-fetch/dsv-fetch --owner dd-agent`
  then in `datadog.yaml`: `secret_backend_command: /opt/dsv-fetch/dsv-fetch`, `secret_backend_arguments: ["agent-backend", "--config", "/etc/datadog-agent/dsv-fetch.json"]`,
  `api_key: ENC[dsv://eh/dev/datadog-api-key#value]`. `/etc/datadog-agent/dsv-fetch.json` (`{"DSV_TENANT": "...", "AZURE_CLIENT_ID": "..."}`,
  0640 root:dd-agent) carries references/ids only, no secret. Check with `sudo datadog-agent secret`.
* **AKS / containers**: init container (image `dsv-fetch`) `install --dest /dsv-bin/dsv-fetch`
  running as **uid 0** (the Agent container runs as root, so the file must be root-owned) into an emptyDir mounted
  read-only in the agent container; `DD_SECRET_BACKEND_COMMAND=/dsv-bin/dsv-fetch`, `DD_SECRET_BACKEND_ARGUMENTS=agent-backend`.
  The emptyDir must not be mounted `noexec`.
* **Windows hosts**: `dsv-fetch-windows-amd64.exe install --dest <dir>\dsv-fetch.exe --owner ddagentuser` (elevated), then
  `secret_backend_command: <dir>\dsv-fetch.exe` (see *Distribution contract*). Check with `& "$env:ProgramFiles\Datadog\Datadog Agent\bin\agent.exe" secret`.
  Cross-compiled and `go vet`-ed for windows/amd64 here; **not executed on Windows** in this repository's tests.

Verified locally with `datadog/agent:7.84.2` (docker, internal network, mock DSV + fake IMDS; 2.0.0 Go binary, 2026-10-10):
`install` wrote `/dsv-bin/dsv-fetch` as `500 root`, and the Agent's series/sketches requests to the fake intake carried the
key resolved through the binary as `secret_backend_command` (no request with another key).

## Build, test

```bash
cd observability/images/dsv-fetch
./build.sh                                   # dist/: 3 release binaries + SHA256SUMS (pinned toolchain; Docker if local Go != 1.24.13)
./build.sh --toolchain docker --out /tmp/rel # always the digest-pinned golang image, --network none
docker build -t dsv-fetch:dev .              # ~3.5 MB content, distroless static, uid 65532 (build context = this directory)
docker buildx build --platform linux/amd64,linux/arm64 .

go test ./... && go vet ./... && GOOS=windows go vet ./...      # Go unit tests (httptest fakes)
python3 -m pytest -q tests                   # conformance suite: every CLI test x {go, python}; Go binary built by build.sh
DSV_FETCH_IMPL=go DSV_FETCH_BIN=dist/dsv-fetch-linux-amd64 python3 -m pytest -q tests   # a release file only
python3 tests/docker_smoke.py --image dsv-fetch:dev   # docker: init files, Fluent Bit, OTel collector, agent-backend, Agent 7.84.2
```

Verify a release: `sha256sum --check SHA256SUMS`; `./dsv-fetch-linux-amd64 version` prints the semver; the image binary
equals the release file: `docker cp $(docker create <image>):/opt/dsv-fetch/dsv-fetch . && sha256sum dsv-fetch`.

Pipeline: the platform pipeline's `B_img_dsv_fetch` job builds the image from this directory (`pipelines/templates/container-image.yml`,
context = component directory, multi-arch) and the release zip (`pipelines/templates/build-dsv-fetch.yml`), then records
both (image digest + package sha256) like every artifact; later environments promote the same digest/sha256.

Test helpers: `tests/fake_identity.py` (IMDS + IDENTITY_ENDPOINT + Entra token endpoint), `tests/capture_intake.py`
(records SHA-256 of `DD-API-KEY`), `tools/secrets/mock_dsv.py` (DSV API; repository tool, not shipped in the package).

Layout: `cmd/dsv-fetch` (main, `-X main.version`), `internal/dsvfetch` (CLI with argparse-compatible messages, DSV/Entra
client, Python-`json.dumps`-compatible output, platform files for install/ACL), `build.sh`, `VERSION`.
`dsv_fetch.py` (1.x) stays only until the callers listed below are migrated; the image no longer contains it.

### Remaining 1.x callers (to migrate by their owners, then delete `dsv_fetch.py`)

Everything that embeds or runs `dsv_fetch.py` with a Python interpreter (`git grep -n dsv_fetch.py`): host-agents Linux
installer (`modules/host-agents`), kubernetes ConfigMap secret backend (`modules/kubernetes`), DBM ACI Agent
(`modules/dbm`, `lab/dbm`), telemetry-transport APM gateway + refresher stub (`modules/telemetry-transport/ops.tf`),
instrumentation ACI refresher stub (`modules/instrumentation`), Batch log setup (`lab/telemetry-transport/batch.tf`),
pipeline templates' `dsvFetchPath` (`observability/pipelines/**`), transport tests. Refresher stubs that ran
`python3 -c ...` inside the old image switch to `init ... --refresh-seconds 3600` (same 3600 s / 30 s cadence).

## Limitations

* Values are fetched once per run; rotation = restart the replica / Agent (`secret_refresh_interval` re-runs the backend).
* Windows: built and vetted, not executed in CI here; no Azure Arc managed identity.
* Workload-identity tokens with DSV: not verified (see above).
* Nothing here has run against real DSV or Azure (status: implemented / locally-verified).

Docs: [Datadog secrets management](https://docs.datadoghq.com/agent/configuration/secrets-management/),
[Azure IMDS managed identity](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/how-to-use-vm-token),
[App Service managed identity endpoint](https://learn.microsoft.com/azure/app-service/overview-managed-identity),
[Fluent Bit YAML configuration](https://docs.fluentbit.io/manual/administration/configuring-fluent-bit/yaml),
[OTel collector config providers](https://opentelemetry.io/docs/collector/configuration/#environment-variables),
Delinea DSV "Authentication: Azure".
