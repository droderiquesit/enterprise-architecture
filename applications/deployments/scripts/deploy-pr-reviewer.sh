#!/usr/bin/env bash
# Deploy the automated PR reviewer's package (svc-pr-reviewer, eh-pr-reviewer zip) to the Flex Consumption app of
# foundation-pr-reviewer (one deploy: the package lands in contract.deployment_container), then smoke /api/healthz.
#
#   deploy-pr-reviewer.sh --root foundation/pr-reviewer [--metadata <build-metadata.json>]
#
# Trust boundary: the reviewer approves pull requests, so its code is deployed ONLY from main
# (Build.SourceBranch == refs/heads/main) and never from a PR build (Build.Reason == PullRequest); anything else exits
# without deploying. Package: build-metadata.json of svc-pr-reviewer (package_url + package_sha256; downloaded with
# Entra auth and sha256-verified). Called by pipelines/scripts/tf-apply.sh after the root's apply.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
LOGGER=deploy-pr-reviewer
# shellcheck source=lib.sh
source "$HERE/lib.sh"
ROOT="" ; META="${ARTIFACT_METADATA_DIR:-}/svc-pr-reviewer/build-metadata.json"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="$2"; shift 2 ;;
    --metadata) META="$2"; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) die "unknown argument $1" ;;
  esac
done
[[ -n "$ROOT" ]] || die "--root required"
if [[ "${BUILD_REASON:-}" == "PullRequest" || "${BUILD_SOURCEBRANCH:-}" != "refs/heads/main" ]]; then
  log INFO "not deploying the reviewer from '${BUILD_SOURCEBRANCH:-local}' (${BUILD_REASON:-local}): main only"
  exit 0
fi
[[ -f "$META" ]] || die "no build metadata for svc-pr-reviewer at $META (Build stage)"
url=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("package_url") or "")' "$META")
sha=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("package_sha256") or "")' "$META")
[[ -n "$url" && -n "$sha" ]] || die "build metadata has no package_url/package_sha256"
C=$(contract_json "$ROOT")
rg=$(jget "$C" 'd["resource_group_name"]'); name=$(jget "$C" 'd["function_app_name"]'); base=$(jget "$C" 'd["function_url"]')
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
fetch_package "$url" "$sha" "$WORK/pkg.zip"
az functionapp deployment config show -g "$rg" -n "$name" --query "storage.value" -o tsv >/dev/null \
  || die "Flex deployment storage not configured on $name"
with_retry az functionapp deployment source config-zip -g "$rg" -n "$name" --src "$WORK/pkg.zip" --only-show-errors >/dev/null
progress "deployed pr-reviewer"
log INFO "deployed $sha to $name"
poll_http "$base/api/healthz" "${SMOKE_ATTEMPTS:-30}" "${SMOKE_INTERVAL:-10}" || die "smoke failed: $base/api/healthz"
log INFO "smoke ok: $base/api/healthz"
