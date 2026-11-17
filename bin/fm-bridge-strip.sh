#!/usr/bin/env bash
# fm-bridge-strip.sh - the Starship bridge: a slim strip across the top of a
# Herdr workspace with the STARSHIP wordmark, the crew's lamps, the owner's most
# urgent call, a red alert, the night shift and the battery.
#
# It is a Herdr plugin pane (herdr-plugins/starship-bridge/). The strip only
# READS: the crew lamps, the most urgent call, the alert and the night shift's
# count come from bin/fm-fleet-status-lib.sh, the same cached reading the
# primary status bar shows, the night shift's hours from the home's
# config/night-shift-window, a Mothership room this Mac cannot reach from the
# notes the room's listener keeps (bin/fm-procevent-mothership.sh,
# state/mothership/<room>.unreachable), and the battery from `pmset -g batt` on
# a Mac. It never steers, changes or drains anything; its one action is that a click on
# the most urgent call opens the Factory pane on it (bin/fm-factory-pane.sh open
# --item, beside the pane below the strip). docs/bridge-strip.md owns what the
# strip shows and why; this header owns the commands.
#
# Usage:
#   fm-bridge-strip.sh install   link the plugin into Herdr, remember this home,
#                                and, when run inside a Herdr pane, show the
#                                strip above that pane
#   fm-bridge-strip.sh remove    stop every running strip (its pane closes with
#                                it) and unlink the plugin
#   fm-bridge-strip.sh open [--pane ID]
#                                show the strip above a pane (default: the pane
#                                this runs in, or the focused pane when Herdr
#                                runs it as the plugin's action)
#   fm-bridge-strip.sh run       the pane's own loop, redrawn every 5 seconds,
#                                and within a second of the owner's calls
#                                changing; Herdr starts it. On a terminal it
#                                asks for mouse reports and reads the clicks.
#   fm-bridge-strip.sh render [--width N] [--height N]
#                                print one frame and exit
#
# Staying current: a running loop keeps the code it started with in memory, so
# an update would otherwise leave it reading the crew with yesterday's code.
# Before each frame `run` takes a checksum of this script and every library it
# sources, and when that changes and the new files are non-empty and parse, it
# re-executes itself in place: the same process and pane, the new code. Until a
# first reading arrives the strip says `reading the crew`; when none arrives
# within one bounded refresh, or a reading it had is lost, it says
# `cannot read the crew (since HH:MM)`. `render` prints one frame with no
# history, so it only ever says `reading the crew`.
#
# Placement: Herdr splits a pane only right or down, so `open` splits the
# target pane down, swaps the two panes (a swap trades places and keeps the
# cells, so the strip moves into the top cell), then shrinks the top cell to
# Herdr's smallest split share, a tenth of the pane, and hands keyboard focus
# back to the pane below (the swap gives it to the strip). Every step names the exact
# panes involved; a step that fails stops there and says which.
#
# `remove` finds running strips only through the records each one keeps in the
# plugin's Herdr config directory, and stops a recorded process only after
# checking it is still this renderer, so it can never close someone else's pane.
#
# Environment:
#   FM_HOME                       the home whose crew is shown. Unset, the home
#                                 `install` recorded is used, else this code root.
#   HERDR_BIN_PATH                the Herdr binary (default: herdr on PATH)
# Test seams:
#   FM_BRIDGE_STRIP_PMSET         battery reader run as `<cmd> -g batt`; empty
#                                 for no battery (default: pmset on a Mac only)
#   FM_BRIDGE_STRIP_CONFIG_DIR    the plugin's config directory, instead of
#                                 asking Herdr
#   FM_FLEET_STATE_*              see bin/fm-fleet-status-lib.sh; its
#                                 FM_FLEET_STATE_NOW also sets the night
#                                 shift's clock
# Exit: 0 on success; 1 when a step fails, with the reason on stderr; 2 on a
# usage error.
set -u

SCRIPT_DIR=$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(CDPATH='' cd -P -- "$SCRIPT_DIR/.." && pwd -P)
PLUGIN_ID=starship.bridge
PLUGIN_DIR="$ROOT/herdr-plugins/starship-bridge"
ME=fm-bridge-strip.sh

# shellcheck source=bin/fm-fleet-status-lib.sh
. "$SCRIPT_DIR/fm-fleet-status-lib.sh"

# The code a running loop holds in memory: this script and every library it
# sources, the fleet library's own three included. code_changed watches them.
SELF="$SCRIPT_DIR/${BASH_SOURCE[0]##*/}"
CODE_FILES=("$SELF" "$SCRIPT_DIR/fm-fleet-status-lib.sh" "$SCRIPT_DIR/fm-status-cache-lib.sh"
  "$SCRIPT_DIR/fm-timeout-lib.sh" "$SCRIPT_DIR/fm-owner-calls-signal-lib.sh")

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() { printf '%s: %s\n' "$ME" "$*" >&2; exit 1; }

herdr_bin() { printf '%s' "${HERDR_BIN_PATH:-herdr}"; }

# --- flight deck colours ------------------------------------------------------
# The brand's tokens as truecolour escapes. A colour only ever says one thing:
# cyan is the ship, amber is work not done yet, green is done, red needs you.

