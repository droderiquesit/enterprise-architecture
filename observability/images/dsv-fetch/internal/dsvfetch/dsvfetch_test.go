package dsvfetch

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"
)

func init() { sleep = func(time.Duration) {} }

func TestPyQuote(t *testing.T) {
	cases := map[string]string{
		"plain":       `"plain"`,
		"we\"ird \\":  `"we\"ird \\"`,
		"ünï":         `"\u00fcn\u00ef"`,
		"a\nb\t\x01":  `"a\nb\t\u0001"`,
		"\x7f":        `"\u007f"`,
		"😀":           `"\ud83d\ude00"`,
		"${X} `y` $z": `"${X} ` + "`y`" + ` $z"`,
	}
	for in, want := range cases {
		if got := pyQuote(in); got != want {
			t.Errorf("pyQuote(%q) = %s, want %s", in, got, want)
		}
	}
}

func TestPyFloatRepr(t *testing.T) {
	cases := map[float64]string{1: "1.0", 2.5: "2.5", 1e-05: "1e-05", 0.0001: "0.0001", 1e16: "1e+16",
		1234567890123456: "1234567890123456.0", 0.1: "0.1", -0.0: "0.0", 1.5e300: "1.5e+300"}
	for in, want := range cases {
		if got := pyFloatRepr(in); got != want {
			t.Errorf("pyFloatRepr(%v) = %s, want %s", in, got, want)
		}
	}
	if pyNumber("-0") != "0" || pyNumber("12") != "12" || pyNumber("1E2") != "100.0" || pyNumber("1e400") != "Infinity" {
		t.Error("pyNumber")
	}
}

func TestPyDumpRawKeepsOrder(t *testing.T) {
	got, err := pyDumpRaw([]byte(`{"b": [1, 2.50, true, null, {}], "a": "ü", "b": {"z": 1e1}}`))
	if err != nil {
		t.Fatal(err)
	}
	if want := `{"b": {"z": 10.0}, "a": "\u00fc"}`; got != want {
		t.Errorf("got %s want %s", got, want)
	}
}

func TestPyRepr(t *testing.T) {
	cases := map[string]string{"x": `'x'`, "it's": `"it's"`, `a'"b`: `'a\'"b'`, "a\nb": `'a\nb'`, "ü": `'ü'`, "": `''`}
	for in, want := range cases {
		if got := pyRepr(in); got != want {
			t.Errorf("pyRepr(%q) = %s, want %s", in, got, want)
		}
	}
}

func TestParseRef(t *testing.T) {
	ok := map[string][2]string{
		"dsv://eh/dev/key":         {"eh/dev/key", "value"},
		"dsv:///eh/dev/key/#site":  {"eh/dev/key", "site"},
		"dsv://a:b/c.d_e-f#x.y_z-": {"a:b/c.d_e-f", "x.y_z-"},
	}
	for ref, want := range ok {
		p, e, err := parseRef(ref)
		if err != nil || p != want[0] || e != want[1] {
			t.Errorf("parseRef(%q) = %q %q %v", ref, p, e, err)
		}
	}
	for _, ref := range []string{"dsv://", "dsv://a/../b", "dsv://a//b", "dsv://a b", "dsv://a#b c", "dsv://_a"} {
		if _, _, err := parseRef(ref); err == nil || err.Error() != "malformed dsv:// reference" {
			t.Errorf("parseRef(%q) err = %v", ref, err)
		}
	}
	if _, _, err := parseRef("vault://x"); err == nil || err.Error() != "not a dsv:// reference" {
		t.Error(err)
	}
}

func TestParseOctal(t *testing.T) {
	for in, want := range map[string]int64{"0400": 0o400, "400": 0o400, "0o440": 0o440, " 444 ": 0o444, "4_00": 0o400} {
		if v, ok := parseOctal(in); !ok || v != want {
			t.Errorf("parseOctal(%q) = %o %v", in, v, ok)
		}
	}
	for _, in := range []string{"", "08", "abc", "_400", "4__0"} {
		if _, ok := parseOctal(in); ok {
			t.Errorf("parseOctal(%q) accepted", in)
		}
	}
}

func TestPyQuotePathAndURLEncode(t *testing.T) {
	if got := pyQuotePath("eh/dev/a b:ü~"); got != "eh/dev/a%20b%3A%C3%BC~" {
		t.Error(got)
	}
	if got := urlencode("api-version", "2018-02-01", "resource", armResource); got != "api-version=2018-02-01&resource=https%3A%2F%2Fmanagement.azure.com%2F" {
		t.Error(got)
	}
}

