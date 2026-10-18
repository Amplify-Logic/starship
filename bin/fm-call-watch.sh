#!/usr/bin/env bash
# fm-call-watch.sh - notice calls on this Mac: remind you to ask before
# recording, and stop a running recording once the call has ended.
#
# Usage:
#   fm-call-watch.sh --once    poll once (what the LaunchAgent runs)
#   fm-call-watch.sh render    print the LaunchAgent definition
#   fm-call-watch.sh install   write and load the LaunchAgent
#   fm-call-watch.sh status    print the call state and the installed agent
#   fm-call-watch.sh remove    unload and delete the LaunchAgent
#
# It never starts a recording. A call is a Google Meet tab in the Chrome that
# chrome-devtools-axi drives, or a call app (Zoom, FaceTime, Teams, Slack,
# WhatsApp, Krisp, or a browser) capturing the microphone, read straight from
# coreaudiod by a small helper compiled on first use from
# bin/fm-call-mic-in-use.c (macOS 14.2 or later). When a call begins and no
# recording is running, one notification asks you to get everyone's agreement
# and names the start command. When a recording is running and no call has been
# seen for 180 seconds, it stops the recording (which writes the end-of-call
# notes and archives the call); a recording started with no call detected, such as an
# in-person meeting, is left for you to stop. A microphone probe that fails
# keeps a microphone call open rather than cutting a live recording.
#
# The LaunchAgent runs `--once` every 20 seconds through the shared owner in
# bin/fm-launchd-schedule-lib.sh, with the PATH this command was installed from
# so it finds Homebrew's tools and claude. The label is derived from FM_HOME, so
# each home installs its own. State: state/calls/call-watch.json.
#
# Environment overrides (tests): CALL_WATCH_STATE_FILE, CALL_WATCH_COMPANION,
# CALL_WATCH_INTERVAL_SECONDS, CALL_WATCH_ABSENT_SECONDS, CALL_WATCH_NOW_EPOCH,
# CALL_WATCH_MIC_HELPER, CALL_WATCH_MIC_HELPER_SOURCE, CALL_WATCH_PAGES_FILE,
# CALL_WATCH_PS_FILE, CALL_WATCH_MIC_PIDS_FILE, CALL_WATCH_NOTIFY_BIN,
# CALL_WATCH_LAUNCH_AGENTS_DIR, CALL_WATCH_LAUNCHCTL.
set -euo pipefail

# shellcheck source=bin/fm-call-lib.sh disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-call-lib.sh"
STATE_DIR=$FM_CALL_STATE
STATE_FILE=${CALL_WATCH_STATE_FILE:-$STATE_DIR/call-watch.json}
COMPANION=${CALL_WATCH_COMPANION:-$FM_CALL_BIN/fm-call-companion.sh}
INTERVAL=${CALL_WATCH_INTERVAL_SECONDS:-20}
ABSENT_LIMIT=${CALL_WATCH_ABSENT_SECONDS:-180}
NOW_EPOCH=${CALL_WATCH_NOW_EPOCH:-}
MIC_HELPER=${CALL_WATCH_MIC_HELPER:-$STATE_DIR/mic-in-use}
MIC_HELPER_SOURCE=${CALL_WATCH_MIC_HELPER_SOURCE:-$FM_CALL_BIN/fm-call-mic-in-use.c}
NOTIFY_BIN=${CALL_WATCH_NOTIFY_BIN:-osascript}

