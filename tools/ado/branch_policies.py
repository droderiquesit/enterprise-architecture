#!/usr/bin/env python3
"""Azure Repos branch policies as code (plan / apply, idempotent), generated from environments/branching.yaml and
the registry ownership map.

    python3 tools/ado/branch_policies.py desired [--json]                         # offline: what we want
    python3 tools/ado/branch_policies.py plan  --org https://dev.azure.com/<org> --project <p> --repository <name>
    python3 tools/ado/branch_policies.py apply --org ... --project ... --repository ...   [--prune]

Auth: $SYSTEM_ACCESSTOKEN (pipeline, Build Service needs "Edit policies") or $ADO_PAT (Basic; fetch it from Delinea DSV:
`tools/secrets/fetch.py exec --env dev --map ADO_PAT=ado-policy-admin-pat -- python3 tools/ado/branch_policies.py apply ...`).
Nothing is printed from the credential.

Policies on the trunk (and release/* prefix), policy type ids from the Policy Configurations REST API (7.1):
  Minimum number of reviewers  fa4e907d-c16b-4a4c-9dfa-4906e5d171dd  2, reset on push, creator vote does not count
  Work item linking            40e92b44-2fe1-4dd6-b3d8-74a9c21d0c6e  required
  Comment requirements         resolved by display name from _apis/policy/types (required)
  Require a merge strategy     fa4e907d-c16b-4a4c-9dfa-4916e5d171ab  squash only
  Build (validation)           0609b952-1397-4640-95ec-e00a01b2c241  BOTH pipelines, queueOnSourceUpdateOnly: true +
                               validDuration: 0 = "expire immediately when main is updated": every PR is re-validated
                               against the newest main before it can complete (the Azure Repos substitute for a merge
                               queue; auto-complete re-queues expired builds)
  Status (required PR status)  resolved by display name "Status"; `policies.required_statuses` (eh-review/policy =
                               the automated PR reviewer's verdict), reset on every push, applies by default
  Required reviewers           fd2167ab-b0be-447a-8ec8-39368250530e  one per owner group, path filtered by the
                               component paths (same map as .github/CODEOWNERS); group ids from `identities` in
                               environments/branching.yaml or the Identities API
Direct pushes to main are blocked by any required policy (only "Bypass policies when pushing" could push - keep it
unassigned). Branch NAME patterns are not a branch policy in Azure Repos: `plan` prints the Git-permission commands
(deny Create branch at the repository root, allow it under feature/ fix/ chore/ docs/ and, for release managers,
release/) for an administrator; they are not applied automatically.
Managed policies are recognised by the `[lab-policy:<key>]` marker in their display name / message; `--prune` deletes
managed policies that are no longer desired. Unmanaged policies are never touched.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Callable, Dict, List, Optional

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.ado.owners import REPO, branching_doc, ownership  # noqa: E402
from tools.changeset.registry import load_registry  # noqa: E402
from tools.changeset.trees import WorkTree  # noqa: E402

API = "7.1"
TYPES = {
    "min-reviewers": "fa4e907d-c16b-4a4c-9dfa-4906e5d171dd",
    "work-item": "40e92b44-2fe1-4dd6-b3d8-74a9c21d0c6e",
    "merge-strategy": "fa4e907d-c16b-4a4c-9dfa-4916e5d171ab",
    "build": "0609b952-1397-4640-95ec-e00a01b2c241",
    "required-reviewers": "fd2167ab-b0be-447a-8ec8-39368250530e",
    "comments": None,  # "Comment requirements": resolved from _apis/policy/types at plan time
    "status": None,    # "Status" (required PR status from an external service): resolved from _apis/policy/types
}
TYPE_NAMES = {"comments": "comment requirements", "status": "status"}
MARK = "[lab-policy:{}]"
SHORT_LIVED_ALLOWED = ("feature", "fix", "chore", "docs")


def _scope(repo_id: Optional[str], ref: str, kind: str) -> List[dict]:
    return [{"repositoryId": repo_id, "refName": ref, "matchKind": kind}]


def desired(repo: Path = REPO, repo_id: Optional[str] = None, definitions: Optional[Dict[str, int]] = None,
            identities: Optional[Dict[str, str]] = None) -> List[dict]:
    doc = branching_doc(repo)
    pol = doc.get("policies") or {}
    trunk = f"refs/heads/{doc.get('trunk', 'main')}"
    release = "refs/heads/" + str((doc.get("release") or {}).get("pattern", "release/*")).rstrip("*")
    definitions = definitions or {}
    identities = {**(doc.get("identities") or {}), **(identities or {})}
    out: List[dict] = []

    def add(key, type_key, settings, blocking=True, ref=trunk, kind="exact"):
        settings = dict(settings, scope=_scope(repo_id, ref, kind))
        out.append({"key": key, "type": type_key, "isEnabled": True, "isBlocking": blocking, "settings": settings})

    for ref, kind, sfx, n in ((trunk, "exact", "", pol.get("minimum_reviewers", 2)),
                              (release, "prefix", "-release", pol.get("release_minimum_reviewers", 2))):
        add(f"min-reviewers{sfx}", "min-reviewers", {"minimumApproverCount": n, "creatorVoteCounts": bool(pol.get("creator_vote_counts", False)),
                                                     "allowDownvotes": False, "resetOnSourcePush": bool(pol.get("reset_on_push", True)),
                                                     "blockLastPusherVote": True}, ref=ref, kind=kind)
        for b in pol.get("build_validation") or []:
            name = b["pipeline"]
            add(f"build-{name}{sfx}", "build", {
                "buildDefinitionId": b.get("definition_id") or definitions.get(name),
                "displayName": f"{name} PR validation {MARK.format(f'build-{name}{sfx}')}",
                "queueOnSourceUpdateOnly": True, "manualQueueOnly": False, "validDuration": 0}, ref=ref, kind=kind)
        if pol.get("squash_only", True):
            add(f"merge-strategy{sfx}", "merge-strategy", {"useSquashMerge": True, "allowSquash": True, "allowNoFastForward": False,
                                                           "allowRebase": False, "allowRebaseMerge": False}, ref=ref, kind=kind)
        if pol.get("work_item_linking", True):
            add(f"work-item{sfx}", "work-item", {}, ref=ref, kind=kind)
        if pol.get("comment_resolution", True):
            add(f"comments{sfx}", "comments", {}, ref=ref, kind=kind)
        # required PR statuses posted by external services (the automated PR reviewer posts eh-review/policy);
        # apply by default (pending until posted), reset on every push, any poster unless author_id is set
        for st in pol.get("required_statuses") or []:
            sk = f"status-{st['genre']}-{st['name']}{sfx}"
            add(sk, "status", {"statusGenre": st["genre"], "statusName": st["name"], "authorId": st.get("author_id"),
                               "invalidateOnSourceUpdate": True, "policyApplicability": None,
                               "defaultDisplayName": f"{st['genre']}/{st['name']} {MARK.format(sk)}"},
                blocking=bool(st.get("blocking", True)), ref=ref, kind=kind)
    # path-filtered required reviewers per owner group (same map as CODEOWNERS)
    by_group: Dict[str, List[str]] = {}
    for path, owners, _src in ownership(load_registry(WorkTree(repo)), doc):
        pattern = path + "*" if path.endswith("/") else path
        for o in owners:
            by_group.setdefault(o, []).append(pattern)
    for group, patterns in sorted(by_group.items()):
        add(f"owners-{group}", "required-reviewers", {
            "requiredReviewerIds": [identities[group]] if identities.get(group) else [],
            "unresolvedGroup": None if identities.get(group) else group,
            "minimumApproverCount": 1, "creatorVoteCounts": False,
            "filenamePatterns": sorted(set(patterns)),
            "message": f"{group} owns these paths (catalog/components.yaml owners) {MARK.format(f'owners-{group}')}"})
    return out


def branch_acl_commands(org: str, project_id: str, repo_id: str, doc: dict) -> List[str]:
    """Git permission commands for branch-name patterns (Git Repositories namespace, CreateBranch = 16)."""
    def seg(name: str) -> str:
        return "".join(f"{b:02x}" for b in name.encode("utf-16-le"))
    ns = "2e9eb7ed-3c0a-47d4-87c1-0ffdd275fd87"
    root = f"repoV2/{project_id}/{repo_id}"
    allowed = [p.split("/")[0] for p in doc.get("short_lived") or []] or list(SHORT_LIVED_ALLOWED)
    cmds = [f"az devops security permission update --org {org} --namespace-id {ns} --subject '[{{project}}]\\Contributors' "
            f"--token '{root}' --deny-bit 16   # no branches outside the allowed folders"]
    for folder in allowed:
        cmds.append(f"az devops security permission update --org {org} --namespace-id {ns} --subject '[{{project}}]\\Contributors' "
                    f"--token '{root}/refs/heads/{seg(folder)}' --allow-bit 16   # {folder}/*")
    cmds.append(f"az devops security permission update --org {org} --namespace-id {ns} --subject '[{{project}}]\\Release Managers' "
                f"--token '{root}/refs/heads/{seg('release')}' --allow-bit 16   # release/* (release managers only)")
    return cmds


# --------------------------------------------------------------------- REST
Http = Callable[[str, str, Optional[dict]], Optional[dict]]


def make_http() -> Http:
    token, pat = os.environ.get("SYSTEM_ACCESSTOKEN"), os.environ.get("ADO_PAT")
    if token:
        auth = f"Bearer {token}"
    elif pat:
        auth = "Basic " + base64.b64encode(f":{pat}".encode()).decode()
    else:
        raise SystemExit("ERROR: set SYSTEM_ACCESSTOKEN (pipeline) or ADO_PAT (fetched from DSV)")

    def http(method: str, url: str, body: Optional[dict]) -> Optional[dict]:
        req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body is not None else None,
                                     headers={"Authorization": auth, "Content-Type": "application/json",
                                              "Accept": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                text = resp.read().decode()
                return json.loads(text) if text else {}
        except urllib.error.HTTPError as exc:
            raise RuntimeError(f"{method} {url.split('?')[0]}: HTTP {exc.code}") from None
    return http


def _managed_key(cfg: dict) -> Optional[str]:
    s = cfg.get("settings") or {}
    for text in (s.get("displayName") or "", s.get("message") or "", s.get("defaultDisplayName") or ""):
        if "[lab-policy:" in text:
            return text.split("[lab-policy:", 1)[1].split("]", 1)[0]
    return None


def _same(want: dict, have: dict) -> bool:
    ws = {k: v for k, v in want["settings"].items() if k != "unresolvedGroup"}
    hs = have.get("settings") or {}
    norm = lambda sc: [{"repositoryId": x.get("repositoryId"), "refName": x.get("refName"),  # noqa: E731
                        "matchKind": str(x.get("matchKind", "")).lower()} for x in sc or []]
    if norm(ws.get("scope")) != norm(hs.get("scope")):
        return False
    return all(hs.get(k) == v for k, v in ws.items() if k != "scope") and \
        have.get("isBlocking") == want["isBlocking"] and have.get("isEnabled") == want["isEnabled"]


def plan(want: List[dict], existing: List[dict], types: Dict[str, str]) -> List[dict]:
    """[{action: create|update|unchanged|delete|blocked, key, ...}]"""
    by_key: Dict[str, dict] = {}
    for cfg in existing:
        if cfg.get("isDeleted"):
            continue
        k = _managed_key(cfg)
        if k is None:
            # unmarked policies of the trunk with the same singleton type are adopted (min reviewers, merge, ...)
            tid = (cfg.get("type") or {}).get("id")
            for w in want:
                if types.get(w["type"]) == tid and w["type"] in ("min-reviewers", "work-item", "merge-strategy", "comments") \
                        and _scope_key(w) == _scope_key(cfg) and w["key"] not in by_key:
                    k = w["key"]
                    break
        if k:
            by_key[k] = cfg
    actions = []
    for w in want:
        tid = types.get(w["type"])
        if not tid:
            actions.append({"action": "blocked", "key": w["key"], "reason": f"policy type '{w['type']}' not found in this organization"})
            continue
        if w["type"] == "build" and not w["settings"].get("buildDefinitionId"):
            actions.append({"action": "blocked", "key": w["key"], "reason": "build definition id unknown (pipeline not created yet?)"})
            continue
        if w["settings"].get("unresolvedGroup"):
            actions.append({"action": "blocked", "key": w["key"],
                            "reason": f"group '{w['settings']['unresolvedGroup']}' has no identity id (environments/branching.yaml identities)"})
            continue
        have = by_key.pop(w["key"], None)
        if have is None:
            actions.append({"action": "create", "key": w["key"], "want": w})
        elif _same(w, have):
            actions.append({"action": "unchanged", "key": w["key"], "id": have.get("id")})
        else:
            actions.append({"action": "update", "key": w["key"], "id": have.get("id"), "want": w})
    for k, cfg in sorted(by_key.items()):
        if _managed_key(cfg):
            actions.append({"action": "delete", "key": k, "id": cfg.get("id")})
    return actions


def _scope_key(item: dict) -> str:
    sc = (item.get("settings") or {}).get("scope") or [{}]
    return f"{sc[0].get('refName')}|{str(sc[0].get('matchKind', '')).lower()}"


def body_of(w: dict, types: Dict[str, str]) -> dict:
    settings = {k: v for k, v in w["settings"].items() if k != "unresolvedGroup"}
    return {"isEnabled": w["isEnabled"], "isBlocking": w["isBlocking"], "type": {"id": types[w["type"]]}, "settings": settings}


def resolve_types(http: Http, base: str) -> Dict[str, str]:
    types = {k: v for k, v in TYPES.items() if v}
    listed = http("GET", f"{base}/_apis/policy/types?api-version={API}", None) or {}
    for t in listed.get("value") or []:
        for key, name in TYPE_NAMES.items():
            if str(t.get("displayName", "")).lower() == name:
                types[key] = t["id"]
    return types


def run(op: str, org: str, project: str, repository: str, http: Http, prune: bool = False, repo: Path = REPO) -> List[dict]:
    base = f"{org.rstrip('/')}/{urllib.parse.quote(project)}"
    r = http("GET", f"{base}/_apis/git/repositories/{urllib.parse.quote(repository)}?api-version={API}", None) or {}
    repo_id = r.get("id")
    defs = {}
    for b in (branching_doc(repo).get("policies") or {}).get("build_validation") or []:
        found = http("GET", f"{base}/_apis/build/definitions?name={urllib.parse.quote(b['pipeline'])}&api-version={API}", None) or {}
        if found.get("value"):
            defs[b["pipeline"]] = found["value"][0]["id"]
    types = resolve_types(http, base)
    want = desired(repo, repo_id, defs)
    existing = (http("GET", f"{base}/_apis/policy/configurations?api-version={API}", None) or {}).get("value") or []
    existing = [c for c in existing if any(s.get("repositoryId") in (None, repo_id) for s in (c.get("settings") or {}).get("scope") or [{}])]
    actions = plan(want, existing, types)
    if op == "apply":
        for a in actions:
            if a["action"] == "create":
                http("POST", f"{base}/_apis/policy/configurations?api-version={API}", body_of(a["want"], types))
            elif a["action"] == "update":
                http("PUT", f"{base}/_apis/policy/configurations/{a['id']}?api-version={API}", body_of(a["want"], types))
            elif a["action"] == "delete" and prune:
                http("DELETE", f"{base}/_apis/policy/configurations/{a['id']}?api-version={API}", None)
    return actions


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("op", choices=("desired", "plan", "apply"))
    ap.add_argument("--org", default=os.environ.get("SYSTEM_COLLECTIONURI"))
    ap.add_argument("--project", default=os.environ.get("SYSTEM_TEAMPROJECT"))
    ap.add_argument("--repository", default=os.environ.get("BUILD_REPOSITORY_NAME", "enterprise-architecture"))
    ap.add_argument("--prune", action="store_true", help="apply: delete managed policies that are no longer desired")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    if args.op == "desired":
        want = desired()
        if args.json:
            print(json.dumps(want, indent=2))
        else:
            for w in want:
                extra = w["settings"].get("filenamePatterns") or ""
                print(f"{w['key']:<32} {w['type']:<20} {w['settings']['scope'][0]['refName']} {extra if extra else ''}")
        return 0
    if not (args.org and args.project):
        ap.error("--org and --project are required (or SYSTEM_COLLECTIONURI / SYSTEM_TEAMPROJECT)")
    actions = run(args.op, args.org, args.project, args.repository, make_http(), args.prune)
    blocked = 0
    for a in actions:
        if a["action"] != "unchanged":
            print(f"{a['action']:<9} {a['key']}" + (f"  ({a['reason']})" if a.get("reason") else ""))
        blocked += a["action"] == "blocked"
    print(f"{args.op}: " + ", ".join(f"{n} {k}" for k in ("create", "update", "delete", "unchanged", "blocked")
                                     if (n := sum(a["action"] == k for a in actions))))
    print("branch name patterns (administrator, not applied):")
    for c in branch_acl_commands(args.org, "<project-id>", "<repository-id>", branching_doc()):
        print("  " + c)
    return 1 if blocked else 0


if __name__ == "__main__":
    sys.exit(main())
