#!/usr/bin/env bash
# Install, run and serve the Windows desk floater from inside WSL 2.
#
# Usage:
#   fm-desk-floater-windows.sh install [--no-start]
#   fm-desk-floater-windows.sh start
#   fm-desk-floater-windows.sh stop
#   fm-desk-floater-windows.sh status
#   fm-desk-floater-windows.sh uninstall
#   fm-desk-floater-windows.sh version
#   fm-desk-floater-windows.sh bridge <verb> [args...]
#   fm-desk-floater-windows.sh --help
#
# WHY: a Windows teammate runs Starship inside WSL 2 (ONBOARDING-windows.md)
# while the microphone, the screen, the speakers and every other app are on
# the Windows side. The Windows floater (desk-floater-windows/) is a thin
# native shell for those: the floating control, the hotkeys, recording,
# screenshots, playback and pasting into the focused Windows app. Everything
# else stays here in WSL and is the same code the Mac floater uses:
# bin/fm-deepgram-stt.sh transcribes, bin/fm-desk-voice.sh delivers into the
# primary chat (with all of its pane checks, the draft stash and the mailbox
# fallback), keeps unsent recordings and stores screenshots, and
# bin/fm-speak.sh speaks replies. See docs/desk-floater-windows.md.
#
# install builds the floater on the Windows side with the C# compiler that
# ships with .NET Framework 4 in every Windows 10 and 11
# (%SystemRoot%\Microsoft.NET\Framework64\v4.0.30319\csc.exe), so nothing is
# downloaded, nothing needs admin rights and no developer tools are installed.
# It copies desk-floater-windows/*.cs to %LOCALAPPDATA%\Starship\Floater\src,
# compiles StarshipFloater.exe beside it, writes floater.ini (this WSL
# distribution, this code root and this home, and the source version), adds
# a per-user "Run" registry value so the floater starts with Windows, records
# the install in this home's state/desk-floater-windows/install, and starts
# it, asking a floater already running to quit first. The running exe is
# renamed aside, which Windows allows, so a reinstall never needs it stopped
# by hand; --no-start leaves a running floater running the old build until
# it restarts. install also adds "set -g focus-events on" to ~/.tmux.conf
# (marked, once, unless a focus-events line is there already), because tmux
# tracks which terminal has focus only for clients that attach while that
# option is on; dictate below relies on it. Running install again after an update is the
# update path, and the floater does it by itself: it compares its own source
# version with `version` when it starts and every hour, and reinstalls and
# restarts itself when they differ.
#
# start and stop start or quit the installed floater. status prints
#   installed: yes|no
#   version: current|stale|unknown
#   running: yes|no|unknown
# uninstall quits it, removes the "Run" value, the install folder, the
# install record and the marked ~/.tmux.conf lines. version prints the source version, a short hash of the
# floater's C# sources.
#
# bridge is how the Windows floater reaches this home; nothing else calls it.
# Each verb prints one tab-separated outcome line (retry and recover may print
# several), exit 0, and exit 1 when nothing was done:
#   transcribe <id> <firstmate|dictate>   standard input is a WAV recording.
#       It is saved as state/desk-voice/recording/<id>-<purpose>.wav and
#       transcribed with bin/fm-deepgram-stt.sh. <id> is the floater's own
#       recording id; an id already received prints "known TAB <id>" and does
#       nothing, so a recording handed over twice is never sent twice.
#         text TAB <recording> TAB <words>   words heard; a talk-to-Firstmate
#                                            recording stays until deliver;
#                                            a dictation's is removed and
#                                            <recording> is "-"
#         saved TAB <path>                  no words, kept as bin/fm-desk-voice.sh
#                                           keep does (transcription failed on
#                                           a recording of at least 0.5 s, or
#                                           no speech in at least 2 s)
#         nothing TAB transcribe-failed|no-speech   too short to keep; removed
#   adopt <id> <firstmate|dictate>   standard input is a WAV recording that
#       could not reach this home when it was made; it is kept straight away
#       (saved TAB <path>, or known TAB <id>) for retry.
#   deliver [--recording <path>]... [--image <png>]...   standard input is the
#       words, possibly none. Sends them with the images through
#       bin/fm-desk-voice.sh send and prints its outcome line (sent:,
#       sent-unconfirmed: or mailbox:), removing the recordings. When the send
#       fails the recordings are kept: "saved TAB <path>" each, then "failed".
#   dictate   standard input is dictated words. Sends them with
#       bin/fm-desk-voice.sh send --front-focused and prints its outcome line;
#       "not-in-front" means the floater pastes the words instead. That check
#       reads tmux's record of which client's terminal has focus, which tmux
#       keeps only for clients that attached while its focus-events option was
#       on, so dictate and hello turn it on in a running tmux server where it
#       is off and record when in the server option @fm-focus-since. Where it
#       is on already and nothing recorded when, they record the server's
#       start if a "set -g focus-events on" line in ~/.tmux.conf is no newer
#       than that start, and now otherwise. Clients attached before that time
#       count once they reattach (bin/fm-desk-voice.sh shown_focused).
#   hello   the floater's check-in when it starts and every hour: turns tmux
#       focus-events on as above and prints "version TAB <source version>".
#   shot   standard input is a PNG; prints the stored path
#       (bin/fm-desk-voice.sh shot --stdin).
#   recover   saves recordings a stopped floater left in
#       state/desk-voice/recording/ (older than 10 s), as the Mac floater does
#       at launch, then prints "retry TAB <path> TAB <attempts>" for each saved
#       talk-to-Firstmate recording.
#   retry <path>   bin/fm-desk-voice.sh retry <path>.
#   speak <args...>   bin/fm-speak.sh <args...>.
#   version   as version above.
# The floater passes this home as FM_HOME through WSLENV. Its calls start
# without a login shell, so Homebrew's and ~/.local's bin folders are put on
# PATH here when they exist.
#
# Environment: FM_HOME selects the home (default: this code root).
# FM_DESK_FLOATER_WINDOWS_NAME overrides the "Run" value name (tests).
#
# Exit: 0 ok, 1 failure, 2 bad usage.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$ROOT}"
STATE="$FM_HOME/state"
SRC="$ROOT/desk-floater-windows"
SOURCES=(Logic.cs Floater.cs)
RECORD_DIR="$STATE/desk-floater-windows"
RECORD="$RECORD_DIR/install"
RECORDING="$STATE/desk-voice/recording"
RECEIVED="$STATE/desk-voice/windows-received"
DESK="$SCRIPT_DIR/fm-desk-voice.sh"
STT="$SCRIPT_DIR/fm-deepgram-stt.sh"
SPEAK="$SCRIPT_DIR/fm-speak.sh"
EXE=StarshipFloater.exe
RUN_KEY='HKCU\Software\Microsoft\Windows\CurrentVersion\Run'
RUN_NAME="${FM_DESK_FLOATER_WINDOWS_NAME:-StarshipFloater}"
TMUX_CONF="$HOME/.tmux.conf"
TMUX_CONF_MARK="# Added by Starship's Windows desk floater (bin/fm-desk-floater-windows.sh): dictation tells when the first mate's chat is in front."

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

