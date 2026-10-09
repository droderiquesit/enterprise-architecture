#!/usr/bin/env bash
# Telemetry transport & collection checks (portable Datadog package):
#   1. terraform fmt -check / init -backend=false / validate / test for every transport module + lab root
#   2. contract JSON-schema checks (obs-telemetry-transport, obs-kubernetes) on mock-provider plans
#   3. docker functional tests (Fluent Bit configs, OTel gateway, DBM) - pytest in this directory
# Env: TERRAFORM_BIN (default terraform), EH_NETWORK_TESTS=1 to include the host installer (needs internet).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
TF="${TERRAFORM_BIN:-terraform}"
rc=0
for d in modules/{instrumentation,fluent-bit,otel-collector,telemetry-transport,diagnostic-settings,azure-logs,log-management,azure-integration,host-agents,kubernetes,dbm} \
         lab/{azure-integration,telemetry-transport,diagnostics,hosts,kubernetes,dbm}; do
  dir="$ROOT/observability/$d"
  if (cd "$dir" && "$TF" fmt -check -recursive >/dev/null && "$TF" init -backend=false -input=false >/dev/null && "$TF" validate >/dev/null && "$TF" test >/tmp/tf-test-$$.log 2>&1); then
    echo "PASS terraform $d ($(grep -Eo '[0-9]+ passed' /tmp/tf-test-$$.log | tail -1))"
  else
    echo "FAIL terraform $d"; tail -30 /tmp/tf-test-$$.log 2>/dev/null || true; rc=1
  fi
done
rm -f /tmp/tf-test-$$.log
python3 "$HERE/contract_check.py" "$ROOT/observability/modules/telemetry-transport" "$ROOT/catalog/contracts/obs-telemetry-transport.v1.schema.json" --require-runs 4 || rc=1
python3 "$HERE/contract_check.py" "$ROOT/observability/lab/telemetry-transport" "$ROOT/catalog/contracts/obs-telemetry-transport.v1.schema.json" --require-runs 1 || rc=1
python3 "$HERE/contract_check.py" "$ROOT/observability/modules/kubernetes" "$ROOT/catalog/contracts/obs-kubernetes.v1.schema.json" --require-runs 1 || rc=1
python3 "$HERE/contract_check.py" "$ROOT/observability/lab/kubernetes" "$ROOT/catalog/contracts/obs-kubernetes.v1.schema.json" --require-runs 1 || rc=1
(cd "$HERE" && python3 -m pytest -q -p no:cacheprovider .) || rc=1
exit $rc
