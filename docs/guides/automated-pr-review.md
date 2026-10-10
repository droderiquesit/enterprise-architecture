# Automated PR review and approvals

Status: **implemented**, **locally-verified** against a fake Azure DevOps server with real git branches
([evidence](../evidence/local/pr-review/e2e-evidence.json)). Not deployed: no Azure DevOps organization or Azure
subscription is connected to this lab sandbox.

The lab reviews every pull request automatically with three cooperating parts:

| Part | What it does | Can approve? |
|---|---|---|
| **GitHub Copilot code review for Azure Repos** (Azure DevOps-native, public preview) | AI review: inline comments + suggestions, guided by `.azuredevops/copilot-instructions.md` and path-scoped `.azuredevops/instructions/*.instructions.md` (read from the target branch) | **No** - always a *Comment* review; never approves, requests changes, satisfies required reviewers or blocks merge |
| **eh-review policy bot** (`eh-pr-reviewer`, this guide) | deterministic rules, change classes, build/Copilot gating; summary thread, inline findings, required status `eh-review/policy`, vote | only a small deterministic allowlist |
| **Humans** | required reviewers on protected paths; resolve Copilot comments | yes |

The bot **auto-approves only** low-risk allowlisted changes after Copilot reviewed the current iteration and every
Copilot thread is resolved; everything else gets a review and needs a human.

| Piece | Path |
|---|---|
| Review engine (pure Python, also a CLI) | `tools/review/` |
| Decision policy (data, schema-validated) | `.review/policy.yaml`, schema `tools/review/policy.schema.json` |
| Trusted Azure Function (Python 3.13, v2 model) | `applications/services/pr-reviewer/` |
| Infrastructure (Flex Consumption, identity, storage) | `foundation/pr-reviewer/` (component `foundation-pr-reviewer`, contract v1) |
| Azure DevOps wiring + branch-policy fragment | `tools/review/ado_setup.py`, `tools/review/branch-policy-fragment.json` |
| Copilot review instructions | `.azuredevops/copilot-instructions.md`, `.azuredevops/instructions/*.instructions.md` (`applyTo` globs) |
| Copilot gating (reads Copilot threads) | `tools/review/copilot.py`, policy section `copilot` |
| Tests, fake Azure DevOps, local e2e | `tests/review/`, `applications/services/pr-reviewer/tests/` |

## 1. Security design

### Why the reviewer is not a pipeline job

A PR validation build in Azure DevOps runs the YAML **and** the code from the PR's *source* branch. Whatever that
build can reach, the PR author can reach (change the YAML, add a step that prints a token, patch a test to call the
API). PR builds therefore stay **credential-free** (ADR-0001 §14: Microsoft-hosted PR builds never fetch secrets) and
must not be the thing that votes.

The reviewer is instead a **trusted Azure Function deployed only from `main`** by the platform pipeline:

```
Azure DevOps ──service hook (HTTPS POST, Basic auth)──▶ /api/ado-webhook ──▶ Storage queue ──▶ review_worker
     ▲                                                      (validate, 202)        (identity)        │
     │                 REST api-version 7.1 with the reviewer's managed identity (Entra token)         │
     └─────── threads / PR status eh-review/policy / vote ◀──── tools/review engine ◀── PR diff as DATA ┘
```

- **The diff is data.** The worker reads the latest iteration (`pullRequests/{id}/iterations`,
  `iterations/{it}/changes`) and item content at the head and merge-base commits (`items?versionDescriptor…`). It
  never clones, checks out, builds, imports or executes anything from the PR. Rules read text, YAML and JSON.
- **The policy and registry are trusted inputs** read from the PR *target* branch head (`targetRefCommit`), never from
  the source branch, so a PR cannot loosen the policy it is judged by (`test_pr_cannot_loosen_its_own_policy`). A
  missing/invalid policy fails closed (status `error`, no vote).
- **Build results are read, not produced.** "Tests pass" comes from the PR's own build validation (policy
  evaluations API: Build policies `approved` on the latest iteration, not expired). The reviewer never runs
  `terraform`, test suites or generators on PR content — those belong to the PR build.
- **Changes to the reviewer or to pipelines can never be bot-approved** (`review-governance`, `pipeline-governance`
  classes are `never_approve`; a change to `.review/**` by a non-owner is a definite violation ⇒ vote reject).

### Webhook authentication

Service hook subscriptions (Web Hooks consumer `webHooks` / `httpRequest`) post to `https://<app>/api/ado-webhook`
with **HTTP Basic** credentials (`eh-review` + secret). The Functions auth level is `anonymous` on purpose (the
`code` key would be a second, unmanaged secret in the subscription URL); the app checks, in this order:

1. body ≤ 256 KiB; `Authorization` header compared with `hmac.compare_digest` against the current and previous secret
   (rotation) — nothing in the body is parsed before this;
