#!/usr/bin/env python3
"""Converge Delinea DSV configuration to the desired state rendered by foundation-secrets (ADR-0001 section 14).

    python3 tools/secrets/dsv_apply.py plan  --root foundation/secrets [--plan-json plan.json] [--summary-md F] [--ado]
    python3 tools/secrets/dsv_apply.py apply --root foundation/secrets
    python3 tools/secrets/dsv_apply.py plan  --state desired.json            (tests / offline)

Desired state source (first match): --state FILE | --plan-json (planned output of a saved plan) |
`terraform -chdir=<root> output -json <--output, default dsv_desired_state>`.

Objects (REST endpoints verified against dsv-cli v1.41.1 commands/*.go; see tools/secrets/dsvlib.py):
  auth provider  GET /config/auth/<name>; created when missing (type azure, properties.tenantId). An existing provider
                 with another type/tenant is a CONFLICT (never modified - it is shared and created at bootstrap).
  users          GET /users/<provider>:<username>; created when missing. provider/externalId cannot be updated
                 through the API (only displayName/password), so a mismatch is a CONFLICT. displayName is updated
                 only on users that carry the marker. Users created by an operator (no marker) that match are kept as-is.
  policy         GET /config/policies/<path>; created when missing. Otherwise its permissionDocument is rewritten
                 as: every permission WITHOUT the marker in its description (operator-owned, kept verbatim and in
                 order) + the desired managed permissions. Managed permissions no longer desired are removed from
                 the document (access revocation); nothing else is ever deleted.
  orphans        managed users (marker, same base path) that are no longer desired are REPORTED, never deleted.

Authentication: the caller's managed identity (DSV_AUTH=azure; on pipelines the deploy agent identity, mapped to
a DSV user with administrative rights by an operator once at bootstrap - bootstrap/README.md).
Exit codes: plan 0 = in sync, 2 = changes, 1 = error/conflict; apply 0 = converged, 1 = error/conflict.
Output never contains secret values (the desired state contains none).
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import List, Optional

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.secrets.dsvlib import DsvClient, DsvError, base_url_from  # noqa: E402

PERMISSION_FIELDS = ("description", "subjects", "effect", "actions", "resources", "conditions")


@dataclass
class Change:
    kind: str       # auth-provider | user | policy
    name: str
    action: str     # create | update | ok | conflict | orphan | adopted
    detail: str = ""
    payload: dict = field(default_factory=dict, repr=False)

    def line(self) -> str:
        return f"{self.action:9} {self.kind:13} {self.name}" + (f"  ({self.detail})" if self.detail else "")


# ----------------------------------------------------------------------------- desired state
def load_desired(args) -> dict:
    if args.state:
        doc = json.loads(Path(args.state).read_text())
        return doc.get("value", doc) if isinstance(doc, dict) and "sensitive" in doc else doc
    if args.plan_json:
        plan = json.loads(Path(args.plan_json).read_text())
        out = (plan.get("planned_values", {}).get("outputs", {}) or {}).get(args.output)
        if out is None:
            raise DsvError(f"planned output '{args.output}' not found in {args.plan_json}")
        if out.get("sensitive"):
            raise DsvError(f"output '{args.output}' must not be sensitive")
        return out["value"]
    proc = subprocess.run(["terraform", f"-chdir={args.root}", "output", "-json", args.output], capture_output=True, text=True)
    if proc.returncode != 0:
        raise DsvError(f"terraform output {args.output} failed: {proc.stderr.strip()[:300]}")
    return json.loads(proc.stdout)


def _perm(p: dict) -> dict:
    return {k: p[k] for k in PERMISSION_FIELDS if k in p and p[k] not in (None, {}, [])}


def _current_permissions(policy: dict) -> List[dict]:
    """permissionDocument as returned by GET /config/policies/<path> (parsed list, or a JSON `policy` string)."""
    if isinstance(policy.get("permissionDocument"), list):
        return policy["permissionDocument"]
    raw = policy.get("policy")
    if isinstance(raw, str) and raw.strip():
        doc = json.loads(raw)
        return doc.get("permissionDocument", []) if isinstance(doc, dict) else []
    return []


def _managed(marker: str, text: Optional[str]) -> bool:
    return isinstance(text, str) and text.startswith(marker + " ")


# ----------------------------------------------------------------------------- diff
def diff(client: DsvClient, desired: dict) -> List[Change]:
    marker = desired["marker"]
    changes: List[Change] = []

    ap = desired["auth_provider"]
    st, cur = client.request("GET", f"config/auth/{ap['name']}")
    want = {"name": ap["name"], "type": ap["type"], "properties": {"tenantId": ap["tenant_id"]}}
    if st == 404:
        changes.append(Change("auth-provider", ap["name"], "create", f"type {ap['type']}", want))
    elif st == 200:
        tenant = (cur.get("properties") or {}).get("tenantId")
        if cur.get("type") != ap["type"] or (tenant or "").lower() != ap["tenant_id"].lower():
            changes.append(Change("auth-provider", ap["name"], "conflict",
                                  f"exists with type={cur.get('type')} tenantId={tenant}; fix it manually (shared object)"))
        else:
            changes.append(Change("auth-provider", ap["name"], "ok"))
    else:
        raise DsvError(f"read auth provider {ap['name']}: HTTP {st}", st)

    for uname, u in sorted(desired["users"].items()):
        qualified = u.get("qualified") or f"{u['provider']}:{uname}"
        st, cur = client.request("GET", f"users/{qualified}")
        body = {"userName": uname, "displayName": u["display_name"], "provider": u["provider"], "externalId": u["external_id"]}
        if st == 404:
            changes.append(Change("user", qualified, "create", f"identity {u['identity']}", body))
            continue
        if st != 200:
            raise DsvError(f"read user {qualified}: HTTP {st}", st)
        if cur.get("provider") != u["provider"] or (cur.get("externalId") or "").lower() != u["external_id"].lower():
            changes.append(Change("user", qualified, "conflict", "provider/externalId differ and cannot be updated "
                                  "through the DSV API; delete/recreate it manually after review"))
        elif not _managed(marker, cur.get("displayName")):
            changes.append(Change("user", qualified, "adopted", "operator-created (no marker); matches - left unchanged"))
        elif cur.get("displayName") != u["display_name"]:
            changes.append(Change("user", qualified, "update", "displayName", {"displayName": u["display_name"]}))
        else:
            changes.append(Change("user", qualified, "ok"))

    # orphaned managed users (reported only)
    st, found = client.request("GET", "users", query={"searchTerm": desired["base_path"].replace("/", "-") + "-"})
    if st == 200:
        wanted = {(u.get("qualified") or f"{u['provider']}:{n}") for n, u in desired["users"].items()}
        for item in found.get("data") or []:
            q = f"{item.get('provider')}:{item.get('userName')}" if item.get("provider") else item.get("userName")
            disp = item.get("displayName") or ""
            if _managed(marker, disp) and f" {desired['base_path']} " in f"{disp} " and q not in wanted:
                changes.append(Change("user", q, "orphan", "managed user no longer desired - not deleted (remove manually)"))

    pol = desired["policy"]
    desired_perms = [_perm(p) for p in pol["permissions"]]
    st, cur = client.request("GET", f"config/policies/{pol['path']}")
    if st == 404:
        changes.append(Change("policy", pol["path"], "create", f"{len(desired_perms)} managed permission(s)",
                              {"path": pol["path"], "permissions": desired_perms}))
    elif st == 200:
        current = _current_permissions(cur)
        keep = [p for p in current if not _managed(marker, p.get("description"))]
        managed_now = [_perm(p) for p in current if _managed(marker, p.get("description"))]
        if _canon(managed_now) == _canon(desired_perms):
            changes.append(Change("policy", pol["path"], "ok", f"{len(keep)} unmanaged permission(s) kept"))
        else:
            before = {p.get("description") for p in managed_now}
            after = {p.get("description") for p in desired_perms}
            detail = (f"+{len(after - before)} -{len(before - after)} ~{sum(1 for p in desired_perms if p.get('description') in before and p not in managed_now)}"
                      f" managed permission(s); {len(keep)} unmanaged kept")
            changes.append(Change("policy", pol["path"], "update", detail,
                                  {"path": pol["path"], "permissions": keep + desired_perms}))
    else:
        raise DsvError(f"read policy {pol['path']}: HTTP {st}", st)
    return changes


def _canon(perms: List[dict]) -> str:
    return json.dumps(sorted((_perm(p) for p in perms), key=lambda p: p.get("description", "")), sort_keys=True)


# ----------------------------------------------------------------------------- apply
def _policy_body(permissions: List[dict]) -> str:
    return json.dumps({"permissionDocument": permissions}, separators=(",", ":"))


def converge(client: DsvClient, changes: List[Change]) -> List[str]:
    done = []
    for ch in changes:
        if ch.action not in ("create", "update"):
            continue
        if ch.kind == "auth-provider":
            st, _ = client.request("POST", "config/auth/", ch.payload)
        elif ch.kind == "user" and ch.action == "create":
            st, _ = client.request("POST", "users/", ch.payload)
        elif ch.kind == "user":
            st, _ = client.request("PUT", f"users/{ch.name}", ch.payload)
        elif ch.kind == "policy" and ch.action == "create":
            st, _ = client.request("POST", "config/policies/", {"path": ch.payload["path"], "serialization": "json",
                                                                "policy": _policy_body(ch.payload["permissions"])})
        else:
            st, _ = client.request("PUT", f"config/policies/{ch.payload['path']}",
                                   {"serialization": "json", "policy": _policy_body(ch.payload["permissions"])})
        if st != 200:
            raise DsvError(f"{ch.action} {ch.kind} {ch.name}: HTTP {st}", st)
        done.append(ch.line())
    return done


# ----------------------------------------------------------------------------- CLI
def render(changes: List[Change]) -> str:
    rows = "\n".join(f"| {c.action} | {c.kind} | `{c.name}` | {c.detail} |" for c in changes)
    return "## DSV desired state (foundation-secrets)\n\n| action | kind | name | detail |\n|---|---|---|---|\n" + rows + "\n"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=("plan", "apply"))
    ap.add_argument("--root", default="foundation/secrets")
    ap.add_argument("--output", default="dsv_desired_state")
    ap.add_argument("--state", help="desired state JSON file (instead of terraform output)")
    ap.add_argument("--plan-json", help="`terraform show -json` of a saved plan (plan stage)")
    ap.add_argument("--base-url", help="DSV API base URL (default: desired state base_url, DSV_BASE_URL overrides)")
    ap.add_argument("--summary-md", help="append a markdown summary here")
    ap.add_argument("--ado", action="store_true", help="emit ##vso output variable dsv_changes")
    args = ap.parse_args(argv)
    try:
        desired = load_desired(args)
        base = args.base_url or base_url_from({"base_url": desired.get("base_url")})
        client = DsvClient(base)
        changes = diff(client, desired)
        for c in changes:
            print(c.line())
        if args.summary_md:
            with open(args.summary_md, "a", encoding="utf-8") as fh:
                fh.write(render(changes))
        conflicts = [c for c in changes if c.action == "conflict"]
        pending = [c for c in changes if c.action in ("create", "update")]
        if args.ado:
            print(f"##vso[task.setvariable variable=dsv_changes;isOutput=true]{'true' if pending else 'false'}")
        if conflicts:
            print(f"ERROR: {len(conflicts)} conflict(s) need operator action (nothing was changed)", file=sys.stderr)
            return 1
        if args.command == "plan":
            print(f"{len(pending)} change(s) pending" if pending else "DSV configuration in sync")
            return 2 if pending else 0
        done = converge(client, changes)
        remaining = [c for c in diff(client, desired) if c.action in ("create", "update", "conflict")]
        if remaining:
            print("ERROR: not converged after apply: " + "; ".join(c.line() for c in remaining), file=sys.stderr)
            return 1
        print(f"applied {len(done)} change(s); DSV configuration converged")
        return 0
    except DsvError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
