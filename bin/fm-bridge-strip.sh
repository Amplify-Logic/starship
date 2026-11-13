#!/usr/bin/env bash
# fm-bridge-strip.sh - the Starship bridge: a slim strip across the top of a
# Herdr workspace with the STARSHIP wordmark, the crew's lamps and the battery.
#
# It is a Herdr plugin pane (herdr-plugins/starship-bridge/). The strip only
# READS: the crew lamps come from bin/fm-fleet-status-lib.sh, the same cached
# reading the primary status bar shows, and the battery from `pmset -g batt` on
# a Mac. It never steers, changes or drains anything. docs/bridge-strip.md owns
# what the strip shows and why; this header owns the commands.
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
#   fm-bridge-strip.sh run       the pane's own loop, redrawn every 5 seconds;
#                                Herdr starts it
#   fm-bridge-strip.sh render [--width N] [--height N]
#                                print one frame and exit
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
#   FM_FLEET_STATE_*              see bin/fm-fleet-status-lib.sh
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
BUSY=0
FOR_YOU=0
TO_MERGE=0
READING_AGE=0

# read_crew: the fleet reading, folded into the three lamps the strip shows.
# Busy is a worker typing plus work the validation pipeline is carrying,
# decisions for you are what a human owes, and ready to merge is the rest of
# what waits on the owner: a PR or branch ready to land.
read_crew() {  # <home>
  local reading records working stopped validating paused attention ready
  local known age decisions
  READING_KNOWN=0
  reading=$(fm_fleet_status_counts "$1/state" decisions 2>/dev/null) || return 0
  IFS=$'\t' read -r records working stopped validating paused attention ready \
    known age decisions <<EOF
$reading
EOF
  case "$working$validating$ready$known$age$decisions" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ "$decisions" -le "$ready" ] || return 0
  READING_KNOWN=$known
  READING_AGE=$age
  BUSY=$((working + validating))
  FOR_YOU=$decisions
  TO_MERGE=$((ready - decisions))
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

# --- composing a row ----------------------------------------------------------

# The tiers a row tries, widest first. Each names the wordmark, the crew and the
# battery form. Words go before lamps, and on a very narrow pane the lamps go
# before the wordmark. A low battery is never dropped while anything else is
# shown, because it is the one piece that can need the owner within minutes.
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

compose() {  # <width>
  local width=$1 mark_form crew_form bat_form mark mark_w crew_s crew_w bat bat_w
  local left left_w need gap text rest
  while read -r mark_form crew_form bat_form; do
    if [ "$bat_form" = none ] && battery_warns; then
      continue
    fi
    wordmark "$mark_form"; mark=$SEG; mark_w=$SEG_W
    crew "$crew_form"; crew_s=$SEG; crew_w=$SEG_W
    battery "$bat_form"; bat=$SEG; bat_w=$SEG_W
    left=$mark; left_w=$mark_w
    if [ "$mark_w" -gt 0 ] && [ "$crew_w" -gt 0 ]; then
      left="${left}  ${FAINT}${RULE}  ${crew_s}"
      left_w=$((left_w + 5 + crew_w))
    elif [ "$crew_w" -gt 0 ]; then
      left=$crew_s; left_w=$crew_w
    fi
    # One column of margin each side, and at least three between the left
    # side and the battery when both are there.
    need=$((2 + left_w + bat_w))
    gap=0
    [ "$bat_w" -eq 0 ] || [ "$left_w" -eq 0 ] || gap=3
    [ $((need + gap)) -le "$width" ] || continue
    ROW=" ${left}$(printf '%*s' "$((width - need))" '')${bat} "
    return 0
  done <<EOF
$TIERS
EOF
  # Narrower than the smallest tier: whatever fits of a low battery's figure,
  # else of the bare wordmark.
  if battery_warns; then
    text="$BAT_PCT%"
    ROW="$(battery_colour)${text:0:$width}"
    rest=${#text}
  else
    text=STARSHIP
    ROW="${BOLD}${CYAN}${text:0:$width}${UNBOLD}"
    rest=8
  fi
  [ "$rest" -lt "$width" ] || rest=$width
  ROW="${ROW}$(printf '%*s' "$((width - rest))" '')"
}

# render_frame: the whole pane, row by row. Every row is painted in the hull
# colour so the strip reads as one raised deck, and the content sits on the
# middle row of however tall Herdr made the pane.
render_frame() {  # <home> <width> <height>
  local home=$1 width=$2 height=$3 middle row blank
  read_crew "$home"
  read_battery
  compose "$width"
  blank="${HULL_BG}$(printf '%*s' "$width" '')${RESET}"
  middle=$(((height + 1) / 2))
  for row in $(seq 1 "$height"); do
    [ "$row" -eq 1 ] || printf '\n'
    if [ "$row" -eq "$middle" ]; then
      printf '%s%s%s' "$HULL_BG" "$ROW" "$RESET"
    else
      printf '%s' "$blank"
    fi
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

# A running strip is recorded as panes/<pid>, holding its pane and tab, so
# `open` can tell a tab already has one and `remove` can stop each one.
RECORD=
record_self() {
  local dir
  dir=$(config_dir) || return 0
  mkdir -p "$dir/panes" 2>/dev/null || return 0
  RECORD="$dir/panes/$$"
  printf 'pane=%s\ntab=%s\n' "${HERDR_PANE_ID:-}" "${HERDR_TAB_ID:-}" > "$RECORD" 2>/dev/null || RECORD=
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
  printf '\n'
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

cleanup() {
  [ -z "$RECORD" ] || rm -f "$RECORD" 2>/dev/null
  printf '%s[?7h%s[?25h%s' "$E" "$E" "$RESET"
}

cmd_run() {
  local home sleeper frame
  home=$(resolve_home)
  record_self
  trap cleanup EXIT
  trap 'exit 0' TERM HUP INT
  # A resize interrupts the wait below, so the strip is cleared and redrawn at
  # once rather than leaving the old size's rows behind.
  RESIZED=0
  trap 'RESIZED=1' WINCH
  # Cursor hidden, autowrap off so a row can never spill onto the next.
  printf '%s[?25l%s[?7l%s[2J' "$E" "$E" "$E"
  while :; do
    pane_size
    frame=$(render_frame "$home" "$PANE_COLS" "$PANE_ROWS")
    [ "$RESIZED" = 0 ] || printf '%s[2J' "$E"
    RESIZED=0
    printf '%s[H%s' "$E" "$frame"
    sleep 5 &
    sleeper=$!
    wait "$sleeper" 2>/dev/null
    kill "$sleeper" 2>/dev/null
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
      if [ "$(record_value "$rec" tab)" = "$HERDR_TAB_ID" ]; then
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
