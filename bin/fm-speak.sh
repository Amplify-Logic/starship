#!/usr/bin/env bash
# fm-speak.sh - speak one captain-facing outcome line out of this machine's
# own speaker, in the captain's spoken register.
#
# Usage:
#   fm-speak.sh [--dry-run] <text>
#   fm-speak.sh --stop
#   fm-speak.sh --repeat
#   fm-speak.sh --history
#   fm-speak.sh --replay <number>
#   fm-speak.sh --mute | --unmute | --muted
#   fm-speak.sh --help
#
# WHY THIS EXISTS: firstmate could already speak to the captain through the
# glasses loop, which owns the spoken register and enforces it in code. What it
# could not do is speak when he is at the desk without the glasses. This is that
# missing sink and nothing else: the same sentence, shaped by the same owner,
# handed to the local speaker instead of to the phone mailbox.
#
# WHAT THIS IS NOT:
#   - Not a second owner of the spoken register. The register - outcome first,
#     a few short sentences inside a bounded spoken length, never a URL, path
#     or id, and never a request for a spoken yes - is owned once by the
#     glasses project's announce entry point. This script shapes through that
#     owner, selects the desk budget below, and refuses to speak if it cannot
#     reach it, because speaking unshaped text would read a URL aloud, which
#     is the one thing the register forbids outright.
#   - Not an approval channel. The register owner refuses text that asks the
#     captain to decide, so money, outward and destructive choices structurally
#     cannot be put to him by voice. They stay in the terminal.
#   - Not a listener. Speech in is the desk floater / glasses path; this script
#     only speaks out. See docs/desk-floater.md for the push-to-talk inbox.
#   - Not proof anything was heard. Exit 0 means the shaped line was handed to
#     the speaker, never that audio was produced or that the captain heard it.
#
# OPT-IN: per home and per device, through private gitignored config/speak. With
# no `enabled = true` line this command is inert and silent, so cloning this
# repo, seeding a secondmate home, or adding a device never makes it talk.
# Config is `key = value` lines; unknown keys are refused rather than ignored.
#   enabled   true to arm this home (default false)
#   voice     optional `say` voice name (default: the system voice). Setting it
#             also selects `say` as the speaker, since Deepgram cannot speak in
#             it - see SPEAKER PREFERENCE below
#
# SPEAKER PREFERENCE: naming a voice picks the speaker, because only one of them
# can honour it. With a non-empty `voice` in config/speak the shaped line goes to
# macOS `say` in that voice; Deepgram's voice comes from DEEPGRAM_TTS_MODEL and
# ignores the key entirely, so a home that asked for a particular voice and got
# Deepgram would simply not be heard in it. With no voice named, DEEPGRAM_API_KEY
# in the environment or in this home's gitignored .env sends the line to Deepgram
# Aura first (bin/fm-deepgram-tts.sh). Either way the other speaker remains the
# fallback: Deepgram when there is no usable `say` binary, `say` when the key is
# absent or Deepgram fails. That choice is made once, before the handoff, and is
# never revisited afterwards: a speaker that fails once it has the line is not
# re-spoken through the other one, because paid synthesis is not this script's
# answer to a local speaker problem. A named voice is checked against the voices
# `say` actually has before the line is handed over, because `say` substitutes a
# voice it does not have and still exits 0 - so an unavailable voice would
# otherwise be neither heard as asked for nor reported anywhere. A voice this
# machine does not have is refused on stderr with exit 1, never quietly spoken in
# some other voice and never swapped to Deepgram. A voice confirmed once is
# remembered in state/speak-voice-confirmed, so only the first spoken line of a
# home pays for that question; renaming the voice in config/speak asks it again.
# The key is never logged, and this preference is about speech out only - the desk
# floater's ears still use the same key for Deepgram transcription
# (docs/desk-floater.md).
#
# DESK SPOKEN BOUND: the register owner's own default budget is tuned for the
# glasses, about eight seconds, and it truncates the shaped line before any
# speaker sees it. At the desk that lands mid-message on an ordinary two- or
# three-sentence outcome, so this script always points the register owner at
# docs/examples/desk-speak-register.toml via GLASSES_ANNOUNCE_CONFIG. It is the
# sink for the desk, not the glasses, so the budget follows the desk and not
# whichever speaker ends up playing the line: the same 16 seconds applies to
# Deepgram Aura and to macOS `say`. That example keeps the same URL/path/id and
# decision refusals and changes the budget only: 16 seconds and four sentences /
# about 41 words at 2.6 wps, into which bin/fm-claude-reply-speak.sh fits its
# spoken lead plus a short pointer to the screen. Two opt-outs remain.
# An already-set GLASSES_ANNOUNCE_CONFIG is never overridden, and
# FM_SPEAK_DEEPGRAM_REGISTER= (empty) keeps the glasses eight-second cut. That variable keeps its historical name because it is the
# published opt-out; it is not a Deepgram gate and never was one.
#
# NEVER BLOCKS THE CALLER'S TURN. The register call is bounded and waited on
# because its output is needed, so its bound is the worst case a captain-facing
# turn can be held: 15 seconds by default against an owner measured at about
# one. The configured-voice check runs beside that call under a bound of its own
# that starts when it does, so the two overlap rather than add up and the register
# call stays the worst case. The speaker call is bounded and detached, with its
# standard streams closed, so a caller that captures this script's output is
# never held open by audio that is still playing; its bound only stops a runaway
# from holding the audio device. A speech error downstream of that handoff is unobservable here
# by design.
#
# SERIAL PLAYBACK. Two calls in one turn used to overlap because each handoff
# returned before audio started. Playback is now serialized per home through
# state/.speak.lock, acquired by the detached speaker after that handoff: a
# second line waits for the current one to finish, then plays, and the calling
# turn is still not held open by audio. Dry-run and register refusals never
# take the lock. The lock serializes playback without ordering it: waiting
# speakers race for the free lock rather than queueing on it, so two lines
# handed off close together play one after the other but not necessarily in
# the order they were handed off. The wait is outside the speaker bound, so a
# queued line still gets its own playback budget after the line ahead of it
# ends. A dead holder is stolen by the portable lock helpers in
# bin/fm-wake-lib.sh, and a holder whose pid number has since been handed to
# an unrelated process is reclaimed on its recorded identity, so a killed
# speaker cannot silence the home for good; a holder that is genuinely still
# speaking is waited out. See hold_playback_lock.
#
# NEVER SHARES THE CALLER'S PROCESS GROUP. Detaching the speaker from the
# caller's streams is not enough to let a line finish: the speaker must also
# leave the caller's process group, or anything that reaps that group takes the
# audio with it. See detach_speaker for what that costs when it is missed.
#
# PLAYBACK CONTROLS, for the desk floater's buttons and any caller:
#   --stop    cuts short the line playing now and cancels every line that was
#             handed over before the stop and has not started yet, so a queued
#             line does not start talking the moment the captain silenced the
#             one ahead of it. A line handed over after the stop plays normally.
#             Each stop bumps state/speak-stop-generation; a speaker compares it
#             with the value it read when its call began, once it holds the
#             playback lock and again once its player is running, and a stop
#             kills the player named in state/.speak-player. Either the speaker
#             sees the new value or the stop sees the player, so no line slips
#             between the two.
#   --repeat  speaks the newest line in the reply history again (see REPLY
#             HISTORY below). Nothing spoken yet is exit 1.
#   --history prints the reply history newest first, one line per reply:
#             `<number> TAB <epoch seconds> TAB <text>`, with the text's own
#             tabs and line breaks turned into spaces. An empty history prints
#             nothing and exits 0.
#   --replay <number>
#             speaks the reply with that number from --history again. The
#             number belongs to the reply, not to its place in the list, so a
#             reply that arrives between reading the list and choosing from it
#             never shifts the choice onto a different line. A number that is
#             not kept (never used, or pruned) is exit 1.
#   --mute    makes every later line, repeats included, stay silent until
#             --unmute, and stops any line playing now. The flag is
#             state/speak-muted and is per home. A muted line is neither shaped
#             nor kept for --repeat, and the call still exits 0: muting affects
#             voice only, and the text reply stays the authoritative one.
#   --muted   prints `muted` or `unmuted`.
# Controls need no opt-in because they can only make this home quieter; --repeat
# and --replay are spoken lines and honour `enabled`, mute and --stop like any
# other, and print the text they replayed.
#
# REPLY HISTORY: every line handed to a speaker is kept in
# state/speak-history/<number>/, readable only by this account (directories
# 0700, files 0600), with the time it was spoken and the text as it was
# shaped, so a refused or unshaped sentence can never be replayed, and a replay
# is never shaped a second time. Numbers only grow; the newest 10 replies
# are kept and older ones are pruned whenever a new one is kept. A muted line is
# neither shaped nor kept. When Deepgram synthesized the line, its audio is kept
# beside the text, and a replay plays that audio straight away instead of paying
# for the network synthesis again - that wait is what made a replay slow. A reply
# with no kept audio (spoken by `say`, or kept before its audio was) is spoken
# through the ordinary speaker choice, and audio synthesized for that replay is
# kept for the next one. A named `voice` in config/speak always wins: kept
# Deepgram audio is not in that voice, so it is not played for such a home.
#
# Environment overrides, for tests and unusual layouts:
#   FM_SPEAK_SHAPER    register owner exposing the `--dry-run <text>` contract
#                      (default: $FM_HOME/projects/glasses-voice/bin/announce)
#   FM_SPEAK_SAY       speech binary (default: /usr/bin/say)
#   FM_SPEAK_DEEPGRAM_TTS
#                      Deepgram TTS helper (default: $ROOT/bin/fm-deepgram-tts.sh)
#   FM_SPEAK_DEEPGRAM_REGISTER
#                      GLASSES_ANNOUNCE_CONFIG path for the longer desk register,
#                      applied to every desk line (default:
#                      $ROOT/docs/examples/desk-speak-register.toml); set it
#                      empty to keep the glasses eight-second cut
#   FM_SPEAK_SHAPER_TIMEOUT
#                      bounded seconds for the waited-on register call
#                      (default 15)
#   FM_SPEAK_TIMEOUT   bounded seconds for the detached speaker (default 60)
#   FM_STATE_OVERRIDE  state directory holding the confirmed-voice memory,
#                      the per-home playback lock and the reply history
#                      (default: $FM_HOME/state)
#
# EXIT CODES (mirroring the register owner's own contract):
#   0  handed to the speaker, printed under --dry-run, or this home is not
#      opted in
#   1  cannot speak: the register owner is unreachable, failed or exceeded its
#      bound, the speech binary is missing, the configured voice is not one
#      this machine has, the state directory that holds the playback lock
#      cannot be created, the config is invalid, or a replay names a reply
#      that is not kept
#   2  refused by the register; nothing was spoken and the reason is reported
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONFIG_FILE="$CONFIG/speak"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
VOICE_CONFIRMED_FILE="$STATE/speak-voice-confirmed"
SPEAK_LOCK="$STATE/.speak.lock"
SPEAK_LOCK_HELD=false
MUTE_FILE="$STATE/speak-muted"
HISTORY_DIR="$STATE/speak-history"
HISTORY_KEEP=10
KEPT_AUDIO=
REPLAY_NUMBER=
STOP_GEN_FILE="$STATE/speak-stop-generation"
PLAYER_FILE="$STATE/.speak-player"
STOP_GEN_AT_START=0

