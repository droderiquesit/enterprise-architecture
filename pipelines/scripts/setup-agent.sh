#!/usr/bin/env bash
# Install the pinned Python tool requirements and (optionally) pinned CLIs on a pipeline agent.
# Usage: setup-agent.sh [tool ...]     e.g. setup-agent.sh terraform
#
# Python: a job virtualenv ($CI_VENV, default $AGENT_TEMPDIRECTORY/ci-venv) populated by uv (open source, Rust;
# installs in seconds) with `uv pip sync --require-hashes` from the hash-pinned, uv-compiled requirement files
# (pipelines/requirements-tools.txt + requirements-ci-tools.txt: pyyaml, jsonschema, pytest, pytest-xdist, ruff,
# yamllint, uv). uv itself is bootstrapped with `pip install --require-hashes` (pipelines/requirements-uv.txt).
# UV_CACHE_DIR is restored/saved by Cache@2 (steps-setup.yml, keyed by the requirement files). The venv's bin dir
# is prepended to PATH, so every later `python3` of the job is the venv's. Without python3-venv (some self-hosted
# images) it falls back to `pip install --user --require-hashes` of the same files.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
REQ=(pipelines/requirements-tools.txt pipelines/requirements-ci-tools.txt)
VENV="${CI_VENV:-${AGENT_TEMPDIRECTORY:-${TMPDIR:-/tmp}}/ci-venv}"
export UV_CACHE_DIR="${UV_CACHE_DIR:-${PIPELINE_WORKSPACE:-$HOME}/.cache/uv}" UV_LINK_MODE=copy
if [[ -x "$VENV/bin/python" ]] || python3 -m venv "$VENV" 2>/dev/null; then
  if [[ ! -x "$VENV/bin/uv" ]]; then
    "$VENV/bin/python" -m pip install --quiet --disable-pip-version-check --require-hashes --no-deps \
      -r pipelines/requirements-uv.txt
  fi
  "$VENV/bin/uv" pip sync --quiet --python "$VENV/bin/python" --require-hashes "${REQ[@]}"
  export PATH="$VENV/bin:$PATH"
  [[ -n "${TF_BUILD:-}" ]] && echo "##vso[task.prependpath]$VENV/bin"
  echo "python tools: $(python3 --version) in $VENV (uv $(uv --version | cut -d' ' -f2))"
else
  echo "##vso[task.logissue type=warning]python3 -m venv unavailable: installing tool requirements with pip --user"
  for r in "${REQ[@]}"; do python3 -m pip install --quiet --user --require-hashes -r "$r"; done
fi
if [[ $# -gt 0 ]]; then bash pipelines/scripts/install-tools.sh "$@"; fi
