#!/usr/bin/env python3
"""Automatic per-component versions (keep it simple).

    python3 tools/deploy/versioning.py version    --component svc-bff [--ref refs/heads/main --build 123 --sha <sha>]
    python3 tools/deploy/versioning.py docker-tag --component svc-bff ...
    python3 tools/deploy/versioning.py changelog  --component svc-bff

version = <semver from <component path>/VERSION, else 0.1.0>
  + "+<build>.<sha7>"     for every branch build (main included): unique, sortable by build, traceable to the commit
  clean "<semver>"        for a tag build `refs/tags/<component>-v<semver>` (or `v<semver>`) that matches VERSION
docker-tag = the version with "+" replaced by "-" (OCI tags cannot contain "+"). Images are ALSO tagged with the
immutable source-fingerprint tag `src-<fp24>` (the reuse key, tools/deploy/artifacts.py) and are always DEPLOYED BY
DIGEST; the version is metadata (OCI label, build-metadata.json `version`, DD_VERSION), never the deploy reference.
changelog prints optional towncrier-like fragments `changes/<component>/*.md` (sorted), for release notes.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path
from typing import Optional

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))
SEMVER = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-[0-9A-Za-z.-]+)?$")
DEFAULT = "0.1.0"


def base_version(component_path: str, repo: Path = REPO) -> str:
    f = Path(repo) / component_path / "VERSION"
    if f.exists():
        v = f.read_text().strip()
        if not SEMVER.match(v):
            raise ValueError(f"{f}: '{v}' is not a semantic version")
        return v
    return DEFAULT


def version(component: str, component_path: str, ref: str = "", build: str = "", sha: str = "", repo: Path = REPO) -> str:
    v = base_version(component_path, repo)
    if ref.startswith("refs/tags/"):
        tag = ref[len("refs/tags/"):]
        if tag in (f"{component}-v{v}", f"v{v}"):
            return v
    build = build or "0"
    sha7 = (sha or "unknown")[:7]
    return f"{v}+{build}.{sha7}"


def docker_tag(v: str) -> str:
    return v.replace("+", "-")


def changelog(component: str, repo: Path = REPO) -> str:
    d = Path(repo) / "changes" / component
    if not d.is_dir():
        return ""
    return "\n".join(f.read_text().strip() for f in sorted(d.glob("*.md"))) + "\n"


def for_component(component: str, repo: Path = REPO, ref: Optional[str] = None, build: Optional[str] = None,
                  sha: Optional[str] = None) -> str:
    from tools.changeset.registry import load_registry
    from tools.changeset.trees import WorkTree

    c = load_registry(WorkTree(repo)).get(component)
    return version(component, c.path, ref if ref is not None else os.environ.get("BUILD_SOURCEBRANCH", ""),
                   build if build is not None else os.environ.get("BUILD_BUILDID", ""),
                   sha if sha is not None else os.environ.get("BUILD_SOURCEVERSION", ""), repo)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("op", choices=("version", "docker-tag", "changelog"))
    ap.add_argument("--component", required=True)
    ap.add_argument("--ref")
    ap.add_argument("--build")
    ap.add_argument("--sha")
    args = ap.parse_args(argv)
    if args.op == "changelog":
        sys.stdout.write(changelog(args.component))
        return 0
    v = for_component(args.component, ref=args.ref, build=args.build, sha=args.sha)
    print(docker_tag(v) if args.op == "docker-tag" else v)
    return 0


if __name__ == "__main__":
    sys.exit(main())
