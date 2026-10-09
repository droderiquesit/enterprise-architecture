#!/usr/bin/env bash
# Build a versioned, portable release of the observability package:
#   <out>/observability-<version>.tar.gz  (+ .sha256)
# Contents: modules/ config/ schemas/ archetypes/ tools/ pipelines/ examples/ README.md CHANGELOG.md UPGRADING.md VERSION
# Never included: lab roots, lab onboarding manifests/rendered output, .terraform/, caches, vendored copies.
# The build FAILS if any packaged file references paths outside the package, lab roots, remote state,
# or a real subscription id. Allowed placeholders: the all-zero GUID and test GUIDs of the form
# xxxxxxxx-0000-0000-0000-000000000000 (third group 0000 = no RFC 4122 version, so never a real subscription id).
#
# Usage: package.sh [--out DIR] [--version X.Y.Z[-pre]]   (default version: ./VERSION)
# Exit codes: 0 ok, 1 portability violation, 2 usage error.
set -euo pipefail

PKG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${PKG_ROOT}/tools/release/dist"
VERSION_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --version) VERSION_OVERRIDE="$2"; shift 2 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

VERSION="${VERSION_OVERRIDE:-$(tr -d '[:space:]' < "${PKG_ROOT}/VERSION")}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "invalid version '$VERSION' (semver expected)" >&2; exit 2
fi

NAME="observability-${VERSION}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "${STAGE}/${NAME}" "$OUT"

INCLUDE=(modules config schemas archetypes tools pipelines examples images README.md CHANGELOG.md UPGRADING.md VERSION)
for item in "${INCLUDE[@]}"; do
  [[ -e "${PKG_ROOT}/${item}" ]] || { echo "note: ${item} not present, skipped" >&2; continue; }
  tar -C "$PKG_ROOT" \
      --exclude='.terraform' --exclude='__pycache__' --exclude='*.pyc' --exclude='.pytest_cache' --exclude='.ruff_cache' \
      --exclude='.vendor' --exclude='terraform.tfstate*' --exclude='*.tfplan' --exclude='dist' \
      --exclude='.terraform.tfstate.lock.info' --exclude='*.auto.tfvars.json' \
      -cf - "$item" | tar -C "${STAGE}/${NAME}" -xf -
done
printf '%s\n' "$VERSION" > "${STAGE}/${NAME}/VERSION"

# ---------------------------------------------------------------- portability gate
violations=0
check() { # pattern description
  local hits
  hits="$(grep -rInE "$1" "${STAGE}/${NAME}" 2>/dev/null | sed "s|${STAGE}/||" || true)"
  if [[ -n "$hits" ]]; then
    echo "PORTABILITY VIOLATION ($2):" >&2
    echo "$hits" | head -20 >&2
    violations=$((violations + 1))
  fi
}
check '\.\./\.\./foundation' 'path escape to lab foundation modules'
# Patterns are split so this script does not match itself.
check '(^|[^A-Za-z0-9_])la''b/' 'reference to lab roots'
check 'terraform_remote''_state' 'remote state coupling'
check '\.\./\.\./\.\.' 'path escape above the package root'
GUID='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
sub_hits="$(grep -rIhoE "(subscriptions/|subscription_id[\"']?[[:space:]]*[:=][[:space:]]*[\"']?)${GUID}" "${STAGE}/${NAME}" \
            | grep -oE "$GUID" | grep -vE '^[0-9a-fA-F]{8}-0000-0000-0000-000000000000$' | sort -u || true)"
if [[ -n "$sub_hits" ]]; then
  echo "PORTABILITY VIOLATION (subscription id other than the all-zero placeholder): $sub_hits" >&2
  violations=$((violations + 1))
fi
if [[ $violations -gt 0 ]]; then
  echo "package NOT built: ${violations} violation class(es)" >&2
  exit 1
fi

# ---------------------------------------------------------------- deterministic archive
TARBALL="${OUT}/${NAME}.tar.gz"
tar -C "$STAGE" --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner --format=gnu -cf - "$NAME" | gzip -n -9 > "$TARBALL"
( cd "$OUT" && sha256sum "${NAME}.tar.gz" > "${NAME}.tar.gz.sha256" )
echo "built ${TARBALL}"
cat "${TARBALL}.sha256"
