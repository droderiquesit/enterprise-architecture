// Command dsv-fetch resolves Delinea DevOps Secrets Vault (DSV) dsv:// references with an Azure managed identity for
// containers and agents that cannot read DSV themselves (init container, Datadog Agent secret_backend_command).
// See ../../README.md. Standard library only; built with CGO_ENABLED=0 (static) by ../../build.sh.
package main

import (
	"os"

	"github.com/lab/enterprise-architecture/observability/images/dsv-fetch/internal/dsvfetch"
)

// version is set at build time: -ldflags "-X main.version=<VERSION>".
var version = "0.0.0-dev"

func main() {
	os.Exit(dsvfetch.Main(os.Args[1:], dsvfetch.Std{In: os.Stdin, Out: os.Stdout, Err: os.Stderr}, version))
}
