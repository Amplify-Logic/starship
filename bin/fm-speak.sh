#!/usr/bin/env bash
# fm-speak.sh - speak one captain-facing outcome line out of this machine's
# own speaker, in the captain's spoken register.
#
# Usage:
#   fm-speak.sh [--dry-run] <text>
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
#     two or three short sentences, about eight seconds, never a URL, path or
#     id, and never a request for a spoken yes - is owned once by the glasses
#     project's announce entry point. This script shapes through that owner and
#     refuses to speak if it cannot reach it, because speaking unshaped text
#     would read a URL aloud, which is the one thing the register forbids
#     outright.
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
#   voice     optional `say` voice name (default: the system voice; ignored for
#             Deepgram, which uses DEEPGRAM_TTS_MODEL instead)
#
# SPEAKER PREFERENCE: when DEEPGRAM_API_KEY is set in the environment or in this
# home's gitignored .env, the shaped line is handed to Deepgram Aura first
# (bin/fm-deepgram-tts.sh). macOS `say` remains the fallback when the key is
# absent or Deepgram fails. The key is never logged.
#
# DEEPGRAM SPOKEN BOUND: when Deepgram is the intended sink, this script points
# the glasses register owner at docs/examples/desk-speak-register.toml via
# GLASSES_ANNOUNCE_CONFIG (unless that variable is already set). That example
# keeps the same URL/path/id and decision refusals but raises the spoken budget
# from ~8s (say-friendly) to 30s. Documented bound for Deepgram desk lines:
# 30 seconds / about 78 words at 2.6 wps. Override the example path with
# FM_SPEAK_DEEPGRAM_REGISTER, or keep an 8s cut by exporting
# FM_SPEAK_DEEPGRAM_REGISTER= (empty) before calling.
#
# NEVER BLOCKS THE CALLER'S TURN. The register call is bounded and waited on
# because its output is needed, so its bound is the worst case a captain-facing
# turn can be held: 15 seconds by default against an owner measured at about
# one. The speaker call is bounded and detached, with its standard streams
# closed, so a caller that captures this script's output is never held open by
# audio that is still playing; its bound only stops a runaway from holding the
# audio device. A speech error downstream of that handoff is unobservable here
# by design.
#
# Environment overrides, for tests and unusual layouts:
#   FM_SPEAK_SHAPER    register owner exposing the `--dry-run <text>` contract
#                      (default: $FM_HOME/projects/glasses-voice/bin/announce)
#   FM_SPEAK_SAY       speech binary (default: /usr/bin/say)
#   FM_SPEAK_DEEPGRAM_TTS
#                      Deepgram TTS helper (default: $ROOT/bin/fm-deepgram-tts.sh)
#   FM_SPEAK_DEEPGRAM_REGISTER
#                      optional GLASSES_ANNOUNCE_CONFIG path for the longer desk
#                      register when Deepgram is available (default:
#                      $ROOT/docs/examples/desk-speak-register.toml)
#   FM_SPEAK_SHAPER_TIMEOUT
#                      bounded seconds for the waited-on register call
#                      (default 15)
#   FM_SPEAK_TIMEOUT   bounded seconds for the detached speaker (default 60)
#
# EXIT CODES (mirroring the register owner's own contract):
#   0  handed to the speaker, printed under --dry-run, or this home is not
#      opted in
#   1  cannot speak: the register owner is unreachable, failed or exceeded its
#      bound, the speech binary is missing, or the config is invalid
#   2  refused by the register; nothing was spoken and the reason is reported
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONFIG_FILE="$CONFIG/speak"

DEFAULT_SHAPER_TIMEOUT=15
DEFAULT_SPEAKER_TIMEOUT=60

