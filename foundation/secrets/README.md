# foundation-secrets

- **Owner:** platform-engineering · **Component id:** `foundation-secrets` · **State key:** `<env>/foundation-secrets.tfstate`
- **Purpose:** the desired **Delinea DevOps Secrets Vault** (DSV) configuration of one environment (ADR-0001 section 14):
  the Azure auth provider, one DSV user per managed identity that reads secrets, and least-privilege permissions.
  Rendered by Terraform as the non-sensitive output `dsv_desired_state`; applied by
  [`tools/secrets/dsv_apply.py`](../../tools/secrets/dsv_apply.py) through the DSV REST API.
- **Consumes:** `foundation-identity` v2 (`identities.*.{id,name,secrets}`, `secrets.{base_path,base_url,auth_provider,refs}`)
  and the secret catalogue [`foundation/identity/secrets.yaml`](../identity/secrets.yaml) (registry `inputs`).
- **Produces:** no contract (output `dsv_desired_state` is read by the pipeline hook, never by other roots).
- **Status:** implemented (validate + plan tests; dsv_apply plan/apply tested end-to-end against
  `tools/secrets/mock_dsv.py`). Not deployed.

## Why Terraform renders and Python applies

`DelineaXPM/dsv` 1.13.0 (registry, published 2026-09-24) has data sources `client`, `role`, `secret` and one resource,
`dsv_client` — **no users, policies or auth providers** — and reading secrets with data sources would put values into
state. So this root has **no provider at all**; its state holds only the rendered desired state, and a change shows up as
an update of `terraform_data.desired_state`. Gap recorded in `catalog/provider-gaps.yaml` (`delinea-dsv`).

## Desired state

| Object | Rendered as | DSV API (dsv-cli v1.41.1 `commands/*.go`) |
|---|---|---|
| Azure auth provider | `{name: secrets.auth_provider, type: azure, tenant_id: environment.tenant_id}` | `GET/POST /v1/config/auth[/<name>]` |
| users | `<prefix>-<env>-<identity>` (provider = auth provider, **externalId = identity resource id**), displayName carries the marker | `GET /v1/users/<provider>:<name>`, `POST /v1/users/` |
| policy | **one** policy at `secrets:<prefix>:<env>` with one permission per user: `read` on exactly its `secrets:<prefix>:<env>:<name>` paths; `publish:<publisher>` = `create`,`update` on generated paths; `list:<checker>` = `list` on `secrets:<prefix>:<env>:<.*>` | `GET/POST/PUT /v1/config/policies[/<path>]` (`{path, policy: <json permissionDocument>, serialization: json}`) |

One policy with one permission per user (not one policy per user): DSV validates the resources of a policy against the
policy path and a path holds exactly one policy, and every secret of an environment lives under the same path
(`/<prefix>/<env>/<name>`, ADR-0001 section 14). Least privilege is per permission (subject = one user, resources = its
exact paths). Subjects use Delinea's documented form `users:<provider:username>`.

## Apply semantics (`dsv_apply.py`)

- `plan` (pipeline plan stage, `tools/secrets/hooks.py post-plan` on the saved plan's planned output): diff printed and
  appended to the plan summary; any DSV difference forces the apply stage even when Terraform has no changes.
- `apply` (apply stage, after `terraform apply`): converges idempotently, then re-diffs to prove convergence and runs
  `tools/secrets/check.py` (warning only).
- Never deletes. Objects it changes carry the marker (`managed-by:foundation-secrets`); operator-owned permissions in
  the same policy are kept verbatim; operator-created users that match (e.g. the bootstrap `deploy-agent` mapping) are
  adopted read-only; mismatching users/auth providers are **conflicts** (exit 1, nothing changed). Managed users of
  removed identities are reported as orphans.
- Authentication: the deploy agent's managed identity, mapped once to a DSV administrator by an operator
  (bootstrap/README.md "Delinea DSV prerequisites").

## Settings (`components.foundation-secrets`)

| Key | Default |
|---|---|
| `publisher_identity` | `deploy-agent` (runs `tools/secrets/publish.py` in the publisher component's apply job) |
| `checker_identity` | `deploy-agent` (`list` for `check.py`) |
| `excluded_identities` | `[]` |
| `marker` | `managed-by:foundation-secrets` |

## Cost at defaults

USD 0 in Azure (no Azure resources). DSV API calls are part of the Delinea subscription.

## Teardown and data retention

`terraform destroy` removes only this root's state; DSV users, permissions and secrets remain (dsv_apply never deletes).
Remove them with the dsv CLI after the environment is gone (docs/runbooks/teardown.md).

## Private networking

None in Azure. The deploy pool needs HTTPS egress to `<tenant>.secretsvaultcloud.<tld>`.

## Known limitations

- Verified against dsv-cli source (endpoints, methods, request bodies) and Delinea docs, and tested against the mock;
  **not run against a real DSV tenant**. Unverified: the exact GET response shape of policies (the tool accepts both a
  parsed `permissionDocument` and a JSON `policy` string) and that `GET /v1/users/<provider>:<name>` addresses
  federated users (dsv-cli converts `/` to `:` in names; the qualified name form is from the Delinea Azure docs).
- `provider`/`externalId` of a DSV user cannot be updated through the API (dsv-cli `user update` sends only password /
  displayName): changing an identity's resource id is a conflict that needs an operator.

## Validation

```bash
tools/validate/terraform.sh foundation/secrets   # fmt, init -backend=false, validate, terraform test (mock providers, no credentials)
python3 -m pytest tests/tools/test_secrets_tools.py -q   # dsv_apply plan/apply against tools/secrets/mock_dsv.py
```

## References

- https://docs.delinea.com/dsv/current/usage/auth-general/authazure
- https://docs.delinea.com/online-help/devops-secrets-vault/tutorials/policy.htm
- https://github.com/DelineaXPM/dsv-cli
- https://registry.terraform.io/providers/DelineaXPM/dsv/latest/docs
