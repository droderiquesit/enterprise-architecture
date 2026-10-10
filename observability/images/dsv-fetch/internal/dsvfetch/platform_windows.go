//go:build windows

package dsvfetch

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

type ownerSpec struct {
	name     string
	uid, gid int
}

func (ownerSpec) modeLabel() string { return "acl" }

// defaultWindowsOwner is the account the Datadog Agent runs as on Windows.
const defaultWindowsOwner = "ddagentuser"

func resolveOwner(name string) (ownerSpec, error) {
	if name == "" {
		name = defaultWindowsOwner
	}
	if strings.ContainsAny(name, "\"\r\n") {
		return ownerSpec{}, usagef("unknown user %s", pyRepr(name))
	}
	return ownerSpec{name: name}, nil
}

func restrictExecutable(*os.File, ownerSpec) error { return nil }

// restrictExecutableACL applies the Datadog Agent's Windows secret_backend_command rule: no rights for anyone except
// the Agent user (read + execute), SYSTEM and the Administrators group. icacls.exe (part of every Windows install) is
// used instead of golang.org/x/sys/windows so the module stays standard-library only:
//
//	icacls <file> /inheritance:r /grant:r <owner>:(RX) *S-1-5-18:(F) *S-1-5-32-544:(F)
//
// Inherited ACEs are removed (/inheritance:r) and the three explicit grants replace any explicit ACEs. Runs on the
// temp file before the rename, so the destination never exists with a broader ACL (needs an elevated installer).
func restrictExecutableACL(path string, o ownerSpec) error {
	icacls := filepath.Join(os.Getenv("SystemRoot"), "System32", "icacls.exe")
	if os.Getenv("SystemRoot") == "" {
		icacls = "icacls.exe"
	}
	cmd := exec.Command(icacls, path, "/inheritance:r", "/grant:r", o.name+":(RX)", "*S-1-5-18:(F)", "*S-1-5-32-544:(F)")
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(out.String())
		if strings.Contains(strings.ToLower(msg), "no mapping") {
			return usagef("unknown user %s", pyRepr(o.name))
		}
		return fmt.Errorf("install failed: icacls (%v): %s", err, firstLine(msg))
	}
	return nil
}

func firstLine(s string) string {
	if i := strings.IndexAny(s, "\r\n"); i >= 0 {
		return s[:i]
	}
	return s
}

// setFileMode: Windows has no POSIX modes; a mode without owner write sets the read-only attribute (os.Chmod).
func setFileMode(f *os.File, mode int64) error { return f.Chmod(os.FileMode(mode & 0o777)) }

// prepareReplace clears the read-only attribute of an existing destination so the rename can replace it.
func prepareReplace(dest string) {
	if st, err := os.Stat(dest); err == nil && st.Mode().IsRegular() {
		_ = os.Chmod(dest, 0o600)
	}
}
