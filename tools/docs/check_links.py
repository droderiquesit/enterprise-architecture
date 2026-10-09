#!/usr/bin/env python3
"""Check that relative links (and #anchors) in Markdown files resolve.

    python3 tools/docs/check_links.py                    # every *.md in the repository
    python3 tools/docs/check_links.py README.md docs     # only these files / directories
    python3 tools/docs/check_links.py --no-anchors       # skip anchor checks

Checked: inline links and images `[text](target)` / `![alt](target)` whose target is not a URL scheme
(`http:`, `https:`, `mailto:` ...). The path part must exist relative to the file; when the target (or the
file itself for `#anchor`) is Markdown, the anchor must match a heading slug (GitHub algorithm: lower-case,
punctuation removed except `-` and `_`, spaces -> `-`, duplicates suffixed `-1`, `-2`) or an explicit
`<a id|name="...">`. Code spans and fenced code blocks are ignored.

Exit codes: 0 all links resolve, 1 broken links found, 2 usage error. Standard library only.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SKIP_DIRS = {".git", "node_modules", ".terraform", ".pytest_cache", ".artifacts", ".vendor", "bin", "obj",
             ".ruff_cache", "TestResults", "__pycache__", "build", "dist", ".venv"}
LINK_RE = re.compile(r"!?\[(?:[^\[\]]|\[[^\]]*\])*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
FENCE_RE = re.compile(r"^(\s*)(```|~~~)")
HEADING_RE = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
ANCHOR_TAG_RE = re.compile(r"<a\s+(?:id|name)=\"([^\"]+)\"", re.I)


def md_files(targets: list[str]) -> list[Path]:
    out: list[Path] = []
    roots = [REPO / t for t in targets] if targets else [REPO]
    for root in roots:
        if root.is_file():
            out.append(root)
            continue
        for p in root.rglob("*.md"):
            if not any(part in SKIP_DIRS for part in p.relative_to(REPO).parts):
                out.append(p)
    return sorted(set(out))


def strip_code(text: str) -> list[str]:
    lines, in_fence = [], False
    for line in text.splitlines():
        if FENCE_RE.match(line):
            in_fence = not in_fence
            lines.append("")
            continue
        lines.append("" if in_fence else re.sub(r"`[^`]*`", "", line))
    return lines


def slugify(heading: str) -> str:
    h = re.sub(r"<[^>]+>", "", heading)                 # html tags
    h = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", h)       # links -> text
    h = h.replace("`", "").strip().lower()
    h = re.sub(r"[^\w\- ]", "", h)                       # keep word chars, hyphen, space
    return h.replace(" ", "-")


_anchor_cache: dict[Path, set[str]] = {}


def anchors(path: Path) -> set[str]:
    if path not in _anchor_cache:
        seen: dict[str, int] = {}
        result: set[str] = set()
        in_fence = False
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            if FENCE_RE.match(line):
                in_fence = not in_fence
                continue
            if in_fence:
                continue
            m = HEADING_RE.match(line)
            if m:
                base = slugify(m.group(2))
                n = seen.get(base, 0)
                result.add(base if n == 0 else f"{base}-{n}")
                seen[base] = n + 1
            result.update(ANCHOR_TAG_RE.findall(line))
        _anchor_cache[path] = result
    return _anchor_cache[path]


def check(files: list[Path], check_anchors: bool) -> list[str]:
    broken = []
    for f in files:
        for lineno, line in enumerate(strip_code(f.read_text(encoding="utf-8", errors="replace")), 1):
            for target in LINK_RE.findall(line):
                if re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", target):
                    continue
                path_part, _, anchor = target.partition("#")
                dest = f if not path_part else (f.parent / path_part).resolve()
                rel = f.relative_to(REPO)
                if not dest.exists():
                    broken.append(f"{rel}:{lineno}: missing target '{target}'")
                    continue
                if check_anchors and anchor and dest.is_file() and dest.suffix == ".md":
                    if anchor not in anchors(dest):
                        broken.append(f"{rel}:{lineno}: missing anchor '#{anchor}' in {dest.relative_to(REPO)}")
    return broken


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="*", help="files or directories relative to the repository root (default: all)")
    ap.add_argument("--no-anchors", action="store_true")
    args = ap.parse_args(argv)
    for p in args.paths:
        if not (REPO / p).exists():
            print(f"no such path: {p}", file=sys.stderr)
            return 2
    files = md_files(args.paths)
    broken = check(files, not args.no_anchors)
    for b in broken:
        print(b)
    print(f"checked {len(files)} Markdown files: {len(broken)} broken link(s)")
    return 1 if broken else 0


if __name__ == "__main__":
    sys.exit(main())
