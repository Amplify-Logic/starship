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
# The Codex companion supplies its own context and quota figures rather than
# leaving them blank: bin/fm-codex-session-metrics-lib.sh binds to the exact
# primary session behind the followed pane and resolves the account's binding
# quota window. Kimi keeps "--" for both, because no equivalent source has been
# verified for it. That library owns the mechanics, the separation that keeps an
# account-level allowance and a per-session reading from standing in for each
# other, and the caching that keeps a one-second refresh off the provider.
#
# --chrome-pane turns on Herdr chrome mode, which is what reclaims the
# companion's empty rows. The canonical row is ALSO published to the primary
# pane's own border title, where it costs no rows at all, so the companion pane
# can be hidden by zoom while the status stays visible. The in-pane row keeps
# being drawn either way: it is the fallback the captain sees the moment the
# primary is unzoomed, and it means a chrome failure degrades to exactly the
# behavior that shipped before chrome mode existed.
# --chrome-role prefixes that border row with the launcher's compact visible
# role marker (FM, or LAB for a lab primary), so the guarded primary identity
# survives on the border rather than being displaced by the status fields.
# Chrome mode never zooms: bin/fm-primary.sh zooms once at launch, and this
# renderer only ever RELEASES the zoom, when a third pane appears in the tab.
# A deliberate unzoom by the captain is therefore never fought.
# --chrome-zoomed is how the launcher says it ACTUALLY applied that zoom. It is
# the only thing that arms the release watch, so this renderer can never issue
# `pane zoom --off` against a zoom it does not own - the launcher withholds the
# zoom on a crowded tab while still passing --chrome-pane, and without this
# signal the renderer would release a co-tenant's zoom it never applied.
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
QUOTA_WINDOW=
COST=--
ROLE=
FOLLOW_PANE=
FOLLOW_BACKEND=tmux
CHROME_PANE=
CHROME_ROLE=
CHROME_ZOOMED=0

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
    --chrome-pane)
      [ "$#" -ge 2 ] || exit 0
      CHROME_PANE=$2
      shift 2
      ;;
    --chrome-role)
      [ "$#" -ge 2 ] || exit 0
      CHROME_ROLE=$2
      shift 2
      ;;
    --chrome-zoomed)
      CHROME_ZOOMED=1
      shift
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

# A window label is presentation for a metric whose scope must stay exact, so
# it is accepted by a positive rule rather than filtered by a denylist: a short
# alphanumeric token, or several of them joined by "/" when the provider
# reports more than one window binding at the same percentage. Anything else is
# dropped whole, which withholds the quota figure rather than labelling it with
# something unrecognized. The eight-character bound is shared with
# _FM_CODEX_WINDOW_LABEL_MAX in bin/fm-codex-session-metrics-lib.sh, which
# collapses a wider tie to its shortest window rather than overflowing the row.
sanitize_window_label() {
  local value=${1:-}
  case "$value" in
    ''|/*|*/|*//*|*[!A-Za-z0-9/]*) printf '' ;;
    *)
      if [ "${#value}" -le 8 ]; then
        printf '%s' "$value"
      else
        printf ''
      fi
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
#
# This is published ONCE, from the value the launcher passed in, before the
# refresh loop starts. The Codex companion re-reads context every tick for the
# row it draws, and deliberately does not feed those readings here: the context
# axis drives primary rotation, and arming that from a display refresh is a
# separate decision with a live primary on the other end of it.
publish_context_sample() {
  local used=$1
  [ "$used" != -- ] || return 0
  # shellcheck source=bin/fm-primary-handoff-lib.sh
  . "$FM_ROOT/bin/fm-primary-handoff-lib.sh" 2>/dev/null \
    && fm_handoff_write_context_sample "$((100 - used))" 2>/dev/null \
    || true
  return 0
}

publish_context_sample "$CONTEXT_USED"

# The Codex companion resolves its own metrics per refresh, so it loads the
# supplier once here rather than on every tick.
CODEX_METRICS_READY=
if [ "$ADAPTER" = codex ] && [ -n "$FOLLOW_PANE" ]; then
  # shellcheck source=bin/fm-codex-session-metrics-lib.sh
  if . "$FM_ROOT/bin/fm-codex-session-metrics-lib.sh" 2>/dev/null; then
    CODEX_METRICS_READY=1
  fi
fi

