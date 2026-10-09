"""A small evaluator for the subset of the Azure Pipelines expression grammar the generator emits.

Supported (semantics per https://learn.microsoft.com/azure/devops/pipelines/process/expressions):
  literals        'string' (quote doubled to escape), true/false, null, numbers
  functions       and, or, not, eq, ne, in, notIn, contains, startsWith, endsWith,
                  succeeded, failed, canceled, always, succeededOrFailed
  property access dependencies.<Stage>.result
                  dependencies.<Stage>.outputs['<job>.<step>.<var>']
                  stageDependencies.<Stage>.<Job>.outputs['<step>.<var>']
                  dependencies.<Job>.outputs['<step>.<var>'] / .result (job scope)
                  variables['name'] / variables.name
String comparison is ordinal-ignore-case, as in Azure Pipelines. Missing values evaluate to null,
which compares equal only to null/'' — exactly why an unselected/blocked stage output never
matches 'true'.

The evaluator is used by tests to prove that the generated stage conditions behave correctly for
upstream results Succeeded / SucceededWithIssues / Skipped / Failed / Canceled.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

TOKEN_RE = re.compile(r"""
    (?P<ws>\s+)
  | (?P<str>'(?:[^']|'')*')
  | (?P<num>-?\d+(?:\.\d+)?)
  | (?P<ident>[A-Za-z_][A-Za-z0-9_]*)
  | (?P<punct>[(),.\[\]])