DEFAULT_SHAPER_TIMEOUT=15
DEFAULT_SPEAKER_TIMEOUT=60

SHAPER="${FM_SPEAK_SHAPER:-$FM_HOME/projects/glasses-voice/bin/announce}"
SAY_BIN="${FM_SPEAK_SAY:-/usr/bin/say}"
DEEPGRAM_TTS="${FM_SPEAK_DEEPGRAM_TTS:-$ROOT/bin/fm-deepgram-tts.sh}"
# Default longer desk register; empty FM_SPEAK_DEEPGRAM_REGISTER disables the bump.
if [ "${FM_SPEAK_DEEPGRAM_REGISTER+x}" = x ]; then
  DESK_REGISTER=$FM_SPEAK_DEEPGRAM_REGISTER
else
  DESK_REGISTER="$ROOT/docs/examples/desk-speak-register.toml"
fi
SHAPER_TIMEOUT="${FM_SPEAK_SHAPER_TIMEOUT:-$DEFAULT_SHAPER_TIMEOUT}"
SPEAKER_TIMEOUT="${FM_SPEAK_TIMEOUT:-$DEFAULT_SPEAKER_TIMEOUT}"

CFG_ENABLED=false
CFG_VOICE=

# shellcheck source=bin/fm-deepgram-lib.sh
. "$ROOT/bin/fm-deepgram-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

