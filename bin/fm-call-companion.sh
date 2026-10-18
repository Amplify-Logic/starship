#!/usr/bin/env bash
# fm-call-companion.sh - record a call, only after everyone on it has agreed,
# into a live desk and end-of-call notes for this Firstmate home.
#
# Usage:
#   fm-call-companion.sh start --mic --everyone-agreed
#   fm-call-companion.sh start --page <id> --everyone-agreed
#   fm-call-companion.sh status
#   fm-call-companion.sh stop
#   fm-call-companion.sh desk [--display]
#   fm-call-companion.sh notes
#   fm-call-companion.sh reset
#   fm-call-companion.sh list
#   fm-call-companion.sh delete [<stamp> | --all]
#
# CONSENT: `start` refuses without --everyone-agreed. Pass it only after every
# person on the call has said yes to being recorded; the flag is recorded as a
# line at the top of the transcript. Nothing in this tool starts a recording on
# its own: bin/fm-call-watch.sh only notices a call, reminds you to ask, and
# stops a running recording when the call ends.
#
# start --mic records this Mac's microphone and, through a loopback device such
# as BlackHole, the call audio (bin/fm-call-mic.sh, transcribed locally by
# whisper.cpp). start --page <id> reads a Google Meet tab's captions instead
# (bin/fm-call-captions.sh; `fm-call-captions.sh --find-meet` lists ids). Both
# run the live desk (bin/fm-call-digest.sh) and open data/calls/glance.html.
# Each call gets a stamp when it starts (state/calls/call-stamp); its archive
# files and its lines in the decision and spoken-order logs carry that stamp.
# stop ends every part, restores the audio output, writes the end-of-call
# notes (bin/fm-call-final-notes.py, a few minutes) to data/calls/notes.*, and
# then archives the call under data/calls/archive/<stamp>-*, so the next start
# always begins clean; when the notes fail, the call stays for `notes` to rerun
# and the next start archives it; a stop after the recorder crashed closes the
# call out the same way. reset archives the current call by hand.
# list prints the archived stamps. delete removes the most recent call: the
# one still in place, otherwise the last one archived; while recording, it
# first stops the recording without writing notes or calling any model, for
# when someone objects. delete <stamp> removes one archived call. Both remove
# its transcript, desk, digest, live items, notes, the logs, and its lines in
# the decision and spoken-order logs, and print which call went. A stop still
# writing the notes of a call deleted meanwhile discards them. delete --all
# removes every call, the archive, and the decision, spoken-order and action
# logs, including untagged lines written before calls had stamps. delete
# <stamp> and delete --all refuse while recording.
#
# desk opens the desk page; with --display, or on start when the display_host
# setting is set, it also shows display_url full screen on that ssh host's
# Hyprland desktop with Chromium, and stop closes it again.
#
# macOS only. Paths and settings: bin/fm-call-lib.sh. Environment overrides:
# CALL_COMPANION_OPEN_BIN, CALL_COMPANION_SSH_BIN,
# CALL_COMPANION_SWITCH_AUDIO_BIN, CALL_COMPANION_STOP_TIMEOUT_SECONDS,
# CALL_COMPANION_PYTHON_BIN, CALL_COMPANION_NOTES_MODEL,
# CALL_COMPANION_FINAL_NOTES (0 skips the end-of-call notes).
# See docs/call-companion.md.

set -euo pipefail

