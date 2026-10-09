#!/usr/bin/env python3
"""Generate .github/CODEOWNERS from the registry ownership (tools/ado/owners.py).

    python3 tools/ado/codeowners.py            # write .github/CODEOWNERS
    python3 tools/ado/codeowners.py --check    # exit 1 when the checked-in file is stale (Validate stage, pre-commit)

The same ownership map drives the Azure Repos path-filtered required-reviewer policies
(tools/ado/branch_policies.py), so CODEOWNERS (GitHub mirror / IDE tooling) and the enforced policies never diverge.
Output is deterministic and sorted (least specific first: last match wins), so concurrent registry edits rarely
conflict and a conflict is resolved by regenerating, never by hand-merging.
"""

from __future__ import annotations

import argparse
import difflib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.ado.owners import REPO, branching_doc, ownership  # noqa: E402
from tools.changeset.registry import load_registry  # noqa: E402
from tools.changeset.trees import WorkTree  # noqa: E402

TARGET = ".github/CODEOWNERS"


def render(repo: Path = REPO) -> str:
    doc = branching_doc(repo)
    org = doc.get("github_org", "lab")
    reg = load_registry(WorkTree(repo))
    lines = ["# GENERATED FILE - DO NOT EDIT. Source: catalog/components.yaml `owners` + environments/branching.yaml",
             "# (owners_by_layer, global_owners). Regenerate: python3 tools/ado/codeowners.py",
             "# Enforced in Azure Repos by tools/ado/branch_policies.py (path-filtered required reviewers).", ""]
    width = 0
    rows = ownership(reg, doc)
    for path, _o, _s in rows:
        width = max(width, len(path))
    for path, owners, src in rows:
        lines.append(f"{path.ljust(width)}  {' '.join(f'@{org}/{o}' for o in owners)}  # {src}")
    return "\n".join(lines) + "\n"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=str(REPO))
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args(argv)
    repo = Path(args.repo)
    text = render(repo)
    target = repo / TARGET
    if args.check:
        current = target.read_text() if target.exists() else ""
        if current != text:
            print("\n".join(list(difflib.unified_diff(current.splitlines(), text.splitlines(), "checked-in", "generated",
                                                      lineterm="", n=0))[:30]))
            print(f"ERROR: {TARGET} is stale; run: python3 tools/ado/codeowners.py", file=sys.stderr)
            return 1
        print(f"{TARGET} is up to date")
        return 0
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text)
    print(f"wrote {TARGET} ({text.count(chr(10)) - 4} entries)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
