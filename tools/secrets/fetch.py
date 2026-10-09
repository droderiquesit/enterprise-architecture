#!/usr/bin/env python3
"""Resolve Delinea DSV secrets for ONE pipeline step with the agent's managed identity (ADR-0001 section 14).

    # run a command with the component's secret_env (catalog/components.yaml) added to ITS environment only
    python3 tools/secrets/fetch.py exec --env dev --component obs-prereqs -- bash pipelines/scripts/tf-plan.sh ...
    python3 tools/secrets/fetch.py exec --env dev --map DD_API_KEY=datadog-api-key -- python3 tools/report/...

    # Azure DevOps: masked secret variables for later steps of the same job (value only inside the logging command)
    python3 tools/secrets/fetch.py ado --env dev --map DD_API_KEY=datadog-api-key [--map ...]

Map syntax: VAR=<secret-name>[#element][?] (path <name_prefix>/<env>/<name>; `?` = optional, skipped when the
path does not exist) or VAR=dsv://<path>#<element>.
Values are never printed by `exec` (the child inherits them; this process prints names only). `ado` writes
`##vso[task.setvariable variable=VAR;issecret=true]<value>`: Azure DevOps masks the value in all later output.
Only on self-hosted deploy agents: Microsoft-hosted PR builds never call this (pipeline_templates lint).
Exit: 1 when a required secret cannot be resolved (the message names VAR and path, never the value).
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path
from typing import Dict, List, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.secrets.dsvlib import DsvClient, DsvError, base_url_from, load_env_settings, secret_spec  # noqa: E402

NAME_OK = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_")


def mappings(repo: Path, component: str | None, maps: List[str]) -> Dict[str, str]:
    out: Dict[str, str] = {}
    if component:
        from tools.secrets.catalog import secret_env_of

        out.update(secret_env_of(repo, component))
    for m in maps:
        var, sep, spec = m.partition("=")
        if not sep or not var or not spec or set(var) - NAME_OK:
            raise DsvError(f"--map must be VAR=<secret>[#element][?], got variable '{var}'")
        out[var] = spec
    return out


def resolve(client: DsvClient, base_path: str, specs: Dict[str, str]) -> Tuple[Dict[str, str], List[str]]:
    values: Dict[str, str] = {}
    notes: List[str] = []
    cache: Dict[str, dict] = {}
    for var, spec in specs.items():
        path, element, optional = secret_spec(base_path, spec)
        try:
            if path not in cache:
                cache[path] = client.read(path).get("data") or {}
        except DsvError as exc:
            if optional and exc.status == 404:
                notes.append(f"{var}: optional secret {path} not present - not set")
                continue
            raise DsvError(f"{var}: cannot read {path} (HTTP {exc.status})", exc.status) from None
        data = cache[path]
        if element not in data:
            if optional:
                notes.append(f"{var}: optional element {path}#{element} not present - not set")
                continue
            raise DsvError(f"{var}: secret {path} has no element '{element}'")
        v = data[element]
        values[var] = v if isinstance(v, str) else str(v)
    return values, notes


def ado_escape(value: str) -> str:
    """Azure DevOps logging-command data escaping (%, CR, LF)."""
    return value.replace("%", "%AZP25").replace("\r", "%0D").replace("\n", "%0A")


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    cmd: List[str] = []
    if "--" in argv:
        i = argv.index("--")
        argv, cmd = argv[:i], argv[i + 1:]
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=("exec", "ado"))
    ap.add_argument("--env", required=True)
    ap.add_argument("--component", help="use this component's secret_env from catalog/components.yaml")
    ap.add_argument("--map", action="append", default=[], help="VAR=<secret>[#element][?]")
    ap.add_argument("--repo", default=".")
    args = ap.parse_args(argv)
    repo = Path(args.repo).resolve()
    try:
        specs = mappings(repo, args.component, args.map)
        if args.mode == "exec" and not cmd:
            ap.error("exec needs a command after --")
        values: Dict[str, str] = {}
        if specs:
            settings = load_env_settings(repo, args.env)
            client = DsvClient(base_url_from(settings))
            values, notes = resolve(client, settings["base_path"], specs)
            for n in notes:
                print(f"fetch.py: {n}", file=sys.stderr)
            print(f"fetch.py: resolved {', '.join(sorted(values)) or 'nothing'} from DSV", file=sys.stderr)
    except DsvError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        print(f"##vso[task.logissue type=error]fetch.py: {exc}")
        return 1
    if args.mode == "ado":
        for var, value in sorted(values.items()):
            sys.stdout.write(f"##vso[task.setvariable variable={var};issecret=true]{ado_escape(value)}\n")
        return 0
    child_env = dict(os.environ)
    child_env.update(values)
    os.execvpe(cmd[0], cmd, child_env)  # replaces this process: the values live only in the child's environment
    return 0  # pragma: no cover


if __name__ == "__main__":
    sys.exit(main())