E=$'\033'
fg() { printf '%s[38;2;%sm' "$E" "$1"; }
HULL_BG="${E}[48;2;13;21;36m"
ICE=$(fg '232;238;247')
MIST=$(fg '163;180;203')
FAINT=$(fg '107;127;156')
LAMP_OFF=$(fg '61;82;115')
CYAN=$(fg '116;215;234')
AMBER=$(fg '255;182;72')
GREEN=$(fg '98;221;154')
RED=$(fg '255;122;107')
BOLD="${E}[1m"
UNBOLD="${E}[22m"
RESET="${E}[0m"
LAMP=$'\342\226\240'   # U+25A0, the brand's small flat square
RULE=$'\342\224\202'   # U+2502, a thin divider
POINTER=$'\342\226\270'   # U+25B8, the pointer before the most urgent call

# Each piece is built into SEG (styled text) and SEG_W (columns it takes).
# Widths are counted, never measured from bytes: every word is ASCII and each
# glyph above is one column.
SEG=
SEG_W=0

# --- the wordmark -------------------------------------------------------------

wordmark() {  # spaced|compact|none
  case "$1" in
    spaced) SEG="${BOLD}${CYAN}S T A R S H I P${UNBOLD}"; SEG_W=15 ;;
    compact) SEG="${BOLD}${CYAN}STARSHIP${UNBOLD}"; SEG_W=8 ;;
    *) SEG=; SEG_W=0 ;;
  esac
}

# --- the crew -----------------------------------------------------------------

READING_KNOWN=0
CANNOT_READ_SINCE=
BUSY=0
FOR_YOU=0
TO_MERGE=0
READING_AGE=0
STOPPED=0
FAILED=-
NIGHT_DONE=-
CALL_KIND=-
CALL_ID=
CALL_TITLE=
CALLS_SIGNAL=-

# read_crew: the fleet reading, folded into the three lamps the strip shows,
# plus the red alert, the most urgent call and the night shift's count, which
# the same fold takes (fm_fleet_status_counts `overview`, the reading the
# status bar and the Factory pane's count line show too) so they never disagree
# with the lamps; docs/status-bar.md "Fleet words" owns the words.
# Busy is a worker typing plus work the validation pipeline is carrying. The
# other two lamps are the owner's calls (fm_owner_calls, the same count the
# Factory pane and the tap page show): decisions for you are his live held
# decisions, and ready to merge is the rest, a PR or branch ready to land.
# CALLS_SIGNAL is the owner's calls signal those calls were read under, which
# the wait between frames watches.
read_crew() {  # <home>
  local reading records working stopped validating paused attention ready
  local known age decisions failed lost night kind id title calls _ready_list
  READING_KNOWN=0
  FAILED=-
  NIGHT_DONE=-
  CALL_KIND=-
  CALLS_SIGNAL=-
  reading=$(fm_fleet_status_counts "$1/state" overview 2>/dev/null) || return 0
  IFS=$'\t' read -r records working stopped validating paused attention ready \
    known age decisions failed lost night kind id title calls _ready_list <<EOF
$reading
EOF
  CALLS_SIGNAL=${calls:--}
  case "$working$stopped$validating$ready$known$age$decisions" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ "$decisions" -le "$ready" ] || return 0
  READING_KNOWN=$known
  READING_AGE=$age
  BUSY=$((working + validating))
  FOR_YOU=$decisions
  TO_MERGE=$((ready - decisions))
  [ "$known" != 0 ] || return 0
  # Without the strip's own readings the alert, the call and the night count
  # stay off rather than guessed.
  case "$failed$lost" in ''|*[!0-9]*) return 0 ;; esac
  STOPPED=$lost
  FAILED=$failed
  NIGHT_DONE=${night:--}
  case "$kind" in
    decision|merge)
      [ -z "$id" ] || [ "$id" = - ] || [ -z "$title" ] || {
        CALL_KIND=$kind
        CALL_ID=$id
        CALL_TITLE=$title
      }
      ;;
  esac
}

age_words() {  # <seconds>
  if [ "$1" -lt 60 ]; then
    printf 'a moment ago'
  elif [ "$1" -lt 3600 ]; then
    printf '%sm ago' "$(($1 / 60))"
  else
    printf '%sh ago' "$(($1 / 3600))"
  fi
}

