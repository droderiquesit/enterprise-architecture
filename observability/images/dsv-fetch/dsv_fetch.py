#!/usr/bin/env python3
"""dsv-fetch - resolve Delinea DevOps Secrets Vault (DSV) references for containers and agents without our code.

Standard library only (Python >= 3.11; the image uses 3.13, the Datadog Agent ships an embedded 3.13). Part of the
portable observability package (ADR-0001 §14). Never prints, logs or writes a secret value anywhere except the
requested output files (mode 0400 by default) or, for ``agent-backend``, the Datadog Agent's stdout pipe.

Commands
--------
dsv-fetch init --out DIR --format files|env-yaml|dotenv [--map NAME=dsv://path#element]... [--map-file FILE.json]
               [--from-env] [--env-yaml-name fluentbit-env.yaml] [--dotenv-name .env] [--file-mode 0400] [--config FILE.json]
    files     DIR/NAME per secret (exact bytes, no trailing newline), e.g. for the OTel collector ``${file:DIR/NAME}``
    env-yaml  DIR/<env-yaml-name>: a Fluent Bit YAML ``env:`` section {NAME: value}; the Fluent Bit main config lists the
              file under ``includes:`` and references ``${NAME}``
    dotenv    DIR/<dotenv-name>: NAME="value" lines (systemd EnvironmentFile / docker --env-file compatible for
              values without quotes/newlines; values with newlines are rejected)
    All references are resolved before anything is written; exit 1 if any fails (stderr names NAME only).

dsv-fetch agent-backend [--config FILE.json]
    Datadog Agent ``secret_backend_command`` protocol: stdin ``{"version": "1.0", "secrets": ["dsv://..."]}`` ->
    stdout ``{"<handle>": {"value": "...", "error": null}}``. Per-handle failures are reported in ``error`` (exit 0);
    a malformed request exits 1. Configure ``api_key: ENC[dsv://eh/dev/datadog-api-key#value]``.

dsv-fetch install --dest PATH [--python /opt/datadog-agent/embedded/bin/python3] [--owner dd-agent]
    Writes a copy of this script to PATH with the given interpreter shebang, mode 0500 (owner read+execute only) and,
    when running as root, the given owner - exactly what the Agent requires of ``secret_backend_command`` (owned by the
    Agent user, no group/other rights). Used by VM/VMSS bootstrap scripts and by the AKS agent init container.

dsv-fetch version

Environment (or the same keys in ``--config FILE.json``; the environment wins)
---------------------------------------------------------------------------------
DSV_AUTH            azure (default) | client_credentials (DSV_CLIENT_ID + DSV_CLIENT_SECRET; local/test only)
DSV_TENANT, DSV_TLD base URL https://{DSV_TENANT}.secretsvaultcloud.{DSV_TLD:-com}/v1 ; DSV_BASE_URL overrides
                    (http:// only for loopback hosts or DSV_ALLOW_INSECURE_HTTP=true)
DSV_TIMEOUT_SECONDS per request (default 5) ; DSV_MAX_ATTEMPTS transient-failure attempts (default 3)
AZURE_CLIENT_ID     user-assigned managed identity client id
Managed identity token for https://management.azure.com/ (first match wins):
  AZURE_FEDERATED_TOKEN_FILE (+ AZURE_TENANT_ID, AZURE_AUTHORITY_HOST)  AKS workload identity client-assertion exchange
  IDENTITY_ENDPOINT + IDENTITY_HEADER                                    App Service / Functions / Container Apps (2019-08-01)
  IMDS http://169.254.169.254 (AZURE_POD_IDENTITY_AUTHORITY_HOST overrides) VM / VMSS / Batch / ACI / AKS node (2018-02-01)

Exit codes: 0 ok, 1 resolution failure / malformed agent request, 2 usage or configuration error.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import random
import re
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

__version__ = "1.0.0"

REF_PREFIX = "dsv://"
ARM_RESOURCE = "https://management.azure.com/"
ARM_SCOPE = "https://management.azure.com/.default"
IMDS_DEFAULT = "http://169.254.169.254"
MAX_AGENT_INPUT = 1024 * 1024
MAX_RESPONSE = 4 * 1024 * 1024
CONFIG_KEYS = (
    "DSV_AUTH",
    "DSV_TENANT",
    "DSV_TLD",
    "DSV_BASE_URL",
    "DSV_ALLOW_INSECURE_HTTP",
    "DSV_CLIENT_ID",
    "DSV_CLIENT_SECRET",
    "DSV_TIMEOUT_SECONDS",
    "DSV_MAX_ATTEMPTS",
    "AZURE_CLIENT_ID",
    "AZURE_TENANT_ID",
    "AZURE_AUTHORITY_HOST",
    "AZURE_FEDERATED_TOKEN_FILE",
    "IDENTITY_ENDPOINT",
    "IDENTITY_HEADER",
    "AZURE_POD_IDENTITY_AUTHORITY_HOST",
)

_PATH_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]*(/[A-Za-z0-9_.:-]+)*$")
_ELEMENT_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
_ENV_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_FILE_NAME_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]*$")
_TRUE = {"1", "true", "yes", "on"}


class UsageError(Exception):
    """Bad arguments or configuration (exit 2)."""


class FetchError(Exception):
    """A reference could not be resolved. The message is value-free (status code / error class)."""

    def __init__(self, reason: str, status: int | None = None) -> None:
        super().__init__(reason)
        self.reason = reason
        self.status = status


# ------------------------------------------------------------------------------------------- references
def parse_ref(ref: str) -> tuple[str, str]:
    if not isinstance(ref, str) or not ref.startswith(REF_PREFIX):
        raise FetchError("not a dsv:// reference")
    path, _, element = ref[len(REF_PREFIX) :].partition("#")
    path = path.strip("/")
    element = element or "value"
    if not path or ".." in path.split("/") or not _PATH_RE.match(path) or not _ELEMENT_RE.match(element):
        raise FetchError("malformed dsv:// reference")
    return path, element


# ------------------------------------------------------------------------------------------------- http
class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


_NO_PROXY_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect)  # IMDS / IDENTITY_ENDPOINT: never via a proxy
_ENV_PROXY_OPENER = urllib.request.build_opener(_NoRedirect)  # DSV / Entra: honour HTTPS_PROXY / NO_PROXY


def _http(
    method: str,
    url: str,
    *,
    headers: dict[str, str] | None = None,
    body: bytes | None = None,
    timeout: float,
    attempts: int,
    retry_status: frozenset[int] = frozenset({429}),
    proxy: bool = True,
) -> dict:
    opener = _ENV_PROXY_OPENER if proxy else _NO_PROXY_OPENER
    if urllib.parse.urlsplit(url).scheme not in ("http", "https"):
        raise FetchError("only http(s) URLs are allowed")
    for attempt in range(1, max(1, attempts) + 1):
        hdrs = {"Accept": "application/json", "User-Agent": f"dsv-fetch/{__version__}", **(headers or {})}
        req = urllib.request.Request(url, data=body, method=method, headers=hdrs)  # noqa: S310 - scheme checked above
        try:
            with opener.open(req, timeout=timeout) as resp:
                raw = resp.read(MAX_RESPONSE + 1)
            if len(raw) > MAX_RESPONSE:
                raise FetchError("response too large")
            try:
                doc = json.loads(raw)
            except ValueError:
                raise FetchError("response is not JSON") from None
            if not isinstance(doc, dict):
                raise FetchError("response is not a JSON object")
            return doc
        except urllib.error.HTTPError as exc:
            exc.close()
            code = exc.code
            if not (code >= 500 or code in retry_status):
                raise FetchError(f"HTTP {code}", code) from None
            if attempt >= attempts:
                raise FetchError(f"HTTP {code} after {attempts} attempts", code) from None
        except (urllib.error.URLError, OSError) as exc:  # connection refused/reset, DNS, timeout
            if attempt >= attempts:
                kind = type(getattr(exc, "reason", exc)).__name__
                raise FetchError(f"unreachable ({kind})") from None
        time.sleep(random.uniform(0, min(2.0, 0.25 * 2 ** (attempt - 1))))
    raise FetchError("unreachable")


# --------------------------------------------------------------------------------------------- settings
def load_settings(config_file: str | None, environ: dict[str, str] | None = None) -> dict[str, str]:
    env = dict(os.environ if environ is None else environ)
    cfg: dict[str, str] = {}
    if config_file:
        try:
            with open(config_file, encoding="utf-8") as fh:
                doc = json.load(fh)
        except (OSError, ValueError) as exc:
            raise UsageError(f"cannot read --config file ({type(exc).__name__})") from None
        if not isinstance(doc, dict):
            raise UsageError("--config must be a JSON object")
        cfg = {k: str(v) for k, v in doc.items() if k in CONFIG_KEYS and v is not None}
    for key in CONFIG_KEYS:
        if env.get(key):
            cfg[key] = env[key]
    return cfg


def _is_loopback(host: str) -> bool:
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def _float(s: dict[str, str], key: str, default: float, minimum: float) -> float:
    try:
        value = float(s.get(key) or default)
    except ValueError:
        raise UsageError(f"{key} must be a number") from None
    if value < minimum:
        raise UsageError(f"{key} must be >= {minimum:g}")
    return value


class DsvClient:
    def __init__(self, settings: dict[str, str]) -> None:
        self.s = settings
        self.auth = (settings.get("DSV_AUTH") or "azure").strip().lower()
        if self.auth not in ("azure", "client_credentials"):
            raise UsageError("DSV_AUTH must be azure or client_credentials for dsv-fetch")
        base = (settings.get("DSV_BASE_URL") or "").strip().rstrip("/")
        if not base and settings.get("DSV_TENANT"):
            base = f"https://{settings['DSV_TENANT'].strip()}.secretsvaultcloud.{(settings.get('DSV_TLD') or 'com').strip()}/v1"
        if not base:
            raise UsageError("DSV_TENANT or DSV_BASE_URL must be set")
        parts = urllib.parse.urlsplit(base)
        allow_http = (settings.get("DSV_ALLOW_INSECURE_HTTP") or "").strip().lower() in _TRUE
        if parts.scheme not in ("https", "http") or not parts.hostname:
            raise UsageError("DSV_BASE_URL must be an absolute https URL")
        if parts.scheme == "http" and not (allow_http or _is_loopback(parts.hostname)):
            raise UsageError("DSV_BASE_URL must use https (http only for loopback or DSV_ALLOW_INSECURE_HTTP=true)")
        if self.auth == "client_credentials" and not (settings.get("DSV_CLIENT_ID") and settings.get("DSV_CLIENT_SECRET")):
            raise UsageError("DSV_AUTH=client_credentials requires DSV_CLIENT_ID and DSV_CLIENT_SECRET")
        self.base = base
        self.timeout = _float(settings, "DSV_TIMEOUT_SECONDS", 5.0, 0.1)
        self.attempts = int(_float(settings, "DSV_MAX_ATTEMPTS", 3, 1))
        self._token: str | None = None
        self._cache: dict[str, dict] = {}
        self.stats = {"entra_requests": 0, "token_requests": 0, "secret_requests": 0}

    # ---------------------------------------------------------------------------------- managed identity
    def entra_token(self) -> str:
        s = self.s
        client_id = (s.get("AZURE_CLIENT_ID") or "").strip()
        self.stats["entra_requests"] += 1
        try:
            if s.get("AZURE_FEDERATED_TOKEN_FILE"):
                tenant = (s.get("AZURE_TENANT_ID") or "").strip()
                if not (tenant and client_id):
                    raise UsageError("workload identity needs AZURE_TENANT_ID and AZURE_CLIENT_ID")
                authority = (s.get("AZURE_AUTHORITY_HOST") or "https://login.microsoftonline.com/").rstrip("/")
                host = urllib.parse.urlsplit(authority)
                if host.scheme != "https" and not _is_loopback(host.hostname or ""):
                    raise UsageError("AZURE_AUTHORITY_HOST must be https")
                try:
                    with open(s["AZURE_FEDERATED_TOKEN_FILE"], encoding="utf-8") as fh:
                        assertion = fh.read().strip()
                except OSError as exc:
                    raise FetchError(f"federated token file unreadable ({type(exc).__name__})") from None
                form = urllib.parse.urlencode(
                    {
                        "grant_type": "client_credentials",
                        "client_id": client_id,
                        "scope": ARM_SCOPE,
                        "client_assertion_type": "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
                        "client_assertion": assertion,
                    }
                ).encode()
                doc = _http(
                    "POST",
                    f"{authority}/{urllib.parse.quote(tenant)}/oauth2/v2.0/token",
                    headers={"Content-Type": "application/x-www-form-urlencoded"},
                    body=form,
                    timeout=self.timeout,
                    attempts=self.attempts,
                )
            elif s.get("IDENTITY_ENDPOINT") and s.get("IDENTITY_HEADER"):
                q = {"api-version": "2019-08-01", "resource": ARM_RESOURCE}
                if client_id:
                    q["client_id"] = client_id
                doc = _http(
                    "GET",
                    f"{s['IDENTITY_ENDPOINT']}?{urllib.parse.urlencode(q)}",
                    headers={"X-IDENTITY-HEADER": s["IDENTITY_HEADER"]},
                    timeout=self.timeout,
                    attempts=self.attempts,
                    proxy=False,
                )
            else:
                imds = (s.get("AZURE_POD_IDENTITY_AUTHORITY_HOST") or IMDS_DEFAULT).rstrip("/")
                q = {"api-version": "2018-02-01", "resource": ARM_RESOURCE}
                if client_id:
                    q["client_id"] = client_id
                doc = _http(
                    "GET",
                    f"{imds}/metadata/identity/oauth2/token?{urllib.parse.urlencode(q)}",
                    headers={"Metadata": "true"},
                    timeout=self.timeout,
                    attempts=max(self.attempts, 3),
                    retry_status=frozenset({404, 410, 429}),  # IMDS: identity not yet assigned / transient
                    proxy=False,
                )
        except FetchError as exc:
            raise FetchError(f"managed identity token unavailable ({exc.reason})", exc.status) from None
        token = doc.get("access_token")
        if not isinstance(token, str) or not token:
            raise FetchError("managed identity token response malformed")
        return token

    # ----------------------------------------------------------------------------------------------- dsv
    def access_token(self) -> str:
        if self._token:
            return self._token  # short-lived process: one DSV token (1 h) per run
        if self.auth == "client_credentials":
            body = {"grant_type": "client_credentials", "client_id": self.s["DSV_CLIENT_ID"], "client_secret": self.s["DSV_CLIENT_SECRET"]}
        else:
            body = {"grant_type": "azure", "jwt": self.entra_token()}
        self.stats["token_requests"] += 1
        try:
            doc = _http(
                "POST",
                f"{self.base}/token",
                headers={"Content-Type": "application/json"},
                body=json.dumps(body).encode(),
                timeout=self.timeout,
                attempts=self.attempts,
            )
        except FetchError as exc:
            raise FetchError(f"DSV authentication failed ({exc.reason})", exc.status) from None
        token = doc.get("accessToken")
        if not isinstance(token, str) or not token:
            raise FetchError("DSV token response malformed")
        self._token = token
        return token

    def secret_data(self, path: str) -> dict:
        if path in self._cache:
            return self._cache[path]
        token = self.access_token()
        self.stats["secret_requests"] += 1
        try:
            doc = _http(
                "GET",
                f"{self.base}/secrets/{urllib.parse.quote(path, safe='/')}",
                headers={"Authorization": f"Bearer {token}"},
                timeout=self.timeout,
                attempts=self.attempts,
            )
        except FetchError as exc:
            reason = {401: "unauthorized, ", 403: "access denied, ", 404: "not found, "}.get(exc.status or 0, "")
            raise FetchError(f"DSV secret read failed ({reason}{exc.reason})", exc.status) from None
        data = doc.get("data")
        if not isinstance(data, dict):
            raise FetchError("DSV secret response malformed")
        self._cache[path] = data
        return data

    def resolve(self, ref: str) -> str:
        path, element = parse_ref(ref)
        data = self.secret_data(path)
        if element not in data or data[element] is None:
            raise FetchError("element missing in DSV secret")
        value = data[element]
        return value if isinstance(value, str) else json.dumps(value)


# ------------------------------------------------------------------------------------------------- init
def _collect_maps(args: argparse.Namespace) -> dict[str, str]:
    maps: dict[str, str] = {}
    if args.map_file:
        try:
            with open(args.map_file, encoding="utf-8") as fh:
                doc = json.load(fh)
        except (OSError, ValueError) as exc:
            raise UsageError(f"cannot read --map-file ({type(exc).__name__})") from None
        if not isinstance(doc, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in doc.items()):
            raise UsageError('--map-file must be a JSON object {"NAME": "dsv://..."}')
        maps.update(doc)
    if args.from_env:
        maps.update({k: v for k, v in os.environ.items() if v.startswith(REF_PREFIX) and not k.startswith("DSV_")})
    for item in args.map or []:
        name, sep, ref = item.partition("=")
        if not sep:
            raise UsageError("--map must be NAME=dsv://path#element")
        maps[name] = ref
    if not maps:
        raise UsageError("nothing to fetch: give --map, --map-file or --from-env")
    name_re = _FILE_NAME_RE if args.format == "files" else _ENV_NAME_RE
    for name, ref in maps.items():
        if not name_re.match(name):
            raise UsageError(f"invalid NAME {name!r} for --format {args.format}")
        if not ref.startswith(REF_PREFIX):
            raise UsageError(f"{name}: value must be a dsv:// reference")
    return maps


def _write_atomic(directory: str, name: str, data: bytes, mode: int) -> None:
    fd, tmp = tempfile.mkstemp(prefix=".dsv-fetch-", dir=directory)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, os.path.join(directory, name))
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _yaml_scalar(value: str) -> str:
    # A JSON string is a valid YAML double-quoted scalar (\", \\, \uXXXX escapes).
    return json.dumps(value, ensure_ascii=True)


def _dotenv_value(name: str, value: str) -> str:
    if "\n" in value or "\r" in value or "\0" in value:
        raise FetchError(f"value of {name} contains a newline; not representable in dotenv")
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("`", "\\`") + '"'


def cmd_init(args: argparse.Namespace) -> int:
    maps = _collect_maps(args)
    try:
        mode = int(args.file_mode, 8)
    except ValueError:
        raise UsageError("--file-mode must be octal (e.g. 0400)") from None
    if mode & 0o333 or not mode & 0o400:
        raise UsageError("--file-mode must be read-only for the owner (0400, 0440 or 0444)")
    client = DsvClient(load_settings(args.config))
    values: dict[str, str] = {}
    failures: list[str] = []
    for name in sorted(maps):
        try:
            values[name] = client.resolve(maps[name])
        except FetchError as exc:
            failures.append(f"{name}: {exc.reason}")
    if failures:
        for f in failures:
            print(f"dsv-fetch: {f}", file=sys.stderr)
        print(f"dsv-fetch: {len(failures)} of {len(maps)} reference(s) failed; nothing written", file=sys.stderr)
        return 1
    out = args.out
    os.makedirs(out, mode=0o700, exist_ok=True)
    try:
        if args.format == "files":
            for name, value in values.items():
                _write_atomic(out, name, value.encode(), mode)
            written = sorted(values)
        elif args.format == "env-yaml":
            text = "# written by dsv-fetch - Fluent Bit YAML env section; do not edit\nenv:\n" + "".join(
                f"  {n}: {_yaml_scalar(v)}\n" for n, v in values.items()
            )
            _write_atomic(out, args.env_yaml_name, text.encode(), mode)
            written = [args.env_yaml_name]
        else:
            text = "".join(f"{n}={_dotenv_value(n, v)}\n" for n, v in values.items())
            _write_atomic(out, args.dotenv_name, text.encode(), mode)
            written = [args.dotenv_name]
    except FetchError as exc:
        print(f"dsv-fetch: {exc.reason}", file=sys.stderr)
        return 1
    print(
        json.dumps({"dsv_fetch": "init", "format": args.format, "out": out, "names": sorted(values), "files": written, "mode": f"{mode:04o}"}), file=sys.stderr
    )
    return 0


# ---------------------------------------------------------------------------------------- agent backend
def cmd_agent_backend(args: argparse.Namespace) -> int:
    raw = sys.stdin.buffer.read(MAX_AGENT_INPUT + 1)
    if len(raw) > MAX_AGENT_INPUT:
        print("dsv-fetch: agent request too large", file=sys.stderr)
        return 1
    try:
        req = json.loads(raw)
        version = str(req["version"])
        handles = req["secrets"]
        if not version.startswith("1.") or not isinstance(handles, list) or not all(isinstance(h, str) for h in handles):
            raise ValueError
    except (ValueError, KeyError, TypeError):
        print('dsv-fetch: malformed agent request (expected {"version":"1.0","secrets":[...]})', file=sys.stderr)
        return 1
    out: dict[str, dict[str, str | None]] = {}
    client: DsvClient | None = None
    setup_error: str | None = None
    try:
        client = DsvClient(load_settings(args.config))
    except UsageError as exc:
        setup_error = f"dsv-fetch configuration error: {exc}"
    for handle in handles:
        if setup_error or client is None:
            out[handle] = {"value": None, "error": setup_error}
            continue
        try:
            out[handle] = {"value": client.resolve(handle), "error": None}
        except FetchError as exc:
            out[handle] = {"value": None, "error": exc.reason}
    sys.stdout.write(json.dumps(out))
    sys.stdout.flush()
    return 0


# ------------------------------------------------------------------------------------------------ install
def cmd_install(args: argparse.Namespace) -> int:
    with open(os.path.abspath(__file__), encoding="utf-8") as fh:
        source = fh.read()
    lines = source.split("\n", 1)
    body = lines[1] if lines[0].startswith("#!") else source
    if not os.path.isabs(args.python) or any(c.isspace() for c in args.python):
        raise UsageError("--python must be an absolute interpreter path without spaces")
    dest = os.path.abspath(args.dest)
    directory = os.path.dirname(dest)
    os.makedirs(directory, mode=0o755, exist_ok=True)
    uid = gid = -1
    if args.owner:
        import pwd  # POSIX only, needed only here

        try:
            entry = pwd.getpwnam(args.owner)
        except KeyError:
            raise UsageError(f"unknown user {args.owner!r}") from None
        uid, gid = entry.pw_uid, entry.pw_gid
    fd, tmp = tempfile.mkstemp(prefix=".dsv-fetch-", dir=directory)
    try:
        os.fchmod(fd, 0o500)
        if uid != -1:
            os.fchown(fd, uid, gid)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(f"#!{args.python} -I\n{body}")
        os.replace(tmp, dest)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    print(json.dumps({"dsv_fetch": "install", "dest": dest, "python": args.python, "mode": "0500", "owner": args.owner or os.getuid()}), file=sys.stderr)
    return 0


# -------------------------------------------------------------------------------------------------- cli
def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="dsv-fetch", description="Resolve Delinea DSV dsv:// references (init container / Datadog Agent secret backend).")
    sub = p.add_subparsers(dest="command", required=True)
    i = sub.add_parser("init", help="resolve references and write them to an in-memory volume")
    i.add_argument("--out", required=True, help="output directory (in-memory volume)")
    i.add_argument("--format", required=True, choices=("files", "env-yaml", "dotenv"))
    i.add_argument("--map", action="append", metavar="NAME=dsv://path#element")
    i.add_argument("--map-file", help='JSON object {"NAME": "dsv://..."}')
    i.add_argument("--from-env", action="store_true", help="also map every env var whose value is a dsv:// reference")
    i.add_argument("--env-yaml-name", default="fluentbit-env.yaml")
    i.add_argument("--dotenv-name", default=".env")
    i.add_argument("--file-mode", default="0400", help="octal mode of written files: 0400 (default), 0440 (shared fsGroup) or 0444")
    i.add_argument("--config", help="JSON file with DSV_* / AZURE_* settings (environment wins)")
    a = sub.add_parser("agent-backend", help="Datadog Agent secret_backend_command (stdin/stdout JSON)")
    a.add_argument("--config", help="JSON file with DSV_* / AZURE_* settings (environment wins)")
    n = sub.add_parser("install", help="install a copy as a Datadog Agent secret_backend_command (mode 0500)")
    n.add_argument("--dest", required=True)
    n.add_argument("--python", default="/opt/datadog-agent/embedded/bin/python3", help="interpreter for the shebang")
    n.add_argument("--owner", help="user that will own the file (requires root), e.g. dd-agent")
    sub.add_parser("version")
    return p


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:  # argparse: 2 on usage errors, 0 on --help
        return int(exc.code or 0)
    try:
        if args.command == "init":
            return cmd_init(args)
        if args.command == "agent-backend":
            return cmd_agent_backend(args)
        if args.command == "install":
            return cmd_install(args)
        print(__version__)
        return 0
    except UsageError as exc:
        print(f"dsv-fetch: {exc}", file=sys.stderr)
        return 2
    except FetchError as exc:
        print(f"dsv-fetch: {exc.reason}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