note() {
  printf 'fm-desk-floater-windows: %s\n' "$*" >&2
}

die() {
  note "$*"
  exit 1
}

refuse() {
  note "$*"
  exit 2
}

# --- Windows side -------------------------------------------------------------

# Windows' own programs are off PATH when WSL is set not to append Windows'
# folders to it.
windows_path() {
  if ! command -v cmd.exe >/dev/null 2>&1 && [ -f /mnt/c/Windows/System32/cmd.exe ]; then
    PATH="$PATH:/mnt/c/Windows/System32"
  fi
}

need_wsl() {
  [ -n "${WSL_DISTRO_NAME:-}" ] \
    || die "run this inside WSL 2 (your Ubuntu window); the Windows floater is installed from there"
  windows_path
  if ! command -v cmd.exe >/dev/null 2>&1 || ! command -v wslpath >/dev/null 2>&1; then
    die "cannot reach Windows from WSL: cmd.exe or wslpath is missing (is WSL interop switched off?)"
  fi
}

# A Windows environment variable, or fail when Windows does not have it.
# cmd.exe is started from a Windows folder when one is mounted, since it
# refuses a WSL working folder with a warning.
win_env() {  # <name>
  local value
  value=$(cd /mnt/c 2>/dev/null || cd /; cmd.exe /d /c "echo %$1%" 2>/dev/null | tr -d '\r' | tail -n 1) \
    || return 1
  [ -n "$value" ] && [ "$value" != "%$1%" ] || return 1
  printf '%s\n' "$value"
}

