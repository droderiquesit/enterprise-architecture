#!/usr/bin/env bash
# Release directory names are generated here (validated VERSION + UTC timestamp), so ls ordering is safe.
# shellcheck disable=SC2010,SC2012
# install.sh - install/upgrade hello-worker on a Linux VM/VMSS instance from a release zip.
#
# Usage (as root, e.g. from an Azure VM Run Command):
#   install.sh <package-url|path> [--env-file <path>] [--no-start]
#   install.sh --rollback
#
# <package-url> may be a SAS URL, or a plain https blob URL when PACKAGE_AUTH=msi (token from IMDS for
# https://storage.azure.com/ using AZURE_CLIENT_ID = the VM's user-assigned identity).
# Package layout (built by applications/python/build.sh): wheels/*.whl (offline wheelhouse incl.
# hello-worker + hello-common), requirements.txt, VERSION, deploy/{hello-worker.service,install.sh,...}.
#
# Behaviour: releases are unpacked to /opt/hello-worker/releases/<version>-<utc timestamp>, each with its own
# venv (Python 3.13, offline pip install --no-index); /opt/hello-worker/current is switched atomically; the unit
# is restarted and /healthz is probed - on failure the previous release is restored automatically.
# Env:  PYTHON_BIN (default python3.13), INSTALL_PYTHON=1 (apt deadsnakes/py3.13 if missing, needs egress),
#       SKIP_SYSTEMD=1 (containers/tests), KEEP_RELEASES (3), HEALTH_URL (http://127.0.0.1:8081/healthz)
set -euo pipefail

APP=hello-worker
BASE=/opt/${APP}
ETC=/etc/${APP}
LOGDIR=/var/log/${APP}
UNIT=/etc/systemd/system/${APP}.service
PYTHON_BIN=${PYTHON_BIN:-python3.13}
KEEP_RELEASES=${KEEP_RELEASES:-3}
HEALTH_URL=${HEALTH_URL:-http://127.0.0.1:8081/healthz}
SKIP_SYSTEMD=${SKIP_SYSTEMD:-0}

log() { printf '{"timestamp":"%s","level":"%s","message":"%s","logger":"install.sh","service":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" "$1" "$2" "$APP"; }
die() { log ERROR "$1"; exit 1; }

[[ $(id -u) -eq 0 ]] || die "must run as root"

PKG="" ; ENV_FILE="" ; NO_START=0 ; ROLLBACK=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file) ENV_FILE="$2"; shift 2 ;;
    --no-start) NO_START=1; shift ;;
    --rollback) ROLLBACK=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) PKG="$1"; shift ;;
  esac
done

restart_and_check() {
  [[ $SKIP_SYSTEMD == 1 || $NO_START == 1 ]] && return 0
  systemctl daemon-reload
  systemctl enable "${APP}.service" >/dev/null
  systemctl restart "${APP}.service"
  for _ in $(seq 1 30); do
    if curl -fsS --max-time 2 "$HEALTH_URL" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  return 1
}

switch_to() {  # atomic symlink swap
  ln -sfn "$1" "${BASE}/current.new"
  mv -Tf "${BASE}/current.new" "${BASE}/current"
}

