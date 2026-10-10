# foundation-governance

- **Owner:** platform-engineering · **Component id:** `foundation-governance` · **State key:** `<env>/foundation-governance.tfstate`
- **Purpose:** cost and policy guard rails for the lab: a monthly consumption budget with e-mail/action-group alerts,
  subscription-scope Azure Policy assignments (required RG tags, allowed locations, no public IPs on NICs) carrying
  expiration metadata, and a read-only script to find expired lab resources.
- **Consumes:** nothing. **Produces:** `foundation-governance` v1 ([schema](../../catalog/contracts/foundation-governance.v1.schema.json)).
- **Status:** implemented (validate + mock tests). Not deployed.

> **Azure budgets alert; they do not cap or stop spend.** When a threshold is crossed Azure sends notifications
> (and can trigger the action group); resources keep running and keep costing money. Stopping spend is a human
> (or automation you add) decision. Cost data also lags by up to ~24 hours.

## Budget

| | Default |
|---|---|
| Scope | subscription (`budget.scope = "resource_group"` + `resource_group_ids` for per-RG budgets) |
| Amount | `settings.budget.amount`, else the environment global `budget.monthly_amount` (`var.budget`, rendered by `tools/config/render.py`; dev: 500), else 300 — billing currency, monthly grain |
| Filter | tags `application = enterprise-hello` AND `env = <env>` (safe in shared subscriptions; `filter_by_lab_tags = false` to count everything) |
| Notifications | Actual ≥ 50 %, 80 %, 100 %; Forecasted > 80 %, 100 % (Azure allows max 5) |
| Recipients | `settings.budget.contact_emails`, else the global `budget.contact_emails`, else `environment.owner` if it is an e-mail; + action group `budget` (e-mail receivers) |
| Start date | first day of the month of first apply (`time_static`), never changes afterwards |

## Policy assignments (subscription scope, built-in definitions verified on Learn 2026-10-09)

| Assignment | Definition | Default mode |
|---|---|---|
| `eh-<env>-rg-tag-{env,owner,expires-on}` (`_` → `-`) | Require a tag on resource groups `96670d01-0a4d-4649-9c89-2d3abc0a5025` | **audit** (`enforce = false` → DoNotEnforce) |
| `eh-<env>-allowed-locations` | Allowed locations `e56962a6-4747-49cd-b67b-bf8b01975c4c` (excludes RGs and `global`) | **enforced**, `[environment.location]` |
| `eh-<env>-nic-no-public-ip` | Network interfaces should not have public IPs `83a86a26-fd1f-447c-b59d-e51f44264114` | **audit**; `nic_public_ip_allowlisted_rg_ids` added to `not_scopes` |

Every assignment carries `metadata = {application, env, owner, expires_on, managed_by, repository}`.
Why tag policies default to audit: platform-managed resource groups (AKS node RG `MC_*`, ARO cluster RG, Functions/ACA
infrastructure RGs) are created by resource providers that do not copy our tags; ARO's support policy explicitly forbids
tag-requirement policies on its managed RG. Enforce only after adding those RGs to `policy.not_scopes`.
Assigning policy needs `Microsoft.Authorization/policyAssignments/write`: bootstrap gives the apply identity
*Resource Policy Contributor* (`apply_policy_contributor = true`).

## Finding expired lab resources

[`scripts/find-expired.sh`](scripts/find-expired.sh) runs Azure Resource Graph queries limited to
`tags.application == 'enterprise-hello'` **and** `tags.repository == 'azure-enterprise-observability-lab'` and
`todatetime(tags.expires_on) < now`. It lists expired resource groups and resources, and with
`--print-delete-commands` prints (never runs) `az group delete` commands for review. Core query:

```kusto
resourcecontainers
| where type =~ 'microsoft.resources/subscriptions/resourcegroups'
| where tostring(tags['application']) == 'enterprise-hello'
| where tostring(tags['repository']) == 'azure-enterprise-observability-lab'
| extend expires_on = todatetime(tostring(tags['expires_on']))
| where isnotnull(expires_on) and expires_on < now()
| project subscriptionId, resourceGroup = name, env = tostring(tags['env']), owner = tostring(tags['owner']), expires_on
```

## Settings (`components.foundation-governance`)

`budget.{amount, scope, resource_group_ids, contact_emails, actual_thresholds, forecast_thresholds, filter_by_lab_tags, start_date, end_date}`,
`action_group_short_name` (≤ 12 chars), `policy.{allowed_locations, allowed_locations_enforce, required_rg_tags, required_rg_tags_enforce,
deny_nic_public_ip, deny_nic_public_ip_enforce, nic_public_ip_allowlisted_rg_ids, not_scopes}`. See `variables.tf` for defaults.

## Cost at defaults

USD 0: budgets, policy assignments and e-mail action-group notifications are free.

## Teardown and data retention

No data. Destroying removes the budget, action group and assignments (compliance history stays in Azure Policy for its
retention period). Destroy last so cost alerts cover the teardown of everything else.

## Known limitations

- Subscription-scope assignments affect *all* resources in the subscription (not only the lab) — in shared subscriptions use
  `policy.not_scopes` or keep audit mode.
- Budget currency is the billing account currency; the `budget.currency` value in environment.yaml is informational.

## References

- Budgets: https://learn.microsoft.com/azure/cost-management-billing/costs/tutorial-acm-create-budgets
- Tag policies: https://learn.microsoft.com/azure/azure-resource-manager/management/tag-policies
- Built-in policies: https://learn.microsoft.com/azure/governance/policy/samples/built-in-policies
- Resource Graph: https://learn.microsoft.com/azure/governance/resource-graph/overview

### GitHub Copilot code review budget

`settings.copilot_review_budget` (on by default, USD 100/month) creates an alert-only budget filtered to meter
category `GitHub` / subcategory `GitHub Copilot for AzDO` - the meter Microsoft uses for Copilot code review in
Azure Repos ([Microsoft Learn](https://learn.microsoft.com/azure/devops/repos/git/copilot-code-reviews#billing)).
Charges land on the subscription **linked to the Azure DevOps organization**; set `subscription_id` when that is not
the lab subscription (the apply identity then needs Cost Management Contributor there). Budgets notify; they never
stop reviews.