source_version() {
  local f
  for f in "${SOURCES[@]}"; do
    [ -f "$SRC/$f" ] || die "missing floater source: $SRC/$f"
  done
  (cd "$SRC" && cat "${SOURCES[@]}") | python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:16])'
}

# Reads the install record into WIN_DIR (Windows form) and LIN_DIR (WSL form).
read_record() {
  local key value
  WIN_DIR=''
  LIN_DIR=''
  [ -f "$RECORD" ] || return 1
  while IFS='=' read -r key value; do
    case "$key" in
      windows_dir) WIN_DIR=$value ;;
      linux_dir) LIN_DIR=$value ;;
    esac
  done < "$RECORD"
  [ -n "$WIN_DIR" ] && [ -n "$LIN_DIR" ]
}

floater_running() {
  tasklist.exe /FI "IMAGENAME eq $EXE" /NH 2>/dev/null | tr -d '\r' | grep -qi "^$EXE"
}

start_floater() {  # <linux dir> <windows dir>
  # PowerShell's Start-Process detaches the floater from this WSL session and
  # returns at once; cmd.exe's start keeps WSL waiting while the floater runs.
  local ps=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe dir
  command -v powershell.exe >/dev/null 2>&1 && ps=powershell.exe
  dir=${2//\'/\'\'}
  (cd "$1" && "$ps" -NoProfile -NonInteractive -Command \
    "Start-Process -FilePath '$dir\\$EXE' -WorkingDirectory '$dir'") </dev/null >/dev/null 2>&1 \
    || die "could not start the floater ($1/$EXE)"
}

quit_floater() {  # <linux dir>
  [ -f "$1/$EXE" ] || return 0
  "$1/$EXE" --quit >/dev/null 2>&1 || true
}

install() {
  local start=true win_local sysroot csc win_dir lin_dir version log f
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --no-start) start=false; shift ;;
      *) refuse "unexpected argument: $1" ;;
    esac
  done
  need_wsl
  version=$(source_version)
  win_local=$(win_env LOCALAPPDATA) || die "cannot read the Windows LOCALAPPDATA folder"
  sysroot=$(win_env SystemRoot) || die "cannot read the Windows SystemRoot folder"
  csc="$(wslpath -u "$sysroot")/Microsoft.NET/Framework64/v4.0.30319/csc.exe"
  [ -f "$csc" ] || die "the C# compiler of .NET Framework 4 is missing ($csc); Windows 10 and 11 include it"
  win_dir="$win_local\\Starship\\Floater"
  lin_dir=$(wslpath -u "$win_dir") || die "cannot map $win_dir into WSL"
  mkdir -p "$lin_dir/src" || die "cannot create $lin_dir"
  rm -f "$lin_dir"/src/*.cs
  for f in "${SOURCES[@]}"; do
    cp "$SRC/$f" "$lin_dir/src/$f" || die "cannot copy $f to $lin_dir/src"
  done
  log="$lin_dir/build.log"
  rm -f "$lin_dir/StarshipFloater.new.exe"
  if ! (cd "$lin_dir" && "$csc" /nologo /target:winexe /optimize+ /codepage:65001 \
      /out:StarshipFloater.new.exe /r:System.Windows.Forms.dll /r:System.Drawing.dll \
      'src\Logic.cs' 'src\Floater.cs') > "$log" 2>&1 \
      || [ ! -f "$lin_dir/StarshipFloater.new.exe" ]; then
    sed 's/\r$//' "$log" >&2 2>/dev/null || true
    die "building the floater failed; the compiler's output is above and in $log"
  fi
  printf 'distro=%s\r\nroot=%s\r\nhome=%s\r\nversion=%s\r\n' \
    "$WSL_DISTRO_NAME" "$ROOT" "$FM_HOME" "$version" > "$lin_dir/floater.ini" \
    || die "cannot write $lin_dir/floater.ini"
  # A running exe cannot be replaced or deleted on Windows, but it can be
  # renamed aside; the copy left from the install before is removed first.
  rm -f "$lin_dir/StarshipFloater.old.exe" 2>/dev/null || true
  if [ -f "$lin_dir/$EXE" ]; then
    mv -f "$lin_dir/$EXE" "$lin_dir/StarshipFloater.old.exe" \
      || die "cannot move the old floater aside in $lin_dir"
  fi
  mv -f "$lin_dir/StarshipFloater.new.exe" "$lin_dir/$EXE" || die "cannot install $lin_dir/$EXE"
  reg.exe add "$RUN_KEY" /v "$RUN_NAME" /t REG_SZ /d "\"$win_dir\\$EXE\"" /f >/dev/null 2>&1 \
    || note "could not add the floater to Windows startup; start it with: bin/fm-desk-floater-windows.sh start"
  tmux_conf_add
  mkdir -p "$RECORD_DIR" || die "cannot create $RECORD_DIR"
  printf 'windows_dir=%s\nlinux_dir=%s\ndistro=%s\nversion=%s\n' \
    "$win_dir" "$lin_dir" "$WSL_DISTRO_NAME" "$version" > "$RECORD" || die "cannot write $RECORD"
  if [ "$start" = true ]; then
    # The floater runs one copy at a time, so the old one goes first.
    quit_floater "$lin_dir"
    start_floater "$lin_dir" "$win_dir"
    printf 'installed and started: %s\\%s\n' "$win_dir" "$EXE"
  else
    printf 'installed: %s\\%s\n' "$win_dir" "$EXE"
  fi
}

start() {
  need_wsl
  read_record || die "the Windows floater is not installed; run: bin/fm-desk-floater-windows.sh install"
  [ -f "$LIN_DIR/$EXE" ] || die "the floater is missing from $LIN_DIR; run install again"
  start_floater "$LIN_DIR" "$WIN_DIR"
  printf 'started\n'
}

stop() {
  need_wsl
  read_record || { printf 'not installed\n'; return 0; }
  quit_floater "$LIN_DIR"
  printf 'stopped\n'
}

status() {
  local installed=no version=unknown running=unknown built=''
  windows_path
  if read_record && [ -f "$LIN_DIR/$EXE" ]; then
    installed=yes
    built=$(sed -n 's/^version=//p' "$RECORD")
    if [ "$built" = "$(source_version)" ]; then version=current; else version=stale; fi
    if command -v tasklist.exe >/dev/null 2>&1; then
      if floater_running; then running=yes; else running=no; fi
    fi
  fi
  printf 'installed: %s\nversion: %s\nrunning: %s\n' "$installed" "$version" "$running"
}

# tmux reads focus-events from ~/.tmux.conf when it starts, so every client
# attaches with focus tracked; a focus-events line already there is the
# teammate's own and is left alone.
tmux_conf_add() {
  ! grep -Eq '^[[:space:]]*set(-option)?[[:space:]].*focus-events' "$TMUX_CONF" 2>/dev/null || return 0
  local lead=
  [ ! -s "$TMUX_CONF" ] || [ -z "$(tail -c 1 "$TMUX_CONF")" ] || lead=$'\n'
  printf '%s%s\nset -g focus-events on\n' "$lead" "$TMUX_CONF_MARK" >> "$TMUX_CONF" \
    || note "could not add focus-events to $TMUX_CONF; dictation will only paste"
}

tmux_conf_remove() {
  local kept
  grep -qxF "$TMUX_CONF_MARK" "$TMUX_CONF" 2>/dev/null || return 0
  if ! kept=$(awk -v mark="$TMUX_CONF_MARK" '$0 == mark { skip = 1; next } skip && $0 == "set -g focus-events on" { skip = 0; next } { skip = 0; print }' "$TMUX_CONF"); then
    note "could not tidy $TMUX_CONF"
    return 0
  fi
  if printf '%s' "$kept" | grep -q '[^[:space:]]'; then
    printf '%s\n' "$kept" > "$TMUX_CONF" || note "could not tidy $TMUX_CONF"
  else
    rm -f "$TMUX_CONF"
  fi
}

uninstall() {
  need_wsl
  if read_record; then
    quit_floater "$LIN_DIR"
    case "$LIN_DIR" in
      */Starship/Floater)
        rm -rf "$LIN_DIR" || note "could not remove $LIN_DIR"
        rmdir "${LIN_DIR%/Floater}" 2>/dev/null || true ;;
      *) note "not removing an unexpected install folder: $LIN_DIR" ;;
    esac
  fi
  reg.exe delete "$RUN_KEY" /v "$RUN_NAME" /f >/dev/null 2>&1 || true
  tmux_conf_remove
  rm -f "$RECORD"
  printf 'uninstalled\n'
}

