"""Branch policies as code, CODEOWNERS generation, branching model schema (offline: fake Azure DevOps REST)."""

from __future__ import annotations

import json
from pathlib import Path

import jsonschema
import yaml

from tools.ado import branch_policies as bp
from tools.ado import codeowners
from tools.ado.owners import branching_doc, owners_for, path_patterns
from tools.changeset.registry import load_registry
from tools.changeset.trees import WorkTree

ROOT = Path(__file__).resolve().parents[2]


def test_branching_model_matches_schema_and_pipelines():
    doc = yaml.safe_load((ROOT / "environments/branching.yaml").read_text())
    jsonschema.validate(doc, json.loads((ROOT / "environments/schema/branching.schema.json").read_text()))
    assert doc["trunk"] == "main"
    for entry in ("azure-pipelines.yml", "azure-pipelines.applications.yml"):
        e = yaml.safe_load((ROOT / entry).read_text())
        assert e["trigger"]["branches"]["include"] == [doc["trunk"]] and e["trigger"]["batch"] is True
    names = {b["pipeline"] for b in doc["policies"]["build_validation"]}
    assert names == {"lab-platform", "lab-applications"}


def test_codeowners_is_generated_and_current():
    assert codeowners.main(["--check"]) == 0
    text = (ROOT / ".github/CODEOWNERS").read_text()
    assert "/foundation/secrets/" in text and "@lab/security-team" in text
    lines = [line for line in text.splitlines() if line and not line.startswith("#")]
    depths = [line.split()[0].rstrip("/").count("/") for line in lines]
    assert depths == sorted(depths)                       # least specific first: last match wins
    assert codeowners.render(ROOT) == codeowners.render(ROOT)   # deterministic


def test_owner_defaults_by_layer():
    reg = load_registry(WorkTree(ROOT))
    doc = branching_doc(ROOT)
    assert owners_for(reg.get("platform-shared"), doc) == ["platform-team"]
    assert owners_for(reg.get("foundation-secrets"), doc) == ["platform-team", "security-team"]
    assert owners_for(reg.get("svc-bff"), doc) == ["app-team"]
    assert "/applications/shared/dotnet/" in path_patterns(reg.get("svc-bff"))


def test_desired_policies():
    want = {w["key"]: w for w in bp.desired(ROOT, "repo-1", {"lab-platform": 11, "lab-applications": 12},
                                            {"platform-team": "g-plat"})}
    mr = want["min-reviewers"]["settings"]
    # 1 on main by design: the required eh-review/policy status keeps non-low-risk PRs pending until a human approves
    assert mr["minimumApproverCount"] == 1 and mr["resetOnSourcePush"] and not mr["creatorVoteCounts"]
    assert mr["blockLastPusherVote"] is True
    assert want["min-reviewers-release"]["settings"]["minimumApproverCount"] == 2
    for name, did in (("lab-platform", 11), ("lab-applications", 12)):
        b = want[f"build-{name}"]["settings"]
        assert b["buildDefinitionId"] == did and b["validDuration"] == 0 and b["queueOnSourceUpdateOnly"] is True
        assert b["scope"] == [{"repositoryId": "repo-1", "refName": "refs/heads/main", "matchKind": "exact"}]
    assert want["merge-strategy"]["settings"]["allowSquash"] and not want["merge-strategy"]["settings"]["allowRebase"]
    assert want["build-lab-platform-release"]["settings"]["scope"][0] == {"repositoryId": "repo-1",
                                                                          "refName": "refs/heads/release/", "matchKind": "prefix"}
    owners = want["owners-platform-team"]["settings"]
    assert owners["requiredReviewerIds"] == ["g-plat"] and "/pipelines/*" in owners["filenamePatterns"]
    assert want["owners-security-team"]["settings"]["unresolvedGroup"] == "security-team"
    # automated PR reviewer verdict is a required status on main and release/*
    st = want["status-eh-review-policy"]
    assert st["type"] == "status" and st["isBlocking"]
    assert (st["settings"]["statusGenre"], st["settings"]["statusName"]) == ("eh-review", "policy")
    assert st["settings"]["invalidateOnSourceUpdate"] is True and "status-eh-review-policy-release" in want
    assert st["settings"]["unresolvedGroup"] == "eh-pr-reviewer"          # only the bot may post the status
    # protected path classes from the reviewer's fragment: human owner groups, never the bot
    prot = want["protected-review-governance"]["settings"]
    assert "/tools/review/*" in prot["filenamePatterns"] and prot["requiredReviewerIds"] == ["g-plat"]
    assert {k for k in want if k.startswith("protected-") and not k.endswith("-release")} == {
        "protected-identity-secrets", "protected-network-security", "protected-pipeline-governance",
        "protected-prod-config", "protected-review-governance"}
    assert want["protected-identity-secrets"]["settings"]["unresolvedGroup"] == "security-team"


