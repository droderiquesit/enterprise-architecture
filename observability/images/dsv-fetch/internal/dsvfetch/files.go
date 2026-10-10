package dsvfetch

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
)

// decodeStringObject decodes a JSON object whose values are all strings, keeping key order (duplicates: first
// position, last value).
func decodeStringObject(raw []byte) ([][2]string, bool) {
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 || raw[0] != '{' {
		return nil, false
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	if _, err := dec.Token(); err != nil {
		return nil, false
	}
	var out [][2]string
	idx := map[string]int{}
	for dec.More() {
		kt, err := dec.Token()
		if err != nil {
			return nil, false
		}
		k, _ := kt.(string)
		var v json.RawMessage
		if err := dec.Decode(&v); err != nil {
			return nil, false
		}
		s, ok := jsonString(v)
		if !ok {
			return nil, false
		}
		if i, seen := idx[k]; seen {
			out[i][1] = s
		} else {
			idx[k] = len(out)
			out = append(out, [2]string{k, s})
		}
	}
	return out, true
}

// parseAgentRequest validates {"version": "1.x", "secrets": ["...", ...]} like the 1.x implementation
// (str(version).startswith("1."), secrets a list of strings).
func parseAgentRequest(raw []byte) ([]string, bool) {
	raw = bytes.TrimPrefix(raw, []byte("\xef\xbb\xbf")) // json.loads(bytes) accepts a UTF-8 BOM
	trim := bytes.TrimSpace(raw)
	if len(trim) == 0 || trim[0] != '{' || !json.Valid(trim) {
		return nil, false
	}
	var req map[string]json.RawMessage
	if json.Unmarshal(trim, &req) != nil {
		return nil, false
	}
	vraw, ok := req["version"]
	if !ok {
		return nil, false
	}
	version, ok := pyStr(vraw)
	if !ok || len(version) < 2 || version[:2] != "1." {
		return nil, false
	}
	sraw := bytes.TrimSpace(req["secrets"])
	if len(sraw) == 0 || sraw[0] != '[' {
		return nil, false
	}
	var items []json.RawMessage
	if json.Unmarshal(sraw, &items) != nil {
		return nil, false
	}
	handles := make([]string, 0, len(items))
	for _, it := range items {
		s, ok := jsonString(it)
		if !ok {
			return nil, false
		}
		handles = append(handles, s)
	}
	return handles, true
}

// makeOutDir is os.makedirs(out, mode=0o700, exist_ok=True): parents default mode, the leaf 0700 (umask applies).
func makeOutDir(out string) error {
	if st, err := os.Stat(out); err == nil {
		if !st.IsDir() {
			return &os.PathError{Op: "mkdir", Path: out, Err: errors.New("file exists")}
		}
		return nil
	}
	if parent := filepath.Dir(filepath.Clean(out)); parent != "" {
		if err := os.MkdirAll(parent, 0o777); err != nil {
			return err
		}
	}
	if err := os.Mkdir(out, 0o700); err != nil && !errors.Is(err, os.ErrExist) {
		return err
	}
	return nil
}

// writeAtomic writes DIR/NAME through a temp file in DIR (mode set before any byte is written) + rename, so a
// restarted init container replaces its read-only files.
func writeAtomic(dir, name string, data []byte, mode int64) (err error) {
	f, err := os.CreateTemp(dir, ".dsv-fetch-*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	defer func() {
		if err != nil {
			f.Close()
			os.Remove(tmp)
		}
	}()
	if err = setFileMode(f, mode); err != nil {
		return err
	}
	if _, err = f.Write(data); err != nil {
		return err
	}
	if err = f.Sync(); err != nil {
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	dest := filepath.Join(dir, name)
	prepareReplace(dest)
	return os.Rename(tmp, dest)
}

// ------------------------------------------------------------------------------------------------ install

// selfExecutable opens the running binary (Linux: /proc/self/exe, valid even if the file was replaced meanwhile).
func selfExecutable() (*os.File, error) {
	if runtime.GOOS == "linux" {
		if f, err := os.Open("/proc/self/exe"); err == nil {
			return f, nil
		}
	}
	p, err := os.Executable()
	if err != nil {
		return nil, err
	}
	return os.Open(p)
}

func cmdInstall(args parsed, std Std) error {
	dest, err := filepath.Abs(args.get("dest"))
	if err != nil {
		return usagef("--dest must be a path")
	}
	owner, err := resolveOwner(args.get("owner"))
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return fmt.Errorf("install failed (%s)", pyTypeName(err))
	}
	src, err := selfExecutable()
	if err != nil {
		return fmt.Errorf("install failed: cannot read the running executable (%s)", pyTypeName(err))
	}
	defer src.Close()
	f, err := os.CreateTemp(filepath.Dir(dest), ".dsv-fetch-*")
	if err != nil {
		return fmt.Errorf("install failed (%s)", pyTypeName(err))
	}
	tmp := f.Name()
	fail := func(stage string, e error) error {
		f.Close()
		os.Remove(tmp)
		return fmt.Errorf("install failed: %s (%s)", stage, pyTypeName(e))
	}
	if err := restrictExecutable(f, owner); err != nil { // mode 0500 + chown (POSIX); no-op on Windows (ACL below)
		return fail("set mode/owner", err)
	}
	if _, err := io.Copy(f, src); err != nil {
		return fail("copy", err)
	}
	if err := f.Sync(); err != nil {
		return fail("sync", err)
	}
	if err := f.Close(); err != nil {
		return fail("close", err)
	}
	if err := restrictExecutableACL(tmp, owner); err != nil { // Windows: icacls; no-op on POSIX
		os.Remove(tmp)
		return err
	}
	prepareReplace(dest)
	if err := os.Rename(tmp, dest); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("install failed: rename (%s)", pyTypeName(err))
	}
	ownerJSON := pyQuote(owner.name)
	if owner.name == "" {
		ownerJSON = strconv.Itoa(os.Getuid())
	}
	fmt.Fprintln(std.Err, pyObject("dsv_fetch", pyQuote("install"), "dest", pyQuote(dest), "mode", pyQuote(owner.modeLabel()), "owner", ownerJSON))
	return nil
}