lamp() {  # <count> <colour> <words>; appends to SEG/SEG_W
  local text="$1${3:+ $3}"
  if [ "$1" -gt 0 ]; then
    SEG="${SEG}${2}${LAMP} ${ICE}${text}"
  else
    SEG="${SEG}${LAMP_OFF}${LAMP} ${FAINT}${text}"
  fi
  SEG_W=$((SEG_W + 2 + ${#text}))
}

gap() {  # <columns>; appends plain spaces
  SEG="${SEG}$(printf '%*s' "$1" '')"
  SEG_W=$((SEG_W + $1))
}

crew() {  # long|short|numbers|none
  local mode=$1 sep busy_w you_w merge_w note decisions=decisions
  SEG=
  SEG_W=0
  [ "$mode" = none ] && return 0
  if [ "$READING_KNOWN" = 0 ] && [ -n "$CANNOT_READ_SINCE" ]; then
    case "$mode" in
      long) note="cannot read the crew (since $CANNOT_READ_SINCE)" ;;
      *) note='cannot read' ;;
    esac
    SEG="${MIST}${note}"
    SEG_W=${#note}
    return 0
  fi
  if [ "$READING_KNOWN" = 0 ]; then
    case "$mode" in
      long) note='reading the crew' ;;
      *) note='reading' ;;
    esac
    SEG="${FAINT}${note}"
    SEG_W=${#note}
    return 0
  fi
  [ "$FOR_YOU" != 1 ] || decisions=decision
  case "$mode" in
    long) sep=3; busy_w='busy'; you_w="$decisions for you"; merge_w='ready to merge' ;;
    short) sep=2; busy_w='busy'; you_w=$decisions; merge_w='to merge' ;;
    *) sep=1; busy_w=; you_w=; merge_w= ;;
  esac
  lamp "$BUSY" "$AMBER" "$busy_w"
  gap "$sep"
  lamp "$FOR_YOU" "$RED" "$you_w"
  gap "$sep"
  lamp "$TO_MERGE" "$GREEN" "$merge_w"
  if [ "$READING_KNOWN" = 2 ] && [ "$mode" != numbers ]; then
    note="($(age_words "$READING_AGE"))"
    SEG="${SEG} ${FAINT}${note}"
    SEG_W=$((SEG_W + 1 + ${#note}))
  fi
}

# --- the battery --------------------------------------------------------------

BATTERY=0
BAT_PCT=
BAT_ON_BATTERY=0
BAT_STATE=
BAT_LEFT=

# read_battery: one `pmset -g batt` reading. A machine with no internal battery,
# a machine that is not a Mac, or an answer that cannot be read leaves the
# battery off the strip rather than guessing.
read_battery() {
  local cmd out line rest
  BATTERY=0
  if [ "${FM_BRIDGE_STRIP_PMSET+set}" = set ]; then
    cmd=$FM_BRIDGE_STRIP_PMSET
  else
    cmd=
    [ "$(uname -s 2>/dev/null)" = Darwin ] && command -v pmset >/dev/null 2>&1 && cmd=pmset
  fi
  [ -n "$cmd" ] || return 0
  out=$("$cmd" -g batt 2>/dev/null) || return 0
  line=$(printf '%s\n' "$out" | grep -m1 'InternalBattery') || return 0
  rest=${line#*$'\t'}
  BAT_PCT=$(printf '%s' "$rest" | sed -n 's/^ *\([0-9][0-9]*\)%.*/\1/p')
  case "$BAT_PCT" in ''|*[!0-9]*) return 0 ;; esac
  case "$out" in
    *"'Battery Power'"*) BAT_ON_BATTERY=1 ;;
    *) BAT_ON_BATTERY=0 ;;
  esac
  BAT_STATE=$(printf '%s' "$rest" | awk -F';' '{ gsub(/^ +| +$/, "", $2); print $2 }')
  BAT_LEFT=$(printf '%s' "$rest" | sed -n 's/.*; \([0-9][0-9]*:[0-9][0-9]\) remaining.*/\1/p')
  [ "$BAT_LEFT" != 0:00 ] || BAT_LEFT=
  BATTERY=1
}

# battery_colour: red below 10% and amber below 25%, only while on battery.
battery_colour() {
  if [ "$BAT_ON_BATTERY" = 1 ] && [ "$BAT_PCT" -lt 10 ]; then
    printf '%s' "$RED"
  elif [ "$BAT_ON_BATTERY" = 1 ] && [ "$BAT_PCT" -lt 25 ]; then
    printf '%s' "$AMBER"
  fi
}

battery_warns() { [ -n "$(battery_colour)" ]; }

battery() {  # full|mid|short|none
  local colour detail text
  SEG=
  SEG_W=0
  [ "$BATTERY" = 1 ] && [ "$1" != none ] || return 0
  colour=$(battery_colour)
  detail=
  if [ "$BAT_ON_BATTERY" = 1 ]; then
    if [ "$BAT_PCT" -lt 10 ]; then
      detail='plug in now'
    elif [ -n "$BAT_LEFT" ]; then
      detail="$BAT_LEFT left"
    fi
  else
    case "$BAT_STATE" in
      charging) detail='charging' ;;
      charged) detail='full' ;;
      *) detail='plugged in' ;;
    esac
  fi
  case "$1" in
    full) text="battery $BAT_PCT%${detail:+, $detail}" ;;
    mid) text="battery $BAT_PCT%" ;;
    *) text="$BAT_PCT%" ;;
  esac
  if [ -n "$colour" ]; then
    SEG="${colour}${LAMP} ${text}"
    SEG_W=$((2 + ${#text}))
  else
    SEG="${MIST}${text}"
    SEG_W=${#text}
  fi
}

# --- the red alert ------------------------------------------------------------

# A Mothership room this Mac cannot reach, in long and short words, or empty.
REACH_LONG=
REACH_SHORT=
# A room is called unreachable once its listener has failed to reach it for
# REACH_AFTER seconds, and only while the listener's latest failed read is at
# most REACH_FRESH seconds old, so a listener that stopped trying leaves no
# alert behind.
REACH_AFTER=120
REACH_FRESH=180

# read_reach: the rooms the home's Mothership listener could not reach. Any
# room cut off by Tailscale says so, since that is the one cause the owner can
# fix on this Mac; otherwise the first room not answering is named.
read_reach() {  # <home>
  local now file key value since last cause name
  REACH_LONG=
  REACH_SHORT=
  now=$(_fm_fleet_now) || return 0
  for file in "$1"/state/mothership/*.unreachable; do
    [ -f "$file" ] || continue
    since='' last='' cause=''
    while IFS='=' read -r key value; do
      case "$key" in
        since) since=$value ;;
        last) last=$value ;;
        cause) cause=$value ;;
      esac
    done < "$file"
    case "$since" in ''|*[!0-9]*) continue ;; esac
    case "$last" in ''|*[!0-9]*) continue ;; esac
    [ $((now - since)) -ge "$REACH_AFTER" ] && [ $((now - last)) -le "$REACH_FRESH" ] || continue
    case "$cause" in
      tailscale)
        REACH_LONG='Tailscale is off on this Mac'
        REACH_SHORT='Tailscale off'
        return 0
        ;;
      room)
        [ -z "$REACH_LONG" ] || continue
        name=${file##*/}
        name=${name%.unreachable}
        REACH_LONG="The $name room is not answering"
        REACH_SHORT='room not answering'
        ;;
    esac
  done
}

# alert: something broke, so trouble shows without the owner looking for it: a
# worker whose endpoint is gone (the reading's lost: stopped, but not failed)
# or work that failed, a worker's failure or a failed validation run (the
# reading's failed), so each broken task counts once; and a Mothership room
# this Mac cannot reach (read_reach). It clears when none of them holds.
alert_text() {  # long|short
  local text='' total=0
  case "$FAILED" in ''|*[!0-9]*) ;; *) total=$((FAILED + STOPPED)) ;; esac
  if [ "$1" = long ]; then
    if [ "$total" -gt 0 ]; then
      [ "$FAILED" -eq 0 ] || text="$FAILED failed"
      [ "$STOPPED" -eq 0 ] || text="${text:+$text, }$STOPPED stopped"
    fi
    [ -z "$REACH_LONG" ] || text="${text:+$text, }$REACH_LONG"
  else
    [ "$total" -eq 0 ] || text="$total broken"
    [ -z "$REACH_SHORT" ] || text="${text:+$text, }$REACH_SHORT"
  fi
  printf '%s' "$text"
}

