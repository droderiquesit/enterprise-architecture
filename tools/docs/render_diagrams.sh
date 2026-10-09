#!/usr/bin/env bash
# Render docs/diagrams/src/*.mmd to docs/diagrams/svg/*.svg with a pinned mermaid-cli and record the source
# hashes in docs/diagrams/svg/manifest.json.
#
#   tools/docs/render_diagrams.sh            # render every diagram whose source changed (or --force all)
#   tools/docs/render_diagrams.sh --force    # re-render everything
#   tools/docs/render_diagrams.sh --check    # exit 1 when an SVG is missing, stale (source sha differs from the
#                                            # manifest) or edited by hand (svg sha differs); needs no browser
#
# Requirements (render mode only):
#   npm i -g @mermaid-js/mermaid-cli@${MMDC_VERSION}      (pinned below; PUPPETEER_SKIP_DOWNLOAD=1 is fine)
#   a Chromium/Chrome binary: $CHROME_BIN, else the Playwright build under /opt/pw-browsers, else google-chrome/chromium
# Check mode needs only bash, sha256sum and python3.
set -euo pipefail

MMDC_VERSION="11.12.0"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$REPO/docs/diagrams/src"
OUT="$REPO/docs/diagrams/svg"
MANIFEST="$OUT/manifest.json"
MODE="render"
FORCE=0
for a in "$@"; do
  case "$a" in
    --check) MODE="check" ;;
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done

sha() { sha256sum "$1" | cut -d' ' -f1; }

manifest_get() {  # manifest_get <name> <field>
  [[ -f "$MANIFEST" ]] || { echo ""; return; }
  python3 - "$MANIFEST" "$1" "$2" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
print(m.get("diagrams", {}).get(sys.argv[2], {}).get(sys.argv[3], ""))
PY
}

if [[ "$MODE" == "check" ]]; then
  rc=0
  for src in "$SRC"/*.mmd; do
    name="$(basename "$src" .mmd)"
    svg="$OUT/$name.svg"
    if [[ ! -f "$svg" ]]; then echo "MISSING: docs/diagrams/svg/$name.svg"; rc=1; continue; fi
    if [[ "$(sha "$src")" != "$(manifest_get "$name" source_sha256)" ]]; then
      echo "STALE: docs/diagrams/svg/$name.svg (source changed; run tools/docs/render_diagrams.sh)"; rc=1
    fi
    if [[ "$(sha "$svg")" != "$(manifest_get "$name" svg_sha256)" ]]; then
      echo "MODIFIED: docs/diagrams/svg/$name.svg differs from the rendered output recorded in the manifest"; rc=1
    fi
  done
  for svg in "$OUT"/*.svg; do
    [[ -e "$svg" ]] || continue
    name="$(basename "$svg" .svg)"
    [[ -f "$SRC/$name.mmd" ]] || { echo "ORPHAN: docs/diagrams/svg/$name.svg has no source"; rc=1; }
  done
  [[ $rc -eq 0 ]] && echo "diagrams up to date"
  exit $rc
fi

command -v mmdc >/dev/null || { echo "mmdc not found: npm i -g @mermaid-js/mermaid-cli@${MMDC_VERSION}" >&2; exit 2; }
have="$(mmdc --version 2>/dev/null | tail -1)"
[[ "$have" == "$MMDC_VERSION" ]] || { echo "mmdc $have found, $MMDC_VERSION required (deterministic output)" >&2; exit 2; }

chrome="${CHROME_BIN:-}"
if [[ -z "$chrome" ]]; then
  chrome="$(ls -d /opt/pw-browsers/chromium-*/chrome-linux/chrome 2>/dev/null | sort | tail -1 || true)"
fi
[[ -n "$chrome" ]] || chrome="$(command -v google-chrome || command -v chromium || command -v chromium-browser || true)"
[[ -x "$chrome" ]] || { echo "no Chromium found; set CHROME_BIN" >&2; exit 2; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/puppeteer.json" <<JSON
{"executablePath": "$chrome", "args": ["--no-sandbox", "--disable-gpu"]}
JSON
cat > "$tmp/mermaid.json" <<'JSON'
{"theme": "default", "flowchart": {"htmlLabels": true, "curve": "basis"}, "securityLevel": "strict"}
JSON

mkdir -p "$OUT"
declare -A NEW_SRC NEW_SVG
for src in "$SRC"/*.mmd; do
  name="$(basename "$src" .mmd)"
  svg="$OUT/$name.svg"
  ssha="$(sha "$src")"
  if [[ $FORCE -eq 0 && -f "$svg" && "$ssha" == "$(manifest_get "$name" source_sha256)" && "$(sha "$svg")" == "$(manifest_get "$name" svg_sha256)" ]]; then
    echo "unchanged: $name"
  else
    echo "rendering: $name"
    mmdc --quiet -p "$tmp/puppeteer.json" -c "$tmp/mermaid.json" -b white -i "$src" -o "$svg"
  fi
  NEW_SRC[$name]="$ssha"
  NEW_SVG[$name]="$(sha "$svg")"
done

{
  echo '{'
  echo "  \"generator\": \"tools/docs/render_diagrams.sh\","
  echo "  \"mermaid_cli\": \"$MMDC_VERSION\","
  echo '  "diagrams": {'
  first=1
  for name in $(printf '%s\n' "${!NEW_SRC[@]}" | sort); do
    [[ $first -eq 1 ]] || echo ','
    first=0
    printf '    "%s": {"source": "docs/diagrams/src/%s.mmd", "source_sha256": "%s", "svg_sha256": "%s"}' \
      "$name" "$name" "${NEW_SRC[$name]}" "${NEW_SVG[$name]}"
  done
  echo
  echo '  }'
  echo '}'
} > "$MANIFEST"
echo "manifest: docs/diagrams/svg/manifest.json"