note() {
  printf 'fm-speak: %s\n' "$*" >&2
}

die() {
  note "$*"
  exit 1
}

# --- configuration ----------------------------------------------------------

load_config() {
  local line key value
  [ -f "$CONFIG_FILE" ] || return 0
  [ ! -L "$CONFIG_FILE" ] || die "config must be a regular file: $CONFIG_FILE"
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(printf '%s\n' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in
      *=*) ;;
      *) die "config line is not key = value: $line" ;;
    esac
    key=$(printf '%s\n' "${line%%=*}" | tr -d '[:space:]')
    value=$(printf '%s\n' "${line#*=}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    case "$key" in
      enabled)
        case "$value" in
          true|false) CFG_ENABLED=$value ;;
          *) die "enabled must be true or false: $value" ;;
        esac
        ;;
      voice)
        CFG_VOICE=$value
        ;;
      *) die "unknown config key: $key" ;;
    esac
  done < "$CONFIG_FILE"
}

require_positive_int() {
  local key=$1 value=$2
  case "$value" in
    ''|*[!0-9]*|0) die "$key must be a positive integer: $value" ;;
  esac
}

# --- bounded execution ------------------------------------------------------

# Start a watchdog that kills <pid> after <seconds>, recording in <firedfile>
# (when given) that it did so. The watchdog is a separate child so the wait on
# the guarded command costs nothing when it returns promptly: a poll loop would
# add its own sleep granularity to every spoken line. The timer runs as the
# watchdog's own background child and is reaped on the way out, so cancelling a
# watchdog never leaves a sleep behind for the rest of the bound.
WATCHDOG_PID=
start_watchdog() {  # <seconds> <pid> [firedfile]
  local seconds=$1 pid=$2 fired=${3:-}
  (
    timer=
    trap 'kill "$timer" 2>/dev/null; exit 0' TERM
    sleep "$seconds" &
    timer=$!
    wait "$timer" 2>/dev/null || true
    # Recorded before the kill, not after it: reaching this line means the bound
    # elapsed (an earlier cancellation leaves through the TERM trap above), and
    # the waiting caller wakes on the kill and can cancel this watchdog before a
    # marker written afterwards would land.
    [ -z "$fired" ] || : > "$fired"
    kill "$pid" 2>/dev/null || true
  ) </dev/null >/dev/null 2>&1 &
  WATCHDOG_PID=$!
  # Drop the watchdog from the job table: killing it is the normal path, and
  # the shell would otherwise print a Terminated notice on every call.
  disown "$WATCHDOG_PID" 2>/dev/null || true
}

# Run a command with its output captured and its stdin closed, bounded by a
# watchdog that kills it rather than letting it hold the caller's turn open.
# Sets RUN_BOUNDED_TIMED_OUT so the caller can tell a bound from a failure.
RUN_BOUNDED_TIMED_OUT=false
run_bounded() {  # <seconds> <outfile> <errfile> <cmd...>
  local seconds=$1 out=$2 err=$3 fired pid guard status
  shift 3
  fired="$err.fired"
  rm -f "$fired"
  RUN_BOUNDED_TIMED_OUT=false
  "$@" </dev/null >"$out" 2>"$err" &
  pid=$!
  start_watchdog "$seconds" "$pid" "$fired"
  guard=$WATCHDOG_PID
  status=0
  # The braces confine the shell's own job-termination notice: when the watchdog
  # fires, bash reports the reaped job on stderr, and that notice would reach
  # the caller on every bounded kill.
  { wait "$pid"; } 2>/dev/null || status=$?
  kill "$guard" 2>/dev/null || true
  if [ "$status" -ne 0 ] && [ -e "$fired" ]; then
    RUN_BOUNDED_TIMED_OUT=true
  fi
  rm -f "$fired"
  return "$status"
}

# Hand one speaker body to the machine and return immediately, with its standard
# streams closed and in a process group of its own.
#
# The closed streams are the turn-blocking boundary: a caller reading this script
# through a pipe or command substitution would otherwise stay blocked until the
# audio finished.
#
# The process group is a second and entirely separate boundary, and it is the one
# the captain was losing the end of every spoken line to. A plain `&` leaves the
# speaker in the process group of the command that spoke, so anything that reaps
# that group reaps the audio with it. An agent harness reaps a finished command's
# process group at the end of its turn, which is exactly when firstmate speaks -
# right after a captain-facing reply - so the line was cut mid-sentence and the
# temporary file was left behind every time. Job control gives the job its own
# group, which a reap aimed at the caller cannot reach.
detach_speaker() {  # <function> [args...]
  local detached
  set -m
  "$@" </dev/null >/dev/null 2>&1 &
  detached=$!
  set +m
  disown "$detached" 2>/dev/null || true
}

