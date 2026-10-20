#!/usr/bin/env bash
set -Eeuo pipefail

trap 'status=$?; printf "ERROR: command failed (exit %s) at line %s: %s\n" "$status" "$LINENO" "$BASH_COMMAND" >&2' ERR

TEMP_DIR=''
TEMP_ARCHIVE=''
TEMP_CHECKSUM=''

cleanup() {
  if [[ -n ${TEMP_DIR:-} && -d ${TEMP_DIR:-} ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
  if [[ -n ${TEMP_ARCHIVE:-} && -f ${TEMP_ARCHIVE:-} ]]; then
    rm -f -- "$TEMP_ARCHIVE"
  fi
  if [[ -n ${TEMP_CHECKSUM:-} && -f ${TEMP_CHECKSUM:-} ]]; then
    rm -f -- "$TEMP_CHECKSUM"
  fi
}

trap cleanup EXIT

log() {
  printf '[build] %s\n' "$*"
}

fail() {
  local code=$1
  shift
  printf '[build] ERROR: %s\n' "$*" >&2
  exit "$code"
}

usage() {
  cat <<'USAGE'
Usage: scripts/ops/build.sh <git-ref>

Build a clean checkout of <git-ref>, run the quality gates, and package dist/.
The artifact and checksum are written to the current directory by default.

Environment:
  AFRICAIR_REPOSITORY      Git URL; defaults to this checkout's origin remote.
  AFRICAIR_ARTIFACT_DIR    Output directory; defaults to the current directory.
  BUILD_USER               Value recorded as builtBy; defaults to SUDO_USER or
                           the current user.

Exit codes:
  0   Build and package succeeded
  2   Invalid usage
  10  Repository clone, fetch, ref resolution, or checkout failed
  20  Node/Corepack/pnpm setup or dependency installation failed
  30  TypeScript checks or tests failed
  40  Production build, metadata, archive, or checksum failed
USAGE
}

run_stage() {
  local label=$1
  local exit_code=$2
  shift 2

  log "$label"
  if "$@"; then
    return 0
  else
    local command_status=$?
    fail "$exit_code" "$label failed (command exit $command_status)"
  fi
}

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  usage
  exit 0
fi

if [[ $# -ne 1 || -z ${1:-} ]]; then
  usage >&2
  exit 2
fi

readonly GIT_REF=$1
readonly SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly REPOSITORY_ROOT=$(git -C "$SCRIPT_DIR/../.." rev-parse --show-toplevel 2>/dev/null || true)
REPOSITORY=${AFRICAIR_REPOSITORY:-}

if [[ -z $REPOSITORY ]]; then
  if [[ -z $REPOSITORY_ROOT ]] || ! REPOSITORY=$(git -C "$REPOSITORY_ROOT" remote get-url origin 2>/dev/null); then
    fail 10 'could not find the origin remote; set AFRICAIR_REPOSITORY to the repository URL'
  fi
fi

if ! command -v git >/dev/null 2>&1; then
  fail 10 'git is required to clone and check out the requested ref'
fi

if ! command -v node >/dev/null 2>&1; then
  fail 20 'Node.js is required; install Node.js 22 LTS first'
fi

NODE_VERSION=$(node --version) || fail 20 'could not determine the Node.js version'
NODE_MAJOR=${NODE_VERSION#v}
NODE_MAJOR=${NODE_MAJOR%%.*}
if [[ $NODE_MAJOR != 22 ]]; then
  fail 20 "Node.js 22 is required; found $NODE_VERSION"
fi

if ! command -v corepack >/dev/null 2>&1; then
  fail 20 'Corepack is required; install or enable it with Node.js 22'
fi

for command_name in jq tar gzip sha256sum; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    fail 40 "required packaging tool is missing: $command_name"
  fi
done

ARTIFACT_DIR=${AFRICAIR_ARTIFACT_DIR:-$PWD}
mkdir -p -- "$ARTIFACT_DIR" || fail 40 "could not create artifact directory: $ARTIFACT_DIR"
ARTIFACT_DIR=$(cd -- "$ARTIFACT_DIR" && pwd -P) || fail 40 'could not resolve artifact directory'

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/africair-build.XXXXXX") || fail 10 'could not create a temporary build directory'
SOURCE_DIR="$TEMP_DIR/source"

checkout_source() {
  git clone --quiet --no-checkout -- "$REPOSITORY" "$SOURCE_DIR" || return 1
  git -C "$SOURCE_DIR" fetch --quiet --force --prune --tags origin '+refs/heads/*:refs/remotes/origin/*' || return 1

  local checkout_target=''
  if git -C "$SOURCE_DIR" show-ref --verify --quiet "refs/remotes/origin/$GIT_REF"; then
    checkout_target="refs/remotes/origin/$GIT_REF"
  elif git -C "$SOURCE_DIR" show-ref --verify --quiet "refs/tags/$GIT_REF"; then
    checkout_target="refs/tags/$GIT_REF"
  elif git -C "$SOURCE_DIR" rev-parse --verify --quiet --end-of-options "${GIT_REF}^{commit}" >/dev/null; then
    checkout_target=$GIT_REF
  else
    return 1
  fi

  git -C "$SOURCE_DIR" checkout --quiet --detach "$checkout_target"
}

log "checking out '$GIT_REF' from $REPOSITORY"
if ! checkout_source; then
  fail 10 "could not clone, fetch, resolve, or check out ref '$GIT_REF'"
fi

cd -- "$SOURCE_DIR"
COMMIT=$(git rev-parse HEAD) || fail 10 'could not determine the checked-out commit'
SHORT_SHA=$(git rev-parse --short=12 HEAD) || fail 10 'could not determine the short commit SHA'

if [[ ! -f package.json || ! -f pnpm-lock.yaml ]]; then
  fail 20 'the checked-out ref does not contain package.json and pnpm-lock.yaml'
fi

run_stage 'installing locked dependencies' 20 corepack pnpm install --frozen-lockfile
run_stage 'running TypeScript checks' 30 corepack pnpm check
run_stage 'running tests' 30 corepack pnpm test
run_stage 'building production assets' 40 corepack pnpm build

if [[ ! -d dist ]]; then
  fail 40 'the production build completed without creating dist/'
fi

if ! command -v jq >/dev/null 2>&1; then
  fail 40 'jq is required to write dist/version.json'
fi

BUILT_AT=$(date -u +'%Y-%m-%dT%H:%M:%SZ') || fail 40 'could not determine the build timestamp'
BUILT_BY=${BUILD_USER:-${SUDO_USER:-$(id -un)}}
NODE_VERSION=$(node --version) || fail 40 'could not determine the Node.js version'

jq -n \
  --arg commit "$COMMIT" \
  --arg ref "$GIT_REF" \
  --arg builtAt "$BUILT_AT" \
  --arg builtBy "$BUILT_BY" \
  --arg nodeVersion "$NODE_VERSION" \
  '{commit: $commit, ref: $ref, builtAt: $builtAt, builtBy: $builtBy, nodeVersion: $nodeVersion}' \
  > dist/version.json || fail 40 'could not write dist/version.json'

ARTIFACT_NAME="africair-${SHORT_SHA}.tar.gz"
CHECKSUM_NAME="${ARTIFACT_NAME}.sha256"
ARTIFACT_PATH="$ARTIFACT_DIR/$ARTIFACT_NAME"
CHECKSUM_PATH="$ARTIFACT_DIR/$CHECKSUM_NAME"
RAW_ARCHIVE="$TEMP_DIR/africair.tar"
SOURCE_DATE_EPOCH=$(git show -s --format=%ct HEAD) || fail 40 'could not determine the commit timestamp'

log "creating $ARTIFACT_NAME"
tar --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner \
  -cf "$RAW_ARCHIVE" -C "$SOURCE_DIR" dist || fail 40 'could not create the tar archive'

TEMP_ARCHIVE=$(mktemp "$ARTIFACT_DIR/.africair-${SHORT_SHA}.archive.XXXXXX") || fail 40 'could not create a temporary artifact file'
gzip --no-name --stdout "$RAW_ARCHIVE" > "$TEMP_ARCHIVE" || fail 40 'gzip compression failed'

TEMP_CHECKSUM=$(mktemp "$ARTIFACT_DIR/.africair-${SHORT_SHA}.checksum.XXXXXX") || fail 40 'could not create a temporary checksum file'
CHECKSUM=$(sha256sum "$TEMP_ARCHIVE" | awk '{ print $1 }') || fail 40 'could not calculate the artifact checksum'
printf '%s  %s\n' "$CHECKSUM" "$ARTIFACT_NAME" > "$TEMP_CHECKSUM" || fail 40 'could not write the checksum file'

mv -f -- "$TEMP_ARCHIVE" "$ARTIFACT_PATH" || fail 40 'could not publish the build artifact'
TEMP_ARCHIVE=''
mv -f -- "$TEMP_CHECKSUM" "$CHECKSUM_PATH" || fail 40 'could not publish the checksum file'
TEMP_CHECKSUM=''

log "artifact: $ARTIFACT_PATH"
log "checksum: $CHECKSUM_PATH"
log "commit: $COMMIT"