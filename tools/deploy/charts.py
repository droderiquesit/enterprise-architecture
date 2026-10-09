#!/usr/bin/env python3
"""Helm charts under applications/charts/<name>/ (Chart.yaml): lint, render-validate, package, push.

    python3 tools/deploy/charts.py list
    python3 tools/deploy/charts.py lint                   # per value set (ci/values.yaml, examples/*.yaml):
                                                          # helm lint --strict + helm template | kubeconform
    python3 tools/deploy/charts.py package --out DIR      # helm package, version <Chart.version>+src<content hash>
    python3 tools/deploy/charts.py push --out DIR --registry <acr name>   # OCI push to <acr>.azurecr.io/helm

Packages are content-addressed (build metadata `+src<sha12>` of the chart files), so pushing is
idempotent and two different chart contents never share a version. The registry token comes from
`az acr login --expose-token` and is passed to helm on stdin (never printed).
Deployment roots that reference a chart path (e.g. `${path.module}/../../charts/<name>`) have the chart
directory as a fingerprint input (tools/changeset/fingerprint.py), so a chart change re-plans them.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parents[2]
CHARTS_DIR = "applications/charts"


def charts(repo: Path = REPO) -> list[Path]:
    base = repo / CHARTS_DIR
    return sorted(p.parent for p in base.glob("*/Chart.yaml")) if base.exists() else []


def content_hash(chart: Path) -> str:
    h = hashlib.sha256()
    for f in sorted(p for p in chart.rglob("*") if p.is_file()):
        h.update(f.relative_to(chart).as_posix().encode() + b"\0" + f.read_bytes() + b"\n")
    return h.hexdigest()[:12]


def package_version(chart: Path) -> str:
    meta = yaml.safe_load((chart / "Chart.yaml").read_text()) or {}
    base = str(meta.get("version", "0.0.0")).split("+", 1)[0]
    return f"{base}+src{content_hash(chart)}"


def run(cmd, **kw) -> subprocess.CompletedProcess:
    print("+ " + " ".join(str(c) for c in cmd), flush=True)
    return subprocess.run(cmd, **kw)


def cmd_list(args) -> int:
    for c in charts(Path(args.repo)):
        print(f"{c.relative_to(Path(args.repo)).as_posix()} {package_version(c)}")
    return 0


def cmd_lint(args) -> int:
    repo = Path(args.repo)
    found = charts(repo)
    if not found:
        print(f"no charts under {CHARTS_DIR}/")
        return 0
    if not shutil.which("helm"):
        print("ERROR: helm not installed (pipelines/scripts/install-tools.sh helm)", file=sys.stderr)
        return 1
    rc = 0
    kubeconform = shutil.which("kubeconform")
    for c in found:
        # value sets to validate: ci/values.yaml, values.ci.yaml and every examples/*.yaml; else chart defaults
        sets = [p for p in (c / "ci/values.yaml", c / "values.ci.yaml") if p.exists()] + sorted((c / "examples").glob("*.yaml"))
        for vals in sets or [None]:
            values = ["-f", str(vals)] if vals else []
            label = vals.name if vals else "defaults"
            print(f"== {c.name} [{label}]", flush=True)
            rc |= run(["helm", "lint", "--strict", str(c), *values]).returncode
            tpl = run(["helm", "template", "lint-render", str(c), *values], capture_output=True, text=True)
            if tpl.returncode != 0:
                print(tpl.stderr, file=sys.stderr)
                rc |= 1
                continue
            if kubeconform:
                kc = run(
                    [
                        kubeconform, "-strict", "-summary",
                        "-kubernetes-version", os.environ.get("KUBERNETES_VERSION", "1.36.0"),
                        "-schema-location", "default",
                        "-schema-location",
                        "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json",
                        "-skip", "Route",  # OpenShift Route has no public schema; asserted in tests/charts
                        *(["-cache", os.environ["KUBECONFORM_CACHE"]] if os.environ.get("KUBECONFORM_CACHE") else []),
                        "-",
                    ],
                    input=tpl.stdout, text=True,
                )
                rc |= kc.returncode
            else:
                print("note: kubeconform not installed; rendered manifests not schema-validated")
    return 1 if rc else 0


def cmd_package(args) -> int:
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    index = []
    for c in charts(Path(args.repo)):
        version = package_version(c)
        proc = run(["helm", "package", str(c), "--version", version, "--destination", str(out)])
        if proc.returncode != 0:
            return 1
        name = (yaml.safe_load((c / "Chart.yaml").read_text()) or {}).get("name", c.name)
        index.append({"chart": name, "path": c.relative_to(Path(args.repo)).as_posix(), "version": version})
    (out / "charts.json").write_text(json.dumps(index, indent=2) + "\n")
    print(json.dumps(index, indent=2))
    return 0


def cmd_push(args) -> int:
    out = Path(args.out)
    pkgs = sorted(out.glob("*.tgz"))
    if not pkgs:
        print("nothing to push")
        return 0
    host = f"{args.registry}.azurecr.io"
    tok = subprocess.run(["az", "acr", "login", "--name", args.registry, "--expose-token", "--query", "accessToken",
                          "-o", "tsv", "--only-show-errors"], capture_output=True, text=True)
    if tok.returncode != 0 or not tok.stdout.strip():
        print("ERROR: could not obtain an ACR token", file=sys.stderr)
        return 1
    login = subprocess.run(["helm", "registry", "login", host, "--username", "00000000-0000-0000-0000-000000000000",
                            "--password-stdin"], input=tok.stdout.strip(), text=True, capture_output=True)
    if login.returncode != 0:
        print(f"ERROR: helm registry login failed: {login.stderr.strip()[:300]}", file=sys.stderr)
        return 1
    rc = 0
    for p in pkgs:
        rc |= run(["helm", "push", str(p), f"oci://{host}/helm"]).returncode
    return 1 if rc else 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=str(REPO))
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list").set_defaults(func=cmd_list)
    sub.add_parser("lint").set_defaults(func=cmd_lint)
    p = sub.add_parser("package")
    p.add_argument("--out", required=True)
    p.set_defaults(func=cmd_package)
    u = sub.add_parser("push")
    u.add_argument("--out", required=True)
    u.add_argument("--registry", required=True)
    u.set_defaults(func=cmd_push)
    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
