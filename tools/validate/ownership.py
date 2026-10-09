#!/usr/bin/env python3
"""Static checks of the ADR-0001 ownership rules over all Terraform files.

    python3 tools/validate/ownership.py [--json]

Rules
  OWN001  azurerm_monitor_diagnostic_setting only under observability/ (ADR §3 rule 4)
  OWN002  no terraform_remote_state anywhere (ADR §5)
  OWN003  datadog_* resources/data sources and the datadog provider only under observability/
  OWN004  observability/modules and observability/examples never reference paths outside observability/
  OWN005  no azurerm_redis_cache (Azure Cache for Redis is retired for new lab work; use azurerm_managed_redis)
  OWN006  one Azure resource => one root: the same (type, literal name) must not appear in two roots (heuristic;
          names computed by the naming module are not comparable statically and are skipped)
  OWN007  app resources and app settings only in applications/deployments/ (observability may own its
          telemetry-transport apps; foundation/deploy-agents may own agent container jobs/groups)
Suppress a finding with a comment on the line above the block: `# ownership:allow OWN00x <reason>`.
"""

from __future__ import annotations

import argparse
import json
import posixpath
import re
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.changeset.graph import components_owning  # noqa: E402
from tools.changeset.registry import load_registry  # noqa: E402
from tools.changeset.trees import WorkTree  # noqa: E402

BLOCK_RE = re.compile(r'^\s*(resource|data)\s+"([A-Za-z0-9_]+)"\s+"([A-Za-z0-9_-]+)"\s*\{', re.M)
PROVIDER_RE = re.compile(r'^\s*provider\s+"datadog"\s*\{', re.M)
DD_SOURCE_RE = re.compile(r'source\s*=\s*"(?:registry\.terraform\.io/)?datadog/datadog"', re.I)
PATH_LITERAL_RE = re.compile(r'"((?:\.\./|\./)[^"$]*)"')
NAME_RE = re.compile(r'^\s{2}name\s*=\s*"([^"$]+)"\s*$', re.M)
APP_TYPES = {
    "azurerm_linux_web_app", "azurerm_windows_web_app", "azurerm_linux_web_app_slot", "azurerm_windows_web_app_slot",
    "azurerm_linux_function_app", "azurerm_windows_function_app", "azurerm_linux_function_app_slot",
    "azurerm_windows_function_app_slot", "azurerm_function_app_flex_consumption", "azurerm_container_app",
    "azurerm_container_app_job", "azurerm_container_group", "azurerm_logic_app_standard",
    "azurerm_static_web_app_custom_domain", "kubernetes_deployment", "kubernetes_deployment_v1",
    "kubernetes_cron_job_v1", "kubernetes_job_v1",
}
APP_OWNER_PREFIXES = ("applications/deployments/", "observability/")
APP_EXCEPTIONS = {"foundation/deploy-agents/": {"azurerm_container_app_job", "azurerm_container_group"}}
APP_SETTINGS_RE = re.compile(r'^\s*app_settings\s*=', re.M)


def _block_body(text: str, start: int) -> str:
    depth, i = 1, start
    in_str = False
    while i < len(text) and depth:
        ch = text[i]
        if ch == '"' and text[i - 1] != "\\":
            in_str = not in_str
        elif not in_str:
            depth += {"{": 1, "}": -1}.get(ch, 0)
        i += 1
    return text[start: i - 1]


def _suppressed(text: str, pos: int, rule: str) -> bool:
    line_start = text.rfind("\n", 0, pos) + 1
    prev_start = text.rfind("\n", 0, max(0, line_start - 1)) + 1
    prev = text[prev_start:line_start]
    return f"ownership:allow {rule}" in prev or f"ownership:allow {rule}" in text[line_start:text.find("\n", pos)]


def scan(repo: Path) -> list[dict]:
    tree = WorkTree(repo)
    reg = load_registry(tree)
    findings: list[dict] = []
    literal_names: dict[tuple[str, str], set[str]] = defaultdict(set)

    def add(rule, path, msg):
        findings.append({"rule": rule, "path": path, "message": msg})

    for path in sorted(p for p in tree.files() if p.endswith(".tf")):
        text = tree.read_text(path) or ""
        in_obs = path.startswith("observability/")
        owner = components_owning(reg, path)
        root = owner[0].path if owner else None
        for m in BLOCK_RE.finditer(text):
            kind, typ, name = m.groups()
            pos = m.start()
            where = f"{kind} {typ}.{name}"
            if typ == "azurerm_monitor_diagnostic_setting" and kind == "resource" and not in_obs and not _suppressed(text, pos, "OWN001"):
                add("OWN001", path, f"{where}: diagnostic settings are owned by observability (obs-diagnostics)")
            if typ == "terraform_remote_state" and not _suppressed(text, pos, "OWN002"):
                add("OWN002", path, f"{where}: terraform_remote_state is forbidden; consume contracts")
            if typ.startswith("datadog_") and not in_obs and not _suppressed(text, pos, "OWN003"):
                add("OWN003", path, f"{where}: Datadog resources belong to observability/")
            if typ == "azurerm_redis_cache" and not _suppressed(text, pos, "OWN005"):
                add("OWN005", path, f"{where}: use azurerm_managed_redis (Azure Managed Redis)")
            if kind == "resource" and typ in APP_TYPES and not path.startswith(APP_OWNER_PREFIXES):
                allowed = any(path.startswith(pfx) and typ in types for pfx, types in APP_EXCEPTIONS.items())
                if not allowed and not _suppressed(text, pos, "OWN007"):
                    add("OWN007", path, f"{where}: app resources are owned by applications/deployments/")
            if kind == "resource" and (typ.startswith("azurerm_") or typ.startswith("azapi_")) and root and "/modules/" not in path:
                body = _block_body(text, m.end())
                nm = NAME_RE.search(body)
                if nm and not _suppressed(text, pos, "OWN006"):
                    literal_names[(typ, nm.group(1))].add(root)
        if not in_obs:
            for m in PROVIDER_RE.finditer(text):
                if not _suppressed(text, m.start(), "OWN003"):
                    add("OWN003", path, 'provider "datadog" configured outside observability/')
            if DD_SOURCE_RE.search(text):
                add("OWN003", path, "datadog provider required outside observability/")
            if not path.startswith(APP_OWNER_PREFIXES):
                for m in APP_SETTINGS_RE.finditer(text):
                    if not _suppressed(text, m.start(), "OWN007"):
                        add("OWN007", path, "app_settings outside applications/deployments/")
        if path.startswith(("observability/modules/", "observability/examples/")):
            base = posixpath.dirname(path)
            for m in PATH_LITERAL_RE.finditer(text):
                target = posixpath.normpath(posixpath.join(base, m.group(1)))
                if not target.startswith("observability/") and target != "observability":
                    add("OWN004", path, f"references '{m.group(1)}' outside observability/ (portable package)")
    for (typ, name), roots in sorted(literal_names.items()):
        if len(roots) > 1:
            add("OWN006", ",".join(sorted(roots)), f"{typ} named '{name}' is declared in several roots: {', '.join(sorted(roots))}")
    return findings


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=".")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    findings = scan(Path(args.repo).resolve())
    if args.json:
        print(json.dumps(findings, indent=2))
    else:
        for f in findings:
            print(f"{f['rule']} {f['path']}: {f['message']}")
        print(f"ownership: {len(findings)} finding(s)")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
