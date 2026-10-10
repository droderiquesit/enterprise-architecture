//go:build !windows

package dsvfetch

import (
	"os"
	"os/user"
	"strconv"
	"syscall"
)

type ownerSpec struct {
	name     string
	uid, gid int
}

func (ownerSpec) modeLabel() string { return "0500" }

// resolveOwner looks the user up in /etc/passwd (pure Go, CGO_ENABLED=0: no NSS/LDAP). A numeric uid is accepted
// too (gid = uid unless the passwd entry says otherwise), e.g. for distroless images without the Agent's user.
func resolveOwner(name string) (ownerSpec, error) {
	if name == "" {
		return ownerSpec{uid: -1, gid: -1}, nil
	}
	u, err := user.Lookup(name)
	if err != nil {
		if n, nerr := strconv.Atoi(name); nerr == nil && n >= 0 {
			if u2, e2 := user.LookupId(name); e2 == nil {
				g, _ := strconv.Atoi(u2.Gid)
				return ownerSpec{name: name, uid: n, gid: g}, nil
			}
			return ownerSpec{name: name, uid: n, gid: n}, nil
		}
		return ownerSpec{}, usagef("unknown user %s", pyRepr(name))
	}
	uid, _ := strconv.Atoi(u.Uid)
	gid, _ := strconv.Atoi(u.Gid)
	return ownerSpec{name: name, uid: uid, gid: gid}, nil
}

// restrictExecutable: mode 0500 (owner read+execute only) and, when an owner is given, chown (needs root) - what the
// Datadog Agent requires of secret_backend_command.
func restrictExecutable(f *os.File, o ownerSpec) error {
	if err := syscall.Fchmod(int(f.Fd()), 0o500); err != nil {
		return err
	}
	if o.uid != -1 {
		return f.Chown(o.uid, o.gid)
	}
	return nil
}

func restrictExecutableACL(string, ownerSpec) error { return nil }

// setFileMode sets the exact mode bits (like os.fchmod, umask not applied).
func setFileMode(f *os.File, mode int64) error { return syscall.Fchmod(int(f.Fd()), uint32(mode)) }

func prepareReplace(string) {}
