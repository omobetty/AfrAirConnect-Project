#!/usr/bin/env bash
set -Eeuo pipefail

trap 'status=$?; printf "ERROR: command failed (exit %s) at line %s: %s\n" "$status" "$LINENO" "$BASH_COMMAND" >&2' ERR

STAGING_DIR=''
TEMP_LINK=''
NEW_RELEASE=''
PREVIOUS_TARGET=''
DEPLOY_SUCCEEDED=0

cleanup() {
  if [[ -n ${TEMP_LINK:-} && -L ${TEMP_LINK:-} ]]; then
    rm -f -- "$TEMP_LINK"
  fi
  if [[ -n ${STAGING_DIR:-} && -d ${STAGING_DIR:-} ]]; then
    rm -rf -- "$STAGING_DIR"
  fi
  if [[ ${DEPLOY_SUCCEEDED:-0} -eq 0 && -n ${NEW_RELEASE:-} && -d ${NEW_RELEASE:-} ]]; then
    local active_target=''
    if [[ -L ${CURRENT_LINK:-} ]]; then
      active_target=$(readlink -- "$CURRENT_LINK" 2>/dev/null || true)
    fi
    if [[ $active_target != "releases/${NEW_RELEASE##*/}" ]]; then
      rm -rf -- "$NEW_RELEASE"
    else
      printf '[deploy] WARNING: preserving failed release because current still points to it: %s\n' "$NEW_RELEASE" >&2
    fi
  fi
}

trap cleanup EXIT

log() {
  printf '[deploy] %s\n' "$*"
}

fail() {
  printf '[deploy] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'Usage: sudo %s <artifact.tar.gz>\n' "$0"
}

switch_current() {
  local target=$1
  TEMP_LINK="$APP_ROOT/.current.deploy.$$.$RANDOM"
  ln -sfn -- "$target" "$TEMP_LINK" || return 1
  mv -Tf -- "$TEMP_LINK" "$CURRENT_LINK" || return 1
  TEMP_LINK=''
}

restore_previous() {
  if [[ -n $PREVIOUS_TARGET ]]; then
    switch_current "$PREVIOUS_TARGET" || return 1
  else
    rm -f -- "$CURRENT_LINK" || return 1
  fi

  nginx -t || return 1
  systemctl reload nginx || return 1
}

