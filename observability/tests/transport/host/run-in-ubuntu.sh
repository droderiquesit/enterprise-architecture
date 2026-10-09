#!/bin/bash
# Runs INSIDE ubuntu:24.04 (test harness): proxy CA for apt, systemctl stub, then the rendered installer twice.
set -e
export DEBIAN_FRONTEND=noninteractive
sed -i 's|http://|https://|g' /etc/apt/sources.list.d/ubuntu.sources
[ -f /ca.crt ] && echo 'Acquire::https::CaInfo "/ca.crt";' > /etc/apt/apt.conf.d/99proxyca
apt-get update -qq >/dev/null && apt-get install -y -qq curl gnupg diffutils ca-certificates >/dev/null 2>&1
[ -f /ca.crt ] && cp /ca.crt /usr/local/share/ca-certificates/proxy.crt && update-ca-certificates >/dev/null 2>&1 || true
cat > /usr/local/bin/systemctl <<'S'
#!/bin/sh
echo "systemctl-stub $*" >> /tmp/systemctl.log
case "$1" in is-active|list-unit-files) exit 1;; esac
exit 0
S
chmod +x /usr/local/bin/systemctl
mkdir -p /var/log/enterprise-hello && cp /samples/app.log /var/log/enterprise-hello/hello-worker.log
DD_API_KEY=test-not-real bash /installer.sh
echo "--- second run (idempotency)"
DD_API_KEY=test-not-real bash /installer.sh
echo "--- result"
dpkg-query -W fluent-bit; ls -la /etc/fluent-bit-eh /etc/fluent-bit-eh/lua; stat -c '%a %n' /etc/default/fluent-bit-eh
cat /etc/systemd/system/datadog-agent.service.d/eh-observability.conf
cat /tmp/systemctl.log
echo "--- agent-only host"
bash /installer-sqlvm.sh && ! dpkg-query -W fluent-bit-not-installed 2>/dev/null; echo AGENT_ONLY_OK