# Play one line under the speaker bound. Runs only inside detach_speaker, where
# job control is on for the fork itself; it is turned back off here so the bound
# below behaves exactly as it does everywhere else in this script. The player's
# status is deliberately not reported upwards: no caller acts on it, because the
# speaker chosen before the handoff is the only one that speaks this line.
# shellcheck disable=SC2329 # Reached only through the speaker bodies below.
play_bounded() {  # <cmd...>
  local pid holder
  set +m
  "$@" &
  pid=$!
  start_watchdog "$SPEAKER_TIMEOUT" "$pid"
  if fm_current_pid holder; then
    printf '%s %s\n' "$pid" "$holder" > "$PLAYER_FILE" 2>/dev/null || true
  fi
  # Checked only after the player is named, so a stop that lands between the
  # lock and this line is either seen here or finds the player to kill.
  ! stopped_since_start || kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  kill "$WATCHDOG_PID" 2>/dev/null || true
  rm -f "$PLAYER_FILE"
}

# Portable lock helpers live in fm-wake-lib.sh. Loaded in the parent before a
# word has been shaped: the state directory the lock lives in has to be refused
# here, while nothing is outstanding, rather than abort a line that was already
# shaped and leave its temporary file behind. The directory is created under
# this script's own refusal because the library creates it unguarded when
# sourced, which would report the failure as a bare mkdir error from a tool the
# captain never called. A missing library fails the same way, on stderr,
# instead of dying silently in the detached speaker whose streams are already
# closed.
load_speak_lock_helpers() {
  mkdir -p "$STATE" 2>/dev/null \
    || die "cannot create the state directory that holds the playback lock: $STATE"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$ROOT/bin/fm-wake-lib.sh"
}

# fm_lock_try_acquire proves a holder alive with kill -0 on the recorded pid
# alone. A speaker that was killed outright leaves its lock in persistent
# state, and once that pid number is handed to some unrelated long-lived
# process the lock reads as held forever - permanent silence, which is a worse
# failure than the overlap being fixed. Recording the holder's identity beside
# the pid is what tells a speaker that is still speaking from a pid that has
# merely been reused.
# shellcheck disable=SC2329 # Reached only through hold_playback_lock.
record_speak_lock_identity() {
  local pid identity
  pid=$(cat "$SPEAK_LOCK/pid" 2>/dev/null) || return 0
  identity=$(fm_pid_identity "$pid" 2>/dev/null) || return 0
  [ -n "$identity" ] || return 0
  printf '%s\n' "$identity" > "$SPEAK_LOCK/pid-identity" 2>/dev/null || true
}

# Positive proof that the live pid in the lock is no longer the speaker that
# took it. Anything short of that proof - an identity that was never recorded,
# or one this machine cannot read back - leaves the holder alone, so the wait
# can never cut a line that is still playing.
# shellcheck disable=SC2329 # Reached only through hold_playback_lock.
speak_lock_pid_was_reused() {
  local pid recorded current
  pid=$(cat "$SPEAK_LOCK/pid" 2>/dev/null) || return 1
  fm_pid_alive "$pid" || return 1
  recorded=$(cat "$SPEAK_LOCK/pid-identity" 2>/dev/null) || return 1
  [ -n "$recorded" ] || return 1
  current=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ -n "$current" ] || return 1
  [ "$current" != "$recorded" ]
}

# Reclaim under the lock's steal mutex, the same serialization
# fm_lock_try_acquire uses for its own dead-owner steal: while it is held no
# other speaker can publish the lock, so the window between proving the pid
# was reused and removing the lock cannot swallow a genuine new claim.
# shellcheck disable=SC2329 # Reached only through hold_playback_lock.
reclaim_reused_speak_lock() {
  local steal="$SPEAK_LOCK.steal"
  speak_lock_pid_was_reused || return 0
  fm_lock_try_acquire "$steal" || return 0
  if speak_lock_pid_was_reused; then
    fm_lock_remove_path "$SPEAK_LOCK" || true
  fi
  fm_lock_release "$steal" || true
}

# Wait for any earlier line in this home to finish, then keep the lock until
# this line has played. The wait is unbounded on a holder that is genuinely
# speaking because that holder's own speaker bound is what ends it. Acquisition
# is attempted at the library's own cadence, but the reuse probe runs once a
# second rather than on every spin: it reads the holder's identity through `ps`,
# and a line queued behind a thirty-second one would otherwise pay that on the
# captain's machine ten times a second for the whole line. A lock left on a
# reused pid is recovered a second later either way.
# shellcheck disable=SC2329 # Reached only through play_serialized.
hold_playback_lock() {
  local spins=0
  until fm_lock_try_acquire "$SPEAK_LOCK"; do
    spins=$((spins + 1))
    if [ "$((spins % 10))" -eq 0 ]; then
      reclaim_reused_speak_lock
    fi
    sleep 0.1
  done
  SPEAK_LOCK_HELD=true
  record_speak_lock_identity
}

# shellcheck disable=SC2329 # Reached only through play_serialized.
release_playback_lock() {
  [ "$SPEAK_LOCK_HELD" = true ] || return 0
  SPEAK_LOCK_HELD=false
  fm_lock_release "$SPEAK_LOCK" || true
}

# Serial wrapper around play_bounded: acquire after detach, release after the
# line ends or the speaker bound kills it. The EXIT trap covers a speaker that
# never reaches the explicit release.
# shellcheck disable=SC2329 # Reached only through the speaker bodies below.
play_serialized() {  # <cmd...>
  hold_playback_lock
  trap release_playback_lock EXIT
  stopped_since_start || play_bounded "$@"
  release_playback_lock
}

# The two speaker bodies. Each owns the temporary files it was handed and removes
# them once the line has actually finished playing, so a file left behind is
# itself the evidence that a speaker was cut short.
# shellcheck disable=SC2329 # Invoked by name through detach_speaker.
say_speaker() {  # <textfile>
  local textfile=$1
  if [ -n "$CFG_VOICE" ]; then
    play_serialized "$SAY_BIN" -v "$CFG_VOICE" -f "$textfile"
  else
    play_serialized "$SAY_BIN" -f "$textfile"
  fi
  rm -f "$textfile"
}

