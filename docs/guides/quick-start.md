# Quick start

Two phases: **local validation** (no credentials, minutes) and **first deployment** (bootstrap from a workstation, then
the pipeline). Nothing in phase 2 has been executed from this repository yet; the steps describe what the code does.

## Phase 1 - local validation (no credentials)

Toolchain (pinned in [`versions.yaml`](../../versions.yaml), ADR-0001 section 2): Terraform 1.16.5 (>= 1.14), Python 3.13
with `pyyaml` + `jsonschema` (`pipelines/requirements-tools.txt`), .NET SDK 10.0, Node 22+ (24 LTS for builds), Go 1.24.13 (only
to rebuild `dsv-fetch` locally; without it `build.sh` uses a digest-pinned golang container, see [`observability/images/dsv-fetch`](../../observability/images/dsv-fetch/README.md)), docker for
integration tests, optional `checkov`.

```bash
git clone <repo> && cd enterprise-architecture
python3 -m pip install -r pipelines/requirements-tools.txt pytest

# registry, configuration and selection
python3 -m tools.changeset graph                          # registry valid, acyclic, dependency layers
python3 tools/config/resolve.py --env dev                 # profile minimal -> enabled components
python3 tools/config/render.py --env dev --component foundation-network --stdout   # one root's tfvars
python3 -m tools.changeset select --mode pr --env dev --target main                 # what a PR would validate

# catalog and generated files
python3 tools/catalog/validate.py
python3 tools/catalog/render_coverage.py --check
python3 tools/pipeline/generate.py --check
python3 tools/validate/pipeline_lint.py && python3 tools/validate/ownership.py && python3 tools/validate/versions.py

# Terraform: fmt -check, init -backend=false, validate, terraform test (mock providers) for every root and module
python3 tools/validate/all_terraform.py --workers 4
# or one root:  tools/validate/terraform.sh foundation/network

# tooling tests
python3 -m pytest -q tests

# one component exactly as the pipeline Validate stage runs it
python3 tools/validate/component.py --component deploy-core-aca --env dev

# observability onboarding (v2 manifests)
python3 observability/tools/onboarding/validate.py --manifests observability/onboarding/dev --env dev --strict
python3 observability/tools/onboarding/render.py render --manifests observability/onboarding/dev --env dev \
  --out observability/onboarding/rendered/dev --check

# documentation
python3 tools/docs/generate.py --check
tools/docs/render_diagrams.sh --check
python3 tools/docs/check_links.py
```

Service-level tests and local runs are documented per service (for example
[`applications/dotnet/README.md`](../../applications/dotnet/README.md),
[`applications/python/README.md`](../../applications/python/README.md),
[`applications/services/frontend/README.md`](../../applications/services/frontend/README.md)). A minimal local journey
without Azure:

```bash
cd applications/dotnet
STORAGE_MODE=memory MESSAGING_MODE=log PRICE_FALLBACK=true dotnet run --project ../services/orders-api/src/Hello.OrdersApi
curl -s -X POST localhost:8080/orders -H 'content-type: application/json' -H 'Idempotency-Key: k1' \
  -d '{"sku":"SKU-0001","quantity":1,"customer_ref":"c1"}'
```

## Phase 2 - first deployment (needs Azure, Azure DevOps and Datadog)

1. **Prerequisites** - subscription rights, resource providers, quotas, Datadog keys, DSV:
   [prerequisites-and-bootstrap.md](prerequisites-and-bootstrap.md).
2. **Configure the environment** - [`environments/dev/environment.yaml`](../../environments/dev/environment.yaml): real
   `subscription_id`/`tenant_id`, `owner`, `expires_on`, `budget`, `profile` (start with `minimal`,
   [deployment-profiles.md](deployment-profiles.md)) and the `components.bootstrap` block.
3. **Bootstrap** from your workstation: `az login --tenant <tenant>` then `bootstrap/scripts/bootstrap.sh --env dev`.
4. **Azure DevOps setup** (not expressible in YAML): [pipelines/README.md](../../pipelines/README.md#one-time-azure-devops-setup-checklist).
5. **Secrets (Delinea DSV)** - map the `deploy-agent` identity once after `foundation-identity` exists, seed the
   operator values, check with `python3 tools/secrets/check.py --env dev`
   ([bootstrap guide](prerequisites-and-bootstrap.md#3b-delinea-devops-secrets-vault-prerequisites),
   [secret rotation](../runbooks/secret-rotation.md)).
6. **Run the pipelines**: `lab-platform` (`azure-pipelines.yml`, mode `auto`) first; on success it triggers
   `lab-applications`. Preview with `python3 -m tools.changeset explain --env dev`. The first foundation runs need the
   temporary hosted-agent access of the bootstrap guide; afterwards point `deployPool` at the private pool.
7. **Check the result** - the Verify stage runs smoke tests and telemetry verification; the Evidence stage writes
   `deployment-report.md` and `evidence.json` ([evidence](../evidence/README.md)). Walk one journey in Datadog with
   [demo-walkthrough.md](demo-walkthrough.md).

Tear down with [runbooks/teardown.md](../runbooks/teardown.md).
