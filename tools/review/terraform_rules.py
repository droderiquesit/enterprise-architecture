"""Terraform risk signals computed from base/head TEXT (no terraform binary, nothing executed).

A lightweight block mapper attributes every line to its top-level block (`resource "<type>" "<name>"`, `data`,
`module`, `moved`, `removed`, ...) and the nested-block path inside it, so added/removed lines can be judged by the
resource type and attribute they touch.
"""

from __future__ import annotations

import fnmatch
import re
from typing import Dict, List, Optional, Tuple

from .diffing import LineDiff
from .model import FileChange, Finding

BLOCK_RE = re.compile(r'^\s*(resource|data|module|moved|removed|import|output|variable|locals|provider|terraform)\b\s*(?:"([^"]+)")?\s*(?:"([^"]+)")?\s*\{')
NESTED_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\{")
ATTR_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+?)\s*$")


class Block:
    def __init__(self, kind: str, a: Optional[str], b: Optional[str], start: int):
        self.kind, self.type, self.name, self.start = kind, a, b, start

    @property
    def address(self) -> str:
        if self.kind == "resource":
            return f"{self.type}.{self.name}"
        if self.kind == "data":
            return f"data.{self.type}.{self.name}"
        if self.kind == "module":
            return f"module.{self.type}"
        return self.kind


def block_map(text: Optional[str]) -> Tuple[Dict[int, Tuple[Block, Tuple[str, ...]]], Dict[str, Block]]:
    """line number -> (top-level block, nested path) and address -> block."""
    lines: Dict[int, Tuple[Block, Tuple[str, ...]]] = {}
    blocks: Dict[str, Block] = {}
    if not text:
        return lines, blocks
    depth = 0
    current: Optional[Block] = None
    stack: List[Tuple[str, int]] = []
    for i, raw in enumerate(text.splitlines(), start=1):
        line = re.sub(r"#.*$|//.*$", "", raw) if '"' not in raw else raw
        if depth == 0:
            m = BLOCK_RE.match(line)
            if m:
                current = Block(m.group(1), m.group(2), m.group(3), i)
                blocks.setdefault(current.address if current.kind in ("resource", "data", "module") else f"{current.kind}@{i}", current)
                stack = []
        elif current is not None:
            m = NESTED_RE.match(line)
            if m:
                stack.append((m.group(1), depth + 1))
        if current is not None:
            lines[i] = (current, tuple(n for n, _ in stack))
        opens, closes = line.count("{"), line.count("}")
        depth += opens - closes
        while stack and depth < stack[-1][1]:
            stack.pop()
        if depth <= 0:
            depth = 0
            current = None
            stack = []
    return lines, blocks


EXPOSURE = [  # (attribute regex on the line, value predicate, rule, severity, message)
    (r"public_network_access_enabled", lambda v: v.startswith("true"), "public-network-access", "high",
     "public_network_access_enabled set to true (ADR-0001 section 8: private by default)."),
    (r"public_network_access", lambda v: '"enabled"' in v.lower(), "public-network-access", "high",
     "public_network_access set to Enabled (ADR-0001 section 8: private by default)."),
    (r"shared_access_key_enabled", lambda v: v.startswith("true"), "local-auth", "high", "Storage shared keys enabled (Entra ID only by default)."),
    (r"local_auth(?:entication)?_enabled", lambda v: v.startswith("true"), "local-auth", "high", "Local (key) authentication enabled."),
    (r"local_authentication_disabled", lambda v: v.startswith("false"), "local-auth", "high", "Local (key) authentication enabled."),
    (r"admin_enabled", lambda v: v.startswith("true"), "local-auth", "high", "Registry admin user enabled."),
    (r"anonymous_pull_enabled", lambda v: v.startswith("true"), "public-network-access", "high", "Anonymous registry pull enabled."),
    (r"allow_nested_items_to_be_public", lambda v: v.startswith("true"), "public-network-access", "high", "Public blob access allowed."),
    (r"https_only", lambda v: v.startswith("false"), "transport-security", "high", "HTTPS-only disabled."),
    (r"min(?:imum)?_tls_version", lambda v: bool(re.search(r"1[._]0|1[._]1", v)), "transport-security", "high", "Minimum TLS version below 1.2."),
    (r"ip_restriction_default_action", lambda v: '"allow"' in v.lower(), "network-exposure", "high", "IP restriction default action Allow."),
    (r"source_address_prefix(?:es)?", lambda v: any(x in v for x in ('"*"', '"Internet"', "0.0.0.0/0", '"Any"')), "network-exposure", "high",
     "Network rule allows any/Internet source."),
    (r"default_action", lambda v: '"allow"' in v.lower(), "network-exposure", "medium", "Network rules default action Allow."),
]


