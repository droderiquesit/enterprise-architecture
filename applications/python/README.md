# Enterprise Hello — Python services, Logic Apps and frontend build

| Component id | Path | Artifact(s) produced by `build.sh` (`.artifacts/<svc>/`) |
|---|---|---|
| (library) | `shared/python/hello_common` | tests only (installed into every service) |
| svc-catalog-api | `services/catalog-api` | image `hello-catalog-api`, App Service code zip |
| svc-dbadapter | `services/dbadapter` | image `hello-dbadapter`, App Service code zip |
| svc-worker | `services/worker` | image `hello-worker`, VM zip (`*-vm.zip`, offline wheelhouse + systemd unit + install.sh) |
| svc-partner-sim | `services/partner-sim` | image `hello-partner-sim` (+ code zip) |
| svc-jobs | `services/jobs` | image `hello-jobs`, Azure Batch zip (`*-batch.zip`, wheelhouse + run.sh) |
| svc-traffic | `services/traffic` | image `hello-traffic` (Playwright base) |
| svc-functions | `services/functions` | Functions zip (deps pre-installed in `.python_packages`), image `hello-functions` |
| svc-logicapps | `services/logicapps` | Standard zip + `batch-request.definition.json` (Consumption) |
| svc-frontend | `services/frontend` | static bundle zip (no `config.json`), image `hello-frontend` (nginx) |

Secrets: any environment variable whose value is `dsv://<path>#<element>` is resolved from Delinea DSV at start-up by
`hello_common.secrets.resolve_env()` (called first by every entrypoint: `python -m <pkg>`, worker, jobs CLI, traffic,
Functions `bootstrap.configure()`); see `shared/python/hello_common/README.md` and ADR-0001 §14. No Key Vault.

Every artifact directory also gets `manifest.json` (version, commit, build time, sha256 per file), `junit.xml`
and, for images, `image.json`.

```bash
applications/python/build.sh                                   # lint,test,package,image for everything
applications/python/build.sh --steps lint,test --services worker,jobs
applications/python/build.sh --steps integration               # docker-based integration suites + Playwright e2e
VERSION=1.2.3 IMAGE_PREFIX=myacr.azurecr.io/ applications/python/build.sh --steps package,image
# behind a TLS-inspecting proxy:
DOCKER_BUILD_ARGS="--network host --build-arg HTTPS_PROXY=$HTTPS_PROXY --secret id=pipca,src=/path/ca.pem" applications/python/build.sh
```

Conventions
* Python 3.13 only (`requires-python = ">=3.13,<3.14"`). Each service: `pyproject.toml` (ranges) +
  `requirements.in` (exact top-level pins, includes `shared/python/hello_common/requirements.in`) →
  `requirements.txt` compiled with `uv pip compile --python-version 3.13 --python-platform x86_64-manylinux_2_28`
  (every transitive dependency pinned). Re-compile after changing a `.in` file.
* Docker build context is `applications/`; each service has `Dockerfile` + `Dockerfile.dockerignore` (BuildKit
  per-Dockerfile ignore) so the context only contains `shared/python/hello_common` and that service.
  Images: digest-pinned bases (`python:3.13.16-slim-trixie`), multi-stage, non-root (uid 10001), no secrets
  (optional `pipca` build secret is mounted only for one `pip install` step).
* Lint: ruff 0.16 with `python/ruff.toml`; shell scripts with `bash -n` + shellcheck when available.
* Unit tests never need network; `integration`-marked tests use real local containers (see each README).
* `.artifacts/` must be git-ignored (repository root `.gitignore` is owned elsewhere).
