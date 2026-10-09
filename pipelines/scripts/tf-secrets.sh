#!/usr/bin/env bash
# Source (do not execute). tf_secret <cmd...>: run one command with the component's DSV secrets in ITS environment only.
# When TF_SECRET_ENV is 'true' the command runs through `tools/secrets/fetch.py exec --component <id>`, which resolves
# the registry `secret_env` (catalog/components.yaml) from Delinea DSV with the deploy agent's managed identity and
# execs the command; values are never printed and never exported into this shell (ADR-0001 section 14).
# Requires: $component, $LAB_ENV.
tf_secret() {
  if [[ "${TF_SECRET_ENV:-false}" == "true" ]]; then
    python3 tools/secrets/fetch.py exec --env "$LAB_ENV" --component "$component" -- "$@"
  else
    "$@"
  fi
}
