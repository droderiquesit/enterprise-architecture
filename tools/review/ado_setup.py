#!/usr/bin/env python3
"""Azure DevOps wiring for eh-pr-reviewer - idempotent, dry-run by default (prints the exact REST requests).

    python3 -m tools.review.ado_setup plan  --org example-org --project-id <guid> --repository-id <guid> \
        --function-url https://<app>.azurewebsites.net/api/ado-webhook --reviewer-object-id <MI principal id> \
        [--reviewer-id <ADO identity id>] [--fragment tools/review/branch-policy-fragment.json]
    python3 -m tools.review.ado_setup apply ...  (needs ADO_TOKEN = Entra token of a Project Collection Administrator,
                                                 and WEBHOOK_SECRET = the DSV value, e.g. via tools/secrets/fetch.py exec)

What it manages
  1. service hook subscriptions (Web Hooks consumer `webHooks`/`httpRequest`, publisher `tfs`) for
     git.pullrequest.created, git.pullrequest.updated and ms.vss-code.git-pullrequest-comment-event (Copilot comments /
     thread resolution re-evaluate the PR; --no-comments to skip),
     filtered to the repository, HTTPS URL, HTTP Basic auth (password = webhook secret), resourceDetailsToSend=minimal,
     no messages. Matched by (eventType, url); existing ones are left alone unless --rotate (PUT with the new secret).
  2. the reviewer's managed identity as an organization user with Basic access (Service Principal Entitlements API),
     member of project Readers only;
  3. repository-scoped ACE: Read + Contribute to pull requests on this repository only (Security - Access Control
     Entries, namespace Git Repositories).
  4. writes the BRANCH POLICY FRAGMENT (required status eh-review/policy authorised for the bot identity, reset on
     push, apply by default; path-based required reviewers for `protected` policy classes) consumed by the
     pipeline builder's tools/ado/branch_policies.py. Branch policies are NOT applied here (single owner).
Nothing secret is printed: the webhook password is shown as <WEBHOOK_SECRET>.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

from tools.changeset import REPO_ROOT

from .policy import load_file

API = "7.1"
EVENTS = ("git.pullrequest.created", "git.pullrequest.updated")
COMMENT_EVENT = "ms.vss-code.git-pullrequest-comment-event"
GIT_REPOS_NAMESPACE = "2e9eb7ed-3c0a-47d4-87c1-0ffdd275fd87"  # Security namespace "Git Repositories"
GIT_READ, GIT_PR_CONTRIBUTE = 2, 16384  # bits: GenericRead, PullRequestContribute (verify via
#                                                                    GET _apis/securitynamespaces/<namespace>)
STATUS_POLICY_TYPE = "cbdc66da-9728-4af8-aada-9a5a32e4a226"
REQUIRED_REVIEWERS_TYPE = "fd2167ab-b0be-447a-8ec8-39368250530e"
FRAGMENT = REPO_ROOT / "tools/review/branch-policy-fragment.json"


def subscriptions(a, secret_placeholder: str = "<WEBHOOK_SECRET>") -> list[dict]:  # noqa: S107 - placeholder text, not a secret
    events = list(EVENTS) + ([] if a.no_comments else [COMMENT_EVENT])
    out = []
    for ev in events:
        out.append(
            {
                "publisherId": "tfs",
                "eventType": ev,
                "resourceVersion": "1.0",
                "consumerId": "webHooks",
                "consumerActionId": "httpRequest",
                "publisherInputs": {"projectId": a.project_id, "repository": a.repository_id},
                "consumerInputs": {
                    "url": a.function_url,
                    "basicAuthUsername": a.webhook_username,
                    "basicAuthPassword": secret_placeholder,
                    "resourceDetailsToSend": "minimal",
                    "messagesToSend": "none",
                    "detailedMessagesToSend": "none",
                },
            }
        )
    return out


def entitlement(a) -> dict:
    return {
        "accessLevel": {"accountLicenseType": "express", "licensingSource": "account"},  # express = Basic
        "servicePrincipal": {"origin": "aad", "originId": a.reviewer_object_id, "subjectKind": "servicePrincipal"},
        "projectEntitlements": [{"group": {"groupType": "projectReader"}, "projectRef": {"id": a.project_id}}],
    }


def ace(a, descriptor: str = "<identity descriptor from the entitlement response>") -> dict:
    return {
        "token": f"repoV2/{a.project_id}/{a.repository_id}",
        "merge": True,
        "accessControlEntries": [{"descriptor": descriptor, "allow": GIT_READ | GIT_PR_CONTRIBUTE, "deny": 0}],
    }


def _path_filter(glob: str) -> str:
    g = glob.rstrip("/")
    if g.endswith("/**"):
        g = g[:-3] + "/*"
    return "/" + g.replace("**/", "*").lstrip("/")


def fragment(a, policy) -> dict:
    protected = [c for c in policy.classes if c.get("protected")]
    scope = [
        {"repositoryId": a.repository_id, "refName": "refs/heads/main", "matchKind": "exact"},
        {"repositoryId": a.repository_id, "refName": "refs/heads/release/", "matchKind": "prefix"},
    ]
    return {
        "_comment": "Generated by tools/review/ado_setup.py. Consumed by tools/ado/branch_policies.py (pipeline builder). "
        "Policy configuration settings per Policy Configurations REST API 7.1; confirm type ids with GET _apis/policy/types.",
        "required_status": {
            "type": {"id": STATUS_POLICY_TYPE, "displayName": "Status"},
            "isEnabled": True,
            "isBlocking": True,
            "settings": {
                "statusGenre": policy["status"]["genre"],
                "statusName": policy["status"]["name"],
                "authorId": a.reviewer_id or "<eh-pr-reviewer ADO identity id>",
                "invalidateOnSourceUpdate": True,
                "policyApplicability": None,
                "defaultDisplayName": f"{policy['status']['genre']}/{policy['status']['name']} (automated review)",
                "scope": scope,
            },
        },
        "required_reviewers_protected_paths": [
            {
                "class": c["name"],
                "type": {"id": REQUIRED_REVIEWERS_TYPE, "displayName": "Required reviewers"},
                "isEnabled": True,
                "isBlocking": True,
                "settings": {
                    "requiredReviewerIds": ["<owner group id for " + c["name"] + ">"],
                    "minimumApproverCount": 1,
                    "creatorVoteCounts": False,
                    "filenamePatterns": sorted({_path_filter(g) for g in c.get("globs", [])}),
                    "message": f"[eh-review] {c['name']}: {c.get('description', '')}"[:200],
                    "scope": scope,
                },
            }
            for c in protected
        ],
        "minimum_reviewers_note": "With the required status above, `Minimum number of reviewers = 1` (reset on push, creator "
        "vote does not count) lets the bot alone approve allowlisted changes; every other change keeps the "
        "status pending until a human approves. Keeping minimum = 2 means a human always approves (the "
        "bot's vote is then one of the two).",
        "copilot_code_review": {
            "manual": True,
            "note": "GitHub Copilot code review for Azure Repos (preview) has no documented REST API: enable it in the UI "
            "(organization, project and repository toggles) and add the branch policy 'Automatically request Copilot code "
            "review' on refs/heads/main and refs/heads/release/*. Copilot only comments (never approves or blocks).",
            "branches": ["refs/heads/main", "refs/heads/release/*"],
        },
        "comment_resolution": {
            "policy": "Comment requirements (Check for comment resolution)",
            "isBlocking": True,
            "note": "Required so Copilot (and human) comment threads must be resolved before completion.",
        },
        "bot_identity_note": "Do NOT add the reviewer identity to any required-reviewer group; give it no 'Bypass policies' permission.",
    }


class Client:
    def __init__(self, token: str):
        self.token = token

    def call(self, method: str, url: str, body: dict | None = None):
        req = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(), method=method)  # noqa: S310 - only https://dev.azure.com / vsaex URLs built from constants
        req.add_header("Authorization", f"Bearer {self.token}")
        req.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(req, timeout=30) as r:  # noqa: S310 - only https://dev.azure.com / vsaex URLs built from constants
            raw = r.read()
            return json.loads(raw) if raw else {}


def apply(a, policy) -> list[str]:
    token, secret = os.environ.get("ADO_TOKEN"), os.environ.get("WEBHOOK_SECRET")
    if not token or not secret:
        raise SystemExit("apply needs ADO_TOKEN and WEBHOOK_SECRET in the environment")
    c = Client(token)
    org = f"https://dev.azure.com/{a.org}"
    done = []
    existing = c.call("GET", f"{org}/_apis/hooks/subscriptions?publisherId=tfs&consumerId=webHooks&api-version={API}").get("value", [])
    for sub in subscriptions(a, secret):
        match = next((s for s in existing if s.get("eventType") == sub["eventType"] and (s.get("consumerInputs") or {}).get("url") == a.function_url), None)
        if match is None:
            c.call("POST", f"{org}/_apis/hooks/subscriptions?api-version={API}", sub)
            done.append(f"subscription created: {sub['eventType']}")
        elif a.rotate:
            c.call("PUT", f"{org}/_apis/hooks/subscriptions/{match['id']}?api-version={API}", dict(sub, id=match["id"]))
            done.append(f"subscription updated (secret rotated): {sub['eventType']}")
        else:
            done.append(f"subscription ok: {sub['eventType']}")
    try:
        ent = c.call("POST", f"https://vsaex.dev.azure.com/{a.org}/_apis/serviceprincipalentitlements?api-version={API}", entitlement(a))
        descriptor = ((ent.get("operationResult") or {}).get("result") or {}).get("servicePrincipal", {}).get("descriptor")
        done.append("entitlement ensured (Basic, project Readers)")
    except urllib.error.HTTPError as exc:
        raise SystemExit(f"service principal entitlement failed: HTTP {exc.code}") from None
    if descriptor:
        c.call("POST", f"{org}/_apis/accesscontrolentries/{GIT_REPOS_NAMESPACE}?api-version={API}", ace(a, descriptor))
        done.append("repository ACE ensured (Read + Contribute to pull requests)")
    else:
        done.append("ACE skipped: descriptor not returned - set it manually (see plan output)")
    return done


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="python3 -m tools.review.ado_setup", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("action", choices=["plan", "apply", "fragment"])
    ap.add_argument("--org", default="example-org")
    ap.add_argument("--project-id", default="<project id>")
    ap.add_argument("--repository-id", default="<repository id>")
    ap.add_argument("--function-url", default="https://<function app>.azurewebsites.net/api/ado-webhook")
    ap.add_argument("--webhook-username", default="eh-review")
    ap.add_argument("--reviewer-object-id", default="<pr-reviewer managed identity principal (object) id>")
    ap.add_argument("--reviewer-id", default=None, help="Azure DevOps identity id of the reviewer (status policy authorId)")
    ap.add_argument(
        "--no-comments",
        action="store_true",
        help="do not subscribe to PR comment events (they re-evaluate the PR when Copilot comments or threads are resolved)",
    )
    ap.add_argument("--rotate", action="store_true")
    ap.add_argument("--policy", default=str(REPO_ROOT / ".review/policy.yaml"))
    ap.add_argument("--fragment", default=str(FRAGMENT))
    a = ap.parse_args(argv)
    if not a.function_url.startswith("https://"):
        print("error: service hooks with Basic auth require an HTTPS URL", file=sys.stderr)
        return 2
    policy = load_file(Path(a.policy))
    frag = fragment(a, policy)
    if a.action in ("fragment", "plan"):
        Path(a.fragment).write_text(json.dumps(frag, indent=2) + "\n")
    if a.action == "plan":
        print(
            json.dumps(
                {
                    "service_hook_subscriptions": {
                        "POST": f"https://dev.azure.com/{a.org}/_apis/hooks/subscriptions?api-version={API}",
                        "bodies": subscriptions(a),
                    },
                    "service_principal_entitlement": {
                        "POST": f"https://vsaex.dev.azure.com/{a.org}/_apis/serviceprincipalentitlements?api-version={API}",
                        "body": entitlement(a),
                    },
                    "repository_ace": {
                        "POST": f"https://dev.azure.com/{a.org}/_apis/accesscontrolentries/{GIT_REPOS_NAMESPACE}?api-version={API}",
                        "body": ace(a),
                    },
                    "branch_policy_fragment": a.fragment,
                },
                indent=2,
            )
        )
    elif a.action == "apply":
        for line in apply(a, policy):
            print(line)
    else:
        print(f"wrote {a.fragment}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
