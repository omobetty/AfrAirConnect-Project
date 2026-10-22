#!/usr/bin/env bash
set -Eeuo pipefail

trap 'status=$?; printf "ERROR: command failed (exit %s) at line %s: %s\n" "$status" "$LINENO" "$BASH_COMMAND" >&2' ERR

STAGING_DIR=''
API_STAGING_DIR=''
TEMP_LINK=''
NEW_RELEASE=''
API_NEW_RELEASE=''
PREVIOUS_TARGET=''
API_PREVIOUS_TARGET=''
DEPLOY_SUCCEEDED=0

cleanup() {
  if [[ -n ${TEMP_LINK:-} && -L ${TEMP_LINK:-} ]]; then
    rm -f -- "$TEMP_LINK"
  fi
  if [[ -n ${STAGING_DIR:-} && -d ${STAGING_DIR:-} ]]; then
    rm -rf -- "$STAGING_DIR"
  fi
  if [[ -n ${API_STAGING_DIR:-} && -d ${API_STAGING_DIR:-} ]]; then
    rm -rf -- "$API_STAGING_DIR"
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
  if [[ ${DEPLOY_SUCCEEDED:-0} -eq 0 && -n ${API_NEW_RELEASE:-} && -d ${API_NEW_RELEASE:-} ]]; then
    local api_active_target=''
    if [[ -L ${API_CURRENT_LINK:-} ]]; then
      api_active_target=$(readlink -- "$API_CURRENT_LINK" 2>/dev/null || true)
    fi
    if [[ $api_active_target != "releases/${API_NEW_RELEASE##*/}" ]]; then
      rm -rf -- "$API_NEW_RELEASE"
    else
      printf '[deploy] WARNING: preserving failed API release because current still points to it: %s\n' "$API_NEW_RELEASE" >&2
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
  printf 'Usage: sudo %s <web-artifact.tar.gz> [api-artifact.tar.gz]\n' "$0"
}

switch_link() {
  local link=$1
  local parent_dir=$2
  local target=$3
  TEMP_LINK="$parent_dir/.current.deploy.$$.$RANDOM"
  ln -sfn -- "$target" "$TEMP_LINK" || return 1
  mv -Tf -- "$TEMP_LINK" "$link" || return 1
  TEMP_LINK=''
}

switch_current() {
  switch_link "$CURRENT_LINK" "$APP_ROOT" "$1"
}

switch_api_current() {
  switch_link "$API_CURRENT_LINK" "$API_ROOT" "$1"
}

switch_api_to_previous() {
  if [[ -n $API_PREVIOUS_TARGET ]]; then
    switch_api_current "$API_PREVIOUS_TARGET" || return 1
    systemctl restart africair-api.service || return 1
  else
    rm -f -- "$API_CURRENT_LINK" || return 1
    systemctl stop africair-api.service >/dev/null 2>&1 || true
  fi
}

