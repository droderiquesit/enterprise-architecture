"""Extract the tag keys / values a Datadog monitor or SLO filters and groups on (best effort, offline, pure).

Supported query syntaxes:
  metric      avg(last_5m):sum:trace.http.request.errors{env:prod,service:orders-api} by {host} > 5
              (also SLO numerator/denominator, formula queries, `IN` / `NOT IN`, `!key:value`, AND/OR, template vars)
  search      logs("service:orders env:prod status:error").index("*").rollup("count").by("service").last("5m") > 10
              trace-analytics(...), rum(...), events(...), audit(...), ci-pipelines(...), error-tracking(...),
              database-monitoring(...), process(...): Datadog search syntax; `@attribute` terms are facets, not tags
  service     "http.can_connect".over("env:prod","service:x").exclude("host:y").by("host","env").last(3).count_by_status()
  composite   referenced monitor ids only (no tags)
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field

SEARCH_FUNCS = ("logs", "trace-analytics", "rum", "events", "audit", "ci-pipelines", "ci-tests", "error-tracking",
                "database-monitoring", "process", "spans", "network")
_SEARCH_CALL = re.compile(r'(?<![A-Za-z0-9_.-])(' + "|".join(re.escape(f) for f in SEARCH_FUNCS) + r')\(\s*"((?:[^"\\]|\\.)*)"\s*\)')
_BY_CALL = re.compile(r'\.by\(\s*((?:"(?:[^"\\]|\\.)*"\s*,?\s*)+)\)')
_OVER_CALL = re.compile(r'\.(over|exclude)\(\s*((?:"(?:[^"\\]|\\.)*"\s*,?\s*)+)\)')
_STR = re.compile(r'"((?:[^"\\]|\\.)*)"')
_METRIC_BY = re.compile(r'\bby\s*\{([^{}]*)\}')
_SCOPE = re.compile(r'\{([^{}]*)\}')
_IN = re.compile(r'([A-Za-z@][A-Za-z0-9_.:/@-]*)\s+(NOT\s+)?IN\s*\(([^)]*)\)', re.IGNORECASE)
_SEARCH_TERM = re.compile(r'(-|NOT\s+)?(@?[A-Za-z][A-Za-z0-9_.\-/]*):(\((?:[^()]*)\)|"(?:[^"\\]|\\.)*"|[^\s()]+)')


@dataclass
class TagUse:
    key: str
    value: str | None          # None = group-by / existence
    usage: str                 # filter | negated | group_by | over | exclude
    syntax: str                # metric | search:<func> | service_check | monitor_tag
    attribute: bool = False    # @facet (log/span attribute), not a tag


@dataclass
class Extraction:
    uses: list[TagUse] = field(default_factory=list)
    template_variables: set[str] = field(default_factory=set)
    unparsed: list[str] = field(default_factory=list)


def _norm_key(k: str) -> str:
    return k.strip().lower()


def _scope_items(scope: str) -> list[str]:
    # split AND / OR / commas outside parentheses
    s = re.sub(r"\s+(AND|OR)\s+", ",", scope, flags=re.IGNORECASE)
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    out.append(cur)
    return [x.strip().strip("()").strip() for x in out if x.strip()]


def parse_metric(query: str, ex: Extraction, syntax: str = "metric") -> None:
    for m in _METRIC_BY.finditer(query):
        for raw_key in m.group(1).split(","):
            k = raw_key.strip()
            if k:
                ex.uses.append(TagUse(_norm_key(k), None, "group_by", syntax))
    rest = _METRIC_BY.sub(" ", query)
    for m in _SCOPE.finditer(rest):
        scope = m.group(1)
        for im in _IN.finditer(scope):
            neg = bool(im.group(2))
            for raw_value in im.group(3).split(","):
                v = raw_value.strip()
                if v:
                    ex.uses.append(TagUse(_norm_key(im.group(1)), v, "negated" if neg else "filter", syntax))
        scope = _IN.sub(",", scope)
        for raw_item in _scope_items(scope):
            neg, item = False, raw_item
            if item.startswith("!"):
                neg, item = True, item[1:].strip()
            elif item.upper().startswith("NOT "):
                neg, item = True, item[4:].strip()
            if item in ("*", "") or item.startswith("$"):
                if item.startswith("$"):
                    ex.template_variables.add(item[1:].split(".")[0])
                continue
            if ":" in item:
                k, v = item.split(":", 1)
                if v.startswith("$"):
                    ex.template_variables.add(v[1:].split(".")[0])
                    v = None
                ex.uses.append(TagUse(_norm_key(k), v, "negated" if neg else "filter", syntax))
            else:
                ex.uses.append(TagUse(item.lower(), None, "negated" if neg else "filter", syntax))


def parse_search(search: str, ex: Extraction, syntax: str) -> None:
    for m in _SEARCH_TERM.finditer(search):
        neg = bool(m.group(1))
        key = m.group(2)
        raw = m.group(3)
        attribute = key.startswith("@")
        values = [raw]
        if raw.startswith("("):
            values = [v.strip().strip('"') for v in re.split(r"\s+OR\s+|\s+AND\s+", raw[1:-1], flags=re.IGNORECASE) if v.strip()]
        elif raw.startswith('"'):
            values = [raw[1:-1]]
        for raw_value in values:
            v = raw_value
            if v.startswith("$"):
                ex.template_variables.add(v[1:].split(".")[0])
                v = None
            ex.uses.append(TagUse(key if attribute else _norm_key(key), v, "negated" if neg else "filter", syntax, attribute))


def parse_query(query: str, monitor_type: str = "") -> Extraction:
    ex = Extraction()
    if not query:
        return ex
    q = query.strip()
    if monitor_type == "composite":
        return ex
    searched = False
    for m in _SEARCH_CALL.finditer(q):
        searched = True
        parse_search(m.group(2).replace('\\"', '"'), ex, f"search:{m.group(1)}")
    if searched:
        for m in _BY_CALL.finditer(q):
            for s in _STR.findall(m.group(1)):
                for raw_key in s.split(","):
                    k = raw_key.strip()
                    if k:
                        ex.uses.append(TagUse(k if k.startswith("@") else _norm_key(k), None, "group_by", "search", k.startswith("@")))
        return ex
    if monitor_type == "service check" or ".over(" in q:
        for m in _OVER_CALL.finditer(q):
            for s in _STR.findall(m.group(2)):
                if s == "*":
                    continue
                if ":" in s:
                    k, v = s.split(":", 1)
                    ex.uses.append(TagUse(_norm_key(k), v, "filter" if m.group(1) == "over" else "negated", "service_check"))
        for m in _BY_CALL.finditer(q):
            for s in _STR.findall(m.group(1)):
                ex.uses.append(TagUse(_norm_key(s), None, "group_by", "service_check"))
        return ex
    if "{" in q:
        parse_metric(q, ex)
        return ex
    ex.unparsed.append(q[:200])
    return ex


def monitor_extraction(mon: dict) -> Extraction:
    ex = parse_query(mon.get("query") or "", (mon.get("type") or "").lower())
    for t in mon.get("tags") or []:
        k, _, v = str(t).partition(":")
        ex.uses.append(TagUse(_norm_key(k), v or None, "monitor_tag", "monitor_tag"))
    # variables (formula & functions monitors): options.variables[].query / .search.query
    variables = (mon.get("options") or {}).get("variables") or []
    if variables:
        ex.unparsed = [u for u in ex.unparsed if not u.startswith("formula(")]
    for var in variables:
        if isinstance(var.get("query"), str):
            parse_metric(var["query"], ex)
        search = (var.get("search") or {}).get("query")
        if isinstance(search, str):
            parse_search(search, ex, f"search:{var.get('data_source', 'search')}")
        for g in var.get("group_by") or []:
            f = g.get("facet")
            if f:
                ex.uses.append(TagUse(f if f.startswith("@") else _norm_key(f), None, "group_by", "search", f.startswith("@")))
    return ex


def slo_extraction(slo: dict) -> Extraction:
    ex = Extraction()
    q = slo.get("query") or {}
    for part in ("numerator", "denominator"):
        if q.get(part):
            parse_metric(q[part], ex, "metric")
    ts = ((slo.get("sli_specification") or {}).get("time_slice") or {}).get("query") or {}
    for item in ts.get("queries") or []:
        if isinstance(item.get("query"), str):
            parse_metric(item["query"], ex, "metric")
    for t in slo.get("tags") or []:
        k, _, v = str(t).partition(":")
        ex.uses.append(TagUse(_norm_key(k), v or None, "monitor_tag", "slo_tag"))
    for g in slo.get("groups") or []:
        if ":" in str(g):
            k, v = str(g).split(":", 1)
            ex.uses.append(TagUse(_norm_key(k), v, "filter", "slo_group"))
    return ex
