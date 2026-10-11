# Graphify: codebase knowledge graph

[Graphify](https://pypi.org/project/graphifyy/) (PyPI package `graphifyy`, CLI `graphify`) turns this repository into
a queryable knowledge graph: one node per symbol / Terraform block / registry component, edges for calls, imports,
references, module sources, contract consumption, and so on. AI coding assistants (Claude Code, Copilot, Codex, ...)
and people use it to answer "what depends on X", "what does a change to Y affect", "how is A connected to B"
without reading hundreds of files. Everything described here runs locally, needs **no API key**, and sends nothing
anywhere.

| Piece | Where |
|---|---|
| pinned version | [`tools/graphify/VERSION`](../../tools/graphify/VERSION) (`0.9.84`) |
| one-command build | [`tools/graphify/build.sh`](../../tools/graphify/build.sh) |
| IaC layer (registry, contracts, artifacts, modules, resources, pipelines, charts, profiles) | [`tools/graphify/iac_graph.py`](../../tools/graphify/iac_graph.py) |
| paths excluded from extraction | [`.graphifyignore`](../../.graphifyignore) (in addition to `.gitignore`) |
| tests (CI suite `py-graphify`) | [`tools/graphify/tests/`](../../tools/graphify/tests/test_iac_graph.py), [`tools/ci/suites.yaml`](../../tools/ci/suites.yaml) |
| output (not committed) | `graphify-out/` (`graph.json`, `graph.html`, `GRAPH_REPORT.md`, `iac-graph.json`, `cache/`) |

## Install

```bash
uv tool install 'graphifyy[terraform,sql]==0.9.84'      # or: pipelines/scripts/install-tools.sh graphify
graphify --version                                      # graphify 0.9.84
```

The `terraform` extra (tree-sitter-hcl) is **required**: without it graphify silently skips every `.tf` file
(`tree_sitter_hcl not installed`), which is most of this repository. `sql` adds the 17 `.sql` files. `build.sh` checks
the version and the Terraform grammar and fails with the install command if either is wrong. To upgrade, change
`tools/graphify/VERSION`, reinstall, run `build.sh --full` and the `py-graphify` tests.

## Build

```bash
tools/graphify/build.sh            # incremental (~30 s): graphify update + IaC layer + clustering + report + HTML
tools/graphify/build.sh --full     # from scratch (~25-40 s on 4 cores): graphify extract . --code-only --force ...
tools/graphify/build.sh --no-viz   # skip graph.html (CI)
tools/graphify/build.sh --label    # name communities with an LLM (only when an API key env var is set, see below)
tools/graphify/build.sh --force    # accept a rebuild with fewer nodes (after deleting code)
```

Steps: (1) code AST: `graphify update .` when `graphify-out/graph.json` exists, otherwise
`graphify extract . --code-only`; (2) `iac_graph.py --merge-into graphify-out/graph.json`, which replaces the IaC
layer in place (idempotent); (3) `graphify cluster-only . --no-label` (communities, `GRAPH_REPORT.md`, `graph.html`).
At the end the script prints the paths of `graph.html` and `GRAPH_REPORT.md`.

The adapter merges in place rather than with `graphify merge-graphs` (a cross-repo merge that re-prefixes ids and
would break incremental updates). Its nodes carry `_origin: "iac"`, which `graphify update` preserves, so a code-only
update never drops the IaC layer; it is refreshed by the next `build.sh`.

## Use

```bash
graphify query "which components consume the obs-telemetry-transport contract"     # BFS from best-matching nodes
graphify affected "obs-telemetry-transport contract" --relation consumes_contract --relation consumes
graphify affected "foundation/modules/naming terraform module" --relation uses_module   # who uses a shared module
graphify path "deploy-core-aks component (terraform root)" "foundation/modules/naming terraform module"
graphify explain "azurerm_key_vault resource type"                                  # node + neighbours
graphify god-nodes --top 15                                                         # architectural hubs
xdg-open graphify-out/graph.html                                                    # or open it in a browser
```

- `affected` follows only code relations by default (`calls`, `imports`, ...): pass the IaC relations with
  `--relation` (table below) for infrastructure impact.
- Node labels say what a node is (`<id> component (terraform root)`, `<name> contract`, `<type> resource type`,
  `<dir> terraform module`, `<file> pipeline`, `<name> helm chart`, `<name> deployment profile`), which keeps
  `query`, `path` and `explain` precise. graphify's own Terraform nodes are labelled `Terraform module: <dir>`,
  `module.<name>`, `var.<name>`, `azurerm_x.y`, and so on.
- `graph.html` shows an aggregated community view (the graph has more than 5000 nodes). `GRAPH_REPORT.md` lists hubs,
  communities and surprising connections.
- The graph is a navigation aid, not a source of truth. The registry, `tools/changeset` and Terraform itself stay
  authoritative.

## What is covered

| Layer | Source | Nodes / relations |
|---|---|---|
| code AST (graphify) | Python, C#, Go, TypeScript, shell, Lua, JSON, `.csproj`/`.sln`, SQL | functions, classes, modules; `calls`, `imports`, `references`, `contains`, `inherits`, ... |
| Terraform AST (graphify, `terraform` extra) | every `.tf` / `.tftest.hcl` | `Terraform module: <dir>`, resources, data, `module.x`, `var.x`, `local.x`, outputs; `contains`, `references`, `module_source`, `depends_on` |
| IaC layer (`iac_graph.py`) | `catalog/components.yaml` | component per registry entry; `consumes` (component to producer, `context: optional` for `optional_consumes`), `depends_on` |
| | `catalog/contracts/*.schema.json` + `produces` | contract (versions); `produces_contract`, `consumes_contract`, `has_schema` (to the schema file's AST node) |
| | `artifact:` / `artifacts:` | artifact (image / package / bundle); `builds`, `consumes_artifact` |
| | `.tf` files per directory | non-component dirs as `<dir> terraform module`, registry modules; `uses_module` (same resolution as `tools/changeset`), `declares_resource` (resource / data source **type** node, weight = block count), `requires_provider`; variable/output counts as node attributes; `implemented_by` to graphify's `Terraform module: <dir>` |
| | `pipelines/**/*.yml`, `azure-pipelines*.yml` | pipeline file; `uses_template` |
| | `applications/charts/*/Chart.yaml` | Helm chart; `deploys_chart` from the roots that reference it |
| | `environments/profiles/*.yaml`, `environments/*/environment.yaml` | profile, environment; `enables`, `uses_profile` |
| | `catalog/services/*.yaml` (referenced entries) | Azure service; `implements_service` (`catalog_refs`) |

Ids are `iac_<kind>_<slug>`, deterministic and disjoint from graphify's ids. The adapter never emits a node whose
source file is excluded by `.graphifyignore` (graphify would evict it on the next update), so `pipelines/generated/`
and vendored `.vendor/` module copies are not in the IaC layer.

**Not covered** without an LLM backend:

- **YAML / Markdown semantics.** Graphify's AST pass does not read YAML, and it reads Markdown only as headings and
  links. The meaning of `environments/**`, `observability/config/**`, ADRs, runbooks and guides is only extracted by
  the semantic (LLM) pass. The IaC adapter covers the architectural YAML deterministically.
- **Community names.** They stay `Community N` (`--no-label`).
- **Terraform expressions.** Resolution of `for_each` and dynamic values is not modelled.

### Optional: semantic extraction and community labels (LLM)

```bash
export ANTHROPIC_API_KEY=...            # never commit keys; never put them in .env files in the repo
graphify extract . --backend claude     # AST + semantic pass over docs/YAML (costs tokens: ~780k words corpus)
python3 tools/graphify/iac_graph.py --out graphify-out/iac-graph.json --merge-into graphify-out/graph.json
graphify cluster-only .                 # or: tools/graphify/build.sh --label
```

This is opt-in and costs tokens. Also, `.graphifyignore` excludes evidence, rendered and generated content, but the
remaining corpus is still large. In CI an API key would come from Delinea DSV like every other secret in this
repository (`tools/secrets/fetch.py`, `secret_env`), never from pipeline variables or files. No pipeline does this
today.

## What is committed

Nothing generated: `graphify-out/` is git-ignored (`graph.json` is 15-20 MB and changes on almost every commit; `cache/`
is per-machine). Committed is what makes the build reproducible: the pin, `.graphifyignore`, `build.sh`, the adapter
and its tests.

## CI

Suite `py-graphify` ([`tools/ci/suites.yaml`](../../tools/ci/suites.yaml); about 5 s, no graphify CLI needed) pins every
node/relation kind on a synthetic tree, the graph.json schema, determinism, merge idempotency and `.graphifyignore`
handling, plus a smoke run over the real catalog. No pipeline publishes the graph; a job that does would need no
secrets and belongs on a hosted agent, never in a job holding deployment credentials.

## AI assistant integration (opt-in, run these yourself)

These commands change assistant configuration, git hooks or user-level files. Nothing in this repository runs them.
Each developer decides, and anything that writes into the repository needs a normal PR and review.

| Command | What it changes |
|---|---|
| `graphify install --platform claude` | copies the graphify skill to `~/.claude/skills/graphify/SKILL.md` and adds a short block to `~/.claude/CLAUDE.md` (user scope, all projects). `--project` writes `.claude/skills/...` + `.claude/CLAUDE.md` in the repo instead. |
| `graphify claude install` | adds a graphify section to the repo's `CLAUDE.md` and **PreToolUse hooks** to `.claude/settings.json`. Before Grep/Glob/Read, Claude Code is nudged (or, with `--strict`, required) to run `graphify query` first. Undo: `graphify claude uninstall`. |
| `graphify hook install` | `.git/hooks/post-commit` + `post-checkout` that run a code-only `graphify update` in the background after each commit/checkout, plus a `graph.json` merge driver in git config + `.gitattributes`. The IaC layer is kept but only refreshed by `build.sh`. Undo: `graphify hook uninstall`; check: `graphify hook status`. |
| `graphify vscode install` | VS Code Copilot Chat: skill at `~/.copilot/skills/graphify/SKILL.md` + a section in `.github/copilot-instructions.md`. This repository keeps Copilot guidance in `.azuredevops/instructions/`, so review where it should go. Undo: `graphify vscode uninstall`. |
| `graphify copilot install` | GitHub Copilot CLI: skill at `~/.copilot/skills/graphify/SKILL.md` only. |
| `graphify uninstall` | removes graphify from every detected platform (`--purge` also deletes `graphify-out/`). |

Recommended minimal setup for Claude Code: build the graph, then run `graphify install --platform claude` (user
scope, nothing in the repo changes). Use `graphify claude install` only if the team agrees to commit the CLAUDE.md
section and hooks. In either case, run `tools/graphify/build.sh` after pulling, so the graph matches the checkout.
