#!/usr/bin/env python3
"""Extract release notes for one version from a Keep-a-Changelog file and check the release version.

    python3 tools/report/release_notes.py --changelog observability/CHANGELOG.md --version 1.2.0 --out notes.md
    python3 tools/report/release_notes.py --tag refs/tags/observability-v1.2.0 --version-file observability/VERSION

--tag mode prints the version and fails unless the tag (observability-v<semver>) equals the VERSION file.
Notes mode fails when the changelog has no `## [<version>]` section (an unreleased package must not ship).
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

SEMVER = r"\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?"


def tag_version(tag: str, prefix: str = "observability-v") -> str:
    tag = tag.removeprefix("refs/tags/")
    m = re.fullmatch(re.escape(prefix) + f"({SEMVER})", tag)
    if not m:
        raise ValueError(f"tag '{tag}' is not {prefix}<semver>")
    return m.group(1)


def notes(changelog: str, version: str) -> str:
    lines = changelog.splitlines()
    start = None
    for i, line in enumerate(lines):
        if re.match(rf"^## \[{re.escape(version)}\]", line):
            start = i
            break
    if start is None:
        raise ValueError(f"CHANGELOG has no section '## [{version}]'")
    end = next((j for j in range(start + 1, len(lines)) if lines[j].startswith("## [")), len(lines))
    return "\n".join(lines[start:end]).strip() + "\n"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--changelog")
    ap.add_argument("--version")
    ap.add_argument("--out")
    ap.add_argument("--tag")
    ap.add_argument("--version-file")
    args = ap.parse_args(argv)
    try:
        if args.tag:
            v = tag_version(args.tag)
            if args.version_file:
                file_v = Path(args.version_file).read_text().strip()
                if file_v != v:
                    raise ValueError(f"tag version {v} != {args.version_file} {file_v}")
            print(v)
            return 0
        text = notes(Path(args.changelog).read_text(), args.version)
    except (ValueError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    if args.out:
        Path(args.out).write_text(text)
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
