#!/usr/bin/env bash
# Enterprise Hello .NET build: restore → build (Release, warnings-as-errors in src) → test → publish packages.
#
# Usage: applications/dotnet/build.sh [all|build|test|publish|images] [service...]
#   services: bff orders-api inventory-api durable   (default: all)
# Environment:
#   VERSION        package/assembly version          (default 0.1.0-local)
#   GIT_COMMIT     commit baked into assemblies       (default: git rev-parse --short HEAD, else "unknown")
#   BUILD_TIME     UTC ISO-8601                        (default: now)
#   ARTIFACTS_DIR  output root                         (default: applications/dotnet/.artifacts)
#   CA_BUNDLE      optional CA bundle passed to `docker build --secret id=ca_bundle` (TLS-intercepting proxies)
#   LOCKED_RESTORE true (default): `dotnet restore --locked-mode` against the committed packages.lock.json files
#                  (fails on drift: NU1004). false: unlocked restore that may update the lock files (after a
#                  Directory.Packages.props change; then commit the regenerated packages.lock.json files).
# Output (publish):
#   .artifacts/<svc>/<artifact>.zip + build-info.json (sha256 of every zip) ; .artifacts/test-results/
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS="$(cd "$HERE/.." && pwd)"
cd "$HERE" # global.json (SDK pin + Microsoft.Testing.Platform runner) applies from here

CMD="${1:-all}"; shift || true
SERVICES=("$@"); [[ ${#SERVICES[@]} -eq 0 ]] && SERVICES=(bff orders-api inventory-api durable)
VERSION="${VERSION:-0.1.0-local}"
GIT_COMMIT="${GIT_COMMIT:-$(git -C "$APPS" rev-parse --short HEAD 2>/dev/null || echo unknown)}"
BUILD_TIME="${BUILD_TIME:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$HERE/.artifacts}"
PROPS=(-p:Version="$VERSION" -p:GIT_COMMIT="$GIT_COMMIT" -p:BUILD_TIME="$BUILD_TIME" -p:ContinuousIntegrationBuild=true)
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1

log() { printf '\n== %s\n' "$*"; }

project_of() {
  case "$1" in
    bff) echo "$APPS/services/bff/src/Hello.Bff/Hello.Bff.csproj" ;;
    orders-api) echo "$APPS/services/orders-api/src/Hello.OrdersApi/Hello.OrdersApi.csproj" ;;
    inventory-api) echo "$APPS/services/inventory-api/src/Hello.InventoryApi/Hello.InventoryApi.csproj" ;;
    durable) echo "$APPS/services/durable/src/Hello.Durable/Hello.Durable.csproj" ;;
    *) echo "unknown service: $1" >&2; exit 2 ;;
  esac
}

zipdir() { # zipdir <dir> <zipfile> — zip the CONTENTS of dir (host.json at the root for Functions one-deploy)
  rm -f "$2"
  (cd "$1" && if command -v zip >/dev/null; then zip -qr -X "$2" .; else python3 -c 'import shutil,sys; shutil.make_archive(sys.argv[1][:-4], "zip", ".")' "$2"; fi)
}

do_build() {
  log "restore + build (Release) $VERSION $GIT_COMMIT"
  if [[ "${LOCKED_RESTORE:-true}" == true ]]; then
    dotnet restore EnterpriseHello.sln --locked-mode
  else
    dotnet restore EnterpriseHello.sln --force-evaluate -p:RestoreLockedMode=false
  fi
  dotnet build EnterpriseHello.sln -c Release --no-restore "${PROPS[@]}"
}

do_test() {
  log "test"
  mkdir -p "$ARTIFACTS_DIR/test-results"
  dotnet test --solution EnterpriseHello.sln -c Release --no-build --results-directory "$ARTIFACTS_DIR/test-results"
}

publish_one() {
  local svc="$1" proj out
  proj="$(project_of "$svc")"
  out="$ARTIFACTS_DIR/$svc"
  rm -rf "$out"; mkdir -p "$out"
  case "$svc" in
    durable)
      # Flex Consumption one-deploy: framework-dependent, contents zipped with host.json at the root.
      dotnet publish "$proj" -c Release -o "$out/publish" "${PROPS[@]}"
      zipdir "$out/publish" "$out/hello-durable-$VERSION.zip" ;;
    inventory-api)
      # App Service Windows (code) / Windows VM service: self-contained win-x64 (includes web.config for ANCM).
      dotnet publish "$proj" -c Release -r win-x64 --self-contained true -o "$out/publish-win-x64" "${PROPS[@]}"
      zipdir "$out/publish-win-x64" "$out/hello-inventory-api-$VERSION-win-x64.zip"
      # App Service Linux / Linux VM: framework-dependent linux-x64 (requires the .NET 10 ASP.NET Core runtime).
      dotnet publish "$proj" -c Release -r linux-x64 --self-contained false -o "$out/publish-linux-x64" "${PROPS[@]}"
      zipdir "$out/publish-linux-x64" "$out/hello-inventory-api-$VERSION-linux-x64.zip" ;;
    *)
      # Container-first services: framework-dependent portable output (the image is built from the Dockerfile).
      dotnet publish "$proj" -c Release -o "$out/publish" "${PROPS[@]}" -p:UseAppHost=false
      zipdir "$out/publish" "$out/hello-$svc-$VERSION.zip" ;;
  esac
  python3 - "$out" "$svc" "$VERSION" "$GIT_COMMIT" "$BUILD_TIME" <<'PY'
import hashlib, json, pathlib, sys
out, svc, version, commit, built = sys.argv[1:]
files = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(pathlib.Path(out).glob("*.zip"))}
info = {"service": f"hello-{svc}", "version": version, "commit": commit, "build_time": built, "artifacts": files}
pathlib.Path(out, "build-info.json").write_text(json.dumps(info, indent=2) + "\n")
print(json.dumps(info))
PY
}

do_publish() { for s in "${SERVICES[@]}"; do log "publish $s"; publish_one "$s"; done; }

do_images() {
  local secret=()
  [[ -n "${CA_BUNDLE:-}" ]] && secret=(--secret "id=ca_bundle,src=$CA_BUNDLE")
  for s in "${SERVICES[@]}"; do
    log "docker build hello-$s:$VERSION"
    docker build -f "$APPS/services/$s/Dockerfile" -t "hello-$s:$VERSION" \
      --build-arg VERSION="$VERSION" --build-arg GIT_COMMIT="$GIT_COMMIT" --build-arg BUILD_TIME="$BUILD_TIME" \
      "${secret[@]}" "$APPS"
  done
}

case "$CMD" in
  build) do_build ;;
  test) do_build; do_test ;;
  publish) do_publish ;;
  images) do_images ;;
  all) do_build; do_test; do_publish ;;
  *) echo "usage: $0 [all|build|test|publish|images] [service...]" >&2; exit 2 ;;
esac
