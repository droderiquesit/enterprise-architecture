#!/usr/bin/env python3
"""Transient-failure classifier and bounded auto-retry for pipeline commands.

    python3 tools/deploy/retry.py classify --file error.log            # print the matching rule
    python3 tools/deploy/retry.py run --component X --label init [--ok-codes 0] -- terraform init ...
    python3 tools/deploy/retry.py tf-apply --component X --root <dir> --plan <tfplan> [--lock-key <env>/<id>.tfstate]

Rules: tools/deploy/retry_rules.yaml (permanent -> lock -> transient; unmatched = permanent).
Policy: registry `retry: {attempts, max_minutes}` per component, else the rule-file defaults; exponential
backoff with full jitter. Every attempt is logged (##vso warning with the matched rule) and appended as a
JSON line to $RETRY_LOG (default $OUT_DIR/health/retries.jsonl) for the pipeline health summary.

`tf-apply` never blindly re-applies a saved plan: after a transient apply failure it re-plans against the
current state and continues only when every change of the new plan is part of the reviewed plan's intent
(same address, an action the reviewed plan allowed - never a new destroy); otherwise it stops and asks for
a reviewed re-run. State-lock failures are handed to tools/deploy/lock_doctor.py.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import random
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Dict, List, Optional, Sequence

import yaml

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))
RULES_FILE = Path(__file__).with_name("retry_rules.yaml")
TAIL_BYTES = 200_000


@dataclass
class Match:
    kind: str          # transient | permanent | lock | unknown
    rule: str
    why: str = ""
    pattern: str = ""

    @property
    def retryable(self) -> bool:
        return self.kind in ("transient", "lock")


@dataclass
class Policy:
    attempts: int = 3
    max_minutes: float = 20
    base_seconds: float = 15
    factor: float = 2.0
    max_backoff_seconds: float = 180
    jitter: float = 0.3

    def backoff(self, attempt: int, rnd: random.Random) -> float:
        raw = min(self.max_backoff_seconds, self.base_seconds * (self.factor ** (attempt - 1)))
        return max(0.0, raw * (1 + rnd.uniform(-self.jitter, self.jitter)))


def load_rules(path: Path = RULES_FILE) -> dict:
    doc = yaml.safe_load(path.read_text()) or {}
    for section in ("permanent", "lock", "transient"):
        for rule in doc.get(section) or []:
            rule["_compiled"] = [re.compile(p, re.I | re.M) for p in rule["patterns"]]
    return doc


def classify(text: str, rules: Optional[dict] = None) -> Match:
    rules = rules or load_rules()
    for section in ("permanent", "lock", "transient"):
        for rule in rules.get(section) or []:
            for rx in rule["_compiled"]:
                if rx.search(text or ""):
                    return Match(section, rule["id"], rule.get("why", ""), rx.pattern)
    return Match("unknown", "unclassified", "no rule matched - treated as permanent")


def policy_for(component: Optional[str], rules: Optional[dict] = None, repo: Path = REPO) -> Policy:
    rules = rules or load_rules()
    d = dict(rules.get("defaults") or {})
    if component:
        try:
            from tools.changeset.registry import load_registry
            from tools.changeset.trees import WorkTree

            c = load_registry(WorkTree(repo)).components.get(component)
            if c is not None and isinstance(c.raw.get("retry"), dict):
                d.update(c.raw["retry"])
        except Exception:  # noqa: BLE001 - a broken registry must not break retries; defaults apply
            pass
    for key, env in (("attempts", "RETRY_ATTEMPTS"), ("max_minutes", "RETRY_MAX_MINUTES")):
        if os.environ.get(env):
            d[key] = float(os.environ[env]) if key == "max_minutes" else int(os.environ[env])
    return Policy(**{k: v for k, v in d.items() if k in Policy.__dataclass_fields__})


def _log_path() -> Optional[Path]:
    if os.environ.get("RETRY_LOG"):
        return Path(os.environ["RETRY_LOG"])
    out = os.environ.get("OUT_DIR") or os.environ.get("HEALTH_DIR")
    return Path(out) / "health" / "retries.jsonl" if out else None


def log_event(event: dict) -> None:
    event = dict(event, at=dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
    p = _log_path()
    if p:
        p.parent.mkdir(parents=True, exist_ok=True)
        with p.open("a") as f:
            f.write(json.dumps(event, sort_keys=True) + "\n")


def _execute(cmd: Sequence[str], cwd: Optional[str] = None, stream: bool = True) -> tuple[int, str]:
    proc = subprocess.Popen(list(cmd), cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                            errors="replace")
    tail: List[str] = []
    size = 0
    assert proc.stdout is not None
    for line in proc.stdout:
        if stream:
            sys.stdout.write(line)
            sys.stdout.flush()
        tail.append(line)
        size += len(line)
        while size > TAIL_BYTES and tail:
            size -= len(tail.pop(0))
    return proc.wait(), "".join(tail)


Runner = Callable[[Sequence[str]], tuple]


def run_with_retry(cmd: Sequence[str], *, label: str, component: Optional[str] = None,
                   ok_codes: Sequence[int] = (0,), policy: Optional[Policy] = None,
                   runner: Optional[Runner] = None, sleep: Callable[[float], None] = time.sleep,
                   on_lock: Optional[Callable[[str], bool]] = None, rnd: Optional[random.Random] = None,
                   clock: Callable[[], float] = time.monotonic, rules: Optional[dict] = None) -> tuple[int, str, List[dict]]:
    """Run `cmd` until it exits with an ok code, a permanent failure occurs or the policy is exhausted.
    Returns (exit code, last output, attempt events)."""
    rules = rules or load_rules()
    policy = policy or policy_for(component, rules)
    runner = runner or (lambda c: _execute(c))
    rnd = rnd or random.Random()
    deadline = clock() + policy.max_minutes * 60
    events: List[dict] = []
    attempt = 0
    while True:
        attempt += 1
        code, output = runner(cmd)
        if code in ok_codes:
            if attempt > 1:
                ev = {"component": component, "label": label, "attempt": attempt, "result": "recovered"}
                events.append(ev)
                log_event(ev)
            return code, output, events
        m = classify(output, rules)
        ev = {"component": component, "label": label, "attempt": attempt, "exit_code": code,
              "class": m.kind, "rule": m.rule}
        if not m.retryable:
            ev["result"] = "permanent"
            events.append(ev)
            log_event(ev)
            print(f"##vso[task.logissue type=error]{label}: {m.kind} failure ({m.rule}: {m.why}) - not retried")
            return code, output, events
        if m.kind == "lock" and on_lock is not None:
            if not on_lock(output):
                ev["result"] = "lock-held"
                events.append(ev)
                log_event(ev)
                print(f"##vso[task.logissue type=error]{label}: state lock held by a live run - not broken")
                return code, output, events
            ev["result"] = "lock-recovered"
        wait = policy.backoff(attempt, rnd)
        if attempt >= policy.attempts or clock() + wait > deadline:
            ev["result"] = "exhausted"
            events.append(ev)
            log_event(ev)
            print(f"##vso[task.logissue type=error]{label}: {m.rule} persisted after {attempt} attempt(s) "
                  f"(budget {policy.attempts} attempts / {policy.max_minutes} min)")
            return code, output, events
        ev.setdefault("result", "retrying")
        ev["backoff_seconds"] = round(wait, 1)
        events.append(ev)
        log_event(ev)
        print(f"##vso[task.logissue type=warning]{label}: transient failure ({m.rule}: {m.why}); "
              f"attempt {attempt + 1}/{policy.attempts} in {wait:.0f}s")
        sleep(wait)


# --------------------------------------------------------------- apply intent
def plan_changes(plan_json: dict) -> Dict[str, set]:
    out = {}
    for rc in plan_json.get("resource_changes", []) or []:
        if rc.get("mode") == "data":
            continue
        actions = set(rc.get("change", {}).get("actions", []))
        if actions <= {"no-op", "read"}:
            continue
        out[rc["address"]] = actions
    return out


def intent_violations(reviewed: dict, new: dict) -> List[str]:
    """Changes of the re-plan that the reviewed plan did not intend (new addresses, new deletes, ...)."""
    allowed_by = {
        frozenset({"create"}): {"create", "update"},
        frozenset({"update"}): {"update"},
        frozenset({"delete"}): {"delete"},
        frozenset({"delete", "create"}): {"delete", "create", "update"},
        frozenset({"forget"}): {"forget"},
    }
    rev = plan_changes(reviewed)
    problems = []
    for addr, actions in sorted(plan_changes(new).items()):
        if addr not in rev:
            problems.append(f"{addr}: {'/'.join(sorted(actions))} not in the reviewed plan")
            continue
        allowed = allowed_by.get(frozenset(rev[addr]), set(rev[addr]))
        extra = actions - allowed
        if extra:
            problems.append(f"{addr}: {'/'.join(sorted(extra))} beyond the reviewed {'/'.join(sorted(rev[addr]))}")
    return problems


def tf_show_json(root: str, plan: str, runner=None) -> dict:
    runner = runner or (lambda c: _execute(c, stream=False))
    code, out = runner(["terraform", f"-chdir={root}", "show", "-json", plan])
    if code != 0:
        raise RuntimeError(f"terraform show -json {plan} failed")
    return json.loads(out[out.index("{"):])


def tf_apply(component: str, root: str, plan: str, *, policy: Optional[Policy] = None, runner=None,
             show=None, sleep=time.sleep, on_lock=None, rules=None) -> int:
    """Apply the reviewed plan; after a transient failure re-plan and continue only within its intent."""
    rules = rules or load_rules()
    policy = policy or policy_for(component, rules)
    show = show or (lambda p: tf_show_json(root, p))
    reviewed = show(plan)
    apply_cmd = ["terraform", f"-chdir={root}", "apply", "-input=false", "-no-color", "-lock-timeout=10m", plan]
    code, output, _ = run_with_retry(apply_cmd, label="terraform apply", component=component,
                                     policy=Policy(**{**policy.__dict__, "attempts": 1}), runner=runner,
                                     sleep=sleep, on_lock=on_lock, rules=rules)
    if code == 0:
        return 0
    m = classify(output, rules)
    if not m.retryable:
        return code
    replan = str(Path(plan).with_name("replan.tfplan"))
    for attempt in range(2, policy.attempts + 1):
        sleep(policy.backoff(attempt - 1, random.Random()))
        pcode, pout, _ = run_with_retry(["terraform", f"-chdir={root}", "plan", "-input=false", "-no-color",
                                         "-lock-timeout=10m", "-detailed-exitcode", f"-out={replan}"],
                                        label="terraform re-plan", component=component, ok_codes=(0, 2),
                                        policy=policy, runner=runner, sleep=sleep, on_lock=on_lock, rules=rules)
        if pcode == 0:
            log_event({"component": component, "label": "terraform apply", "attempt": attempt,
                       "result": "recovered", "note": "re-plan shows no remaining changes"})
            return 0
        if pcode != 2:
            return pcode
        problems = intent_violations(reviewed, show(replan))
        if problems:
            log_event({"component": component, "label": "terraform apply", "attempt": attempt,
                       "result": "refused", "violations": problems})
            for p in problems:
                print(f"##vso[task.logissue type=error]auto-continue refused: {p}")
            print("re-plan contains changes outside the reviewed plan: re-run the pipeline for a reviewed plan",
                  file=sys.stderr)
            return 1
        code, output, _ = run_with_retry(["terraform", f"-chdir={root}", "apply", "-input=false", "-no-color",
                                          "-lock-timeout=10m", replan], label="terraform apply (remaining diff)",
                                         component=component, policy=Policy(**{**policy.__dict__, "attempts": 1}),
                                         runner=runner, sleep=sleep, on_lock=on_lock, rules=rules)
        if code == 0:
            log_event({"component": component, "label": "terraform apply", "attempt": attempt, "result": "recovered"})
            return 0
        if not classify(output, rules).retryable:
            return code
    return code


def _lock_hook(args):
    if not args.lock_key:
        return None

    def hook(output: str) -> bool:
        from tools.deploy.lock_doctor import recover_from_output

        return recover_from_output(output, env=os.environ.get("LAB_ENV", ""), component=args.component,
                                   root=getattr(args, "root", None), key=args.lock_key)
    return hook


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("classify")
    c.add_argument("--file", required=True)
    r = sub.add_parser("run")
    r.add_argument("--component")
    r.add_argument("--label", required=True)
    r.add_argument("--ok-codes", default="0")
    r.add_argument("--lock-key")
    r.add_argument("command", nargs=argparse.REMAINDER)
    a = sub.add_parser("tf-apply")
    a.add_argument("--component", required=True)
    a.add_argument("--root", required=True)
    a.add_argument("--plan", required=True)
    a.add_argument("--lock-key")
    args = ap.parse_args(argv)
    if args.cmd == "classify":
        m = classify(Path(args.file).read_text(errors="replace"))
        print(json.dumps(m.__dict__))
        return 0
    if args.cmd == "run":
        cmd = args.command[1:] if args.command[:1] == ["--"] else args.command
        if not cmd:
            ap.error("command required after --")
        code, _out, _ev = run_with_retry(cmd, label=args.label, component=args.component,
                                         ok_codes=[int(x) for x in args.ok_codes.split(",")], on_lock=_lock_hook(args))
        return code
    return tf_apply(args.component, args.root, args.plan, on_lock=_lock_hook(args))


if __name__ == "__main__":
    sys.exit(main())
