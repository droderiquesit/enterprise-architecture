package dsvfetch

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"
)

const (
	refPrefix     = "dsv://"
	armResource   = "https://management.azure.com/"
	armScope      = "https://management.azure.com/.default"
	imdsDefault   = "http://169.254.169.254"
	maxAgentInput = 1024 * 1024
	maxResponse   = 4 * 1024 * 1024
)

// configKeys are the settings read from the environment or --config FILE.json (the environment wins).
var configKeys = []string{
	"DSV_AUTH", "DSV_TENANT", "DSV_TLD", "DSV_BASE_URL", "DSV_ALLOW_INSECURE_HTTP", "DSV_CLIENT_ID", "DSV_CLIENT_SECRET",
	"DSV_TIMEOUT_SECONDS", "DSV_MAX_ATTEMPTS", "AZURE_CLIENT_ID", "AZURE_TENANT_ID", "AZURE_AUTHORITY_HOST",
	"AZURE_FEDERATED_TOKEN_FILE", "IDENTITY_ENDPOINT", "IDENTITY_HEADER", "AZURE_POD_IDENTITY_AUTHORITY_HOST",
}

// Python's re.match(...$) also matches before one trailing newline; "\n?$" keeps that behaviour.
var (
	pathRE    = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.:-]*(/[A-Za-z0-9_.:-]+)*\n?$`)
	elementRE = regexp.MustCompile(`^[A-Za-z0-9_.-]+\n?$`)
	envNameRE = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*\n?$`)
	fileRE    = regexp.MustCompile(`^[A-Za-z0-9_][A-Za-z0-9_.-]*\n?$`)
)

// UsageError: bad arguments or configuration (exit 2).
type UsageError struct{ Msg string }

func (e *UsageError) Error() string { return e.Msg }

func usagef(format string, a ...any) error { return &UsageError{fmt.Sprintf(format, a...)} }

// FetchError: a reference could not be resolved. The reason is value-free (status code / error class). Exit 1.
type FetchError struct {
	Reason string
	Status int
}

func (e *FetchError) Error() string { return e.Reason }

func fetchErr(reason string, status int) error { return &FetchError{reason, status} }

// ---------------------------------------------------------------------------------------------- references

func parseRef(ref string) (path, element string, err error) {
	if !strings.HasPrefix(ref, refPrefix) {
		return "", "", fetchErr("not a dsv:// reference", 0)
	}
	rest := ref[len(refPrefix):]
	path, element, _ = strings.Cut(rest, "#")
	path = strings.Trim(path, "/")
	if element == "" {
		element = "value"
	}
	dotdot := false
	for _, seg := range strings.Split(path, "/") {
		if seg == ".." {
			dotdot = true
		}
	}
	if path == "" || dotdot || !pathRE.MatchString(path) || !elementRE.MatchString(element) {
		return "", "", fetchErr("malformed dsv:// reference", 0)
	}
	return path, element, nil
}

// ------------------------------------------------------------------------------------------------ settings

// pyTypeName maps a Go error to the Python exception class name the 1.x implementation reported.
func pyTypeName(err error) string {
	var se *json.SyntaxError
	var te *json.UnmarshalTypeError
	switch {
	case errors.Is(err, os.ErrNotExist):
		return "FileNotFoundError"
	case errors.Is(err, os.ErrPermission):
		return "PermissionError"
	case isDirError(err):
		return "IsADirectoryError"
	case errors.As(err, &se), errors.As(err, &te), errors.Is(err, errEmptyJSON):
		return "JSONDecodeError"
	case errors.Is(err, errNotUTF8):
		return "UnicodeDecodeError"
	}
	return "OSError"
}

var (
	errEmptyJSON = errors.New("empty JSON document")
	errNotUTF8   = errors.New("not UTF-8")
)

func isDirError(err error) bool {
	var pe *os.PathError
	if errors.As(err, &pe) {
		if st, e := os.Stat(pe.Path); e == nil && st.IsDir() {
			return true
		}
	}
	return false
}

// readJSONFile reads a UTF-8 JSON document (like open(encoding="utf-8") + json.load: a BOM is not accepted).
func readJSONFile(path string) ([]byte, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if !utf8.Valid(raw) {
		return nil, errNotUTF8
	}
	trim := bytes.TrimSpace(raw)
	if len(trim) == 0 {
		return nil, errEmptyJSON
	}
	if !json.Valid(trim) {
		var v any
		return nil, json.Unmarshal(trim, &v)
	}
	return trim, nil
}