def _attr(line: str) -> Optional[Tuple[str, str]]:
    m = ATTR_RE.match(line)
    return (m.group(1), m.group(2)) if m else None


def _sensitive(rtype: Optional[str], patterns: List[str]) -> bool:
    return bool(rtype) and any(fnmatch.fnmatchcase(rtype, p) for p in patterns)


def scan(ch: FileChange, d: LineDiff, cfg: dict) -> List[Finding]:
    if not ch.path.endswith((".tf", ".tf.json")):
        return []
    sens_types = cfg.get("sensitive_resource_types", [])
    sec_attrs = set(cfg.get("security_attributes", []))
    head_lines, head_blocks = block_map(ch.head_text)
    base_lines, base_blocks = block_map(ch.base_text)
    out: List[Finding] = []
    p = ch.path

    def add(rule, sev, msg, line, evidence, suggestion=None, kind="risk"):
        out.append(Finding(rule=f"terraform.{rule}", severity=sev, kind=kind, category="terraform", message=msg, file=p,
                           line=line, suggestion=suggestion, evidence=evidence))

    # 1. sensitive resource types touched (added, removed or modified lines inside them)
    touched: Dict[str, int] = {}
    for ln, _ in d.added:
        b = head_lines.get(ln)
        if b and b[0].kind == "resource" and _sensitive(b[0].type, sens_types):
            touched.setdefault(b[0].address, ln)
    for ln, _ in d.removed:
        b = base_lines.get(ln)
        if b and b[0].kind == "resource" and _sensitive(b[0].type, sens_types):
            touched.setdefault(b[0].address, head_blocks[b[0].address].start if b[0].address in head_blocks else 0)
    for addr, ln in sorted(touched.items()):
        add("sensitive-resource", "high", f"Security-sensitive resource `{addr}` changed (RBAC / identity / network perimeter).", ln or None,
            f"sensitive:{addr}", "A human owner of the affected layer must review this change (branch policy required reviewers).")

    # 2. destroy-capable: resource blocks removed (or renamed without a `moved` block), explicit `removed` blocks
    moved_text = ch.head_text or ""
    for addr, blk in base_blocks.items():
        if blk.kind != "resource" or addr in head_blocks:
            continue
        if re.search(r"from\s*=\s*" + re.escape(addr) + r"\b", moved_text):
            continue
        add("resource-removed", "high", f"Resource `{addr}` is removed: the apply will DESTROY it (no `moved` block).", None,
            f"removed:{addr}", "Add a `moved {}` block for renames; destroying stateful resources needs an explicit retirement.")
    for ln, line in d.added:
        if re.match(r"^\s*removed\s*\{", line):
            add("removed-block", "high", "`removed` block added (resource leaves state / may be destroyed).", ln, f"removed-block:{line.strip()}")
        if "terraform_remote_state" in line:
            add("remote-state", "high", "terraform_remote_state is forbidden (ADR-0001 section 5: consume contracts).", ln,
                "remote-state", "Consume the upstream contract variable instead.", kind="violation")

    # 3. attribute flips that widen exposure / enable local auth
    for ln, line in d.added:
        kv = _attr(line)
        if not kv:
            continue
        key, val = kv
        for rx, pred, rule, sev, msg in EXPOSURE:
            if re.fullmatch(rx, key) and pred(val.strip().lower() if rule != "network-exposure" else val):
                blk = head_lines.get(ln)
                where = f" in `{blk[0].address}`" if blk else ""
                add(rule, sev, msg + where, ln, f"{rule}:{blk[0].address if blk else ''}:{key}",
                    "Keep the resource private / Entra-only, or document the exception in the component README and catalog.")
                break

    # 4. lifecycle protections
    for ln, line in d.removed:
        if re.match(r"^\s*prevent_destroy\s*=\s*true", line):
            blk = base_lines.get(ln)
            add("prevent-destroy-removed", "high", f"`prevent_destroy = true` removed{' from `' + blk[0].address + '`' if blk else ''}.", None,
                f"prevent-destroy:{blk[0].address if blk else ''}")
    for ln, line in d.added:
        if re.match(r"^\s*prevent_destroy\s*=\s*false", line):
            add("prevent-destroy-removed", "high", "`prevent_destroy` set to false.", ln, "prevent-destroy-false")
        m = re.match(r"^\s*ignore_changes\s*=\s*\[(.*)\]", line)
        if m:
            attrs = {a.strip() for a in m.group(1).split(",") if a.strip()}
            bad = sorted(a for a in attrs if a.split(".")[0].split("[")[0] in sec_attrs or a == "all")
            if bad:
                add("ignore-security-attrs", "high", f"lifecycle.ignore_changes hides drift on security attributes: {', '.join(bad)}.", ln,
                    f"ignore:{','.join(bad)}", "Do not ignore security-relevant attributes; fix the drift source instead.")
    return out