func TestArgs(t *testing.T) {
	spec := commands[0]
	p, err := spec.parse(prog, []string{"--out=o", "--form", "files", "--map", "A=dsv://a", "--map=B=dsv://b", "--from-env"})
	if err != nil {
		t.Fatal(err)
	}
	if p.get("out") != "o" || p.get("format") != "files" || len(p.values["map"]) != 2 || !p.flags["from-env"] || p.get("file-mode") != "0400" {
		t.Errorf("%+v", p)
	}
	for args, msg := range map[string]string{
		"--out o":                     "the following arguments are required: --format",
		"--out o --format x":          "argument --format: invalid choice: 'x' (choose from 'files', 'env-yaml', 'dotenv')",
		"--out o --format files --f":  "ambiguous option: --f could match --format, --from-env, --file-mode",
		"--out o --format files --zz": "unrecognized arguments: --zz",
		"--out --format files":        "argument --out: expected one argument",
	} {
		_, err := spec.parse(prog, strings.Fields(args))
		if err == nil || err.Error() != msg {
			t.Errorf("%s: %v", args, err)
		}
	}
}

func env(m map[string]string) func(string) string { return func(k string) string { return m[k] } }

func TestLoadSettings(t *testing.T) {
	dir := t.TempDir()
	cfg := filepath.Join(dir, "c.json")
	os.WriteFile(cfg, []byte(`{"DSV_TENANT": "t1", "DSV_TIMEOUT_SECONDS": 2.0, "DSV_MAX_ATTEMPTS": 4, "DSV_ALLOW_INSECURE_HTTP": true, "AZURE_CLIENT_ID": null, "OTHER": "x"}`), 0o600)
	s, err := loadSettings(cfg, env(map[string]string{"DSV_TENANT": "t2", "DSV_TLD": ""}))
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{"DSV_TENANT": "t2", "DSV_TIMEOUT_SECONDS": "2.0", "DSV_MAX_ATTEMPTS": "4", "DSV_ALLOW_INSECURE_HTTP": "True"}
	if len(s) != len(want) {
		t.Errorf("%v", s)
	}
	for k, v := range want {
		if s[k] != v {
			t.Errorf("%s = %q want %q", k, s[k], v)
		}
	}
	if _, err := loadSettings(filepath.Join(dir, "none"), env(nil)); err == nil || err.Error() != "cannot read --config file (FileNotFoundError)" {
		t.Error(err)
	}
	os.WriteFile(cfg, []byte(`{bad`), 0o600)
	if _, err := loadSettings(cfg, env(nil)); err == nil || err.Error() != "cannot read --config file (JSONDecodeError)" {
		t.Error(err)
	}
}

func TestNewClientValidation(t *testing.T) {
	c, err := NewClient(map[string]string{"DSV_TENANT": " t ", "DSV_TLD": "eu"})
	if err != nil || c.base != "https://t.secretsvaultcloud.eu/v1" || c.timeout != 5 || c.attempts != 3 {
		t.Fatalf("%v %+v", err, c)
	}
	for msg, s := range map[string]map[string]string{
		"DSV_TENANT or DSV_BASE_URL must be set":                                               {},
		"DSV_AUTH must be azure or client_credentials for dsv-fetch":                           {"DSV_AUTH": "x", "DSV_TENANT": "t"},
		"DSV_BASE_URL must use https (http only for loopback or DSV_ALLOW_INSECURE_HTTP=true)": {"DSV_BASE_URL": "http://dsv.example"},
		"DSV_BASE_URL must be an absolute https URL":                                           {"DSV_BASE_URL": "dsv.example"},
		"DSV_AUTH=client_credentials requires DSV_CLIENT_ID and DSV_CLIENT_SECRET":             {"DSV_AUTH": "client_credentials", "DSV_TENANT": "t"},
		"DSV_TIMEOUT_SECONDS must be >= 0.1":                                                   {"DSV_TENANT": "t", "DSV_TIMEOUT_SECONDS": "0"},
		"DSV_MAX_ATTEMPTS must be a number":                                                    {"DSV_TENANT": "t", "DSV_MAX_ATTEMPTS": "x"},
	} {
		if _, err := NewClient(s); err == nil || err.Error() != msg {
			t.Errorf("%v: got %v want %s", s, err, msg)
		}
	}
	for _, base := range []string{"http://127.0.0.1:8200/v1", "http://localhost/v1", "http://[::1]:1/v1"} {
		if _, err := NewClient(map[string]string{"DSV_BASE_URL": base}); err != nil {
			t.Errorf("%s: %v", base, err)
		}
	}
	if _, err := NewClient(map[string]string{"DSV_BASE_URL": "http://dsv:8200/v1", "DSV_ALLOW_INSECURE_HTTP": "Yes"}); err != nil {
		t.Error(err)
	}
}