class FakeAdo:
    def __init__(self, existing=None, copilot=True):
        self.copilot = copilot
        self.configs = {c["id"]: c for c in existing or []}
        self.calls = []
        self.next_id = 100

    def __call__(self, method, url, body):
        self.calls.append((method, url.split("?")[0], body))
        path = url.split("?")[0]
        if "/_apis/git/repositories/" in path:
            return {"id": "repo-1"}
        if "/_apis/build/definitions" in path:
            return {"value": [{"id": 11 if "platform" in url else 12}]}
        if path.endswith("/_apis/policy/types"):
            types = [{"id": "c6a1889d-b943-4856-b76f-9e46bb6b0df2", "displayName": "Comment requirements"},
                     {"id": "cbdc66da-9728-4af8-aada-9a5a32e4a226", "displayName": "Status"}]
            if self.copilot:      # discovered by name: the id here is a test value, never hard-coded in the tool
                types.append({"id": "11111111-2222-3333-4444-555555555555",
                              "displayName": "Automatically request Copilot code review"})
            return {"value": types}
        if path.endswith("/_apis/policy/configurations") and method == "GET":
            return {"value": list(self.configs.values())}
        if method == "POST":
            self.next_id += 1
            self.configs[self.next_id] = dict(body, id=self.next_id)
            return self.configs[self.next_id]
        if method == "PUT":
            cid = int(path.rsplit("/", 1)[1])
            self.configs[cid] = dict(body, id=cid)
            return self.configs[cid]
        if method == "DELETE":
            self.configs.pop(int(path.rsplit("/", 1)[1]), None)
            return {}
        raise AssertionError(url)


def test_apply_is_idempotent_and_never_touches_unmanaged(monkeypatch):
    doc = branching_doc(ROOT)
    doc["identities"] = {g: f"id-{g}" for g in ("app-team", "docs-team", "observability-team", "platform-team", "security-team",
                                                 "eh-pr-reviewer")}
    monkeypatch.setattr(bp, "branching_doc", lambda repo=ROOT: doc)
    unmanaged = {"id": 1, "isEnabled": True, "isBlocking": True, "type": {"id": "aaaa"},
                 "settings": {"scope": [{"repositoryId": "repo-1", "refName": "refs/heads/main", "matchKind": "exact"}]}}
    fake = FakeAdo([unmanaged])
    first = bp.run("apply", "https://dev.azure.com/org", "lab", "enterprise-architecture", fake)
    assert {a["action"] for a in first} == {"create"} and len(first) == 31
    second = bp.run("apply", "https://dev.azure.com/org", "lab", "enterprise-architecture", fake)
    assert {a["action"] for a in second} == {"unchanged"}
    assert 1 in fake.configs                                         # unmanaged policy untouched
    # drift on a managed policy is corrected; a no-longer-desired managed policy is pruned only with --prune
    bid = next(c["id"] for c in fake.configs.values() if "build-lab-platform]" in (c["settings"].get("displayName") or ""))
    fake.configs[bid]["settings"]["validDuration"] = 720
    extra = dict(fake.configs[bid], id=999, settings=dict(fake.configs[bid]["settings"], displayName="old [lab-policy:build-old]"))
    fake.configs[999] = extra
    third = bp.run("apply", "https://dev.azure.com/org", "lab", "enterprise-architecture", fake)
    acts = {a["key"]: a["action"] for a in third}
    assert acts["build-lab-platform"] == "update" and acts["build-old"] == "delete" and 999 in fake.configs
    assert fake.configs[bid]["settings"]["validDuration"] == 0
    bp.run("apply", "https://dev.azure.com/org", "lab", "enterprise-architecture", fake, prune=True)
    assert 999 not in fake.configs


def test_unresolved_groups_and_missing_pipelines_block():
    fake = FakeAdo()
    acts = bp.run("plan", "https://dev.azure.com/org", "lab", "enterprise-architecture", fake)
    blocked = [a for a in acts if a["action"] == "blocked"]
    assert blocked and all("identity id" in a["reason"] for a in blocked)
    assert not [c for c in fake.calls if c[0] in ("POST", "PUT", "DELETE")]   # plan never writes


def test_branch_acl_tokens_are_utf16_hex():
    cmds = bp.branch_acl_commands("https://dev.azure.com/org", "p", "r", branching_doc(ROOT))
    assert any("refs/heads/6600650061007400750072006500" in c for c in cmds)   # "feature"
    assert "--deny-bit 16" in cmds[0]


def test_copilot_review_is_discovered_by_name_or_skipped(monkeypatch):
    doc = branching_doc(ROOT)
    doc["identities"] = {g: f"id-{g}" for g in ("app-team", "docs-team", "observability-team", "platform-team", "security-team",
                                                 "eh-pr-reviewer")}
    monkeypatch.setattr(bp, "branching_doc", lambda repo=ROOT: doc)
    with_copilot = FakeAdo()
    acts = {a["key"]: a for a in bp.run("apply", "https://dev.azure.com/org", "lab", "enterprise-architecture", with_copilot)}
    assert acts["copilot-review"]["action"] == "create" and acts["copilot-review-release"]["action"] == "create"
    created = [c for c in with_copilot.configs.values() if c["type"]["id"] == "11111111-2222-3333-4444-555555555555"]
    assert len(created) == 2 and all(c["isBlocking"] is False for c in created)
    assert acts["comments"]["action"] == "create"                    # comments (Copilot's too) must be resolved
    again = {a["key"]: a["action"] for a in bp.run("apply", "https://dev.azure.com/org", "lab", "enterprise-architecture",
                                                   with_copilot)}
    assert again["copilot-review"] == "unchanged"                      # adopted on re-run: idempotent
    without = bp.run("plan", "https://dev.azure.com/org", "lab", "enterprise-architecture", FakeAdo(copilot=False))
    skipped = [a for a in without if a["action"] == "skipped"]
    assert {a["key"] for a in skipped} == {"copilot-review", "copilot-review-release"}
    assert "not available in this organization yet" in skipped[0]["reason"]
    assert not [a for a in without if a["action"] == "blocked"]       # skipping never blocks the other policies