alert() {  # long|short
  local text
  SEG=
  SEG_W=0
  text=$(alert_text "$1")
  [ -n "$text" ] || return 0
  SEG="${RED}${LAMP} ${text}"
  SEG_W=$((2 + ${#text}))
}

alert_shows() { [ -n "$(alert_text short)" ]; }

# --- the most urgent call -----------------------------------------------------

# call_label: the owner's most urgent call by name, the first of his calls
# (fm_owner_calls orders his held decisions before work ready to merge).
call_label() {
  if [ -n "$NOTICE" ] && [ "$(date +%s)" -lt "$NOTICE_UNTIL" ]; then
    printf '%s' "$NOTICE"
    return 0
  fi
  NOTICE=
  case "$CALL_KIND" in
    merge) printf 'Merge: %s' "$CALL_TITLE" ;;
    decision) printf 'Decide: %s' "$CALL_TITLE" ;;
  esac
}

# --- the night shift ----------------------------------------------------------

NIGHT_TEXT=
NIGHT_COLOUR=

# read_night: the night shift's line for this minute from the home's window
# (fm_night_shift_window): when it starts in the evening, that it is on, and in
# the morning how much finished in it, from the reading's count of the window
# that ended last. A home with no window shows none, and neither does a morning
# whose reading does not yet cover the window that just ended, or one in which
# nothing was counted.
read_night() {  # <home>
  local now window phase start _last_start last_end count end
  NIGHT_TEXT=
  now=$(_fm_fleet_now) || return 0
  window=$(fm_night_shift_window "$1/config/night-shift-window" "$now") || return 0
  IFS=$'\t' read -r phase start _last_start last_end <<EOF
$window
EOF
  case "$phase" in
    evening) NIGHT_TEXT="night shift from $start"; NIGHT_COLOUR=$MIST ;;
    on) NIGHT_TEXT='night shift on'; NIGHT_COLOUR=$MIST ;;
    morning)
      count=${NIGHT_DONE%@*}
      end=${NIGHT_DONE#*@}
      case "$count" in ''|*[!0-9]*) return 0 ;; esac
      [ "$end" = "$last_end" ] && [ "$count" -gt 0 ] || return 0
      NIGHT_TEXT="$count done overnight"
      NIGHT_COLOUR=$GREEN
      ;;
  esac
}

# --- composing a row ----------------------------------------------------------

# The tiers a row tries, widest first. Each names the wordmark, the crew and the
# battery form. Words go before lamps, and on a very narrow pane the lamps go
# before the wordmark. A low battery and the red alert are never dropped while
# anything else is shown, because each can need the owner within minutes; the
# alert takes its long words beside the long crew and `N broken` otherwise.
# The most urgent call and the night shift only ever take the columns the
# chosen tier leaves over, the call first, so they never change which tier a
# pane gets.
TIERS='spaced long full
spaced long mid
compact long mid
compact short mid
compact short short
compact numbers short
none numbers short
none numbers none
compact none none
none none short'

ROW=
# The columns, counted from 1, that the most urgent call takes on the content
# row, or 0 when it is not shown; a click there opens the Factory pane on it.
LINK_FROM=0
LINK_TO=0
# The shortest a call's name is cut to before it is left out.
CALL_MIN=12

# row_need: the columns a row of these widths takes, with one column of margin
# each side and three between the left and right sides when both are there.
row_need() {  # <left width> <right width>
  local gap=0
  [ "$1" -eq 0 ] || [ "$2" -eq 0 ] || gap=3
  printf '%s' $((2 + $1 + $2 + gap))
}