# shellcheck disable=SC2329 # Invoked by name through detach_speaker.
audio_speaker() {  # <player> <audio> [textfile]
  local player=$1 audio=$2 textfile=${3:-}
  play_serialized "$player" "$audio"
  rm -f "$audio"
  [ -z "$textfile" ] || rm -f "$textfile"
}

speak_say_detached() {  # <textfile>
  detach_speaker say_speaker "$1"
}

# Prefer Deepgram when a key is available. Synthesis is waited on under the
# speaker watchdog (network only, --to file); playback is then detached so the
# caller's turn is never held open by audio. Returns 0 when Deepgram accepted
# the line, 1 when the caller should use `say`.
speak_deepgram_or_fail() {  # <textfile>
  local textfile=$1 key audio status=0 afplay_bin out err
  key=$(fm_deepgram_api_key)
  [ -n "$key" ] || return 1
  [ -x "$DEEPGRAM_TTS" ] || {
    note "Deepgram TTS helper is not executable: $DEEPGRAM_TTS; falling back to say"
    return 1
  }
  audio=$(mktemp "${TMPDIR:-/tmp}/fm-speak-dg.XXXXXX") || return 1
  mv "$audio" "$audio.mp3"
  audio=$audio.mp3
  out=$(mktemp "${TMPDIR:-/tmp}/fm-speak-dg-out.XXXXXX") || { rm -f "$audio"; return 1; }
  err=$(mktemp "${TMPDIR:-/tmp}/fm-speak-dg-err.XXXXXX") || { rm -f "$audio" "$out"; return 1; }
  status=0
  # Subshell keeps the key out of this shell; helper re-reads env/.env itself,
  # and this home's FM_HOME is passed so it reads the voice from the same .env.
  run_bounded "$SPEAKER_TIMEOUT" "$out" "$err" \
    env DEEPGRAM_API_KEY="$key" FM_HOME="$FM_HOME" "$DEEPGRAM_TTS" --to "$audio" -- "$(cat "$textfile")" \
    || status=$?
  rm -f "$out" "$err"
  if [ "$status" -ne 0 ] || [ ! -s "$audio" ]; then
    rm -f "$audio"
    note "Deepgram TTS failed; falling back to macOS say"
    return 1
  fi
  afplay_bin="${FM_DEEPGRAM_AFPLAY:-/usr/bin/afplay}"
  if [ ! -x "$afplay_bin" ]; then
    rm -f "$audio"
    note "no afplay at $afplay_bin; falling back to say"
    return 1
  fi
  keep_audio "$audio"
  detach_speaker audio_speaker "$afplay_bin" "$audio" "$textfile"
  return 0
}

# --- playback controls ------------------------------------------------------

stop_generation() {
  local gen
  gen=$(cat "$STOP_GEN_FILE" 2>/dev/null) || gen=0
  case "$gen" in ''|*[!0-9]*) gen=0 ;; esac
  printf '%s\n' "$gen"
}

# shellcheck disable=SC2329 # Reached only through the speaker bodies above.
stopped_since_start() {
  [ "$(stop_generation)" != "$STOP_GEN_AT_START" ]
}

# Cancel every line handed over so far, then cut the one playing now. The player
# is killed only while it is still the child of the speaker that named it, so a
# pid number reused after the line ended is never signalled.
stop_playback() {
  local next tmp player holder parent
  mkdir -p "$STATE" 2>/dev/null || die "cannot create the state directory: $STATE"
  next=$(( $(stop_generation) + 1 ))
  tmp=$(mktemp "$STATE/.speak-stop.XXXXXX") || die "cannot record the stop in $STATE"
  printf '%s\n' "$next" > "$tmp"
  mv -f "$tmp" "$STOP_GEN_FILE" || { rm -f "$tmp"; die "cannot record the stop in $STATE"; }
  [ -f "$PLAYER_FILE" ] || return 0
  read -r player holder 2>/dev/null < "$PLAYER_FILE" || return 0
  case "$player$holder" in ''|*[!0-9]*) return 0 ;; esac
  parent=$(ps -o ppid= -p "$player" 2>/dev/null | tr -d '[:space:]') || return 0
  [ "$parent" = "$holder" ] || return 0
  kill "$player" 2>/dev/null || true
}

is_muted() {
  [ -e "$MUTE_FILE" ]
}

set_muted() {  # true|false
  mkdir -p "$STATE" 2>/dev/null || die "cannot create the state directory: $STATE"
  if [ "$1" = true ]; then
    : > "$MUTE_FILE" || die "cannot record mute in $MUTE_FILE"
    stop_playback
  else
    rm -f "$MUTE_FILE" || die "cannot clear mute in $MUTE_FILE"
  fi
}

# --- reply history ----------------------------------------------------------

# Kept reply numbers, oldest first. An entry directory is claimed before its text
# is written, so a number may briefly have no text; readers skip it.
history_numbers() {
  local entry name
  for entry in "$HISTORY_DIR"/*; do
    name=${entry##*/}
    case "$name" in ''|*[!0-9]*) continue ;; esac
    [ -d "$entry" ] && printf '%s\n' "$name"
  done | sort -n
}

# Copy the synthesized audio aside before the detached speaker plays and removes
# it, so the reply history can keep it. Best effort: a line without kept audio
# is still replayable, only not instantly.
keep_audio() {  # <audio>
  local kept
  KEPT_AUDIO=
  kept=$(mktemp "$STATE/.speak-audio.XXXXXX" 2>/dev/null) || return 0
  if { ln -f "$1" "$kept" 2>/dev/null || cp "$1" "$kept" 2>/dev/null; } \
    && chmod 600 "$kept" 2>/dev/null; then
    KEPT_AUDIO=$kept
  else
    rm -f "$kept"
  fi
}

