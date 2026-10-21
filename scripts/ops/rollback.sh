#!/usr/bin/env bash
set -Eeuo pipefail

trap 'status=$?; printf "ERROR: command failed (exit %s) at line %s: %s\n" "$status" "$LINENO" "$BASH_COMMAND" >&2' ERR

TEMP_LINK=''

cleanup() {
  if [[ -n ${TEMP_LINK:-} && -L ${TEMP_LINK:-} ]]; then
    rm -f -- "$TEMP_LINK"
  fi
}

trap cleanup EXIT

log() {
  printf '[rollback] %s\n' "$*"
}

fail() {
  printf '[rollback] ERROR: %s\n' "$*" >&2
  exit 1
}

switch_current() {
  local target=$1
  TEMP_LINK="$APP_ROOT/.current.rollback.$$.$RANDOM"
  ln -sfn -- "$target" "$TEMP_LINK" || return 1
  mv -Tf -- "$TEMP_LINK" "$CURRENT_LINK" || return 1
  TEMP_LINK=''
}

reload_nginx() {
  nginx -t || return 1
  systemctl reload nginx || return 1
}

restore_original() {
  switch_current "$ORIGINAL_TARGET" || return 1
  reload_nginx || return 1
}

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  printf 'Usage: sudo %s\nSwitch current to the newest retained release other than the active one.\n' "$0"
  exit 0
fi
if [[ $# -ne 0 ]]; then
  printf 'Usage: sudo %s\n' "$0" >&2
  exit 2
fi
if [[ $EUID -ne 0 ]]; then
  fail 'run as root, for example: sudo scripts/ops/rollback.sh'
fi

readonly APP_ROOT=/opt/africair
readonly RELEASES_DIR="$APP_ROOT/releases"
readonly CURRENT_LINK="$APP_ROOT/current"
readonly BASE_URL=${AFRICAIR_BASE_URL:-http://127.0.0.1}

for command_name in jq curl nginx systemctl; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command is missing: $command_name"
done

[[ -d $RELEASES_DIR && ! -L $RELEASES_DIR ]] || fail "release directory is missing or not a real directory: $RELEASES_DIR"
[[ -L $CURRENT_LINK ]] || fail 'there is no current release symlink to roll back from'

ORIGINAL_TARGET=$(readlink -- "$CURRENT_LINK") || fail 'could not read current symlink'
[[ $ORIGINAL_TARGET == releases/* && ${ORIGINAL_TARGET#releases/} != */* ]] || fail "current symlink points outside the release layout: $ORIGINAL_TARGET"
CURRENT_NAME=${ORIGINAL_TARGET#releases/}
[[ -d "$RELEASES_DIR/$CURRENT_NAME" ]] || fail "current release does not exist: $CURRENT_NAME"

release_names=()
for release_path in "$RELEASES_DIR"/*; do
  [[ -d $release_path && ! -L $release_path ]] || continue
  release_name=${release_path##*/}
  [[ $release_name =~ ^[0-9]{8}T[0-9]{6}\.[0-9]{9}Z-[0-9a-f]{40}$ ]] || continue
  release_names+=("$release_name")
done

if ((${#release_names[@]} == 0)); then
  fail 'no retained releases were found'
fi
mapfile -t release_names < <(printf '%s\n' "${release_names[@]}" | LC_ALL=C sort -r)

TARGET_NAME=''
for release_name in "${release_names[@]}"; do
  if [[ $release_name != "$CURRENT_NAME" ]]; then
    TARGET_NAME=$release_name
    break
  fi
done
[[ -n $TARGET_NAME ]] || fail 'there is no previous release to restore'

TARGET_DIR="$RELEASES_DIR/$TARGET_NAME"
[[ -f $TARGET_DIR/index.html && -f $TARGET_DIR/version.json ]] || fail "previous release is incomplete: $TARGET_NAME"
TARGET_COMMIT=$(jq -er '.commit | strings | select(test("^[0-9a-f]{40}$"))' "$TARGET_DIR/version.json") || fail "previous release has invalid version metadata: $TARGET_NAME"

log "testing nginx configuration before switching to $TARGET_NAME"
nginx -t || fail 'nginx configuration test failed; current release was not changed'

log "switching current to releases/$TARGET_NAME"
switch_current "releases/$TARGET_NAME" || fail 'could not atomically switch the current symlink'

if ! systemctl reload nginx; then
  log 'nginx reload failed; restoring the original release'
  restore_original || fail 'nginx reload failed and automatic restoration also failed'
  fail 'rollback could not reload nginx'
fi

if ! curl --fail --silent --show-error --retry 10 --retry-connrefused --retry-delay 1 --max-time 10 "$BASE_URL/healthz" >/dev/null; then
  log 'health check failed; restoring the original release'
  restore_original || fail 'health check failed and automatic restoration also failed'
  fail 'rollback failed health check'
fi

if ! DEPLOYED_VERSION=$(curl --fail --silent --show-error --retry 5 --retry-connrefused --retry-delay 1 --max-time 10 "$BASE_URL/version.json"); then
  log 'could not fetch version.json; restoring the original release'
  restore_original || fail 'version check failed and automatic restoration also failed'
  fail 'rollback could not verify version.json'
fi
if ! DEPLOYED_COMMIT=$(jq -er '.commit | strings' <<< "$DEPLOYED_VERSION") || [[ $DEPLOYED_COMMIT != "$TARGET_COMMIT" ]]; then
  log "version mismatch; restoring the original release (expected $TARGET_COMMIT, got ${DEPLOYED_COMMIT:-invalid})"
  restore_original || fail 'version check failed and automatic restoration also failed'
  fail 'rollback version verification failed'
fi

log "rollback succeeded: $CURRENT_NAME -> $TARGET_NAME ($TARGET_COMMIT)"