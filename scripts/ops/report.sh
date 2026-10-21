#!/usr/bin/env bash
set -Eeuo pipefail

trap 'status=$?; printf "ERROR: command failed (exit %s) at line %s: %s\n" "$status" "$LINENO" "$BASH_COMMAND" >&2' ERR

TEMP_FILE=''
cleanup() {
  if [[ -n ${TEMP_FILE:-} && -f ${TEMP_FILE:-} ]]; then
    rm -f -- "$TEMP_FILE"
  fi
}
trap cleanup EXIT

usage() {
  printf 'Usage: %s [logfile]\n' "$0"
  printf 'Default logfile: /var/log/nginx/africair.access.json\n'
}

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  usage
  exit 0
fi
if [[ $# -gt 1 ]]; then
  usage >&2
  exit 2
fi

LOG_FILE=${1:-/var/log/nginx/africair.access.json}
if [[ ! -f $LOG_FILE || ! -r $LOG_FILE ]]; then
  printf 'ERROR: log file is missing or unreadable: %s\n' "$LOG_FILE" >&2
  exit 1
fi

for command_name in jq awk sort uniq mktemp; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'ERROR: required command is missing: %s\n' "$command_name" >&2
    exit 1
  fi
done

TEMP_FILE=$(mktemp "${TMPDIR:-/tmp}/africair-report.XXXXXX")
CUTOFF=$(jq -n 'now - 3600')

jq -r --argjson cutoff "$CUTOFF" '
  def epoch:
    capture("^(?<wall>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?<zone>Z|(?<sign>[+-])(?<hours>[0-9]{2}):(?<minutes>[0-9]{2}))$") as $parts
    | ($parts.wall | strptime("%Y-%m-%dT%H:%M:%S") | mktime) as $wall_epoch
    | if $parts.zone == "Z" then $wall_epoch
      else
        (($parts.hours | tonumber) * 3600 + ($parts.minutes | tonumber) * 60) as $offset
        | if $parts.sign == "+" then $wall_epoch - $offset else $wall_epoch + $offset end
      end;

  def status_class:
    (.status | tostring) as $status
    | if ($status | test("^[2-5][0-9]{2}$")) then ($status[0:1] + "xx") else "" end;

  def request_path:
    (.request // "")
    | try capture("^[^ ]+ (?<target>[^ ]+)").target catch ""
    | split("?")[0];

  def recent_minute:
    (try (.time | epoch) catch null) as $timestamp
    | if $timestamp != null and $timestamp >= $cutoff
      then ($timestamp | floor / 60 * 60 | gmtime | strftime("%Y-%m-%d %H:%M"))
      else ""
      end;

  [(.remote_addr // ""), status_class, request_path, recent_minute]
  | @tsv
' "$LOG_FILE" > "$TEMP_FILE"

printf '\nTop 10 client IPs\n'
awk -F '\t' 'NF >= 1 && $1 != "" { print $1 }' "$TEMP_FILE" \
  | sort \
  | uniq -c \
  | sort -nr \
  | awk 'NR <= 10 { printf "  %7d %s\n", $1, $2 } END { if (NR == 0) print "  (no requests)" }'

printf '\nRequest counts by status class\n'
awk -F '\t' '
  BEGIN { count["2xx"] = 0; count["3xx"] = 0; count["4xx"] = 0; count["5xx"] = 0 }
  NF >= 2 && $2 in count { count[$2]++ }
  END { for (class in count) printf "%s %d\n", class, count[class] }
' "$TEMP_FILE" | sort -k1,1 | awk '{ printf "  %-4s %d\n", $1, $2 }'

printf '\nTop 10 requested paths (query strings excluded)\n'
awk -F '\t' 'NF >= 3 && $3 != "" { print $3 }' "$TEMP_FILE" \
  | sort \
  | uniq -c \
  | sort -nr \
  | awk 'NR <= 10 { printf "  %7d %s\n", $1, $2 } END { if (NR == 0) print "  (no requests)" }'

printf '\nRequests per minute (last hour, UTC)\n'
awk -F '\t' 'NF >= 4 && $4 != "" { print $4 }' "$TEMP_FILE" \
  | sort \
  | uniq -c \
  | sort -k2,2 \
  | awk '{ printf "  %7d %s\n", $1, $2 } END { if (NR == 0) print "  (no requests in the last hour)" }'