# refresh_codex_metrics: re-read the followed session's context and the
# account's binding quota. Both stay "--" unless the supplier could establish
# them, so a failed read renders as unavailable rather than as zero.
refresh_codex_metrics() {
  local reading ctx quota window
  [ "$CODEX_METRICS_READY" = 1 ] || return 0
  reading=$(fm_codex_session_metrics \
    "$FOLLOW_PANE" "$FOLLOW_BACKEND" "${FM_STATUS_HERDR_SESSION:-}" \
    "$STATE" 2>/dev/null) || return 0
  IFS=$'\t' read -r ctx quota window <<EOF
$reading
EOF
  CONTEXT_USED=$(normalize_percent "$ctx")
  QUOTA_USED=$(normalize_percent "$quota")
  QUOTA_WINDOW=
  if [ "$QUOTA_USED" != -- ]; then
    QUOTA_WINDOW=$(sanitize_window_label "$window")
    # A quota figure whose window cannot be named would imply a scope the row
    # does not know, so it is withheld rather than shown bare.
    if [ -z "$QUOTA_WINDOW" ]; then
      QUOTA_USED=--
    fi
  fi
  return 0
}

G=$'\033[92m'
Y=$'\033[93m'
R=$'\033[91m'
C=$'\033[96m'
D=$'\033[2m'
BOLD=$'\033[1m'
BR=$'\033[91;1m'
X=$'\033[0m'

# shellcheck source=bin/fm-fleet-status-lib.sh
. "$FM_ROOT/bin/fm-fleet-status-lib.sh"

# Fleet fields, from bin/fm-fleet-status-lib.sh. This used to count every meta
# file as a running ship and fold each status log's last line into paused and
# attention; both readings turned task RECORDS into apparent live workers. The
# library now folds the canonical current-state reader instead, and reports
# whether it has a usable reading at all.
fleet_counts() {
  local reading
  RECORD_COUNT=0
  WORKING_COUNT=0
  VALIDATING_COUNT=0
  PAUSED_COUNT=0
  ATTENTION_COUNT=0
  FLEET_KNOWN=0
  reading=$(fm_fleet_status_counts "$STATE" 2>/dev/null) || return 0
  IFS=$'\t' read -r RECORD_COUNT WORKING_COUNT VALIDATING_COUNT \
    PAUSED_COUNT ATTENTION_COUNT FLEET_KNOWN <<EOF
$reading
EOF
  case "$RECORD_COUNT" in ''|*[!0-9]*) RECORD_COUNT=0 ;; esac
  case "$FLEET_KNOWN" in 1) ;; *) FLEET_KNOWN=0 ;; esac
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
  local working_color validating_color

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
    # The window is part of the metric, not decoration: the same percentage
    # means something different against a five-hour allowance than against a
    # weekly one, so an adapter that knows its window always names it.
    quota_part="${quota_color}⚡${QUOTA_USED}%${X}"
    [ -z "$QUOTA_WINDOW" ] \
      || quota_part="${quota_color}⚡${QUOTA_USED}%${X}${D}${QUOTA_WINDOW}${X}"
  fi

  # The record count is always exact and always shown, because it is the one
  # fleet number that makes no claim about running workers. The four live fields
  # are a single reading: without one they ALL show the placeholder, because a
  # zero here would assert an idle fleet, which is a real state the captain has
  # to be able to believe.
  if [ "$FLEET_KNOWN" != 1 ]; then
    fleet_part="${D}🚢-- 🧪-- ⏸-- ⚠--${X} ${D}📋${RECORD_COUNT}${X}"
  else
    working_color=$D
    [ "$WORKING_COUNT" -eq 0 ] || working_color=$G
    validating_color=$D
    [ "$VALIDATING_COUNT" -eq 0 ] || validating_color=$C
    paused_color=$D
    [ "$PAUSED_COUNT" -eq 0 ] || paused_color=$Y
    attention_color=$D
    [ "$ATTENTION_COUNT" -eq 0 ] || attention_color=$R
    fleet_part="${working_color}🚢${WORKING_COUNT}${X} ${validating_color}🧪${VALIDATING_COUNT}${X}"
    fleet_part="${fleet_part} ${paused_color}⏸${PAUSED_COUNT}${X} ${attention_color}⚠${ATTENTION_COUNT}${X}"
    fleet_part="${fleet_part} ${D}📋${RECORD_COUNT}${X}"
  fi

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

