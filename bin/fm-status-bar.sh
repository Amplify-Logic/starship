#!/usr/bin/env bash
# Render the canonical Firstmate primary status bar.
#
# Usage:
#   fm-status-bar.sh --adapter claude
#   fm-status-bar.sh --adapter pi --model MODEL --effort LEVEL \
#     --context-remaining PERCENT --quota-used PERCENT --cost USD
#   fm-status-bar.sh --adapter kimi --model MODEL --effort LEVEL \
#     --follow-pane TMUX_PANE
#
# Claude mode reads the native statusLine JSON payload from stdin.
# Pi supplies its native footer metrics as normalized arguments.
# Kimi's guarded primary launcher uses --follow-pane for a one-row tmux
# companion because Kimi 0.27.0 has no third-party status-bar API.
#
# The complete field, threshold, color, placeholder, and adapter contract lives
# in docs/status-bar.md.
# This renderer is inert unless FM_PRIMARY_HARNESS matches --adapter, so tracked
# project integrations never activate outside bin/fm-primary.sh.
#
# Test seam:
#   FM_STATUS_BAR_NOW overrides the current epoch.
set -u

SCRIPT_DIR=$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=$(CDPATH='' cd -P -- "$SCRIPT_DIR/.." && pwd -P)
FM_HOME=${FM_HOME:-$FM_ROOT}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}

ADAPTER=
MODEL=--
EFFORT=--
CONTEXT_REMAINING=--
QUOTA_USED=--
COST=--
FOLLOW_PANE=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --adapter)
      [ "$#" -ge 2 ] || exit 0
      ADAPTER=$2
      shift 2
      ;;
    --model)
      [ "$#" -ge 2 ] || exit 0
      MODEL=$2
      shift 2
      ;;
    --effort)
      [ "$#" -ge 2 ] || exit 0
      EFFORT=$2
      shift 2
      ;;
    --context-remaining)
      [ "$#" -ge 2 ] || exit 0
      CONTEXT_REMAINING=$2
      shift 2
      ;;
    --quota-used)
      [ "$#" -ge 2 ] || exit 0
      QUOTA_USED=$2
      shift 2
      ;;
    --cost)
      [ "$#" -ge 2 ] || exit 0
      COST=$2
      shift 2
      ;;
    --follow-pane)
      [ "$#" -ge 2 ] || exit 0
      FOLLOW_PANE=$2
      shift 2
      ;;
    *)
      exit 0
      ;;
  esac
done

case "$ADAPTER" in
  claude|pi|kimi) ;;
  *) exit 0 ;;
esac
[ "${FM_PRIMARY_HARNESS:-}" = "$ADAPTER" ] || exit 0

sanitize_label() {
  local value=${1:---}
  value=${value//$'\n'/ }
  value=${value//$'\r'/ }
  value=${value//$'\t'/ }
  value=$(printf '%s' "$value" | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177')
  [ -n "$value" ] || value=--
  printf '%s' "$value"
}

normalize_percent() {
  local value=${1:---}
  case "$value" in
    ''|--|*[!0-9]*) printf '%s' -- ;;
    *)
      [ "$value" -le 100 ] 2>/dev/null || value=100
      printf '%s' "$value"
      ;;
  esac
}

normalize_cost() {
  local value=${1:---}
  case "$value" in
    ''|--|*[!0-9.]*|*.*.*) printf '%s' -- ;;
    *)
      LC_NUMERIC=C printf '%.2f' "$value" 2>/dev/null || printf '%s' --
      ;;
  esac
}

if [ "$ADAPTER" = claude ]; then
  input=$(cat 2>/dev/null || printf '')
  if command -v jq >/dev/null 2>&1; then
    IFS=$'\t' read -r MODEL EFFORT CONTEXT_REMAINING QUOTA_USED COST <<EOF