now_epoch() { if [ -n "$NOW_EPOCH" ]; then printf '%s\n' "$NOW_EPOCH"; else date +%s; fi; }
iso_time() { date -r "$1" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date -d "@$1" '+%Y-%m-%dT%H:%M:%S%z'; }
write_state() {
  local active=$1 source=$2 since=$3 last_seen=$4 mic_pid=${5:-0} out="$STATE_FILE.tmp.$$"
  jq -n --argjson active "$active" --arg source "$source" --argjson since "$since" --argjson last_seen "$last_seen" --argjson mic_pid "$mic_pid" '{active:$active,source:$source,since:$since,last_seen:$last_seen,mic_pid:$mic_pid}' > "$out"
  mv "$out" "$STATE_FILE"
}
ensure_state() { mkdir -p "$(dirname "$STATE_FILE")"; jq -e 'type=="object" and (.active|type=="boolean")' "$STATE_FILE" >/dev/null 2>&1 || write_state false none 0 0 0; }
pages_output() { if [ -n "${CALL_WATCH_PAGES_FILE:-}" ]; then cat "$CALL_WATCH_PAGES_FILE"; else chrome-devtools-axi pages 2>/dev/null || true; fi; }
find_meet() {
  pages_output | awk 'match($0,/https:\/\/meet\.google\.com\/[a-z][a-z][a-z]-[a-z][a-z][a-z][a-z]-[a-z][a-z][a-z]([^[:alnum:]-]|$)/) { if (match($0,/(^|[^0-9])[0-9]+([^0-9]|$)/)) { s=substr($0,RSTART,RLENGTH); gsub(/[^0-9]/,"",s); print s; exit } }'
}
# Call apps are matched by bundle path, so a browser's audio helper process counts as its browser.
CALL_APP_PATTERN='/zoom\.us\.app/|/FaceTime\.app/|/usr/libexec/avconferenced|/Microsoft Teams[^/]*\.app/|/Slack\.app/|/WhatsApp\.app/|/krisp\.app/|/Arc\.app/|/Google Chrome\.app/|/Safari\.app/|com\.apple\.WebKit\.GPU'
export CALL_APP_PATTERN
ensure_helper() {
  [ -x "$MIC_HELPER" ] && [ ! "$MIC_HELPER_SOURCE" -nt "$MIC_HELPER" ] && return 0
  [ -f "$MIC_HELPER_SOURCE" ] || return 1
  mkdir -p "$(dirname "$MIC_HELPER")"
  /usr/bin/clang -O2 -framework CoreAudio -framework CoreFoundation -o "$MIC_HELPER.tmp.$$" "$MIC_HELPER_SOURCE" 2>/dev/null && mv "$MIC_HELPER.tmp.$$" "$MIC_HELPER"
}
# PID<TAB>bundle for every process capturing audio input now, straight from coreaudiod.
mic_pids() {
  if [ -n "${CALL_WATCH_MIC_PIDS_FILE:-}" ]; then cat "$CALL_WATCH_MIC_PIDS_FILE"; return 0; fi
  ensure_helper || { printf 'call-watch: microphone helper missing and could not be built from %s\n' "$MIC_HELPER_SOURCE" >&2; return 1; }
  "$MIC_HELPER" || { printf 'call-watch: microphone helper failed\n' >&2; return 1; }
}
process_output() { if [ -n "${CALL_WATCH_PS_FILE:-}" ]; then cat "$CALL_WATCH_PS_FILE"; else ps -o pid=,command= -p "$1" 2>/dev/null || true; fi; }
# Prints the PIDs of call-app processes capturing audio now; returns 1 when the probe itself failed.
active_call_mic_pids() {
  local pids list
  pids=$(mic_pids) || return 1
  list=$(printf '%s\n' "$pids" | awk -F '\t' '$1 ~ /^[0-9]+$/ {printf "%s%s", sep, $1; sep=","}')
  [ -n "$list" ] || return 0
  process_output "$list" | awk -v want="$list" 'BEGIN{n=split(want,w,",");for(i=1;i<=n;i++)ok[w[i]]=1} {pid=$1; if(!(pid in ok)) next; cmd=$0; sub(/^ *[0-9]+ +/,"",cmd); if (cmd ~ ENVIRON["CALL_APP_PATTERN"]) print pid}'
}
# Read status in full: grep -q would close the pipe early and, under pipefail, fail on SIGPIPE.
recording() { local out; out=$("$COMPANION" status 2>/dev/null) || true; [[ "$out" == *' running '* ]]; }
notify() {
  local message=$1 escaped
  escaped=$(printf '%s' "$message" | sed 's/\\/\\\\/g; s/"/\\"/g')
  if [ "$NOTIFY_BIN" = osascript ]; then
    osascript -e "display notification \"$escaped\" with title \"Call recorder\"" >/dev/null 2>&1 || true
  else
    "$NOTIFY_BIN" "$message" >/dev/null 2>&1 || true
  fi
}
# A new call: remind, never record. The reminder names the exact start command.
begin_call() {
  local source=$1 value=$2 now=$3 command
  if ! recording; then
    if [ "$source" = meet ]; then command="fm-call-companion.sh start --page $value --everyone-agreed"; else command='fm-call-companion.sh start --mic --everyone-agreed'; fi
    notify "Call detected; not recording. To record, ask everyone first; once all agree, run: $command"
  fi
  write_state true "$source" "$now" "$now" "$value"
}
end_call() {
  if recording; then "$COMPANION" stop || true; fi
  write_state false none 0 0 0
}
poll_once() {
  local now active source since last_seen mic_pid meet mic='' probe_failed=false detected_source='' detected_value=0
  now=$(now_epoch); active=$(jq -r .active "$STATE_FILE"); source=$(jq -r .source "$STATE_FILE"); since=$(jq -r .since "$STATE_FILE"); last_seen=$(jq -r .last_seen "$STATE_FILE"); mic_pid=$(jq -r .mic_pid "$STATE_FILE")
  meet=$(find_meet)
  if [ -n "$meet" ]; then detected_source=meet; detected_value=$meet
  elif mic=$(active_call_mic_pids); then
    if [ -n "$mic" ]; then
      detected_source=mic
      if printf '%s\n' "$mic" | grep -qx "$mic_pid"; then detected_value=$mic_pid; else detected_value=$(printf '%s\n' "$mic" | head -n 1); fi
    fi
  else probe_failed=true
  fi
  if [ -n "$detected_source" ]; then
    if [ "$active" = false ]; then begin_call "$detected_source" "$detected_value" "$now"
    elif [ "$source" = mic ] && [ "$detected_source" = mic ]; then write_state true "$source" "$since" "$now" "$detected_value"
    else write_state true "$source" "$since" "$now" "$mic_pid"; fi
  elif [ "$active" = true ] && [ "$source" = mic ] && [ "$probe_failed" = true ]; then
    : # microphone state unknown: keep the call open rather than cut a live recording
  elif [ "$active" = true ] && [ $((now-last_seen)) -ge "$ABSENT_LIMIT" ]; then end_call; fi
}
show_state() { local active source since last_seen; active=$(jq -r .active "$STATE_FILE"); source=$(jq -r .source "$STATE_FILE"); since=$(jq -r .since "$STATE_FILE"); last_seen=$(jq -r .last_seen "$STATE_FILE"); if [ "$active" = true ]; then printf 'call on; source=%s; since=%s; last-seen=%s\n' "$source" "$(iso_time "$since")" "$(iso_time "$last_seen")"; else printf 'call off; source=none\n'; fi; }

