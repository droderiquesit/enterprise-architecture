#!/usr/bin/env python3
"""Pipeline self-monitoring: health summary per run, Datadog event + metrics, alerts.

    python3 tools/report/ci_metrics.py summarize --run-dir <downloaded run artifacts> --env dev --run-id 123 \
        [--records-url <deployments store>] [--scope platform] --out health.json
    python3 tools/report/ci_metrics.py send --health health.json --site datadoghq.com      # needs DD_API_KEY
    python3 tools/report/ci_metrics.py alert --env dev --component X --kind quarantine --reason "..."
    python3 tools/report/ci_metrics.py monitors                                             # suggested monitors

summarize reads what the jobs of this run left behind - */health/retries.jsonl (tools/deploy/retry.py,
lock_doctor.py, rollback.py events), */health/remediation.json (tools/deploy/remediate.py), the selection
document, and the deployment records - and writes one evidence document:
  {selected, mode, retries[{component,label,rule,attempts,result}], recovered, healed, rolled_back,
   quarantined, held, lock_recoveries, drift_remediated, drift_refused, metrics{pipeline.heal.*}}
send posts it as ONE Datadog event (POST /api/v1/events) and gauges (POST /api/v2/series, type 3):
  pipeline.heal.selected, .retries, .retries_recovered, .healed, .rolled_back, .quarantined,
  .lock_recoveries, .drift_remediated, .drift_refused, .failed_components
tagged env:<env>, scope:<scope>, mode:<mode>, pipeline:<definition>. DD_API_KEY comes from Delinea DSV via
`tools/secrets/fetch.py exec --map DD_API_KEY=datadog-api-key` (never a pipeline variable). Telemetry never fails
a run: every network error is a warning.
alert opens (or reuses) an Azure Boards work item (REST, System.AccessToken) and/or sends a Datadog error event,
as configured by environments/<env>/environment.yaml self_healing.notify.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Callable, Dict, List, Optional

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))

METRICS = ("selected", "retries", "retries_recovered", "healed", "rolled_back", "quarantined", "lock_recoveries",
           "drift_remediated", "drift_refused", "failed_components")

MONITOR_ARCHETYPES = [
    {"name": "[lab] component quarantined by the pipeline circuit breaker",
     "query": "max(last_4h):max:pipeline.heal.quarantined{*} by {env,scope} > 0",
     "why": "a component failed max_consecutive_failures runs in a row; heal stopped selecting it",
     "runbook": "docs/runbooks/quarantine.md"},
    {"name": "[lab] consecutive failed pipeline runs",
     "query": "sum(last_6h):sum:pipeline.heal.failed_components{*} by {env,scope}.as_count() >= 3",
     "why": "deployments keep failing even after automatic retries"},
    {"name": "[lab] heal runs failing",
     "query": "events(\"source:azure_devops tags:pipeline-health,mode:heal status:error\").rollup(\"count\").last(\"6h\") >= 2",
     "why": "scheduled heal runs end with failed components - the failure is not transient"},
    {"name": "[lab] state-lock recovery spike",
     "query": "sum(last_1d):sum:pipeline.heal.lock_recoveries{*} by {env}.as_count() > 3",
     "why": "agents or runs are dying mid-apply (stale locks); check agent health / timeouts",
     "runbook": "docs/runbooks/lock-recovery.md"},
    {"name": "[lab] retry storm",
     "query": "sum(last_1h):sum:pipeline.heal.retries{*} by {env}.as_count() > 20",
     "why": "Azure throttling / outage: many transient retries in one hour"},
    {"name": "[lab] drift remediation refused",
     "query": "max(last_1d):max:pipeline.heal.drift_refused{*} by {env} > 0",
     "why": "drift that would delete/replace resources needs a reviewed change"},
]


def _now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _jsonl(path: Path) -> List[dict]:
    out = []
    for line in path.read_text(errors="replace").splitlines():
        try:
            out.append(json.loads(line))
        except ValueError:
            continue
    return out


def summarize(run_dir: Path, env: str, run_id: str, records=None, scope: Optional[str] = None,
              selection: Optional[dict] = None) -> dict:
    run_dir = Path(run_dir)
    if selection is None:
        sel_file = next(iter(sorted(run_dir.glob("selection*/selection.json"))), None)
        selection = json.loads(sel_file.read_text()) if sel_file else {}
    comps = selection.get("components") or {}
    planned = sorted(c for c, e in comps.items() if e.get("plan"))
    events: List[dict] = []
    seen = set()
    for f in sorted(run_dir.rglob("retries.jsonl")):
        for ev in _jsonl(f):
            key = json.dumps(ev, sort_keys=True)
            if key not in seen:          # attempt-aware artifacts may contain the same event twice
                seen.add(key)
                events.append(ev)
    retries = [e for e in events if e.get("result") in ("retrying", "exhausted", "permanent", "recovered",
                                                         "lock-recovered", "lock-held", "refused")]
    retry_attempts = [e for e in retries if e.get("result") in ("retrying", "lock-recovered")]
    recovered = sorted({f"{e.get('component')}:{e.get('label')}" for e in retries if e.get("result") == "recovered"})
    lock_events = [e for e in events if e.get("result") == "lock-broken"]
    rollbacks = [e for e in events if e.get("label") == "rollback"]
    remediation = []
    for f in sorted(run_dir.rglob("remediation.json")):
        try:
            remediation.append(json.loads(f.read_text()))
        except ValueError:
            pass
    statuses: Dict[str, str] = {}
    quarantined: List[dict] = []
    held: List[str] = sorted(selection.get("held") or [])
    if records is not None:
        for key in records.list(f"{env}/"):
            if not key.endswith(".json") or key.count("/") != 1:
                continue
            rec = records.get_json(key) or {}
            cid = key.split("/", 1)[1][:-5]
            if scope and rec.get("scope") and rec.get("scope") != scope:
                continue
            if str(rec.get("run_id")) == str(run_id):
                statuses[cid] = rec.get("status")
            if rec.get("status") == "quarantined":
                quarantined.append({"component": cid, **(rec.get("quarantine") or {})})
        lock_ids = {json.dumps(e, sort_keys=True) for e in lock_events}
        for key in records.list(f"{env}/_audit/"):
            a = records.get_json(key) or {}
            if str((a.get("by") or {}).get("build_id")) == str(run_id):
                lock_ids.add(key)
        lock_count = len(lock_ids)
    else:
        lock_count = len(lock_events)
    healed = sorted(c for c in planned if comps[c].get("heal") and statuses.get(c) == "succeeded")
    failed = sorted(c for c, s in statuses.items() if s in ("failed", "partial", "canceled", "rolled_back", "quarantined"))
    doc = {
        "schema_version": 1, "env": env, "run_id": str(run_id), "scope": scope or selection.get("scope"),
        "mode": selection.get("mode"), "generated_at": _now(),
        "selected": planned,
        "heal_candidates": sorted(c for c in planned if comps[c].get("heal")),
        "retries": retries, "recovered": recovered,
        "healed": healed,
        "rolled_back": sorted({e.get("component") for e in rollbacks if e.get("result") == "rolled_back"}
                              | {c for c, s in statuses.items() if s == "rolled_back"}),
        "rollback_failed": sorted({e.get("component") for e in rollbacks if e.get("result") == "rollback_failed"}),
        "quarantined": quarantined, "held": held,
        "lock_recoveries": lock_count,
        "drift_remediated": sorted(r["component"] for r in remediation if r.get("remediate") == "true"),
        "drift_refused": sorted(r["component"] for r in remediation if r.get("remediate") == "refused"),
        "statuses": statuses, "failed_components": failed,
    }
    doc["metrics"] = {
        "selected": len(planned), "retries": len(retry_attempts), "retries_recovered": len(recovered),
        "healed": len(healed), "rolled_back": len(doc["rolled_back"]), "quarantined": len(quarantined),
        "lock_recoveries": lock_count, "drift_remediated": len(doc["drift_remediated"]),
        "drift_refused": len(doc["drift_refused"]), "failed_components": len(failed),
    }
    return doc


def markdown(doc: dict) -> str:
    m = doc["metrics"]
    lines = [f"## Pipeline health ({doc['env']}, {doc.get('scope') or 'all'}, mode {doc.get('mode')})", "",
             "| metric | value |", "|---|---|"]
    lines += [f"| {k} | {m[k]} |" for k in METRICS]
    for title, key in (("Healed", "healed"), ("Rolled back", "rolled_back"), ("Held (need a commit or manual run)", "held"),
                       ("Drift re-applied", "drift_remediated"), ("Drift refused (destructive)", "drift_refused")):
        if doc.get(key):
            lines += ["", f"**{title}:** " + ", ".join(doc[key])]
    if doc.get("quarantined"):
        lines += ["", "**Quarantined:**"] + [f"- {q['component']}: {q.get('reason', '')}" for q in doc["quarantined"]]
    if doc.get("retries"):
        lines += ["", "**Retries:**"] + [f"- {e.get('component')} {e.get('label')}: {e.get('rule', '')} -> {e.get('result')}"
                                         for e in doc["retries"][:50]]
    return "\n".join(lines) + "\n"


Poster = Callable[[str, dict, Dict[str, str]], int]


def _post(url: str, body: dict, headers: Dict[str, str], attempts: int = 3) -> int:
    data = json.dumps(body).encode()
    for i in range(attempts):
        req = urllib.request.Request(url, data=data, method="POST", headers={"Content-Type": "application/json", **headers})
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                return resp.status
        except urllib.error.HTTPError as exc:
            if exc.code < 500 and exc.code != 429:
                return exc.code
        except (urllib.error.URLError, TimeoutError, OSError):
            pass
        time.sleep(2 * (i + 1))
    return 0


def datadog_payloads(doc: dict, pipeline: str = "") -> tuple:
    tags = [f"env:{doc['env']}", f"scope:{doc.get('scope') or 'all'}", f"mode:{doc.get('mode') or 'unknown'}",
            "source:azure_devops", "pipeline-health"] + ([f"pipeline:{pipeline}"] if pipeline else [])
    bad = doc["metrics"]["failed_components"] or doc["metrics"]["quarantined"] or doc.get("rollback_failed")
    event = {"title": f"[lab] pipeline health {doc['env']}/{doc.get('scope') or 'all'} run {doc['run_id']}: "
                      f"{doc['metrics']['selected']} selected, {doc['metrics']['healed']} healed, "
                      f"{doc['metrics']['failed_components']} failed",
             "text": markdown(doc)[:3900], "tags": tags, "alert_type": "error" if bad else "info",
             "source_type_name": "azure_devops", "aggregation_key": f"pipeline-health-{doc['env']}"}
    ts = int(time.time())
    series = {"series": [{"metric": f"pipeline.heal.{k}", "type": 3, "points": [{"timestamp": ts, "value": doc["metrics"][k]}],
                          "tags": tags[:3]} for k in METRICS]}
    return event, series


def send(doc: dict, site: str, api_key: str, pipeline: str = "", poster: Poster = _post) -> bool:
    event, series = datadog_payloads(doc, pipeline)
    h = {"DD-API-KEY": api_key}
    e = poster(f"https://api.{site}/api/v1/events", event, h)
    s = poster(f"https://api.{site}/api/v2/series", series, h)
    return 200 <= e < 300 and 200 <= s < 300


def notify_settings(env: str) -> dict:
    import yaml

    try:
        doc = yaml.safe_load((REPO / f"environments/{env}/environment.yaml").read_text()) or {}
    except OSError:
        return {}
    return ((doc.get("self_healing") or {}).get("notify")) or {}


def work_item(title: str, description: str, tags: List[str], wi_type: str = "Bug", area: Optional[str] = None,
              poster: Optional[Callable] = None) -> Optional[int]:
    """Create (or reuse an open) Azure Boards work item with System.AccessToken. None when not possible."""
    base, project = os.environ.get("SYSTEM_COLLECTIONURI", ""), os.environ.get("SYSTEM_TEAMPROJECT", "")
    token = os.environ.get("SYSTEM_ACCESSTOKEN", "")
    if not (base and project and token):
        return None
    root = f"{base.rstrip('/')}/{urllib.parse.quote(project)}/_apis/wit"
    auth = {"Authorization": f"Bearer {token}"}

    def call(url, body, content_type="application/json"):
        if poster:
            return poster(url, body, {**auth, "Content-Type": content_type})
        req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                     headers={**auth, "Content-Type": content_type, "Accept": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                return json.loads(resp.read().decode() or "{}")
        except (urllib.error.URLError, TimeoutError, OSError, ValueError):
            return None

    safe = title.replace("'", "''")
    found = call(f"{root}/wiql?api-version=7.1",
                 {"query": f"SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project AND "
                           f"[System.Title] = '{safe}' AND [System.State] NOT IN ('Closed', 'Done', 'Removed')"})
    if isinstance(found, dict) and found.get("workItems"):
        return int(found["workItems"][0]["id"])
    ops = [{"op": "add", "path": "/fields/System.Title", "value": title},
           {"op": "add", "path": "/fields/System.Description", "value": description},
           {"op": "add", "path": "/fields/System.Tags", "value": "; ".join(tags)}]
    if area:
        ops.append({"op": "add", "path": "/fields/System.AreaPath", "value": area})
    created = call(f"{root}/workitems/${urllib.parse.quote(wi_type)}?api-version=7.1", ops, "application/json-patch+json")
    return int(created["id"]) if isinstance(created, dict) and created.get("id") else None


def alert(env: str, component: str, kind: str, reason: str, site: str = "", poster: Poster = _post,
          wi_poster=None) -> dict:
    n = notify_settings(env)
    title = f"[lab pipeline] {env}/{component}: {kind}"
    text = (f"{reason}\n\nRun: {os.environ.get('BUILD_BUILDID', 'local')} ({os.environ.get('BUILD_DEFINITIONNAME', '')}). "
            f"Runbook: docs/runbooks/{'quarantine' if kind == 'quarantine' else 'rollback' if 'rollback' in kind else 'drift'}.md")
    out = {"title": title, "work_item": None, "datadog": None}
    if n.get("work_item"):
        out["work_item"] = work_item(title, text, ["lab-pipeline", kind, env, component], n.get("work_item_type", "Bug"),
                                     n.get("area_path"), wi_poster)
    key = os.environ.get("DD_API_KEY")
    if n.get("datadog_event", True) and key and site:
        out["datadog"] = poster(f"https://api.{site}/api/v1/events",
                                {"title": title, "text": text, "alert_type": "error",
                                 "tags": [f"env:{env}", f"component:{component}", f"kind:{kind}", "pipeline-health",
                                          "source:azure_devops"], "aggregation_key": f"{env}-{component}-{kind}"},
                                {"DD-API-KEY": key})
    print(f"##vso[task.logissue type=error]{title}: {reason}")
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("summarize")
    s.add_argument("--run-dir", required=True)
    s.add_argument("--env", required=True)
    s.add_argument("--run-id", default=os.environ.get("BUILD_BUILDID", "local"))
    s.add_argument("--records-url")
    s.add_argument("--scope")
    s.add_argument("--out", required=True)
    s.add_argument("--markdown")
    d = sub.add_parser("send")
    d.add_argument("--health", required=True)
    d.add_argument("--site", required=True)
    d.add_argument("--pipeline", default=os.environ.get("BUILD_DEFINITIONNAME", ""))
    a = sub.add_parser("alert")
    a.add_argument("--env", required=True)
    a.add_argument("--component", required=True)
    a.add_argument("--kind", required=True, choices=("quarantine", "rollback-failed", "drift-refused", "rolled-back"))
    a.add_argument("--reason", required=True)
    a.add_argument("--site", default=os.environ.get("DD_SITE", ""))
    sub.add_parser("monitors")
    args = ap.parse_args(argv)
    if args.cmd == "monitors":
        print(json.dumps(MONITOR_ARCHETYPES, indent=2))
        return 0
    if args.cmd == "summarize":
        from tools.changeset.store import open_store

        doc = summarize(Path(args.run_dir), args.env, args.run_id, open_store(args.records_url), args.scope)
        doc["suggested_monitors"] = [m["name"] for m in MONITOR_ARCHETYPES]
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(json.dumps(doc, indent=2, sort_keys=True))
        if args.markdown:
            Path(args.markdown).write_text(markdown(doc))
        print(json.dumps(doc["metrics"], sort_keys=True))
        return 0
    if args.cmd == "send":
        key = os.environ.get("DD_API_KEY")
        if not key:
            print("##vso[task.logissue type=warning]DD_API_KEY not available: pipeline health not sent to Datadog")
            return 0
        if not send(json.loads(Path(args.health).read_text()), args.site, key, args.pipeline):
            print("##vso[task.logissue type=warning]pipeline health event/metrics not accepted by Datadog")
        return 0
    alert(args.env, args.component, args.kind, args.reason, args.site)
    return 0


if __name__ == "__main__":
    sys.exit(main())
