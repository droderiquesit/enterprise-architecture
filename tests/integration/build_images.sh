#!/usr/bin/env bash
# Rebuild every Enterprise Hello image used by the local e2e run from the CURRENT source tree, with the
# repository Dockerfiles (build context = applications/, exactly as applications/dotnet/build.sh `images` and
# applications/python/build.sh `image` do). Tags: hello-<svc>:${E2E_VERSION:-0.1.0-e2e}.
#
#   tests/integration/build_images.sh [svc ...]     (default: all services the compose file uses)
#
# Behind a TLS-intercepting egress proxy (CI sandboxes) set CA_BUNDLE=/path/ca.pem: it is passed as the build
# secrets the Dockerfiles already accept (`ca_bundle` for .NET, `pipca` for Python/npm), never stored in a layer;
# HTTPS_PROXY (if set) is forwarded as a build arg and the build uses the host network so 127.0.0.1 proxies work.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
APPS="$REPO/applications"
VERSION="${E2E_VERSION:-0.1.0-e2e}"
GIT_COMMIT="${GIT_COMMIT:-$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)}"
if [[ -n "$(git -C "$REPO" status --porcelain -- applications 2>/dev/null)" ]]; then GIT_COMMIT="${GIT_COMMIT}-dirty"; fi
BUILD_TIME="${BUILD_TIME:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
SERVICES=("$@")
[[ ${#SERVICES[@]} -eq 0 ]] && SERVICES=(bff orders-api inventory-api durable catalog-api dbadapter worker partner-sim frontend)

common=(--build-arg VERSION="$VERSION" --build-arg GIT_COMMIT="$GIT_COMMIT" --build-arg BUILD_TIME="$BUILD_TIME")
if [[ -n "${HTTPS_PROXY:-}" ]]; then
  # NO_PROXY is deliberately not forwarded: sandboxes list package indexes there that are only reachable via the proxy
  common+=(--network host --build-arg HTTPS_PROXY="$HTTPS_PROXY" --build-arg https_proxy="$HTTPS_PROXY")
fi
CA_BUNDLE="${CA_BUNDLE:-}"
[[ -z "$CA_BUNDLE" && -f /root/.ccr/ca-bundle.crt ]] && CA_BUNDLE=/root/.ccr/ca-bundle.crt

for svc in "${SERVICES[@]}"; do
  secret=()
  case "$svc" in
    bff|orders-api|inventory-api|durable) [[ -n "$CA_BUNDLE" ]] && secret=(--secret "id=ca_bundle,src=$CA_BUNDLE") ;;
    *) [[ -n "$CA_BUNDLE" ]] && secret=(--secret "id=pipca,src=$CA_BUNDLE") ;;
  esac
  echo "== docker build hello-$svc:$VERSION ($GIT_COMMIT)"
  docker build -q -f "$APPS/services/$svc/Dockerfile" -t "hello-$svc:$VERSION" "${common[@]}" "${secret[@]}" "$APPS"
done
echo "== built: ${SERVICES[*]} as :$VERSION commit=$GIT_COMMIT build_time=$BUILD_TIME"