# shellcheck source=bin/fm-call-lib.sh disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-call-lib.sh"
DATA_DIR=$FM_CALL_DATA
STATE_DIR=$FM_CALL_STATE
LOG_DIR="$STATE_DIR/logs"
AUDIO_DIR="$STATE_DIR/audio"
ARCHIVE_DIR="$DATA_DIR/archive"
PUBLIC_DIR="$DATA_DIR/public"
TRANSCRIPT="$DATA_DIR/transcript.txt"
DIGEST="$DATA_DIR/digest.json"
DESK="$DATA_DIR/desk.md"
GLANCE="$DATA_DIR/glance.html"
LIVE_ITEMS="$STATE_DIR/live-items.jsonl"
CALL_STAMP="$STATE_DIR/call-stamp"
PREVIOUS_OUTPUT="$STATE_DIR/previous-output"
DISPLAY_ADDRESS="$STATE_DIR/display-desk-address"
NOTES_FILES='notes.md notes.html notes.json notes-model.json'
CALL_LOGS='triggers.log decisions.log decisions-batch.log'
OPEN_BIN=${CALL_COMPANION_OPEN_BIN:-open}
SSH_BIN=${CALL_COMPANION_SSH_BIN:-ssh}
SWITCH_AUDIO_BIN=${CALL_COMPANION_SWITCH_AUDIO_BIN:-$(fm_call_tool SwitchAudioSource /opt/homebrew/bin/SwitchAudioSource)}
STOP_TIMEOUT_SECONDS=${CALL_COMPANION_STOP_TIMEOUT_SECONDS:-2}
PYTHON_BIN=${CALL_COMPANION_PYTHON_BIN:-$(fm_call_tool python3 /usr/bin/python3)}
NOTES_SCRIPT="$FM_CALL_BIN/fm-call-final-notes.py"
FINAL_NOTES=${CALL_COMPANION_FINAL_NOTES:-1}
NOTES_MODEL=${CALL_COMPANION_NOTES_MODEL:-$(fm_call_setting notes_model opus)}
LOCAL_SPEAKER=$(fm_call_setting speaker_name me)
MULTI_OUTPUT=$(fm_call_setting multi_output_device 'Multi-Output Device')
DISPLAY_HOST=$(fm_call_setting display_host '')
DISPLAY_URL=$(fm_call_setting display_url '')

usage() {
  cat <<'EOF' >&2
usage: fm-call-companion.sh start --mic --everyone-agreed
       fm-call-companion.sh start --page <id> --everyone-agreed
       fm-call-companion.sh status
       fm-call-companion.sh stop
       fm-call-companion.sh desk [--display]
       fm-call-companion.sh notes
       fm-call-companion.sh reset
       fm-call-companion.sh list
       fm-call-companion.sh delete [<stamp> | --all]
EOF
}

display_ssh() {
  "$SSH_BIN" -o BatchMode=yes -o ConnectTimeout=5 "$DISPLAY_HOST" "$@"
}

display_reachable() {
  [ -n "$DISPLAY_HOST" ] || return 1
  display_ssh true >/dev/null 2>&1
}