# Move kept audio into a reply's entry. An entry pruned in the meantime simply
# loses the audio.
attach_kept_audio() {  # <entry-dir>
  [ -n "$KEPT_AUDIO" ] || return 0
  mv -f "$KEPT_AUDIO" "$1/audio.mp3" 2>/dev/null || rm -f "$KEPT_AUDIO"
  KEPT_AUDIO=
}

prune_history() {
  local count number
  count=$(history_numbers | wc -l | tr -d '[:space:]')
  [ "$count" -gt "$HISTORY_KEEP" ] || return 0
  history_numbers | head -n "$((count - HISTORY_KEEP))" | while read -r number; do
    rm -rf "${HISTORY_DIR:?}/$number"
  done
}

# Keep one line that was handed to a speaker. Best effort, like the handoff it
# follows: a history that cannot be written never turns a spoken line into a
# failure. Everything is written under umask 077 and the directory is tightened
# to 0700 on every use, so the captain's replies are never readable by another
# account on the machine, including a history left behind by an older version.
record_history() {  # <shaped text>
  local saved
  saved=$(umask)
  umask 077
  store_history "$1"
  umask "$saved"
}

# The number is claimed with mkdir, which is atomic, so two lines kept at once
# never share one.
store_history() {  # <shaped text>
  local last next tries=0 entry
  if ! mkdir -p "$HISTORY_DIR" 2>/dev/null || ! chmod 700 "$HISTORY_DIR" 2>/dev/null; then
    attach_kept_audio /nonexistent
    return 0
  fi
  last=$(history_numbers | tail -n 1)
  next=$(( ${last:-0} + 1 ))
  until mkdir "$HISTORY_DIR/$next" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge 20 ]; then
      attach_kept_audio /nonexistent
      return 0
    fi
    next=$((next + 1))
  done
  entry=$HISTORY_DIR/$next
  date +%s > "$entry/time" 2>/dev/null || true
  attach_kept_audio "$entry"
  if printf '%s\n' "$1" > "$entry/.text" 2>/dev/null; then
    mv -f "$entry/.text" "$entry/text" 2>/dev/null || true
  fi
  prune_history
}

list_history() {
  local number entry when text
  history_numbers | sort -rn | while read -r number; do
    entry=$HISTORY_DIR/$number
    [ -s "$entry/text" ] || continue
    text=$(tr '\t\r\n' '   ' < "$entry/text" 2>/dev/null) || continue
    text=$(printf '%s' "$text" | sed -E 's/[[:space:]]+$//')
    when=$(cat "$entry/time" 2>/dev/null) || when=0
    case "$when" in ''|*[!0-9]*) when=0 ;; esac
    printf '%s\t%s\t%s\n' "$number" "$when" "$text"
  done
}

# Play a reply's kept audio straight away, with no synthesis. The speaker gets a
# copy of its own so pruning the entry while the line waits for the playback
# lock cannot take the audio from under it. Returns 1 when there is nothing to
# play this way and the caller should speak the text instead.
play_kept_audio() {  # <entry-dir>
  local entry=$1 player audio
  [ -z "$CFG_VOICE" ] || return 1
  [ -s "$entry/audio.mp3" ] || return 1
  player="${FM_DEEPGRAM_AFPLAY:-/usr/bin/afplay}"
  [ -x "$player" ] || return 1
  audio=$(mktemp "${TMPDIR:-/tmp}/fm-speak-dg.XXXXXX") || return 1
  mv "$audio" "$audio.mp3" || { rm -f "$audio"; return 1; }
  audio=$audio.mp3
  if ! ln -f "$entry/audio.mp3" "$audio" 2>/dev/null && ! cp "$entry/audio.mp3" "$audio" 2>/dev/null; then
    rm -f "$audio"
    return 1
  fi
  detach_speaker audio_speaker "$player" "$audio"
}

# --- configured voice -------------------------------------------------------

# `say` does not refuse a voice it does not have: it substitutes one and still
# exits 0, so a misspelled `voice` would be answered in some other voice with
# nothing said about it. Asking which voices exist is therefore done here, before
# the handoff, because the detached speaker has no way back to the caller.
#
# Two things keep that question off the captain's turn. It is asked in the
# background, under a bound that starts with it rather than when it is collected,
# so it runs beside the register call and the two bounds overlap instead of
# adding up: the register call remains the worst case a turn can be held. And a
# voice this machine confirmed once is remembered, so only the first spoken line
# of a home ever waits for the answer at all. Nothing here touches the network.
VOICE_LIST_FILE=
VOICE_LIST_PID=
VOICE_LIST_GUARD=

# The register can refuse or fail after the list was asked for, so the question
# is cleaned up on the way out as well as on the way through: the file is dropped
# and the bound that guards it is cancelled, because a watchdog left sleeping
# outlives this script and its trap. An orphaned fm-speak temporary file is this
# script's evidence that a speaker was cut short; asking `say` a question must
# never spend that signal.
# shellcheck disable=SC2329 # Invoked through the EXIT trap below.
drop_voice_list() {
  [ -z "$VOICE_LIST_GUARD" ] || kill "$VOICE_LIST_GUARD" 2>/dev/null || true
  [ -z "$VOICE_LIST_FILE" ] || rm -f "$VOICE_LIST_FILE"
  VOICE_LIST_GUARD=
  VOICE_LIST_FILE=
}
# shellcheck disable=SC2329 # Invoked through the EXIT trap below.
cleanup_on_exit() {
  drop_voice_list
  [ -z "$KEPT_AUDIO" ] || rm -f "$KEPT_AUDIO"
}
trap cleanup_on_exit EXIT

# Only a confirmed voice is remembered. A voice that was not found is re-asked
# every line on purpose: the captain is being told about it every line too, and a
# remembered "missing" would go on refusing after he installed it.
voice_already_confirmed() {
  [ -n "$CFG_VOICE" ] || return 1
  [ -r "$VOICE_CONFIRMED_FILE" ] || return 1
  [ "$(cat "$VOICE_CONFIRMED_FILE" 2>/dev/null)" = "$CFG_VOICE" ]
}