2. `publisherId == "tfs"`, event type in `git.pullrequest.created | git.pullrequest.updated | ms.vss-code.git-pullrequest-comment-event`,
   organization (account id, optional), project id and repository id on the allowlist from trusted app settings;
3. replay: `createdDate` within 10 min (2 min clock skew) and the event `id` not seen before (per-instance cache;
   duplicates answer `200 duplicate`, so Azure DevOps retries do not double-queue).

Microsoft Learn notes that `httpHeaders` of a subscription are "viewable by anyone who has access to the service hook
subscription"; Basic credentials are therefore used instead of a custom header, `resourceDetailsToSend = minimal`, and
the payload is only used to pick *which* PR to re-read. Inbound traffic is additionally restricted to the
`AzureDevOps` **service tag** (Microsoft Learn, *Allowed IP addresses and domain URLs*: service tags are supported for
inbound connections from Azure DevOps, including service hooks), with an opt-out setting.

### Identity and least privilege

- User-assigned managed identity **`eh-id-pr-reviewer-<env>`**, created by `foundation/pr-reviewer` (not
  foundation-identity, so nothing else can use it).
- Added to the Azure DevOps organization as a user with **Basic** access (Repos needs Basic or higher), member of the
  project **Readers** group, plus a repository-scoped ACE: **Read + Contribute to pull requests** on the lab repository
  only (status posting requires *Contribute to pull requests*). No Build, Release, policy-edit or bypass permissions;
  never a member of a required-reviewer group.
- Tokens: Entra access token for Azure DevOps — resource `499b84ac-1321-427f-aa17-267ca6975798`, scope
  `499b84ac-1321-427f-aa17-267ca6975798/.default` (equivalently `https://app.vssps.visualstudio.com/.default`),
  verified on Microsoft Learn *Use service principals & managed identities in Azure DevOps* / *Issue Entra tokens*.
- Secrets: `WEBHOOK_SECRET=dsv://<prefix>/<env>/pr-reviewer-webhook-secret#value` and optional
  `ANTHROPIC_API_KEY=dsv://<prefix>/<env>/anthropic-api-key#value`, resolved at start-up by `hello_common` with the
  Function's managed identity (ADR-0001 §14). The DSV user + `read` permission on exactly those two paths are in the
  root's `dsv_desired_state` output (converged by `tools/secrets/dsv_apply.py`, own marker).

### Threats considered

| Threat | Control |
|---|---|
| PR modifies pipeline YAML to steal reviewer credentials | reviewer is not a pipeline job; PR builds hold no credentials |
| PR edits `.review/policy.yaml` / the reviewer to approve itself | policy read from target branch; governance classes never approved; non-owner policy edit ⇒ reject |
| Forged webhook / replay | constant-time Basic auth, allowlist, createdDate window, event-id cache; worker re-reads everything from ADO |
| Prompt injection in the diff | Copilot comments are only counted as open/resolved threads (text never interpreted) and can only withhold approval; optional Claude output is schema-validated and can only add findings; approval is computed by `decide.py` only |
| Human comment imitating a bot marker | only threads whose first comment's author is the bot are managed |
| Fake "succeeded" status by someone else | status policy restricted to the bot identity (`authorId`) |
| Stale approval after a new push | branch policy resets votes on push; status is per iteration and resets on source update |
| Committed secret | definite patterns ⇒ reject (-10); values never appear in comments or logs (only `<redacted>`) |
| Supply-chain via lockfiles | non-pin lines in requirements / non-npmjs `resolved` URLs ⇒ not a patch bump |

## 2. Review engine

`python3 -m tools.review --base origin/main --head HEAD --build-status green [--author you@example.com] [--json r.json]`
runs exactly the same engine on a local checkout (policy/registry from `--base`).

1. **Change analysis** — every changed path gets a *change class* (first match in `.review/policy.yaml`), components
   via `tools/changeset` (registry, `Graph`, `Fingerprinter.owns`, read-only), layers and transitive consumers.
   Lockfiles are refined into `dependency-patch` / `dependency-change` (requirements pins, package-lock v2/3,
   `.terraform.lock.hcl`, `Directory.Packages.props`, NuGet `packages.lock.json`); onboarding manifests into
   `observability-thresholds` (only numeric values at guarded paths, inside the guardrail range),
   `onboarding-manifest` (new, non-prod, schema-valid against `observability/schemas/onboarding-manifest.v1.schema.json`)
   or `observability-config`.
