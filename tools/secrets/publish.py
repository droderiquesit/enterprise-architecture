#!/usr/bin/env python3
"""Write Azure-generated secret values from a sensitive Terraform output to their DSV paths (after apply).

    python3 tools/secrets/publish.py --env dev --component obs-telemetry-transport \
        --root observability/lab/telemetry-transport --output generated_secrets
    python3 tools/secrets/publish.py ... --output-json values.json        (tests)

The output is {<secret-name>: "<value>" | {<element>: "<value>", ...}}; each name must be a catalogue secret
(foundation/identity/secrets.yaml) with `source: generated` and `publisher: <component>`. Values are compared and
written (create / update / unchanged) without ever being printed. A null value (e.g. Event Hub mode "existing")
is skipped. Authentication: the deploy agent's managed identity, which foundation-secrets grants create/update on
exactly the generated paths.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.secrets.catalog import load_catalogue  # noqa: E402
from tools.secrets.dsvlib import DsvClient, DsvError, base_url_from, load_env_settings  # noqa: E402


def terraform_output(root: str, name: str):
    proc = subprocess.run(["terraform", f"-chdir={root}", "output", "-json", name], capture_output=True, text=True)
    if proc.returncode != 0:
        # never echo stdout (it would hold values); stderr of `terraform output` carries no values
        raise DsvError(f"terraform output {name} failed: {proc.stderr.strip()[:300]}")
    return json.loads(proc.stdout)


def publish(client: DsvClient, base_path: str, values: dict, catalogue: dict, component: str):
    results = []
    for name, value in sorted(values.items()):
        meta = catalogue.get(name)
        if not meta or meta.get("source") != "generated":
            raise DsvError(f"{name}: not a generated secret in foundation/identity/secrets.yaml")
        if component and meta.get("publisher") != component:
            raise DsvError(f"{name}: published by {meta.get('publisher')}, not {component}")
        if value is None:
            results.append((name, "skipped (null)"))
            continue
        data = {k: str(v) for k, v in value.items()} if isinstance(value, dict) else {"value": str(value)}
        if not all(data.values()):
            raise DsvError(f"{name}: empty value")
        results.append((name, client.write(f"{base_path}/{name}", data, {"managed_by": "tools/secrets/publish.py",
                                                                          "publisher": component or ""})))
    return results


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--env", required=True)
    ap.add_argument("--component", required=True)
    ap.add_argument("--root")
    ap.add_argument("--output", default="generated_secrets")
    ap.add_argument("--output-json", help="read {name: value} from this file instead of terraform output")
    ap.add_argument("--repo", default=".")
    args = ap.parse_args(argv)
    repo = Path(args.repo).resolve()
    try:
        if args.output_json:
            values = json.loads(Path(args.output_json).read_text())
        else:
            if not args.root:
                ap.error("--root or --output-json required")
            values = terraform_output(args.root, args.output)
        if not isinstance(values, dict):
            raise DsvError(f"output {args.output} must be a map of secret name to value")
        settings = load_env_settings(repo, args.env)
        client = DsvClient(base_url_from(settings))
        for name, state in publish(client, settings["base_path"], values, load_catalogue(repo), args.component):
            print(f"{name}: {state}")
    except DsvError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        print(f"##vso[task.logissue type=error]publish.py: {exc}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