# --- bridge (the floater's own calls) -----------------------------------------

bridge_path() {
  local dir
  for dir in "$HOME/.local/bin" "$HOME/.linuxbrew/bin" /home/linuxbrew/.linuxbrew/sbin /home/linuxbrew/.linuxbrew/bin; do
    [ -d "$dir" ] || continue
    case ":$PATH:" in
      *":$dir:"*) ;;
      *) PATH="$dir:$PATH" ;;
    esac
  done
  export PATH FM_HOME
}

check_id() {  # <id>
  printf '%s' "$1" | grep -Eqx '[A-Za-z0-9][A-Za-z0-9-]{7,63}' || refuse "not a recording id: $1"
}

check_purpose() {  # <purpose>
  case "$1" in
    firstmate|dictate) ;;
    *) refuse "purpose must be firstmate or dictate: $1" ;;
  esac
}

# Claims recording <id> and stores standard input as its audio. Prints the
# path, or returns 3 when the id was received before.
receive() {  # <id> <purpose>
  local dest tmp
  mkdir -p "$RECORDING" "$RECEIVED" || die "cannot create $RECORDING"
  chmod 700 "$STATE/desk-voice" "$RECORDING" "$RECEIVED" 2>/dev/null || true
  find "$RECEIVED" -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rmdir {} + 2>/dev/null || true
  # mkdir is the atomic claim, so two hand-overs of one id cannot both win.
  mkdir "$RECEIVED/$1" 2>/dev/null || return 3
  dest="$RECORDING/$1-$2.wav"
  tmp=$(mktemp "$RECORDING/.in.XXXXXX") || { rmdir "$RECEIVED/$1"; die "cannot create a recording file"; }
  if ! cat > "$tmp" || [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    rmdir "$RECEIVED/$1"
    die "no recording arrived on standard input"
  fi
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$dest" || { rm -f "$tmp"; rmdir "$RECEIVED/$1"; die "cannot store $dest"; }
  printf '%s\n' "$dest"
}

# Seconds of audio in a WAV file; an unreadable header is measured by size as
# 16 kHz, 16-bit mono, the format the floater records.
wav_seconds() {  # <file>
  python3 - "$1" <<'PY'
import os, sys, wave
path = sys.argv[1]
try:
    with wave.open(path, "rb") as w:
        rate, frames = w.getframerate(), w.getnframes()
        if rate > 0 and frames > 0:
            print(frames / rate)
            raise SystemExit(0)
except (wave.Error, EOFError, OSError):
    pass
print(max(0, os.path.getsize(path) - 44) / 32000)
PY
}

at_least() {  # <seconds> <limit>
  awk -v s="$1" -v l="$2" 'BEGIN { exit !(s + 0 >= l + 0) }'
}

keep_recording() {  # <path> <purpose> <reason>
  local saved
  saved=$("$DESK" keep --purpose "$2" --reason "$3" -- "$1") || return 1
  printf 'saved\t%s\n' "$saved"
}

bridge_transcribe() {
  local id purpose rec text rc=0 seconds
  [ "$#" -eq 2 ] || refuse "usage: bridge transcribe <id> <firstmate|dictate>"
  id=$1 purpose=$2
  check_id "$id"
  check_purpose "$purpose"
  rec=$(receive "$id" "$purpose") || {
    [ "$?" = 3 ] || exit 1
    printf 'known\t%s\n' "$id"
    return 0
  }
  text=$("$STT" "$rec") || rc=$?
  case "$text" in
    *[![:space:]]*) ;;
    *) text='' ;;
  esac
  if [ "$rc" = 0 ] && [ -n "$text" ]; then
    text=$(printf '%s' "$text" | tr '\t\r\n' '   ')
    if [ "$purpose" = dictate ]; then
      rm -f "$rec"
      rec=-
    fi
    printf 'text\t%s\t%s\n' "$rec" "$text"
    return 0
  fi
  seconds=$(wav_seconds "$rec")
  if [ "$rc" != 0 ] && at_least "$seconds" 0.5; then
    keep_recording "$rec" "$purpose" "transcription failed" || die "cannot keep $rec"
  elif [ "$rc" = 0 ] && at_least "$seconds" 2; then
    keep_recording "$rec" "$purpose" "no speech heard" || die "cannot keep $rec"
  else
    rm -f "$rec"
    if [ "$rc" != 0 ]; then
      printf 'nothing\ttranscribe-failed\n'
    else
      printf 'nothing\tno-speech\n'
    fi
  fi
}