// fakeAzure is IMDS + IDENTITY_ENDPOINT + Entra + DSV in one httptest server.
type fakeAzure struct {
	mu        sync.Mutex
	srv       *httptest.Server
	calls     []string
	imdsFails int
}

func newFakeAzure(t *testing.T) *fakeAzure {
	f := &fakeAzure{}
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		f.calls = append(f.calls, r.Method+" "+r.URL.Path)
		fails := f.imdsFails
		if r.URL.Path == "/metadata/identity/oauth2/token" && fails > 0 {
			f.imdsFails--
		}
		f.mu.Unlock()
		body, _ := io.ReadAll(r.Body)
		reply := func(code int, v any) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(code)
			json.NewEncoder(w).Encode(v)
		}
		switch {
		case r.URL.Path == "/metadata/identity/oauth2/token":
			if r.Header.Get("Metadata") != "true" || r.URL.Query().Get("resource") != armResource {
				reply(400, map[string]string{})
			} else if fails > 0 {
				reply(503, map[string]string{})
			} else {
				reply(200, map[string]string{"access_token": "entra-imds"})
			}
		case r.URL.Path == "/msi/token":
			if r.Header.Get("X-Identity-Header") != "hdr" || r.URL.Query().Get("api-version") != "2019-08-01" {
				reply(401, map[string]string{})
			} else {
				reply(200, map[string]string{"access_token": "entra-msi"})
			}
		case strings.HasSuffix(r.URL.Path, "/oauth2/v2.0/token"):
			if !strings.Contains(string(body), "client_assertion=sa-token&") && !strings.HasSuffix(string(body), "client_assertion=sa-token") {
				reply(401, map[string]string{})
			} else {
				reply(200, map[string]string{"access_token": "entra-wi"})
			}
		case r.URL.Path == "/v1/token":
			var req map[string]string
			json.Unmarshal(body, &req)
			if strings.HasPrefix(req["jwt"], "entra-") || req["client_secret"] == "s" {
				reply(200, map[string]string{"accessToken": "dsv-token"})
			} else {
				reply(401, map[string]string{})
			}
		case strings.HasPrefix(r.URL.Path, "/v1/secrets/"):
			if r.Header.Get("Authorization") != "Bearer dsv-token" {
				reply(401, map[string]string{})
				return
			}
			switch strings.TrimPrefix(r.URL.Path, "/v1/secrets/") {
			case "eh/dev/key":
				reply(200, map[string]any{"data": map[string]any{"value": "VALUE-1", "n": 3}})
			case "eh/dev/denied":
				reply(403, map[string]string{})
			case "eh/dev/flaky":
				reply(500, map[string]string{})
			default:
				reply(404, map[string]string{})
			}
		default:
			reply(404, map[string]string{})
		}
	}))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeAzure) count(prefix string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, c := range f.calls {
		if strings.HasPrefix(c, prefix) {
			n++
		}
	}
	return n
}

func TestClientIdentitySources(t *testing.T) {
	f := newFakeAzure(t)
	tok := filepath.Join(t.TempDir(), "sa")
	os.WriteFile(tok, []byte("sa-token\n"), 0o600)
	for name, extra := range map[string]map[string]string{
		"imds":     {"AZURE_POD_IDENTITY_AUTHORITY_HOST": f.srv.URL + "/"},
		"identity": {"IDENTITY_ENDPOINT": f.srv.URL + "/msi/token", "IDENTITY_HEADER": "hdr"},
		"workload": {"AZURE_FEDERATED_TOKEN_FILE": tok, "AZURE_TENANT_ID": "tn", "AZURE_CLIENT_ID": "cid", "AZURE_AUTHORITY_HOST": f.srv.URL},
		"client":   {"DSV_AUTH": "client_credentials", "DSV_CLIENT_ID": "c", "DSV_CLIENT_SECRET": "s"},
	} {
		s := map[string]string{"DSV_BASE_URL": f.srv.URL + "/v1"}
		for k, v := range extra {
			s[k] = v
		}
		c, err := NewClient(s)
		if err != nil {
			t.Fatal(err)
		}
		v, err := c.Resolve("dsv://eh/dev/key")
		if err != nil || v != "VALUE-1" {
			t.Errorf("%s: %q %v", name, v, err)
		}
		if v, err := c.Resolve("dsv://eh/dev/key#n"); err != nil || v != "3" {
			t.Errorf("%s: element n %q %v", name, v, err)
		}
	}
	if n := f.count("GET /v1/secrets/"); n != 4 {
		t.Errorf("secret reads = %d, want 4 (one per client, cached per path)", n)
	}
}

