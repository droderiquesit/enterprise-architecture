#!/usr/bin/env python3
"""Artifact helpers for the Build stage and for deploy roots.

  tag         print the immutable tag of an artifact: src-<first 24 hex of its deploy fingerprint>
  resolve     look for an existing image/package for that tag (ACR / `packages` container); when all
              formats exist, write build-metadata.json and set ARTIFACT_EXISTS=true (skip the build)
  image-meta  write the per-format JSON of a pushed image (repository, digest, tag)
  stage/zip   deterministic packaging helpers (sorted entries, fixed timestamps => reproducible sha256)
  finalize    upload packages, write build-metadata.json (source commit, digests, sha256, SBOM refs)
              and the artifact's record (<env>/<component>.json, kind artifact)
  promote     (environments after the first of a promotion chain) copy the image digest / package sha256 the
              `promote_from` environment recorded for the SAME source fingerprint; never builds; fails if missing
  tfvars      for a deploy root: write <root>/artifacts.auto.tfvars.json with
              artifacts = {<artifact component id> = {name, image, digest, package_url, package_sha256,
              source_fp, tag}} when the root declares `variable "artifacts"`; print the sha256.
              Artifacts built by the OTHER pipeline scope (--recorded, e.g. img-dsv-fetch of the platform pipeline
              consumed by applications roots) come from their deployment record <env>/<artifact>.json
              (artifact_metadata), which must be `succeeded` for the artifact's CURRENT source fingerprint
              (selection document) - otherwise the plan fails instead of deploying a stale digest.
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
from typing import List, Optional

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
        "artifact_metadata": {k: v for k, v in meta.items() if k not in ("reused",)},
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
    try:  # human version <semver>+<build>.<sha7> (tools/deploy/versioning.py); metadata only, deploys use the digest
        from tools.deploy.versioning import for_component

        meta["version"] = for_component(args.component)
    except Exception as exc:  # noqa: BLE001 - a bad VERSION file must not lose a built artifact
        print(f"##vso[task.logissue type=warning]{args.component}: no version ({exc})")
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


# ------------------------------------------------------------------- promotion
class PromotionError(Exception):
    pass


def _acr_digest(registry: str, ref: str) -> str:
    proc = _run(["az", "acr", "manifest", "show-metadata", "--registry", registry, "--name", ref,
                 "--query", "digest", "-o", "tsv", "--only-show-errors"])
    return proc.stdout.strip() if proc.returncode == 0 else ""


def _acr_import(target: str, source_image: str, target_ref: str) -> None:
    proc = _run(["az", "acr", "import", "--name", target, "--source", source_image, "--image", target_ref,
                 "--force", "--only-show-errors"])
    if proc.returncode != 0:
        raise PromotionError(f"az acr import {source_image} -> {target}/{target_ref} failed: {proc.stderr.strip()[:400]}")


def promote(component: str, selection: dict, env: str, source_env: str, source_records, source_packages,
            target_packages, target_registry: str, source_registry: str, packages_url: str) -> dict:
    """Copy exactly what `source_env` recorded for this artifact (same source fingerprint) into this env.

    Never builds. Fails when the source environment has no successful record for the same source fingerprint.
    Container images keep their digest (az acr import copies the manifest unchanged; verified afterwards);
    packages are copied and their sha256 verified."""
    fp = selection["components"][component]["deploy_fp"]
    rec = source_records.get_json(f"{source_env}/{component}.json")
    if not rec or rec.get("status") != "succeeded":
        raise PromotionError(f"{component}: no successful artifact record in '{source_env}' - deploy/promote "
                             f"'{source_env}' first (build once, promote)")
    meta = dict(rec.get("artifact_metadata") or {})
    if not meta:
        raise PromotionError(f"{component}: the '{source_env}' record has no artifact_metadata (re-run its Build stage)")
    if meta.get("source_fp") != fp or rec.get("deploy_fp") != fp:
        raise PromotionError(f"{component}: '{source_env}' recorded source fingerprint {str(meta.get('source_fp'))[:12]} but "
                             f"this commit needs {fp[:12]} - promote the same commit through '{source_env}' first")
    tag = meta.get("tag") or ("src-" + fp[:24])
    out = {k: v for k, v in meta.items() if k not in ("reused", "attachments")}
    if meta.get("digest"):
        digest = meta["digest"]
        name = meta.get("name") or component
        if _acr_digest(target_registry, f"{name}:{tag}") != digest:
            _acr_import(target_registry, f"{source_registry}.azurecr.io/{name}@{digest}", f"{name}:{tag}")
            got = _acr_digest(target_registry, f"{name}:{tag}")
            if got != digest:
                raise PromotionError(f"{component}: digest after import {got!r} != promoted digest {digest}")
        repo = f"{target_registry}.azurecr.io/{name}"
        out.update({"image": f"{repo}@{digest}", "repository": repo, "digest": digest})
    if meta.get("package_sha256"):
        name = meta.get("name") or component
        key = f"{name}/{tag}.zip"
        data = source_packages.get_bytes(key)
        if data is None:
            raise PromotionError(f"{component}: package {key} missing in '{source_env}' packages container")
        if hashlib.sha256(data).hexdigest() != meta["package_sha256"]:
            raise PromotionError(f"{component}: package {key} sha256 differs from the '{source_env}' record")
        target_packages.put_bytes(key, data, "application/zip")
        url = f"{packages_url.rstrip('/')}/{key}"
        target_packages.put_json(f"{name}/{tag}.json", {"package_url": url, "package_sha256": meta["package_sha256"],
                                                         "commit": meta.get("commit"), "promoted_from": source_env})
        out.update({"package_url": url})
    out.update({"promoted_from": source_env, "reused": True, "tag": tag})
    return out


def cmd_promote(args) -> int:
    sel = _selection(args.selection)
    try:
        meta = promote(args.component, sel, args.env, args.source_env, open_store(args.source_records_url),
                       open_store(args.source_packages_url), open_store(args.packages_url),
                       args.registry, args.source_registry, args.packages_url)
    except PromotionError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        print(f"##vso[task.logissue type=error]{exc}")
        return 1
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "build-metadata.json").write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n")
    print(f"promoted {args.component} from {args.source_env}: digest={meta.get('digest')} sha256={meta.get('package_sha256')}")
    print("##vso[task.setvariable variable=ARTIFACT_EXISTS]true")
    return 0


class RecordError(Exception):
    pass


def recorded_metadata(component: str, records, env: str, selection: Optional[dict]) -> dict:
    """build-metadata of an artifact built by the other pipeline, from its deployment record."""
    rec = records.get_json(f"{env}/{component}.json") if records else None
    if not rec or rec.get("status") != "succeeded" or not rec.get("artifact_metadata"):
        raise RecordError(f"{component}: no succeeded artifact record in '{env}' - the "
                          f"{'platform' if component.startswith('img-') else 'other'} pipeline must build it first")
    meta = dict(rec["artifact_metadata"])
    want = ((selection or {}).get("components") or {}).get(component, {}).get("deploy_fp")
    if want and meta.get("source_fp") != want:
        raise RecordError(f"{component}: recorded source fingerprint {str(meta.get('source_fp'))[:12]} != current "
                          f"{want[:12]} - wait for the pipeline that builds it (selection marks this root waiting)")
    return meta


def artifacts_tfvars(repo: Path, component: str, metadata_dir: Path, write: bool = True,
                     recorded: Optional[List[str]] = None, records=None, env: Optional[str] = None,
                     selection: Optional[dict] = None):
    tree = WorkTree(repo)
    comp = load_registry(tree).get(component)
    recorded = set(recorded or [])
    entries = {}
    missing = []
    for a in comp.artifacts:
        f = metadata_dir / a / "build-metadata.json"
        if f.exists():
            m = json.loads(f.read_text())
        elif a in recorded:
            try:
                m = recorded_metadata(a, records, env or "", selection)
            except RecordError as exc:
                raise SystemExit(f"ERROR: {exc}") from None
        else:
            missing.append(a)
            continue
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
    recorded = [a for a in (args.recorded or "").split(",") if a]
    records = open_store(args.records_url) if recorded and args.records_url else None
    selection = _selection(args.selection) if args.selection and Path(args.selection).exists() else None
    _entries, digest = artifacts_tfvars(Path(args.repo).resolve(), args.component, Path(args.metadata_dir),
                                        recorded=recorded, records=records, env=args.env, selection=selection)
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
    pr = sub.add_parser("promote", help="copy the artifact recorded by the source environment (never builds)")
    for a in ("--component", "--selection", "--env", "--source-env", "--source-records-url", "--source-packages-url",
              "--registry", "--source-registry", "--packages-url", "--out"):
        pr.add_argument(a, required=True)
    pr.set_defaults(func=cmd_promote)
    v = sub.add_parser("tfvars")
    v.add_argument("--component", required=True)
    v.add_argument("--metadata-dir", required=True)
    v.add_argument("--recorded", default="", help="comma separated artifacts read from deployment records (other scope)")
    v.add_argument("--records-url", default="")
    v.add_argument("--selection", default="")
    v.add_argument("--env", default="")
    v.set_defaults(func=cmd_tfvars)
    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
