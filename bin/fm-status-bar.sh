#!/usr/bin/env bash
# Render the canonical Firstmate primary status bar.
#
# Usage:
#   fm-status-bar.sh --adapter claude
#   fm-status-bar.sh --adapter pi --model MODEL --effort LEVEL \
#     --context-used PERCENT --quota-used PERCENT --cost USD
#   fm-status-bar.sh --adapter kimi --model MODEL --effort LEVEL \
#     --follow-pane PANE [--follow-backend tmux|herdr]
#
# Claude mode reads the native statusLine JSON payload from stdin.
# Cursor mode reads Cursor CLI's native statusLine JSON payload from stdin.
# Pi supplies its native footer metrics as normalized arguments.
# Kimi and Codex use --follow-pane for a companion row because neither exposes
# a third-party status-bar API that can carry Firstmate's fleet fields.
# --follow-backend selects the session provider that owns the companion pane:
# tmux (default) or herdr. Herdr panes are addressed by HERDR_PANE_ID.
#
# --role renders a compact account role beside the model. It is only ever a
# verified label supplied by the launcher: --role, else FM_PRIMARY_ACCOUNT_ROLE
# (which bin/fm-primary.sh sets for its companion panes), else the account
# owner's own FM_ACCOUNT_NAME, which is what reaches the native Claude, Pi and
# Cursor surfaces. This renderer only CONSUMES that resolution; bin/fm-account-*
# owns it. An unknown account renders no label at all rather than a guess, and
# an ID or email is never rendered.
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
CONTEXT_USED=--
QUOTA_USED=--
COST=--
ROLE=
FOLLOW_PANE=
FOLLOW_BACKEND=tmux

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
    --context-used)
      [ "$#" -ge 2 ] || exit 0
      CONTEXT_USED=$2
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
    --role)
      [ "$#" -ge 2 ] || exit 0
      ROLE=$2
      shift 2
      ;;
    --follow-pane)
      [ "$#" -ge 2 ] || exit 0
      FOLLOW_PANE=$2
      shift 2
      ;;
    --follow-backend)
      [ "$#" -ge 2 ] || exit 0
      FOLLOW_BACKEND=$2
      shift 2
      ;;
    *)
      exit 0
      ;;
  esac
done

case "$ADAPTER" in
  claude|pi|kimi|codex|cursor) ;;
  *) exit 0 ;;
esac
case "$FOLLOW_BACKEND" in
  tmux|herdr) ;;
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

if [ "$ADAPTER" = cursor ]; then
  # Cursor CLI 2026.09.08 statusLine command payload. It exposes model and
  # context use but no provider quota and no session cost, so both stay unknown.
  input=$(cat 2>/dev/null || printf '')
  if command -v jq >/dev/null 2>&1; then
    IFS=$'\t' read -r MODEL EFFORT CONTEXT_USED <<EOF