""", re.VERBOSE)

RESULTS = ("Succeeded", "SucceededWithIssues", "Skipped", "Failed", "Canceled")


class ExpressionError(Exception):
    pass


@dataclass
class EvalContext:
    """`dependencies`: {name: {"result": str, "outputs": {key: value}}}.
    `stage_dependencies`: {stage: {job: {"result": str, "outputs": {key: value}}}}.
    `run_canceled`: the run was canceled. `variables`: pipeline variables."""

    dependencies: Dict[str, Dict[str, Any]] = field(default_factory=dict)
    stage_dependencies: Dict[str, Dict[str, Dict[str, Any]]] = field(default_factory=dict)
    variables: Dict[str, Any] = field(default_factory=dict)
    run_canceled: bool = False


def tokenize(text: str) -> List[tuple]:
    pos = 0
    tokens = []
    while pos < len(text):
        m = TOKEN_RE.match(text, pos)
        if not m:
            raise ExpressionError(f"unexpected character at {pos}: {text[pos:pos + 20]!r}")
        pos = m.end()
        kind = m.lastgroup
        if kind == "ws":
            continue
        tokens.append((kind, m.group(kind)))
    return tokens


# AST nodes: ("lit", value) | ("call", name, [args]) | ("prop", [segments])
class Parser:
    def __init__(self, text: str):
        self.tokens = tokenize(text)
        self.i = 0

    def peek(self, offset: int = 0):
        j = self.i + offset
        return self.tokens[j] if j < len(self.tokens) else (None, None)

    def take(self, kind=None, value=None):
        tok = self.peek()
        if tok[0] is None or (kind and tok[0] != kind) or (value and tok[1] != value):
            raise ExpressionError(f"expected {value or kind}, got {tok[1]!r}")
        self.i += 1
        return tok

    def parse(self):
        node = self.expr()
        if self.i != len(self.tokens):
            raise ExpressionError(f"trailing tokens: {self.tokens[self.i:]}")
        return node

    def expr(self):
        kind, val = self.peek()
        if kind == "str":
            self.i += 1
            return ("lit", val[1:-1].replace("''", "'"))
        if kind == "num":
            self.i += 1
            return ("lit", float(val) if "." in val else int(val))
        if kind == "ident":
            low = val.lower()
            if low in ("true", "false") and self.peek(1)[1] != "(":
                self.i += 1
                return ("lit", low == "true")
            if low == "null":
                self.i += 1
                return ("lit", None)
            if self.peek(1)[1] == "(":
                self.i += 2
                args = []
                if self.peek()[1] != ")":
                    args.append(self.expr())
                    while self.peek()[1] == ",":
                        self.i += 1
                        args.append(self.expr())
                self.take("punct", ")")
                return ("call", low, args)
            return self.prop()
        raise ExpressionError(f"unexpected token {val!r}")

    def prop(self):
        segs = [self.take("ident")[1]]
        while True:
            tok = self.peek()
            if tok[1] == ".":
                self.i += 1
                segs.append(self.take("ident")[1])
            elif tok[1] == "[":
                self.i += 1
                k = self.take("str")[1]
                segs.append(k[1:-1].replace("''", "'"))
                self.take("punct", "]")
            else:
                return ("prop", segs)


def _norm(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if v is None:
        return None
    return str(v)


def _eq(a, b) -> bool:
    if a is None or b is None:
        return (a in (None, "")) and (b in (None, ""))
    if isinstance(a, bool) or isinstance(b, bool):
        return _truthy(a) == _truthy(b)
    return _norm(a).lower() == _norm(b).lower()


def _truthy(v) -> bool:
    if isinstance(v, bool):
        return v
    if v is None:
        return False
    if isinstance(v, (int, float)):
        return v != 0
    return v != ""


class Evaluator:
    def __init__(self, ctx: EvalContext):
        self.ctx = ctx

    def resolve(self, segs: List[str]):
        root = segs[0]
        if root == "variables":
            return self.ctx.variables.get(segs[1]) if len(segs) > 1 else None
        if root == "dependencies":
            dep = self.ctx.dependencies.get(segs[1]) if len(segs) > 1 else None
            if dep is None:
                return None
            if len(segs) == 3 and segs[2] == "result":
                return dep.get("result")
            if len(segs) == 4 and segs[2] == "outputs":
                return dep.get("outputs", {}).get(segs[3])
            return None
        if root == "stageDependencies":
            if len(segs) == 5 and segs[3] == "outputs":
                job = self.ctx.stage_dependencies.get(segs[1], {}).get(segs[2], {})
                return job.get("outputs", {}).get(segs[4])
            if len(segs) == 4 and segs[3] == "result":
                return self.ctx.stage_dependencies.get(segs[1], {}).get(segs[2], {}).get("result")
            return None
        raise ExpressionError(f"unsupported context '{root}'")

    def ev(self, node):
        t = node[0]
        if t == "lit":
            return node[1]
        if t == "prop":
            return self.resolve(node[1])
        name, args = node[1], node[2]
        if name == "and":
            if len(args) < 2:
                raise ExpressionError("and() needs at least 2 arguments")
            return all(_truthy(self.ev(a)) for a in args)
        if name == "or":
            if len(args) < 2:
                raise ExpressionError("or() needs at least 2 arguments")
            return any(_truthy(self.ev(a)) for a in args)
        if name == "not":
            return not _truthy(self.ev(args[0]))
        if name == "eq":
            return _eq(self.ev(args[0]), self.ev(args[1]))
        if name == "ne":
            return not _eq(self.ev(args[0]), self.ev(args[1]))
        if name == "in":
            first = self.ev(args[0])
            return any(_eq(first, self.ev(a)) for a in args[1:])
        if name == "notin":
            first = self.ev(args[0])
            return not any(_eq(first, self.ev(a)) for a in args[1:])
        if name == "contains":
            a, b = _norm(self.ev(args[0])) or "", _norm(self.ev(args[1])) or ""
            return b.lower() in a.lower()
        if name == "startswith":
            return (_norm(self.ev(args[0])) or "").lower().startswith((_norm(self.ev(args[1])) or "").lower())
        if name == "endswith":
            return (_norm(self.ev(args[0])) or "").lower().endswith((_norm(self.ev(args[1])) or "").lower())
        if name == "canceled":
            return self.ctx.run_canceled
        if name == "always":
            return True
        deps = [d.get("result") for d in self.ctx.dependencies.values()]
        if name == "succeeded":
            return not self.ctx.run_canceled and all(r in ("Succeeded", "SucceededWithIssues") for r in deps)
        if name == "failed":
            return not self.ctx.run_canceled and any(r == "Failed" for r in deps)
        if name == "succeededorfailed":
            return not self.ctx.run_canceled
        raise ExpressionError(f"unsupported function {name}()")


def parse(text: str):
    return Parser(text).parse()


def evaluate(text: str, ctx: EvalContext) -> bool:
    return _truthy(Evaluator(ctx).ev(parse(text)))


def functions_used(text: str) -> set:
    found = set()

    def walk(node):
        if node[0] == "call":
            found.add(node[1])
            for a in node[2]:
                walk(a)

    walk(parse(text))
    return found


def top_level_conjuncts(text: str) -> Optional[List[str]]:
    """Function names of the direct arguments of a top-level and(...)."""
    node = parse(text)
    if node[0] != "call" or node[1] != "and":
        return None
    return [a[1] if a[0] == "call" else a[0] for a in node[2]]
