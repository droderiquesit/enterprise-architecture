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

Standard library only (`tests/test_stdlib_only.py` enforces it), single file `dsv_fetch.py`, Python ≥ 3.11 — so the same
file runs in the image, under the Datadog Agent's embedded Python 3.13 (`/opt/datadog-agent/embedded/bin/python3`), or under
the OS `python3` on a VM.

## Interface (stable — deployments and modules rely on it)

```
dsv-fetch init --out DIR --format files|env-yaml|dotenv
               [--map NAME=dsv://path#element]... [--map-file FILE.json] [--from-env]
               [--env-yaml-name fluentbit-env.yaml] [--dotenv-name .env] [--file-mode 0400|0440|0444] [--config FILE.json]
dsv-fetch agent-backend [--config FILE.json]
dsv-fetch install --dest PATH [--python /opt/datadog-agent/embedded/bin/python3] [--owner dd-agent]
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
* **install** writes a copy of the script with `#!<python> -I` shebang, mode **0500**, owned by `--owner` (needs root).
* Exit codes: `0` ok, `1` resolution failure / malformed Agent request, `2` usage or configuration error.

### Configuration (environment; `--config FILE.json` with the same keys fills what the environment lacks)

| Variable | Meaning |
|---|---|
| `DSV_AUTH` | `azure` (default) or `client_credentials` (local/test only: `DSV_CLIENT_ID`, `DSV_CLIENT_SECRET`) |
| `DSV_TENANT`, `DSV_TLD` | base URL `https://{DSV_TENANT}.secretsvaultcloud.{DSV_TLD:-com}/v1` |
| `DSV_BASE_URL` | override (mock server). `http://` only for loopback hosts or with `DSV_ALLOW_INSECURE_HTTP=true` (docker tests) |
| `DSV_TIMEOUT_SECONDS` / `DSV_MAX_ATTEMPTS` | per request (5) / attempts for connection errors, timeouts, 429, 5xx (3); 401/403/404 never retried; full-jitter backoff ≤ 2 s |
| `AZURE_CLIENT_ID` | user-assigned managed identity (omit = system-assigned) |

Managed identity token for `https://management.azure.com/` — first match wins, stdlib `urllib` only:

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

Agent requirements (docs.datadoghq.com "Secrets Management"): the executable must belong to the user running the Agent
(`dd-agent`, or `root` inside a container), have **no rights for group or other**, and at least execute for the owner.
`dsv-fetch install` produces exactly that (mode 0500):

* **VM / VMSS (Linux)**: bootstrap (cloud-init / custom script, as root):
  `python3 dsv_fetch.py install --dest /opt/dsv-fetch/dsv-fetch --python /opt/datadog-agent/embedded/bin/python3 --owner dd-agent`
  then in `datadog.yaml`: `secret_backend_command: /opt/dsv-fetch/dsv-fetch`, `secret_backend_arguments: ["agent-backend", "--config", "/etc/datadog-agent/dsv-fetch.json"]`,
  `api_key: ENC[dsv://eh/dev/datadog-api-key#value]`. `/etc/datadog-agent/dsv-fetch.json` (`{"DSV_TENANT": "...", "AZURE_CLIENT_ID": "..."}`,
  0640 root:dd-agent) carries references/ids only, no secret. Check with `sudo datadog-agent secret`.
* **AKS / containers**: init container `dsv-fetch install --dest /dsv-bin/dsv-fetch --python /opt/datadog-agent/embedded/bin/python3`
  running as **uid 0** (the Agent container runs as root, so the file must be root-owned) into an emptyDir mounted
  read-only in the agent container; `DD_SECRET_BACKEND_COMMAND=/dsv-bin/dsv-fetch`, `DD_SECRET_BACKEND_ARGUMENTS=agent-backend`.
  The emptyDir must not be mounted `noexec`.
* Windows hosts: not supported by this tool (the Agent requires a Win32 executable owned by Administrators/ddagentuser).

Verified locally with `datadog/agent:7.84.2` (docker, internal network, mock DSV + fake IMDS): `agent secret` reports
"Executable permissions: OK" and "Number of secrets resolved: 1", and the Agent's intake requests carried the resolved key.

## Build, test

```bash
docker build -t dsv-fetch:dev observability/images/dsv-fetch          # ~91 MB, distroless python3-debian13 (3.13), uid 65532
python3 -m pytest -q observability/images/dsv-fetch/tests              # unit/CLI tests: mock DSV + fake IMDS/IDENTITY_ENDPOINT/Entra
python3 observability/images/dsv-fetch/tests/docker_smoke.py           # docker: init files, Fluent Bit, OTel collector, Agent
```

Test helpers: `tests/fake_identity.py` (IMDS + IDENTITY_ENDPOINT + Entra token endpoint), `tests/capture_intake.py`
(records SHA-256 of `DD-API-KEY`), `tools/secrets/mock_dsv.py` (DSV API; repository tool, not shipped in the package).

## Limitations

* Values are fetched once per run; rotation = restart the replica / Agent (`secret_refresh_interval` re-runs the backend).
* No Windows support; no Azure Arc managed identity.
* Workload-identity tokens with DSV: not verified (see above).
* Nothing here has run against real DSV or Azure (status: implemented / locally-verified).

Docs: [Datadog secrets management](https://docs.datadoghq.com/agent/configuration/secrets-management/),
[Azure IMDS managed identity](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/how-to-use-vm-token),
[App Service managed identity endpoint](https://learn.microsoft.com/azure/app-service/overview-managed-identity),
[Fluent Bit YAML configuration](https://docs.fluentbit.io/manual/administration/configuring-fluent-bit/yaml),
[OTel collector config providers](https://opentelemetry.io/docs/collector/configuration/#environment-variables),
Delinea DSV "Authentication: Azure".
