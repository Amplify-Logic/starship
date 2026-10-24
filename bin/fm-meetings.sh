#!/usr/bin/env bash
# fm-meetings.sh - turn finished personal meetings recorded by Anarlog, and
# glasses calls shared to an iCloud Drive folder, into Starship work.
#
# Usage:
#   fm-meetings.sh check               the standing watcher check (bounded poll, one line)
#   fm-meetings.sh arm                 write and register state/meetings.check.sh
#   fm-meetings.sh disarm              remove the check shim and its trust binding
#   fm-meetings.sh poll                one unbounded poll, printing what check would print
#   fm-meetings.sh intake [<id>...]    take in every meeting the check announced, or the named ones
#   fm-meetings.sh recall <words>...   what was said or agreed: a person, topic or title
#   fm-meetings.sh status              every tracked meeting and shared file, and any standing problem
#   fm-meetings.sh --help
#
# Anarlog (anarlog.so) records the meeting on this Mac and keeps it in its own
# local database. This layer reads it only through Anarlog's own command-line
# tool (`anarlog --json meetings ...`, local source) and never opens that
# database itself. The one thing it asks Anarlog to add is a recording import,
# through Anarlog's supported `meetings import` command, which needs the
# desktop app open on the same database.
#
# THE CHECK. `arm` writes state/meetings.check.sh, a byte-static shim that runs
# `check`, and binds it with fm-check-register.sh, so the watcher runs it on its
# slow-check cadence and turns its one printed line into a `check:` wake. The
# line starts `meetings:` and names each meeting that became ready for intake
# since the last poll, once, plus any problem worth a wake, once until it
# clears. `arm` also records the arming time: a meeting that ended before it is
# left alone (intake can still take one in by id). The poll must finish inside
# the watcher's per-check bound (FM_CHECK_TIMEOUT, default 30); unfinished work
# carries over to the next poll.
#
# WHEN A RECORDING IS FINISHED. A recorded meeting counts once Anarlog shows an
# end time, has no capture still pending, nothing changed for two minutes, and
# its summary exists or ten minutes have passed. Anarlog's live model (Parakeet
# Streaming) writes the transcript during the call; Anarlog runs its Batch
# model (Parakeet Batch, which labels speakers) after the call on its own only
# when the live transcript broke off or the meeting has two or more remote
# participants. So:
#   - a transcript Anarlog already rewrote with its Batch pass is used as is;
#   - otherwise the meeting's own recording is always imported through
#     `anarlog meetings import` as a second meeting titled "<title> (speaker
#     pass)", which Anarlog transcribes after the call with its Batch model, and
#     its transcript is the one the intake reads;
#   - the live transcript is used only when no recording was kept, or the
#     speaker pass failed or did not finish within speaker_pass_wait_minutes;
#     the intake's outcome then says so.
#
# GLASSES CALLS. Audio exported from a phone app into `glasses_folder` (default
# iCloud Drive/Starship calls) is imported into Anarlog the same way once the
# file has stopped changing for a minute; Anarlog transcribes it with its Batch
# model, in whichever of its configured spoken languages it hears (add Dutch
# next to English in Anarlog's Language & Region settings for Dutch calls), and
# the imported meeting then flows through the same intake once Anarlog's
# summary of it is in, or ten minutes after its transcript. iCloud placeholders
# are asked to download first. Files in the folder are never moved or deleted;
# non-audio files are listed by `status` and skipped.
#
# INTAKE. `intake` takes in each announced meeting once:
#   - Work meetings stay out. A meeting whose title, participants, notes,
#     summary or transcript match a work word (each `work_marker`, plus every
#     line of the private config/meeting-work-words, one word or phrase per
#     line with `#` comments; neither ships with any word) is never sent to a
#     model or actioned; intake prints only `work meeting, not processed:
#     <title>`.
#   - Otherwise one model pass (`claude -p`, no tools, no session) reads a
#     bounded copy of the meeting: Anarlog's summary, the captain's own notes,
#     action items and the transcript, capped at transcript_chars characters.
#   - Paragraphs where someone says "Firstmate, do it", "Firstmate, build that"
#     or "captain's order" are found first and handed to the model as
#     spoken-order candidates. They are read from the meeting's own transcript,
#     where Anarlog labels the captain's speech (the live one when a speaker
#     pass ran), and from the speaker-pass transcript too, each numbered once;
#     the model groups the copies of one order into one entry, and a candidate
#     no entry covers waits as an order that could not be read clearly. An
#     order counts as a clear action only when its quoted source is in a copy
#     said under the captain's own speaker label; one said by another labelled
#     speaker, one where the transcript never labels the captain, and one heard
#     only in the speaker pass (so it could not tell who said it) stays for
#     review. An action that is the same step as a spoken order (its quoted
#     source contains or lies within the order's quoted source, or it carries
#     the same instruction) is filed only as that spoken order, so this rule
#     alone decides whether it starts. Any other action whose quoted source
#     lies in a candidate is kept but waits, because it was said alongside a
#     spoken order.
#   - Each outcome is sorted in two. A clear, low-risk, internal follow-up whose
#     quoted source is found in the meeting goes to firstmate as ready-to-start
#     work: one inbox note per meeting (`fm-inbox.sh note --request-id
#     meeting-<id>-start`). Everything else - needing review or refinement,
#     outward-facing (an instruction to send, reply, email, message, post,
#     publish, pay, buy, sign, invite or call someone; "call", "phone",
#     "message" and "post" count as nouns only right after a word like "the",
#     "our" or "on"), destructive (delete or
#     remove), touching another person's commitment, or whose
#     source cannot be found - goes in a second note (`meeting-<id>-review`)
#     for firstmate to put on the captain's phone tap page, where it waits.
#     This layer itself sends nothing anywhere outside this Mac's own inbox.
#   - One spoken line goes to the desk through fm-speak.sh (inert unless the
#     home turned desk voice on), and the record is kept in
#     data/meetings/<id>/intake.json, which `recall` searches.
# A failed intake leaves the meeting ready for the next `intake`, and after
# three failures marks it failed. The request ids make a repeated intake reuse
# its notes rather than file them twice.
#
# RECALL. `recall` answers "what did we agree with <person>" from the intake
# records and Anarlog's title search, leaving out work meetings, and prints
# date, title, people, outcome, follow-ups and Anarlog's own action items and
# summary for the asker to answer from. Anarlog's own MCP server (`anarlog
# mcp`) is the richer route for an agent that has it connected.
#
# CONFIG. Optional, private, gitignored config/meetings: `key = value` lines,
# `#` comments; an unknown key is refused. docs/examples/meetings lists every
# key with its default:
#   speaker_pass_wait_minutes  how long to wait for the speaker pass before using the live transcript (180)
#   glasses_folder             the shared-audio folder, or off
#   work_marker                a work word or phrase; repeatable
#   self_label                 another transcript label that is the captain; repeatable
#   intake_model               the Claude model for the intake (sonnet)
#   transcript_chars           how much of the meeting the model reads (60000)
#
# RECORDS. state/meetings/records.json (what each meeting and shared file has
# reached; locked, written by rename), state/meetings/check-problem (the last
# failed or timed-out check line, so it wakes once until a poll succeeds) and
# data/meetings/<id>/intake.json.
#
# Environment overrides (tests): FM_MEETINGS_ANARLOG, FM_MEETINGS_CLAUDE,
# FM_MEETINGS_INBOX, FM_MEETINGS_SPEAK, FM_MEETINGS_NOW, FM_MEETINGS_PYTHON,
# FM_MEETINGS_CHECK_BUDGET (seconds, 5..25, default 20).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
export FM_HOME
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CHECK_ID=meetings
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
PYTHON_BIN=${FM_MEETINGS_PYTHON:-python3}
CORE="$SCRIPT_DIR/fm-meetings.py"
MAX_LINE=400

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  sed -n '3,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  printf '\nThe header of %s owns the full contract; docs/meetings.md is the operator guide.\n' "${BASH_SOURCE[0]}"
}