bridge_adopt() {
  local id purpose rec
  [ "$#" -eq 2 ] || refuse "usage: bridge adopt <id> <firstmate|dictate>"
  id=$1 purpose=$2
  check_id "$id"
  check_purpose "$purpose"
  rec=$(receive "$id" "$purpose") || {
    [ "$?" = 3 ] || exit 1
    printf 'known\t%s\n' "$id"
    return 0
  }
  keep_recording "$rec" "$purpose" "the floater could not reach Ubuntu when it was recorded" \
    || die "cannot keep $rec"
}

# True when <path> is a recording directly inside the recording folder.
in_recording_dir() {  # <path>
  local dir real
  dir=$(cd -P "$(dirname "$1")" 2>/dev/null && pwd) || return 1
  real=$(cd -P "$RECORDING" 2>/dev/null && pwd) || return 1
  [ "$dir" = "$real" ] && [ -f "$1" ]
}

bridge_deliver() {
  local text out rec
  local -a recs=() args=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --recording)
        [ "$#" -ge 2 ] || refuse "--recording needs a path"
        in_recording_dir "$2" || refuse "not a recording in $RECORDING: $2"
        recs+=("$2")
        shift 2
        ;;
      --image)
        [ "$#" -ge 2 ] || refuse "--image needs a path"
        args+=(--image "$2")
        shift 2
        ;;
      *) refuse "unexpected argument: $1" ;;
    esac
  done
  text=$(cat)
  if out=$("$DESK" send --source desk-floater ${args[@]+"${args[@]}"} -- "$text") && [ -n "$out" ]; then
    for rec in ${recs[@]+"${recs[@]}"}; do
      rm -f "$rec"
    done
    printf '%s\n' "$out"
    return 0
  fi
  for rec in ${recs[@]+"${recs[@]}"}; do
    keep_recording "$rec" firstmate "delivery failed" || note "could not keep $rec"
  done
  printf 'failed\n'
}