compose() {  # <width>
  local width=$1 mark_form crew_form bat_form mark mark_w crew_s crew_w bat bat_w
  local alert_s alert_w left left_w right right_w text rest label sep room cut
  local night_s night_w clickable
  LINK_FROM=0
  LINK_TO=0
  while read -r mark_form crew_form bat_form; do
    if [ "$bat_form" = none ] && battery_warns; then
      continue
    fi
    wordmark "$mark_form"; mark=$SEG; mark_w=$SEG_W
    crew "$crew_form"; crew_s=$SEG; crew_w=$SEG_W
    battery "$bat_form"; bat=$SEG; bat_w=$SEG_W
    if [ "$crew_form" = long ]; then alert long; else alert short; fi
    alert_s=$SEG; alert_w=$SEG_W
    left=$mark; left_w=$mark_w
    if [ "$mark_w" -gt 0 ] && [ "$crew_w" -gt 0 ]; then
      left="${left}  ${FAINT}${RULE}  ${crew_s}"
      left_w=$((left_w + 5 + crew_w))
    elif [ "$crew_w" -gt 0 ]; then
      left=$crew_s; left_w=$crew_w
    fi
    right_w=$alert_w
    [ "$alert_w" -eq 0 ] || [ "$bat_w" -eq 0 ] || right_w=$((right_w + 3))
    right_w=$((right_w + bat_w))
    [ "$(row_need "$left_w" "$right_w")" -le "$width" ] || continue

    # The most urgent call, after the crew, cut to the columns left over.
    label=$(call_label)
    clickable=0
    [ -z "$label" ] || [ "$label" = "$NOTICE" ] || clickable=1
    if [ -n "$label" ]; then
      sep=0
      [ "$left_w" -eq 0 ] || sep=5
      room=$((width - $(row_need $((left_w + sep + 2)) "$right_w")))
      cut=${#label}
      [ "$cut" -le "$CALL_MIN" ] || cut=$CALL_MIN
      if [ "$room" -ge "$cut" ]; then
        [ "${#label}" -le "$room" ] || label="${label:0:$((room - 3))}..."
        [ "$sep" -eq 0 ] || left="${left}  ${FAINT}${RULE}  "
        if [ "$clickable" = 1 ]; then
          LINK_FROM=$((2 + left_w + sep))
          LINK_TO=$((LINK_FROM + 1 + ${#label}))
        fi
        left="${left}${CYAN}${POINTER} ${ICE}${label}"
        left_w=$((left_w + sep + 2 + ${#label}))
      fi
    fi

    # The night shift, between the alert and the battery, when it fits whole.
    night_s=
    night_w=0
    if [ -n "$NIGHT_TEXT" ]; then
      night_w=${#NIGHT_TEXT}
      [ "$right_w" -eq 0 ] || night_w=$((night_w + 3))
      if [ "$(row_need "$left_w" $((right_w + night_w)))" -le "$width" ]; then
        night_s="${NIGHT_COLOUR}${NIGHT_TEXT}"
      else
        night_w=0
      fi
    fi

    right=$alert_s
    [ -z "$night_s" ] || right="${right}${right:+   }${night_s}"
    [ "$bat_w" -eq 0 ] || right="${right}${right:+   }${bat}"
    right_w=$((right_w + night_w))
    ROW=" ${left}$(printf '%*s' "$((width - 2 - left_w - right_w))" '')${right} "
    return 0
  done <<EOF
$TIERS
EOF
  # Narrower than the smallest tier: whatever fits of a low battery's figure,
  # else of the alert, else of the bare wordmark.
  if battery_warns; then
    text="$BAT_PCT%"
    ROW="$(battery_colour)${text:0:$width}"
    rest=${#text}
  elif alert_shows; then
    text=$(alert_text short)
    ROW="${RED}${text:0:$width}"
    rest=${#text}
  else
    text=STARSHIP
    ROW="${BOLD}${CYAN}${text:0:$width}${UNBOLD}"
    rest=8
  fi
  [ "$rest" -lt "$width" ] || rest=$width
  ROW="${ROW}$(printf '%*s' "$((width - rest))" '')"
}

# render_frame: the whole pane, row by row, into FRAME. Every row is painted in
# the hull colour so the strip reads as one raised deck, and the content sits on
# the middle row (MIDDLE) of however tall Herdr made the pane. track_reading
# runs before compose so the crew's words match this reading.
FRAME=
MIDDLE=1
render_frame() {  # <home> <width> <height>
  local home=$1 width=$2 height=$3 row blank
  read_crew "$home"
  track_reading
  read_night "$home"
  read_reach "$home"
  read_battery
  compose "$width"
  blank="${HULL_BG}$(printf '%*s' "$width" '')${RESET}"
  MIDDLE=$(((height + 1) / 2))
  FRAME=
  row=1
  while [ "$row" -le "$height" ]; do
    [ "$row" -eq 1 ] || FRAME="${FRAME}"$'\n'
    if [ "$row" -eq "$MIDDLE" ]; then
      FRAME="${FRAME}${HULL_BG}${ROW}${RESET}"
    else
      FRAME="${FRAME}${blank}"
    fi
    row=$((row + 1))
  done
}

# --- the home and the plugin's own records ------------------------------------

config_dir() {
  local dir=${FM_BRIDGE_STRIP_CONFIG_DIR:-${HERDR_PLUGIN_CONFIG_DIR:-}}
  [ -n "$dir" ] || dir=$("$(herdr_bin)" plugin config-dir "$PLUGIN_ID" 2>/dev/null | tail -n 1) || dir=
  [ -n "$dir" ] || return 1
  printf '%s' "$dir"
}

resolve_home() {
  local dir recorded
  if [ -n "${FM_HOME:-}" ]; then
    printf '%s' "$FM_HOME"
    return 0
  fi
  if dir=$(config_dir) && [ -f "$dir/home" ]; then
    recorded=$(head -n 1 "$dir/home")
    [ -z "$recorded" ] || { printf '%s' "$recorded"; return 0; }
  fi
  printf '%s' "$ROOT"
}

# A running strip is recorded as panes/<pid>, holding its pane, tab and Herdr
# session, so `open` can tell a tab already has one and `remove` can stop each
# one. Herdr shares this directory across sessions and tab ids repeat between
# them, so a tab is only the same tab in the same session, named by the socket
# path every pane inherits from it.
RECORD=
record_self() {
  local dir
  dir=$(config_dir) || return 0
  mkdir -p "$dir/panes" 2>/dev/null || return 0
  RECORD="$dir/panes/$$"
  printf 'pane=%s\ntab=%s\nsession=%s\n' "${HERDR_PANE_ID:-}" "${HERDR_TAB_ID:-}" \
    "${HERDR_SOCKET_PATH:-}" > "$RECORD" 2>/dev/null || RECORD=
}

# is_strip_pid: the recorded process is still this renderer, not a recycled pid.
is_strip_pid() {  # <pid>
  local cmd
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  cmd=$(ps -p "$1" -o command= 2>/dev/null) || return 1
  case "$cmd" in *"$ME run"|*"$ME run "*) return 0 ;; esac
  return 1
}

record_value() {  # <file> <key>
  awk -F= -v k="$2" '$1 == k { print substr($0, index($0, "=") + 1); exit }' "$1" 2>/dev/null
}

# --- subcommands --------------------------------------------------------------

cmd_render() {
  local width=${COLUMNS:-100} height=1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --width) width=${2:-}; shift ;;
      --height) height=${2:-}; shift ;;
      *) usage; exit 2 ;;
    esac
    shift
  done
  case "$width$height" in ''|*[!0-9]*) usage; exit 2 ;; esac
  render_frame "$(resolve_home)" "$width" "$height"
  printf '%s\n' "$FRAME"
}

# pane_size: the pane's rows and columns from its terminal, or one row of 80
# columns when the terminal does not say (a size of zero says nothing).
pane_size() {
  local size
  size=$(stty size </dev/tty 2>/dev/null) || size=
  PANE_ROWS=${size% *}
  PANE_COLS=${size#* }
  case "$PANE_ROWS" in ''|*[!0-9]*|0) PANE_ROWS=1 ;; esac
  case "$PANE_COLS" in ''|*[!0-9]*|0) PANE_COLS=80 ;; esac
}

# The terminal settings the pane had, restored on exit, and whether this strip
# reads clicks (only when its input is a terminal).
TTY_SAVED=
CLICKS=0

cleanup() {
  [ -z "$RECORD" ] || rm -f "$RECORD" 2>/dev/null
  if [ "$CLICKS" = 1 ]; then
    printf '%s[?1006l%s[?1000l' "$E" "$E"
    [ -z "$TTY_SAVED" ] || stty "$TTY_SAVED" 2>/dev/null
  fi
  printf '%s[?7h%s[?25h%s' "$E" "$E" "$RESET"
}

# read_mouse: the rest of one SGR mouse report after its ESC, as MOUSE_B,
# MOUSE_X and MOUSE_Y, and MOUSE_PRESS 1 for a press (M) or 0 for a release
# (m). It fails on anything that is not one, having read only what it saw.
# Herdr hands a pane that asked for mouse reports the clicks made on it.
MOUSE_B=
MOUSE_X=
MOUSE_Y=
MOUSE_PRESS=0
read_mouse() {
  local ch seq='' n=0
  IFS= read -rsn1 -t 1 ch && [ "$ch" = '[' ] || return 1
  IFS= read -rsn1 -t 1 ch && [ "$ch" = '<' ] || return 1
  while [ "$n" -lt 24 ]; do
    IFS= read -rsn1 -t 1 ch || return 1
    case "$ch" in
      M|m) break ;;
      [0-9]|';') seq="$seq$ch" ;;
      *) return 1 ;;
    esac
    n=$((n + 1))
  done
  case "$ch" in M) MOUSE_PRESS=1 ;; m) MOUSE_PRESS=0 ;; *) return 1 ;; esac
  IFS=';' read -r MOUSE_B MOUSE_X MOUSE_Y <<EOF
