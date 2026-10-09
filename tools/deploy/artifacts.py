#!/usr/bin/env python3
"""Artifact helpers for the Build stage and for deploy roots.

  tag         print the immutable tag of an artifact: src-<first 24 hex of its deploy fingerprint>
  resolve     look for an existing image/package for that tag (ACR / `packages` container); when all
              formats exist, write build-metadata.json and set ARTIFACT_EXISTS=true (skip the build)
  image-meta  write the per-format JSON of a pushed image (repository, digest, tag)
  stage/zip   deterministic packaging helpers (sorted entries, fixed timestamps => reproducible sha256)
  finalize    upload packages, write build-metadata.json (source commit, digests, sha256, SBOM refs)
              and the artifact's record (<env>/<component>.json, kind artifact)
  tfvars      for a deploy root: write <root>/artifacts.auto.tfvars.json with
              artifacts = {<artifact component id> = {name, image, digest, package_url, package_sha256,
              source_fp, tag}} when the root declares `variable "artifacts"`; print the sha256
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.changeset.registry import load_registry  # noqa: E402
from tools.changeset.store import open_store  # noqa: E402
from tools.changeset.trees import WorkTree  # noqa: E402
from tools.config.lib import declared_variables  # noqa: E402

FIXED_TS = (2020, 1, 1, 0, 0, 0)
SKIP_DIRS = {"tests", "test", "__pycache__", ".pytest_cache", ".venv", "node_modules", ".git"}
ZIP_FORMATS = ("zip-package", "static-bundle")


def _selection(path: str) -> dict:
    return json.loads(Path(path).read_text())


def tag_for(selection: dict, component: str) -> str:
    fp = selection["components"][component]["deploy_fp"]
    return "src-" + fp[:24]


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def deterministic_zip(src: Path, out: Path) -> str:
    src = Path(src)
    out.parent.mkdir(parents=True, exist_ok=True)
    files = sorted(p for p in src.rglob("*") if p.is_file())
    with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for f in files:
            rel = f.relative_to(src).as_posix()
            info = zipfile.ZipInfo(rel, FIXED_TS)
            info.external_attr = (0o755 if os.access(f, os.X_OK) else 0o644) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            zf.writestr(info, f.read_bytes())
    return sha256_file(out)


def stage_tree(src: Path, out: Path) -> None:
    def ignore(_d, names):
        return [n for n in names if n in SKIP_DIRS or n.endswith((".pyc", ".md"))]

    if out.exists():
        shutil.rmtree(out)
    shutil.copytree(src, out, ignore=ignore)


def _run(cmd) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True)


def cmd_tag(args) -> int:
    print(tag_for(_selection(args.selection), args.component))
    return 0


def cmd_resolve(args) -> int:
    sel = _selection(args.selection)
    tag = tag_for(sel, args.component)
    formats = [f for f in args.formats.split(",") if f]
    meta = {"component": args.component, "name": args.name, "source_fp": sel["components"][args.component]["deploy_fp"],
            "tag": tag, "reused": True, "formats": formats}
    store = open_store(args.packages_url) if any(f in ZIP_FORMATS for f in formats) else None
    for fmt in formats:
        if fmt == "container-image":
            proc = _run(["az", "acr", "manifest", "show-metadata", "--registry", args.registry,
                         "--name", f"{args.name}:{tag}", "--query", "digest", "-o", "tsv", "--only-show-errors"])
            digest = proc.stdout.strip()
            if proc.returncode != 0 or not digest.startswith("sha256:"):
                print(f"{fmt} {args.name}:{tag} not found - will build")
                return 0
            repo = f"{args.registry}.azurecr.io/{args.name}"
            meta.update({"image": f"{repo}@{digest}", "repository": repo, "digest": digest})
        else:
            key = f"{args.name}/{tag}.zip"
            side = store.get_json(f"{args.name}/{tag}.json") if store else None
            if not side:
                print(f"{fmt} {key} not found - will build")
                return 0
            meta.update({"package_url": side.get("package_url"), "package_sha256": side.get("package_sha256")})
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "build-metadata.json").write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n")
    print(f"reusing existing artifact for {args.component} ({tag})")
    print("##vso[task.setvariable variable=ARTIFACT_EXISTS]true")
    return 0


def cmd_image_meta(args) -> int:
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text(json.dumps({"format": "container-image", "image": f"{args.repository}@{args.digest}",
                                          "repository": args.repository, "digest": args.digest, "tag": args.tag},
                                         indent=2) + "\n")
    return 0


def cmd_zip(args) -> int:
    print(deterministic_zip(Path(args.src), Path(args.out)))
    return 0


def cmd_stage(args) -> int:
    stage_tree(Path(args.src), Path(args.out))
    return 0


def _write_record(args, meta: dict, sel: dict) -> None:
    if not args.records_url:
        return
    entry = sel["components"][args.component]
    record = {
        "component": args.component, "env": args.env, "kind": "artifact", "status": "succeeded",
        "deploy_fp": entry["deploy_fp"], "fp_parts": entry.get("fp_parts"),
        "commit": os.environ.get("BUILD_SOURCEVERSION", meta.get("commit", "unknown")),
        "run_id": os.environ.get("BUILD_BUILDID", "local"),
        "finished_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "artifact_digests": {args.component: meta.get("digest") or meta.get("package_sha256")},
        "path": entry.get("path"),
    }
    open_store(args.records_url).put_json(f"{args.env}/{args.component}.json", record)


def cmd_finalize(args) -> int:
    sel = _selection(args.selection)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    existing = out / "build-metadata.json"
    if existing.exists() and json.loads(existing.read_text()).get("reused"):
        meta = json.loads(existing.read_text())
        _write_record(args, meta, sel)
        print("artifact reused; record updated")
        return 0
    build = Path(args.build_dir)
    tag = tag_for(sel, args.component)
    meta = {"component": args.component, "name": args.name, "source_fp": sel["components"][args.component]["deploy_fp"],
            "tag": tag, "reused": False, "commit": os.environ.get("BUILD_SOURCEVERSION", "unknown"),
            "build_time": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "build_run": os.environ.get("BUILD_BUILDID", "local")}
    img = build / "container-image.json"
    if img.exists():
        meta.update({k: v for k, v in json.loads(img.read_text()).items() if k != "format"})
    pkg = build / "package.zip"
    if pkg.exists():
        sha = sha256_file(pkg)
        key = f"{args.name}/{tag}.zip"
        store = open_store(args.packages_url)
        store.put_file(pkg, key, "application/zip")
        url = f"{args.packages_url.rstrip('/')}/{key}"
        store.put_json(f"{args.name}/{tag}.json", {"package_url": url, "package_sha256": sha, "commit": meta["commit"]})
        meta.update({"package_url": url, "package_sha256": sha})
    if not img.exists() and not pkg.exists():
        print("ERROR: build produced neither an image nor a package", file=sys.stderr)
        return 1
    for extra in ("sbom.spdx.json", "buildx-metadata.json"):
        if (build / extra).exists():
            shutil.copy(build / extra, out / extra)
            meta.setdefault("attachments", []).append(extra)
    existing.write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n")
    _write_record(args, meta, sel)
    print(json.dumps(meta, indent=2, sort_keys=True))
    return 0


def artifacts_tfvars(repo: Path, component: str, metadata_dir: Path, write: bool = True):
    tree = WorkTree(repo)
    comp = load_registry(tree).get(component)
    entries = {}
    missing = []
    for a in comp.artifacts:
        f = metadata_dir / a / "build-metadata.json"
        if not f.exists():
            missing.append(a)
            continue
        m = json.loads(f.read_text())
        entries[a] = {k: m.get(k) for k in ("name", "image", "digest", "package_url", "package_sha256", "source_fp", "tag", "commit")}
        # Deployment roots set DD_VERSION / build metadata from these (version = immutable tag derived from source_fp).
        entries[a]["version"] = m.get("version") or m.get("tag")
    if missing:
        raise SystemExit(f"ERROR: artifact metadata missing for {', '.join(missing)} (Build stage output)")
    text = json.dumps({"artifacts": entries}, sort_keys=True, separators=(",", ":"))
    if write and comp.artifacts and "artifacts" in declared_variables(tree, comp.path):
        (repo / comp.path / "artifacts.auto.tfvars.json").write_text(text + "\n")
    return entries, hashlib.sha256(text.encode()).hexdigest()


def cmd_tfvars(args) -> int:
    _entries, digest = artifacts_tfvars(Path(args.repo).resolve(), args.component, Path(args.metadata_dir))
    print(digest)
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=".")
    sub = ap.add_subparsers(dest="cmd", required=True)
    t = sub.add_parser("tag")
    t.add_argument("--component", required=True)
    t.add_argument("--selection", required=True)
    t.set_defaults(func=cmd_tag)
    r = sub.add_parser("resolve")
    for a in ("--component", "--selection", "--registry", "--packages-url", "--name", "--formats", "--out"):
        r.add_argument(a, required=True)
    r.set_defaults(func=cmd_resolve)
    i = sub.add_parser("image-meta")
    for a in ("--out", "--repository", "--digest", "--tag"):
        i.add_argument(a, required=True)
    i.set_defaults(func=cmd_image_meta)
    z = sub.add_parser("zip")
    z.add_argument("--src", required=True)
    z.add_argument("--out", required=True)
    z.set_defaults(func=cmd_zip)
    s = sub.add_parser("stage")
    s.add_argument("--src", required=True)
    s.add_argument("--out", required=True)
    s.set_defaults(func=cmd_stage)
    f = sub.add_parser("finalize")
    for a in ("--component", "--selection", "--build-dir", "--packages-url", "--name", "--out", "--env"):
        f.add_argument(a, required=True)
    f.add_argument("--records-url")
    f.set_defaults(func=cmd_finalize)
    v = sub.add_parser("tfvars")
    v.add_argument("--component", required=True)
    v.add_argument("--metadata-dir", required=True)
    v.set_defaults(func=cmd_tfvars)
    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
