#!/usr/bin/env bash
# Static validation of one Terraform root or module directory (ADR §12):
#   terraform fmt -check, init -backend=false (lock file read-only when committed), validate,
#   terraform test (when tests/*.tftest.hcl exist), tflint (only when installed).
# Usage: tools/validate/terraform.sh <dir> [--clean]
# Exit codes: 0 ok, 1 a check failed, 2 usage / directory has no .tf files.
set -euo pipefail

dir="${1:-}"
clean="${2:-}"
if [[ -z "$dir" || ! -d "$dir" ]]; then echo "usage: $0 <terraform dir> [--clean]" >&2; exit 2; fi
if ! compgen -G "$dir/*.tf" >/dev/null; then echo "no .tf files in $dir" >&2; exit 2; fi

export TF_IN_AUTOMATION=true TF_INPUT=0
step() { printf '[%s] %s\n' "$dir" "$*"; }

had_lock=false
[[ -f "$dir/.terraform.lock.hcl" ]] && had_lock=true
cleanup() {
  if [[ "$clean" == "--clean" ]]; then rm -rf "${dir:?}/.terraform"; fi
  # never leave a lock file behind in a directory that did not commit one (shared modules)
  if [[ "$had_lock" == false ]]; then rm -f "${dir:?}/.terraform.lock.hcl"; fi
}
trap cleanup EXIT

step "fmt -check"
terraform -chdir="$dir" fmt -check -recursive -diff -no-color

init_args=(-backend=false -input=false -no-color)
if [[ "$had_lock" == true ]]; then
  init_args+=(-lockfile=readonly)
else
  # no committed lock file (shared module): reuse cached providers without checksum entries instead of
  # re-installing into a shared plugin cache that other terraform processes may be executing from
  export TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE=true
fi
step "init ${init_args[*]}"
terraform -chdir="$dir" init "${init_args[@]}" >/dev/null

step "validate"
terraform -chdir="$dir" validate -no-color

if compgen -G "$dir/tests/*.tftest.hcl" >/dev/null; then
  step "test"
  terraform -chdir="$dir" test -no-color
else
  step "test: no tests/*.tftest.hcl (skipped)"
fi

if command -v tflint >/dev/null 2>&1; then
  step "tflint"
  tflint_cfg="$(cd "$(dirname "${BASH_SOURCE[0]}")/../ci" && pwd)/tflint.hcl"   # bundled terraform ruleset, recommended
  tflint --chdir="$dir" --config="$tflint_cfg" --minimum-failure-severity=error --no-color
fi
step "OK"
