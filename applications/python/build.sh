#!/usr/bin/env bash
# Build pipeline for the Enterprise Hello Python services, hello-logicapps and hello-frontend.
#
#   applications/python/build.sh [--steps lint,test,package,image] [--services catalog-api,worker,...] [--version X]
#
# Steps (default: lint,test,package,image):
#   lint         ruff check + ruff format --check (applications/python/ruff.toml); frontend: tsc typecheck
#   test         unit tests per service in an isolated venv built from that service's pinned requirements.txt
#                (JUnit XML in .artifacts/<svc>/junit.xml); frontend: vitest
#   integration  pytest -m integration (needs docker; pulls postgres/mysql/redis/mongo/mssql/azurite/citus/
#                cassandra/Service Bus emulator images) ; frontend: Playwright e2e against `vite preview`
#   package      zips into .artifacts/<svc>/ (see README) + manifest.json with sha256 of every artifact
#   image        docker build (context = applications/) tagged hello-<svc>:<version>, image.json written
# Services: hello-common catalog-api dbadapter worker partner-sim jobs traffic functions logicapps frontend
#
# Environment: ARTIFACTS_DIR (default <repo>/.artifacts), BUILD_CACHE (default $ARTIFACTS_DIR/.cache),
#   VERSION (default git describe), PYTHON (python3.13), DOCKER_BUILD_ARGS (extra `docker build` args, e.g.
#   "--network host --secret id=pipca,src=/path/ca.pem" behind a TLS-inspecting proxy), IMAGE_PREFIX (registry/).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
APPS=$(cd "$HERE/.." && pwd)
REPO=$(cd "$APPS/.." && pwd)
ARTIFACTS_DIR=${ARTIFACTS_DIR:-$REPO/.artifacts}
BUILD_CACHE=${BUILD_CACHE:-$ARTIFACTS_DIR/.cache}
PYTHON=${PYTHON:-python3.13}
GIT_COMMIT=$(git -C "$REPO" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)
VERSION=${VERSION:-$(git -C "$REPO" describe --tags --always --dirty 2>/dev/null || echo 0.0.0-dev)}
BUILD_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
IMAGE_PREFIX=${IMAGE_PREFIX:-}
STEPS="lint,test,package,image"
SERVICES="hello-common,catalog-api,dbadapter,worker,partner-sim,jobs,traffic,functions,logicapps,frontend"
TEST_DEPS=(pytest==9.1.1 pytest-asyncio==1.4.0 jsonschema==4.26.0)
RUFF_VERSION=0.16.10

while [[ $# -gt 0 ]]; do
  case "$1" in
    --steps) STEPS="$2"; shift 2 ;;
    --services) SERVICES="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done

has_step() { [[ ",$STEPS," == *",$1,"* ]]; }
log() { printf '\n==> %s\n' "$*"; }
declare -A PKG=([catalog-api]=hello_catalog [dbadapter]=hello_dbadapter [worker]=hello_worker [partner-sim]=hello_partner_sim
                [jobs]=hello_jobs [traffic]=hello_traffic [functions]=hello_functions)
FAILED=()

mkdir -p "$ARTIFACTS_DIR" "$BUILD_CACHE"
SVC_LIST=${SERVICES//,/ }

svc_dir() { case "$1" in hello-common) echo "$APPS/shared/python/hello_common" ;; *) echo "$APPS/services/$1" ;; esac; }

