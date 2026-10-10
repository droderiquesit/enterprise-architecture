"""Data model of the review engine. Everything here is plain data: the PR diff is never executed."""

from __future__ import annotations

import hashlib
from dataclasses import asdict, dataclass, field
from typing import Any

SEVERITIES = ("critical", "high", "medium", "low", "info")
SEVERITY_RANK = {s: i for i, s in enumerate(SEVERITIES)}  # lower = worse
# kind: violation (author must fix), risk (needs a human decision), quality (advice), ai (model output, untrusted)
KINDS = ("violation", "risk", "quality", "ai")

OUTCOMES = {  # outcome -> Azure DevOps reviewer vote (Pull Request Reviewers - Create Pull Request Reviewer, api 7.1)
    "approve": 10,
    "approve-with-suggestions": 5,
    "no-vote": 0,
    "wait-for-author": -5,
    "reject": -10,
}


@dataclass
class FileChange:
    """One changed path between base and head. Texts are None when absent (add/delete) or binary/too large."""

    path: str
    status: str  # A M D R (rename) T
    old_path: str | None = None
    base_text: str | None = None
    head_text: str | None = None
    binary: bool = False
    too_large: bool = False
    change_tracking_id: int | None = None  # Azure DevOps iteration change id (inline thread anchoring)

    @property
    def paths(self) -> list[str]:
        return [p for p in (self.old_path, self.path) if p]


@dataclass
class Finding:
    rule: str
    severity: str
    kind: str
    category: str
    message: str
    file: str | None = None
    line: int | None = None
    suggestion: str | None = None
    evidence: str = ""  # normalised text the fingerprint is computed from (never a secret value)
    definite: bool = False  # a definite policy violation (committed secret, policy tamper) -> reject
    source: str = "rule"  # rule | ai
    fingerprint: str = ""

    def __post_init__(self) -> None:
        if self.severity not in SEVERITIES:
            raise ValueError(f"unknown severity {self.severity}")
        if self.kind not in KINDS:
            raise ValueError(f"unknown kind {self.kind}")
        if not self.fingerprint:
            basis = "|".join([self.source, self.rule, self.file or "", " ".join(self.evidence.split()) or self.message])
            self.fingerprint = hashlib.sha256(basis.encode()).hexdigest()[:16]

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class BuildStatus:
    """PR build validation state on the latest iteration (Policy Evaluations API, read by the reviewer)."""

    state: str = "unknown"  # green | failed | pending | unknown
    details: list[dict] = field(default_factory=list)


@dataclass
class ReviewContext:
    author: str = ""  # unique name / id of the PR author
    author_id: str = ""
    bot_ids: list[str] = field(default_factory=list)
    target_branch: str = "main"
    build: BuildStatus = field(default_factory=BuildStatus)
    head: str = ""
    base: str = ""
    pr_id: int | None = None
    iteration: int | None = None
    title: str = ""
    copilot: Any = None  # tools.review.copilot.CopilotState (None = not evaluated, e.g. local CLI)


@dataclass
class Decision:
    outcome: str
    vote: int
    status_state: str  # succeeded | failed | pending
    status_description: str
    auto_approvable: bool
    human_required: bool
    reasons: list[str] = field(default_factory=list)
    recheck: bool = False  # waiting for something external (build, Copilot review): re-check later


@dataclass
class ReviewResult:
    head: str
    base: str
    policy_hash: str
    files: list[dict]
    components: list[dict]
    consumers: list[str]
    layers: list[str]
    classes: dict[str, list[str]]
    findings: list[Finding]
    decision: Decision
    stats: dict
    ai: dict
    notes: list[str] = field(default_factory=list)
    copilot: dict = field(default_factory=dict)

    def to_dict(self) -> dict:
        d = asdict(self)
        d["findings"] = [f.to_dict() for f in self.findings]
        return d

    @property
    def input_hash(self) -> str:
        """Identity of the review for idempotency (same head + policy + findings + decision => same outputs)."""
        basis = "|".join(
            [
                self.head,
                self.policy_hash,
                self.decision.outcome,
                self.decision.status_state,
                ",".join(sorted(f.fingerprint for f in self.findings)),
                f"copilot:{self.copilot.get('active_threads')}:{self.copilot.get('reviewed_current')}",
            ]
        )
        return hashlib.sha256(basis.encode()).hexdigest()[:20]
