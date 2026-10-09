#!/usr/bin/env bash
# Install pinned CLI tools into $HOME/.local/bin (or $TOOLS_BIN) on a pipeline agent, verifying
# SHA-256 checksums published by each project. Idempotent: an existing binary of the requested
# version is reused. Usage:
#   pipelines/scripts/install-tools.sh terraform            # version from versions.yaml
#   pipelines/scripts/install-tools.sh gitleaks trivy syft  # versions from pipelines/variables/tools.yml env
# Versions for scanners come from environment variables GITLEAKS_VERSION, TRIVY_VERSION, SYFT_VERSION
# (set by pipelines/variables/tools.yml).
set -euo pipefail

BIN="${TOOLS_BIN:-$HOME/.local/bin}"
mkdir -p "$BIN"
export PATH="$BIN:$PATH"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

arch() { case "$(uname -m)" in x86_64) echo amd64 ;; aarch64|arm64) echo arm64 ;; *) echo "unsupported arch" >&2; exit 1 ;; esac; }

fetch() { # url dest  (bounded retries for transient network errors)
  curl --fail --silent --show-error --location --retry 4 --retry-delay 3 --retry-all-errors --max-time 300 -o "$2" "$1"
}

verify() { # file sums-file name-in-sums
  local expected
  expected="$(grep -E "[[:space:]]\*?$3\$" "$2" | awk '{print $1}' | head -1)"
  [[ -n "$expected" ]] || { echo "checksum for $3 not found" >&2; exit 1; }
  echo "$expected  $1" | sha256sum --check --status || { echo "checksum mismatch for $3" >&2; exit 1; }
}

install_terraform() {
  local v
  v="$(python3 -c "import yaml;print(yaml.safe_load(open('$REPO_ROOT/versions.yaml'))['terraform']['cli'])")"
  if command -v terraform >/dev/null && terraform version -json | grep -q "\"terraform_version\": \"$v\""; then
    echo "terraform $v present"; return; fi
  local a; a="$(arch)"; local zip="terraform_${v}_linux_${a}.zip"
  fetch "https://releases.hashicorp.com/terraform/${v}/${zip}" "$WORK/$zip"
  fetch "https://releases.hashicorp.com/terraform/${v}/terraform_${v}_SHA256SUMS" "$WORK/sums"
  verify "$WORK/$zip" "$WORK/sums" "$zip"
  python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extract('terraform', sys.argv[2])" "$WORK/$zip" "$BIN"
  chmod +x "$BIN/terraform"; terraform version
}

install_gitleaks() {
  local v="${GITLEAKS_VERSION:?GITLEAKS_VERSION not set}"; local a; a="$(arch)"; [[ $a == amd64 ]] && a=x64
  local tgz="gitleaks_${v}_linux_${a}.tar.gz"
  fetch "https://github.com/gitleaks/gitleaks/releases/download/v${v}/${tgz}" "$WORK/$tgz"
  fetch "https://github.com/gitleaks/gitleaks/releases/download/v${v}/gitleaks_${v}_checksums.txt" "$WORK/sums"
  verify "$WORK/$tgz" "$WORK/sums" "$tgz"
  tar -xzf "$WORK/$tgz" -C "$BIN" gitleaks; gitleaks version
}

install_trivy() {
  local v="${TRIVY_VERSION:?TRIVY_VERSION not set}"; local a; a="$(arch)"; [[ $a == amd64 ]] && a=64bit || a=ARM64
  local tgz="trivy_${v}_Linux-${a}.tar.gz"
  fetch "https://github.com/aquasecurity/trivy/releases/download/v${v}/${tgz}" "$WORK/$tgz"
  fetch "https://github.com/aquasecurity/trivy/releases/download/v${v}/trivy_${v}_checksums.txt" "$WORK/sums"
  verify "$WORK/$tgz" "$WORK/sums" "$tgz"
  tar -xzf "$WORK/$tgz" -C "$BIN" trivy; trivy --version
}

install_syft() {
  local v="${SYFT_VERSION:?SYFT_VERSION not set}"; local a; a="$(arch)"
  local tgz="syft_${v}_linux_${a}.tar.gz"
  fetch "https://github.com/anchore/syft/releases/download/v${v}/${tgz}" "$WORK/$tgz"
  fetch "https://github.com/anchore/syft/releases/download/v${v}/syft_${v}_checksums.txt" "$WORK/sums"
  verify "$WORK/$tgz" "$WORK/sums" "$tgz"
  tar -xzf "$WORK/$tgz" -C "$BIN" syft; syft version
}

install_checkov() {
  local v="${CHECKOV_VERSION:?CHECKOV_VERSION not set}"
  python3 -m pip install --quiet --user "checkov==${v}"; checkov --version
}

for tool in "$@"; do "install_${tool}"; done
# make the bin dir visible to later steps
[[ -n "${TF_BUILD:-}" ]] && echo "##vso[task.prependpath]$BIN"
exit 0