$seq
EOF
  case "$MOUSE_B$MOUSE_X$MOUSE_Y" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$MOUSE_B" ] && [ -n "$MOUSE_X" ] && [ -n "$MOUSE_Y" ]
}

# A short line shown in place of the call when opening it failed, and the
# epoch it shows until.
NOTICE=
NOTICE_UNTIL=0

# open_call: open the Factory pane on the most urgent call, beside the pane
# below the strip (the pane the strip was opened above), through
# bin/fm-factory-pane.sh, which shows it in a Factory pane already open in
# this tab or opens one.
open_call() {  # <home>
  local out below now
  below=
  if [ -n "${HERDR_PANE_ID:-}" ] && command -v jq >/dev/null 2>&1; then
    out=$("$(herdr_bin)" pane neighbor --pane "$HERDR_PANE_ID" --direction down 2>/dev/null) || out=
    below=$(printf '%s' "$out" | jq -r '.result.neighbor.neighbor_pane_id // empty' 2>/dev/null)
  fi
  if [ -n "$below" ] && env -u HERDR_PLUGIN_CONFIG_DIR FM_HOME="$1" \
      bash "$SCRIPT_DIR/fm-factory-pane.sh" open --pane "$below" \
      --item "$CALL_ID" </dev/null >/dev/null 2>&1; then
    return 0
  fi
  now=$(date +%s)
  NOTICE='the Factory pane did not open'
  NOTICE_UNTIL=$((now + 5))
}