rollback_after_failure() {
  local reason=$1
  log "$reason; restoring the previous release"
  if ! restore_previous; then
    log 'automatic rollback failed; inspect the current symlink and nginx service immediately'
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
if [[ $EUID -ne 0 ]]; then
  fail 'run as root, for example: sudo scripts/ops/deploy.sh africair-<sha>.tar.gz'
fi

readonly APP_ROOT=/opt/africair
readonly RELEASES_DIR="$APP_ROOT/releases"
readonly SHARED_DIR="$APP_ROOT/shared"
readonly CURRENT_LINK="$APP_ROOT/current"
readonly SERVICE_USER=africair
readonly SERVICE_GROUP=africair
readonly BASE_URL=${AFRICAIR_BASE_URL:-http://127.0.0.1}

for command_name in realpath sha256sum tar jq curl nginx systemctl; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command is missing: $command_name"
done

[[ -d $RELEASES_DIR && ! -L $RELEASES_DIR ]] || fail "release directory is missing or not a real directory: $RELEASES_DIR"
[[ -d $SHARED_DIR && ! -L $SHARED_DIR ]] || fail "shared directory is missing or not a real directory: $SHARED_DIR"
chmod 0755 "$APP_ROOT" "$RELEASES_DIR" || fail 'could not make the public release path traversable by nginx'
getent passwd "$SERVICE_USER" >/dev/null || fail "service user '$SERVICE_USER' does not exist; run bootstrap.sh first"
getent group "$SERVICE_GROUP" >/dev/null || fail "service group '$SERVICE_GROUP' does not exist; run bootstrap.sh first"

ARTIFACT=$(realpath -e -- "$1") || fail "artifact does not exist: $1"
[[ -f $ARTIFACT ]] || fail "artifact is not a regular file: $ARTIFACT"
CHECKSUM_FILE="${ARTIFACT}.sha256"
[[ -f $CHECKSUM_FILE ]] || fail "checksum file is missing: $CHECKSUM_FILE"

log 'verifying artifact checksum'
if ! (cd -- "$(dirname -- "$ARTIFACT")" && sha256sum --check --strict --status -- "$(basename -- "$CHECKSUM_FILE")"); then
  fail 'artifact checksum verification failed'
fi

if [[ -L $CURRENT_LINK ]]; then
  PREVIOUS_TARGET=$(readlink -- "$CURRENT_LINK") || fail 'could not read current symlink'
  [[ $PREVIOUS_TARGET == releases/* && ${PREVIOUS_TARGET#releases/} != */* ]] || fail "current symlink points outside the release layout: $PREVIOUS_TARGET"
  [[ -d "$APP_ROOT/$PREVIOUS_TARGET" ]] || fail "current symlink target does not exist: $PREVIOUS_TARGET"
elif [[ -e $CURRENT_LINK ]]; then
  fail "$CURRENT_LINK exists but is not a symlink"
fi

STAGING_DIR=$(mktemp -d "$RELEASES_DIR/.staging.XXXXXX") || fail 'could not create a staging directory under releases/'
ARCHIVE_LIST="$STAGING_DIR/archive.list"

log 'checking archive paths and entry types'
tar -tzf "$ARTIFACT" > "$ARCHIVE_LIST" || fail 'artifact is not a readable gzip tar archive'
tar -tvzf "$ARTIFACT" > "$STAGING_DIR/archive.details" || fail 'could not inspect archive entries'

while IFS= read -r entry; do
  [[ $entry == dist || $entry == dist/* ]] || fail "archive contains a path outside dist/: $entry"
  [[ $entry != /* && ! $entry =~ (^|/)\.\.(/|$) ]] || fail "archive contains an unsafe path: $entry"
done < "$ARCHIVE_LIST"

while IFS= read -r entry; do
  entry_type=${entry:0:1}
  [[ $entry_type == d || $entry_type == - ]] || fail 'archive contains a link or special file; refusing extraction'
done < "$STAGING_DIR/archive.details"

log 'extracting release files'
tar --extract --gzip --file "$ARTIFACT" --directory "$STAGING_DIR" --no-same-owner --no-same-permissions || fail 'could not extract the artifact'
[[ -f $STAGING_DIR/dist/index.html ]] || fail 'artifact is missing dist/index.html'
[[ -f $STAGING_DIR/dist/version.json ]] || fail 'artifact is missing dist/version.json'

COMMIT=$(jq -er '.commit | strings | select(test("^[0-9a-f]{40}$"))' "$STAGING_DIR/dist/version.json") || fail 'dist/version.json has no valid full commit SHA'
EXPECTED_SHORT_SHA=${COMMIT:0:12}
ARTIFACT_NAME=$(basename -- "$ARTIFACT")
[[ $ARTIFACT_NAME == "africair-${EXPECTED_SHORT_SHA}.tar.gz" ]] || fail "artifact name does not match version.json commit: expected africair-${EXPECTED_SHORT_SHA}.tar.gz"

RELEASE_TIMESTAMP=$(date -u +'%Y%m%dT%H%M%S.%NZ') || fail 'could not determine the UTC release timestamp'
RELEASE_NAME="${RELEASE_TIMESTAMP}-${COMMIT}"
NEW_RELEASE="$RELEASES_DIR/$RELEASE_NAME"
[[ ! -e $NEW_RELEASE && ! -L $NEW_RELEASE ]] || fail "release already exists: $NEW_RELEASE"

mv -- "$STAGING_DIR/dist" "$NEW_RELEASE" || fail 'could not move extracted files into the release directory'
chown -R "$SERVICE_USER:$SERVICE_GROUP" "$NEW_RELEASE" || fail 'could not assign release ownership to africair'
chmod 0755 "$NEW_RELEASE" || fail 'could not set release directory permissions'
rm -rf -- "$STAGING_DIR" || fail 'could not remove the temporary staging directory'
STAGING_DIR=''

log 'testing nginx configuration before reload'
nginx -t || fail 'nginx configuration test failed; current release was not changed'

log "switching current to releases/$RELEASE_NAME"
switch_current "releases/$RELEASE_NAME" || fail 'could not atomically switch the current symlink'

if ! systemctl reload nginx; then
  rollback_after_failure 'nginx reload failed'
  fail 'deployment failed while reloading nginx'
fi

log 'checking the deployed health endpoint'
if ! curl --fail --silent --show-error --retry 10 --retry-connrefused --retry-delay 1 --max-time 10 "$BASE_URL/healthz" >/dev/null; then
  rollback_after_failure 'health check failed'
  fail 'deployment failed health check'
fi

log 'checking the deployed version'
if ! DEPLOYED_VERSION=$(curl --fail --silent --show-error --retry 5 --retry-connrefused --retry-delay 1 --max-time 10 "$BASE_URL/version.json"); then
  rollback_after_failure 'could not fetch /version.json'
  fail 'deployment could not verify the deployed version'
fi
if ! DEPLOYED_COMMIT=$(jq -er '.commit | strings' <<< "$DEPLOYED_VERSION") || [[ $DEPLOYED_COMMIT != "$COMMIT" ]]; then
  rollback_after_failure "deployed commit mismatch (expected $COMMIT, got ${DEPLOYED_COMMIT:-invalid})"
  fail 'deployment version verification failed'
fi

log 'pruning releases older than the five most recent'
release_names=()
for release_path in "$RELEASES_DIR"/*; do
  [[ -d $release_path && ! -L $release_path ]] || continue
  release_name=${release_path##*/}
  [[ $release_name =~ ^[0-9]{8}T[0-9]{6}\.[0-9]{9}Z-[0-9a-f]{40}$ ]] || continue
  release_names+=("$release_name")
done

if ((${#release_names[@]} > 0)); then
  mapfile -t release_names < <(printf '%s\n' "${release_names[@]}" | LC_ALL=C sort -r)
  current_name=${RELEASE_NAME}
  retained_others=0
  for release_name in "${release_names[@]}"; do
    [[ $release_name == "$current_name" ]] && continue
    if ((retained_others < 4)); then
      ((retained_others += 1))
      continue
    fi
    rm -rf -- "$RELEASES_DIR/$release_name"
    log "removed old release $release_name"
  done
fi

log "deployment succeeded: $RELEASE_NAME"
DEPLOY_SUCCEEDED=1