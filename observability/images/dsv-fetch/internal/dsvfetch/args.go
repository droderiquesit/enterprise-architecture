package dsvfetch

// A small argparse-compatible option parser: long options only, "--opt value" and "--opt=value", unique-prefix
// abbreviations, repeatable options, required options, choices, -h/--help. Errors print the usage line plus
// "<prog>: error: <message>" to stderr and exit 2, exactly like the 1.x Python (argparse) implementation.

import (
	"fmt"
	"regexp"
	"slices"
	"strings"
)

type optSpec struct {
	name     string // without leading "--"
	value    bool   // takes a value (otherwise store_true)
	repeat   bool
	required bool
	choices  []string
	def      string
	metavar  string
	help     string
}

type cmdSpec struct {
	name string
	help string
	opts []optSpec
}

type parsed struct {
	values map[string][]string
	flags  map[string]bool
}

func (p parsed) get(name string) string {
	v := p.values[name]
	if len(v) == 0 {
		return ""
	}
	return v[len(v)-1]
}

type argError struct {
	usage string
	prog  string
	msg   string
}

func (e *argError) Error() string { return e.msg }

type helpRequested struct{ text string }

func (h *helpRequested) Error() string { return "help" }

var negNumRE = regexp.MustCompile(`^-\d+$|^-\d*\.\d+$`)

func (c cmdSpec) usage(prog string) string {
	parts := []string{"usage: " + prog + " " + c.name, "[-h]"}
	for _, o := range c.opts {
		s := "--" + o.name
		if o.value {
			s += " " + o.meta()
		}
		if !o.required {
			s = "[" + s + "]"
		}
		parts = append(parts, s)
	}
	return strings.Join(parts, " ")
}

func (o optSpec) meta() string {
	if o.metavar != "" {
		return o.metavar
	}
	if len(o.choices) > 0 {
		return "{" + strings.Join(o.choices, ",") + "}"
	}
	return strings.ToUpper(strings.ReplaceAll(o.name, "-", "_"))
}

func (c cmdSpec) helpText(prog string) string {
	var b strings.Builder
	b.WriteString(c.usage(prog) + "\n\n")
	if c.help != "" {
		b.WriteString(c.help + "\n\n")
	}
	b.WriteString("options:\n  -h, --help            show this help message and exit\n")
	for _, o := range c.opts {
		flag := "--" + o.name
		if o.value {
			flag += " " + o.meta()
		}
		help := o.help
		if o.def != "" && !strings.Contains(help, "default") {
			help = strings.TrimSpace(help + " (default: " + o.def + ")")
		}
		if len(flag) <= 20 {
			fmt.Fprintf(&b, "  %-22s%s\n", flag, help)
		} else {
			fmt.Fprintf(&b, "  %s\n                        %s\n", flag, help)
		}
	}
	return b.String()
}

func (c cmdSpec) parse(prog string, args []string) (parsed, error) {
	p := parsed{values: map[string][]string{}, flags: map[string]bool{}}
	fail := func(format string, a ...any) error {
		return &argError{usage: c.usage(prog), prog: prog + " " + c.name, msg: fmt.Sprintf(format, a...)}
	}
	var unknown []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "-h" || a == "--help" {
			return p, &helpRequested{c.helpText(prog)}
		}
		if a == "--" {
			unknown = append(unknown, args[i+1:]...)
			break
		}
		if !strings.HasPrefix(a, "--") || len(a) == 2 {
			unknown = append(unknown, a)
			continue
		}
		name, val, hasVal := strings.Cut(a[2:], "=")
		var spec *optSpec
		var matches []string
		for j := range c.opts {
			if c.opts[j].name == name {
				spec, matches = &c.opts[j], nil
				break
			}
			if strings.HasPrefix(c.opts[j].name, name) {
				matches = append(matches, "--"+c.opts[j].name)
				spec = &c.opts[j]
			}
		}
		if name != "help" && strings.HasPrefix("help", name) && spec == nil {
			return p, &helpRequested{c.helpText(prog)}
		}
		if len(matches) > 1 {
			return p, fail("ambiguous option: --%s could match %s", name, strings.Join(matches, ", "))
		}
		if spec == nil {
			unknown = append(unknown, a)
			continue
		}
		if !spec.value {
			if hasVal {
				return p, fail("argument --%s: ignored explicit argument %s", spec.name, pyRepr(val))
			}
			p.flags[spec.name] = true
			continue
		}
		if !hasVal {
			if i+1 >= len(args) || (strings.HasPrefix(args[i+1], "-") && args[i+1] != "-" && !negNumRE.MatchString(args[i+1])) {
				return p, fail("argument --%s: expected one argument", spec.name)
			}
			i++
			val = args[i]
		}
		if len(spec.choices) > 0 && !contains(spec.choices, val) {
			return p, fail("argument --%s: invalid choice: %s (choose from %s)", spec.name, pyRepr(val), reprList(spec.choices))
		}
		if spec.repeat {
			p.values[spec.name] = append(p.values[spec.name], val)
		} else {
			p.values[spec.name] = []string{val}
		}
	}
	var missing []string
	for _, o := range c.opts {
		if o.required && len(p.values[o.name]) == 0 {
			missing = append(missing, "--"+o.name)
		}
	}
	if len(missing) > 0 {
		return p, fail("the following arguments are required: %s", strings.Join(missing, ", "))
	}
	if len(unknown) > 0 {
		return p, &argError{usage: topUsage(prog), prog: prog, msg: "unrecognized arguments: " + strings.Join(unknown, " ")}
	}
	for _, o := range c.opts {
		if o.value && o.def != "" && len(p.values[o.name]) == 0 {
			p.values[o.name] = []string{o.def}
		}
	}
	return p, nil
}

func contains(list []string, s string) bool { return slices.Contains(list, s) }

// reprList is argparse's "'a', 'b', 'c'" listing of choices.
func reprList(items []string) string {
	q := make([]string, len(items))
	for i, s := range items {
		q[i] = pyRepr(s)
	}
	return strings.Join(q, ", ")
}