SHAPER="${FM_SPEAK_SHAPER:-$FM_HOME/projects/glasses-voice/bin/announce}"
SAY_BIN="${FM_SPEAK_SAY:-/usr/bin/say}"
DEEPGRAM_TTS="${FM_SPEAK_DEEPGRAM_TTS:-$ROOT/bin/fm-deepgram-tts.sh}"
# Default longer desk register; empty FM_SPEAK_DEEPGRAM_REGISTER disables the bump.
if [ "${FM_SPEAK_DEEPGRAM_REGISTER+x}" = x ]; then
  DEEPGRAM_REGISTER=$FM_SPEAK_DEEPGRAM_REGISTER
else
  DEEPGRAM_REGISTER="$ROOT/docs/examples/desk-speak-register.toml"
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
    if kill "$pid" 2>/dev/null && [ -n "$fired" ]; then
      : > "$fired"
    fi
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

# Hand the shaped line to macOS `say` and return immediately. The standard
# streams are closed before backgrounding: a caller reading this script through
# a pipe or command substitution would otherwise stay blocked until the audio
# finished, which is exactly the turn-blocking this script must never cause.
speak_say_detached() {  # <textfile>
  local textfile=$1
  (
    local say_pid
    if [ -n "$CFG_VOICE" ]; then
      "$SAY_BIN" -v "$CFG_VOICE" -f "$textfile" &
    else
      "$SAY_BIN" -f "$textfile" &
    fi
    say_pid=$!
    start_watchdog "$SPEAKER_TIMEOUT" "$say_pid"
    wait "$say_pid" 2>/dev/null || true
    kill "$WATCHDOG_PID" 2>/dev/null || true
    rm -f "$textfile"
  ) </dev/null >/dev/null 2>&1 &
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
  # Subshell keeps the key out of this shell; helper re-reads env/.env itself.
  run_bounded "$SPEAKER_TIMEOUT" "$out" "$err" \
    env DEEPGRAM_API_KEY="$key" "$DEEPGRAM_TTS" --to "$audio" -- "$(cat "$textfile")" \
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
  (
    local play_pid
    "$afplay_bin" "$audio" &
    play_pid=$!
    start_watchdog "$SPEAKER_TIMEOUT" "$play_pid"
    wait "$play_pid" 2>/dev/null || true
    kill "$WATCHDOG_PID" 2>/dev/null || true
    rm -f "$audio" "$textfile"
  ) </dev/null >/dev/null 2>&1 &
  return 0
}

speak_detached() {  # <textfile>
  local textfile=$1
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

# When Deepgram will be the sink, prefer the longer desk register example unless
# GLASSES_ANNOUNCE_CONFIG is already set, or FM_SPEAK_DEEPGRAM_REGISTER is empty.
maybe_apply_deepgram_register() {
  local key
  key=$(fm_deepgram_api_key)
  [ -n "$key" ] || return 0
  [ -n "${GLASSES_ANNOUNCE_CONFIG:-}" ] && return 0
  [ -n "$DEEPGRAM_REGISTER" ] || return 0
  [ -f "$DEEPGRAM_REGISTER" ] || {
    note "Deepgram desk register example missing: $DEEPGRAM_REGISTER (continuing with the shaper default)"
    return 0
  }
  export GLASSES_ANNOUNCE_CONFIG="$DEEPGRAM_REGISTER"
}

# --- main -------------------------------------------------------------------

main() {
  local dry_run=false text='' outfile errfile textfile status shaped

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h) usage; exit 0 ;;
      --dry-run) dry_run=true; shift ;;
      --) shift; break ;;
      -*) note "unexpected option: $1"; usage; exit 1 ;;
      *) break ;;
    esac
  done

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

  [ -x "$SHAPER" ] \
    || die "the spoken register owner is not executable: $SHAPER (set FM_SPEAK_SHAPER)"
  if [ "$dry_run" != true ]; then
    if [ ! -x "$SAY_BIN" ] && [ -z "$(fm_deepgram_api_key)" ]; then
      die "no speech binary at $SAY_BIN and no DEEPGRAM_API_KEY (set FM_SPEAK_SAY or the key)"
    fi
  fi

  maybe_apply_deepgram_register

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
  printf '%s\n' "$shaped"
  exit 0
}

main "$@"
