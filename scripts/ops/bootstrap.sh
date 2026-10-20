#!/usr/bin/env bash
set -Eeuo pipefail

trap 'status=$?; printf "ERROR: command failed (exit %s) at line %s: %s\n" "$status" "$LINENO" "$BASH_COMMAND" >&2' ERR

TEMP_DIR=''

cleanup() {
  if [[ -n ${TEMP_DIR:-} && -d ${TEMP_DIR:-} ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
}

trap cleanup EXIT

log() {
  printf '[bootstrap] %s\n' "$*"
}

fail() {
  local line=${BASH_LINENO[0]:-$LINENO}
  printf '[bootstrap] ERROR at line %s: %s\n' "$line" "$*" >&2
  exit 1
}

if [[ ${EUID} -ne 0 ]]; then
  fail 'run this script as root, for example: sudo ./scripts/ops/bootstrap.sh'
fi

if [[ ! -r /etc/os-release ]]; then
  fail 'cannot identify the operating system: /etc/os-release is missing'
fi

# shellcheck disable=SC1091
source /etc/os-release
if [[ ${ID:-} != ubuntu || ${VERSION_ID:-} != 24.04 ]]; then
  fail 'this script supports Ubuntu 24.04 only'
fi

readonly APP_ROOT=/opt/africair
readonly RELEASES_DIR="$APP_ROOT/releases"
readonly SHARED_DIR="$APP_ROOT/shared"
readonly CURRENT_LINK="$APP_ROOT/current"
readonly SERVICE_USER=africair
readonly NODE_MAJOR=22
readonly NODE_SOURCE_KEY_URL=https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key
readonly NODE_SOURCE_KEYRING=/etc/apt/keyrings/nodesource.gpg
readonly NODE_SOURCE_LIST=/etc/apt/sources.list.d/nodesource-africair.list

package_is_installed() {
  local package_status
  package_status=$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null) || return 1
  [[ $package_status == installed ]]
}

ensure_directory() {
  local path owner group mode actual actual_owner actual_group actual_mode
  path=$1
  owner=$2
  group=$3
  mode=$4

  if [[ -L $path ]]; then
    fail "expected a directory, but found a symlink: $path"
  fi
  if [[ ! -d $path ]]; then
    mkdir -p -- "$path"
  fi

  actual=$(stat -c '%U:%G:%a' -- "$path")
  IFS=: read -r actual_owner actual_group actual_mode <<< "$actual"
  if [[ $actual_owner != "$owner" || $actual_group != "$group" ]]; then
    chown "$owner:$group" -- "$path"
  fi
  if [[ $actual_mode != "${mode#0}" ]]; then
    chmod "$mode" -- "$path"
  fi
}

ufw_policy_is() {
  local key=$1 expected=$2
  awk -F= -v key="$key" -v expected="$expected" '
    $1 == key {
      value = $2
      gsub(/["[:space:]]/, "", value)
      if (value == expected) found = 1
    }
    END { exit !found }
  ' /etc/default/ufw
}

node_is_target_version() {
  local node_major
  command -v node >/dev/null 2>&1 || return 1
  node_major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null) || return 1
  [[ $node_major == "$NODE_MAJOR" ]]
}

APT_METADATA_UPDATED=0
BASE_PACKAGES=(ca-certificates curl gnupg git nginx ufw jq)
MISSING_PACKAGES=()

for package in "${BASE_PACKAGES[@]}"; do
  if ! package_is_installed "$package"; then
    MISSING_PACKAGES+=("$package")
  fi
done

if ((${#MISSING_PACKAGES[@]} > 0)); then
  log "installing system packages: ${MISSING_PACKAGES[*]}"
  apt-get update
  APT_METADATA_UPDATED=1
  DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends "${MISSING_PACKAGES[@]}"
else
  log 'required system packages are already installed'
fi

architecture=$(dpkg --print-architecture)
case "$architecture" in
  amd64|arm64) ;;
  *) fail "NodeSource Node.js packages are not configured for architecture: $architecture" ;;
esac

ensure_directory /etc/apt/keyrings root root 0755
NODE_REPOSITORY_LINE="deb [arch=$architecture signed-by=$NODE_SOURCE_KEYRING] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main"
NODE_REPOSITORY_CHANGED=0

if [[ ! -s $NODE_SOURCE_KEYRING ]]; then
  TEMP_DIR=$(mktemp -d)
  curl --fail --silent --show-error --location "$NODE_SOURCE_KEY_URL" --output "$TEMP_DIR/nodesource.asc"
  gpg --batch --yes --dearmor --output "$TEMP_DIR/nodesource.gpg" "$TEMP_DIR/nodesource.asc"
  install -o root -g root -m 0644 "$TEMP_DIR/nodesource.gpg" "$NODE_SOURCE_KEYRING"
  NODE_REPOSITORY_CHANGED=1
fi

if [[ -e $NODE_SOURCE_LIST ]]; then
  if [[ $(<"$NODE_SOURCE_LIST") != "$NODE_REPOSITORY_LINE" ]]; then
    fail "$NODE_SOURCE_LIST already exists with different contents; review it before continuing"
  fi
else
  printf '%s\n' "$NODE_REPOSITORY_LINE" > "$NODE_SOURCE_LIST"
  chmod 0644 "$NODE_SOURCE_LIST"
  NODE_REPOSITORY_CHANGED=1
fi

if [[ $NODE_REPOSITORY_CHANGED -eq 1 ]] || ! node_is_target_version; then
  if [[ $APT_METADATA_UPDATED -eq 0 ]]; then
    log 'refreshing package metadata for Node.js'
    apt-get update
    APT_METADATA_UPDATED=1
  fi
fi

if ! node_is_target_version; then
  log "installing Node.js $NODE_MAJOR LTS"
  DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-install-recommends nodejs
fi

node_is_target_version || fail "Node.js $NODE_MAJOR is required; found $(node --version 2>/dev/null || printf 'no Node.js')"
command -v npm >/dev/null 2>&1 || fail 'npm was not installed with Node.js'

if ! command -v corepack >/dev/null 2>&1; then
  log 'installing Corepack'
  npm install --global corepack
fi
command -v corepack >/dev/null 2>&1 || fail 'Corepack installation failed'

if ! command -v pnpm >/dev/null 2>&1; then
  log 'enabling Corepack package-manager shims'
  corepack enable
fi

ensure_directory "$APP_ROOT" root root 0755

if getent passwd "$SERVICE_USER" >/dev/null 2>&1; then
  service_uid=$(id -u "$SERVICE_USER")
  service_shell=$(getent passwd "$SERVICE_USER" | cut -d: -f7)
  if ((service_uid >= 1000)) || [[ $service_shell != /usr/sbin/nologin ]]; then
    fail "user '$SERVICE_USER' already exists but is not the expected restricted system user"
  fi
  log "system user '$SERVICE_USER' already exists"
else
  log "creating restricted system user '$SERVICE_USER'"
  useradd --system --user-group --home-dir "$SHARED_DIR" --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
fi

ensure_directory "$RELEASES_DIR" "$SERVICE_USER" "$SERVICE_USER" 0750
ensure_directory "$SHARED_DIR" "$SERVICE_USER" "$SERVICE_USER" 0750

if [[ -e $CURRENT_LINK || -L $CURRENT_LINK ]]; then
  if [[ ! -L $CURRENT_LINK ]]; then
    fail "$CURRENT_LINK exists but is not a symlink"
  fi
  current_target=$(readlink -- "$CURRENT_LINK")
  if [[ $current_target != releases/* || ! -d "$APP_ROOT/$current_target" ]]; then
    fail "$CURRENT_LINK must point to an existing directory under releases/"
  fi
  log "current release is $current_target"
else
  log 'no deployed release exists yet; the first deployment will create current'
fi

log 'configuring UFW to deny incoming traffic by default'
if ! ufw_policy_is DEFAULT_INPUT_POLICY DROP; then
  ufw default deny incoming
fi
if ! ufw_policy_is DEFAULT_OUTPUT_POLICY ACCEPT; then
  ufw default allow outgoing
fi
ufw allow 22/tcp comment 'OpenSSH'
ufw allow 80/tcp
ufw allow 443/tcp

if [[ $(ufw status | awk 'NR == 1 { print $2 }') != active ]]; then
  log 'enabling UFW'
  ufw --force enable
else
  log 'UFW is already active'
fi

log 'bootstrap complete'