# --------------------------------------------------------------------------------------------- venvs
make_venv() {  # make_venv <name> <requirements file|-> -> prints venv path
  local req=$2 venv="$BUILD_CACHE/venv-$1" stamp
  stamp=$( { [[ "$req" != - ]] && cat "$req"; printf '%s' "${TEST_DEPS[*]}"; } | sha256sum | cut -c1-16)
  if [[ ! -f "$venv/.stamp" || "$(cat "$venv/.stamp")" != "$stamp" ]]; then
    rm -rf "$venv"
    if command -v uv >/dev/null 2>&1; then
      uv venv -q -p "$PYTHON" "$venv"
      [[ "$req" != - ]] && VIRTUAL_ENV="$venv" uv pip install -q -r "$req"
      VIRTUAL_ENV="$venv" uv pip install -q "${TEST_DEPS[@]}"
    else
      "$PYTHON" -m venv "$venv"
      "$venv/bin/pip" install -q --upgrade pip
      [[ "$req" != - ]] && "$venv/bin/pip" install -q -r "$req"
      "$venv/bin/pip" install -q "${TEST_DEPS[@]}"
    fi
    echo "$stamp" > "$venv/.stamp"
  fi
  # local packages (editable, no deps: everything third-party comes from the pinned requirements)
  if command -v uv >/dev/null 2>&1; then
    VIRTUAL_ENV="$venv" uv pip install -q --no-deps -e "$APPS/shared/python/hello_common" >/dev/null
  else
    "$venv/bin/pip" install -q --no-deps -e "$APPS/shared/python/hello_common" >/dev/null
  fi
  echo "$venv"
}

svc_venv() {
  local svc=$1 dir venv
  dir=$(svc_dir "$svc")
  case "$svc" in
    hello-common) venv=$(make_venv hello-common "$APPS/services/catalog-api/requirements.txt") ;;  # superset of hello_common deps
    logicapps) venv=$(make_venv logicapps -) ;;
    *) venv=$(make_venv "$svc" "$dir/requirements.txt") ;;
  esac
  if [[ -f "$dir/pyproject.toml" && "$svc" != functions && "$svc" != logicapps && "$svc" != hello-common ]]; then
    if command -v uv >/dev/null 2>&1; then VIRTUAL_ENV="$venv" uv pip install -q --no-deps -e "$dir" >/dev/null
    else "$venv/bin/pip" install -q --no-deps -e "$dir" >/dev/null; fi
  fi
  echo "$venv"
}