2. **Rules** (findings with severity, file/line, suggestion, stable fingerprint):
   - Terraform text rules: security-sensitive resource types (role assignments, federated credentials, NSGs/rules,
     routes, firewall, locks, policy, private endpoints, `azapi_resource`, …), resources removed without `moved`,
     `removed` blocks, `public_network_access(_enabled)` → enabled, shared keys / local auth enabled, TLS < 1.2,
     Internet/any sources, `prevent_destroy` removed, `ignore_changes` on security attributes, `terraform_remote_state`.
   - Secrets: private keys, storage/SAS keys, Anthropic/GitHub/AWS/Slack tokens, JWTs (definite ⇒ reject);
     credential-looking assignments (high); high-entropy tokens (medium). `dsv://`, `${…}`, `[[…]]`, placeholders are fine.
   - Size (files/changed lines), binary/oversized files, missing tests per component, dependency major/downgrade notes,
     owner-protected policy paths.
3. **AI review = GitHub Copilot** (`ai.provider: copilot`, default). The bot does not call any model; it reads
   Copilot's PR threads (first comment authored by an identity matching `copilot.reviewer_names` /
   `copilot.reviewer_ids`; default display name `GitHub Copilot`, no id hard-coded because none is documented):
   - active/pending Copilot threads ⇒ auto-approval withheld, vote none, status pending
     **"resolve Copilot comments"** (also holds the status after a human approval). They never cause
     wait-for-author or reject;
   - `copilot.required_before_auto_approve: true` (default) ⇒ no auto-approval until Copilot reviewed the current
     iteration; the job re-checks while waiting;
   - commits pushed after Copilot's newest comment ⇒ the summary says **"request a fresh Copilot review"**
     (Copilot does not re-review new commits automatically).
   Detection is a heuristic: there is no documented Copilot review-status API, so "reviewed the current iteration" =
   Copilot's newest comment is not older than the latest iteration's `createdDate` (Copilot appears as a reviewer with
   vote 0). A Copilot review that leaves no comment on a new iteration looks like "not reviewed yet": request a review
   or have a human approve. A user whose display name equals the matcher could fake a Copilot thread; it can only
   withhold or (for allowlisted classes) satisfy the Copilot gate, never approve - set `copilot.reviewer_ids` once the
   real id is observed. Copilot comment text is never interpreted (prompt injection in it changes nothing).

   **Alternative provider `claude`** (`ai.provider: claude`, `ai.enabled: true`, `ANTHROPIC_API_KEY` from DSV): the
   bot's own Claude review (`tools/review/ai.py`, official `anthropic` SDK 1.13.0,
   `client.beta.messages.create(model="claude-opus-5-5", output_config={"effort": "medium", "format": json_schema},
   betas=["server-side-fallback-2026-07-01"], fallbacks="default")`), bounded + redacted diff, schema-validated output,
   capped findings, cached per (head commit, policy hash); output can only add findings. Disabled by default.
4. **Decision** (`tools/review/decide.py`, strictest first):

| Outcome | Vote | Status | When |
|---|---|---|---|
| `reject` | -10 | failed | definite violation: committed secret, owner-protected policy changed by a non-owner |
| `wait-for-author` | -5 | failed | PR build validation failed; violation/AI finding at `wait_for_author_severities` |
| `no-vote` (pending build) | 0 | pending | build not green yet (re-checked every 2 min, bounded) |
| `no-vote` (Copilot gate) | 0 | pending | otherwise auto-approvable, but Copilot threads unresolved or no Copilot review of the current iteration |
| `approve` / `approve-with-suggestions` | 10 / 5 | succeeded | **all** files in `auto_approve_classes`, no finding at `blocking_severities`, build green, author ≠ bot, target not `release/*`, ≤ 40 files (5 when only low findings) |
| human required | `human_required_vote` (0, or 5) | pending → succeeded when a non-author human approved | everything else |

