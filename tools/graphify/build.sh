#!/usr/bin/env bash
# (Re)build the Graphify knowledge graph of this repository: code AST (incremental) + the IaC layer
# (tools/graphify/iac_graph.py) merged in place + clustering/report/HTML. No LLM or API key needed.
# Guide: docs/guides/graphify.md
#
#   tools/graphify/build.sh              # incremental: `graphify update` when graphify-out/graph.json exists
#   tools/graphify/build.sh --full       # full code re-extraction (graphify extract --code-only --force)
#   tools/graphify/build.sh --no-viz     # skip graph.html (CI)
#   tools/graphify/build.sh --label      # also name communities with an LLM backend (needs an API key env var,
#                                        # e.g. ANTHROPIC_API_KEY; without --label communities stay "Community N")
#   tools/graphify/build.sh --force      # accept a rebuild with fewer nodes (after deleting code)
#
# Requires the pinned CLI with the Terraform + SQL grammars (tools/graphify/VERSION):
#   uv tool install 'graphifyy[terraform,sql]==0.9.84'      (or: pipelines/scripts/install-tools.sh graphify)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
PIN="$(tr -d '[:space:]' < tools/graphify/VERSION)"
OUT=graphify-out
GRAPH="$OUT/graph.json"
INSTALL_HINT="uv tool install 'graphifyy[terraform,sql]==${PIN}' --force   (or: pipelines/scripts/install-tools.sh graphify)"

full=0 viz=1 label=0 force=()
for arg in "$@"; do
  case "$arg" in
    --full) full=1 ;;
    --no-viz) viz=0 ;;
    --label) label=1 ;;
    --force) force=(--force) ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "build.sh: unknown option $arg" >&2; exit 2 ;;
  esac
done

die() { echo "graphify build: $*" >&2; exit 1; }

# ---- pinned CLI + grammars
command -v graphify >/dev/null 2>&1 || die "graphify CLI not found on PATH. Install the pinned version:
    $INSTALL_HINT"
have="$(graphify --version 2>/dev/null | awk '{print $2}' | head -1)"
[[ "$have" == "$PIN" ]] || die "graphify $have found, this repository pins $PIN (tools/graphify/VERSION). Install it:
    $INSTALL_HINT"
gpy="$(head -1 "$(command -v graphify)" | sed -n 's/^#!//p' | awk '{print $1}')"
if [[ -n "$gpy" && -x "$gpy" ]]; then
  "$gpy" -c 'import tree_sitter_hcl' 2>/dev/null || die "graphify $PIN is installed without the Terraform grammar
    (tree-sitter-hcl): every .tf file would be silently skipped. Reinstall with the extras:
    $INSTALL_HINT"
fi
python3 -c 'import yaml' 2>/dev/null || die "python3 with PyYAML is required for the IaC layer (pip install pyyaml)"

# ---- 1. code AST (local, no API key)
if [[ $full -eq 0 && -s "$GRAPH" ]]; then
  echo "==> graphify update . (incremental code AST)"
  graphify update . --no-cluster "${force[@]}"
else
  echo "==> graphify extract . --code-only (full code AST)"
  graphify extract . --code-only --no-cluster --force
fi
[[ -s "$GRAPH" ]] || die "$GRAPH was not produced"

# ---- 2. IaC layer (components, contracts, artifacts, modules, resources, pipelines, charts, profiles)
echo "==> tools/graphify/iac_graph.py (IaC layer, merged into $GRAPH)"
python3 tools/graphify/iac_graph.py --out "$OUT/iac-graph.json" --merge-into "$GRAPH"

# ---- 3. clustering + GRAPH_REPORT.md + graph.html
cluster=(graphify cluster-only .)
[[ $viz -eq 1 ]] || cluster+=(--no-viz)
if [[ $label -eq 1 ]]; then
  if [[ -n "${ANTHROPIC_API_KEY:-}${OPENAI_API_KEY:-}${GEMINI_API_KEY:-}${GOOGLE_API_KEY:-}${MOONSHOT_API_KEY:-}${DEEPSEEK_API_KEY:-}${OLLAMA_HOST:-}" ]]; then
    echo "==> graphify cluster-only . (LLM community labels)"
  else
    echo "    --label: no LLM backend env var set (ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY, ...);" \
         "keeping placeholder community names" >&2
    cluster+=(--no-label)
  fi
else
  cluster+=(--no-label)
  echo "==> graphify cluster-only . --no-label"
fi
"${cluster[@]}"

python3 - "$GRAPH" <<'EOF'
import json, sys
g = json.load(open(sys.argv[1], encoding="utf-8"))
links = g.get("links", g.get("edges", []))
iac = sum(1 for n in g["nodes"] if str(n.get("id", "")).startswith("iac_"))
comms = {n.get("community") for n in g["nodes"] if n.get("community") is not None}
print(f"graph: {len(g['nodes'])} nodes ({iac} IaC), {len(links)} edges, {len(comms)} communities")
EOF
echo "report:  $REPO_ROOT/$OUT/GRAPH_REPORT.md"
[[ $viz -eq 1 ]] && echo "browser: $REPO_ROOT/$OUT/graph.html"
echo "query:   graphify query \"which components consume the obs-telemetry-transport contract\""