func TestClientErrorsAndRetries(t *testing.T) {
	f := newFakeAzure(t)
	f.imdsFails = 2
	c, _ := NewClient(map[string]string{"DSV_BASE_URL": f.srv.URL + "/v1", "AZURE_POD_IDENTITY_AUTHORITY_HOST": f.srv.URL, "DSV_MAX_ATTEMPTS": "1"})
	if _, err := c.Resolve("dsv://eh/dev/key"); err != nil {
		t.Fatalf("IMDS 503 must be retried (min 3 attempts): %v", err)
	}
	for ref, want := range map[string]string{
		"dsv://eh/dev/denied":  "DSV secret read failed (access denied, HTTP 403)",
		"dsv://eh/dev/missing": "DSV secret read failed (not found, HTTP 404)",
		"dsv://eh/dev/flaky":   "DSV secret read failed (HTTP 500 after 1 attempts)",
		"dsv://eh/dev/key#zz":  "element missing in DSV secret",
	} {
		if _, err := c.Resolve(ref); err == nil || err.Error() != want {
			t.Errorf("%s: %v, want %s", ref, err, want)
		}
	}
	c2, _ := NewClient(map[string]string{"DSV_BASE_URL": f.srv.URL + "/v1", "AZURE_POD_IDENTITY_AUTHORITY_HOST": "http://127.0.0.1:1", "DSV_MAX_ATTEMPTS": "1", "DSV_TIMEOUT_SECONDS": "0.5"})
	if _, err := c2.Resolve("dsv://eh/dev/key"); err == nil || !strings.HasPrefix(err.Error(), "managed identity token unavailable (unreachable (ConnectionRefusedError)") {
		t.Error(err)
	}
	c3, _ := NewClient(map[string]string{"DSV_BASE_URL": f.srv.URL + "/v1", "IDENTITY_ENDPOINT": "file:///etc/passwd", "IDENTITY_HEADER": "h"})
	if _, err := c3.Resolve("dsv://eh/dev/key"); err == nil || err.Error() != "managed identity token unavailable (only http(s) URLs are allowed)" {
		t.Error(err)
	}
}

func TestRedirectsAreNotFollowed(t *testing.T) {
	srv := httptest.NewServer(http.RedirectHandler("http://169.254.169.254/elsewhere", http.StatusFound))
	defer srv.Close()
	_, err := newHTTPClient().do(request{method: "GET", url: srv.URL, timeout: 2, attempts: 3, retry: map[int]bool{}})
	if err == nil || err.Error() != "HTTP 302" {
		t.Error(err)
	}
}

func TestResponseValidation(t *testing.T) {
	for body, want := range map[string]string{"[1]": "response is not a JSON object", "nope": "response is not JSON", "": "response is not JSON"} {
		if _, err := parseObject([]byte(body)); err == nil || err.Error() != want {
			t.Errorf("%q: %v", body, err)
		}
	}
	if _, err := parseObject(bytes.Repeat([]byte(" "), maxResponse+1)); err == nil || err.Error() != "response too large" {
		t.Error(err)
	}
}

func runMain(t *testing.T, argv []string, stdin string, e map[string]string) (int, string, string) {
	t.Helper()
	var out, errb bytes.Buffer
	code := Main(argv, Std{In: strings.NewReader(stdin), Out: &out, Err: &errb, Getenv: env(e), Environ: func() []string {
		var l []string
		for k, v := range e {
			l = append(l, k+"="+v)
		}
		return l
	}}, "9.9.9")
	return code, out.String(), errb.String()
}