die_usage() {
  printf 'fm-meetings: %s\n' "$1" >&2
  usage >&2
  exit 2
}

core() {
  "$PYTHON_BIN" "$CORE" "$@"
}

CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in
  ''|*[!0-9]*|0) CHECK_TIMEOUT=30 ;;
esac

action_check() {
  local budget=${FM_MEETINGS_CHECK_BUDGET:-20} out rc=0 line problem="" marker="$STATE/meetings/check-problem"
  case "$budget" in
    ''|*[!0-9]*) budget=20 ;;
  esac
  [ "$budget" -ge 5 ] || budget=5
  [ "$budget" -le 25 ] || budget=25
  # The core stops starting new work at its budget; the timer is the backstop
  # inside the watcher's own bound, with the alarm and kill margins left over.
  [ "$budget" -le $((CHECK_TIMEOUT - 5)) ] || budget=$((CHECK_TIMEOUT - 5))
  [ "$budget" -ge 1 ] || budget=1
  out=$(fm_run_timed $((budget + 3)) "$PYTHON_BIN" "$CORE" poll --budget "$budget" 2>&1) || rc=$?
  if [ "$rc" -eq 124 ]; then
    problem="meetings: the poll did not finish within $((budget + 3))s; it carries on at the next check"
  elif [ "$rc" -ne 0 ]; then
    problem="meetings: the poll failed: $(printf '%s\n' "$out" | sed -n '$p')"
  fi
  if [ -n "$problem" ]; then
    line=
    if [ "$(cat "$marker" 2>/dev/null)" != "$problem" ]; then
      line=$problem
      mkdir -p "$STATE/meetings" && printf '%s\n' "$problem" > "$marker"
    fi
  else
    rm -f -- "$marker"
    line=$(printf '%s\n' "$out" | sed -n '/^meetings: /p' | sed -n '1p')
  fi
  if [ -n "$line" ]; then
    fm_cap_line_var "$line" "$MAX_LINE"
    printf '%s\n' "$FM_LINE_CAP_LINE"
  fi
  return 0
}

