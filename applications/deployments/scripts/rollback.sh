#!/usr/bin/env bash
# Automatic rollback of an application deployment root after a failed code deploy / smoke test:
#
#   rollback.sh --component <id> --root <terraform root dir> [--env <env>] [--progress <deploy-zip progress file>] [--out <json>]
#
# Thin wrapper around tools/deploy/rollback.py (the actions are planned from the new contract, the previous
# contract envelope and contract.rollback.method; see that file). Called by pipelines/scripts/tf-apply.sh only for
# applications/deployments/* roots - infrastructure is never rolled back automatically. Exit 0 = rolled back and the
# previous release passed smoke; exit 1 = rollback failed (operator action: docs/runbooks/rollback.md).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
LOGGER=rollback
# shellcheck source=lib.sh
source "$HERE/lib.sh"
COMPONENT="" ; ROOT="" ; ENV_NAME="${LAB_ENV:-}" ; PROGRESS="${DEPLOY_PROGRESS_FILE:-}" ; OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --component) COMPONENT="$2"; shift 2 ;;
    --root) ROOT="$2"; shift 2 ;;
    --env) ENV_NAME="$2"; shift 2 ;;
    --progress) PROGRESS="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) die "unknown argument $1" ;;
  esac
done
[[ -n "$COMPONENT" && -n "$ROOT" && -n "$ENV_NAME" ]] || die "--component, --root and --env (or LAB_ENV) required"
args=(run --env "$ENV_NAME" --component "$COMPONENT" --root "$ROOT")
[[ -n "$PROGRESS" ]] && args+=(--progress "$PROGRESS")
[[ -n "$OUT" ]] && args+=(--out "$OUT")
cd "$HERE/../../.."
exec python3 tools/deploy/rollback.py "${args[@]}"
