#!/bin/bash
# Runs INSIDE ubuntu:24.04 (test harness, --network host): proxy CA for apt, systemctl stub, then the rendered
# installer twice. The mock DSV (tools/secrets/mock_dsv.py) listens on 127.0.0.1:<random port> on the docker host (rendered into dsv.json); the test
# adds DSV client credentials to /etc/eh-dsv/dsv.json (hosts use the managed identity via IMDS instead).
set -e
export DEBIAN_FRONTEND=noninteractive
sed -i 's|http://|https://|g' /etc/apt/sources.list.d/ubuntu.sources
[ -f /ca.crt ] && echo 'Acquire::https::CaInfo "/ca.crt";' > /etc/apt/apt.conf.d/99proxyca
apt-get update -qq >/dev/null && apt-get install -y -qq curl gnupg diffutils ca-certificates python3 sudo >/dev/null 2>&1
[ -f /ca.crt ] && cp /ca.crt /usr/local/share/ca-certificates/proxy.crt && update-ca-certificates >/dev/null 2>&1 || true
cat > /usr/local/bin/systemctl <<'S'
#!/bin/sh
echo "systemctl-stub $*" >> /tmp/systemctl.log
case "$1" in is-active|list-unit-files) exit 1;; esac
exit 0
S
chmod +x /usr/local/bin/systemctl
mkdir -p /var/log/enterprise-hello && cp /samples/app.log /var/log/enterprise-hello/hello-worker.log
bash /installer.sh
echo "--- second run (idempotency)"
bash /installer.sh
echo "--- result"
dpkg-query -W fluent-bit; dpkg-query -W datadog-agent || true
ls -la /etc/fluent-bit-eh /etc/fluent-bit-eh/lua; stat -c '%a %n' /etc/default/fluent-bit-eh
if grep -q DD_API_KEY /etc/default/fluent-bit-eh; then echo "KEY_IN_ENV_FILE"; fi
grep -E '^(api_key|secret_backend_command):' /etc/datadog-agent/datadog.yaml
stat -c '%a %U %n' /opt/eh-dsv-fetch/dsv-fetch /opt/eh-dsv-fetch/agent/dsv-fetch
cat /etc/systemd/system/datadog-agent.service.d/eh-observability.conf
cat /tmp/systemctl.log
echo "--- ExecStartPre (dsv-fetch -> tmpfs env file) + Fluent Bit dry-run with the real file"
python3 - <<'PY'
import json
p = "/etc/eh-dsv/dsv.json"; c = json.load(open(p))
c.update({"DSV_CLIENT_ID": "host-test", "DSV_CLIENT_SECRET": "host-test-secret"})
json.dump(c, open(p, "w"))
PY
install -d -m 0700 /run/fluent-bit-eh
pre="$(sed -n 's/^ExecStartPre=//p' /etc/systemd/system/fluent-bit-eh.service)"
$pre
stat -c '%a %n' /run/fluent-bit-eh/fluentbit-env.yaml
(set -a; . /etc/default/fluent-bit-eh; set +a; cd /etc/fluent-bit-eh && /opt/fluent-bit/bin/fluent-bit -c /etc/fluent-bit-eh/fluent-bit.yaml --dry-run)
echo "--- Agent secret backend as dd-agent"
echo '{"version":"1.0","secrets":["dsv://eh/test/datadog-api-key#value"]}' | sudo -u dd-agent /opt/eh-dsv-fetch/agent/dsv-fetch agent-backend --config /etc/eh-dsv/dsv.json | python3 -c 'import json,sys,hashlib; r=json.load(sys.stdin)["dsv://eh/test/datadog-api-key#value"]; print("BACKEND_OK" if r["error"] is None and hashlib.sha256(r["value"].encode()).hexdigest()==sys.argv[1] else "BACKEND_BAD", r["error"])' "$EXPECTED_KEY_SHA"
echo "--- agent-only host"
bash /installer-sqlvm.sh && ! dpkg-query -W fluent-bit-not-installed 2>/dev/null; echo AGENT_ONLY_OK