# Herdr's border title is stored, and silently clipped, at 80 CODEPOINTS, with
# no marker of its own (measured on herdr 0.7.4). Herdr's renderer does truncate
# visibly for a narrow pane - it appends its own ellipsis - so width is Herdr's
# problem, but the 80-codepoint store is ours: a row that arrives longer than
# that loses its rightmost fields with nothing to show it happened.
#
# So whole fields are dropped from the right until the row fits, and a visible
# marker is appended. Clipping on the field separator is deliberate: the row is
# full of multibyte glyphs, and slicing it by offset could split one, whereas a
# separator is located by pattern and always falls on a character boundary. Only
# the final fallback trims, and it trims whole codepoints, never bytes.
#
# The measurement cannot rely on the ambient locale. `${#var}` counts CODEPOINTS
# under a UTF-8 LC_CTYPE and BYTES under C/POSIX, and neither the herdr server
# nor the shell it spawns the companion in is guaranteed to carry a UTF-8
# locale. The row is emoji-heavy, so a byte count runs roughly half again as
# long as the codepoint count and would drop whole fields off a row that fits.
# So the locale is forced to C and the codepoints are counted directly: every
# UTF-8 byte that is not a continuation byte (0x80-0xBF) begins exactly one
# codepoint. That is the same answer on every host.
FM_STATUS_CHROME_LIMIT=${FM_STATUS_CHROME_LIMIT:-80}

chrome_clip() {  # <text> -> text that fits the border-title store
  # LC_ALL is local, so bash's byte-wise view lasts only for this call. Every
  # pattern below is a fixed byte sequence, so matching and stripping them
  # bytewise is exact.
  local LC_ALL=C text=$1 limit=$FM_STATUS_CHROME_LIMIT lead
  lead=${text//[$'\200'-$'\277']/}
  # A row that already fits is published byte-for-byte, with no marker.
  if [ "${#lead}" -le "$limit" ]; then
    printf '%s' "$text"
    return
  fi
  # Room for the two-codepoint marker has to survive the clip.
  while [ "$((${#lead} + 2))" -gt "$limit" ]; do
    case "$text" in
      *' │ '*) text=${text% │ *} ;;
      *) break ;;
    esac
    lead=${text//[$'\200'-$'\277']/}
  done
  # Nothing separable left and still over: trim the tail one CODEPOINT at a
  # time rather than emit a row the server would clip without a marker. Bytes
  # are dropped until a non-continuation byte goes with them, so a trim can
  # never leave half a glyph behind.
  while [ -n "$text" ] && [ "$((${#lead} + 2))" -gt "$limit" ]; do
    while [ -n "$text" ]; do
      case "${text: -1}" in
        [$'\200'-$'\277']) text=${text%?} ;;
        *) text=${text%?}; break ;;
      esac
    done
    lead=${text//[$'\200'-$'\277']/}
  done
  printf '%s …' "$text"
}

# chrome_row_from_frame: the canonical row as PLAIN text for the border title,
# with the launcher's visible role marker leading it.
#
# It reuses the frame already collected for the pane instead of rendering a
# second time. That halves the per-refresh work, and more importantly it
# guarantees the border and the in-pane fallback show the same sample rather
# than two reads taken a few milliseconds apart.
#
# Stripping runs under LC_ALL=C on purpose: an ANSI sequence is pure ASCII, so
# removing it bytewise can never touch the row's multibyte glyphs.
chrome_row_from_frame() {  # <styled frame>
  local row
  row=$(printf '%s' "$1" | LC_ALL=C sed 's/'$'\033''\[[0-9;]*m//g')
  [ -z "$CHROME_ROLE" ] || row="$CHROME_ROLE │ $row"
  chrome_clip "$row"
}

# chrome_publish: push the row onto the primary pane's own border title.
#
# The source is deliberately NOT bin/fm-primary.sh's firstmate-primary-visible-v1.
# Herdr REPLACES a source's whole metadata record on every report-metadata call
# (measured), so publishing under that source would wipe the primary's own
# display-agent and supervision state labels on the very first refresh. A
# separate source only ever contributes this title, and the launcher's record
# keeps resolving untouched.
#
# --ttl-ms is what keeps the border honest: if this renderer dies, the row
# expires instead of freezing a stale fleet count on the captain's border.
FM_STATUS_CHROME_SOURCE=firstmate-primary-status-v1