# A laptop host with its lid shut has no screen to show the desk on.
display_lid_open() {
  display_ssh 'bash -s' <<'REMOTE'
set -euo pipefail
shopt -s nullglob
states=(/proc/acpi/button/lid/*/state)
[ "${#states[@]}" -gt 0 ] || exit 0
for state_file in "${states[@]}"; do
  state=$(awk 'tolower($0) ~ /state:[[:space:]]*open/ {print "open"} tolower($0) ~ /state:[[:space:]]*closed/ {print "closed"}' "$state_file")
  [ "$state" = open ] || exit 1
done
REMOTE
}

display_show_window() {
  local url=$1 url_q address
  printf -v url_q '%q' "$url"
  address=$(
  display_ssh "bash -s -- $url_q" <<'REMOTE'
set -euo pipefail
url=$1
uid=$(id -u)
runtime_dir=/run/user/$uid
hypr_dir=${FIRSTMATE_HYPR_DIR:-$runtime_dir/hypr}
signature=
if [ -d "$hypr_dir" ]; then
  for entry in "$hypr_dir"/*; do
    [ -e "$entry" ] || continue
    signature=${entry##*/}
    break
  done
fi
[ -n "$signature" ] || exit 1
export XDG_RUNTIME_DIR=$runtime_dir
export HYPRLAND_INSTANCE_SIGNATURE=$signature
target=${url#*://}
host=${target%%/*}
host=${host%%:*}
path=${target#*/}
[ "$path" != "$target" ] || path=
path=${path%%\?*}
path=${path//\//_}
hyprctl dispatch 'hl.dsp.dpms("on")' >/dev/null
hyprctl dispatch "hl.dsp.exec_cmd(\"chromium --app=$url\")" >/dev/null
sleep 1
clients=$(hyprctl clients -j)
address=$(printf '%s\n' "$clients" | jq -r --arg host "$host" --arg path "$path" '.[] | .initialClass as $class | select(($class | startswith("chrome-")) and ($class | contains($host)) and ($path == "" or ($class | contains($path)))) | .address' | head -n 1)
[ -n "$address" ] || exit 1
workspace=$(hyprctl activeworkspace -j | jq -r '.id')
hyprctl dispatch "hl.dsp.window.move({window=\"address:$address\", workspace=$workspace})" >/dev/null
hyprctl dispatch "hl.dsp.focus({window=\"address:$address\"})" >/dev/null
fullscreen=$(printf '%s\n' "$clients" | jq -r --arg address "$address" '.[] | select(.address == $address) | .fullscreen')
if [ "$fullscreen" = 0 ]; then
  hyprctl dispatch "hl.dsp.window.fullscreen({window=\"address:$address\"})" >/dev/null
fi
printf '%s\n' "$address"
REMOTE
  )
  [[ "$address" =~ ^0x[0-9A-Fa-f]+$ ]] || return 1
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$address" > "$DISPLAY_ADDRESS.tmp.$$"
  mv "$DISPLAY_ADDRESS.tmp.$$" "$DISPLAY_ADDRESS"
}

display_hide_window() {
  local address=$1 address_q
  printf -v address_q '%q' "$address"
  display_ssh "bash -s -- $address_q" <<'REMOTE'
set -euo pipefail
address=$1
uid=$(id -u)
runtime_dir=/run/user/$uid
hypr_dir=${FIRSTMATE_HYPR_DIR:-$runtime_dir/hypr}
signature=
if [ -d "$hypr_dir" ]; then
  for entry in "$hypr_dir"/*; do
    [ -e "$entry" ] || continue
    signature=${entry##*/}
    break
  done
fi
[ -n "$signature" ] || exit 1
export XDG_RUNTIME_DIR=$runtime_dir
export HYPRLAND_INSTANCE_SIGNATURE=$signature
hyprctl dispatch "hl.dsp.window.close({window=\"address:$address\"})" >/dev/null
REMOTE
}

hide_desk_display() {
  local address
  [ -s "$DISPLAY_ADDRESS" ] || return 0
  display_reachable || return 0
  address=$(cat "$DISPLAY_ADDRESS")
  [[ "$address" =~ ^0x[0-9A-Fa-f]+$ ]] || return 1
  display_hide_window "$address"
  rm -f "$DISPLAY_ADDRESS"
}

# The desk on the second screen; a missing or closed screen is a note on the
# desk, never a failed start.
show_desk_display() {
  if [ -z "$DISPLAY_HOST" ] || [ -z "$DISPLAY_URL" ]; then
    mkdir -p "$STATE_DIR"
    printf '%s\n' 'Second screen skipped: set display_host and display_url' > "$STATE_DIR/display-note"
  elif display_reachable && display_lid_open && display_show_window "$DISPLAY_URL"; then
    rm -f "$STATE_DIR/display-note"
  else
    mkdir -p "$STATE_DIR"
    printf '%s\n' 'Second screen skipped: unreachable, lid closed or display unavailable' > "$STATE_DIR/display-note"
  fi
}

pid_file_for() {
  printf '%s/%s.pid\n' "$STATE_DIR" "$1"
}

command_for_pid() {
  ps -p "$1" -o command= 2>/dev/null || true
}

is_owned_running() {
  local component=$1 expected=$2 pid_file pid command
  pid_file=$(pid_file_for "$component")
  [ -f "$pid_file" ] || return 1
  pid=$(sed -n '1p' "$pid_file")
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  command=$(command_for_pid "$pid")
  [[ "$command" == *"$FM_CALL_BIN/$expected"* ]]
}

# Only the desk views are linked here, so a home can serve this one folder
# (for a phone) without ever serving the transcript.
ensure_public_dir() {
  local name
  mkdir -p "$PUBLIC_DIR"
  for name in glance.html desk.md notes.html; do
    [ -L "$PUBLIC_DIR/$name" ] || ln -s "../$name" "$PUBLIC_DIR/$name"
  done
}