inspect_archive() {
  local archive=$1
  local archive_root=$2
  local staging_dir=$3
  local entry
  local entry_type

  tar -tzf "$archive" > "$staging_dir/archive.list" || return 1
  tar -tvzf "$archive" > "$staging_dir/archive.details" || return 1

  while IFS= read -r entry; do
    [[ $entry == "$archive_root" || $entry == "$archive_root"/* ]] || return 1
    [[ $entry != /* && ! $entry =~ (^|/)\.\.(/|$) ]] || return 1
  done < "$staging_dir/archive.list"

  while IFS= read -r entry; do
    entry_type=${entry:0:1}
    [[ $entry_type == d || $entry_type == - ]] || return 1
  done < "$staging_dir/archive.details"
}

restore_previous() {
  if [[ -n $API_ARTIFACT ]]; then
    switch_api_to_previous || return 1
  fi
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
if [[ $# -lt 1 || $# -gt 2 || -z ${1:-} ]]; then
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
readonly API_ROOT="$APP_ROOT/api"
readonly API_RELEASES_DIR="$API_ROOT/releases"
readonly API_CURRENT_LINK="$API_ROOT/current"
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
API_ARTIFACT=''
if [[ -n ${2:-} ]]; then
  API_ARTIFACT=$(realpath -e -- "$2") || fail "API artifact does not exist: $2"
  [[ -f $API_ARTIFACT ]] || fail "API artifact is not a regular file: $API_ARTIFACT"
fi
CHECKSUM_FILE="${ARTIFACT}.sha256"
[[ -f $CHECKSUM_FILE ]] || fail "checksum file is missing: $CHECKSUM_FILE"

log 'verifying artifact checksum'
if ! (cd -- "$(dirname -- "$ARTIFACT")" && sha256sum --check --strict --status -- "$(basename -- "$CHECKSUM_FILE")"); then
  fail 'artifact checksum verification failed'
fi
if [[ -n $API_ARTIFACT ]]; then
  API_CHECKSUM_FILE="${API_ARTIFACT}.sha256"
  [[ -f $API_CHECKSUM_FILE ]] || fail "API checksum file is missing: $API_CHECKSUM_FILE"
  if ! (cd -- "$(dirname -- "$API_ARTIFACT")" && sha256sum --check --strict --status -- "$(basename -- "$API_CHECKSUM_FILE")"); then
    fail 'API artifact checksum verification failed'
  fi
fi

if [[ -L $CURRENT_LINK ]]; then
  PREVIOUS_TARGET=$(readlink -- "$CURRENT_LINK") || fail 'could not read current symlink'
  [[ $PREVIOUS_TARGET == releases/* && ${PREVIOUS_TARGET#releases/} != */* ]] || fail "current symlink points outside the release layout: $PREVIOUS_TARGET"
  [[ -d "$APP_ROOT/$PREVIOUS_TARGET" ]] || fail "current symlink target does not exist: $PREVIOUS_TARGET"
elif [[ -e $CURRENT_LINK ]]; then
  fail "$CURRENT_LINK exists but is not a symlink"
fi

if [[ -n $API_ARTIFACT ]]; then
  systemctl cat africair-api.service >/dev/null 2>&1 || fail 'africair-api.service is not installed; install the B8 service unit first'
  install -d -o root -g "$SERVICE_GROUP" -m 0750 "$API_ROOT"
  install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 0750 "$API_RELEASES_DIR"
  if [[ -L $API_CURRENT_LINK ]]; then
    API_PREVIOUS_TARGET=$(readlink -- "$API_CURRENT_LINK") || fail 'could not read API current symlink'
    [[ $API_PREVIOUS_TARGET == releases/* && ${API_PREVIOUS_TARGET#releases/} != */* ]] || fail "API current symlink points outside its release layout: $API_PREVIOUS_TARGET"
    [[ -d "$API_ROOT/$API_PREVIOUS_TARGET" ]] || fail "API current symlink target does not exist: $API_PREVIOUS_TARGET"
  elif [[ -e $API_CURRENT_LINK ]]; then
    fail "$API_CURRENT_LINK exists but is not a symlink"
  fi
fi

STAGING_DIR=$(mktemp -d "$RELEASES_DIR/.staging.XXXXXX") || fail 'could not create a staging directory under releases/'

log 'checking archive paths and entry types'
inspect_archive "$ARTIFACT" dist "$STAGING_DIR" || fail 'web artifact is unreadable or contains an unexpected path or file type'

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

API_RELEASE_NAME=''
if [[ -n $API_ARTIFACT ]]; then
  API_STAGING_DIR=$(mktemp -d "$API_RELEASES_DIR/.staging.XXXXXX") || fail 'could not create API staging directory'
  inspect_archive "$API_ARTIFACT" api "$API_STAGING_DIR" || fail 'API artifact is unreadable or contains an unexpected path or file type'
  tar --extract --gzip --file "$API_ARTIFACT" --directory "$API_STAGING_DIR" --no-same-owner --no-same-permissions || fail 'could not extract the API artifact'

  API_PACKAGE="$API_STAGING_DIR/api"
  [[ -f $API_PACKAGE/dist/index.js && -f $API_PACKAGE/dist/migrate.js && -d $API_PACKAGE/migrations ]] || fail 'API artifact is missing compiled entry points or migrations'
  [[ -d $API_PACKAGE/node_modules/pg && -d $API_PACKAGE/node_modules/prom-client ]] || fail 'API artifact is missing production dependencies'
  API_COMMIT=$(jq -er '.commit | strings | select(test("^[0-9a-f]{40}$"))' "$API_PACKAGE/version.json") || fail 'API version metadata has no valid full commit SHA'
  [[ $API_COMMIT == "$COMMIT" ]] || fail 'web and API artifacts are from different commits'
  API_ARTIFACT_NAME=$(basename -- "$API_ARTIFACT")
  [[ $API_ARTIFACT_NAME == "africair-api-${EXPECTED_SHORT_SHA}.tar.gz" ]] || fail "API artifact name does not match version.json commit: expected africair-api-${EXPECTED_SHORT_SHA}.tar.gz"

  API_RELEASE_NAME="${RELEASE_TIMESTAMP}-${API_COMMIT}"
  API_NEW_RELEASE="$API_RELEASES_DIR/$API_RELEASE_NAME"
  [[ ! -e $API_NEW_RELEASE && ! -L $API_NEW_RELEASE ]] || fail "API release already exists: $API_NEW_RELEASE"
  printf 'GIT_SHA=%s\n' "$API_COMMIT" > "$API_PACKAGE/version.env" || fail 'could not create API version environment file'
  mv -- "$API_PACKAGE" "$API_NEW_RELEASE" || fail 'could not move API files into the release directory'
  chown -R "$SERVICE_USER:$SERVICE_GROUP" "$API_NEW_RELEASE" || fail 'could not assign API release ownership to africair'
  chmod 0750 "$API_NEW_RELEASE" || fail 'could not set API release directory permissions'
  rm -rf -- "$API_STAGING_DIR" || fail 'could not remove temporary API staging directory'
  API_STAGING_DIR=''
fi

mv -- "$STAGING_DIR/dist" "$NEW_RELEASE" || fail 'could not move extracted files into the release directory'
chown -R "$SERVICE_USER:$SERVICE_GROUP" "$NEW_RELEASE" || fail 'could not assign release ownership to africair'
chmod 0755 "$NEW_RELEASE" || fail 'could not set release directory permissions'
rm -rf -- "$STAGING_DIR" || fail 'could not remove the temporary staging directory'
STAGING_DIR=''

log 'testing nginx configuration before reload'
nginx -t || fail 'nginx configuration test failed; current release was not changed'

if [[ -n $API_ARTIFACT ]]; then
  log "switching API current to releases/$API_RELEASE_NAME"
  switch_api_current "releases/$API_RELEASE_NAME" || fail 'could not atomically switch the API current symlink'
  if ! systemctl restart africair-api.service; then
    rollback_after_failure 'API service restart failed'
    fail 'API deployment failed while restarting the service'
  fi

  log 'checking API readiness and PostgreSQL connectivity'
  if ! API_READY=$(curl --fail --silent --show-error --retry 15 --retry-connrefused --retry-delay 1 --max-time 10 "$BASE_URL/api/readyz"); then
    rollback_after_failure 'API readiness check failed'
    fail 'API deployment failed readiness check'
  fi
  if ! jq -e '.status == "ready" and .db == "connected"' <<< "$API_READY" >/dev/null; then
    rollback_after_failure 'API did not report a connected database'
    fail 'API deployment did not become database-ready'
  fi

  log 'checking API runtime settings and file-based credentials'
  if ! API_CONFIG=$(curl --fail --silent --show-error --retry 5 --retry-connrefused --retry-delay 1 --max-time 10 "$BASE_URL/api/config"); then
    rollback_after_failure 'could not fetch API runtime config'
    fail 'API deployment could not verify runtime configuration'
  fi
  EXPECTED_API_ENV=${AFRICAIR_EXPECT_APP_ENV:-staging}
  if ! jq -e --arg env "$EXPECTED_API_ENV" --arg commit "$API_COMMIT" '
    .appEnv == $env and .commit == $commit and .storage == "database" and
    .secrets.database.status == "connected" and .secrets.database.source == "file" and
    .secrets.adminToken.configured == true and .secrets.adminToken.source == "file" and
    .secrets.promoCodes.count > 0 and .secrets.promoCodes.source == "file"
  ' <<< "$API_CONFIG" >/dev/null; then
    rollback_after_failure 'API config does not match staging/database/file-credential expectations'
    fail 'API deployment runtime configuration verification failed'
  fi
fi

log "switching current to releases/$RELEASE_NAME"
if ! switch_current "releases/$RELEASE_NAME"; then
  rollback_after_failure 'could not atomically switch the web current symlink'
  fail 'could not atomically switch the current symlink'
fi

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

if [[ -n $API_ARTIFACT ]]; then
  log 'pruning API releases older than the five most recent'
  api_release_names=()
  for api_release_path in "$API_RELEASES_DIR"/*; do
    [[ -d $api_release_path && ! -L $api_release_path ]] || continue
    api_release_name=${api_release_path##*/}
    [[ $api_release_name =~ ^[0-9]{8}T[0-9]{6}\.[0-9]{9}Z-[0-9a-f]{40}$ ]] || continue
    api_release_names+=("$api_release_name")
  done

  if ((${#api_release_names[@]} > 0)); then
    mapfile -t api_release_names < <(printf '%s\n' "${api_release_names[@]}" | LC_ALL=C sort -r)
    api_current_name=${API_RELEASE_NAME}
    api_retained_others=0
    for api_release_name in "${api_release_names[@]}"; do
      [[ $api_release_name == "$api_current_name" ]] && continue
      if ((api_retained_others < 4)); then
        ((api_retained_others += 1))
        continue
      fi
      rm -rf -- "$API_RELEASES_DIR/$api_release_name"
      log "removed old API release $api_release_name"
    done
  fi
fi

log "deployment succeeded: $RELEASE_NAME"
DEPLOY_SUCCEEDED=1