# Windows Terminal reports focus to tmux only once focus-events is on.
# @fm-focus-since is left set either way: the server's start when
# ~/.tmux.conf turned focus-events on before the server started, else now.
tmux_focus_events() {
  local since started modified
  command -v tmux >/dev/null 2>&1 || return 0
  tmux list-sessions >/dev/null 2>&1 || return 0
  since=$(date +%s)
  if [ "$(tmux show-options -gv focus-events 2>/dev/null)" != on ]; then
    tmux set-option -g @fm-focus-since "$since" >/dev/null 2>&1 || true
    tmux set-option -g focus-events on >/dev/null 2>&1 || true
    return 0
  fi
  [ -z "$(tmux show-options -gqv @fm-focus-since 2>/dev/null)" ] || return 0
  started=$(tmux display-message -p '#{start_time}' 2>/dev/null) || started=''
  if grep -Eq '^[[:space:]]*set(-option)?[[:space:]]+(-[[:alpha:]]+[[:space:]]+)*focus-events[[:space:]]+on([[:space:]]|$)' "$TMUX_CONF" 2>/dev/null; then
    modified=$(stat -c %Y "$TMUX_CONF" 2>/dev/null || stat -f %m "$TMUX_CONF" 2>/dev/null) || modified=''
    case "$started,$modified" in
      ,*|*,|*[!0-9,]*) ;;
      *) [ "$modified" -gt "$started" ] || since=$started ;;
    esac
  fi
  tmux set-option -g @fm-focus-since "$since" >/dev/null 2>&1 || true
}

