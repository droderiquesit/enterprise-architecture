"""Dependency version changes in lockfiles / exact pins, classified as patch | minor | major | added | removed.

Parsed as DATA (regex / json): requirements*.txt (`name==x.y.z`), package-lock.json (lockfileVersion 2/3
`packages`), .terraform.lock.hcl (`provider "..." { version = "x" }`), Directory.Packages.props
(`<PackageVersion Include= Version=>`), packages.lock.json (NuGet `resolved`).
"""

from __future__ import annotations

import json
import re
from typing import Dict, List, Optional, Tuple

PEP440 = re.compile(r"^\s*([A-Za-z0-9][A-Za-z0-9._-]*)(?:\[[^\]]*\])?\s*==\s*([0-9][^\s;#]*)")
TF_PROVIDER = re.compile(r'provider\s+"([^"]+)"\s*\{[^}]*?version\s*=\s*"([^"]+)"', re.S)
NUGET_PROPS = re.compile(r'<PackageVersion\s+Include="([^"]+)"\s+Version="([^"]+)"', re.I)
SEMVER = re.compile(r"^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?(.*)$")


def _req(text: str) -> Dict[str, str]:
    out = {}
    for line in text.splitlines():
        m = PEP440.match(line)
        if m:
            out[m.group(1).lower().replace("_", "-")] = m.group(2)
    return out


def _npm(text: str) -> Dict[str, str]:
    try:
        doc = json.loads(text)
    except ValueError:
        return {}
    out = {}
    for path, meta in (doc.get("packages") or {}).items():
        if path and isinstance(meta, dict) and meta.get("version"):
            out[path] = str(meta["version"])
    for name, meta in (doc.get("dependencies") or {}).items():   # lockfileVersion 1
        if isinstance(meta, dict) and meta.get("version") and f"node_modules/{name}" not in out:
            out[f"node_modules/{name}"] = str(meta["version"])
    return out


def _nuget_lock(text: str) -> Dict[str, str]:
    try:
        doc = json.loads(text)
    except ValueError:
        return {}
    out = {}
    for fw, deps in (doc.get("dependencies") or {}).items():
        for name, meta in (deps or {}).items():
            if isinstance(meta, dict) and meta.get("resolved"):
                out[f"{fw}/{name}"] = str(meta["resolved"])
    return out


def parse(path: str, text: Optional[str]) -> Optional[Dict[str, str]]:
    if text is None:
        return {}
    name = path.rsplit("/", 1)[-1]
    if name.endswith(".txt") and name.startswith("requirements"):
        return _req(text)
    if name == "package-lock.json":
        return _npm(text)
    if name == ".terraform.lock.hcl":
        return dict(TF_PROVIDER.findall(text))
    if name == "Directory.Packages.props":
        return {k: v for k, v in NUGET_PROPS.findall(text)}
    if name == "packages.lock.json":
        return _nuget_lock(text)
    return None


def bump(old: str, new: str) -> str:
    a, b = SEMVER.match(old), SEMVER.match(new)
    if not a or not b:
        return "major"
    pa = [int(x or 0) for x in a.groups()[:3]]
    pb = [int(x or 0) for x in b.groups()[:3]]
    if a.group(4) or b.group(4):      # pre-release / local versions: never "patch"
        return "major" if pa[0] != pb[0] else "minor"
    if pb < pa:
        return "downgrade"
    if pa[0] != pb[0]:
        return "major"
    if pa[1] != pb[1]:
        return "minor"
    return "patch" if pa[2] != pb[2] else "same"


def classify(path: str, base: Optional[str], head: Optional[str]) -> Optional[List[Tuple[str, str, Optional[str], Optional[str]]]]:
    """[(package, kind, old, new)] for changed entries, or None when the file format is not understood."""
    old, new = parse(path, base), parse(path, head)
    if old is None or new is None:
        return None
    out = []
    for pkg in sorted(set(old) | set(new)):
        o, n = old.get(pkg), new.get(pkg)
        if o == n:
            continue
        if o is None:
            out.append((pkg, "added", None, n))
        elif n is None:
            out.append((pkg, "removed", o, None))
        else:
            out.append((pkg, bump(o, n), o, n))
    return out
