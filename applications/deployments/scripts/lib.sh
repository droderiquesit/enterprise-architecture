#!/usr/bin/env bash
# Shared helpers for applications/deployments/scripts/*.sh (sourced, not executed).
set -euo pipefail

log() { printf '{"timestamp":"%s","level":"%s","message":"%s","logger":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "${LOGGER:-deploy}" >&2; }
die() { log ERROR "$1"; exit 1; }
# progress <line>: deployment progress for rollback.sh (which apps were deployed / swapped).
progress() { if [[ -n "${DEPLOY_PROGRESS_FILE:-}" ]]; then echo "$1" >> "$DEPLOY_PROGRESS_FILE"; fi; }

# with_retry <cmd...>: bounded retry of an IDEMPOTENT az call (package upload / zip deploy / download) when
# tools/deploy/retry_rules.yaml classifies the failure as transient (throttling, 5xx, timeouts, DNS). Never use it for
# slot swaps or anything that is not safe to repeat. WITH_RETRY_ATTEMPTS (default 3), backoff 15 s, 30 s, ...
with_retry() {
  local attempts="${WITH_RETRY_ATTEMPTS:-3}" i out rc cls repo
  repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  out="$(mktemp)"
  for ((i = 1; i <= attempts; i++)); do
    set +e; "$@" > >(tee "$out") 2> >(tee -a "$out" >&2); rc=$?; set -e
    if [[ $rc -eq 0 ]]; then rm -f "$out"; return 0; fi
    cls="$(python3 "$repo/tools/deploy/retry.py" classify --file "$out" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["kind"])' 2>/dev/null || echo unknown)"
    if [[ "$cls" != "transient" || $i -eq $attempts ]]; then
      log ERROR "$1 failed (exit $rc, class $cls, attempt $i/$attempts)"; rm -f "$out"; return $rc
    fi
    log WARNING "$1 transient failure (attempt $i/$attempts); retrying in $((15 * i))s"
    sleep $((15 * i))
  done
}

# contract_json <file|root-dir>: prints the contract data object. Accepts a published envelope ({"data": ...}),
# `terraform output -json contract` ({"value": ...} or the bare object), or a Terraform root directory.
contract_json() {
  local src="$1"
  if [[ -d "$src" ]]; then terraform -chdir="$src" output -json contract; return; fi
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d=d.get("data",d) if isinstance(d,dict) else d; d=d.get("value",d) if isinstance(d,dict) and "value" in d and "sensitive" in d else d; print(json.dumps(d))' "$src"
}

# jget <json> <python expression over d>: evaluate a small expression against the contract.
jget() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); r=eval(sys.argv[2]); print(r if isinstance(r,str) else json.dumps(r))' "$1" "$2"; }

# fetch_package <https blob url> <sha256> <dest>: Entra-authenticated download (no SAS) + integrity check.
fetch_package() {
  local url="$1" sha="$2" dest="$3" account container blob
  account=$(sed -E 's#https://([^.]+)\..*#\1#' <<<"$url"); container=$(cut -d/ -f4 <<<"$url"); blob=$(cut -d/ -f5- <<<"$url")
  with_retry az storage blob download --auth-mode login --account-name "$account" --container-name "$container" --name "$blob" \
    --file "$dest" --only-show-errors >/dev/null || die "package download failed: $url"
  echo "$sha  $dest" | sha256sum -c --status || die "sha256 mismatch for $url"
}

# poll_http <url> <attempts> <interval>: bounded polling until HTTP 200.
poll_http() {
  local url="$1" attempts="${2:-30}" interval="${3:-10}" i
  for ((i = 1; i <= attempts; i++)); do
    if curl -fsS --max-time 10 -o /dev/null "$url"; then return 0; fi
    sleep "$interval"
  done
  return 1
}