func TestMainInitFormats(t *testing.T) {
	f := newFakeAzure(t)
	e := map[string]string{"DSV_BASE_URL": f.srv.URL + "/v1", "DSV_AUTH": "client_credentials", "DSV_CLIENT_ID": "c", "DSV_CLIENT_SECRET": "s", "APP_KEY": "dsv://eh/dev/key#n", "DSV_X": "dsv://x"}
	dir := filepath.Join(t.TempDir(), "a", "out")
	code, _, stderr := runMain(t, []string{"init", "--out", dir, "--format", "files", "--map", "K=dsv://eh/dev/key", "--from-env"}, "", e)
	if code != 0 {
		t.Fatal(stderr)
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "K")); string(b) != "VALUE-1" {
		t.Error(string(b))
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "APP_KEY")); string(b) != "3" {
		t.Error(string(b))
	}
	if want := `{"dsv_fetch": "init", "format": "files", "out": "` + dir + `", "names": ["APP_KEY", "K"], "files": ["APP_KEY", "K"], "mode": "0400"}` + "\n"; stderr != want {
		t.Errorf("summary %q", stderr)
	}
	if runtime.GOOS != "windows" {
		if st, _ := os.Stat(filepath.Join(dir, "K")); st.Mode().Perm() != 0o400 {
			t.Errorf("mode %v", st.Mode())
		}
		if st, _ := os.Stat(dir); st.Mode().Perm() != 0o700 {
			t.Errorf("dir mode %v", st.Mode())
		}
	}
	code, _, stderr = runMain(t, []string{"init", "--out", dir, "--format", "env-yaml", "--map", "K=dsv://eh/dev/key", "--file-mode", "0440"}, "", e)
	if b, _ := os.ReadFile(filepath.Join(dir, "fluentbit-env.yaml")); code != 0 || string(b) != "# written by dsv-fetch - Fluent Bit YAML env section; do not edit\nenv:\n  K: \"VALUE-1\"\n" {
		t.Errorf("%d %s %q", code, stderr, b)
	}
	code, _, _ = runMain(t, []string{"init", "--out", dir, "--format", "dotenv", "--map", "K=dsv://eh/dev/key"}, "", e)
	if b, _ := os.ReadFile(filepath.Join(dir, ".env")); code != 0 || string(b) != "K=\"VALUE-1\"\n" {
		t.Errorf("%d %q", code, b)
	}
	code, _, stderr = runMain(t, []string{"init", "--out", dir, "--format", "files", "--map", "A=dsv://eh/dev/denied", "--map", "B=dsv://eh/dev/key"}, "", e)
	if code != 1 || stderr != "dsv-fetch: A: DSV secret read failed (access denied, HTTP 403)\ndsv-fetch: 1 of 2 reference(s) failed; nothing written\n" {
		t.Errorf("%d %q", code, stderr)
	}
	if code, _, stderr = runMain(t, []string{"init", "--out", dir, "--format", "files", "--map", "K=dsv://eh/dev/key", "--file-mode", "0600"}, "", e); code != 2 || !strings.Contains(stderr, "read-only for the owner") {
		t.Errorf("%d %q", code, stderr)
	}
	if code, out, _ := runMain(t, []string{"version"}, "", e); code != 0 || out != "9.9.9\n" {
		t.Error(out)
	}
	entries, _ := os.ReadDir(dir)
	for _, en := range entries {
		if strings.HasPrefix(en.Name(), ".dsv-fetch-") {
			t.Errorf("temp file left: %s", en.Name())
		}
	}
}

func TestMainAgentBackend(t *testing.T) {
	f := newFakeAzure(t)
	e := map[string]string{"DSV_BASE_URL": f.srv.URL + "/v1", "AZURE_POD_IDENTITY_AUTHORITY_HOST": f.srv.URL}
	code, out, stderr := runMain(t, []string{"agent-backend"}, `{"version":"1.0","secrets":["dsv://eh/dev/key","dsv://eh/dev/denied","x","dsv://eh/dev/key"]}`, e)
	want := `{"dsv://eh/dev/key": {"value": "VALUE-1", "error": null}, "dsv://eh/dev/denied": {"value": null, "error": "DSV secret read failed (access denied, HTTP 403)"}, "x": {"value": null, "error": "not a dsv:// reference"}}`
	if code != 0 || out != want || stderr != "" {
		t.Errorf("%d %s %q", code, out, stderr)
	}
	code, out, _ = runMain(t, []string{"agent-backend"}, `{"version":"1.0","secrets":["dsv://a"]}`, map[string]string{})
	if code != 0 || out != `{"dsv://a": {"value": null, "error": "dsv-fetch configuration error: DSV_TENANT or DSV_BASE_URL must be set"}}` {
		t.Error(out)
	}
	for _, in := range []string{"", "x", `{"secrets":[]}`, `{"version":"2.0","secrets":[]}`, `{"version":"1.0","secrets":[1]}`, `[]`} {
		if code, out, stderr := runMain(t, []string{"agent-backend"}, in, e); code != 1 || out != "" || !strings.Contains(stderr, "malformed agent request") {
			t.Errorf("%q: %d %q %q", in, code, out, stderr)
		}
	}
	if code, _, stderr := runMain(t, []string{"agent-backend"}, strings.Repeat(" ", maxAgentInput+1), e); code != 1 || !strings.Contains(stderr, "too large") {
		t.Error(stderr)
	}
}