# ---------------------------------------------------------------------------------------------- lint
if has_step lint; then
  log "lint: ruff $RUFF_VERSION"
  RUFF=$(command -v ruff || true)
  if [[ -z "$RUFF" ]]; then
    lintvenv=$(make_venv lint -)
    "$lintvenv/bin/pip" install -q "ruff==$RUFF_VERSION"
    RUFF="$lintvenv/bin/ruff"
  fi
  py_dirs=()
  for svc in $SVC_LIST; do [[ "$svc" != frontend ]] && py_dirs+=("$(svc_dir "$svc")"); done
  if ((${#py_dirs[@]})); then
    "$RUFF" check --config "$HERE/ruff.toml" "${py_dirs[@]}" || FAILED+=("lint:ruff-check")
    "$RUFF" format --check --config "$HERE/ruff.toml" "${py_dirs[@]}" || FAILED+=("lint:ruff-format")
  fi
  for f in "$APPS/services/worker/deploy/vm/install.sh" "$APPS/services/jobs/deploy/batch/run.sh" "$HERE/build.sh"; do
    bash -n "$f" || FAILED+=("lint:bash-syntax:$f")
    if command -v shellcheck >/dev/null 2>&1; then shellcheck "$f" || FAILED+=("lint:shellcheck:$f"); fi
  done
fi

# --------------------------------------------------------------------------------------- frontend
frontend_steps() {
  local dir="$APPS/services/frontend" out="$ARTIFACTS_DIR/frontend"
  mkdir -p "$out"
  (cd "$dir" && { [[ -d node_modules ]] || PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --no-audit --no-fund; }) || { FAILED+=("frontend:npm-ci"); return; }
  if has_step lint; then (cd "$dir" && npm run -s typecheck) || FAILED+=("frontend:typecheck"); fi
  if has_step test; then (cd "$dir" && npx vitest run --reporter=default --reporter=junit --outputFile.junit="$out/junit.xml") || FAILED+=("frontend:vitest"); fi
  if has_step integration; then (cd "$dir" && npx playwright test) || FAILED+=("frontend:playwright"); fi
  if has_step package; then
    (cd "$dir" && npm run -s build) || { FAILED+=("frontend:build"); return; }
    rm -f "$out"/hello-frontend-*.zip
    # config.json is environment-specific (written by the deployment); the bundle ships without it
    (cd "$dir/dist" && zip -qr -X "$out/hello-frontend-$VERSION.zip" . -x config.json)
  fi
}

# ---------------------------------------------------------------------------------------- packaging
wheelhouse() {  # wheelhouse <svc> <dest> : offline linux/x86_64 cp313 wheels for requirements + local packages
  local svc=$1 dest=$2 dir venv
  dir=$(svc_dir "$svc")
  venv=$(svc_venv "$svc")
  mkdir -p "$dest"
  "$venv/bin/python" -m pip --version >/dev/null 2>&1 || "$venv/bin/python" -m ensurepip >/dev/null 2>&1 || return 1
  "$venv/bin/python" -m pip download -q --only-binary=:all: --platform manylinux_2_28_x86_64 --platform manylinux_2_17_x86_64 \
    --platform manylinux2014_x86_64 --python-version 3.13 --implementation cp --abi cp313 --abi abi3 --abi none \
    -r "$dir/requirements.txt" -d "$dest" || return 1
  "$venv/bin/python" -m pip wheel -q --no-deps -w "$dest" "$APPS/shared/python/hello_common" "$dir" || return 1
}

package_svc() {
  local svc=$1 dir out stage zipf
  dir=$(svc_dir "$svc")
  out="$ARTIFACTS_DIR/$svc"
  stage="$BUILD_CACHE/stage-$svc"
  rm -rf "$stage" && mkdir -p "$stage" "$out"
  rm -f "$out"/*.zip
  case "$svc" in
    catalog-api|dbadapter|partner-sim)
      # App Service (Linux, code) / generic zip: packages at the root, Oryx installs requirements.txt;
      # startup command: python -m <package>
      cp -r "$dir/src/${PKG[$svc]}" "$APPS/shared/python/hello_common/src/hello_common" "$stage/"
      cp "$dir/requirements.txt" "$stage/"
      echo "python -m ${PKG[$svc]}" > "$stage/startup.txt"
      zipf="$out/hello-$svc-$VERSION.zip" ;;
    worker)
      wheelhouse worker "$stage/wheels" || return 1
      mkdir -p "$stage/deploy"
      cp "$dir/deploy/vm/"* "$stage/deploy/"
      cp "$dir/requirements.txt" "$dir/README.md" "$stage/"
      zipf="$out/hello-worker-$VERSION-vm.zip" ;;
    jobs)
      wheelhouse jobs "$stage/wheels" || return 1
      cp "$dir/deploy/batch/run.sh" "$dir/requirements.txt" "$dir/README.md" "$stage/"
      zipf="$out/hello-jobs-$VERSION-batch.zip" ;;
    functions)
      # Functions zip deploy without remote build: dependencies pre-installed for linux x64 / Python 3.13
      cp "$dir/function_app.py" "$dir/host.json" "$dir/requirements.txt" "$dir/.funcignore" "$stage/"
      cp -r "$dir/hello_functions" "$APPS/shared/python/hello_common/src/hello_common" "$stage/"
      venv=$(svc_venv functions)
      "$venv/bin/python" -m pip --version >/dev/null 2>&1 || "$venv/bin/python" -m ensurepip >/dev/null 2>&1 || return 1
      "$venv/bin/python" -m pip install -q --only-binary=:all: --platform manylinux_2_28_x86_64 --platform manylinux_2_17_x86_64 \
        --platform manylinux2014_x86_64 --python-version 3.13 --implementation cp --abi cp313 --abi abi3 --abi none \
        --target "$stage/.python_packages/lib/site-packages" -r "$dir/requirements.txt" || return 1
      zipf="$out/hello-functions-$VERSION.zip" ;;
    logicapps)
      cp -r "$dir/standard/." "$stage/"
      zipf="$out/hello-logicapps-standard-$VERSION.zip"
      cp "$dir/consumption/batch-request.definition.json" "$out/batch-request.definition.json" ;;
    traffic|hello-common) return 0 ;;  # container image only / library
  esac
  echo "$VERSION" > "$stage/VERSION"
  find "$stage" -name __pycache__ -type d -prune -exec rm -rf {} +
  (cd "$stage" && zip -qr -X "$zipf" .) || return 1
}

write_manifest() {
  local svc=$1 out="$ARTIFACTS_DIR/$1"
  [[ -d "$out" ]] || return 0
  "$PYTHON" - "$out" "$svc" "$VERSION" "$GIT_COMMIT" "$BUILD_TIME" <<'PY'
import hashlib, json, os, sys
out, svc, version, commit, built = sys.argv[1:]
files = []
for name in sorted(os.listdir(out)):
    path = os.path.join(out, name)
    if name in ("manifest.json",) or not os.path.isfile(path):
        continue
    files.append({"file": name, "bytes": os.path.getsize(path), "sha256": hashlib.sha256(open(path, "rb").read()).hexdigest()})
json.dump({"service": svc, "version": version, "commit": commit, "build_time": built, "artifacts": files}, open(os.path.join(out, "manifest.json"), "w"), indent=2)
PY
}

# ------------------------------------------------------------------------------------- per service
for svc in $SVC_LIST; do
  if [[ "$svc" == frontend ]]; then log "frontend"; frontend_steps; write_manifest frontend; continue; fi
  dir=$(svc_dir "$svc")
  [[ -d "$dir" ]] || { echo "unknown service $svc" >&2; exit 2; }
  out="$ARTIFACTS_DIR/$svc"; mkdir -p "$out"
  if has_step test || has_step integration; then
    log "$svc: venv"
    venv=$(svc_venv "$svc")
    if has_step test; then
      log "$svc: unit tests"
      (cd "$dir" && "$venv/bin/python" -m pytest -q -p no:cacheprovider --junitxml="$out/junit.xml") || FAILED+=("$svc:test")
    fi
    if has_step integration && grep -rqs "pytest.mark.integration" "$dir/tests"; then
      log "$svc: integration tests"
      (cd "$dir" && "$venv/bin/python" -m pytest -q -p no:cacheprovider -m integration --junitxml="$out/junit-integration.xml") || FAILED+=("$svc:integration")
    fi
  fi
  if has_step package; then log "$svc: package"; package_svc "$svc" || FAILED+=("$svc:package"); fi
  if has_step image && [[ -f "$dir/Dockerfile" ]]; then
    log "$svc: image"
    image="${IMAGE_PREFIX}hello-$svc:$VERSION"
    # shellcheck disable=SC2086 # DOCKER_BUILD_ARGS is intentionally word-split
    if docker build ${DOCKER_BUILD_ARGS:-} --build-arg VERSION="$VERSION" --build-arg GIT_COMMIT="$GIT_COMMIT" --build-arg BUILD_TIME="$BUILD_TIME" \
         -f "$dir/Dockerfile" -t "$image" "$APPS"; then
      id=$(docker image inspect "$image" --format '{{.Id}}')
      printf '{"image": "%s", "id": "%s", "version": "%s", "commit": "%s"}\n' "$image" "$id" "$VERSION" "$GIT_COMMIT" > "$out/image.json"
    else
      FAILED+=("$svc:image")
    fi
  fi
  write_manifest "$svc"
done
if has_step image && [[ ",$SERVICES," == *",frontend,"* ]]; then
  log "frontend: image"
  image="${IMAGE_PREFIX}hello-frontend:$VERSION"
  # shellcheck disable=SC2086
  if docker build ${DOCKER_BUILD_ARGS:-} --build-arg VERSION="$VERSION" --build-arg GIT_COMMIT="$GIT_COMMIT" -f "$APPS/services/frontend/Dockerfile" -t "$image" "$APPS"; then
    printf '{"image": "%s", "id": "%s", "version": "%s"}\n' "$image" "$(docker image inspect "$image" --format '{{.Id}}')" "$VERSION" > "$ARTIFACTS_DIR/frontend/image.json"
  else
    FAILED+=("frontend:image")
  fi
  write_manifest frontend
fi

if ((${#FAILED[@]})); then
  printf '\nFAILED: %s\n' "${FAILED[*]}"
  exit 1
fi
printf '\nOK: steps=%s services=%s version=%s artifacts=%s\n' "$STEPS" "$SERVICES" "$VERSION" "$ARTIFACTS_DIR"
