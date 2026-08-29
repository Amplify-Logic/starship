#!/usr/bin/env bash
# fm-order.sh - Standing Order operations over data/orders/<slug>.md.
#
# A Standing Order is one captain-approved markdown file per capability.
# This script lists, shows, runs, arms, disarms, and graduates those files.
# Arm, disarm, and graduate require --by-captain: firstmate must not self-arm;
# the flag is the invoker's attestation that the captain's word authorized it.
# Graduate structurally refuses any action kind the gateway's ceiling classifier
# treats as non-graduatable (it calls fm-action-gateway.sh classify; it does
# not duplicate the spend/messaging/irreversible list).
# File format: header + Status + Watch / Stage / Last click / Reaches me / Route.
# Parse is lenient on optional sections and fails loudly on a missing Status line.
# log-fire is the Watch self-logging filter: a check pipes its output through it
# so a printed wake line appends a 'ts=<epoch> fired' line to
# state/order-<slug>.check.log, the only source list reads for the last fire
# (no recorded fire renders '-'). run records a fire on the same terms: only
# when the check printed a wake line, never on a quiet or timed-out run, and
# always by appending so earlier fire history survives.
# Object model: docs/ops-command-center.md.
#
# Commands:
#   list
#   show <slug>
#   run <slug>
#   log-fire <slug>
#   arm <slug> --by-captain
#   disarm <slug> --by-captain
#   graduate <slug> <action-kind> --by-captain
#   -h|--help
#
# Environment:
#   FM_HOME / FM_DATA_OVERRIDE / FM_STATE_OVERRIDE - home roots
#   FM_ACTION_GATEWAY_TEST / FM_ACTION_* - forwarded to fm-tray.sh
#   FM_CHECK_TIMEOUT - seconds allowed for run (default 30)
#
# Exit:
#   0 on success
#   1 on usage, missing Status, missing flag, unregistered check, timed-out check,
#     or non-graduatable kind
#   run otherwise exits with the registered check's own status
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ORDERS="$DATA/orders"
CHECK_TIMEOUT="${FM_CHECK_TIMEOUT:-30}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  cat <<'EOF' >&2
usage: fm-order.sh list
       fm-order.sh show <slug>
       fm-order.sh run <slug>
       fm-order.sh log-fire <slug>
       fm-order.sh arm <slug> --by-captain
       fm-order.sh disarm <slug> --by-captain
       fm-order.sh graduate <slug> <action-kind> --by-captain
       fm-order.sh -h|--help

Standing Order operations over data/orders/<slug>.md.
arm/disarm/graduate require --by-captain (the captain's word; firstmate
must not self-arm). Graduate refuses kinds the action gateway's ceiling
classifier treats as non-graduatable. log-fire is a stdout filter for an
order's Watch check: it passes output through unchanged and appends a fire
line to state/order-<slug>.check.log when that output is non-empty. run
records a fire on the same terms; a quiet or timed-out run records none.
See docs/ops-command-center.md.
EOF
}

fail() {
  printf 'fm-order: %s\n' "$*" >&2
  exit 1
}

slug_valid() {
  fm_task_id_path_safe "$1"
}

order_path() {
  printf '%s/%s.md\n' "$ORDERS" "$1"
}

check_id() {
  printf 'order-%s\n' "$1"
}

require_by_captain() {
  local op=$1
  [ "$BY_CAPTAIN" = "1" ] || fail "$op requires --by-captain (the captain's word is the authority; firstmate must not self-arm)"
}

status_line_of() {
  local file=$1 line
  line=$(awk 'tolower($0) ~ /^[[:space:]]*status:[[:space:]]*/ { print; exit }' "$file")
  [ -n "$line" ] || fail "order missing Status line: ${file#"$FM_HOME"/}"
  printf '%s\n' "$line"
}

status_token() {
  local line=$1
  printf '%s\n' "$line" | sed 's/^[[:space:]]*[Ss][Tt][Aa][Tt][Uu][Ss]:[[:space:]]*//' | awk '{print toupper($1)}'
}

format_age() {
  local secs=$1
  if [ "$secs" -lt 0 ]; then
    secs=0
  fi
  if [ "$secs" -lt 60 ]; then
    printf '%ss\n' "$secs"
  elif [ "$secs" -lt 3600 ]; then
    printf '%sm\n' $((secs / 60))
  elif [ "$secs" -lt 86400 ]; then
    printf '%sh\n' $((secs / 3600))
  else
    printf '%sd\n' $((secs / 86400))
  fi
}

now_ts() {
  if [ "${FM_ACTION_GATEWAY_TEST:-}" = "1" ] && [ -n "${FM_ACTION_GATEWAY_NOW:-}" ]; then
    printf '%s\n' "$FM_ACTION_GATEWAY_NOW"
    return 0
  fi
  python3 -c 'import time; print(int(time.time()))'
}

