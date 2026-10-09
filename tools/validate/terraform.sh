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

cleanup() { if [[ "$clean" == "--clean" ]]; then rm -rf "${dir:?}/.terraform"; fi; }
trap cleanup EXIT

step "fmt -check"
terraform -chdir="$dir" fmt -check -recursive -diff -no-color

init_args=(-backend=false -input=false -no-color)
if [[ -f "$dir/.terraform.lock.hcl" ]]; then init_args+=(-lockfile=readonly); fi
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
  tflint --chdir="$dir" --no-color
fi
step "OK"
