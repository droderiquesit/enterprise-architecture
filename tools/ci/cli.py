"""python3 -m tools.ci - test impact selection, fingerprint test cache, sharded multi-agent fan-out, local parity.

    python3 -m tools.ci plan   [--selection sel.json | --base REV | --target main] [--scope platform|applications]
                               [--full] [--cache DIR|URL] [--no-cache] [--out plan.json] [--ado]
    python3 -m tools.ci run    [--changed | --all] [--jobs N] [--base REV] [--cache DIR] [--no-cache] [--out DIR]
    python3 -m tools.ci run    --plan plan.json --leg NAME [--jobs N] ...          # one CI leg (matrix job)
    python3 -m tools.ci report --plan plan.json --results DIR [--timeline tl.json] --out timing.json [--markdown f]
    python3 -m tools.ci gates  [--jobs N]                                          # cheap static gates
    python3 -m tools.ci check                                                      # suites.yaml well-formed
    python3 -m tools.ci tf-mirror --mirror DIR [--config-out FILE]                 # read-only provider mirror
    python3 -m tools.ci scan   --out DIR [--selection sel.json] [--full]          # security scanners in parallel
    python3 -m tools.ci failfast                                                   # cancel this run (gate failed)

`run --changed` (default) is the local equivalent of a PR build: the working tree (uncommitted changes included)
against the merge-base with origin/main; `--all` is the nightly full run (no cache hits). Local caches live in
.ci-cache/ (test results, timings); CI uses the same code with Cache@2 directories / the testcache blob container.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
import time
from pathlib import Path
from typing import Optional

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))

from tools.changeset.registry import load_registry  # noqa: E402
from tools.changeset.trees import WorkTree  # noqa: E402

from . import balance, catalog, impact  # noqa: E402
from .cache import ResultCache  # noqa: E402

LOCAL_CACHE = ".ci-cache"


def _now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def compute_selection(repo: Path, env: str, base: Optional[str], target: str, worktree: bool, scope: Optional[str]) -> dict:
    from tools.changeset.select import select_pr

    try:
        return select_pr(repo, env, target=target, base=base, head=None if worktree else "HEAD", scope=scope,
                         worktree=worktree)
    except RuntimeError as exc:
        if base:
            raise
        print(f"ci: {exc}; comparing the working tree with HEAD instead (uncommitted changes only)", file=sys.stderr)
        return select_pr(repo, env, target=target, base="HEAD", head=None if worktree else "HEAD", scope=scope,
                         worktree=worktree)


def build_plan(repo: Path, selection: dict, *, scope: Optional[str] = None, full: bool = False,
               cache: Optional[ResultCache] = None, use_cache: bool = True, max_legs: Optional[int] = None,
               timings: Optional[dict] = None) -> dict:
    tree = WorkTree(repo)
    registry = load_registry(tree)
    cat = catalog.load(tree, registry)
    sel = impact.select(cat, selection, tree, registry, scope=scope, full=full,
                        module_dirs=impact.module_dirs(repo) if full or "changed_files" not in selection else None)
    timings = timings or balance.load_timings()
    d = cat.defaults
    target = float(d.get("target_leg_seconds", 240))
    legs_cap = max_legs or int((d.get("max_legs") or {}).get(scope or "platform", 24))
    suites, units = {}, []
    for sid, item in sel.items():
        s = item["suite"]
        files = catalog.pytest_files(repo, s) if s.kind == "pytest" else None
        est = balance.estimate(s, timings, files)
        entry = {"status": "run", "reasons": item["reasons"], "fingerprint": s.fingerprint, "tier": s.tier,
                 "kind": s.kind, "toolchain": s.toolchain, "scope": s.scope, "cacheable": s.cache,
                 "estimate_seconds": round(est, 1)}
        hit = cache.hit(s.fingerprint) if (cache and use_cache and s.cache and not full) else None
        if hit:
            entry.update(status="cached", cache_hit={"run": hit.get("run"), "at": hit.get("at")})
        else:
            for u in balance.units_for(s, timings, target, files):
                units.append(u)
        suites[sid] = entry
    legs = balance.pack(units, target, legs_cap)
    overhead = balance.DEFAULTS["leg_overhead"]
    plan = {
        "schema_version": 1, "generated_at": _now(), "scope": scope or "all",
        "mode": "full" if full else ("deploy" if "changed_files" not in selection else "changed"),
        "base": selection.get("base"), "head": selection.get("head"), "use_cache": bool(use_cache and not full),
        "suites": dict(sorted(suites.items())),
        "legs": [{"name": lg.name, "toolchain": lg.toolchain, "estimate_seconds": round(lg.seconds, 1),
                  "units": [{"suite": u.suite, "shard": u.shard, "files": u.files, "seconds": u.seconds,
                             "toolchain": u.toolchain, "tier": u.tier} for u in lg.units]} for lg in legs],
    }
    plan["estimate"] = {"serial_seconds": round(sum(u.seconds for u in units), 1),
                        "critical_leg_seconds": round(max((lg.seconds for lg in legs), default=0.0) + overhead, 1),
                        "legs": len(legs), "leg_overhead_seconds": overhead}
    return plan


def ado_matrix(plan: dict) -> dict:
    return {lg["name"]: {"CI_LEG": lg["name"], "CI_TOOLCHAIN": lg["toolchain"]} for lg in plan["legs"]}


def _units(leg: dict):
    return [balance.Unit(u["suite"], u["toolchain"], u["tier"], u["seconds"], u.get("files"), u.get("shard") or "")
            for u in leg["units"]]


def _suites_for(repo: Path, plan: dict) -> dict:
    tree = WorkTree(repo)
    cat = catalog.load(tree, load_registry(tree))
    out = dict(cat.suites)
    for sid in plan["suites"]:
        if sid.startswith("module:"):
            out[sid] = catalog.module_suite(sid.split(":", 1)[1])
    return out


def execute(repo: Path, plan: dict, legs: list, *, jobs: int, out_dir: Path, cache: Optional[ResultCache],
            env_name: str, enable_env_suites: bool, leg_name: str) -> dict:
    from .runner import run_units

    suites = _suites_for(repo, plan)
    fps = {sid: e["fingerprint"] for sid, e in plan["suites"].items()}
    units = [u for lg in legs for u in _units(lg)]
    if any(u.toolchain == "terraform" for u in units) and not os.environ.get("TF_CLI_CONFIG_FILE"):
        local_mirror(repo, out_dir)
    start = time.monotonic()
    results = run_units(units, suites, repo, jobs=jobs, out_dir=out_dir, env_name=env_name, cache=cache,
                        fingerprints=fps, enable_env_suites=enable_env_suites)
    doc = {"leg": leg_name, "started_at": _now(), "seconds": round(time.monotonic() - start, 2), "jobs": jobs,
           "results": results}
    (out_dir / "ci-results.json").write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n")
    return doc


def local_mirror(repo: Path, out_dir: Path) -> Optional[Path]:
    """Local parity with CI: install providers from a read-only filesystem mirror instead of a shared plugin cache
    (parallel inits). Mirror: $CI_TF_MIRROR, else the plugin_cache_dir of ~/.terraformrc (same layout), else
    .ci-cache/tf-mirror (populated once)."""
    import re as _re

    from . import tfmirror

    mirror = os.environ.get("CI_TF_MIRROR")
    rc = Path.home() / ".terraformrc"
    if not mirror and rc.exists():
        m = _re.search(r'plugin_cache_dir\s*=\s*"([^"]+)"', rc.read_text())
        mirror = m.group(1) if m else None
    mirror_path = Path(mirror or REPO / LOCAL_CACHE / "tf-mirror")
    try:
        tfmirror.populate(mirror_path, tfmirror.lock_providers(repo))
    except (RuntimeError, OSError) as exc:
        print(f"ci: provider mirror incomplete ({exc}); terraform falls back to its own configuration")
        return None
    cfg = tfmirror.cli_config(mirror_path, out_dir / "terraformrc")
    os.environ["TF_CLI_CONFIG_FILE"] = str(cfg)
    os.environ["TF_PLUGIN_CACHE_DIR"] = ""
    os.environ.pop("TF_PLUGIN_CACHE_DIR")
    return cfg


def promote_shards(plan: dict, cache: Optional[ResultCache]) -> list:
    if cache is None:
        return []
    done = []
    parts = {}
    for lg in plan["legs"]:
        for u in lg["units"]:
            if u.get("shard"):
                parts.setdefault(u["suite"], []).append(u["files"])
    for sid, p in sorted(parts.items()):
        if cache.promote(sid, plan["suites"][sid]["fingerprint"], p):
            done.append(sid)
    return done


def record_passes(plan: dict, leg_results: list, cache: Optional[ResultCache]) -> int:
    """Write the passes of all legs into the (aggregated) cache: the legs' own cache dirs are per agent."""
    if cache is None:
        return 0
    n = 0
    for lr in leg_results:
        for r in lr.get("results", []):
            e = plan["suites"].get(r["suite"]) or {}
            if r["status"] == "passed" and e.get("cacheable", True) and e.get("fingerprint"):
                files = next((u.get("files") for lg in plan["legs"] for u in lg["units"]
                              if u["suite"] == r["suite"] and (u.get("shard") or "") == (r.get("shard") or "")), None)
                cache.record(r["suite"], e["fingerprint"], r["seconds"], files if r.get("shard") else None, lr.get("leg", ""))
                n += 1
    return n