if [[ $ROLLBACK == 1 ]]; then
  current=$(readlink -f "${BASE}/current" || true)
  previous=$(ls -1dt "${BASE}"/releases/* 2>/dev/null | grep -vx "$current" | head -1 || true)
  [[ -n "$previous" ]] || die "no previous release to roll back to"
  switch_to "$previous"
  restart_and_check || die "rollback release failed health check"
  log INFO "rolled back to $(basename "$previous")"
  exit 0
fi

[[ -n "$PKG" ]] || die "package url or path required"

# --- python 3.13 -------------------------------------------------------------------------------
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  if [[ ${INSTALL_PYTHON:-1} == 1 ]] && command -v apt-get >/dev/null 2>&1; then
    log INFO "installing python3.13 (deadsnakes PPA)"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y -q && apt-get install -y -q software-properties-common curl
    add-apt-repository -y ppa:deadsnakes/ppa && apt-get update -y -q
    apt-get install -y -q python3.13 python3.13-venv
  else
    die "$PYTHON_BIN not found (set PYTHON_BIN or INSTALL_PYTHON=1)"
  fi
fi

# --- fetch package -----------------------------------------------------------------------------
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ZIP="$WORK/pkg.zip"
if [[ "$PKG" =~ ^https?:// ]]; then
  headers=()
  if [[ ${PACKAGE_AUTH:-sas} == msi ]]; then
    imds="http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.azure.com%2F"
    [[ -n "${AZURE_CLIENT_ID:-}" ]] && imds="${imds}&client_id=${AZURE_CLIENT_ID}"
    token=$(curl -fsS --max-time 10 -H "Metadata: true" "$imds" | "$PYTHON_BIN" -c 'import json,sys;print(json.load(sys.stdin)["access_token"])')
    headers=(-H "Authorization: Bearer ${token}" -H "x-ms-version: 2023-11-03")
  fi
  curl -fsS --retry 5 --retry-delay 3 --max-time 300 "${headers[@]}" -o "$ZIP" "$PKG" || die "download failed"
else
  cp "$PKG" "$ZIP"
fi
"$PYTHON_BIN" -m zipfile -e "$ZIP" "$WORK/pkg" || die "unzip failed"
VERSION=$(tr -d '[:space:]' < "$WORK/pkg/VERSION")
[[ "$VERSION" =~ ^[A-Za-z0-9._+-]+$ ]] || die "invalid VERSION in package"

# --- user, dirs ---------------------------------------------------------------------------------
id -u "$APP" >/dev/null 2>&1 || useradd --system --home-dir "$BASE" --no-create-home --shell /usr/sbin/nologin "$APP"
install -d -m 0755 "$BASE" "$BASE/releases"
install -d -m 0750 -o root -g "$APP" "$ETC"
install -d -m 0750 -o "$APP" -g "$APP" "$LOGDIR"

REL="$BASE/releases/${VERSION}-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$REL"
cp -r "$WORK/pkg/deploy" "$WORK/pkg/VERSION" "$REL/"
[[ -f "$WORK/pkg/README.md" ]] && cp "$WORK/pkg/README.md" "$REL/"
"$PYTHON_BIN" -m venv "$REL/venv"
"$REL/venv/bin/pip" install --quiet --no-index --find-links "$WORK/pkg/wheels" -r "$WORK/pkg/requirements.txt" || die "dependency install failed"
"$REL/venv/bin/pip" install --quiet --no-index --no-deps --find-links "$WORK/pkg/wheels" hello-common hello-worker || die "app install failed"
"$REL/venv/bin/python" -c "import hello_worker, hello_common" || die "import check failed"
chown -R root:root "$REL" && chmod -R go-w "$REL"

# --- config + unit ------------------------------------------------------------------------------
if [[ -n "$ENV_FILE" ]]; then
  install -m 0640 -o root -g "$APP" "$ENV_FILE" "$ETC/${APP}.env"
elif [[ ! -f "$ETC/${APP}.env" ]]; then
  install -m 0640 -o root -g "$APP" "$WORK/pkg/deploy/${APP}.env.example" "$ETC/${APP}.env"
  log WARNING "no env file supplied; installed example settings to $ETC/${APP}.env"
fi
if [[ $SKIP_SYSTEMD != 1 ]]; then
  install -m 0644 "$WORK/pkg/deploy/${APP}.service" "$UNIT"
fi

previous=$(readlink -f "$BASE/current" 2>/dev/null || true)
switch_to "$REL"
if ! restart_and_check; then
  log ERROR "health check failed for ${VERSION}; rolling back"
  if [[ -n "$previous" && -d "$previous" ]]; then switch_to "$previous"; restart_and_check || true; fi
  exit 1
fi

# --- prune old releases ---------------------------------------------------------------------------
ls -1dt "$BASE"/releases/* | tail -n +$((KEEP_RELEASES + 1)) | while read -r old; do
  [[ "$old" == "$(readlink -f "$BASE/current")" ]] || rm -rf "$old"
done
log INFO "installed ${APP} ${VERSION} -> $REL"