$(printf '%s' "$input" | jq -r '
  [
    (.model.display_name // .model.id // "--" | tostring),
    (.model.param_summary // "--" | tostring),
    (if (.context_window.used_percentage | type) == "number"
      then (.context_window.used_percentage | floor)
      elif (.context_window.remaining_percentage | type) == "number"
      then ((100 - (.context_window.remaining_percentage | floor)) |
        if . < 0 then 0 elif . > 100 then 100 else . end)
      else "--"
      end)
  ] | @tsv
' 2>/dev/null)
EOF
  fi
fi

if [ "$ADAPTER" = claude ]; then
  input=$(cat 2>/dev/null || printf '')
  if command -v jq >/dev/null 2>&1; then
    IFS=$'\t' read -r MODEL EFFORT CONTEXT_USED QUOTA_USED COST <<EOF
$(printf '%s' "$input" | jq -r '
  [
    (.model.display_name // .model.id // "--" | tostring),
    (.effort.level // "--" | tostring),
    (if (.context_window.used_percentage | type) == "number"
      then (.context_window.used_percentage | floor)
      elif (.context_window.remaining_percentage | type) == "number"
      then ((100 - (.context_window.remaining_percentage | floor)) |
        if . < 0 then 0 elif . > 100 then 100 else . end)
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
CONTEXT_USED=$(normalize_percent "$CONTEXT_USED")
QUOTA_USED=$(normalize_percent "$QUOTA_USED")
COST=$(normalize_cost "$COST")

# A role label is optional presentation. It is rendered only when the launcher
# supplied a verified one; an unknown account stays silent instead of guessing.
# Only a short, entirely alphabetic role word is accepted. Everything else -
# a bare numeric id, a UUID or any prefix of one, punctuation, spaces, or an
# over-long value - is dropped rather than shortened, so no ID or email, and no
# truncated fragment of one, can reach the status row.
[ -n "$ROLE" ] || ROLE=${FM_PRIMARY_ACCOUNT_ROLE:-${FM_ACCOUNT_NAME:-}}
if [ -n "$ROLE" ]; then
  ROLE=$(sanitize_label "$ROLE")
  case "$ROLE" in
    *[!A-Za-z]*) ROLE= ;;
    *) [ "${#ROLE}" -le 12 ] || ROLE= ;;
  esac
fi

# Persist a context sample for the primary-handoff supervisor (context axis).
# Display shows used %; the sample API still takes remaining and derives used.
# Best-effort: never fail the status-bar render.
if [ "$CONTEXT_USED" != -- ]; then
  context_remaining=$((100 - CONTEXT_USED))
  # shellcheck source=bin/fm-primary-handoff-lib.sh
  . "$FM_ROOT/bin/fm-primary-handoff-lib.sh" 2>/dev/null \
    && fm_handoff_write_context_sample "$context_remaining" 2>/dev/null \
    || true
fi

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
  [ -z "$ROLE" ] || anchor="${anchor} ${D}[${ROLE}]${X}"

  if [ "$CONTEXT_USED" = -- ]; then
    context_part="${D}🧠--${X}"
  else
    # Used thresholds invert the prior remaining bands: green while low,
    # yellow above 70% used (was under 30% remaining), red above 85% used
    # (was under 15% remaining).
    context_color=$G
    [ "$CONTEXT_USED" -le 70 ] || context_color=$Y
    [ "$CONTEXT_USED" -le 85 ] || context_color=$R
    context_part="${context_color}🧠${CONTEXT_USED}%${X}"
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

# companion_pane_alive: one cheap liveness read of the pane this companion is
# attached to, for whichever session provider owns it. Both arms compare the
# resolved id against the requested one so a provider that answers about a
# DIFFERENT pane (or answers with nothing) is treated as gone rather than live.
companion_pane_alive() {
  local resolved
  case "$FOLLOW_BACKEND" in
    tmux)
      resolved=$(tmux display-message -p -t "$FOLLOW_PANE" '#{pane_id}' 2>/dev/null) || return 1
      ;;
    herdr)
      resolved=$(herdr --session "$FM_STATUS_HERDR_SESSION" pane get "$FOLLOW_PANE" 2>/dev/null \
        | jq -r '.result.pane.pane_id // empty' 2>/dev/null) || return 1
      ;;
    *) return 1 ;;
  esac
  [ "$resolved" = "$FOLLOW_PANE" ]
}

if [ -n "$FOLLOW_PANE" ]; then
  case "$FOLLOW_BACKEND" in
    tmux) command -v tmux >/dev/null 2>&1 || exit 0 ;;
    herdr)
      command -v herdr >/dev/null 2>&1 || exit 0
      command -v jq >/dev/null 2>&1 || exit 0
      # Herdr panes are addressed within a session; fail closed rather than
      # letting an unscoped call resolve against another session's pane.
      FM_STATUS_HERDR_SESSION=${FM_STATUS_HERDR_SESSION:-${HERDR_SESSION:-default}}
      [ -n "$FM_STATUS_HERDR_SESSION" ] || exit 0
      ;;
  esac
  # shellcheck disable=SC2329 # Invoked indirectly by the signal and exit traps.
  restore_terminal() {
    printf '\033[?25h\033[?7h'
  }
  trap restore_terminal EXIT HUP INT TERM
  # Autowrap off keeps the canonical line clipped to one row on a narrow
  # companion instead of spilling onto the pane's second row.
  # The one-time full clear removes whatever the provider left in the pane
  # before this process took it over - herdr's `pane run` echoes the launch
  # command into the pane's shell, and that line would otherwise sit below the
  # status row for the life of the companion.
  printf '\033[?25l\033[?7l\033[2J'
  while companion_pane_alive; do
    # Collect the complete frame before any of it reaches the pane, then publish
    # the row erase and the finished frame in a single write. Erasing first left
    # the row visibly blank for the whole length of the collection, which is what
    # made the companion appear to flicker once a second on a fleet large enough
    # for the per-task collection to take a noticeable fraction of the interval.
    # The erase still leads the frame, so a shorter row's stale tail is clipped.
    frame=$(render_once)
    printf '\033[H\033[2K%s' "$frame"
    sleep "${FM_STATUS_BAR_INTERVAL:-1}"
  done
  exit 0
fi

render_once
