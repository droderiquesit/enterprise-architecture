#!/usr/bin/env bash
# Reproducible build of the dsv-fetch static binaries (component img-dsv-fetch). Used by the Dockerfile (builder
# stage), the platform pipeline (release files) and developers.
#
#   build.sh [--out DIR] [--version X.Y.Z] [--target GOOS/GOARCH]... [--binary FILE] [--toolchain auto|local|docker]
#
# Default: the three release targets into DIR (default ./dist) plus SHA256SUMS:
#   dsv-fetch-linux-amd64  dsv-fetch-linux-arm64  dsv-fetch-windows-amd64.exe  SHA256SUMS (sha256sum format)
# --binary FILE with exactly one --target writes just that binary (no SHA256SUMS; used by the Dockerfile).
# Flags: CGO_ENABLED=0 go build -trimpath -buildvcs=false -ldflags "-s -w -buildid= -X main.version=<VERSION>".
# Byte-identical output needs the pinned Go toolchain (GO_VERSION below, = the Dockerfile builder image):
#   --toolchain local   use `go` from PATH (or /usr/local/go/bin/go) as is (warns when it is not GO_VERSION)
#   --toolchain docker  run inside the digest-pinned golang image (GO_IMAGE), no local Go needed
#   --toolchain auto    (default) local when it is GO_VERSION, else docker when available, else local with a warning
# Exit codes: 0 ok, 1 build failure, 2 usage error.
set -euo pipefail

GO_VERSION="1.24.13"
GO_IMAGE="golang:1.24.13-bookworm@sha256:1a6d4452c65dea36aac2e2d606b01b4a029ec90cc1ae53890540ce6173ea77ac"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${HERE}/dist"
VERSION=""
BINARY=""
TOOLCHAIN="${DSV_FETCH_TOOLCHAIN:-auto}"
TARGETS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --target) TARGETS+=("$2"); shift 2 ;;
    --binary) BINARY="$2"; shift 2 ;;
    --toolchain) TOOLCHAIN="$2"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ ${#TARGETS[@]} -gt 0 ]] || TARGETS=(linux/amd64 linux/arm64 windows/amd64)
VERSION="${VERSION:-$(tr -d '[:space:]' < "${HERE}/VERSION")}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?$ ]]; then
  echo "invalid version '$VERSION' (semver expected)" >&2; exit 2
fi
if [[ -n "$BINARY" && ${#TARGETS[@]} -ne 1 ]]; then
  echo "--binary needs exactly one --target" >&2; exit 2
fi
for t in "${TARGETS[@]}"; do
  [[ "$t" =~ ^(linux|windows|darwin)/(amd64|arm64)$ ]] || { echo "unsupported target '$t'" >&2; exit 2; }
done

GO="$(command -v go || true)"
[[ -n "$GO" ]] || { [[ -x /usr/local/go/bin/go ]] && GO=/usr/local/go/bin/go; }
local_version() { [[ -n "$GO" ]] && "$GO" env GOVERSION 2>/dev/null | sed 's/^go//' || true; }
case "$TOOLCHAIN" in
  auto)
    if [[ "$(local_version)" == "$GO_VERSION" ]]; then TOOLCHAIN=local
    elif command -v docker >/dev/null && docker info >/dev/null 2>&1; then TOOLCHAIN=docker
    else TOOLCHAIN=local; fi ;;
  local|docker) ;;
  *) echo "--toolchain must be auto, local or docker" >&2; exit 2 ;;
esac

if [[ "$TOOLCHAIN" == docker ]]; then
  # Re-run this script inside the pinned toolchain image (module is stdlib only: no network needed in the container).
  mkdir -p "$OUT"
  OUT_ABS="$(cd "$OUT" && pwd)"
  args=(--out /out --version "$VERSION" --toolchain local)
  for t in "${TARGETS[@]}"; do args+=(--target "$t"); done
  [[ -z "$BINARY" ]] || { echo "--binary is not supported with --toolchain docker" >&2; exit 2; }
  docker run --rm --network none --user "$(id -u):$(id -g)" -e HOME=/tmp -e GOCACHE=/tmp/gocache \
    -v "${HERE}:/src:ro" -v "${OUT_ABS}:/out" -w /src "$GO_IMAGE" bash /src/build.sh "${args[@]}"
  exit 0
fi

[[ -n "$GO" ]] || { echo "go not found (install Go ${GO_VERSION} or use --toolchain docker)" >&2; exit 1; }
LV="$(local_version)"
if [[ "$LV" != "$GO_VERSION" ]]; then
  echo "warning: go ${LV} is not the pinned ${GO_VERSION}; binaries are not byte-identical to the release" >&2
fi

export CGO_ENABLED=0 GOTOOLCHAIN=local GOFLAGS="${GOFLAGS:-} -trimpath -buildvcs=false"
LDFLAGS="-s -w -buildid= -X main.version=${VERSION}"
build_one() { # target outfile
  local goos="${1%/*}" goarch="${1#*/}"
  (cd "$HERE" && GOOS="$goos" GOARCH="$goarch" "$GO" build -ldflags "$LDFLAGS" -o "$2" ./cmd/dsv-fetch)
}

if [[ -n "$BINARY" ]]; then
  build_one "${TARGETS[0]}" "$BINARY"
  echo "built $BINARY (${TARGETS[0]}, ${VERSION}, go ${LV})" >&2
  exit 0
fi

mkdir -p "$OUT"
names=()
for t in "${TARGETS[@]}"; do
  name="dsv-fetch-${t%/*}-${t#*/}"
  [[ "${t%/*}" == windows ]] && name+=".exe"
  build_one "$t" "${OUT}/${name}"
  names+=("$name")
done
(cd "$OUT" && sha256sum "${names[@]}" > SHA256SUMS && sha256sum --check --quiet SHA256SUMS)
echo "built ${names[*]} + SHA256SUMS in ${OUT} (${VERSION}, go ${LV})" >&2