write_idle_glance() {
  local output="$GLANCE.tmp.$$" updated last_notes=''
  updated=$(date '+%H:%M')
  if [ -s "$DATA_DIR/notes.html" ]; then last_notes='<p><a style="color:#77d5ff" href="notes.html">Notes from the last call</a></p>'; fi
  cat > "$output" <<EOF
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta http-equiv="refresh" content="20"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Live Call Desk</title>
<style>body{margin:0;background:#090d12;color:#f4f7fb;font:24px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}main{max-width:900px;margin:12vh auto;padding:28px}h1{font-size:56px;margin:0 0 14px}p{color:#aab7c8}.card{background:#141b24;border:1px solid #293547;border-radius:16px;padding:28px}</style>
</head><body><main><div class="card"><h1>Live Call Desk</h1><p>Updated $updated · refresh 20s</p><p>Not recording. Recording starts only after everyone on the call has agreed.</p>$last_notes</div></main></body></html>
EOF
  mv "$output" "$GLANCE"
}

write_idle_desk() {
  local output="$DESK.tmp.$$"
  cat > "$output" <<'EOF'
# Live Call Desk

Not recording. Recording starts only after everyone on the call has agreed.
EOF
  mv "$output" "$DESK"
}

prepare_views() {
  mkdir -p "$DATA_DIR" "$ARCHIVE_DIR"
  [ -f "$GLANCE" ] || write_idle_glance
  [ -f "$DESK" ] || write_idle_desk
  ensure_public_dir
}

status_component() {
  local component=$1 expected=$2 pid_file pid command
  pid_file=$(pid_file_for "$component")
  if is_owned_running "$component" "$expected"; then
    pid=$(sed -n '1p' "$pid_file")
    printf '%-10s running (pid %s)\n' "$component" "$pid"
    return 0
  fi
  if [ -f "$pid_file" ]; then
    pid=$(sed -n '1p' "$pid_file")
    command=$(command_for_pid "$pid")
    if [ -n "$command" ]; then
      printf '%-10s not owned (pid %s now belongs to: %s)\n' "$component" "$pid" "$command"
    else
      printf '%-10s stopped (stale pid file)\n' "$component"
    fi
  else
    printf '%-10s stopped\n' "$component"
  fi
}

# A call is started from start until stop has stopped its parts, even if they
# have since died.
any_started() {
  [ -e "$(pid_file_for captions)" ] || [ -e "$(pid_file_for mic)" ] || [ -e "$(pid_file_for digest)" ]
}

clear_pid_files() {
  rm -f "$(pid_file_for captions)" "$(pid_file_for mic)" "$(pid_file_for digest)"
}

call_in_place() {
  [ -s "$TRANSCRIPT" ] || [ -s "$DIGEST" ] || [ -s "$LIVE_ITEMS" ] || [ -e "$CALL_STAMP" ]
}

stamp_time() {
  printf '%s-%s-%s %s:%s:%s\n' "${1:0:4}" "${1:4:2}" "${1:6:2}" "${1:9:2}" "${1:11:2}" "${1:13:2}"
}

any_running() {
  is_owned_running captions fm-call-captions.sh ||
    is_owned_running mic fm-call-mic.sh ||
    is_owned_running digest fm-call-digest.sh
}

refuse_while_recording() {
  if any_running; then
    printf 'companion: stop the recording before %s\n' "$1" >&2
    exit 1
  fi
}

# Route the system output through the multi-output device while recording, so
# the call audio also reaches the loopback input; an empty setting never
# switches.
prepare_loopback_output() {
  local current
  [ -n "$MULTI_OUTPUT" ] || return 0
  mkdir -p "$STATE_DIR"
  if [ ! -x "$SWITCH_AUDIO_BIN" ] || ! "$SWITCH_AUDIO_BIN" -a -t output | grep -Fxq "$MULTI_OUTPUT"; then
    printf 'Far side not captured: no %s output\n' "$MULTI_OUTPUT" > "$STATE_DIR/far-side-note"
    return 0
  fi
  current=$("$SWITCH_AUDIO_BIN" -c -t output)
  printf '%s\n' "$current" > "$PREVIOUS_OUTPUT"
  "$SWITCH_AUDIO_BIN" -s "$MULTI_OUTPUT" -t output >/dev/null
  rm -f "$STATE_DIR/far-side-note"
}

restore_loopback_output() {
  local previous
  [ -s "$PREVIOUS_OUTPUT" ] || return 0
  previous=$(cat "$PREVIOUS_OUTPUT")
  if [ -x "$SWITCH_AUDIO_BIN" ]; then "$SWITCH_AUDIO_BIN" -s "$previous" -t output >/dev/null || return 1; fi
  rm -f "$PREVIOUS_OUTPUT"
}

start_component() {
  local component=$1 script=$2 log=$3
  shift 3
  nohup "$FM_CALL_BIN/$script" "$@" >> "$LOG_DIR/$log" 2>&1 &
  printf '%s\n' "$!" > "$(pid_file_for "$component")"
}

transcript_note() {
  mkdir -p "$DATA_DIR"
  printf '# %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$1" >> "$TRANSCRIPT"
}

has_transcript_lines() {
  [ -s "$TRANSCRIPT" ] && grep -Eq '^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]' "$TRANSCRIPT"
}

start_companion() {
  local source=$1 page=${2:-}
  if any_running; then
    printf 'companion: already running; use fm-call-companion.sh status or stop first\n' >&2
    exit 1
  fi
  clear_pid_files
  ! call_in_place || reset_companion
  prepare_views
  mkdir -p "$STATE_DIR"
  date '+%Y%m%d-%H%M%S' > "$CALL_STAMP"
  transcript_note "recording started ($source) after everyone on the call agreed to be recorded"

  if [ "$source" = captions ]; then
    start_component captions fm-call-captions.sh captions.log --page "$page"
  else
    prepare_loopback_output
    start_component mic fm-call-mic.sh mic.log
  fi
  start_component digest fm-call-digest.sh digest.log
  sleep 0.5
  if [ "$source" = captions ]; then
    is_owned_running captions fm-call-captions.sh || {
      printf 'companion: caption reader exited during startup; see %s/captions.log\n' "$LOG_DIR" >&2
      stop_component digest fm-call-digest.sh
      transcript_note 'recording stopped: the caption reader failed to start'
      exit 1
    }
  else
    is_owned_running mic fm-call-mic.sh || {
      printf 'companion: microphone reader exited during startup; see %s/mic.log\n' "$LOG_DIR" >&2
      stop_component digest fm-call-digest.sh
      restore_loopback_output || true
      transcript_note 'recording stopped: the microphone reader failed to start'
      exit 1
    }
  fi
  is_owned_running digest fm-call-digest.sh || {
    printf 'companion: digest loop exited during startup; see %s/digest.log\n' "$LOG_DIR" >&2
    if [ "$source" = captions ]; then
      stop_component captions fm-call-captions.sh
    else
      stop_component mic fm-call-mic.sh
      restore_loopback_output || true
    fi
    transcript_note 'recording stopped: the live desk failed to start'
    exit 1
  }
  "$OPEN_BIN" "$GLANCE" || true
  [ -z "$DISPLAY_HOST" ] || show_desk_display
  printf 'companion: started %s source and digest loop\n' "$source"
  printf 'companion: glance page %s\n' "$GLANCE"
}

stop_component() {
  local component=$1 expected=$2 pid_file pid command attempt attempts
  pid_file=$(pid_file_for "$component")
  [ -f "$pid_file" ] || return 0
  pid=$(sed -n '1p' "$pid_file")
  if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
    printf 'companion: ignoring invalid %s pid file\n' "$component" >&2
    rm -f "$pid_file"
    return 0
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$pid_file"
    return 0
  fi
  command=$(command_for_pid "$pid")
  if [[ "$command" != *"$FM_CALL_BIN/$expected"* ]]; then
    printf 'companion: refusing to kill pid %s; it is not this companion\x27s %s process\n' "$pid" "$component" >&2
    return 1
  fi
  kill "$pid"
  attempts=$((STOP_TIMEOUT_SECONDS * 10))
  for ((attempt = 0; attempt < attempts; attempt += 1)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    printf 'companion: %s pid %s did not stop within %ss after SIGTERM\n' "$component" "$pid" "$STOP_TIMEOUT_SECONDS" >&2
    return 1
  fi
  rm -f "$pid_file"
}

# Authoritative notes from the whole transcript of call <stamp>; a failure never
# blocks stop or reset. They are written under the logs and land with their
# call: in place, in the archive if it was archived meanwhile, or nowhere if it
# was deleted meanwhile.
write_final_notes() {
  local stamp=$1 call_date out status=0 notes_file
  [ "$FINAL_NOTES" = 1 ] || return 0
  has_transcript_lines || return 0
  if [ -n "$stamp" ]; then call_date="${stamp:0:4}-${stamp:4:2}-${stamp:6:2}"; else call_date=$(date '+%Y-%m-%d'); fi
  printf 'companion: writing end-of-call notes from the full transcript (a few minutes)\n'
  out=$(mktemp -d "$LOG_DIR/notes.XXXXXX")
  "$PYTHON_BIN" "$NOTES_SCRIPT" --transcript "$TRANSCRIPT" --live-items "$LIVE_ITEMS" --out-dir "$out" \
    --date "$call_date" --local-name "$LOCAL_SPEAKER" --model "$NOTES_MODEL" >> "$LOG_DIR/final-notes.log" 2>&1 || status=1
  if [ "$(fm_call_stamp || true)" = "$stamp" ]; then
    mkdir -p "$DATA_DIR"
    for notes_file in $NOTES_FILES; do [ ! -f "$out/$notes_file" ] || mv "$out/$notes_file" "$DATA_DIR/$notes_file"; done
    if [ "$status" -eq 0 ]; then
      printf 'companion: end-of-call notes at %s/notes.md and notes.html\n' "$DATA_DIR"
    else
      printf 'companion: end-of-call notes failed; see %s/final-notes.log, then rerun fm-call-companion.sh notes\n' "$LOG_DIR" >&2
    fi
  elif [ -n "$stamp" ] && [ -n "$(find "$ARCHIVE_DIR" -maxdepth 1 -type f -name "$stamp-*" 2>/dev/null)" ]; then
    for notes_file in $NOTES_FILES; do [ ! -f "$out/$notes_file" ] || mv "$out/$notes_file" "$ARCHIVE_DIR/$stamp-$notes_file"; done
    if [ "$status" -eq 0 ]; then
      printf 'companion: call %s was archived while its notes were written; they are in the archive\n' "$stamp"
    else
      printf 'companion: end-of-call notes for archived call %s failed; see %s/final-notes.log\n' "$stamp" "$LOG_DIR" >&2
    fi
  else
    printf 'companion: the call was deleted while its notes were written; discarded them\n'
  fi
  rm -rf "$out"
  return "$status"
}

stop_parts() {
  local failed=0
  stop_component captions fm-call-captions.sh || failed=1
  stop_component mic fm-call-mic.sh || failed=1
  stop_component digest fm-call-digest.sh || failed=1
  return "$failed"
}

# Notes newer than the last archive belong to the call in place.
remove_unarchived_notes() {
  local notes_file
  for notes_file in $NOTES_FILES; do
    if [ -f "$DATA_DIR/$notes_file" ] && [ "$DATA_DIR/$notes_file" -nt "$ARCHIVE_DIR/.last-notes-copy" ]; then rm -f "$DATA_DIR/$notes_file"; fi
  done
}

stop_all() {
  local failed=0 was_running=false stamp notes_written=false
  stamp=$(fm_call_stamp) || stamp=
  if [ -n "$stamp" ] && any_started; then was_running=true; fi
  stop_parts || failed=1
  [ "$(fm_call_stamp || true)" = "$stamp" ] || was_running=false
  if [ "$was_running" = true ]; then
    transcript_note 'recording stopped'
    "$FM_CALL_BIN/fm-call-digest.sh" --final-batch || failed=1
  fi
  restore_loopback_output || failed=1
  hide_desk_display || true
  if [ "$was_running" = true ]; then
    ! write_final_notes "$stamp" || notes_written=true
    if [ "$notes_written" = true ] && [ "$(fm_call_stamp || true)" = "$stamp" ] && ! any_running; then reset_companion; fi
  fi
  [ "$failed" -eq 0 ] || exit 1
  printf 'companion: stopped\n'
}

reset_companion() {
  local stamp archived=false notes_file
  refuse_while_recording reset
  clear_pid_files
  if ! call_in_place; then
    printf 'companion: reset; there is no call in place to archive\n'
    return 0
  fi
  mkdir -p "$ARCHIVE_DIR"
  stamp=$(fm_call_stamp) || stamp=$(date '+%Y%m%d-%H%M%S')
  if [ -s "$TRANSCRIPT" ]; then
    mv "$TRANSCRIPT" "$ARCHIVE_DIR/$stamp-transcript.txt"
    archived=true
  fi
  if [ -s "$DIGEST" ]; then
    mv "$DIGEST" "$ARCHIVE_DIR/$stamp-digest.json"
    archived=true
  fi
  if [ -s "$DESK" ]; then
    mv "$DESK" "$ARCHIVE_DIR/$stamp-desk.md"
    archived=true
  fi
  if [ -s "$LIVE_ITEMS" ]; then
    mv "$LIVE_ITEMS" "$ARCHIVE_DIR/$stamp-live-items.jsonl"
    archived=true
  fi
  # The last call's notes stay in place (the desk links them) and are copied to the archive.
  for notes_file in $NOTES_FILES; do
    if [ -s "$DATA_DIR/$notes_file" ] && [ "$DATA_DIR/$notes_file" -nt "$ARCHIVE_DIR/.last-notes-copy" ]; then
      cp -p "$DATA_DIR/$notes_file" "$ARCHIVE_DIR/$stamp-$notes_file"
      archived=true
    fi
  done
  touch "$ARCHIVE_DIR/.last-notes-copy"
  rm -f "$CALL_STAMP"
  : > "$TRANSCRIPT"
  write_idle_glance
  write_idle_desk
  if [ "$archived" = true ]; then
    printf 'companion: archived transcript, digest, desk, live items, and notes with stamp %s, then reset\n' "$stamp"
  else
    printf 'companion: reset; the call in place had nothing to archive\n'
  fi
}

list_archive() {
  [ -d "$ARCHIVE_DIR" ] || return 0
  find "$ARCHIVE_DIR" -maxdepth 1 -type f -name '[0-9]*-[0-9]*-*' -print | sed -E 's#^.*/([0-9]{8}-[0-9]{6})-.*$#\1#' | sort -u
}

# Logs can hold call text (a rejected digest is kept there for inspection), so
# every delete clears them along with the call they came from.
delete_logs() {
  rm -rf "$LOG_DIR" "$AUDIO_DIR"
  mkdir -p "$LOG_DIR"
}

# Drop one call's lines, tagged with its stamp, from the cross-call logs.
forget_call_lines() {
  local stamp=$1 log
  for log in $CALL_LOGS; do
    [ -f "$STATE_DIR/$log" ] || continue
    awk -F '\t' -v stamp="$stamp" '$1 != stamp' "$STATE_DIR/$log" > "$STATE_DIR/$log.tmp.$$"
    mv "$STATE_DIR/$log.tmp.$$" "$STATE_DIR/$log"
  done
}

delete_in_place() {
  local stamp
  stamp=$(fm_call_stamp) || stamp=
  clear_pid_files
  rm -f "$TRANSCRIPT" "$DIGEST" "$DESK" "$GLANCE" "$LIVE_ITEMS"
  remove_unarchived_notes
  [ -z "$stamp" ] || forget_call_lines "$stamp"
  rm -f "$CALL_STAMP"
  delete_logs
  prepare_views
  if [ -n "$stamp" ]; then
    printf 'companion: deleted call %s (started %s), which was not archived yet, and the logs\n' "$stamp" "$(stamp_time "$stamp")"
  else
    printf 'companion: deleted the unstamped call in place and the logs\n'
  fi
}

delete_archived() {
  local stamp=$1 count notes_file notes_removed=false
  count=$(find "$ARCHIVE_DIR" -maxdepth 1 -type f -name "$stamp-*" 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -gt 0 ] || { printf 'companion: no archived call %s\n' "$stamp" >&2; exit 1; }
  for notes_file in $NOTES_FILES; do
    if [ -f "$DATA_DIR/$notes_file" ] && cmp -s "$ARCHIVE_DIR/$stamp-$notes_file" "$DATA_DIR/$notes_file"; then
      rm -f "$DATA_DIR/$notes_file"
      notes_removed=true
    fi
  done
  find "$ARCHIVE_DIR" -maxdepth 1 -type f -name "$stamp-*" -exec rm -f {} +
  forget_call_lines "$stamp"
  [ "$notes_removed" = false ] || write_idle_glance
  delete_logs
  printf 'companion: deleted archived call %s (started %s; %s files) and the logs\n' "$stamp" "$(stamp_time "$stamp")" "$count"
}

delete_latest() {
  local latest
  if any_running; then
    stop_parts || { printf 'companion: could not stop the recording; nothing was deleted\n' >&2; exit 1; }
    restore_loopback_output || true
    hide_desk_display || true
    printf 'companion: stopped the recording without writing notes\n'
  fi
  if call_in_place; then
    delete_in_place
    return
  fi
  latest=$(list_archive | tail -n 1)
  [ -n "$latest" ] || { printf 'companion: there is no call to delete\n' >&2; exit 1; }
  delete_archived "$latest"
}

delete_stamp() {
  [[ "$1" =~ ^[0-9]{8}-[0-9]{6}$ ]] || { printf 'companion: stamp must look like 20261018-153000; see fm-call-companion.sh list\n' >&2; exit 2; }
  refuse_while_recording delete
  delete_archived "$1"
}

delete_all() {
  refuse_while_recording delete
  clear_pid_files
  rm -rf "$DATA_DIR"
  rm -f "$LIVE_ITEMS" "$CALL_STAMP" "$STATE_DIR/triggers.log" "$STATE_DIR/decisions.log" "$STATE_DIR/decisions-batch.log" "$STATE_DIR/actions.log"
  delete_logs
  printf 'companion: deleted every call, the archive, and the decision, spoken-order and action logs\n'
}

main() {
  mkdir -p "$LOG_DIR"
  case "${1:-}" in
    start)
      if [ "$#" -eq 3 ] && [ "$2" = --mic ] && [ "$3" = --everyone-agreed ]; then
        start_companion mic
      elif [ "$#" -eq 4 ] && [ "$2" = --page ] && [ "$4" = --everyone-agreed ]; then
        [[ "$3" =~ ^[0-9]+$ ]] || { printf 'companion: page id must be numeric\n' >&2; exit 2; }
        start_companion captions "$3"
      elif [ "${*: -1}" != --everyone-agreed ]; then
        printf 'companion: not recording. Ask everyone on the call first; once every person has agreed to be recorded, run the same command with --everyone-agreed at the end\n' >&2
        exit 2
      else
        usage
        exit 2
      fi
      ;;
    status)
      [ "$#" -eq 1 ] || { usage; exit 2; }
      status_component captions fm-call-captions.sh
      status_component mic fm-call-mic.sh
      status_component digest fm-call-digest.sh
      ;;
    desk)
      { [ "$#" -eq 1 ] || { [ "$#" -eq 2 ] && [ "$2" = --display ]; }; } || { usage; exit 2; }
      prepare_views
      "$OPEN_BIN" "$GLANCE"
      [ "${2:-}" != --display ] || show_desk_display
      printf 'companion: opened %s\n' "$GLANCE"
      ;;
    stop)
      [ "$#" -eq 1 ] || { usage; exit 2; }
      stop_all
      ;;
    reset)
      [ "$#" -eq 1 ] || { usage; exit 2; }
      reset_companion
      ;;
    notes)
      [ "$#" -eq 1 ] || { usage; exit 2; }
      FINAL_NOTES=1 write_final_notes "$(fm_call_stamp || true)"
      ;;
    list)
      [ "$#" -eq 1 ] || { usage; exit 2; }
      list_archive
      ;;
    delete)
      case "$#:${2:-}" in
        1:) delete_latest ;;
        2:--all) delete_all ;;
        2:*) delete_stamp "$2" ;;
        *) usage; exit 2 ;;
      esac
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage
      exit 2
      ;;
  esac
}

main "$@"
