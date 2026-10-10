#!/usr/bin/env bash
# Install pinned CLI tools into $HOME/.local/bin (or $TOOLS_BIN) on a pipeline agent, verifying
# SHA-256 checksums published by each project. Idempotent: an existing binary of the requested
# version is reused. Usage:
#   pipelines/scripts/install-tools.sh terraform            # version from versions.yaml
#   pipelines/scripts/install-tools.sh gitleaks trivy syft grype helm kubeconform tflint hadolint shellcheck
#                                                       # versions: pipelines/variables/tools.yml
# Python-distributed tools (uv, ruff, yamllint, pytest-xdist) come hash-pinned from PyPI (setup-agent.sh).
# Versions for scanners come from environment variables GITLEAKS_VERSION, TRIVY_VERSION, SYFT_VERSION
# (set by pipelines/variables/tools.yml).
# Agent resilience: every downloaded archive and checksum file is also kept in $TOOL_CACHE_DIR (restored/saved by the
# Cache@2 step of steps-setup.yml, keyed by the tool versions). When a download fails (release host down, throttled,
# agent egress hiccup) the cached copy is used instead - and the checksum is ALWAYS verified, whichever copy is used.
set -euo pipefail

BIN="${TOOLS_BIN:-$HOME/.local/bin}"
mkdir -p "$BIN"
export PATH="$BIN:$PATH"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

arch() { case "$(uname -m)" in x86_64) echo amd64 ;; aarch64|arm64) echo arm64 ;; *) echo "unsupported arch" >&2; exit 1 ;; esac; }

CACHE="${TOOL_CACHE_DIR:-${PIPELINE_WORKSPACE:-$HOME}/.tool-cache}"
mkdir -p "$CACHE"

download() { # url dest  (bounded retries for transient network errors)
  curl --fail --silent --show-error --location --retry 4 --retry-delay 3 --retry-all-errors --max-time 300 -o "$2" "$1"
}

fetch() { # url dest: download (and refresh the cache) or fall back to the cached copy; callers verify checksums
  local c; c="$CACHE/$(printf %s "$1" | sha256sum | cut -c1-16)-$(basename "$1")"
  if download "$1" "$2"; then
    cp -f "$2" "$c" 2>/dev/null || true
  elif [[ -s "$c" ]]; then
    echo "##vso[task.logissue type=warning]download failed: $1 - using the cached copy (checksum verified next)"
    echo "TOOL_CACHE_FALLBACK $(basename "$1")" >&2
    cp -f "$c" "$2"
  else
    echo "##vso[task.logissue type=error]download failed and no cached copy: $1"
    return 1
  fi
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

install_helm() {
  local v="${HELM_VERSION:?HELM_VERSION not set}"; local a; a="$(arch)"
  local tgz="helm-v${v}-linux-${a}.tar.gz"
  fetch "https://get.helm.sh/${tgz}" "$WORK/$tgz"
  fetch "https://get.helm.sh/${tgz}.sha256sum" "$WORK/sums"
  verify "$WORK/$tgz" "$WORK/sums" "$tgz"
  tar -xzf "$WORK/$tgz" -C "$WORK" "linux-${a}/helm" && install -m 0755 "$WORK/linux-${a}/helm" "$BIN/helm"; helm version
}

install_kubeconform() {
  local v="${KUBECONFORM_VERSION:?KUBECONFORM_VERSION not set}"; local a; a="$(arch)"
  local tgz="kubeconform-linux-${a}.tar.gz"
  fetch "https://github.com/yannh/kubeconform/releases/download/v${v}/${tgz}" "$WORK/$tgz"
  fetch "https://github.com/yannh/kubeconform/releases/download/v${v}/CHECKSUMS" "$WORK/sums"
  verify "$WORK/$tgz" "$WORK/sums" "$tgz"
  tar -xzf "$WORK/$tgz" -C "$BIN" kubeconform; kubeconform -v
}

install_checkov() {
  local v="${CHECKOV_VERSION:?CHECKOV_VERSION not set}"
  python3 -m pip install --quiet --user "checkov==${v}"; checkov --version
}

install_tflint() {
  local v="${TFLINT_VERSION:?TFLINT_VERSION not set}"; local a; a="$(arch)"
  local zip="tflint_linux_${a}.zip"
  if command -v tflint >/dev/null && tflint --version | grep -q "version ${v}"; then echo "tflint $v present"; return; fi
  fetch "https://github.com/terraform-linters/tflint/releases/download/v${v}/${zip}" "$WORK/$zip"
  fetch "https://github.com/terraform-linters/tflint/releases/download/v${v}/checksums.txt" "$WORK/sums"
  verify "$WORK/$zip" "$WORK/sums" "$zip"
  python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extract('tflint', sys.argv[2])" "$WORK/$zip" "$BIN"
  chmod +x "$BIN/tflint"; tflint --version
}

install_hadolint() {
  # pinned container image, verified by its registry digest (HADOLINT_IMAGE = repo:tag@sha256:...)
  local img="${HADOLINT_IMAGE:?HADOLINT_IMAGE not set}"
  docker pull --quiet "$img" >/dev/null
  printf '#!/usr/bin/env bash\nexec docker run --rm -i -v "$PWD:$PWD" -w "$PWD" %s hadolint "$@"\n' "$img" > "$BIN/hadolint"
  chmod +x "$BIN/hadolint"; hadolint --version
}

install_grype() {
  local v="${GRYPE_VERSION:?GRYPE_VERSION not set}"; local a; a="$(arch)"
  local tgz="grype_${v}_linux_${a}.tar.gz"
  fetch "https://github.com/anchore/grype/releases/download/v${v}/${tgz}" "$WORK/$tgz"
  fetch "https://github.com/anchore/grype/releases/download/v${v}/grype_${v}_checksums.txt" "$WORK/sums"
  verify "$WORK/$tgz" "$WORK/sums" "$tgz"
  tar -xzf "$WORK/$tgz" -C "$BIN" grype; grype version
}

install_shellcheck() {
  # Microsoft-hosted ubuntu images ship shellcheck; shellcheck publishes no checksum file, so anywhere else the
  # pinned container image is used, verified by its registry digest (SHELLCHECK_IMAGE = repo:tag@sha256:...)
  if command -v shellcheck >/dev/null; then shellcheck --version | sed -n 2p; return; fi
  local img="${SHELLCHECK_IMAGE:?SHELLCHECK_IMAGE not set}"
  docker pull --quiet "$img" >/dev/null
  printf '#!/usr/bin/env bash\nexec docker run --rm -v "$PWD:$PWD" -w "$PWD" %s "$@"\n' "$img" > "$BIN/shellcheck"
  chmod +x "$BIN/shellcheck"; shellcheck --version | sed -n 2p
}

for tool in "$@"; do "install_${tool}"; done
# make the bin dir visible to later steps
[[ -n "${TF_BUILD:-}" ]] && echo "##vso[task.prependpath]$BIN"
exit 0
