#!/usr/bin/env bash
# Vendor a VERSIONED release of the observability package into ./.vendor/observability-<version>/ (git-ignored).
# Reads package.lock.json {version, sha256, url}; url may be https:// or file:// (local tarball).
# The sha256 is verified BEFORE extraction; a mismatch aborts without touching an existing vendored copy.
#
#   ./vendor.sh                   vendor the locked version, verify that *.tf module sources use it
#   ./vendor.sh --update-sources  also rewrite ./.vendor/observability-<old>/ module sources to the locked version
#   PACKAGE_LOCK=other.json ./vendor.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
LOCK="${PACKAGE_LOCK:-package.lock.json}"
UPDATE_SOURCES=false
[[ "${1:-}" == "--update-sources" ]] && UPDATE_SOURCES=true

read_lock() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$LOCK" "$1"; }
VERSION="$(read_lock version)"; SHA="$(read_lock sha256)"; URL="$(read_lock url)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || { echo "bad version '$VERSION' in $LOCK" >&2; exit 2; }
[[ "$SHA" =~ ^[0-9a-f]{64}$ ]] || { echo "sha256 in $LOCK is not set (64 hex chars expected)" >&2; exit 2; }

DEST=".vendor/observability-${VERSION}"
STAMP="${DEST}/.sha256"
if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$SHA" ]]; then
  echo "already vendored: ${DEST}"
else
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  case "$URL" in
    file://*) cp "${URL#file://}" "$TMP/pkg.tar.gz" ;;
    https://*) curl -fsSL --proto '=https' --tlsv1.2 -o "$TMP/pkg.tar.gz" "$URL" ;;
    *) echo "unsupported url scheme: $URL" >&2; exit 2 ;;
  esac
  echo "${SHA}  ${TMP}/pkg.tar.gz" | sha256sum -c --quiet - || { echo "sha256 mismatch for $URL" >&2; exit 1; }
  mkdir -p "$TMP/x"
  tar -xzf "$TMP/pkg.tar.gz" -C "$TMP/x" --no-same-owner
  [[ -d "$TMP/x/observability-${VERSION}" ]] || { echo "archive does not contain observability-${VERSION}/" >&2; exit 1; }
  [[ "$(tr -d '[:space:]' < "$TMP/x/observability-${VERSION}/VERSION")" == "$VERSION" ]] || { echo "VERSION file mismatch" >&2; exit 1; }
  mkdir -p .vendor
  rm -rf "$DEST"
  mv "$TMP/x/observability-${VERSION}" "$DEST"
  echo "$SHA" > "$STAMP"
  echo "vendored observability ${VERSION} -> ${DEST}"
fi

if $UPDATE_SOURCES; then
  for f in *.tf; do
    sed -i -E "s#\./\.vendor/observability-[0-9A-Za-z.+-]+/#./.vendor/observability-${VERSION}/#g" "$f"
  done
  echo "module sources now point to ${DEST}"
fi
stale="$(grep -hoE '\./\.vendor/observability-[0-9A-Za-z.+-]+/' ./*.tf | sort -u | grep -v "observability-${VERSION}/" || true)"
if [[ -n "$stale" ]]; then
  echo "module sources reference another version: ${stale} (run ./vendor.sh --update-sources)" >&2
  exit 1
fi
