# foundation/pr-reviewer — trusted automated PR reviewer (component `foundation-pr-reviewer`)

**Owner:** platform security / DevSecOps (`platform-security@example.com`). **Layer:** foundation. **State key:** `<env>/foundation-pr-reviewer.tfstate`.

## Purpose

Hosts **eh-pr-reviewer** (`applications/services/pr-reviewer`, engine `tools/review`): an Azure Function that Azure DevOps
service hooks call on `git.pullrequest.created` / `git.pullrequest.updated`. It reads the PR **as data** through the
Azure DevOps REST API with its own managed identity, posts a summary thread, inline findings, the PR status
`eh-review/policy` and a vote. It never checks out, builds or runs PR code. Design and threat model:
[docs/guides/automated-pr-review.md](../../docs/guides/automated-pr-review.md).

This root deliberately owns the identity, the runtime storage, the Flex Consumption plan **and** the function app
(ADR-0001 §3 normally puts plans in `platform/` and apps in `applications/deployments/`): the reviewer is lab
governance tooling, not an Enterprise Hello workload, and keeping its whole trust boundary in one root means one
owner, one deployment path (from `main` only) and an identity that nothing else can use. The OWN007 exceptions are
annotated in `main.tf` (`# ownership:allow OWN007`).

## Resources

