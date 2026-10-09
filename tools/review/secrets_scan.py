"""Secret heuristics over ADDED lines (never prints or stores a matched value).

definite   private keys and well-known credential formats      -> critical, definite (vote reject)
heuristic  credential-looking assignments, high-entropy tokens -> high (wait for author / human)
`dsv://` references (ADR-0001 section 14), `${...}` / `[[...]]` / `<...>` placeholders and obvious examples are fine.
"""

from __future__ import annotations

import math
import re
from collections import Counter
from typing import Iterable, List, Tuple

from tools.changeset import globs

from .model import Finding

DEFINITE = [
    ("private-key", re.compile(r"-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED |PGP )?PRIVATE KEY(?: BLOCK)?-----")),
    ("azure-storage-key", re.compile(r"AccountKey=[A-Za-z0-9+/]{80,}={0,2}")),
    ("azure-sas-key", re.compile(r"SharedAccessKey=[A-Za-z0-9+/]{40,}={0,2}")),
    ("azure-sas-signature", re.compile(r"[?&]sig=[A-Za-z0-9%+/]{40,}")),
    ("anthropic-api-key", re.compile(r"sk-ant-[A-Za-z0-9_-]{20,}")),
    ("github-token", re.compile(r"\b(?:ghp|gho|ghs|ghr|github_pat)_[A-Za-z0-9_]{30,}")),
    ("aws-access-key", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    ("slack-token", re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}")),
    ("ado-pat-basic", re.compile(r"(?i)authorization:\s*basic\s+[A-Za-z0-9+/]{40,}={0,2}")),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}")),
]
ASSIGNMENT = re.compile(
    r"""(?ix)(?P<key>[a-z0-9_.-]*(?:password|passwd|pwd|secret|token|api[_-]?key|apikey|client[_-]?secret|access[_-]?key|connection[_-]?string)[a-z0-9_.-]*)
        ["']?\s*[:=]\s*["']?(?P<value>[^\s"'#,;]{8,})""")
TOKEN = re.compile(r"[A-Za-z0-9+/=_-]{20,}")
PLACEHOLDER = re.compile(r"^(?:\$\{.*\}|\[\[.*\]\]|<.*>|\{\{.*\}\}|%\(.*\)s|\$\(.*\)|dsv://.*|ENC\[.*\]|var\..*|local\..*|each\..*|module\..*|data\..*)$")
EXAMPLE_WORDS = ("example", "changeme", "placeholder", "dummy", "redacted", "xxxxxxxx", "your-", "fake", "sample", "test-fixture",
                 "not-a-secret", "localdev", "password123")
HEX = re.compile(r"^[0-9a-fA-F]+$")
UUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")


def shannon(s: str) -> float:
    if not s:
        return 0.0
    n = len(s)
    return -sum(c / n * math.log2(c / n) for c in Counter(s).values())


def _benign(value: str) -> bool:
    v = value.strip().strip("\"'")
    low = v.lower()
    if PLACEHOLDER.match(v) or any(w in low for w in EXAMPLE_WORDS):
        return True
    if UUID.match(v) or v.startswith(("sha256:", "sha512-", "sha1-", "/subscriptions/", "http://", "https://")):
        return True
    return v.lower() in ("true", "false", "null", "none") or v.isdigit()


def _masked(line: str, spans: Iterable[Tuple[int, int]], limit: int = 200) -> str:
    out, last = [], 0
    for a, b in sorted(spans):
        out.append(line[last:a])
        out.append("<redacted>")
        last = b
    out.append(line[last:])
    text = "".join(out)
    return text.strip()[:limit] if limit else text


def redact(text: str) -> str:
    """Replace anything secret-looking (definite patterns, credential assignments, high-entropy tokens)."""
    def line_redact(line: str) -> str:
        spans = [m.span() for _, rx in DEFINITE for m in rx.finditer(line)]
        for m in ASSIGNMENT.finditer(line):
            if not _benign(m.group("value")):
                spans.append(m.span("value"))
        for m in TOKEN.finditer(line):
            tok = m.group(0)
            if len(tok) >= 32 and not _benign(tok) and shannon(tok) > (3.0 if HEX.match(tok) else 4.0):
                spans.append(m.span())
        if not spans:
            return line
        merged: List[Tuple[int, int]] = []
        for a, b in sorted(spans):
            if merged and a <= merged[-1][1]:
                merged[-1] = (merged[-1][0], max(b, merged[-1][1]))
            else:
                merged.append((a, b))
        return _masked(line, merged, limit=0)
    return "\n".join(line_redact(x) for x in text.splitlines())


def scan(path: str, added: List[Tuple[int, str]], cfg: dict) -> List[Finding]:
    if globs.match_any(cfg.get("skip_paths", []), path):
        return []
    fixture = globs.match_any(cfg.get("fixture_paths", []), path)
    min_len = int(cfg.get("entropy_min_length", 32))
    th_b64 = float(cfg.get("entropy_threshold_base64", 4.3))
    th_hex = float(cfg.get("entropy_threshold_hex", 3.2))
    out: List[Finding] = []
    for lineno, line in added:
        hit = False
        for name, rx in DEFINITE:
            m = rx.search(line)
            if m and not _benign(m.group(0)):
                hit = True
                out.append(Finding(
                    rule=f"secret.{name}", severity="high" if fixture else "critical", kind="violation", category="secret",
                    message=f"Committed credential ({name}) in an added line." + (" Test fixture path: still blocks approval." if fixture else ""),
                    file=path, line=lineno, definite=not fixture,
                    suggestion="Remove the value from the change (and from history), rotate it, store it in Delinea DSV and "
                               "reference it as dsv://<prefix>/<env>/<name>#value (ADR-0001 section 14).",
                    evidence=f"{name}:{_masked(line, [m.span()])}"))
                break
        if hit:
            continue
        for m in ASSIGNMENT.finditer(line):
            value = m.group("value")
            if _benign(value) or len(value) < 12 or shannon(value) < 3.0:
                continue
            hit = True
            out.append(Finding(
                rule="secret.assignment", severity="high", kind="violation", category="secret",
                message=f"`{m.group('key')}` is assigned a literal value that looks like a credential.",
                file=path, line=lineno,
                suggestion="Use a dsv:// reference (resolved at runtime by hello_common / Hello.Common / dsv-fetch) instead of a literal.",
                evidence=f"assignment:{_masked(line, [m.span('value')])}"))
            break
        if hit:
            continue
        for m in TOKEN.finditer(line):
            tok = m.group(0)
            if len(tok) < min_len or _benign(tok):
                continue
            ent = shannon(tok)
            if (HEX.match(tok) and ent >= th_hex and len(tok) not in (40, 64)) or (not HEX.match(tok) and ent >= th_b64):
                out.append(Finding(
                    rule="secret.high-entropy", severity="medium", kind="violation", category="secret",
                    message=f"High-entropy string ({len(tok)} chars, entropy {ent:.2f}) in an added line - possible secret.",
                    file=path, line=lineno,
                    suggestion="If this is a credential, move it to DSV; if it is a hash/identifier, mention it in the PR description.",
                    evidence=f"entropy:{_masked(line, [m.span()])}"))
                break
    return out