def observed_timings(leg_results: list) -> dict:
    out = {"suites": {}, "files": {}}
    for lr in leg_results:
        for r in lr.get("results", []):
            if r["status"] != "passed":
                continue
            if not r.get("shard"):
                out["suites"][r["suite"]] = r["seconds"]
            out["files"].update(r.get("file_seconds") or {})
    return out


def _print_plan(plan: dict) -> None:
    for sid, e in plan["suites"].items():
        print(f"  {e['status']:6} {sid:42} {e['estimate_seconds']:>7.1f}s  {e['reasons'][0][:90]}")
    est = plan["estimate"]
    print(f"plan: {len(plan['suites'])} suite(s), {sum(e['status'] == 'cached' for e in plan['suites'].values())} cached, "
          f"{est['legs']} leg(s), serial {est['serial_seconds']}s, critical leg ~{est['critical_leg_seconds']}s")


# ------------------------------------------------------------------------------------------------ commands
def _cache(args) -> Optional[ResultCache]:
    if getattr(args, "no_cache", False):
        return None
    return ResultCache.open(args.cache or os.environ.get("CI_TEST_CACHE") or str(REPO / LOCAL_CACHE / "testcache"))


def _timings_path(args) -> Path:
    return Path(getattr(args, "timings", None) or os.environ.get("CI_TIMINGS") or REPO / LOCAL_CACHE / "timings.json")


