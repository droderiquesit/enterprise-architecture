#!/usr/bin/env bash
# Runs the rendered Linux VM Application setup script in ubuntu:24.04 WITHOUT network: curl (IMDS + Datadog install
# script), systemctl and the Agent package are stubbed; dsv-fetch is the fake fixture binary. Prints the resulting
# files for test_linux_setup.py.
set -euo pipefail
STUB=/stub
mkdir -p "$STUB" /var/lib/fake-dd
cat > "$STUB/curl" <<'CURL'
#!/usr/bin/env bash
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2 ;; http*) url=$1; shift ;; *) shift ;; esac; done
case "$url" in
  *169.254.169.254*) printf '%s' "$FAKE_TAGS" ;;
  *install_script_agent7.sh)
    cat > "$out" <<'INST'
#!/usr/bin/env bash
# fake Datadog install script: requires an existing datadog.yaml in DD_INSTALL_ONLY mode (no DD_API_KEY)
set -e
[ -f /etc/datadog-agent/datadog.yaml ] || { echo "no datadog.yaml and no DD_API_KEY"; exit 9; }
getent passwd dd-agent >/dev/null || useradd -r -U -M -s /usr/sbin/nologin dd-agent
env | grep -E '^DD_' | grep -v API_KEY | sort > /var/lib/fake-dd/install-env
if [ "${DD_APM_INSTRUMENTATION_ENABLED:-}" = host ]; then mkdir -p /opt/datadog-packages/datadog-apm-inject; fi
touch /var/lib/fake-dd/installed
INST
    ;;
  *) echo "unexpected curl $url" >&2; exit 7 ;;
esac
CURL
cat > "$STUB/systemctl" <<'SYS'
#!/usr/bin/env bash
echo "systemctl $*" >> /var/lib/fake-dd/systemctl.log
case "$1" in is-active) [ -f /var/lib/fake-dd/active ] ;; restart) touch /var/lib/fake-dd/active ;; *) exit 0 ;; esac
SYS
cat > "$STUB/dpkg-query" <<'DPKG'
#!/usr/bin/env bash
if [ "${*: -1}" = datadog-agent ]; then [ -f /var/lib/fake-dd/installed ] && printf '1:7.84.2-1' && exit 0; exit 1; fi
exec /usr/bin/dpkg-query "$@"
DPKG
cat > "$STUB/apt-mark" <<'APT'
#!/usr/bin/env bash
exit 0
APT
chmod +x "$STUB"/*
export PATH="$STUB:$PATH"
APPDIR=/var/lib/waagent/Microsoft.CPlat.Core.VMApplicationManagerLinux/datadog-agent-linux/1.0.0
mkdir -p "$APPDIR"
cp /in/datadog-agent-setup.sh /in/dsv-fetch "$APPDIR/"
cd "$APPDIR"
echo "=== RUN1"; bash ./datadog-agent-setup.sh install
echo "=== RUN2"; bash ./datadog-agent-setup.sh update
echo "=== DATADOG_YAML"; cat /etc/datadog-agent/datadog.yaml
echo "=== LOGS_CONF"; cat /etc/datadog-agent/conf.d/eh-host-logs.d/conf.yaml
echo "=== DSV_JSON"; cat /etc/datadog-dsv/dsv.json
echo "=== INSTALL_ENV"; cat /var/lib/fake-dd/install-env
echo "=== PERMS"; stat -c '%a %U %n' /opt/datadog-dsv/dsv-fetch /etc/datadog-agent/datadog.yaml
stat -c '%G %n' /etc/datadog-agent/datadog.yaml
echo "=== UNIT"; cat /etc/systemd/system/datadog-agent.service.d/eh-vmapp.conf
echo "=== TAMPER"; printf 'x' >> ./dsv-fetch; if bash ./datadog-agent-setup.sh update; then echo TAMPER_ACCEPTED; else echo "TAMPER_REJECTED rc=$?"; fi
echo "=== REMOVE"; bash ./datadog-agent-setup.sh remove; [ ! -e /opt/datadog-dsv ] && [ ! -e /etc/datadog-dsv ] && echo REMOVED_OK