fire_log_path() {
  printf '%s/%s.check.log\n' "$STATE" "$(check_id "$1")"
}

record_fire() {
  local log=$1
  mkdir -p "$STATE"
  (
    umask 077
    printf 'ts=%s fired\n' "$(now_ts)" >> "$log"
  )
  chmod 0600 "$log" 2>/dev/null || true
}

last_fire_for() {
  local slug=$1 log now ts
  log=$(fire_log_path "$slug")
  if [ ! -f "$log" ]; then
    printf '%s\n' '-'
    return 0
  fi
  ts=$(awk '
    $0 ~ /(^|[[:space:]])fired([[:space:]]|$)/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^ts=[0-9]+$/) { t = substr($i, 4) }
      }
    }
    END { if (t != "") print t }
  ' "$log")
  if [ -z "$ts" ]; then
    printf '%s\n' '-'
    return 0
  fi
  now=$(now_ts)
  format_age $((now - ts))
}

tray_depth_for() {
  local slug=$1 line n
  if ! line=$("$SCRIPT_DIR/fm-tray.sh" counts --order "$slug"); then
    printf '%s\n' '?'
    return 0
  fi
  n=${line#TRAY }
  n=${n%% *}
  case "$n" in
    ''|*[!0-9]*) printf '%s\n' '?' ;;
    *) printf '%s\n' "$n" ;;
  esac
}

require_order() {
  local slug=$1 path
  slug_valid "$slug" || fail "invalid order slug: $slug"
  path=$(order_path "$slug")
  [ -f "$path" ] || fail "order not found: $slug"
  printf '%s\n' "$path"
}

rewrite_status() {
  local file=$1 new_line=$2 tmp mode
  mode=$(fm_pr_file_mode "$file" || true)
  tmp=$(mktemp "${file}.XXXXXX")
  if ! awk -v repl="$new_line" '
    BEGIN { done=0 }
    tolower($0) ~ /^[[:space:]]*status:[[:space:]]*/ && !done {
      print repl
      done=1
      next
    }
    { print }
    END { if (!done) exit 1 }
  ' "$file" > "$tmp"; then
    rm -f "$tmp"
    fail "order missing Status line: ${file#"$FM_HOME"/}"
  fi
  [ -z "$mode" ] || chmod "$mode" "$tmp"
  mv "$tmp" "$file"
}

captain_date() {
  date -u +%Y-%m-%d
}