func loadSettings(configFile string, environ func(string) string) (map[string]string, error) {
	cfg := map[string]string{}
	if configFile != "" {
		raw, err := readJSONFile(configFile)
		if err != nil {
			return nil, usagef("cannot read --config file (%s)", pyTypeName(err))
		}
		var doc map[string]json.RawMessage
		if len(raw) == 0 || raw[0] != '{' || json.Unmarshal(raw, &doc) != nil {
			return nil, usagef("--config must be a JSON object")
		}
		for _, k := range configKeys {
			v, ok := doc[k]
			if !ok || string(bytes.TrimSpace(v)) == "null" {
				continue
			}
			if s, ok := pyStr(v); ok {
				cfg[k] = s
			} else {
				cfg[k] = string(v) // nested object/list: Python str() of it; never a useful setting
			}
		}
	}
	for _, k := range configKeys {
		if v := environ(k); v != "" {
			cfg[k] = v
		}
	}
	return cfg, nil
}

func isLoopback(host string) bool {
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

var truthy = map[string]bool{"1": true, "true": true, "yes": true, "on": true}

func settingFloat(s map[string]string, key string, def, minimum float64) (float64, error) {
	v := def
	if raw := s[key]; raw != "" {
		f, err := strconv.ParseFloat(strings.ReplaceAll(strings.TrimSpace(raw), "_", ""), 64)
		if err != nil && !errors.Is(err, strconv.ErrRange) {
			return 0, usagef("%s must be a number", key)
		}
		v = f
	}
	if v < minimum {
		return 0, usagef("%s must be >= %s", key, strconv.FormatFloat(minimum, 'g', -1, 64))
	}
	return v, nil
}

// --------------------------------------------------------------------------------------------- DSV client

// Client resolves dsv:// references (one DSV token and one read per secret path per process).
type Client struct {
	s        map[string]string
	auth     string
	base     string
	timeout  float64
	attempts int
	token    string
	cache    map[string]map[string]json.RawMessage
	http     *httpClient
}

func NewClient(s map[string]string) (*Client, error) {
	auth := strings.ToLower(strings.TrimSpace(orDefault(s["DSV_AUTH"], "azure")))
	if auth != "azure" && auth != "client_credentials" {
		return nil, usagef("DSV_AUTH must be azure or client_credentials for dsv-fetch")
	}
	base := strings.TrimRight(strings.TrimSpace(s["DSV_BASE_URL"]), "/")
	if base == "" && s["DSV_TENANT"] != "" {
		base = fmt.Sprintf("https://%s.secretsvaultcloud.%s/v1", strings.TrimSpace(s["DSV_TENANT"]), strings.TrimSpace(orDefault(s["DSV_TLD"], "com")))
	}
	if base == "" {
		return nil, usagef("DSV_TENANT or DSV_BASE_URL must be set")
	}
	scheme, host := splitSchemeHost(base)
	allowHTTP := truthy[strings.ToLower(strings.TrimSpace(s["DSV_ALLOW_INSECURE_HTTP"]))]
	if (scheme != "https" && scheme != "http") || host == "" {
		return nil, usagef("DSV_BASE_URL must be an absolute https URL")
	}
	if scheme == "http" && !(allowHTTP || isLoopback(host)) {
		return nil, usagef("DSV_BASE_URL must use https (http only for loopback or DSV_ALLOW_INSECURE_HTTP=true)")
	}
	if auth == "client_credentials" && (s["DSV_CLIENT_ID"] == "" || s["DSV_CLIENT_SECRET"] == "") {
		return nil, usagef("DSV_AUTH=client_credentials requires DSV_CLIENT_ID and DSV_CLIENT_SECRET")
	}
	timeout, err := settingFloat(s, "DSV_TIMEOUT_SECONDS", 5, 0.1)
	if err != nil {
		return nil, err
	}
	attempts, err := settingFloat(s, "DSV_MAX_ATTEMPTS", 3, 1)
	if err != nil {
		return nil, err
	}
	if attempts > math.MaxInt32 {
		attempts = math.MaxInt32
	}
	return &Client{s: s, auth: auth, base: base, timeout: timeout, attempts: int(attempts),
		cache: map[string]map[string]json.RawMessage{}, http: newHTTPClient()}, nil
}

func orDefault(v, def string) string {
	if v == "" {
		return def
	}
	return v
}

// splitSchemeHost mimics urllib.parse.urlsplit(...).scheme / .hostname (lower-cased, IPv6 brackets removed).
func splitSchemeHost(raw string) (scheme, host string) {
	u, err := url.Parse(raw)
	if err != nil {
		i := strings.Index(raw, "://")
		if i <= 0 {
			return "", ""
		}
		scheme = strings.ToLower(raw[:i])
		rest := raw[i+3:]
		if j := strings.IndexAny(rest, "/?#"); j >= 0 {
			rest = rest[:j]
		}
		if j := strings.LastIndex(rest, "@"); j >= 0 {
			rest = rest[j+1:]
		}
		if strings.HasPrefix(rest, "[") {
			if j := strings.Index(rest, "]"); j > 0 {
				return scheme, strings.ToLower(rest[1:j])
			}
		}
		if j := strings.LastIndex(rest, ":"); j >= 0 {
			rest = rest[:j]
		}
		return scheme, strings.ToLower(rest)
	}
	return strings.ToLower(u.Scheme), strings.ToLower(u.Hostname())
}

// pyQuotePath is urllib.parse.quote(s, safe="/"): unreserved characters and "/" stay, everything else %XX (UTF-8).
func pyQuotePath(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || strings.IndexByte("_.-~/", c) >= 0 {
			b.WriteByte(c)
		} else {
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}

// urlencode is urllib.parse.urlencode of ordered pairs (quote_plus).
func urlencode(pairs ...string) string {
	parts := make([]string, 0, len(pairs)/2)
	for i := 0; i+1 < len(pairs); i += 2 {
		parts = append(parts, url.QueryEscape(pairs[i])+"="+url.QueryEscape(pairs[i+1]))
	}
	return strings.Join(parts, "&")
}

// ---------------------------------------------------------------------------------------- managed identity

func (c *Client) entraToken() (string, error) {
	s := c.s
	clientID := strings.TrimSpace(s["AZURE_CLIENT_ID"])
	var doc map[string]json.RawMessage
	var err error
	switch {
	case s["AZURE_FEDERATED_TOKEN_FILE"] != "":
		tenant := strings.TrimSpace(s["AZURE_TENANT_ID"])
		if tenant == "" || clientID == "" {
			return "", usagef("workload identity needs AZURE_TENANT_ID and AZURE_CLIENT_ID")
		}
		authority := strings.TrimRight(orDefault(s["AZURE_AUTHORITY_HOST"], "https://login.microsoftonline.com/"), "/")
		scheme, host := splitSchemeHost(authority)
		if scheme != "https" && !isLoopback(host) {
			return "", usagef("AZURE_AUTHORITY_HOST must be https")
		}
		raw, rerr := os.ReadFile(s["AZURE_FEDERATED_TOKEN_FILE"])
		if rerr == nil && !utf8.Valid(raw) {
			rerr = errNotUTF8
		}
		if rerr != nil {
			err = fetchErr(fmt.Sprintf("federated token file unreadable (%s)", pyTypeName(rerr)), 0)
			break
		}
		form := urlencode(
			"grant_type", "client_credentials",
			"client_id", clientID,
			"scope", armScope,
			"client_assertion_type", "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
			"client_assertion", pyStrip(string(raw)),
		)
		doc, err = c.http.do(request{
			method: "POST", url: authority + "/" + pyQuotePath(tenant) + "/oauth2/v2.0/token",
			headers: [][2]string{{"Content-Type", "application/x-www-form-urlencoded"}}, body: []byte(form),
			timeout: c.timeout, attempts: c.attempts, retry: map[int]bool{429: true}, proxy: true,
		})
	case s["IDENTITY_ENDPOINT"] != "" && s["IDENTITY_HEADER"] != "":
		q := []string{"api-version", "2019-08-01", "resource", armResource}
		if clientID != "" {
			q = append(q, "client_id", clientID)
		}
		doc, err = c.http.do(request{
			method: "GET", url: s["IDENTITY_ENDPOINT"] + "?" + urlencode(q...),
			headers: [][2]string{{"X-IDENTITY-HEADER", s["IDENTITY_HEADER"]}},
			timeout: c.timeout, attempts: c.attempts, retry: map[int]bool{429: true}, proxy: false,
		})
	default:
		imds := strings.TrimRight(orDefault(s["AZURE_POD_IDENTITY_AUTHORITY_HOST"], imdsDefault), "/")
		q := []string{"api-version", "2018-02-01", "resource", armResource}
		if clientID != "" {
			q = append(q, "client_id", clientID)
		}
		doc, err = c.http.do(request{
			method: "GET", url: imds + "/metadata/identity/oauth2/token?" + urlencode(q...),
			headers: [][2]string{{"Metadata", "true"}},
			timeout: c.timeout, attempts: max(c.attempts, 3),
			retry: map[int]bool{404: true, 410: true, 429: true}, // IMDS: identity not yet assigned / transient
			proxy: false,
		})
	}
	if err != nil {
		var fe *FetchError
		if errors.As(err, &fe) {
			return "", fetchErr(fmt.Sprintf("managed identity token unavailable (%s)", fe.Reason), fe.Status)
		}
		return "", err
	}
	tok, ok := jsonString(doc["access_token"])
	if !ok || tok == "" {
		return "", fetchErr("managed identity token response malformed", 0)
	}
	return tok, nil
}

// pyStrip is str.strip() (Unicode whitespace).
func pyStrip(s string) string { return strings.TrimSpace(s) }

func jsonString(raw json.RawMessage) (string, bool) {
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 || raw[0] != '"' {
		return "", false
	}
	var s string
	if json.Unmarshal(raw, &s) != nil {
		return "", false
	}
	return s, true
}

// -------------------------------------------------------------------------------------------------- DSV

func (c *Client) accessToken() (string, error) {
	if c.token != "" {
		return c.token, nil // short-lived process: one DSV token (1 h) per run
	}
	var body string
	if c.auth == "client_credentials" {
		body = pyObject("grant_type", pyQuote("client_credentials"), "client_id", pyQuote(c.s["DSV_CLIENT_ID"]),
			"client_secret", pyQuote(c.s["DSV_CLIENT_SECRET"]))
	} else {
		jwt, err := c.entraToken()
		if err != nil {
			return "", err
		}
		body = pyObject("grant_type", pyQuote("azure"), "jwt", pyQuote(jwt))
	}
	doc, err := c.http.do(request{
		method: "POST", url: c.base + "/token", headers: [][2]string{{"Content-Type", "application/json"}},
		body: []byte(body), timeout: c.timeout, attempts: c.attempts, retry: map[int]bool{429: true}, proxy: true,
	})
	if err != nil {
		var fe *FetchError
		if errors.As(err, &fe) {
			return "", fetchErr(fmt.Sprintf("DSV authentication failed (%s)", fe.Reason), fe.Status)
		}
		return "", err
	}
	tok, ok := jsonString(doc["accessToken"])
	if !ok || tok == "" {
		return "", fetchErr("DSV token response malformed", 0)
	}
	c.token = tok
	return tok, nil
}

func (c *Client) secretData(path string) (map[string]json.RawMessage, error) {
	if d, ok := c.cache[path]; ok {
		return d, nil
	}
	tok, err := c.accessToken()
	if err != nil {
		return nil, err
	}
	doc, err := c.http.do(request{
		method: "GET", url: c.base + "/secrets/" + pyQuotePath(path), headers: [][2]string{{"Authorization", "Bearer " + tok}},
		timeout: c.timeout, attempts: c.attempts, retry: map[int]bool{429: true}, proxy: true,
	})
	if err != nil {
		var fe *FetchError
		if errors.As(err, &fe) {
			reason := map[int]string{401: "unauthorized, ", 403: "access denied, ", 404: "not found, "}[fe.Status]
			return nil, fetchErr(fmt.Sprintf("DSV secret read failed (%s%s)", reason, fe.Reason), fe.Status)
		}
		return nil, err
	}
	raw := bytes.TrimSpace(doc["data"])
	var data map[string]json.RawMessage
	if len(raw) == 0 || raw[0] != '{' || json.Unmarshal(raw, &data) != nil {
		return nil, fetchErr("DSV secret response malformed", 0)
	}
	c.cache[path] = data
	return data, nil
}

// Resolve returns the element value: a string as is, any other JSON value as Python's json.dumps of it.
func (c *Client) Resolve(ref string) (string, error) {
	path, element, err := parseRef(ref)
	if err != nil {
		return "", err
	}
	data, err := c.secretData(path)
	if err != nil {
		return "", err
	}
	raw, ok := data[element]
	raw = bytes.TrimSpace(raw)
	if !ok || string(raw) == "null" {
		return "", fetchErr("element missing in DSV secret", 0)
	}
	if s, ok := jsonString(raw); ok {
		return s, nil
	}
	v, err := pyDumpRaw(raw)
	if err != nil {
		return "", fetchErr("DSV secret response malformed", 0)
	}
	return v, nil
}
