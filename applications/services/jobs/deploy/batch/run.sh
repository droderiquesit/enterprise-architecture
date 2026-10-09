#!/usr/bin/env bash
# Azure Batch task entrypoint for hello-jobs (application package or resource-file zip).
#   Task command line:  /bin/bash -c '"$AZ_BATCH_APP_PACKAGE_hello_jobs"/run.sh daily-aggregate'
# The package carries an offline wheelhouse; the venv is built once per node and version under
# $AZ_BATCH_NODE_SHARED_DIR (flock-protected so concurrent tasks on one node do not race).
# Requires python3.13 on the pool image (pool start task) - override with PYTHON_BIN.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
PY=${PYTHON_BIN:-python3.13}
VERSION=$(tr -d '[:space:]' < "$HERE/VERSION")
ROOT=${AZ_BATCH_NODE_SHARED_DIR:-${TMPDIR:-/tmp}}/hello-jobs
VENV="$ROOT/venv-$VERSION"
mkdir -p "$ROOT"
command -v "$PY" >/dev/null 2>&1 || { echo "{\"level\":\"ERROR\",\"message\":\"$PY not found on node\",\"service\":\"hello-jobs\"}"; exit 3; }
(
  flock -w 300 9
  if [[ ! -x "$VENV/bin/python" ]]; then
    rm -rf "$VENV.tmp"
    "$PY" -m venv "$VENV.tmp"
    "$VENV.tmp/bin/pip" install --quiet --no-index --find-links "$HERE/wheels" -r "$HERE/requirements.txt"
    "$VENV.tmp/bin/pip" install --quiet --no-index --no-deps --find-links "$HERE/wheels" hello-common hello-jobs
    mv "$VENV.tmp" "$VENV"
  fi
) 9>"$ROOT/.lock"
export OUTPUT_PATH=${OUTPUT_PATH:-${AZ_BATCH_TASK_WORKING_DIR:-$PWD}}
exec "$VENV/bin/python" -m hello_jobs "${1:-daily-aggregate}"