func TestMainInstallCopiesRunningBinary(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "bin", "dsv-fetch")
	code, _, stderr := runMain(t, []string{"install", "--dest", dest, "--python", "ignored"}, "", nil)
	if code != 0 {
		t.Fatal(stderr)
	}
	self, _ := os.Executable()
	a, _ := os.ReadFile(self)
	b, _ := os.ReadFile(dest)
	if !bytes.Equal(a, b) {
		t.Error("installed copy differs from the running binary")
	}
	if runtime.GOOS != "windows" {
		if st, _ := os.Stat(dest); st.Mode().Perm() != 0o500 {
			t.Errorf("mode %v", st.Mode())
		}
		if !strings.Contains(stderr, `"mode": "0500"`) {
			t.Error(stderr)
		}
		if code, _, stderr := runMain(t, []string{"install", "--dest", dest, "--owner", "no-such-user-x"}, "", nil); code != 2 || !strings.Contains(stderr, "unknown user 'no-such-user-x'") {
			t.Errorf("%d %s", code, stderr)
		}
	}
}

func TestMainUsage(t *testing.T) {
	for _, argv := range [][]string{{}, {"bogus"}, {"init"}, {"version", "x"}} {
		if code, _, stderr := runMain(t, argv, "", nil); code != 2 || !strings.HasPrefix(stderr, "usage: dsv-fetch") {
			t.Errorf("%v: %d %q", argv, code, stderr)
		}
	}
	if code, out, _ := runMain(t, []string{"--help"}, "", nil); code != 0 || !strings.Contains(out, "agent-backend") {
		t.Error(out)
	}
}

func TestInitRefreshLoop(t *testing.T) {
	f := newFakeAzure(t)
	e := map[string]string{"DSV_BASE_URL": f.srv.URL + "/v1", "DSV_AUTH": "client_credentials", "DSV_CLIENT_ID": "c", "DSV_CLIENT_SECRET": "s"}
	var waits []time.Duration
	old := refreshSleep
	refreshSleep = func(d time.Duration) bool { waits = append(waits, d); return len(waits) < 3 }
	defer func() { refreshSleep = old }()
	dir := t.TempDir()
	code, _, stderr := runMain(t, []string{"init", "--out", dir, "--format", "files", "--map", "K=dsv://eh/dev/key", "--refresh-seconds", "3600"}, "", e)
	if code != 0 || len(waits) != 3 || waits[0] != time.Hour || f.count("POST /v1/token") != 3 {
		t.Errorf("%d %v %d %s", code, waits, f.count("POST /v1/token"), stderr)
	}
	waits = nil
	code, _, _ = runMain(t, []string{"init", "--out", dir, "--format", "files", "--map", "K=dsv://eh/dev/denied", "--refresh-seconds", "60", "--retry-seconds", "5"}, "", e)
	if code != 1 || len(waits) != 3 || waits[0] != 5*time.Second {
		t.Errorf("%d %v", code, waits)
	}
	if code, _, stderr := runMain(t, []string{"init", "--out", dir, "--format", "files", "--map", "K=dsv://eh/dev/key", "--refresh-seconds", "0.5"}, "", e); code != 2 || !strings.Contains(stderr, "--refresh-seconds must be 0 or >= 1") {
		t.Error(stderr)
	}
	if code, _, _ := runMain(t, []string{"init", "--out", dir, "--format", "files", "--map", "K=bad", "--refresh-seconds", "10"}, "", e); code != 2 {
		t.Error("usage error must end the loop with exit 2")
	}
}
