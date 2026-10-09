"""CLI: review a local git range with the same engine the Azure Function uses.

    python3 -m tools.review --base origin/main --head HEAD [--build-status green] [--author me@example.com]
                            [--target main] [--json out.json] [--markdown out.md] [--ai] [--policy-from base|head|FILE]

The policy and component registry are read from --base (the trusted side) unless --policy-from says otherwise.
Exit code: 0 always for a completed review (the decision is in the output), 2 on usage/policy errors;
--strict returns 1 for wait-for-author / reject.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from tools.changeset import REPO_ROOT, ensure_repo_on_path

ensure_repo_on_path()

from tools.changeset.gitdiff import merge_base, resolve_target_ref, rev_parse  # noqa: E402
from tools.changeset.trees import GitTree, WorkTree  # noqa: E402

from . import render  # noqa: E402
from .analysis import TrustedBase  # noqa: E402
from .engine import ai_from_policy, review  # noqa: E402
from .local import git_changes  # noqa: E402
from .model import BuildStatus, ReviewContext  # noqa: E402
from .policy import POLICY_PATH, PolicyError, load_file, parse  # noqa: E402


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="python3 -m tools.review", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=str(REPO_ROOT))
    ap.add_argument("--base", help="base ref (default: merge-base of --target and --head)")
    ap.add_argument("--head", default="HEAD", help="head ref; 'WORKTREE' reviews uncommitted changes")
    ap.add_argument("--target", default="main", help="PR target branch (decision: release/* is never approved)")
    ap.add_argument("--author", default="", help="PR author (unique name) for owner / bot checks")
    ap.add_argument("--build-status", default="unknown", choices=["green", "failed", "pending", "unknown"],
                    help="PR build validation state (in Azure DevOps the reviewer reads it from policy evaluations)")
    ap.add_argument("--policy-from", default="base", help="base | head | <path to policy.yaml>")
    ap.add_argument("--ai", action="store_true", help="run the optional AI review if the policy enables it and the key env var is set")
    ap.add_argument("--json", help="write the full review result JSON here")
    ap.add_argument("--markdown", help="write the PR summary markdown here")
    ap.add_argument("--strict", action="store_true")
    args = ap.parse_args(argv)

    repo = Path(args.repo).resolve()
    head = None if args.head == "WORKTREE" else args.head
    try:
        base = args.base or merge_base(repo, resolve_target_ref(repo, args.target), head or "HEAD")
        base_sha = rev_parse(repo, base)
        trusted_tree = GitTree(repo, base_sha)
        if args.policy_from == "base":
            text = trusted_tree.read_text(POLICY_PATH)
            if text is None:
                raise PolicyError(f"{POLICY_PATH} not found at base {base_sha[:12]}")
            policy = parse(text, f"{POLICY_PATH}@{base_sha[:12]}")
        elif args.policy_from == "head":
            tree = GitTree(repo, head) if head else WorkTree(repo)
            policy = parse(tree.read_text(POLICY_PATH) or "", f"{POLICY_PATH}@head")
        else:
            policy = load_file(Path(args.policy_from))
    except (PolicyError, RuntimeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    head_sha = rev_parse(repo, head) if head else "WORKTREE"
    changes = git_changes(repo, base_sha, head, int(policy["limits"]["max_file_bytes"]))
    ctx = ReviewContext(author=args.author, target_branch=args.target, build=BuildStatus(args.build_status),
                        head=head_sha, base=base_sha)
    result = review(changes, policy, TrustedBase(trusted_tree), ctx, ai_reviewer=ai_from_policy(policy) if args.ai else None)
    md = render.summary(result)
    if args.markdown:
        Path(args.markdown).write_text(md + "\n")
    if args.json:
        Path(args.json).write_text(json.dumps(result.to_dict(), indent=2, sort_keys=True) + "\n")
    print(md)
    if args.strict and result.decision.outcome in ("wait-for-author", "reject"):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