# The home is embedded already resolved, because the watcher runs the shim from
# its own working directory and a relative spelling would send the check to a
# different home, or to none at all.
shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-meetings.sh - finished-meeting poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-meetings.sh") check"
}

# Write the shim the way this repo writes its other trusted check shims: the
# guards run before anything is written, so a symlink at the shim path is
# refused instead of followed, and the bytes arrive by rename so the watcher
# never reads a half-written shim and rejects it as unauthenticated.
SHIM_WRITE_TMP=

shim_write() {
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-meetings-check.XXXXXX" 2>/dev/null) || return 1
  SHIM_WRITE_TMP=$tmp
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  SHIM_WRITE_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

# An unregistered shim is not inert: the watcher rejects it on every cycle and
# wakes firstmate about unauthenticated state checks. So a failed or
# interrupted arm never leaves a shim without a matching trust binding.
arm_rollback() {
  [ -z "$SHIM_WRITE_TMP" ] || rm -f -- "$SHIM_WRITE_TMP"
  SHIM_WRITE_TMP=
  fm_custom_check_registered "$STATE" "$CHECK_ID" || rm -f -- "$CHECK_SHIM"
}

# shellcheck disable=SC2329  # Registered by action_arm's signal trap.
arm_interrupted() {
  arm_rollback
  printf 'fm-meetings: arming was interrupted, so state/%s.check.sh is not armed\n' "$CHECK_ID" >&2
  exit 1
}

action_arm() {
  local want home
  command -v "$PYTHON_BIN" >/dev/null 2>&1 || {
    printf 'fm-meetings: %s is required to arm the meetings check\n' "$PYTHON_BIN" >&2
    return 1
  }
  mkdir -p "$STATE" || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-meetings: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  FM_HOME="$home" core baseline >/dev/null || return 1
  want=$(shim_content "$home")
  # The shim exists unbound from the rename until the register returns, so a
  # signal in that window rolls back the same way a failure does.
  trap arm_interrupted HUP INT TERM
  if ! shim_write "$want"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-meetings: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    rm -f -- "$CHECK_SHIM"
    printf 'fm-meetings: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
  printf 'disarmed: state/%s.check.sh (meeting records kept)\n' "$CHECK_ID"
  return 0
}

case "${1:-}" in
  check) action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  poll|intake|recall|status) core "$@" ;;
  -h|--help) usage ;;
  '') die_usage "an action is required" ;;
  *) die_usage "unknown action: $1" ;;
esac
