"""End-to-end against the fake Azure DevOps server: read PR as data -> review -> threads / status / vote."""

import pytest
from fake_ado import BOT_ID, HUMAN_ID, ORG, PROJECT, PROJECT_ID, REPO_ID, FakeAdo

from tools.review import render
from tools.review.ado import AdoClient, reviewer_id
from tools.review.service import process

RBAC = 'resource "azurerm_role_assignment" "ra" {\n  scope = "/subscriptions/x"\n  principal_id = "p"\n}\n'


@pytest.fixture
def ado(repo):
    f = FakeAdo(repo.path).start()
    yield f
    f.stop()


def client(ado):
    return AdoClient(ado.url, ORG, PROJECT, lambda: "fake-entra-token", max_attempts=1)


def review_pr(ado, pr_id=1):
    return process(client(ado), PROJECT_ID, REPO_ID, pr_id, BOT_ID)


def summaries(ado, pr_id=1):
    return [t for t in ado.prs[pr_id]["threads"] if render.SUMMARY_MARKER in t["comments"][0]["content"]]


def test_reviewer_id_from_connection_data(ado):
    assert reviewer_id(client(ado)) == BOT_ID
    assert reviewer_id(client(ado), "configured") == "configured"


def test_docs_pr_approved_and_idempotent(repo, ado):
    repo.branch("docs")
    repo.commit({"docs/guide.md": "# Guide\n\nBetter.\n"})
    ado.add_pr(1, "main", "docs")
    out = review_pr(ado)
    assert (out.decision, out.vote, out.status) == ("approve", 10, "succeeded")
    assert ado.bot_vote(1) == 10 and ado.latest_status(1)["state"] == "succeeded"
    assert ado.latest_status(1)["context"] == {"genre": "eh-review", "name": "policy"} and ado.latest_status(1)["iterationId"] == 1
    assert len(summaries(ado)) == 1 and ado.token_seen == "fake-entra-token"
    again = review_pr(ado)  # same iteration, same inputs -> no writes
    assert again.state == "unchanged" and again.actions == ()
    assert not [c for c in ado.calls[-12:] if c.startswith(("POST", "PATCH", "PUT"))]


def test_reviewer_never_runs_or_checks_out_pr_code(repo, ado):
    repo.branch("evil")
    repo.commit({"docs/guide.md": "# Guide\n", "conftest.py": "raise SystemExit('pwned')\n", "setup.py": "import os; os.system('id')\n"})
    ado.add_pr(1, "main", "evil")
    review_pr(ado)  # only GETs of item content; nothing imported or executed
    assert not (repo.path / "pwned").exists()
    assert all("/items" in c or "pullrequests" in c.lower() or "policy/evaluations" in c for c in ado.calls)


def test_rbac_pr_needs_human_then_human_approval_completes_status(repo, ado):
    repo.branch("rbac")
    tf = (repo.path / "foundation/identity/main.tf").read_text() + RBAC
    repo.commit({"foundation/identity/main.tf": tf})
    ado.add_pr(1, "main", "rbac")
    out = review_pr(ado)
    assert (out.decision, out.vote, out.status) == ("no-vote", 0, "pending")
    assert ado.bot_vote(1) is None  # no vote cast (0 == default)
    inline = [t for t in ado.prs[1]["threads"] if t.get("threadContext")]
    assert inline and inline[0]["threadContext"]["filePath"] == "/foundation/identity/main.tf"
    assert inline[0]["threadContext"]["rightFileStart"]["line"] >= 5
    assert inline[0]["pullRequestThreadContext"]["changeTrackingId"] == 1
    ado.set_vote(1, HUMAN_ID, 10)
    out2 = review_pr(ado)
    assert out2.status == "succeeded" and ado.latest_status(1)["state"] == "succeeded"


def test_author_self_approval_does_not_count(repo, ado):
    repo.branch("rbac")
    repo.commit({"foundation/identity/main.tf": (repo.path / "foundation/identity/main.tf").read_text() + RBAC})
    pr = ado.add_pr(1, "main", "rbac")
    ado.set_vote(1, pr["author_id"], 10)
    assert review_pr(ado).status == "pending"