| Resource | Notes |
|---|---|
| `azurerm_user_assigned_identity.pr_reviewer` | `eh-id-pr-reviewer-<env>`; created **here** (not in foundation-identity). Added to Azure DevOps as a user (Basic) with Read + *Contribute to pull requests* on the lab repository only (`python3 -m tools.review.ado_setup`). |
| `azurerm_storage_account.this` | host storage (`AzureWebJobsStorage__*` identity-based), deployment container `deploy`, lease container `locks`, queue `pr-review`. Shared keys **off**, Entra only. |
| `azurerm_role_assignment.storage` (×3) | Blob Data Owner / Queue Data Contributor / Table Data Contributor for the reviewer identity on this account only. |
| `azurerm_service_plan.this` | `FC1` (Flex Consumption, Linux). |
| `azurerm_function_app_flex_consumption.this` | Python 3.13, 512 MB instances, max 40 instances, HTTPS only, basic publishing credentials off, inbound **Deny** except service tag `AzureDevOps` (+ optional ranges, by default the deploy agents' egress IPs for smoke tests). |
| `module.storage_pe` (vnet mode) | blob/queue/table private endpoints (DNS zones from foundation-network). |

No AzAPI resources (no provider gaps).

## Consumed contracts

- `foundation-identity` **v2** — only `secrets.{tenant, tld, base_url, base_path, auth_provider}` (DSV coordinates).
- `foundation-network` v1 — optional; only for `network_mode = "vnet"` (`subnets.flex-integration`, `subnets.private-endpoints`,
  `private_dns_zones.{blob,queue,table}`, `egress.public_ips`).

## Produced contract — `foundation-pr-reviewer` v1

`catalog/contracts/foundation-pr-reviewer.v1.schema.json`: `function_url`, `webhook_url`, `webhook_path`
(`/api/ado-webhook`), `webhook_username`, `webhook_secret_ref` (a `dsv://` reference, never the value),
`identity_{id,name,client_id,principal_id}`, `deployment_container`, `storage_account_name`, `queue_name`,
`network_mode`, `inbound_service_tag`, `status_context` (`eh-review/policy`). Also `dsv_desired_state` (same format as
foundation-secrets, own marker `managed-by:foundation-pr-reviewer`): one DSV user for the identity (externalId = its
resource id) with `read` on exactly `pr-reviewer-webhook-secret` (+ `anthropic-api-key` when `ai_enabled`).

## Settings (`components.foundation-pr-reviewer`)

| Setting | Default | Meaning |
|---|---|---|
| `network_mode` | `public` | `public`: no VNet integration, storage public but Entra-only. `vnet`: Flex VNet integration + private storage. The app's inbound endpoint is public in both (service hooks need a public HTTPS URL). |
| `restrict_to_azure_devops` | `true` | inbound only from the `AzureDevOps` service tag (Microsoft Learn: "Azure Service Tags are supported only for inbound connections"; App Service access restrictions support service tags). |
| `allowed_ip_ranges` / `allow_deploy_agent_egress` | `[]` / `true` | extra allowed inbound ranges (smoke tests from the deploy agents). |
| `maximum_instance_count`, `instance_memory_in_mb` | 40, 512 | Flex scale ceiling / instance size. |
| `ado.{organization, project, project_id, repository_ids, account_ids, reviewer_id}` | placeholders | webhook allowlist + REST target. `reviewer_id` = the identity's Azure DevOps id (else read from connectionData). |
| `webhook_username`, `webhook_secret_name` | `eh-review`, `pr-reviewer-webhook-secret` | HTTP Basic credentials of the service hook; the value lives only in DSV. |
| `ai_enabled`, `anthropic_api_key_name` | `false`, `anthropic-api-key` | adds `ANTHROPIC_API_KEY=dsv://…`; the AI review must also be enabled in `.review/policy.yaml`. |
| `otlp_endpoint` | `""` | OTLP/HTTP endpoint (observability OTel gateway) for traces. |

## Cost at defaults (approx., swedencentral, Oct 2026)

Flex Consumption bills per execution/GB-s with a monthly free grant; a lab with ~50 PR events/day uses a few hundred
GB-s ⇒ **≈ $0–2/month**. Storage (LRS, KBs of queue/lease data, one deployment package) **< $1/month**. Optional AI review:
Claude Opus 5.5 at $4 / $20 per MTok — a 30k-token excerpt + 2k output ≈ $0.16 per reviewed iteration (cached per head
commit); `claude-sonnet-5-5` ($2 / $10) halves it. No always-ready instances (cold starts of a few seconds are fine: the
webhook acknowledges after enqueueing).

## Teardown / data retention

Destroying the root deletes the app, the queue (pending jobs are lost — the next PR event re-reviews), lease blobs and the
identity. Remove the Azure DevOps user and the service hook subscriptions afterwards (application identities are not
removed from Azure DevOps automatically). Blob soft delete keeps deleted deployment packages for `blob_retention_days` (7).
PR threads/statuses/votes stay in Azure DevOps.

## Private networking notes

The inbound endpoint must be public (Azure DevOps service hooks cannot target private/loopback addresses); defence in
depth: AzureDevOps service tag restriction, HTTPS only, constant-time HTTP Basic check, payload allowlist, replay window.
Outbound calls go to `dev.azure.com`, `vssps`, Entra ID, Delinea DSV and (optional) `api.anthropic.com`.

## Known limitations

- Not deployed or verified in Azure (no credentials in this lab sandbox) — status **implemented**.
- The `AzureDevOps` service tag covers Azure DevOps inbound connections per Microsoft Learn; confirm it includes the
  service-hook senders of your organization's region before relying on it (set `restrict_to_azure_devops = false` to fall back
  to secret-only authentication).
- One Flex app per plan (FC1). Replay protection's event-id cache is per instance (processing is idempotent per PR iteration).

## Validation

```bash
tools/validate/terraform.sh foundation/pr-reviewer   # fmt, init -backend=false, validate, terraform test (mock providers, no credentials)
```

## Docs

- Flex Consumption: https://learn.microsoft.com/azure/azure-functions/flex-consumption-plan
- Identity-based connections: https://learn.microsoft.com/azure/azure-functions/functions-reference#configure-an-identity-based-connection
- Service principals & managed identities in Azure DevOps: https://learn.microsoft.com/azure/devops/integrate/get-started/authentication/service-principal-managed-identity
- Allowed IP addresses / service tag: https://learn.microsoft.com/azure/devops/organizations/security/allow-list-ip-url
- Web Hooks consumer: https://learn.microsoft.com/azure/devops/service-hooks/consumers#webhooks