def cmd_plan(args) -> int:
    repo = Path(args.repo).resolve()
    sel = json.loads(Path(args.selection).read_text()) if args.selection else \
        compute_selection(repo, args.env, args.base, args.target, args.worktree, args.scope)
    plan = build_plan(repo, sel, scope=args.scope, full=args.full, cache=_cache(args), use_cache=not args.no_cache,
                      max_legs=args.max_legs, timings=balance.load_timings(_timings_path(args)))
    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(json.dumps(plan, indent=2, sort_keys=True) + "\n")
    if args.ado:
        m = ado_matrix(plan)
        print(f"##vso[task.setvariable variable=matrix;isOutput=true]{json.dumps(m, separators=(',', ':'), sort_keys=True)}")
        print(f"##vso[task.setvariable variable=count;isOutput=true]{len(m)}")
    _print_plan(plan)
    return 0


def cmd_run(args) -> int:
    repo = Path(args.repo).resolve()
    jobs = args.jobs or os.cpu_count() or 2
    out_dir = Path(args.out or (REPO / LOCAL_CACHE / "runs" / dt.datetime.now().strftime("%Y%m%dT%H%M%S")))
    cache = _cache(args)
    if args.plan:
        plan = json.loads(Path(args.plan).read_text())
        legs = [lg for lg in plan["legs"] if not args.leg or lg["name"] == args.leg]
        if args.leg and not legs:
            print(f"leg {args.leg} not in the plan", file=sys.stderr)
            return 2
    else:
        sel = compute_selection(repo, args.env, args.base or ("HEAD" if args.all else None), args.target,
                                worktree=not args.all, scope=args.scope)
        plan = build_plan(repo, sel, scope=args.scope, full=args.all, cache=cache, use_cache=not args.no_cache,
                          timings=balance.load_timings(_timings_path(args)))
        _print_plan(plan)
        legs = plan["legs"]
        out_dir.mkdir(parents=True, exist_ok=True)
        (out_dir / "ci-plan.json").write_text(json.dumps(plan, indent=2, sort_keys=True) + "\n")
    t0 = time.monotonic()
    doc = execute(repo, plan, legs, jobs=jobs, out_dir=out_dir, cache=cache, env_name=args.env,
                  enable_env_suites=args.enable_env_suites, leg_name=args.leg or "local")
    wall = time.monotonic() - t0
    if not args.leg:
        promote_shards(plan, cache)
        from . import report

        rep = report.build(plan, [doc])
        rep["wall_seconds"] = round(wall, 1)
        (out_dir / "timing.json").write_text(json.dumps(rep, indent=2, sort_keys=True) + "\n")
        tp = _timings_path(args)
        tp.parent.mkdir(parents=True, exist_ok=True)
        tp.write_text(json.dumps(balance.merge_timings(balance.load_timings(tp) if tp.exists() else {}, observed_timings([doc])),
                                 indent=2, sort_keys=True) + "\n")
        print(f"ci: {len(doc['results'])} unit(s) in {wall:.1f}s with {jobs} job(s); "
              f"{rep['suites_cached']} suite(s) from cache; results: {out_dir}")
    failed = [r for r in doc["results"] if r["status"] == "failed"]
    return 1 if failed else 0


