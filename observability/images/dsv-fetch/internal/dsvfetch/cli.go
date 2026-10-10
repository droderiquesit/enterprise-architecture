// Package dsvfetch implements the dsv-fetch command (see the README next to go.mod). Behaviour, messages and exit
// codes are identical to the 1.x Python implementation (dsv_fetch.py); the Python test suite under tests/ is the
// black-box conformance suite for both.
//
// Exit codes: 0 ok, 1 resolution failure / malformed Agent request, 2 usage or configuration error.
// Nothing ever prints a secret value except the requested output files and, for agent-backend, stdout.
package dsvfetch

import (
	"errors"
	"fmt"
	"io"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Std carries the process streams and environment (injectable for tests).
type Std struct {
	In      io.Reader
	Out     io.Writer
	Err     io.Writer
	Getenv  func(string) string // default os.Getenv
	Environ func() []string     // default os.Environ
}

const prog = "dsv-fetch"

var commands = []cmdSpec{
	{name: "init", help: "resolve references and write them to an in-memory volume", opts: []optSpec{
		{name: "out", value: true, required: true, help: "output directory (in-memory volume)"},
		{name: "format", value: true, required: true, choices: []string{"files", "env-yaml", "dotenv"}},
		{name: "map", value: true, repeat: true, metavar: "NAME=dsv://path#element"},
		{name: "map-file", value: true, help: `JSON object {"NAME": "dsv://..."}`},
		{name: "from-env", help: "also map every env var whose value is a dsv:// reference"},
		{name: "env-yaml-name", value: true, def: "fluentbit-env.yaml"},
		{name: "dotenv-name", value: true, def: ".env"},
		{name: "file-mode", value: true, def: "0400", help: "octal mode of written files: 0400 (default), 0440 (shared fsGroup) or 0444"},
		{name: "config", value: true, help: "JSON file with DSV_* / AZURE_* settings (environment wins)"},
		{name: "refresh-seconds", value: true, help: "2.x: keep running (refresher container) and re-resolve every N seconds; 0 = run once (default)"},
		{name: "retry-seconds", value: true, def: "30", help: "2.x, with --refresh-seconds: delay after a failed run"},
	}},
	{name: "agent-backend", help: "Datadog Agent secret_backend_command (stdin/stdout JSON)", opts: []optSpec{
		{name: "config", value: true, help: "JSON file with DSV_* / AZURE_* settings (environment wins)"},
	}},
	{name: "install", help: "install a copy of this binary as a Datadog Agent secret_backend_command (mode 0500 / restricted ACL)", opts: []optSpec{
		{name: "dest", value: true, required: true},
		{name: "python", value: true, help: "accepted and ignored (1.x compatibility: the binary needs no interpreter)"},
		{name: "owner", value: true, help: "user that will own the file (requires root), e.g. dd-agent; Windows: account granted read+execute (default ddagentuser)"},
	}},
	{name: "version"},
}

func commandNames() []string {
	names := make([]string, len(commands))
	for i, c := range commands {
		names[i] = c.name
	}
	return names
}

func topUsage(p string) string {
	return "usage: " + p + " [-h] {init,agent-backend,install,version} ..."
}

func topHelp() string {
	var b strings.Builder
	b.WriteString(topUsage(prog) + "\n\nResolve Delinea DSV dsv:// references (init container / Datadog Agent secret backend).\n\n")
	b.WriteString("positional arguments:\n  {init,agent-backend,install,version}\n")
	for _, c := range commands {
		if c.help != "" {
			fmt.Fprintf(&b, "    %-20s%s\n", c.name, c.help)
		} else {
			fmt.Fprintf(&b, "    %s\n", c.name)
		}
	}
	b.WriteString("\noptions:\n  -h, --help            show this help message and exit\n")
	return b.String()
}

// Main runs the CLI and returns the exit code.
func Main(argv []string, std Std, version string) int {
	if std.Getenv == nil {
		std.Getenv = os.Getenv
	}
	if std.Environ == nil {
		std.Environ = os.Environ
	}
	userAgentVersion = version
	argErr := func(e *argError) int {
		fmt.Fprintf(std.Err, "%s\n%s: error: %s\n", e.usage, e.prog, e.msg)
		return 2
	}
	if len(argv) == 0 {
		return argErr(&argError{usage: topUsage(prog), prog: prog, msg: "the following arguments are required: command"})
	}
	first := argv[0]
	if first == "-h" || first == "--help" {
		fmt.Fprint(std.Out, topHelp())
		return 0
	}
	var spec *cmdSpec
	for i := range commands {
		if commands[i].name == first {
			spec = &commands[i]
		}
	}
	if spec == nil {
		if strings.HasPrefix(first, "-") {
			return argErr(&argError{usage: topUsage(prog), prog: prog, msg: "the following arguments are required: command"})
		}
		return argErr(&argError{usage: topUsage(prog), prog: prog,
			msg: fmt.Sprintf("argument command: invalid choice: %s (choose from %s)", pyRepr(first), reprList(commandNames()))})
	}
	args, err := spec.parse(prog, argv[1:])
	var ae *argError
	var hr *helpRequested
	switch {
	case errors.As(err, &hr):
		fmt.Fprint(std.Out, hr.text)
		return 0
	case errors.As(err, &ae):
		return argErr(ae)
	}
	switch spec.name {
	case "init":
		err = cmdInitLoop(args, std)
	case "agent-backend":
		err = cmdAgentBackend(args, std)
	case "install":
		err = cmdInstall(args, std)
	default:
		fmt.Fprintln(std.Out, version)
		return 0
	}
	var ue *UsageError
	var fe *FetchError
	var ex exitCode
	switch {
	case err == nil:
		return 0
	case errors.As(err, &ex):
		return int(ex)
	case errors.As(err, &ue):
		fmt.Fprintf(std.Err, "dsv-fetch: %s\n", ue.Msg)
		return 2
	case errors.As(err, &fe):
		fmt.Fprintf(std.Err, "dsv-fetch: %s\n", fe.Reason)
		return 1
	}
	fmt.Fprintf(std.Err, "dsv-fetch: %s\n", err)
	return 1
}

// exitCode ends a command with a code after it printed its own messages.
type exitCode int

func (e exitCode) Error() string { return "exit " + strconv.Itoa(int(e)) }

// --------------------------------------------------------------------------------------------------- init

type orderedMap struct {
	keys []string
	m    map[string]string
}

func (o *orderedMap) set(k, v string) {
	if o.m == nil {
		o.m = map[string]string{}
	}
	if _, ok := o.m[k]; !ok {
		o.keys = append(o.keys, k)
	}
	o.m[k] = v
}

func collectMaps(args parsed, std Std) (*orderedMap, error) {
	maps := &orderedMap{}
	if f := args.get("map-file"); f != "" {
		raw, err := readJSONFile(f)
		if err != nil {
			return nil, usagef("cannot read --map-file (%s)", pyTypeName(err))
		}
		pairs, ok := decodeStringObject(raw)
		if !ok {
			return nil, usagef(`--map-file must be a JSON object {"NAME": "dsv://..."}`)
		}
		for _, kv := range pairs {
			maps.set(kv[0], kv[1])
		}
	}
	if args.flags["from-env"] {
		for _, kv := range std.Environ() {
			k, v, ok := strings.Cut(kv, "=")
			if ok && strings.HasPrefix(v, refPrefix) && !strings.HasPrefix(k, "DSV_") {
				maps.set(k, v)
			}
		}
	}
	for _, item := range args.values["map"] {
		name, ref, ok := strings.Cut(item, "=")
		if !ok {
			return nil, usagef("--map must be NAME=dsv://path#element")
		}
		maps.set(name, ref)
	}
	if len(maps.keys) == 0 {
		return nil, usagef("nothing to fetch: give --map, --map-file or --from-env")
	}
	format := args.get("format")
	re := envNameRE
	if format == "files" {
		re = fileRE
	}
	for _, name := range maps.keys {
		if !re.MatchString(name) {
			return nil, usagef("invalid NAME %s for --format %s", pyRepr(name), format)
		}
		if !strings.HasPrefix(maps.m[name], refPrefix) {
			return nil, usagef("%s: value must be a dsv:// reference", name)
		}
	}
	return maps, nil
}

// parseOctal is int(s, 8): optional sign, optional 0o prefix, underscores between digits.
func parseOctal(s string) (int64, bool) {
	s = strings.TrimSpace(s)
	neg := false
	if strings.HasPrefix(s, "+") || strings.HasPrefix(s, "-") {
		neg = s[0] == '-'
		s = s[1:]
	}
	if strings.HasPrefix(s, "0o") || strings.HasPrefix(s, "0O") {
		s = strings.TrimPrefix(s[2:], "_")
	}
	if s == "" || strings.HasPrefix(s, "_") || strings.HasSuffix(s, "_") || strings.Contains(s, "__") {
		return 0, false
	}
	v, err := strconv.ParseInt(strings.ReplaceAll(s, "_", ""), 8, 64)
	if err != nil {
		return 0, false
	}
	if neg {
		v = -v
	}
	return v, true
}

// refreshSleep is replaced in unit tests; it returns false to stop the loop.
var refreshSleep = func(d time.Duration) bool { time.Sleep(d); return true }

// cmdInitLoop runs init once, or with --refresh-seconds N forever (the ACI / ACA-dedicated "refresher" container that
// replaces the 1.x Python stub): a run that ends in a usage/configuration error exits 2 at once; after any other run it
// sleeps N seconds (success) or --retry-seconds (failure) and resolves everything again with a fresh token.
func cmdInitLoop(args parsed, std Std) error {
	refresh, err := settingFloat(map[string]string{"--refresh-seconds": args.get("refresh-seconds")}, "--refresh-seconds", 0, 0)
	if err != nil {
		return err
	}
	retry, err := settingFloat(map[string]string{"--retry-seconds": args.get("retry-seconds")}, "--retry-seconds", 30, 1)
	if err != nil {
		return err
	}
	if refresh == 0 {
		return cmdInit(args, std)
	}
	if refresh < 1 {
		return usagef("--refresh-seconds must be 0 or >= 1")
	}
	for {
		err := cmdInit(args, std)
		var ue *UsageError
		if errors.As(err, &ue) {
			return err
		}
		wait := refresh
		if err != nil {
			var ex exitCode
			var fe *FetchError
			if !errors.As(err, &ex) {
				if errors.As(err, &fe) {
					fmt.Fprintf(std.Err, "dsv-fetch: %s\n", fe.Reason)
				} else {
					fmt.Fprintf(std.Err, "dsv-fetch: %s\n", err)
				}
			}
			wait = retry
		}
		if !refreshSleep(time.Duration(wait * float64(time.Second))) {
			return err
		}
	}
}

func cmdInit(args parsed, std Std) error {
	maps, err := collectMaps(args, std)
	if err != nil {
		return err
	}
	mode, ok := parseOctal(args.get("file-mode"))
	if !ok {
		return usagef("--file-mode must be octal (e.g. 0400)")
	}
	if mode&0o333 != 0 || mode&0o400 == 0 {
		return usagef("--file-mode must be read-only for the owner (0400, 0440 or 0444)")
	}
	settings, err := loadSettings(args.get("config"), std.Getenv)
	if err != nil {
		return err
	}
	client, err := NewClient(settings)
	if err != nil {
		return err
	}
	names := append([]string(nil), maps.keys...)
	sort.Strings(names)
	values := map[string]string{}
	var failures []string
	for _, name := range names {
		v, err := client.Resolve(maps.m[name])
		var fe *FetchError
		switch {
		case err == nil:
			values[name] = v
		case errors.As(err, &fe):
			failures = append(failures, name+": "+fe.Reason)
		default:
			return err
		}
	}
	if len(failures) > 0 {
		for _, f := range failures {
			fmt.Fprintf(std.Err, "dsv-fetch: %s\n", f)
		}
		fmt.Fprintf(std.Err, "dsv-fetch: %d of %d reference(s) failed; nothing written\n", len(failures), len(names))
		return exitCode(1)
	}
	out := args.get("out")
	if err := makeOutDir(out); err != nil {
		return fmt.Errorf("cannot create --out directory (%s)", pyTypeName(err))
	}
	format := args.get("format")
	var written []string
	switch format {
	case "files":
		for _, name := range names {
			if err := writeAtomic(out, name, []byte(values[name]), mode); err != nil {
				return fmt.Errorf("cannot write %s (%s)", name, pyTypeName(err))
			}
		}
		written = names
	case "env-yaml":
		var b strings.Builder
		b.WriteString("# written by dsv-fetch - Fluent Bit YAML env section; do not edit\nenv:\n")
		for _, n := range names {
			b.WriteString("  " + n + ": " + pyQuote(values[n]) + "\n") // a JSON string is a valid YAML double-quoted scalar
		}
		fn := args.get("env-yaml-name")
		if err := writeAtomic(out, fn, []byte(b.String()), mode); err != nil {
			return fmt.Errorf("cannot write %s (%s)", fn, pyTypeName(err))
		}
		written = []string{fn}
	default:
		var b strings.Builder
		for _, n := range names {
			v := values[n]
			if strings.ContainsAny(v, "\n\r\x00") {
				return fetchErr(fmt.Sprintf("value of %s contains a newline; not representable in dotenv", n), 0)
			}
			r := strings.NewReplacer(`\`, `\\`, `"`, `\"`, `$`, `\$`, "`", "\\`")
			b.WriteString(n + `="` + r.Replace(v) + "\"\n")
		}
		fn := args.get("dotenv-name")
		if err := writeAtomic(out, fn, []byte(b.String()), mode); err != nil {
			return fmt.Errorf("cannot write %s (%s)", fn, pyTypeName(err))
		}
		written = []string{fn}
	}
	fmt.Fprintln(std.Err, pyObject(
		"dsv_fetch", pyQuote("init"), "format", pyQuote(format), "out", pyQuote(out),
		"names", pyList(names), "files", pyList(written), "mode", pyQuote(fmt.Sprintf("%04o", mode)),
	))
	return nil
}

// ------------------------------------------------------------------------------------------ agent backend

func cmdAgentBackend(args parsed, std Std) error {
	raw, _ := io.ReadAll(io.LimitReader(std.In, maxAgentInput+1))
	if len(raw) > maxAgentInput {
		fmt.Fprintln(std.Err, "dsv-fetch: agent request too large")
		return exitCode(1)
	}
	handles, ok := parseAgentRequest(raw)
	if !ok {
		fmt.Fprintln(std.Err, `dsv-fetch: malformed agent request (expected {"version":"1.0","secrets":[...]})`)
		return exitCode(1)
	}
	var client *Client
	setupError := ""
	settings, err := loadSettings(args.get("config"), std.Getenv)
	if err == nil {
		client, err = NewClient(settings)
	}
	if err != nil {
		var ue *UsageError
		if !errors.As(err, &ue) {
			return err
		}
		setupError = "dsv-fetch configuration error: " + ue.Msg
	}
	out := &orderedMap{}
	for _, h := range handles {
		if setupError != "" {
			out.set(h, pyObject("value", "null", "error", pyQuote(setupError)))
			continue
		}
		v, err := client.Resolve(h)
		var fe *FetchError
		switch {
		case err == nil:
			out.set(h, pyObject("value", pyQuote(v), "error", "null"))
		case errors.As(err, &fe):
			out.set(h, pyObject("value", "null", "error", pyQuote(fe.Reason)))
		default:
			return err // configuration error found while resolving (e.g. workload identity settings): exit 2
		}
	}
	pairs := make([]string, 0, 2*len(out.keys))
	for _, k := range out.keys {
		pairs = append(pairs, k, out.m[k])
	}
	_, err = io.WriteString(std.Out, pyObject(pairs...))
	return err
}
