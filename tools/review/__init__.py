"""eh-pr-reviewer engine: automated, policy-driven pull request review for Azure DevOps.

Pure Python (stdlib + PyYAML + jsonschema; `anthropic` only for the optional AI review). Imported by the trusted
Azure Function applications/services/pr-reviewer and runnable locally:

    python3 -m tools.review --base origin/main --head HEAD --build-status green

Modules
  model          data classes (FileChange, Finding, Decision, ReviewResult)
  policy         .review/policy.yaml loader + schema (policy.schema.json)
  analysis       change classes, component attribution (tools/changeset, read-only), dependency/observability refinement
  diffing        difflib line diffs
  secrets_scan   secret heuristics + redaction
  terraform_rules Terraform risk signals from text
  deps           lockfile version-bump classification
  observability  onboarding manifest threshold guardrails
  ai             optional Claude review (untrusted output, can only add findings)
  decide         deterministic decision (the only source of approvals)
  engine         orchestration
  render         PR summary / inline comment markdown with hidden markers
  ado            Azure DevOps REST client (api-version 7.1) + PR reader
  publish        idempotent threads / status / vote synchronisation
  webhook        service hook authentication, sanity and replay checks
  service        one review job end to end (Function queue trigger)
  ado_setup      service hooks, identity entitlement, branch policy fragment (dry-run by default)
See docs/guides/automated-pr-review.md.
"""
