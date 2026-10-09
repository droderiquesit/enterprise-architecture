"""Command line interface: python3 -m tools.changeset <command> ...

Commands
  graph        validate the registry and dependency graph; print layers (--json) or a cycle path
  owners       which components own the given paths
  fingerprint  deploy/validation fingerprints (and parts) of components
  select       produce the selection document (+ ADO output variables with --ado)
  explain      preview for the local working tree: what would be validated/built/planned/applied, and why
  apply-set    given a selection and plan exit codes, list components that will apply
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from .ado import logging_commands
from .graph import CycleError, Graph
from .registry import RegistryError, load_registry
from .select import (
    MODES,
    SelectionError,
    auto_mode,
    select_all,
    select_deploy,
    select_manual,
    select_pr,
    select_promote,
    select_retire,
)
from .store import open_store
from .trees import WorkTree


def _split(v: str | None) -> list[str]:
    return [x.strip() for x in (v or "").replace(" ", ",").split(",") if x.strip()]


def cmd_graph(args) -> int:
    tree = WorkTree(Path(args.repo))
    try:
        reg = load_registry(tree)
        from .registry import scope_errors

        problems = scope_errors(reg)
        if problems:
            print("ERROR: " + "\n  ".join(problems), file=sys.stderr)
            return 2
        g = Graph(reg)
        cyc = g.find_cycle()
        if cyc:
            print("ERROR: dependency cycle: " + " -> ".join(cyc), file=sys.stderr)
            return 2
        layers = g.layers()
    except (RegistryError, CycleError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps({
            "layers": layers,
            "edges": {k: dict(sorted(v.items())) for k, v in sorted(g.edges.items())},
            "consumers": {c.id: sorted(g.consumers(c.id)) for c in reg},
        }, indent=2))
    else:
        print(f"registry ok: {len(reg.components)} components, acyclic, {len(layers)} layers")
        for i, layer in enumerate(layers):
            print(f"  layer {i}: {', '.join(layer)}")
    return 0


def cmd_owners(args) -> int:
    from .fingerprint import Fingerprinter

    tree = WorkTree(Path(args.repo))
    reg = load_registry(tree)
    fp = Fingerprinter(tree, reg, Graph(reg), args.env, None, None, None)
    for p in args.paths:
        owners = [c.id for c in reg if fp.owns(c, p)]
        print(f"{p}: {', '.join(owners) or '-'}")
    return 0


def cmd_fingerprint(args) -> int:
    from .select import Context

    ctx = Context(Path(args.repo), args.env, worktree=args.worktree)
    ids = _split(args.component) or sorted(c.id for c in ctx.registry if not c.is_docs and c.pipeline != "manual")
    out = {cid: {"deploy_fp": ctx.fp.deploy_fp(cid), "validation_fp": ctx.fp.validation_fp(cid),
                 "parts": ctx.fp.parts(cid), "modules": ctx.fp.modules(cid)} for cid in ids}
    print(json.dumps(out, indent=2))
    return 0


def _load_digests(path: str | None):
    if not path:
        return None
    p = Path(path)
    if p.is_dir():
        digests = {}
        for f in p.rglob("build-metadata.json"):
            meta = json.loads(f.read_text())
            digests[meta["component"]] = meta.get("digest") or meta.get("package_sha256")
        return digests
    return json.loads(p.read_text())


def run_select(args, mode: str, repo: Path) -> dict:
    store = open_store(args.records_url or args.records_dir)
    contracts = open_store(getattr(args, "contracts_url", None) or getattr(args, "contracts_dir", None))
    scope = getattr(args, "scope", None) or None
    if scope == "all":
        scope = None
    common = dict(head=args.head, worktree=args.worktree, scope=scope)
    if mode == "pr":
        return select_pr(repo, args.env, target=args.target, base=args.base, **common)
    if mode == "deploy":
        return select_deploy(repo, args.env, store, artifact_digests=_load_digests(args.artifact_digests),
                             contracts_store=contracts, **common)
    if mode == "promote":
        return select_promote(repo, args.env, store, args.source_env or "auto",
                              open_store(args.source_records_url or args.source_records_dir),
                              contracts_store=contracts, **common)
    if mode == "manual":
        return select_manual(repo, args.env, _split(args.components), with_consumers=args.with_consumers,
                             store=store, **common)
    if mode in ("reconcile", "drift"):
        return select_all(repo, args.env, mode, store=store, **common)
    if mode == "retire":
        return select_retire(repo, args.env, store, **common)
    raise SelectionError(f"unknown mode {mode}")


def cmd_select(args) -> int:
    mode = args.mode
    if mode == "auto":
        mode = auto_mode(args.build_reason or os.environ.get("BUILD_REASON"))
    repo = Path(args.repo)
    try:
        doc = run_select(args, mode, repo)
    except Exception as exc:  # noqa: BLE001 - CLI boundary: explicit message, non-zero exit
        print(f"ERROR: selection failed: {exc}", file=sys.stderr)
        if args.ado:
            print(f"##vso[task.logissue type=error]selection failed: {str(exc).splitlines()[0]}")
        return 1
    text = json.dumps(doc, indent=2, sort_keys=True)
    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(text + "\n")
    if args.ado:
        reg = load_registry(WorkTree(repo)) if args.worktree or not (repo / ".git").exists() else None
        if reg is None:
            from .trees import GitTree

            reg = load_registry(GitTree(repo, args.head))
        for line in logging_commands(doc, reg):
            print(line)
    if not args.out and not args.ado:
        print(text)
    s = doc["summary"]
    print(f"mode={doc['mode']} env={doc['environment']} validate={len(s['validate'])} plan={len(s['plan'])} "
          f"apply_candidates={len(s['apply_candidates'])} build={len(s['build'])} "
          f"retire_scheduled={len(s['retire_scheduled'])}", file=sys.stderr)
    for cid in s["plan"]:
        e = doc["components"][cid]
        print(f"  plan {cid} (wave {e['wave']}): {'; '.join(e['reason'])}", file=sys.stderr)
    return 0


def cmd_explain(args) -> int:
    """Preview a run for the local working tree (uncommitted changes included)."""
    repo = Path(args.repo)
    args.worktree, args.head = True, "HEAD"
    args.components, args.with_consumers, args.artifact_digests = "", False, None
    args.records_url = getattr(args, "records_url", None)
    mode = "deploy" if (args.records_dir or args.records_url) else "pr"
    if mode == "pr":
        args.target = args.target or "main"
    try:
        doc = run_select(args, mode, repo)
    except Exception as exc:  # noqa: BLE001
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(doc, indent=2, sort_keys=True))
        return 0
    rows = []
    for cid, e in sorted(doc["components"].items(), key=lambda kv: (kv[1]["scope"], kv[1]["layer"], kv[0])):
        if not (e["validate"] or e["plan"] or e["build"] or e["resolve"] or e.get("waiting_for") or e.get("out_of_scope") and e["reason"]):
            continue
        flags = {
            "validate": "yes" if e["validate"] else "",
            "build": "build" if e["build"] else ("resolve" if e["resolve"] else ""),
            "plan": "yes" if e["plan"] else ("WAIT" if e.get("waiting_for") else ""),
            "apply": "if-changes" if e["apply_candidate"] else "",
        }
        rows.append((cid, e["scope"], flags, "; ".join(e["reason"])[:160]))
    base = doc.get("base") or "deployment records"
    print(f"explain: mode={doc['mode']} env={doc['environment']} scope={doc.get('scope') or 'all'} base={base}")
    if not rows:
        print("nothing would be validated, built or deployed")
    else:
        w = max(len(r[0]) for r in rows)
        print(f"{'component'.ljust(w)}  {'scope':12}  validate  build    plan  apply       why")
        for cid, scope, f, why in rows:
            print(f"{cid.ljust(w)}  {scope:12}  {f['validate']:8}  {f['build']:7}  {f['plan']:4}  {f['apply']:10}  {why}")
    pipelines = sorted({e["scope"] for e in doc["components"].values() if e["plan"] or e["build"] or e["validate"]})
    if pipelines:
        names = {"platform": "azure-pipelines.yml", "applications": "azure-pipelines.applications.yml"}
        print("pipelines that would run work: " + ", ".join(f"{p} ({names[p]})" for p in pipelines))
    for m in doc.get("modules_to_validate", []):
        print(f"module validation: {m}")
    for r in doc.get("retirements", []):
        print(f"retirement: {r['component']} {r['status']} - {r['reason']}")
    return 0


def cmd_apply_set(args) -> int:
    from .planresults import apply_set

    doc = json.loads(Path(args.selection).read_text())
    results = json.loads(Path(args.plan_results).read_text())
    print(json.dumps(apply_set(doc, results), indent=2))
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="python3 -m tools.changeset", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=".")
    sub = ap.add_subparsers(dest="cmd", required=True)

    g = sub.add_parser("graph")
    g.add_argument("--json", action="store_true")
    g.add_argument("--check", action="store_true", help="validate only (default behaviour)")
    g.set_defaults(func=cmd_graph)

    o = sub.add_parser("owners")
    o.add_argument("paths", nargs="+")
    o.add_argument("--env", default="dev")
    o.set_defaults(func=cmd_owners)

    f = sub.add_parser("fingerprint")
    f.add_argument("--env", default="dev")
    f.add_argument("--component")
    f.add_argument("--worktree", action="store_true", help="hash the working tree instead of HEAD")
    f.set_defaults(func=cmd_fingerprint)

    s = sub.add_parser("select")
    s.add_argument("--mode", default="auto", choices=("auto",) + MODES)
    s.add_argument("--env", default="dev")
    s.add_argument("--target", default="main", help="PR target branch (System.PullRequest.TargetBranch)")
    s.add_argument("--base", help="explicit base revision (overrides merge-base)")
    s.add_argument("--head", default="HEAD")
    s.add_argument("--components", help="comma list for manual mode")
    s.add_argument("--with-consumers", action="store_true")
    s.add_argument("--records-dir", help="local deployment record directory (<dir>/<env>/<id>.json)")
    s.add_argument("--records-url", help="https://<acct>.blob.core.windows.net/deployments")
    s.add_argument("--artifact-digests", help="JSON {artifact-id: digest} or directory of build-metadata.json")
    s.add_argument("--build-reason", help="Build.Reason (auto mode); defaults to $BUILD_REASON")
    s.add_argument("--worktree", action="store_true")
    s.add_argument("--scope", choices=("all", "platform", "applications"), default="all",
                   help="restrict to one pipeline (azure-pipelines.yml = platform, azure-pipelines.applications.yml = applications)")
    s.add_argument("--contracts-url", help="contracts store (blob URL); enables upstream-contract change detection")
    s.add_argument("--contracts-dir", help="local contracts store directory")
    s.add_argument("--source-env", help="promote mode: source environment ('auto' = promotion.yaml promote_from)")
    s.add_argument("--source-records-url", help="promote mode: deployment records of the source environment")
    s.add_argument("--source-records-dir")
    s.add_argument("--out")
    s.add_argument("--ado", action="store_true", help="print ##vso output variables")
    s.set_defaults(func=cmd_select)

    x = sub.add_parser("explain", help="preview what a run would validate/build/plan/apply for the working tree, and why")
    x.add_argument("--env", default="dev")
    x.add_argument("--base", help="compare with this revision (default: merge-base with origin/<target>)")
    x.add_argument("--target", default="main")
    x.add_argument("--scope", choices=("all", "platform", "applications"), default="all")
    x.add_argument("--records-dir", help="deployment records: preview a deploy-mode run instead of a PR run")
    x.add_argument("--records-url")
    x.add_argument("--contracts-dir")
    x.add_argument("--contracts-url")
    x.add_argument("--json", action="store_true")
    x.set_defaults(func=cmd_explain)

    a = sub.add_parser("apply-set")
    a.add_argument("--selection", required=True)
    a.add_argument("--plan-results", required=True, help="JSON {component: terraform plan exit code}")
    a.set_defaults(func=cmd_apply_set)

    args = ap.parse_args(argv)
    return args.func(args)