bridge_dictate() {
  local text out
  [ "$#" -eq 0 ] || refuse "usage: bridge dictate (words on standard input)"
  tmux_focus_events
  text=$(cat)
  out=$("$DESK" send --front-focused --source desk-floater-dictation -- "$text") || { printf 'failed\n'; return 0; }
  printf '%s\n' "$out"
}

bridge_recover() {
  local f now modified seconds path purpose attempts
  [ "$#" -eq 0 ] || refuse "usage: bridge recover"
  if [ -d "$RECORDING" ]; then
    now=$(date +%s)
    for f in "$RECORDING"/*.wav; do
      [ -f "$f" ] || continue
      modified=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || printf '%s' "$now")
      # A file still being written belongs to a hand-over under way.
      [ $((now - modified)) -ge 10 ] || continue
      seconds=$(wav_seconds "$f")
      case "$f" in
        *-dictate.wav) purpose=dictate ;;
        *) purpose=firstmate ;;
      esac
      if at_least "$seconds" 0.5; then
        "$DESK" keep --purpose "$purpose" --reason "the floater stopped before it was sent" -- "$f" >/dev/null \
          || note "could not keep $f"
      else
        rm -f "$f"
      fi
    done
  fi
  "$DESK" recordings | while IFS=$'\t' read -r path purpose attempts _; do
    [ "$purpose" = firstmate ] || continue
    printf 'retry\t%s\t%s\n' "$path" "$attempts"
  done
}

bridge() {
  [ "$#" -gt 0 ] || refuse "usage: bridge <verb> [args...]"
  bridge_path
  local verb=$1
  shift
  case "$verb" in
    transcribe) bridge_transcribe "$@" ;;
    adopt) bridge_adopt "$@" ;;
    deliver) bridge_deliver "$@" ;;
    dictate) bridge_dictate "$@" ;;
    shot) [ "$#" -eq 0 ] || refuse "usage: bridge shot (a PNG on standard input)"; exec "$DESK" shot --stdin ;;
    recover) bridge_recover "$@" ;;
    retry) [ "$#" -eq 1 ] || refuse "usage: bridge retry <path>"; exec "$DESK" retry "$1" ;;
    speak) exec "$SPEAK" "$@" ;;
    hello)
      [ "$#" -eq 0 ] || refuse "usage: bridge hello"
      tmux_focus_events
      printf 'version\t%s\n' "$(source_version)"
      ;;
    version) source_version ;;
    *) refuse "unknown bridge verb: $verb" ;;
  esac
}

main() {
  [ "$#" -gt 0 ] || { usage; exit 2; }
  case "$1" in
    --help|-h) usage; exit 0 ;;
    install) shift; install "$@" ;;
    start) shift; [ "$#" -eq 0 ] || refuse "usage: start"; start ;;
    stop) shift; [ "$#" -eq 0 ] || refuse "usage: stop"; stop ;;
    status) shift; [ "$#" -eq 0 ] || refuse "usage: status"; status ;;
    uninstall) shift; [ "$#" -eq 0 ] || refuse "usage: uninstall"; uninstall ;;
    version) shift; [ "$#" -eq 0 ] || refuse "usage: version"; source_version ;;
    bridge) shift; bridge "$@" ;;
    *) refuse "unknown command: $1" ;;
  esac
}

main "$@"
