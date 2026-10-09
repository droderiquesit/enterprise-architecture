#!/usr/bin/env bash
# Stage the eh-pr-reviewer Flex Consumption package: function_app.py + host.json + pr_reviewer/ + hello_common +
# the review engine (tools/review) and the change-detection library it reuses read-only (tools/changeset), plus
# the pinned dependencies in .python_packages (remote build is not used: the package is built once, from main).
#   applications/services/pr-reviewer/build.sh [--out DIR] [--zip FILE]
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
OUT="$HERE/.stage"
ZIP=""
PYTHON=${PYTHON:-python3.13}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --zip) ZIP="$2"; shift 2 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done
rm -rf "$OUT"; mkdir -p "$OUT/tools"
cp "$HERE/function_app.py" "$HERE/host.json" "$OUT/"
cp -r "$HERE/pr_reviewer" "$OUT/pr_reviewer"
cp -r "$REPO/applications/shared/python/hello_common/src/hello_common" "$OUT/hello_common"
for pkg in review changeset; do
  mkdir -p "$OUT/tools/$pkg"
  cp "$REPO"/tools/$pkg/*.py "$OUT/tools/$pkg/"
done
cp "$REPO/tools/review/policy.schema.json" "$OUT/tools/review/"
find "$OUT" -name __pycache__ -prune -exec rm -rf {} +
"$PYTHON" -m pip install --quiet --disable-pip-version-check --target "$OUT/.python_packages/lib/site-packages" \
  --platform manylinux2014_x86_64 --implementation cp --python-version 3.13 --only-binary=:all: -r "$HERE/requirements.txt"
if [[ -n "$ZIP" ]]; then
  (cd "$OUT" && zip -qr "$ZIP" . -x '*.pyc')
  sha256sum "$ZIP"
fi
echo "staged $OUT"