# calls_moved: 0 when the owner's calls may have changed since the frame on
# screen read them (bin/fm-owner-calls-signal-lib.sh), so the strip draws again
# at once rather than at the next frame: an answered or parked decision gives
# way to the next call within a second or two. A frame with no calls reading
# keeps the ordinary cadence.
calls_moved() {  # <home>
  [ "$CALLS_SIGNAL" != - ] || return 1
  [ "$(fm_owner_calls_signal "$1/state")" != "$CALLS_SIGNAL" ]
}

# wait_input: the pause between frames, <seconds> one-second ticks unless the
# pane is resized or clicked, or the owner's calls move. A left press on the
# most urgent call opens it. Each read waits at most a second, because bash 3.2
# cannot wait less and a resize does not interrupt it there.
wait_input() {  # <home> <seconds>
  local tick=0 ch
  while [ "$tick" -lt "$2" ] && [ "$RESIZED" = 0 ]; do
    tick=$((tick + 1))
    IFS= read -rsn1 -t 1 ch || {
      ! calls_moved "$1" || return 0
      continue
    }
    [ "$ch" = "$E" ] || continue
    read_mouse || continue
    [ "$MOUSE_PRESS" = 1 ] || continue
    # A left button press: low two bits clear, and no motion or wheel bit.
    [ $((MOUSE_B & 227)) -eq 0 ] || continue
    if [ "$MOUSE_Y" -eq "$MIDDLE" ] && [ "$LINK_FROM" -gt 0 ] \
      && [ "$MOUSE_X" -ge "$LINK_FROM" ] && [ "$MOUSE_X" -le "$LINK_TO" ]; then
      open_call "$1"
      return 0
    fi
  done
}

code_print() { cksum "${CODE_FILES[@]}" 2>/dev/null; }

# code_changed: the code on disk is no longer the code this loop started with,
# and every file of it is non-empty and parses, so re-executing cannot swap a
# working strip for an empty or half-written one. A change refused here is
# tried again next frame.
code_changed() {
  local f
  [ "$(code_print)" != "$CODE_PRINT" ] || return 1
  for f in "${CODE_FILES[@]}"; do
    [ -e "$f" ] || [ "$f" = "$SELF" ] || continue
    [ -s "$f" ] && bash -n "$f" 2>/dev/null || return 1
  done
}

# track_reading: when the strip stops saying it is reading and says it cannot.
# Before a first reading it allows one bounded refresh (FM_FLEET_STATE_WAIT in
# bin/fm-fleet-status-lib.sh) and a frame; a reading it had and lost is named at
# once. Either way the time shown is when the strip last stopped having one.
# READ_GRACE defaults to that bounded refresh plus one default frame, so
# `render` has it too; `run` recomputes it with its own interval.
READ_GRACE=$(($(fm_status_ttl "${FM_FLEET_STATE_WAIT:-}" 90) + 5))
READ_ONCE=0
UNREAD_AT=
UNREAD_CLOCK=
track_reading() {
  if [ "$READING_KNOWN" != 0 ]; then
    READ_ONCE=1
    UNREAD_AT=
    CANNOT_READ_SINCE=
    return 0
  fi
  if [ -z "$UNREAD_AT" ]; then
    UNREAD_AT=$SECONDS
    UNREAD_CLOCK=$(date +%H:%M)
  fi
  if [ "$READ_ONCE" = 1 ] || [ $((SECONDS - UNREAD_AT)) -ge "$READ_GRACE" ]; then
    CANNOT_READ_SINCE=$UNREAD_CLOCK
  fi
}

cmd_run() {
  local home sleeper interval tick
  # FM_BRIDGE_STRIP_INTERVAL is a test seam for faster frames, not a setting.
  interval=$(fm_status_ttl "${FM_BRIDGE_STRIP_INTERVAL:-}" 5)
  [ "$interval" -gt 0 ] || interval=5
  READ_GRACE=$(($(fm_status_ttl "${FM_FLEET_STATE_WAIT:-}" 90) + interval))
  CODE_PRINT=$(code_print)
  home=$(resolve_home)
  record_self
  trap cleanup EXIT
  trap 'exit 0' TERM HUP INT
  # A resize interrupts the wait below, so the strip is cleared and redrawn at
  # once rather than leaving the old size's rows behind.
  RESIZED=0
  trap 'RESIZED=1' WINCH
  # Keystrokes and mouse reports are read, never echoed, and the pane asks for
  # button reports in the SGR form so a click on the most urgent call can open
  # it. Without a terminal there is nothing to click and the strip only waits.
  if [ -t 0 ] && TTY_SAVED=$(stty -g 2>/dev/null) && stty -echo -icanon min 1 time 0 2>/dev/null; then
    CLICKS=1
  fi
  # Cursor hidden, autowrap off so a row can never spill onto the next.
  printf '%s[?25l%s[?7l%s[2J' "$E" "$E" "$E"
  [ "$CLICKS" = 0 ] || printf '%s[?1000h%s[?1006h' "$E" "$E"
  while :; do
    # Same process, same pane record and pane; only the code is new. The
    # pane's own terminal settings go back first, so the new process saves
    # those rather than this one's.
    if code_changed; then
      [ "$CLICKS" = 0 ] || [ -z "$TTY_SAVED" ] || stty "$TTY_SAVED" 2>/dev/null
      exec "$BASH" "$SELF" run
    fi
    pane_size
    render_frame "$home" "$PANE_COLS" "$PANE_ROWS"
    [ "$RESIZED" = 0 ] || printf '%s[2J' "$E"
    RESIZED=0
    printf '%s[H%s' "$E" "$FRAME"
    if [ "$CLICKS" = 1 ]; then
      wait_input "$home" "$interval"
    else
      tick=0
      while [ "$tick" -lt "$interval" ] && [ "$RESIZED" = 0 ]; do
        tick=$((tick + 1))
        sleep 1 &
        sleeper=$!
        wait "$sleeper" 2>/dev/null
        kill "$sleeper" 2>/dev/null
        ! calls_moved "$home" || break
      done
    fi
  done
}

