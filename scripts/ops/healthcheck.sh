#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR=/var/lib/africair
STATE_FILE="$STATE_DIR/healthcheck.failures"
HEALTH_URL=${AFRICAIR_HEALTHCHECK_URL:-http://127.0.0.1/healthz}
MAX_FAILURES=3

log() {
  local priority=$1
  shift
  logger -t africair-health -p "user.$priority" -- "$*"
}

fail_unexpected() {
  local status=$?
  logger -t africair-health -p user.err -- "ERROR: healthcheck command failed at line ${BASH_LINENO[0]:-$LINENO}: ${BASH_COMMAND} (exit $status)" || true
  exit "$status"
}

trap fail_unexpected ERR

if [[ $EUID -ne 0 ]]; then
  printf 'healthcheck.sh must run as root\n' >&2
  exit 1
fi

for command_name in curl logger systemctl; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'required command is missing: %s\n' "$command_name" >&2
    exit 1
  fi
done

install -d -o root -g root -m 0750 "$STATE_DIR"

write_failure_count() {
  local count=$1
  local temporary_file
  temporary_file=$(mktemp "$STATE_DIR/.healthcheck.failures.XXXXXX")
  printf '%s\n' "$count" > "$temporary_file"
  chmod 0640 "$temporary_file"
  mv -f -- "$temporary_file" "$STATE_FILE"
}

previous_count=0
if [[ -f $STATE_FILE ]]; then
  IFS= read -r previous_count < "$STATE_FILE" || previous_count=0
  if [[ ! $previous_count =~ ^[0-9]+$ ]]; then
    log warning "invalid failure counter; resetting $STATE_FILE"
    previous_count=0
  fi
fi
if ((previous_count > MAX_FAILURES)); then
  previous_count=$MAX_FAILURES
fi

if response=$(curl --fail --silent --show-error --max-time 5 "$HEALTH_URL") && [[ $response == ok ]]; then
  write_failure_count 0
  log info "health check passed: $HEALTH_URL; failure counter reset"
  exit 0
fi

failure_count=$((previous_count + 1))
if ((failure_count > MAX_FAILURES)); then
  failure_count=$MAX_FAILURES
fi
write_failure_count "$failure_count"

if ((failure_count == MAX_FAILURES && previous_count < MAX_FAILURES)); then
  log warning "WARNING: health check failed $failure_count consecutive times; reloading nginx"
  if systemctl reload nginx; then
    log info 'nginx reload completed after three consecutive health check failures'
  else
    log warning 'WARNING: nginx reload failed after three consecutive health check failures'
  fi
elif ((failure_count == MAX_FAILURES)); then
  log err "health check still failing after $failure_count consecutive failures; nginx reload already attempted"
else
  log err "health check failed ($failure_count/$MAX_FAILURES): $HEALTH_URL"
fi

exit 1