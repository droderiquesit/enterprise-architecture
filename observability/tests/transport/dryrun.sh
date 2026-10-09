#!/usr/bin/env bash
# Dry-run (`fluent-bit --dry-run`, verified flag in 5.1.3: "-D, --dry-run") every Fluent Bit config in
# observability/config/fluent-bit/ with the pinned image and a representative environment.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$(cd "$HERE/../../config/fluent-bit" && pwd)"
IMAGE="${FLUENT_BIT_IMAGE:-fluent/fluent-bit:5.1.3}"
ENV_ARGS=(
  -e LOG_FILE_PATH=/var/log/app/app.log -e FLB_STATE_DIR=/tmp/flb -e FLB_LOG_PATHS=/var/log/app/*.log
  -e FLB_DD_HOST=http-intake.logs.datadoghq.com -e FLB_DD_PORT=443 -e FLB_DD_TLS=on -e DD_API_KEY=dry-run-not-a-key
  -e FLB_DD_SOURCE=csharp -e FLB_DD_SERVICE=hello-test -e FLB_DD_TAGS=env:test
  -e FLB_FORWARD_HOST=aggregator -e FLB_FORWARD_PORT=24224 -e FLB_FORWARD_TLS=off -e FLB_FORWARD_TLS_VERIFY=on
  -e FLB_FORWARD_SHARED_KEY=dry-run -e FLB_FORWARD_TLS_CRT= -e FLB_FORWARD_TLS_KEY=
  -e EVENTHUB_BROKERS=example.servicebus.windows.net:9093 -e EVENTHUB_TOPICS=app-logs,platform-logs
  -e EVENTHUB_CONSUMER_GROUP=fluent-bit -e KAFKA_SECURITY_PROTOCOL=SASL_SSL -e 'EVENTHUB_CONNECTION_STRING=Endpoint=sb://example/;SharedAccessKeyName=x;SharedAccessKey=y'
  -e 'FLB_EXCLUDE_PATHS=/var/log/containers/*_kube-system_*.log' -e FLB_THROTTLE_RATE=2000 -e FLB_SYSTEMD_UNIT=hello-worker.service
)
rc=0
for f in sidecar.yaml sidecar-forward.yaml aggregator.yaml k8s-daemonset.yaml linux-host.yaml windows-host.yaml; do
  out="$(docker run --rm "${ENV_ARGS[@]}" -v "$CFG:/fluent-bit/etc/eh:ro" "$IMAGE" -c "/fluent-bit/etc/eh/$f" --dry-run 2>&1 || true)"
  if grep -q "configuration test is successful" <<<"$out" && ! grep -q "\[error\]" <<<"$out"; then
    echo "PASS dry-run $f"
  else
    echo "FAIL dry-run $f"; echo "$out" | grep -v '^[|_ ]' | tail -15; rc=1
  fi
done
# linux-host with the journald add-on swapped in as inputs-extra.yaml
TMP="$(mktemp -d)"; cp -r "$CFG/." "$TMP/"; cp "$CFG/linux-host-systemd.yaml" "$TMP/inputs-extra.yaml"
out="$(docker run --rm "${ENV_ARGS[@]}" -v "$TMP:/fluent-bit/etc/eh:ro" "$IMAGE" -c /fluent-bit/etc/eh/linux-host.yaml --dry-run 2>&1 || true)"
if grep -q "configuration test is successful" <<<"$out" && ! grep -q "\[error\]" <<<"$out"; then echo "PASS dry-run linux-host.yaml+systemd"; else echo "FAIL linux-host+systemd"; echo "$out" | tail -10; rc=1; fi
rm -rf "$TMP"
exit $rc
