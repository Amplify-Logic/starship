#!/usr/bin/env bash
# fm-call-lib.sh - shared paths and settings for the call companion scripts.
#
# Sourced by bin/fm-call-companion.sh, fm-call-watch.sh, fm-call-digest.sh,
# fm-call-mic.sh and fm-call-captions.sh; never run on its own.
# docs/call-companion.md describes the tool.
#
# Every runtime file lives in the operational home, never in this code root:
#   data/calls/    the call record: transcript.txt, digest.json, desk.md,
#                  glance.html, notes.{md,html,json}, archive/, and public/
#                  (symlinks to just the desk views, for a home that serves them)
#   state/calls/   process ids, logs/, audio/ (short-lived chunks), the live
#                  item and decision logs, call-stamp (the current call's
#                  stamp), the watcher's state, and the compiled microphone
#                  helper
#
# Settings come from the home's private, gitignored config/call-companion:
# `key = value` lines, `#` comments and blank lines ignored, unknown keys
# refused. docs/examples/call-companion lists every key with its default.
#   speaker_name         label for speech heard only on this Mac's microphone
#   mic_device           microphone name to record (empty: first physical one)
#   loopback_device      loopback input carrying the call audio (BlackHole)
#   multi_output_device  output switched to while recording, so the call audio
#                        also reaches the loopback (empty: never switch)
#   whisper_model        whisper.cpp model file (empty: large-v3-turbo, then
#                        base.en, under ~/.cache/whisper)
#   digest_model         Claude model for the live desk (sonnet)
#   notes_model          Claude model for the end-of-call notes (opus)
#   display_host         ssh host showing the desk on a second Hyprland screen
#                        (empty: off)
#   display_url          the address that host opens for the desk
#
# Environment: FM_HOME selects the home (default: this code root);
# FM_DATA_OVERRIDE, FM_STATE_OVERRIDE and FM_CONFIG_OVERRIDE move one of its
# directories as for the other scripts. CALL_COMPANION_DATA_DIR,
# CALL_COMPANION_STATE_DIR and CALL_COMPANION_CONFIG name the call directories
# and settings file directly; the lib exports all three once resolved, so every
# component a script starts reads the same home.

FM_CALL_BIN=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_CALL_ROOT=$(cd "$FM_CALL_BIN/.." && pwd)
FM_CALL_HOME=${FM_HOME:-$FM_CALL_ROOT}
CALL_COMPANION_DATA_DIR=${CALL_COMPANION_DATA_DIR:-${FM_DATA_OVERRIDE:-$FM_CALL_HOME/data}/calls}
CALL_COMPANION_STATE_DIR=${CALL_COMPANION_STATE_DIR:-${FM_STATE_OVERRIDE:-$FM_CALL_HOME/state}/calls}
CALL_COMPANION_CONFIG=${CALL_COMPANION_CONFIG:-${FM_CONFIG_OVERRIDE:-$FM_CALL_HOME/config}/call-companion}
export CALL_COMPANION_DATA_DIR CALL_COMPANION_STATE_DIR CALL_COMPANION_CONFIG
# Read by the sourcing scripts, not by this library.
# shellcheck disable=SC2034
FM_CALL_DATA=$CALL_COMPANION_DATA_DIR
# shellcheck disable=SC2034
FM_CALL_STATE=$CALL_COMPANION_STATE_DIR

FM_CALL_KEYS='speaker_name mic_device loopback_device multi_output_device whisper_model digest_model notes_model display_host display_url'

# fm_call_setting <key> <default> - print one setting, or the default when the
# file or the key is absent. A malformed line or an unknown key is reported and
# fails, so a typo never silently changes what is recorded.
fm_call_setting() {
  local want=$1 default=$2 line key value found=false result=
  case " $FM_CALL_KEYS " in *" $want "*) ;; *) printf 'call-companion: unknown setting %s\n' "$want" >&2; return 2 ;; esac
  if [ -f "$CALL_COMPANION_CONFIG" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line=$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
      case "$line" in ''|'#'*) continue ;; esac
      case "$line" in *=*) ;; *) printf 'call-companion: malformed line in %s: %s\n' "$CALL_COMPANION_CONFIG" "$line" >&2; return 2 ;; esac
      key=$(printf '%s' "${line%%=*}" | sed -E 's/[[:space:]]+$//')
      value=$(printf '%s' "${line#*=}" | sed -E 's/^[[:space:]]+//')
      case " $FM_CALL_KEYS " in *" $key "*) ;; *) printf 'call-companion: unknown key in %s: %s\n' "$CALL_COMPANION_CONFIG" "$key" >&2; return 2 ;; esac
      if [ "$key" = "$want" ]; then found=true; result=$value; fi
    done < "$CALL_COMPANION_CONFIG"
  fi
  if [ "$found" = true ]; then printf '%s\n' "$result"; else printf '%s\n' "$default"; fi
}

# fm_call_stamp - print the current call's stamp (YYYYMMDD-HHMMSS, chosen by
# `fm-call-companion.sh start` and kept until the call is archived or
# deleted); fails when there is none.
fm_call_stamp() {
  local stamp
  stamp=$(sed -n '1p' "$FM_CALL_STATE/call-stamp" 2>/dev/null) || return 1
  [[ "$stamp" =~ ^[0-9]{8}-[0-9]{6}$ ]] || return 1
  printf '%s\n' "$stamp"
}

# fm_call_tool <name> <fallback-path> - the first <name> on PATH, else the
# fallback (Homebrew's location on Apple silicon), so a launchd job with a
# minimal PATH still finds what Homebrew installed.
fm_call_tool() {
  command -v "$1" 2>/dev/null || printf '%s\n' "$2"
}
