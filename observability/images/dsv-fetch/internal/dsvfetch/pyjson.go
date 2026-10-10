package dsvfetch

// Byte-compatible re-implementation of the bits of Python's json.dumps / str() / repr() whose output the 1.x Python
// implementation (dsv_fetch.py) produced, so consumers and tests see identical files and messages:
// json.dumps(..., ensure_ascii=True) with the default ", " / ": " separators, float repr, and repr() of a str.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

// pyQuote is json.dumps(s) (ensure_ascii=True): everything outside ' '..'~' is escaped.
func pyQuote(s string) string {
	var b strings.Builder
	b.Grow(len(s) + 2)
	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		case '\b':
			b.WriteString(`\b`)
		case '\f':
			b.WriteString(`\f`)
		default:
			switch {
			case r >= 0x20 && r <= 0x7e:
				b.WriteRune(r)
			case r > 0xffff:
				v := r - 0x10000
				fmt.Fprintf(&b, `\u%04x\u%04x`, 0xd800|((v>>10)&0x3ff), 0xdc00|(v&0x3ff))
			default:
				fmt.Fprintf(&b, `\u%04x`, r)
			}
		}
	}
	b.WriteByte('"')
	return b.String()
}

// pyFloatRepr is Python's repr(float) (shortest round-trip, scientific outside 1e-4 <= |x| < 1e16).
func pyFloatRepr(f float64) string {
	switch {
	case math.IsInf(f, 1):
		return "Infinity" // json.dumps spelling
	case math.IsInf(f, -1):
		return "-Infinity"
	case math.IsNaN(f):
		return "NaN"
	}
	if f == 0 {
		if math.Signbit(f) {
			return "-0.0"
		}
		return "0.0"
	}
	e := strconv.FormatFloat(f, 'e', -1, 64)
	exp, _ := strconv.Atoi(e[strings.IndexByte(e, 'e')+1:])
	if exp >= -4 && exp < 16 {
		s := strconv.FormatFloat(f, 'f', -1, 64)
		if !strings.ContainsRune(s, '.') {
			s += ".0"
		}
		return s
	}
	return e
}

// pyNumber renders a JSON number literal the way Python prints the value json.loads made of it (int or float).
func pyNumber(lit string) string {
	if !strings.ContainsAny(lit, ".eE") {
		if lit == "-0" {
			return "0"
		}
		return lit
	}
	f, _ := strconv.ParseFloat(lit, 64) // a range error still returns ±Inf, like Python's float()
	return pyFloatRepr(f)
}

// pyDumpRaw re-serialises a JSON value the way json.dumps(json.loads(raw)) does (key order kept; for duplicate keys
// the first position and the last value, like a Python dict).
func pyDumpRaw(raw []byte) (string, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	s, err := pyDumpValue(dec)
	if err != nil {
		return "", err
	}
	if _, err := dec.Token(); err != io.EOF {
		return "", fmt.Errorf("trailing data")
	}
	return s, nil
}

func pyDumpValue(dec *json.Decoder) (string, error) {
	tok, err := dec.Token()
	if err != nil {
		return "", err
	}
	switch t := tok.(type) {
	case json.Delim:
		switch t {
		case '{':
			var keys []string
			vals := map[string]string{}
			for dec.More() {
				kt, err := dec.Token()
				if err != nil {
					return "", err
				}
				k, _ := kt.(string)
				v, err := pyDumpValue(dec)
				if err != nil {
					return "", err
				}
				if _, seen := vals[k]; !seen {
					keys = append(keys, k)
				}
				vals[k] = v
			}
			if _, err := dec.Token(); err != nil {
				return "", err
			}
			parts := make([]string, len(keys))
			for i, k := range keys {
				parts[i] = pyQuote(k) + ": " + vals[k]
			}
			return "{" + strings.Join(parts, ", ") + "}", nil
		case '[':
			var parts []string
			for dec.More() {
				v, err := pyDumpValue(dec)
				if err != nil {
					return "", err
				}
				parts = append(parts, v)
			}
			if _, err := dec.Token(); err != nil {
				return "", err
			}
			return "[" + strings.Join(parts, ", ") + "]", nil
		}
		return "", fmt.Errorf("unexpected delimiter")
	case string:
		return pyQuote(t), nil
	case json.Number:
		return pyNumber(string(t)), nil
	case bool:
		if t {
			return "true", nil
		}
		return "false", nil
	case nil:
		return "null", nil
	}
	return "", fmt.Errorf("unexpected token")
}

// pyStr is Python's str() of a json.loads value given as raw JSON (only scalars are needed).
func pyStr(raw json.RawMessage) (string, bool) {
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 {
		return "", false
	}
	switch raw[0] {
	case '"':
		var s string
		if json.Unmarshal(raw, &s) != nil {
			return "", false
		}
		return s, true
	case 't':
		return "True", true
	case 'f':
		return "False", true
	case 'n':
		return "None", true
	case '{', '[':
		return "", false
	}
	return pyNumber(string(raw)), true
}

// pyRepr is Python's repr() of a str (used in "invalid NAME 'x'" messages).
func pyRepr(s string) string {
	q := byte('\'')
	if strings.ContainsRune(s, '\'') && !strings.ContainsRune(s, '"') {
		q = '"'
	}
	var b strings.Builder
	b.WriteByte(q)
	for i, w := 0, 0; i < len(s); i += w {
		r, width := utf8.DecodeRuneInString(s[i:])
		w = width
		switch {
		case r == utf8.RuneError && width == 1:
			fmt.Fprintf(&b, `\x%02x`, s[i])
		case r == '\\':
			b.WriteString(`\\`)
		case r == rune(q):
			b.WriteByte('\\')
			b.WriteByte(q)
		case r == '\n':
			b.WriteString(`\n`)
		case r == '\r':
			b.WriteString(`\r`)
		case r == '\t':
			b.WriteString(`\t`)
		case r < 0x20 || r == 0x7f:
			fmt.Fprintf(&b, `\x%02x`, r)
		case r < 0x80 || unicode.IsPrint(r):
			b.WriteRune(r)
		case r <= 0xff:
			fmt.Fprintf(&b, `\x%02x`, r)
		case r <= 0xffff:
			fmt.Fprintf(&b, `\u%04x`, r)
		default:
			fmt.Fprintf(&b, `\U%08x`, r)
		}
	}
	b.WriteByte(q)
	return b.String()
}

// pyObject renders an ordered JSON object with Python's default separators from already-encoded values.
func pyObject(pairs ...string) string {
	parts := make([]string, 0, len(pairs)/2)
	for i := 0; i+1 < len(pairs); i += 2 {
		parts = append(parts, pyQuote(pairs[i])+": "+pairs[i+1])
	}
	return "{" + strings.Join(parts, ", ") + "}"
}

func pyList(items []string) string {
	q := make([]string, len(items))
	for i, s := range items {
		q[i] = pyQuote(s)
	}
	return "[" + strings.Join(q, ", ") + "]"
}