chrome_publish() {  # <row>
  local ttl
  ttl=$(( ${FM_STATUS_BAR_INTERVAL:-1} * 2500 ))
  [ "$ttl" -ge 1000 ] || ttl=1000
  herdr --session "$FM_STATUS_HERDR_SESSION" pane report-metadata "$CHROME_PANE" \
    --source "$FM_STATUS_CHROME_SOURCE" \
    --title "$1" \
    --ttl-ms "$ttl" >/dev/null 2>&1
}

# chrome_release_zoom_if_crowded: give the reclaimed rows back rather than hide
# a co-tenant pane.
#
# Only ever reached when the launcher reported --chrome-zoomed, so the zoom
# being released is one bin/fm-primary.sh applied itself, at launch, when
# exactly the primary and its companion shared the tab. If anything later
# splits that tab, the zoom would hide the new pane, so the zoom is released.
# This only ever releases: it never zooms, so a captain who deliberately
# unzooms is not fought once a second, and once released the check stops
# running for good.
chrome_release_zoom_if_crowded() {
  local panes
  panes=$(herdr --session "$FM_STATUS_HERDR_SESSION" pane layout --pane "$CHROME_PANE" 2>/dev/null \
    | jq -r '.result.layout.panes | length' 2>/dev/null)
  case "$panes" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ "$panes" -gt 2 ] || return 0
  herdr --session "$FM_STATUS_HERDR_SESSION" pane zoom "$CHROME_PANE" --off >/dev/null 2>&1
  CHROME_ZOOM_WATCH=0
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
  # Chrome mode is herdr-only, and it decorates a pane that must not be the
  # companion this renderer is drawing into. Anything else turns it off and
  # leaves the in-pane row as the only surface, which is the pre-chrome
  # behavior rather than a failure.
  if [ -n "$CHROME_PANE" ]; then
    if [ "$FOLLOW_BACKEND" != herdr ] || [ "$CHROME_PANE" = "$FOLLOW_PANE" ]; then
      CHROME_PANE=
    fi
  fi
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
  chrome_tick=0
  # Armed ONLY when the launcher reported that it applied the zoom itself, so
  # this renderer never releases a zoom it does not own. The release path
  # clears it permanently.
  CHROME_ZOOM_WATCH=$CHROME_ZOOMED
  while companion_pane_alive; do
    # Collect the complete frame before any of it reaches the pane, then publish
    # the row erase and the finished frame in a single write. Erasing first left
    # the row visibly blank for the whole length of the collection, which is what
    # made the companion appear to flicker once a second on a fleet large enough
    # for the per-task collection to take a noticeable fraction of the interval.
    # The erase still leads the frame, so a shorter row's stale tail is clipped.
    # The refresh runs HERE rather than inside render_once, because the frame
    # is collected in a command substitution: a subshell's assignments are
    # discarded, so a refresh that remembers anything between ticks - the last
    # published context sample, this tick's reading - has to run in the loop's
    # own shell. It still runs before any of the frame reaches the pane.
    refresh_codex_metrics
    # Deliberately NOT published to the primary-handoff context sample. That
    # file is the handoff supervisor's CONTEXT axis: a home that enables the
    # axis rotates its live primary once the sample crosses the threshold. The
    # Codex adapter's context was always unavailable before this work, so it
    # never fed that axis, and starting to feed it here would arm a live-primary
    # rotation path as a side effect of a display change. Showing the figure and
    # driving a lifecycle decision with it are separate decisions, and only the
    # first one was asked for. docs/status-bar.md records the boundary.
    frame=$(render_once)
    printf '\033[H\033[2K%s' "$frame"
    if [ -n "$CHROME_PANE" ]; then
      # The border row is published after the pane row, so a slow or failing
      # herdr call can never delay the fallback surface.
      chrome_publish "$(chrome_row_from_frame "$frame")"
      # The co-tenant check is a layout read, not a per-refresh need, so it runs
      # on a slow cadence and stops for good once the zoom has been released.
      chrome_tick=$((chrome_tick + 1))
      if [ "$CHROME_ZOOM_WATCH" = 1 ] \
        && [ "$((chrome_tick % ${FM_STATUS_CHROME_ZOOM_EVERY:-5}))" -eq 0 ]; then
        chrome_release_zoom_if_crowded
      fi
    fi
    sleep "${FM_STATUS_BAR_INTERVAL:-1}"
  done
  exit 0
fi

render_once