def cmd_report(args) -> int:
    from . import report

    plan = json.loads(Path(args.plan).read_text())
    legs = report.load_leg_results(Path(args.results))
    tl = json.loads(Path(args.timeline).read_text()) if args.timeline and Path(args.timeline).exists() else None
    if tl is None and os.environ.get("SYSTEM_ACCESSTOKEN"):
        from tools.report.pr_budget import fetch_timeline

        tl = fetch_timeline() or None
    doc = report.build(plan, legs, tl, args.budget_minutes)
    cache = _cache(args)
    doc["recorded_passes"] = record_passes(plan, legs, cache)
    doc["promoted_shards"] = promote_shards(plan, cache)
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n")
    md = report.markdown(doc)
    if args.markdown:
        Path(args.markdown).write_text(md)
        if os.environ.get("TF_BUILD"):
            print(f"##vso[task.uploadsummary]{Path(args.markdown).resolve()}")
    if args.timings_out:
        old = balance.load_timings(Path(args.timings_out)) if Path(args.timings_out).exists() else {}
        Path(args.timings_out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.timings_out).write_text(json.dumps(balance.merge_timings(old, observed_timings(legs)), indent=2,
                                                     sort_keys=True) + "\n")
    if doc["over_budget"]:
        print(f"##vso[task.logissue type=warning]CI over budget ({doc['change_class']}, {doc['budget_minutes']} min): "
              f"critical leg {doc['validate_critical_leg']} {doc['validate_seconds']} s")
    print(md)
    return 0


def cmd_gates(args) -> int:
    from . import gates

    return gates.run(Path(args.repo).resolve(), args.env, args.jobs or 8)


def cmd_check(args) -> int:
    import yaml

    repo = Path(args.repo).resolve()
    errors = catalog.validate_doc(yaml.safe_load((repo / catalog.SUITES_FILE).read_text()) or {})
    tree = WorkTree(repo)
    reg = load_registry(tree)
    cat = catalog.load(tree, reg) if not errors else None
    if cat:
        for sid, s in cat.suites.items():
            for c in s.covers:
                if c not in reg:
                    errors.append(f"{sid}: covers unknown component {c}")
            for p in s.paths:
                if not (repo / p).exists():
                    errors.append(f"{sid}: path {p} does not exist")
            if s.kind == "pytest" and not catalog.pytest_files(repo, s):
                errors.append(f"{sid}: no test_*.py under {s.paths}")
    for e in errors:
        print(f"ERROR: tools/ci/suites.yaml: {e}")
    if not errors:
        print(f"ci suites: {len(cat.suites)} suite(s) OK")
    return 1 if errors else 0


