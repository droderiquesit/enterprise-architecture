package dsvfetch

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/rand/v2"
	"net"
	"net/http"
	"strings"
	"time"
)

// userAgentVersion is the version in the User-Agent header (set by Main).
var userAgentVersion = "0.0.0-dev"

// sleep is replaced in unit tests.
var sleep = time.Sleep

type request struct {
	method   string
	url      string
	headers  [][2]string
	body     []byte
	timeout  float64
	attempts int
	retry    map[int]bool // retried statuses besides 5xx
	proxy    bool         // false: IMDS / IDENTITY_ENDPOINT, never via a proxy
}

type httpClient struct {
	direct  *http.Transport
	proxied *http.Transport
}

func newHTTPClient() *httpClient {
	mk := func(proxy bool) *http.Transport {
		t := &http.Transport{
			ForceAttemptHTTP2:   true,
			DisableCompression:  true, // like urllib: no Accept-Encoding; the size limit applies to what is sent
			MaxIdleConnsPerHost: 2,
			IdleConnTimeout:     30 * time.Second,
		}
		if proxy {
			t.Proxy = http.ProxyFromEnvironment // DSV / Entra: honour HTTPS_PROXY / NO_PROXY
		}
		return t
	}
	return &httpClient{direct: mk(false), proxied: mk(true)}
}

// do performs a JSON request with retries: connection errors, timeouts, 5xx and r.retry statuses are retried with
// full-jitter backoff (<= 2 s); other non-2xx statuses fail at once. Redirects are never followed. Returns the JSON
// object or a value-free *FetchError.
func (h *httpClient) do(r request) (map[string]json.RawMessage, error) {
	if s, _ := splitSchemeHost(r.url); s != "http" && s != "https" {
		return nil, fetchErr("only http(s) URLs are allowed", 0)
	}
	attempts := max(1, r.attempts)
	tr := h.direct
	if r.proxy {
		tr = h.proxied
	}
	timeout := time.Duration(r.timeout * float64(time.Second))
	client := &http.Client{
		Transport:     tr,
		Timeout:       timeout,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	for attempt := 1; attempt <= attempts; attempt++ {
		var body io.Reader
		if r.body != nil {
			body = bytes.NewReader(r.body)
		}
		req, err := http.NewRequest(r.method, r.url, body)
		if err != nil {
			return nil, fetchErr("unreachable (InvalidURL)", 0)
		}
		req.Header.Set("Accept", "application/json")
		req.Header.Set("User-Agent", "dsv-fetch/"+userAgentVersion)
		for _, kv := range r.headers {
			req.Header.Set(kv[0], kv[1])
		}
		resp, err := client.Do(req)
		if err == nil {
			raw, rerr := io.ReadAll(io.LimitReader(resp.Body, maxResponse+1))
			resp.Body.Close()
			switch {
			case rerr != nil:
				err = rerr // read failure (reset / timeout): retried like a connection error
			case resp.StatusCode < 200 || resp.StatusCode > 299:
				code := resp.StatusCode
				if !(code >= 500 || r.retry[code]) {
					return nil, fetchErr(fmt.Sprintf("HTTP %d", code), code)
				}
				if attempt >= attempts {
					return nil, fetchErr(fmt.Sprintf("HTTP %d after %d attempts", code, r.attempts), code)
				}
			default:
				return parseObject(raw)
			}
		}
		if err != nil && attempt >= attempts {
			return nil, fetchErr(fmt.Sprintf("unreachable (%s)", netErrKind(err)), 0)
		}
		backoff := min(2.0, 0.25*float64(int64(1)<<min(attempt-1, 30)))
		sleep(time.Duration(rand.Float64() * backoff * float64(time.Second)))
	}
	return nil, fetchErr("unreachable", 0)
}

func parseObject(raw []byte) (map[string]json.RawMessage, error) {
	if len(raw) > maxResponse {
		return nil, fetchErr("response too large", 0)
	}
	trim := bytes.TrimSpace(raw)
	if len(trim) == 0 || !json.Valid(trim) {
		return nil, fetchErr("response is not JSON", 0)
	}
	var doc map[string]json.RawMessage
	if trim[0] != '{' || json.Unmarshal(trim, &doc) != nil {
		return nil, fetchErr("response is not a JSON object", 0)
	}
	return doc, nil
}

// netErrKind names the error class like the 1.x implementation (Python exception names), never a value.
func netErrKind(err error) string {
	var ne net.Error
	var dns *net.DNSError
	var ua x509.UnknownAuthorityError
	var hn x509.HostnameError
	var ci x509.CertificateInvalidError
	var tv *tls.CertificateVerificationError
	var rh tls.RecordHeaderError
	msg := strings.ToLower(err.Error())
	switch {
	case errors.As(err, &dns):
		return "gaierror"
	case errors.As(err, &ua), errors.As(err, &hn), errors.As(err, &ci), errors.As(err, &tv):
		return "SSLCertVerificationError"
	case errors.As(err, &rh):
		return "SSLError"
	case errors.As(err, &ne) && ne.Timeout():
		return "TimeoutError"
	case strings.Contains(msg, "refused"):
		return "ConnectionRefusedError"
	case strings.Contains(msg, "reset by peer"), strings.Contains(msg, "forcibly closed"):
		return "ConnectionResetError"
	case errors.Is(err, io.EOF), errors.Is(err, io.ErrUnexpectedEOF), strings.Contains(msg, "server closed"):
		return "RemoteDisconnected"
	case strings.Contains(msg, "proxyconnect"):
		return "ProxyError"
	}
	return "OSError"
}