# open: the Herdr calls that put the strip on top of a pane and leave focus below it.
cmd_open() {
  local target=${HERDR_PANE_ID:-} herdr dir rec out strip home
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --pane) target=${2:-}; shift ;;
      *) usage; exit 2 ;;
    esac
    shift
  done
  [ -n "$target" ] || die "no pane to put the strip above; run this inside a Herdr pane or pass --pane"
  command -v jq >/dev/null 2>&1 || die "jq is needed to read Herdr's answer"
  herdr=$(herdr_bin)
  if [ -n "${HERDR_TAB_ID:-}" ] && dir=$(config_dir); then
    for rec in "$dir"/panes/*; do
      [ -f "$rec" ] || continue
      is_strip_pid "$(basename "$rec")" || continue
      if [ "$(record_value "$rec" tab)" = "$HERDR_TAB_ID" ] \
        && [ "$(record_value "$rec" session)" = "${HERDR_SOCKET_PATH:-}" ]; then
        printf 'The Starship bridge is already showing in this tab.\n'
        return 0
      fi
    done
  fi
  home=$(resolve_home)
  out=$("$herdr" plugin pane open --plugin "$PLUGIN_ID" --entrypoint bridge \
    --placement split --direction down --target-pane "$target" --no-focus \
    --env "FM_HOME=$home" 2>&1) || die "Herdr did not open the strip: $out"
  strip=$(printf '%s' "$out" | jq -r '(.result.plugin_pane.pane.pane_id // .result.pane.pane_id) // empty' 2>/dev/null)
  [ -n "$strip" ] && [ "$strip" != "$target" ] \
    || die "Herdr opened a strip below pane $target but did not name it, so it was left where it is"
  "$herdr" pane swap --source-pane "$strip" --target-pane "$target" >/dev/null 2>&1 \
    || die "the strip opened below pane $target as pane $strip, but could not be moved above it"
  # The split's first share is now the strip's. Shrinking pane $target's top
  # edge upward by the largest step takes that share to Herdr's floor.
  "$herdr" pane resize --pane "$target" --direction up --amount 0.5 >/dev/null 2>&1 \
    || die "the strip is above pane $target as pane $strip, but could not be made slim"
  # The swap handed keyboard focus to the strip; give it back to the pane below.
  "$herdr" pane focus --pane "$strip" --direction down >/dev/null 2>&1 \
    || die "the strip is showing above pane $target, but focus could not be given back to it"
  printf 'The Starship bridge is showing above this pane.\n'
}

cmd_install() {
  local herdr dir home
  herdr=$(herdr_bin)
  [ -f "$PLUGIN_DIR/herdr-plugin.toml" ] || die "the plugin is missing from $PLUGIN_DIR"
  "$herdr" plugin link "$PLUGIN_DIR" >/dev/null || die "Herdr did not link the plugin at $PLUGIN_DIR"
  home=${FM_HOME:-$ROOT}
  dir=$(config_dir) || die "the plugin is linked, but Herdr did not say where its config lives"
  if ! { mkdir -p "$dir" && printf '%s\n' "$home" > "$dir/home"; }; then
    die "the plugin is linked, but this home could not be recorded in $dir"
  fi
  printf 'The Starship bridge is installed.\n'
  if [ -n "${HERDR_PANE_ID:-}" ]; then
    cmd_open
  else
    printf 'Show it from a Herdr pane with: %s open\n' "$0"
  fi
}

cmd_remove() {
  local herdr dir rec pid stopped=0
  herdr=$(herdr_bin)
  if dir=$(config_dir); then
    for rec in "$dir"/panes/*; do
      [ -f "$rec" ] || continue
      pid=$(basename "$rec")
      if is_strip_pid "$pid"; then
        # The renderer is its pane's only process, so the pane closes with it.
        kill -TERM "$pid" 2>/dev/null && stopped=$((stopped + 1))
      fi
      rm -f "$rec"
    done
    rm -f "$dir/home"
  fi
  "$herdr" plugin unlink "$PLUGIN_ID" >/dev/null || die "stopped $stopped strip(s), but Herdr did not unlink the plugin"
  printf 'The Starship bridge is removed (%s strip(s) closed).\n' "$stopped"
}

case "${1:-}" in
  render) shift; cmd_render "$@" ;;
  run) shift; cmd_run "$@" ;;
  open) shift; cmd_open "$@" ;;
  install) shift; cmd_install "$@" ;;
  remove) shift; cmd_remove "$@" ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