remember_confirmed_voice() {
  mkdir -p "$STATE" 2>/dev/null || return 0
  printf '%s\n' "$CFG_VOICE" > "$VOICE_CONFIRMED_FILE" 2>/dev/null || true
}

start_voice_list() {
  [ -n "$CFG_VOICE" ] || return 0
  [ -x "$SAY_BIN" ] || return 0
  ! voice_already_confirmed || return 0
  VOICE_LIST_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-speak-voices.XXXXXX") || return 0
  "$SAY_BIN" -v '?' </dev/null >"$VOICE_LIST_FILE" 2>/dev/null &
  VOICE_LIST_PID=$!
  start_watchdog "$SHAPER_TIMEOUT" "$VOICE_LIST_PID"
  VOICE_LIST_GUARD=$WATCHDOG_PID
}

# True when the configured voice is one `say` listed. Anything short of a
# complete answer - a lister that never ran, exited non-zero, or produced nothing
# - means the question could not be answered rather than that the voice is
# missing, so the line is still spoken. A list killed part-way has already flushed
# whole blocks of the alphabet, so a name absent from it proves nothing; a killed
# lister is caught by its non-zero status. This check exists to catch a name that
# is clearly wrong, not to become a new way to lose a line.
#
# It must therefore match at least as loosely as `say` resolves, or it would
# refuse a name `say` speaks perfectly well. `say` matches case-insensitively,
# and it resolves a bare base name to its qualified voice: `Eddy` reaches
# `Eddy (English (UK))` and `Ava` reaches `Ava (Premium)`, byte for byte. The
# qualifier is stripped from the listed name only, never from the configured one,
# because the resolution does not run the other way: `Zarvox (Premium)` does not
# reach the listed `Zarvox`, it falls through to the substitute voice, and that
# is a name worth refusing.
#
# Each listed line is `<name> <locale> # <sample>`, and the name itself can hold
# spaces and brackets, so the locale and the sample are stripped from the end
# rather than the name being read from the start.
configured_voice_is_available() {
  local available=0 status=0
  [ -n "$VOICE_LIST_PID" ] || return 0
  { wait "$VOICE_LIST_PID"; } 2>/dev/null || status=$?
  kill "$VOICE_LIST_GUARD" 2>/dev/null || true
  VOICE_LIST_GUARD=
  VOICE_LIST_PID=
  if [ "$status" -eq 0 ] && [ -s "$VOICE_LIST_FILE" ]; then
    if awk -v want="$CFG_VOICE" '
      BEGIN { want = tolower(want) }
      {
        name = $0
        sub(/[[:space:]]*#.*$/, "", name)
        sub(/[[:space:]]+[^[:space:]]+[[:space:]]*$/, "", name)
        name = tolower(name)
        base = name
        sub(/[[:space:]]*\(.*\)$/, "", base)
        if (name == want || base == want) { found = 1 }
      }
      END { exit found ? 0 : 1 }
    ' "$VOICE_LIST_FILE"; then
      remember_confirmed_voice
    else
      available=1
    fi
  fi
  drop_voice_list
  return "$available"
}

speak_detached() {  # <textfile>
  local textfile=$1
  # A configured voice is a choice this script can only keep through `say`:
  # Deepgram takes its voice from DEEPGRAM_TTS_MODEL and ignores the config key,
  # so preferring Deepgram here would silently answer in a voice the home did not
  # ask for. Deepgram stays the fallback for a host with no usable `say`.
  if [ -n "$CFG_VOICE" ] && [ -x "$SAY_BIN" ]; then
    if ! configured_voice_is_available; then
      rm -f "$textfile"
      die "say has no voice named '$CFG_VOICE' (config/speak); nothing was spoken"
    fi
    speak_say_detached "$textfile"
    return 0
  fi
  if speak_deepgram_or_fail "$textfile"; then
    return 0
  fi
  # Deepgram path leaves the textfile in place for the say fallback.
  [ -f "$textfile" ] || return 0
  if [ ! -x "$SAY_BIN" ]; then
    rm -f "$textfile"
    die "no speech binary at $SAY_BIN (set FM_SPEAK_SAY)"
  fi
  speak_say_detached "$textfile"
}

# Every desk line gets the longer desk register, whichever speaker plays it: the
# register owner truncates before playback, so gating this on the sink is what
# made the same outcome finish through one speaker and stop mid-sentence through
# the other. Skipped when GLASSES_ANNOUNCE_CONFIG is already set, or when
# FM_SPEAK_DEEPGRAM_REGISTER is empty and the caller wants the glasses cut.
apply_desk_register() {
  [ -n "${GLASSES_ANNOUNCE_CONFIG:-}" ] && return 0
  [ -n "$DESK_REGISTER" ] || return 0
  [ -f "$DESK_REGISTER" ] || {
    note "desk register example missing: $DESK_REGISTER (continuing with the shaper default)"
    return 0
  }
  export GLASSES_ANNOUNCE_CONFIG="$DESK_REGISTER"
}

# --- main -------------------------------------------------------------------

# Speak a kept reply again, as it was shaped. Honours opt-in and mute exactly
# like a new line, and takes the same speaker path and playback lock; kept audio
# skips the synthesis. <number> empty means the newest reply (--repeat).
replay_reply() {  # [number]
  local number=$1 entry text textfile
  load_config
  if [ "$CFG_ENABLED" != true ]; then
    note "this home is not opted in; add 'enabled = true' to config/speak to speak here"
    exit 0
  fi
  if is_muted; then
    note "voice is muted; nothing was spoken (fm-speak.sh --unmute)"
    exit 0
  fi
  if [ -z "$number" ]; then
    number=$(list_history | head -n 1 | cut -f 1)
    [ -n "$number" ] || die "nothing has been spoken here yet; nothing to repeat"
  fi
  entry=$HISTORY_DIR/$number
  text=$(cat "$entry/text" 2>/dev/null) || text=
  [ -n "$text" ] || die "no reply numbered $number is kept; see fm-speak.sh --history"
  load_speak_lock_helpers
  if play_kept_audio "$entry"; then
    printf '%s\n' "$text"
    exit 0
  fi
  if [ ! -x "$SAY_BIN" ] && [ -z "$(fm_deepgram_api_key)" ]; then
    die "no speech binary at $SAY_BIN and no DEEPGRAM_API_KEY (set FM_SPEAK_SAY or the key)"
  fi
  start_voice_list
  textfile=$(mktemp "${TMPDIR:-/tmp}/fm-speak-text.XXXXXX") || die "cannot create a temporary file"
  printf '%s\n' "$text" > "$textfile"
  speak_detached "$textfile"
  attach_kept_audio "$entry"
  printf '%s\n' "$text"
  exit 0
}

main() {
  local dry_run=false text='' outfile errfile textfile status shaped control=

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h) usage; exit 0 ;;
      --dry-run) dry_run=true; shift ;;
      --stop|--repeat|--history|--replay|--mute|--unmute|--muted)
        [ -z "$control" ] || {
          note "only one of --stop, --repeat, --history, --replay, --mute, --unmute, --muted"
          exit 1
        }
        control=${1#--}
        if [ "$control" = replay ]; then
          [ "$#" -ge 2 ] || { note "--replay needs a reply number from --history"; exit 1; }
          REPLAY_NUMBER=$2
          case "$REPLAY_NUMBER" in
            ''|*[!0-9]*|0*) note "--replay needs a reply number from --history: $REPLAY_NUMBER"; exit 1 ;;
          esac
          shift
        fi
        shift
        ;;
      --) shift; break ;;
      -*) note "unexpected option: $1"; usage; exit 1 ;;
      *) break ;;
    esac
  done

  STOP_GEN_AT_START=$(stop_generation)
  if [ -n "$control" ]; then
    [ "$#" -eq 0 ] && [ "$dry_run" = false ] \
      || { note "--$control takes no other text and no --dry-run"; exit 1; }
    case "$control" in
      stop) stop_playback ;;
      mute) set_muted true ;;
      unmute) set_muted false ;;
      muted) if is_muted; then printf 'muted\n'; else printf 'unmuted\n'; fi ;;
      history) list_history ;;
      repeat|replay)
        require_positive_int FM_SPEAK_TIMEOUT "$SPEAKER_TIMEOUT"
        replay_reply "$REPLAY_NUMBER"
        ;;
    esac
    exit 0
  fi

  [ "$#" -gt 0 ] || { note "nothing to speak"; usage; exit 1; }
  text=$*
  case "$text" in
    *[![:space:]]*) ;;
    *) die "nothing to speak" ;;
  esac

  require_positive_int FM_SPEAK_SHAPER_TIMEOUT "$SHAPER_TIMEOUT"
  require_positive_int FM_SPEAK_TIMEOUT "$SPEAKER_TIMEOUT"
  load_config

  if [ "$CFG_ENABLED" != true ]; then
    note "this home is not opted in; add 'enabled = true' to config/speak to speak here"
    exit 0
  fi
  if [ "$dry_run" != true ] && is_muted; then
    note "voice is muted; nothing was spoken (fm-speak.sh --unmute)"
    exit 0
  fi

  [ -x "$SHAPER" ] \
    || die "the spoken register owner is not executable: $SHAPER (set FM_SPEAK_SHAPER)"
  if [ "$dry_run" != true ]; then
    if [ ! -x "$SAY_BIN" ] && [ -z "$(fm_deepgram_api_key)" ]; then
      die "no speech binary at $SAY_BIN and no DEEPGRAM_API_KEY (set FM_SPEAK_SAY or the key)"
    fi
  fi

  apply_desk_register
  if [ "$dry_run" != true ]; then
    load_speak_lock_helpers
    start_voice_list
  fi

  outfile=$(mktemp "${TMPDIR:-/tmp}/fm-speak-out.XXXXXX") || die "cannot create a temporary file"
  errfile=$(mktemp "${TMPDIR:-/tmp}/fm-speak-err.XXXXXX") || {
    rm -f "$outfile"
    die "cannot create a temporary file"
  }

  status=0
  run_bounded "$SHAPER_TIMEOUT" "$outfile" "$errfile" "$SHAPER" --dry-run "$text" || status=$?

  # The register owner's own notes explain what it stripped or truncated, so
  # they are passed through rather than swallowed.
  [ ! -s "$errfile" ] || cat "$errfile" >&2
  shaped=$(cat "$outfile")
  rm -f "$outfile" "$errfile"

  case "$status" in
    0) ;;
    2)
      note "refused by the spoken register; nothing was spoken"
      exit 2
      ;;
    *)
      if [ "$RUN_BOUNDED_TIMED_OUT" = true ]; then
        note "the spoken register owner exceeded its ${SHAPER_TIMEOUT}s bound (FM_SPEAK_SHAPER_TIMEOUT); nothing was spoken"
      else
        note "the spoken register owner failed (exit $status); nothing was spoken"
      fi
      exit 1
      ;;
  esac

  case "$shaped" in
    *[![:space:]]*) ;;
    *)
      note "the spoken register left nothing to speak"
      exit 2
      ;;
  esac

  if [ "$dry_run" = true ]; then
    printf '%s\n' "$shaped"
    exit 0
  fi

  # The speaker reads from a file rather than from an argument so no shaped
  # sentence can ever be parsed as an option.
  textfile=$(mktemp "${TMPDIR:-/tmp}/fm-speak-text.XXXXXX") || die "cannot create a temporary file"
  printf '%s\n' "$shaped" > "$textfile"
  speak_detached "$textfile"
  record_history "$shaped"
  printf '%s\n' "$shaped"
  exit 0
}

main "$@"