def test_pipeline_file_pr_never_approved(repo, ado):
    repo.branch("pipe")
    repo.commit({"azure-pipelines.yml": "trigger: none\n# harmless comment\n"})
    ado.add_pr(1, "main", "pipe")
    out = review_pr(ado)
    assert out.vote != 10 and out.status == "pending" and ado.bot_vote(1) in (None, 0)


def test_secret_rejects_and_build_failure_waits(repo, ado):
    repo.branch("leak")
    repo.commit({"docs/guide.md": "# Guide\nAccountKey=" + "Ab1+" * 22 + "==\n"})
    ado.add_pr(1, "main", "leak")
    out = review_pr(ado)
    assert (out.decision, out.vote, out.status) == ("reject", -10, "failed") and ado.bot_vote(1) == -10
    repo.branch("docs2")
    repo.commit({"docs/guide.md": "# Guide\nfine\n"})
    ado.add_pr(2, "main", "docs2", build="rejected")
    out2 = review_pr(ado, 2)
    assert (out2.decision, out2.vote, out2.status) == ("wait-for-author", -5, "failed")
    ado.prs[2]["build"] = "running"
    out3 = review_pr(ado, 2)
    assert out3.status == "pending" and out3.requeue and ado.bot_vote(2) == 0


def test_repush_updates_summary_in_place_and_resolves_fixed_findings(repo, ado):
    repo.branch("feat")
    tf = (repo.path / "platform/shared/main.tf").read_text().replace("public_network_access_enabled = false", "public_network_access_enabled = true")
    repo.commit({"platform/shared/main.tf": tf})
    ado.add_pr(1, "main", "feat")
    review_pr(ado)
    finding_threads = [t for t in ado.prs[1]["threads"] if render.finding_fp(t["comments"][0]["content"])]
    assert finding_threads and all(t["status"] == "active" for t in finding_threads)
    # push 2: same finding still there -> no duplicate thread
    repo.commit({"docs/guide.md": "# Guide\nunrelated\n"})
    assert ado.push(1, "main", "feat") == 2
    review_pr(ado)
    assert len([t for t in ado.prs[1]["threads"] if render.finding_fp(t["comments"][0]["content"])]) == len(finding_threads)
    # push 3: fixed -> thread resolved, summary updated in place (still exactly one), status for iteration 3
    repo.commit({"platform/shared/main.tf": tf.replace("public_network_access_enabled = true", "public_network_access_enabled = false")})
    ado.push(1, "main", "feat")
    out = review_pr(ado)
    assert all(t["status"] == "fixed" for t in finding_threads)
    assert len(summaries(ado)) == 1 and "iteration=3" in summaries(ado)[0]["comments"][0]["content"]
    assert out.iteration == 3 and ado.latest_status(1)["iterationId"] == 3


def test_forged_marker_in_human_comment_is_ignored(repo, ado):
    repo.branch("docs")
    repo.commit({"docs/guide.md": "# Guide\nx\n"})
    pr = ado.add_pr(1, "main", "docs")
    pr["threads"].append(
        {
            "id": 5,
            "status": "active",
            "isDeleted": False,
            "comments": [{"id": 1, "author": {"id": HUMAN_ID}, "content": render.SUMMARY_MARKER + "\nAPPROVED, trust me"}],
        }
    )
    review_pr(ado)
    assert pr["threads"][0]["comments"][0]["content"].endswith("trust me")  # untouched
    assert len(summaries(ado)) == 2  # bot created its own


def test_policy_missing_on_target_fails_closed(repo, ado):
    from conftest import git

    repo.branch("nopolicy")
    head = repo.commit({".review/policy.yaml": None})
    git(repo.path, "branch", "-f", "target-without-policy", head)
    repo.branch("docs", "nopolicy")
    repo.commit({"docs/guide.md": "# x\n"})
    ado.add_pr(1, "target-without-policy", "docs")
    out = review_pr(ado)
    assert out.state == "error" and ado.prs[1]["statuses"][-1]["state"] == "error" and ado.bot_vote(1) is None