$(printf '%s' "$input" | jq -r '
  [
    (.model.display_name // .model.id // "--" | tostring),
    (.effort.level // "--" | tostring),
    (if (.context_window.remaining_percentage | type) == "number"
      then (.context_window.remaining_percentage | floor)
      else "--"
      end),
    (if (.rate_limits.five_hour.used_percentage | type) == "number"
      then (.rate_limits.five_hour.used_percentage | floor)
      else "--"
      end),
    (if (.cost.total_cost_usd | type) == "number"
      then .cost.total_cost_usd
      else "--"
      end)
  ] | @tsv
' 2>/dev/null)
EOF
  fi
fi

MODEL=$(sanitize_label "$MODEL")
EFFORT=$(sanitize_label "$EFFORT")
CONTEXT_REMAINING=$(normalize_percent "$CONTEXT_REMAINING")
QUOTA_USED=$(normalize_percent "$QUOTA_USED")
COST=$(normalize_cost "$COST")

G=$'\033[92m'
Y=$'\033[93m'
R=$'\033[91m'
C=$'\033[96m'
D=$'\033[2m'
BOLD=$'\033[1m'
BR=$'\033[91;1m'
X=$'\033[0m'

last_status_line() {
  local file=$1
  [ -f "$file" ] || return 0
  awk 'NF { line=$0 } END { print line }' "$file" 2>/dev/null
}

fleet_counts() {
  local meta id kind last
  ACTIVE_COUNT=0
  PAUSED_COUNT=0
  ATTENTION_COUNT=0
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    kind=$(awk -F= '$1 == "kind" { print substr($0, index($0, "=") + 1); exit }' "$meta" 2>/dev/null)
    [ "$kind" = secondmate ] && continue
    ACTIVE_COUNT=$((ACTIVE_COUNT + 1))
    id=$(basename "$meta" .meta)
    last=$(last_status_line "$STATE/$id.status")
    case "$last" in
      paused:*) PAUSED_COUNT=$((PAUSED_COUNT + 1)) ;;
      needs-decision:*|blocked:*|failed:*) ATTENTION_COUNT=$((ATTENTION_COUNT + 1)) ;;
    esac
  done
}

supervision_age() {
  local beat="$STATE/.last-watcher-beat" now modified age
  now=${FM_STATUS_BAR_NOW:-$(date +%s 2>/dev/null)}
  case "$now" in
    ''|*[!0-9]*)
      printf '%s' --
      return
      ;;
  esac
  [ -f "$beat" ] || {
    printf '%s' --
    return
  }
  modified=$(stat -f %m "$beat" 2>/dev/null || stat -c %Y "$beat" 2>/dev/null)
  case "$modified" in
    ''|*[!0-9]*)
      printf '%s' --
      return
      ;;
  esac
  age=$((now - modified))
  [ "$age" -ge 0 ] || age=0
  printf '%s' "$age"
}

render_once() {
  local anchor separator context_part quota_part paused_color attention_color
  local fleet_part watch_part cost_part afk_part age context_color quota_color

  fleet_counts
  age=$(supervision_age)
  separator=" ${D}│${X} "
  anchor="${BOLD}⚓ ${MODEL}${X}${D}·${X}${EFFORT}"

  if [ "$CONTEXT_REMAINING" = -- ]; then
    context_part="${D}🧠--${X}"
  else
    context_color=$G
    [ "$CONTEXT_REMAINING" -ge 30 ] || context_color=$Y
    [ "$CONTEXT_REMAINING" -ge 15 ] || context_color=$R
    context_part="${context_color}🧠${CONTEXT_REMAINING}%${X}"
  fi

  if [ "$QUOTA_USED" = -- ]; then
    quota_part="${D}⚡--${X}"
  else
    quota_color=$G
    [ "$QUOTA_USED" -lt 70 ] || quota_color=$Y
    [ "$QUOTA_USED" -lt 90 ] || quota_color=$R
    quota_part="${quota_color}⚡${QUOTA_USED}%${X}"
  fi

  paused_color=$D
  [ "$PAUSED_COUNT" -eq 0 ] || paused_color=$Y
  attention_color=$D
  [ "$ATTENTION_COUNT" -eq 0 ] || attention_color=$R
  fleet_part="${G}🚢${ACTIVE_COUNT}${X} ${paused_color}⏸${PAUSED_COUNT}${X} ${attention_color}⚠${ATTENTION_COUNT}${X}"

  if [ "$age" = -- ]; then
    watch_part="${BR}👁 NO-WATCH --${X}"
  elif [ "$age" -lt 180 ]; then
    watch_part="${G}👁 ${age}s${X}"
  else
    watch_part="${BR}👁 NO-WATCH ${age}s${X}"
  fi

  if [ "$COST" = -- ]; then
    cost_part="${D}\$--${X}"
  else
    cost_part="\$${COST}"
  fi

  if [ -e "$STATE/.afk" ]; then
    afk_part="${C}💤AFK${X}"
  else
    afk_part="${D}💤--${X}"
  fi

  printf '%s%s%s %s%s%s%s%s%s%s%s' \
    "$anchor" "$separator" "$context_part" "$quota_part" \
    "$separator" "$fleet_part" "$separator" "$watch_part" \
    "$separator" "$cost_part" "$separator$afk_part"
}

if [ -n "$FOLLOW_PANE" ]; then
  resolved_pane=
  command -v tmux >/dev/null 2>&1 || exit 0
  # shellcheck disable=SC2329 # Invoked indirectly by the signal and exit traps.
  restore_terminal() {
    printf '\033[?25h\033[?7h'
  }
  trap restore_terminal EXIT HUP INT TERM
  printf '\033[?25l\033[?7l'
  while resolved_pane=$(tmux display-message -p -t "$FOLLOW_PANE" '#{pane_id}' 2>/dev/null) \
    && [ "$resolved_pane" = "$FOLLOW_PANE" ]; do
    printf '\033[H\033[2K'
    render_once
    sleep "${FM_STATUS_BAR_INTERVAL:-1}"
  done
  exit 0
fi

render_once
