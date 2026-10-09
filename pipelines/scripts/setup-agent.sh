#!/usr/bin/env bash
# Install the pinned Python tool requirements and (optionally) pinned CLIs on a pipeline agent.
# Usage: setup-agent.sh [tool ...]     e.g. setup-agent.sh terraform
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
python3 -m pip install --quiet --user --requirement pipelines/requirements-tools.txt
if [[ $# -gt 0 ]]; then bash pipelines/scripts/install-tools.sh "$@"; fi
