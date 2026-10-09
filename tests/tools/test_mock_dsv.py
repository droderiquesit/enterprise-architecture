import json
import urllib.error
import urllib.request

from tools.secrets.mock_dsv import fake_entra_token, serve

MIRID = "/subscriptions/0/resourcegroups/rg/providers/microsoft.managedidentity/userassignedidentities/id-hello-bff"


def _req(url, method="GET", body=None, token=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(url, data=data, method=method, headers={"Content-Type": "application/json"})
    if token:
        r.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(r) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


def test_azure_grant_and_policy():
    httpd, _ = serve({"users": {MIRID: {"read": ["eh/dev/fault-token"]}}, "secrets": {"eh/dev/fault-token": {"value": "t"}, "eh/dev/other": {"value": "x"}}})
    base = f"http://127.0.0.1:{httpd.server_address[1]}/v1"
    try:
        code, tok = _req(f"{base}/token", "POST", {"grant_type": "azure", "jwt": fake_entra_token(MIRID)})
        assert code == 200 and tok["expiresIn"] == 3600
        code, sec = _req(f"{base}/secrets/eh/dev/fault-token", token=tok["accessToken"])
        assert code == 200 and sec["data"] == {"value": "t"}
        assert _req(f"{base}/secrets/eh/dev/other", token=tok["accessToken"])[0] == 403
        assert _req(f"{base}/secrets/eh/dev/fault-token")[0] == 401
        assert _req(f"{base}/token", "POST", {"grant_type": "azure", "jwt": fake_entra_token("/other")})[0] == 401
    finally:
        httpd.shutdown()