Auto-approvable classes: `docs`, `tests`, `generated` (the PR build's `--check` verifies generators), `dependency-patch`,
`observability-thresholds`, `onboarding-manifest`. Never approvable: `review-governance`, `pipeline-governance`,
`identity-secrets`, `network-security`, `evidence` (status claims, ADR-0001 §11), `prod-config`.

5. **Outputs** — one summary thread updated in place (hidden `<!-- eh-review:summary -->` marker + state marker with
   iteration/head/input hash), one inline thread per finding fingerprint (deduplicated across iterations, re-activated
   when a finding returns, set to `fixed` when it disappears), PR status `eh-review/policy` per iteration
   (`pullRequests/{id}/statuses`), vote via `PUT pullRequests/{id}/reviewers/{reviewerId}` only when it changes.
   Re-running with the same inputs writes nothing.

## 3. Branch policy (owned by the pipeline builder's `tools/ado/branch_policies.py`)

`python3 -m tools.review.ado_setup fragment` writes `tools/review/branch-policy-fragment.json`:

- **Status policy** `eh-review/policy`: required (blocking), *Apply by default*, **authorized identity = the reviewer**,
  reset when the source branch is updated, on `main` and `release/*`.
- **Required reviewers** (path filters) for every `protected` policy class — pipelines and governance, identity and
  secrets, network, prod configuration, the reviewer itself — creator vote does not count.
- **Minimum number of reviewers**: reset votes on push, creator vote does not count. With the required status, `1`
  lets the bot alone approve allowlisted changes; `2` means a human always approves (the bot's vote is one of two).

The bot vote is one reviewer; it can never satisfy a required-reviewer group (it is not a member) and the status stays
`pending` until a human approves anything outside the allowlist.

## 4. GitHub Copilot code review: setup, cost, limits

Checklist (Azure DevOps UI - no documented REST API for these toggles, none is scripted here):

1. **Enable** Copilot code review: organization (Project Collection Administrator) → project → repository toggles.
2. **Billing**: per token through the Azure subscription linked to the Azure DevOps organization (GitHub AI credits,
   meter **"GitHub Copilot for AzDO"**, tags `_organizationname_` / `_projectname_`). Create a **budget alert** in Cost
   Management filtered on that meter (and the tags) for the lab subscription.
3. **Branch policy** "Automatically request Copilot code review" on `main` and `release/*`.
4. **Branch policy "Check for comment resolution"** (Comment requirements) **required**, so Copilot and human threads
   must be resolved before completion (`tools/review/branch-policy-fragment.json` → `comment_resolution`).
5. **Compute**: Copilot runs on the organization's default Azure Pipelines (Microsoft-hosted) pool or a **Managed DevOps
   Pool with the latest Ubuntu image**; self-hosted pools and Windows images are not supported - keep the
   `foundation-deploy-agents` MDP option with an Ubuntu image (the VMSS self-hosted agents cannot run it).
6. Keep the service hook for `ms.vss-code.git-pullrequest-comment-event` (created by `ado_setup.py` by default) so the bot
   re-evaluates when Copilot comments or threads are resolved.
7. After the first Copilot review, copy the reviewer's Azure DevOps identity id into `copilot.reviewer_ids`.

Limits (Microsoft Learn): PR must be Active with no merge conflicts; ≤ 100 changed files/changes; repository ≤ 10 GB;
one review per merge commit; 5 concurrent reviews per organization. Larger PRs never get a Copilot review, so with
`required_before_auto_approve` they are never bot-approved (they exceed `max_files_for_auto_approve` anyway).

What Copilot cannot do: approve, request changes, satisfy required reviewers or block merge (only the required
comment-resolution policy makes its comments binding); re-review new commits automatically; run on self-hosted or
Windows pools; read instructions from the PR source branch (instructions come from the target branch - a PR cannot
weaken them for its own review; `.azuredevops/**` is a never-auto-approved `review-governance` path).

Cost: no fixed fee; token-based per review. Budget the meter rather than estimate per PR (token use depends on diff
size and instructions). The bot itself adds ≈ $0-2/month (Flex Consumption) - see `foundation/pr-reviewer/README.md`.

## 5. Setup (operator, once per organization)

1. Apply `foundation-pr-reviewer` (pipeline). Note `contract.identity_principal_id` and `contract.webhook_url`.
2. Create the secrets in DSV: `dsv secret create --path eh/<env>/pr-reviewer-webhook-secret --data '{"value":"<random 48 bytes>"}'`
   (and `anthropic-api-key` if AI is enabled); converge `dsv_desired_state` with `tools/secrets/dsv_apply.py`.
3. `python3 -m tools.review.ado_setup plan --org <org> --project-id <guid> --repository-id <guid> --function-url <webhook_url> --reviewer-object-id <principal id>`
   prints the exact REST requests; `apply` (with `ADO_TOKEN` of a Project Collection Administrator and `WEBHOOK_SECRET`)
   creates the service hooks, the Basic-access entitlement and the repository ACE idempotently.
4. Set `components.foundation-pr-reviewer.settings.ado.reviewer_id` to the identity's Azure DevOps id; re-apply.
5. Hand the branch-policy fragment to `tools/ado/branch_policies.py`.

## 6. Not verified (needs a real organization)

Real service hook delivery and Basic-auth input names (`basicAuthUsername`/`basicAuthPassword` — the Learn consumer
table lists the setting as *Basic authentication credentials*), a managed identity added as an Azure DevOps user and
its vote/status permissions, the Git security bit values (Read = 2, PullRequestContribute = 16384), the status-policy
setting names (`statusGenre`, `statusName`, `authorId`, `invalidateOnSourceUpdate`, `policyApplicability`), inline
thread anchoring in the web UI, `AzureDevOps` service tag coverage of service-hook senders, a live Claude API call
(tests use a fake client), and the real shape of Copilot's threads (author display/unique name and id, whether it
posts a summary thread, comment timestamps): tests use simulated Copilot threads in the fake server.