die() {
  printf 'fm-call-watch: %s\n' "$*" >&2
  exit 2
}

FM_LAUNCHD_STEM=call-watch
FM_LAUNCHD_PROGRAM="$FM_CALL_BIN/fm-call-watch.sh"
FM_LAUNCHD_PROGRAM_ARG=--once
FM_LAUNCHD_ROOT=$FM_CALL_ROOT
FM_LAUNCHD_FM_HOME=$FM_CALL_HOME
FM_LAUNCHD_LOG_DIR="$STATE_DIR/watch"
FM_LAUNCHD_AGENTS_DIR=${CALL_WATCH_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}
FM_LAUNCHD_LAUNCHCTL=${CALL_WATCH_LAUNCHCTL:-launchctl}
FM_LAUNCHD_PATH=$PATH
FM_LAUNCHD_REMOVE_NEEDS_DARWIN=true

# shellcheck source=bin/fm-launchd-schedule-lib.sh disable=SC1091
. "$FM_CALL_BIN/fm-launchd-schedule-lib.sh"

fm_launchd_interval() {
  case "$INTERVAL" in ''|*[!0-9]*|0) die "CALL_WATCH_INTERVAL_SECONDS must be a positive integer: $INTERVAL" ;; esac
  printf '%s\n' "$INTERVAL"
}

fm_launchd_status_detail() {
  ensure_state
  show_state
}

main() {
  command -v jq >/dev/null 2>&1 || { printf 'fm-call-watch: jq is required\n' >&2; exit 127; }
  case "${1:-}" in
    --once) ensure_state; poll_once ;;
    render) fm_launchd_render ;;
    install) fm_launchd_install ;;
    status) fm_launchd_status ;;
    remove) fm_launchd_remove ;;
    -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0" ;;
    *) printf 'usage: fm-call-watch.sh --once|render|install|status|remove\n' >&2; exit 2 ;;
  esac
}
main "$@"