cmd_list() {
  local slug path line token depth fire
  [ "$#" -eq 0 ] || fail "list takes no arguments"
  if [ ! -d "$ORDERS" ]; then
    printf '%s\n' "(no standing orders)"
    return 0
  fi
  shopt -s nullglob
  local found=0
  for path in "$ORDERS"/*.md; do
    found=1
    slug=$(basename "$path" .md)
    slug_valid "$slug" || fail "invalid order filename: $(basename "$path")"
    line=$(status_line_of "$path")
    token=$(status_token "$line")
    [ -n "$token" ] || fail "order missing Status line: orders/${slug}.md"
    depth=$(tray_depth_for "$slug")
    fire=$(last_fire_for "$slug")
    printf '%s\t%s\ttray=%s\tlast_fire=%s\n' "$slug" "$line" "$depth" "$fire"
  done
  shopt -u nullglob
  if [ "$found" -eq 0 ]; then
    printf '%s\n' "(no standing orders)"
  fi
}

cmd_show() {
  local slug=$1 path
  [ -n "$slug" ] || fail "show requires a slug"
  path=$(require_order "$slug")
  status_line_of "$path" >/dev/null
  printf '%s\n' "=== order $slug ==="
  cat "$path"
  printf '\n%s\n' "=== live tray cards ==="
  "$SCRIPT_DIR/fm-tray.sh" --order "$slug"
}

cmd_run() {
  local slug=$1 id rc out
  [ -n "$slug" ] || fail "run requires a slug"
  require_order "$slug" >/dev/null
  id=$(check_id "$slug")
  if ! fm_custom_check_registered "$STATE" "$id"; then
    fail "no registered check for order $slug (need state/${id}.check.sh bound with fm-check-register.sh)"
  fi
  mkdir -p "$STATE"
  if ! fm_custom_check_snapshot_prepare "$STATE" "$id"; then
    fm_custom_check_snapshot_cleanup
    fail "registered check for order $slug failed snapshot checks"
  fi
  set +e
  out=$(fm_run_timeout "$CHECK_TIMEOUT" bash "$FM_CUSTOM_CHECK_SNAPSHOT")
  rc=$?
  set -e
  fm_custom_check_snapshot_cleanup
  if [ "$rc" -eq 124 ]; then
    fail "order $slug check timed out after ${CHECK_TIMEOUT}s"
  fi
  if [ -n "$out" ]; then
    record_fire "$(fire_log_path "$slug")"
    printf '%s\n' "$out"
  fi
  return "$rc"
}

cmd_log_fire() {
  local slug=$1 line fired=0
  slug_valid "$slug" || fail "invalid order slug: $slug"
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line"
    [ -z "$line" ] || fired=1
  done
  [ "$fired" -eq 1 ] || return 0
  record_fire "$(fire_log_path "$slug")"
}

cmd_arm() {
  local slug=$1 path line token date
  require_by_captain arm
  path=$(require_order "$slug")
  line=$(status_line_of "$path")
  token=$(status_token "$line")
  if [ "$token" = "ARMED" ]; then
    printf '%s\n' "already ARMED: $slug"
    return 0
  fi
  [ "$token" = "DRAFT" ] || fail "arm expects Status DRAFT (got $token)"
  date=$(captain_date)
  rewrite_status "$path" "Status: ARMED (captain $date)"
  printf '%s\n' "armed: $slug"
}

cmd_disarm() {
  local slug=$1 path line token
  require_by_captain disarm
  path=$(require_order "$slug")
  line=$(status_line_of "$path")
  token=$(status_token "$line")
  if [ "$token" = "DRAFT" ]; then
    printf '%s\n' "already DRAFT: $slug"
    return 0
  fi
  [ "$token" = "ARMED" ] || fail "disarm expects Status ARMED (got $token)"
  rewrite_status "$path" "Status: DRAFT"
  printf '%s\n' "disarmed: $slug"
}

cmd_graduate() {
  local slug=$1 kind=$2 path classif graduatable severity ceiling rc=0
  require_by_captain graduate
  [ -n "$kind" ] || fail "graduate requires an action kind"
  path=$(require_order "$slug")
  status_line_of "$path" >/dev/null
  classif=$("$SCRIPT_DIR/fm-action-gateway.sh" classify --action-kind "$kind" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    [ -z "$classif" ] || printf '%s\n' "$classif" >&2
    case "$classif" in
      *deny-by-default*)
        fail "graduate refused: unknown or unregistered action kind $kind (gateway deny-by-default)"
        ;;
    esac
    fail "graduate aborted: gateway classify failed for $kind"
  fi
  graduatable=$(printf '%s\n' "$classif" | awk -F= '$1=="graduatable" {print $2; exit}')
  severity=$(printf '%s\n' "$classif" | awk -F= '$1=="severity" {print $2; exit}')
  ceiling=$(printf '%s\n' "$classif" | awk -F= '$1=="ceiling" {print $2; exit}')
  if [ "$graduatable" != "yes" ]; then
    fail "graduate refused: $kind is not graduatable (gateway ceiling classifier: severity=${severity:-?} ceiling=${ceiling:-none})"
  fi
  if grep -F "GRADUATED: $kind " "$path" >/dev/null 2>&1; then
    printf '%s\n' "already graduated: $slug $kind"
    return 0
  fi
  printf '\nGRADUATED: %s (captain %s)\n' "$kind" "$(captain_date)" >> "$path"
  printf '%s\n' "graduated: $slug $kind"
}

parse_global() {
  BY_CAPTAIN=0
  POS=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --by-captain)
        BY_CAPTAIN=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        POS+=("$@")
        break
        ;;
      -*)
        fail "unknown flag: $1"
        ;;
      *)
        POS+=("$1")
        shift
        ;;
    esac
  done
}

main() {
  local op
  parse_global "$@"
  set -- "${POS[@]+"${POS[@]}"}"

  if [ "$#" -eq 0 ]; then
    usage
    exit 1
  fi

  op=$1
  shift
  case "$op" in
    list)
      cmd_list "$@"
      ;;
    show)
      [ "$#" -eq 1 ] || fail "show requires a slug"
      cmd_show "$1"
      ;;
    run)
      [ "$#" -eq 1 ] || fail "run requires a slug"
      cmd_run "$1"
      ;;
    log-fire)
      [ "$#" -eq 1 ] || fail "log-fire requires a slug"
      cmd_log_fire "$1"
      ;;
    arm)
      [ "$#" -eq 1 ] || fail "arm requires a slug"
      cmd_arm "$1"
      ;;
    disarm)
      [ "$#" -eq 1 ] || fail "disarm requires a slug"
      cmd_disarm "$1"
      ;;
    graduate)
      [ "$#" -eq 2 ] || fail "graduate requires a slug and an action kind"
      cmd_graduate "$1" "$2"
      ;;
    *)
      fail "unknown command: $op"
      ;;
  esac
}

main "$@"