def cmd_tf_mirror(args) -> int:
    from . import tfmirror

    repo = Path(args.repo).resolve()
    mirror = Path(args.mirror)
    providers = tfmirror.lock_providers(repo, [r for r in (args.roots or "").split(",") if r] or None)
    added = tfmirror.populate(mirror, providers)
    cfg = tfmirror.cli_config(mirror, Path(args.config_out or mirror / "terraformrc"))
    print(f"mirror {mirror}: {len(providers)} provider version(s), {len(added)} downloaded")
    if os.environ.get("TF_BUILD"):
        print(f"##vso[task.setvariable variable=TF_CLI_CONFIG_FILE]{cfg}")
        print("##vso[task.setvariable variable=TF_PLUGIN_CACHE_DIR]")
    print(f"TF_CLI_CONFIG_FILE={cfg}")
    return 0


def cmd_scan(args) -> int:
    from . import scan

    sel = json.loads(Path(args.selection).read_text()) if args.selection and Path(args.selection).exists() else None
    return scan.run(Path(args.repo).resolve(), Path(args.out), sel, full=args.full or sel is None,
                    fail=not args.soft_fail)


def cmd_failfast(args) -> int:
    from .failfast import cancel_run

    return 0 if cancel_run() else 1


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="python3 -m tools.ci", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=str(REPO))
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(p, selection=True):
        p.add_argument("--env", default="dev")
        p.add_argument("--scope", choices=("platform", "applications"))
        p.add_argument("--cache", help="test result cache: directory or https://<acct>.blob.core.windows.net/testcache")
        p.add_argument("--no-cache", action="store_true")
        p.add_argument("--timings", help="observed timings JSON (default .ci-cache/timings.json)")
        if selection:
            p.add_argument("--base", help="diff base revision (default: merge-base with origin/<target>)")
            p.add_argument("--target", default="main")

    p = sub.add_parser("plan")
    common(p)
    p.add_argument("--selection", help="tools.changeset select output (Select stage)")
    p.add_argument("--worktree", action="store_true", help="include uncommitted changes")
    p.add_argument("--full", action="store_true", help="every suite, no cache hits (nightly / release)")
    p.add_argument("--max-legs", type=int)
    p.add_argument("--out")
    p.add_argument("--ado", action="store_true")
    p.set_defaults(func=cmd_plan)

    r = sub.add_parser("run")
    common(r)
    g = r.add_mutually_exclusive_group()
    g.add_argument("--changed", action="store_true", help="(default) impact-selected suites for the working tree")
    g.add_argument("--all", action="store_true", help="every suite, no cache hits")
    r.add_argument("--plan", help="run legs of an existing plan (CI)")
    r.add_argument("--leg", help="run one leg of --plan")
    r.add_argument("--jobs", type=int, help="parallel CPU tokens (default: CPU count)")
    r.add_argument("--enable-env-suites", action="store_true",
                   help="set needs_env (e.g. E2E=1) for suites that need docker instead of skipping them")
    r.add_argument("--out")
    r.set_defaults(func=cmd_run)

    rp = sub.add_parser("report")
    rp.add_argument("--plan", required=True)
    rp.add_argument("--results", required=True, help="directory with the legs' ci-results.json")
    rp.add_argument("--timeline")
    rp.add_argument("--budget-minutes", type=float)
    rp.add_argument("--cache")
    rp.add_argument("--no-cache", action="store_true")
    rp.add_argument("--timings-out", help="merge observed timings into this file (cached for the next plan)")
    rp.add_argument("--out", required=True)
    rp.add_argument("--markdown")
    rp.set_defaults(func=cmd_report)

    gt = sub.add_parser("gates")
    gt.add_argument("--env", default="dev")
    gt.add_argument("--jobs", type=int)
    gt.set_defaults(func=cmd_gates)

    ck = sub.add_parser("check")
    ck.set_defaults(func=cmd_check)

    tm = sub.add_parser("tf-mirror")
    tm.add_argument("--mirror", required=True)
    tm.add_argument("--roots", help="comma list of root dirs (default: every committed lock file)")
    tm.add_argument("--config-out")
    tm.set_defaults(func=cmd_tf_mirror)

    sc = sub.add_parser("scan")
    sc.add_argument("--out", required=True)
    sc.add_argument("--selection", help="PR: scan only the changed scope")
    sc.add_argument("--full", action="store_true")
    sc.add_argument("--soft-fail", action="store_true")
    sc.set_defaults(func=cmd_scan)

    ff = sub.add_parser("failfast")
    ff.set_defaults(func=cmd_failfast)

    args = ap.parse_args(argv)
    return args.func(args)
