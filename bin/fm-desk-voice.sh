#!/usr/bin/env bash
# Desk-voice delivery: captain-input transcripts and screenshots from the Mac
# floater.
#
# Usage:
#   fm-desk-voice.sh send [--source <name>] [--image <png>]... [<transcript text...>]
#   fm-desk-voice.sh send --front-app <pid> --front-tty <tty> [--source <name>] [<text...>]
#   fm-desk-voice.sh deliver [--source <name>] [--image <png>]... [<transcript text...>]
#   fm-desk-voice.sh ring <line>
#   fm-desk-voice.sh shot [--display <n>]
#   fm-desk-voice.sh keep [--purpose firstmate|dictate] [--reason <text>] <audio-file>
#   fm-desk-voice.sh recordings
#   fm-desk-voice.sh retry [<saved-recording>...]
#   fm-desk-voice.sh pending
#   fm-desk-voice.sh drain [--print]
#   fm-desk-voice.sh --help
#
# WHY: the floater is mouth/ears only. Transcripts meant for Firstmate must not
# be pasted into random terminals, and the floater must not act as a second
# Firstmate. The only terminal this script ever types into is the primary
# session that holds this home's session lock. (The floater's separate
# dictation mode pastes into the text box the captain chose, and reaches this
# script only through send --front-app below, when that text box is the
# primary's own chat; see docs/desk-floater.md.)
#
# send is the floater's talk-to-firstmate path. It types the message (the
# transcript and any screenshots, composed as deliver composes them) into
# the primary's own chat pane and presses Enter, so the words arrive at once,
# even mid-turn, without that pane needing focus. The pane is resolved from
# state/.lock: the lock's pid must be a live harness, the pane named by that
# process's own environment (TMUX_PANE, or HERDR_ENV + HERDR_PANE_ID, with the
# precedence bin/fm-supervisor-target-lib.sh owns) must exist, and the pane's
# root process must be that pid or one of its ancestors. The pane's composer
# must also read empty or pending (bin/fm-backend.sh fm_backend_composer_state):
# an unknown screen can be a modal dialog, a picker, or a dead shell, where
# typed words become keypresses. Claude's dim suggested prompt is not typed
# text, so a box showing only that reads empty. A screen showing a selection
# dialog (a pointer on a numbered option, or an Enter to select / Esc to
# cancel footer) is refused too, whatever the composer reads. Delivery goes
# through the backend's submit primitive (bin/fm-backend.sh
# fm_backend_send_text_submit), so any backend that can report a pane's root
# pid below can be added. When a Claude primary's box holds the captain's
# unsent draft (pending), the message goes past it instead: see
# send_past_draft below, which never submits, clears, or retypes the draft.
# Another harness's draft is joined by the message and submitted with it. A
# message of screenshots alone is the exception: it is typed only into a
# composer that reads empty, and goes to the mailbox past any draft, because
# a stray screenshot must never interrupt the captain's typing. The
# text is sent as the captain's plain words: control characters, newlines, and
# Unicode line separators become spaces, so nothing can submit early or reach
# the pane as a key.
# Outcomes, one line on stdout, exit 0:
#   sent: <backend> <target>              typed and submit confirmed
#   sent-unconfirmed: <backend> <target> (<verdict>)
#                                         typed and Enter sent, submit not
#                                         proven; never re-sent to the mailbox
#   mailbox: <path>                       the pane could not be resolved, its
#                                         composer was not empty or pending
#                                         (not empty, for screenshots alone),
#                                         it showed a selection dialog, a
#                                         Claude draft could not be set aside,
#                                         or the backend reported send-failed,
#                                         its known-undelivered verdict; the
#                                         message went to the mailbox below
#   not-in-front                          with --front-app and --front-tty
#                                         only: the chat is not what the
#                                         captain is typing in; nothing sent
# A message therefore reaches the primary exactly one way.
#
# send --front-app <pid> --front-tty <tty> is the floater's dictation path: it
# sends only when the text box with the cursor is the primary's own chat, and
# otherwise prints "not-in-front" and delivers nothing, so the floater pastes
# the text where the cursor is instead. <pid> is the frontmost Mac app and
# <tty> the terminal device of its frontmost tab. The chat is in front when
# the proven primary pane is the multiplexer's focused pane (herdr: that
# pane's own focused flag; tmux: the active pane of its session's active
# window) and a client of that multiplexer runs on <tty> beneath <pid>. A
# herdr client is found by the kernel's socket facts (lsof): a process whose
# unix socket peers with a socket of the server that owns this pane's API
# socket, and whose standard input is <tty>. An unresolved primary counts as
# not in front. Once in front, every send check above still applies, so an
# unreadable chat or a selection dialog still goes to the mailbox.
#
# ring is the mid-turn doorbell other captain-input paths use: it types <line>
# into the same proven primary pane, with every send check above, and never
# falls back to the mailbox, because the caller has already queued its own
# durable wake. It types only into a composer that reads empty, so a draft the
# captain is writing is never submitted with it. One line on stdout, exit 0:
#   rung: <backend> <target>              typed and submit confirmed
#   rung-unconfirmed: <backend> <target> (<verdict>)
#   not-rung                              nothing typed; the queued wake stands
# Ring and send share a per-home pane-writer lock through inspection, typing,
# submission and recovery. On contention send uses its mailbox and ring leaves
# its queued wake alone. Ring leaves a Claude stash alone, and send presses
# Enter only once over one, as a stash is restored on submission. Before every
# ring Enter, including retries, the box must still show only the ring's
# literal payload.
#
# deliver is the mailbox path. Transcripts land under
#   $FM_HOME/state/desk-voice/inbox/<utc>-<id>.json
# and a single wake is appended so the primary can see and drain them.
# A wake alone reaches a busy primary only at its next turn end, minutes
# later, so deliver also rings the primary, as a captain inbox note does: a
# detached ring (ring above, with every one of its checks) of one labelled
# line asking it to drain now. A ring that cannot be typed yet is tried again
# after FM_DESK_VOICE_RING_DELAYS seconds
# (default "0 2 5 10 20 30 60 60 60", about four minutes in all; empty turns
# the ring off). The ring stops once it is typed, once the message has been
# drained, when no proven primary holds the session lock, or in away or quiet
# mode, whose own supervision owns wakes.
# The queued wake stays the durable delivery either way.
#
# deliver --image (repeatable, absolute path to an existing file) attaches
# screenshots: the message becomes the transcript, if any, followed by one line
# "Screenshots: <path> <path>...", and the JSON also lists them under "images".
# A message may be screenshots alone.
#
# shot captures one whole display (screencapture's -D numbering, 1 = main;
# the main display when omitted) to
#   $FM_HOME/state/desk-voice/shots/<utc-with-microseconds>-<id>.png
# prints that path, and prunes the folder to the newest FM_DESK_SHOTS_KEEP
# (default 30) images. It never delivers anything by itself. The capture
# command is FM_DESK_SHOT_CAPTURE (default screencapture), called as
# <cmd> -x -t png [-D <n>] <file>; tests point it at a stub.
#
# keep, recordings and retry make sure a recording is never lost. The floater
# records into state/desk-voice/recording/ and keeps that audio until its
# words are delivered; when transcription fails, hears nothing in a recording
# worth keeping, or delivery fails, it hands the audio to keep, which moves it
# into state/desk-voice/unsent/ (folder 0700, files 0600) beside a small JSON
# record of its purpose (talk to Firstmate, or dictation), how many attempts
# it has had, and why the last one failed, and prints the saved path. A saved
# recording is never removed automatically: only once retry delivers its words
# (or prints them, for dictation), or when the owner deletes it.
# recordings lists them oldest first, one line each:
#   <path> TAB <purpose> TAB <attempts> TAB <saved-at> TAB <last reason>
# retry transcribes the named saved recordings again (every saved one when
# none is named) through bin/fm-deepgram-stt.sh, one at a time under one lock,
# and prints one line each (exit 0):
#   delivered TAB <path> TAB <send outcome>   talk to Firstmate: the words went
#                                         through send above, and the recording
#                                         is removed
#   transcript TAB <path> TAB <text>      dictation: the words on one line, for
#                                         the caller to paste; the recording is
#                                         removed
#   unsent TAB <path> TAB <attempts> TAB <reason>
#                                         still not delivered; kept for later
#   busy TAB <path>                       another retry holds the lock
#   gone TAB <path>                       already delivered or removed
# Only files inside the unsent folder are retried.
#
# Drain moves files to state/desk-voice/processed/ and prints each transcript
# (one JSON object per line with --print, plain text otherwise). The primary
# treats drained text as captain input.
#
# Exit: 0 ok, 1 failure, 2 bad usage.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
INBOX="$STATE/desk-voice/inbox"
PROCESSED="$STATE/desk-voice/processed"
SHOTS="$STATE/desk-voice/shots"
UNSENT="$STATE/desk-voice/unsent"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$SCRIPT_DIR/fm-supervisor-target-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$SCRIPT_DIR/fm-composer-lib.sh"

# The pane environment keys read from the primary's process.
PANE_ENV_RE='^(TMUX|TMUX_PANE|HERDR_ENV|HERDR_PANE_ID|HERDR_SESSION|HERDR_SOCKET_PATH)='

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

note() {
  printf 'fm-desk-voice: %s\n' "$*" >&2
}

die() {
  note "$*"
  exit 1
}

refuse() {
  note "$*"
  exit 2
}

ensure_dirs() {
  mkdir -p "$INBOX" "$PROCESSED" || die "cannot create desk-voice mailbox dirs"
  chmod 700 "$STATE/desk-voice" "$INBOX" "$PROCESSED" 2>/dev/null || true
}

write_transcript_json() {  # <path> <stamp> <id> <source> <text> [<image>...]
  python3 - "$@" <<'PY'
import json, sys
path, stamp, rid, source, text = sys.argv[1:6]
images = sys.argv[6:]
doc = {
    "schema": "fm-desk-voice-transcript.v1",
    "id": rid,
    "created_at": stamp,
    "source": source,
    "transcript": text,
}
if images:
    doc["images"] = images
with open(path, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, ensure_ascii=False)
    fh.write("\n")
PY
}

# Parse "[--source <name>] [--image <png>]... [--] [<text...>]" into ARG_SOURCE,
# ARG_IMAGES and ARG_TEXT (empty when the text is blank).
parse_transcript_args() {
  ARG_SOURCE=desk-floater
  ARG_IMAGES=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source)
        [ "$#" -ge 2 ] || refuse "--source needs a name"
        ARG_SOURCE=$2
        shift 2
        ;;
      --image)
        [ "$#" -ge 2 ] || refuse "--image needs a path"
        case "$2" in
          /*) ;;
          *) refuse "--image needs an absolute path: $2" ;;
        esac
        [ -f "$2" ] || refuse "no such image: $2"
        ARG_IMAGES+=("$2")
        shift 2
        ;;
      --) shift; break ;;
      -*) refuse "unexpected option: $1" ;;
      *) break ;;
    esac
  done
  ARG_TEXT=$*
  case "$ARG_TEXT" in
    *[![:space:]]*) ;;
    *) ARG_TEXT='' ;;
  esac
}

# The message the parsed arguments make: the transcript, if any, then one
# "Screenshots: <path>..." line when images are attached.
message_text() {
  local text=$ARG_TEXT
  if [ "${#ARG_IMAGES[@]}" -gt 0 ]; then
    text="${text:+$text
}Screenshots: ${ARG_IMAGES[*]}"
  fi
  printf '%s' "$text"
}

deliver() {
  local source text id stamp path tmp
  parse_transcript_args "$@"
  source=$ARG_SOURCE
  text=$(message_text)
  [ -n "$text" ] || refuse "nothing to deliver"

  ensure_dirs
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  id=$(python3 -c 'import secrets; print(secrets.token_hex(4))')
  path="$INBOX/${stamp}-${id}.json"
  tmp=$(mktemp "$INBOX/.tmp.XXXXXX") || die "cannot create temp transcript"

  if ! write_transcript_json "$tmp" "$stamp" "$id" "$source" "$text" ${ARG_IMAGES[@]+"${ARG_IMAGES[@]}"}; then
    rm -f "$tmp"
    die "cannot write transcript JSON"
  fi
  mv "$tmp" "$path" || die "cannot finalize transcript"
  chmod 600 "$path" 2>/dev/null || true

  # Wake the primary: one check wake naming the durable file.
  fm_wake_append check desk-voice "desk-voice: $path" \
    || note "transcript saved but wake append failed; primary will see it on next drain"
  ring_mailbox "$path"

  # Best-effort macOS notice so a human at the desk knows something landed.
  if command -v osascript >/dev/null 2>&1; then
    osascript -e 'display notification "Desk voice transcript ready" with title "Firstmate"' \
      >/dev/null 2>&1 || true
  fi

  printf '%s\n' "$path"
}

# Rings the primary about mailbox message <path> in the background, trying
# again on the FM_DESK_VOICE_RING_DELAYS schedule (see the header). Its output
# goes nowhere, so a caller reading this script's output (the floater) is
# never held by it.
ring_mailbox() {  # <path>
  local path=$1 delays=${FM_DESK_VOICE_RING_DELAYS-0 2 5 10 20 30 60 60 60} delay
  local line='[firstmate desk-voice] a desk voice message is waiting in the mailbox. Run bin/fm-wake-drain.sh now to pick it up; it stays queued until handled and acknowledged.'
  [ -n "${delays// /}" ] || return 0
  for delay in $delays; do
    case "$delay" in
      ''|*[!0-9]*) note "FM_DESK_VOICE_RING_DELAYS must be whole seconds; not ringing"; return 0 ;;
    esac
  done
  (
    trap '' HUP
    local result
    for delay in $delays; do
      sleep "$delay"
      [ -e "$path" ] || exit 0
      [ ! -e "$STATE/.afk" ] && [ ! -e "$STATE/.afk-contract" ] || exit 0
      result=$(ring_line "$line") || exit 0
      [ "$result" = not-rung ] || exit 0
    done
  ) </dev/null >/dev/null 2>&1 &
}

# The captain's words as one typed line: every control character (C0, DEL,
# C1) and Unicode line or paragraph separator becomes a space, then runs of
# whitespace collapse, so no byte can submit early or act as a key.
plain_line() {  # <text>
  python3 -c '
import sys, unicodedata
text = "".join(" " if unicodedata.category(c) in ("Cc", "Zl", "Zp") else c for c in sys.argv[1])
sys.stdout.write(" ".join(text.split()))
' "$1"
}

# The pane keys from process <pid>'s own environment, one KEY=VALUE per line.
# Linux exposes it in /proc; macOS ps -E prints argv then the environment, so
# the last occurrence of a key wins. macOS withholds the environment of Apple
# platform binaries, which no verified harness is.
holder_pane_env() {  # <pid>
  local pid=$1
  if [ -r "/proc/$pid/environ" ]; then
    tr '\0' '\n' < "/proc/$pid/environ"
  else
    ps -E -ww -o command= -p "$pid" 2>/dev/null | tr ' ' '\n'
  fi | awk -v re="$PANE_ENV_RE" '
    $0 ~ re { key = $0; sub(/=.*/, "", key); seen[key] = $0 }
    END { for (key in seen) print seen[key] }
  '
}

# The pid at the root of <target>'s pane. A backend without an arm here cannot
# prove which process its pane hosts, so it falls back to the mailbox.
pane_root_pid() {  # <backend> <target>
  local backend=$1 target=$2 info
  case "$backend" in
    tmux)
      tmux display-message -p -t "$target" '#{pane_pid}' 2>/dev/null
      ;;
    herdr)
      fm_backend_source herdr || return 1
      fm_backend_herdr_parse_target "$target" || return 1
      info=$(fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane process-info \
        --pane "$FM_BACKEND_HERDR_PANE" 2>/dev/null) || return 1
      printf '%s' "$info" | jq -er --arg pane "$FM_BACKEND_HERDR_PANE" '
        select(.result.process_info.pane_id == $pane)
        | .result.process_info.shell_pid | select(type == "number" and . > 1) | floor
      ' 2>/dev/null
      ;;
    *) return 1 ;;
  esac
}

# True when <pid> is <root> or runs beneath it.
pid_within() {  # <pid> <root>
  local pid=$1 root=$2 hops=0
  case "$root" in ''|*[!0-9]*) return 1 ;; esac
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] && [ "$hops" -lt 64 ]; do
    [ "$pid" = "$root" ] && return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    hops=$((hops + 1))
  done
  return 1
}

# True when <target>'s screen shows a selection dialog (a permission prompt, a
# question, a picker), where typed words would pick an option. The shared
# composer classifier already refuses a pointer on a numbered option; this
# also catches the dialog footers it does not read. An unreadable screen counts.
shows_selection_dialog() {  # <backend> <target>
  local screen
  screen=$(fm_backend_capture "$1" "$2" "${FM_COMPOSER_CAPTURE_LINES:-20}" 2>/dev/null) || return 0
  printf '%s\n' "$screen" | grep -Eiq '(❯|›)[[:space:]]*[0-9]+\.|enter to select|esc to cancel'
}

# The text in <target>'s chat box as the last [rows] screen rows show it, or
# fail when no box can be read. A dim suggested prompt reads as text here, so
# ask fm_backend_composer_state whether the box is empty.
composer_text() {  # <backend> <target> [rows]
  local cap
  cap=$(fm_backend_capture "$1" "$2" "${3:-${FM_COMPOSER_CAPTURE_LINES:-20}}" 2>/dev/null) || return 1
  fm_composer_extract_selected_content styled=0 "$cap"
}

# <text> with its spaces normalized and all whitespace removed, so two readings
# of the same words compare equal however they wrap.
squeezed() {  # <text>
  local text=$1
  fm_composer_normalize_spaces_var text
  text=${text//[$' \t\r\n\v\f']/}
  printf '%s' "${text//$'\xE2\x81\xA3'/}"
}

# True when Claude's footer shows a stashed draft (`› stashed`). An unreadable
# screen counts, so a stash the captain already keeps is never replaced.
shows_stash() {  # <backend> <target>
  local screen
  screen=$(fm_backend_capture "$1" "$2" "${FM_COMPOSER_CAPTURE_LINES:-20}" 2>/dev/null) || return 0
  printf '%s\n' "$screen" | fm_composer_strip_ansi | grep -Eq '›[[:space:]]*stashed[[:space:]]*$'
}

# Put <text> into <target> as one bracketed paste, without submitting it.
# Claude reads a paste whole and shows one over 800 characters as a single
# `[Pasted text #N]` placeholder; a typed burst that long can lose its head or
# fold into placeholders plus a literal tail, which no proof can tell from a
# truncated message (verified live on claude 2.1.283). <text> is one plain
# line (plain_line), so it holds no escape that could end the paste early.
paste_text() {  # <backend> <target> <text>
  local buffer="fm-desk-voice-$$"
  fm_backend_source "$1" || return 1
  case "$1" in
    tmux)
      printf '%s' "$3" | tmux load-buffer -b "$buffer" - \
        && tmux paste-buffer -p -d -b "$buffer" -t "$2"
      ;;
    herdr) fm_backend_herdr_send_literal "$2" $'\033[200~'"$3"$'\033[201~' ;;
    *) return 1 ;;
  esac
}

# Poll <target>'s composer verdict until it reads <want>; 0 when it did.
await_composer() {  # <backend> <target> <want> <tries>
  local i=0
  while [ "$i" -lt "$4" ]; do
    [ "$(fm_backend_composer_state "$1" "$2" 2>/dev/null)" = "$3" ] && return 0
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

# Put a draft this script stashed back into the box: Ctrl+S on an empty box
# pops the stash. Pressed only while the box reads empty, because on a box
# holding text Ctrl+S would stash that text over the draft. 0 when the draft
# is back in the box.
unstash_draft() {  # <backend> <target>
  await_composer "$1" "$2" empty 5 || return 1
  fm_backend_send_key "$1" "$2" C-s >/dev/null 2>&1 || return 1
  await_composer "$1" "$2" pending 10
}

# Send <line> past the captain's unsent draft in a Claude primary's chat box.
# Ctrl+S stashes the draft, with its pasted text and images, and empties the
# box; Claude puts the draft back by itself the moment the next message is
# submitted, and mid-turn too, where that message is queued (verified live on
# claude 2.1.283; docs/verification/runtime-backends.md "Desk floater send
# past a draft"). So the message is pasted (paste_text) only into a box the
# stash has emptied, and Enter is pressed once, only while the box shows
# exactly the message, or only the placeholder a long paste becomes, never
# again: a second Enter after Claude restored the draft would
# submit the draft. The proof reads, and the Ctrl+U presses that clear a
# refused message, are sized by the message, which wraps (fm_composer_proof_lines).
# The proof is read for up to 3s before it is refused: a busy chat draws a
# paste late but handles it before any later key, so a box that still reads
# empty early on may yet show the message, and a Ctrl+S then would stash it
# over the draft.
# After Enter the message was submitted only once the box reads empty or
# shows the captain's draft again: Claude can redraw a long message it has not
# submitted as pasted-text placeholders plus its tail, which is neither the
# proven text nor the message.
# The one deliberate exception where text in the box still sends the message
# to the mailbox: a footer that already shows `› stashed`, because a second
# stash would replace the one the captain keeps, and an existing Claude stash
# is never overwritten. Prints the submit vocabulary: empty (submitted),
# send-failed (not submitted; the draft is back in the box or a note says it
# is stashed), unknown (typed, and the box could not be proven empty again).
send_past_draft() {  # <backend> <target> <line>
  local backend=$1 target=$2 line=$3 draft after shown rows i
  if shows_stash "$backend" "$target" \
    || ! draft=$(composer_text "$backend" "$target") || [ -z "$draft" ]; then
    printf 'send-failed'
    return 0
  fi
  fm_backend_send_key "$backend" "$target" C-s >/dev/null 2>&1 || { printf 'send-failed'; return 0; }
  if ! await_composer "$backend" "$target" empty 10; then
    note "the chat box did not set the captain's draft aside"
    printf 'send-failed'
    return 0
  fi
  if ! shows_stash "$backend" "$target"; then
    if unstash_draft "$backend" "$target"; then
      note "the chat box did not show the captain's draft as stashed, so it was put back"
    else
      note "the captain's draft may be stashed; Ctrl+S in the chat brings it back"
    fi
    printf 'send-failed'
    return 0
  fi
  if ! paste_text "$backend" "$target" "$line"; then
    unstash_draft "$backend" "$target" || note "the captain's draft is stashed; Ctrl+S in the chat brings it back"
    printf 'send-failed'
    return 0
  fi
  rows=$(fm_composer_proof_lines "$line")
  i=0
  while sleep 0.2; ! after=$(composer_text "$backend" "$target" "$rows") \
    || ! fm_composer_payload_shown "$line" "$after"; do
    i=$((i + 1))
    [ "$i" -lt 15 ] || break
  done
  if [ "$i" -ge 15 ]; then
    # An empty/unreadable box is not acknowledgment that the paste was handled.
    # A queued paste would run before recovery keys, replacing the saved draft.
    if [ -z "${after:-}" ] \
      || [ "$(fm_backend_composer_state "$backend" "$target" 2>/dev/null)" != pending ]; then
      note "the paste has not appeared; the draft remains stashed, and no recovery keys were sent"
      printf 'unknown'
      return 0
    fi
    i=0
    while ! await_composer "$backend" "$target" empty 1; do
      if [ "$i" -ge "$rows" ] || ! fm_backend_send_key "$backend" "$target" C-u >/dev/null 2>&1; then
        note "the captain's draft is stashed; Ctrl+S in the chat brings it back once the box is empty"
        printf 'unknown'
        return 0
      fi
      i=$((i + 1))
    done
    unstash_draft "$backend" "$target" || note "the captain's draft is stashed; Ctrl+S in the chat brings it back"
    printf 'send-failed'
    return 0
  fi
  shown=$(squeezed "$after")
  draft=$(squeezed "$draft")
  fm_backend_send_key "$backend" "$target" Enter >/dev/null 2>&1 || { printf 'unknown'; return 0; }
  i=0
  while :; do
    sleep 0.2
    if [ "$(fm_backend_composer_state "$backend" "$target" 2>/dev/null)" = empty ] \
      || { [ "$draft" != "$shown" ] && after=$(composer_text "$backend" "$target") \
        && [ "$(squeezed "$after")" = "$draft" ]; }; then
      printf 'empty'
      return 0
    fi
    i=$((i + 1))
    [ "$i" -lt 15 ] || { printf 'unknown'; return 0; }
  done
}

# Ring input is short literal text. Do not accept a pasted-text placeholder as
# proof of its contents: it could be a new draft. The proof is read for up to
# 3s while the box still reads empty, perhaps under a dim suggestion, or shows
# only the start of the ring, as a busy chat draws a paste late; any other
# text refuses it at once. After Enter the box gets 3s to read empty before
# it counts as swallowed; a retry needs the box to still show only the ring
# and no stash Claude could restore into it.
# Whitespace normalization is only for the composer's line wrapping.
submit_ring() {  # <backend> <target> <line>
  local backend=$1 target=$2 line=$3 expected shown after rows i=0 tries=1
  rows=$(fm_composer_proof_lines "$line")
  expected=$(squeezed "$line")
  paste_text "$backend" "$target" "$line" || { printf 'send-failed'; return 0; }
  while sleep 0.2; do
    if [ "$(fm_backend_composer_state "$backend" "$target" 2>/dev/null)" != empty ]; then
      after=$(composer_text "$backend" "$target" "$rows") || after=''
      shown=$(squeezed "$after")
      [ "$shown" != "$expected" ] || break
      case $expected in "$shown"*) ;; *) printf 'unknown'; return 0 ;; esac
    fi
    i=$((i + 1))
    [ "$i" -lt 15 ] || { printf 'unknown'; return 0; }
  done
  while fm_backend_send_key "$backend" "$target" Enter >/dev/null 2>&1; do
    ! await_composer "$backend" "$target" empty 15 || { printf 'empty'; return 0; }
    [ "$tries" -lt 3 ] && ! shows_stash "$backend" "$target" \
      && after=$(composer_text "$backend" "$target" "$rows") \
      && [ "$(squeezed "$after")" = "$expected" ] || break
    tries=$((tries + 1))
  done
  printf 'unknown'
}

# The pids of the herdr clients attached to the server that owns <socket> (the
# pane's API socket) and runs <root>, one per line. A client is a process
# whose unix socket peers with one of that server's other sockets.
herdr_client_pids() {  # <socket> <root>
  local socket=$1 root=$2 listing server
  listing=$(lsof -U -F pdn 2>/dev/null) || [ -n "$listing" ] || return 1
  for server in $(printf '%s\n' "$listing" | awk -v sock="$socket" '
    /^p/ { pid = substr($0, 2) }
    /^n/ && substr($0, 2) == sock { print pid }
  ' | sort -u); do
    pid_within "$root" "$server" || continue
    printf '%s\n' "$listing" | awk -v sock="$socket" -v server="$server" '
      /^p/ { pid = substr($0, 2); next }
      /^d/ { dev = substr($0, 2); next }
      /^n/ {
        name = substr($0, 2)
        if (pid == server && name != sock) { mine[dev] = 1 }
        else if (pid != server && name ~ /^->/) { peer[pid] = peer[pid] " " substr(name, 3) }
      }
      END {
        for (p in peer) {
          n = split(peer[p], addrs, " ")
          for (i = 1; i <= n; i++) if (addrs[i] in mine) { print p; break }
        }
      }
    '
    return 0
  done
  return 1
}

# The terminal device on <pid>'s standard input.
stdin_tty() {  # <pid>
  lsof -a -p "$1" -d 0 -F n 2>/dev/null | sed -n 's/^n//p' | head -n 1
}

# True when <target> is what the captain sees in the frontmost tab <tty> of
# app <app>: the multiplexer's focused pane, shown by a client on <tty>
# running beneath <app>. <root> is the pane's proven root pid.
shown_in_front() {  # <backend> <target> <root> <app> <tty>
  local backend=$1 target=$2 root=$3 app=$4 tty=$5 client info session
  case "$backend" in
    herdr)
      fm_backend_herdr_parse_target "$target" || return 1
      fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane get "$FM_BACKEND_HERDR_PANE" 2>/dev/null \
        | jq -e --arg pane "$FM_BACKEND_HERDR_PANE" \
          '.result.pane | select(.pane_id == $pane) | .focused == true' >/dev/null 2>&1 \
        || return 1
      [ -n "${HERDR_SOCKET_PATH:-}" ] || return 1
      for client in $(herdr_client_pids "$HERDR_SOCKET_PATH" "$root"); do
        [ "$(stdin_tty "$client")" = "$tty" ] && pid_within "$client" "$app" && return 0
      done
      ;;
    tmux)
      info=$(tmux display-message -p -t "$target" '#{session_id} #{window_active}#{pane_active}' 2>/dev/null) \
        || return 1
      session=${info% *}
      [ "${info##* }" = 11 ] || return 1
      while read -r client info; do
        [ "$info" = "$tty" ] && pid_within "$client" "$app" && return 0
      done <<EOF
$(tmux list-clients -t "$session" -F '#{client_pid} #{client_tty}' 2>/dev/null)
EOF
      ;;
  esac
  return 1
}

# Type <line> into the lock-holding primary's own pane and submit it. Prints
# "<verdict><TAB><backend><TAB><target>" once the pane is proven to host the
# primary and show its chat input. Returns 1 when the pane is not proven, or
# with <app> and <tty> is not in front (see shown_in_front), and 2 when it is
# proven but not showing its chat input, another writer owns it, or a ring
# finds a stash; nothing was typed either way. PRIMARY_SUBMIT_COMPOSER lists
# the composer states that may take the line (default "empty pending"), and
# PRIMARY_SUBMIT_RING=1 submits it the way ring does. Its subshell scopes the pane environment and writer lock.
primary_submit() (  # <line> [<app> <tty>]
  local lock="$STATE/.lock" pid envs kv backend target root verdict draft claude composer tries
  local writer_lock="$STATE/desk-voice/.send.lock"
  [ -f "$lock" ] && [ ! -L "$lock" ] || return 1
  pid=$(head -n 1 "$lock" 2>/dev/null) || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  fm_harness_holder_alive "$pid" || return 1
  # Kept now: sourcing a backend resets the session-lock library's flag.
  claude=${FM_HARNESS_IS_CLAUDE:-0}
  envs=$(holder_pane_env "$pid")
  [ -n "$envs" ] || return 1
  unset FM_SUPERVISOR_TARGET FM_SUPERVISOR_BACKEND TMUX TMUX_PANE \
    HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH
  while IFS= read -r kv; do
    [ -n "$kv" ] && export "${kv?}"
  done <<EOF
$envs
EOF
  target=$(discover_supervisor_target) || return 1
  backend=$(discover_supervisor_backend) || return 1
  fm_backend_target_exists "$backend" "$target" || return 1
  root=$(pane_root_pid "$backend" "$target") || return 1
  pid_within "$pid" "$root" || return 1
  if [ "$#" -ge 3 ]; then
    shown_in_front "$backend" "$target" "$root" "$2" "$3" || return 1
  fi
  mkdir -p "$STATE/desk-voice" || return 2
  fm_lock_try_acquire "$writer_lock" || return 2
  trap 'fm_lock_release "$writer_lock"' EXIT
  composer=$(fm_backend_composer_state "$backend" "$target" 2>/dev/null)
  case " ${PRIMARY_SUBMIT_COMPOSER:-empty pending} " in
    *" $composer "*) ;;
    *) return 2 ;;
  esac
  case "$composer" in
    empty) draft=0 ;;
    pending) draft=1 ;;
    *) return 2 ;;
  esac
  ! shows_selection_dialog "$backend" "$target" || return 2
  if [ "${PRIMARY_SUBMIT_RING:-0}" = 1 ]; then
    ! shows_stash "$backend" "$target" || return 2
    verdict=$(submit_ring "$backend" "$target" "$1") || verdict=send-failed
  elif [ "$draft" = 1 ] && [ "$claude" = 1 ]; then
    verdict=$(send_past_draft "$backend" "$target" "$1") || verdict=send-failed
  else
    tries=3
    [ "$claude" != 1 ] || ! shows_stash "$backend" "$target" || tries=1
    verdict=$(fm_backend_send_text_submit "$backend" "$target" "$1" "$tries" 0.4 0.5) || verdict=send-failed
  fi
  printf '%s\t%s\t%s\n' "${verdict:-send-failed}" "$backend" "$target"
)

send() {
  local source text line result='' verdict backend target path image rc=0
  local composer='empty pending' front_app='' front_tty=''
  local -a image_args=() front=() rest=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --front-app)
        [ "$#" -ge 2 ] || refuse "--front-app needs a pid"
        front_app=$2
        shift 2
        ;;
      --front-tty)
        [ "$#" -ge 2 ] || refuse "--front-tty needs a terminal device"
        front_tty=$2
        shift 2
        ;;
      --source|--image)
        [ "$#" -ge 2 ] || break
        rest+=("$1" "$2")
        shift 2
        ;;
      *) break ;;
    esac
  done
  set -- ${rest[@]+"${rest[@]}"} "$@"
  if [ -n "$front_app$front_tty" ]; then
    case "$front_app" in
      ''|0*|*[!0-9]*) refuse "--front-app needs a pid: $front_app" ;;
    esac
    printf '%s' "$front_tty" | grep -Eqx '/dev/(tty[A-Za-z0-9]+|pts/[0-9]+)' \
      || refuse "--front-tty needs a terminal device: $front_tty"
    front=("$front_app" "$front_tty")
  fi
  parse_transcript_args "$@"
  source=$ARG_SOURCE
  text=$ARG_TEXT
  line=$(plain_line "$(message_text)") || die "cannot prepare transcript"
  [ -n "$line" ] || refuse "nothing to deliver"

  # Screenshots alone never go past a draft: the captain may be typing.
  [ -n "$text" ] || composer=empty
  result=$(PRIMARY_SUBMIT_COMPOSER=$composer primary_submit "$line" ${front[@]+"${front[@]}"}) || rc=$?
  if [ "${#front[@]}" -gt 0 ] && [ "$rc" = 1 ]; then
    printf 'not-in-front\n'
    return 0
  fi
  if [ "$rc" = 0 ] && [ -n "$result" ]; then
    IFS=$'\t' read -r verdict backend target <<<"$result"
    case "$verdict" in
      empty)
        printf 'sent: %s %s\n' "$backend" "$target"
        return 0
        ;;
      send-failed)
        note "the primary's chat pane refused the text; saving it to the mailbox instead"
        ;;
      *)
        # Typed and Enter sent: a mailbox copy could deliver it twice.
        note "typed into the primary's chat pane but the submit was not confirmed ($verdict)"
        printf 'sent-unconfirmed: %s %s (%s)\n' "$backend" "$target" "$verdict"
        return 0
        ;;
    esac
  else
    note "the primary's chat pane is not reachable; saving to the mailbox instead"
  fi
  for image in ${ARG_IMAGES[@]+"${ARG_IMAGES[@]}"}; do
    image_args+=(--image "$image")
  done
  path=$(deliver --source "$source" ${image_args[@]+"${image_args[@]}"} -- "$text") \
    || die "cannot save to the mailbox"
  printf 'mailbox: %s\n' "$path"
}

ring() {
  local line
  [ "$#" -eq 1 ] || refuse "usage: fm-desk-voice.sh ring <line>"
  line=$(plain_line "$1") || die "cannot prepare the line"
  [ -n "$line" ] || refuse "nothing to ring"
  ring_line "$line" || true
}

# Rings plain <line> once and prints ring's one outcome line. Returns 1 when
# no proven primary holds the session lock.
ring_line() {  # <line>
  local result='' verdict backend target rc=0
  result=$(PRIMARY_SUBMIT_COMPOSER=empty PRIMARY_SUBMIT_RING=1 primary_submit "$1") || rc=$?
  if [ "$rc" = 0 ] && [ -n "$result" ]; then
    IFS=$'\t' read -r verdict backend target <<<"$result"
    case "$verdict" in
      empty) printf 'rung: %s %s\n' "$backend" "$target"; return 0 ;;
      send-failed) ;;
      *) printf 'rung-unconfirmed: %s %s (%s)\n' "$backend" "$target" "$verdict"; return 0 ;;
    esac
  fi
  printf 'not-rung\n'
  [ "$rc" != 1 ]
}

shot() {
  local display='' keep=${FM_DESK_SHOTS_KEEP:-30} capture=${FM_DESK_SHOT_CAPTURE:-screencapture}
  local name path tmp excess
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --display)
        [ "$#" -ge 2 ] || refuse "--display needs a number"
        display=$2
        shift 2
        ;;
      *) refuse "unexpected argument: $1" ;;
    esac
  done
  case "$display" in
    ''|[1-9]|[1-9][0-9]) ;;
    *) refuse "--display needs a display number from 1: $display" ;;
  esac
  case "$keep" in
    [1-9]|[1-9][0-9]|[1-9][0-9][0-9]) ;;
    *) refuse "FM_DESK_SHOTS_KEEP must be a number from 1 to 999: $keep" ;;
  esac

  ensure_dirs
  mkdir -p "$SHOTS" || die "cannot create $SHOTS"
  chmod 700 "$SHOTS" 2>/dev/null || true
  # Microseconds in the name keep name order equal to capture order for pruning.
  name=$(python3 -c 'import datetime, secrets; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ") + "-" + secrets.token_hex(4))')
  path="$SHOTS/${name}.png"
  # macOS screencapture writes nothing to a dot-prefixed file name yet exits 0,
  # so the capture gets a plain name inside a private folder the prune skips.
  mkdir -p "$SHOTS/.tmp" || die "cannot create $SHOTS/.tmp"
  chmod 700 "$SHOTS/.tmp" 2>/dev/null || true
  tmp="$SHOTS/.tmp/${name}.png"
  if ! "$capture" -x -t png ${display:+-D "$display"} "$tmp" >/dev/null || [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    die "screen capture failed"
  fi
  mv "$tmp" "$path" || die "cannot finalize screenshot"
  chmod 600 "$path" 2>/dev/null || true

  # Keep only the newest images; names sort by capture time.
  shopt -s nullglob
  local -a all=("$SHOTS"/*.png)
  excess=$(( ${#all[@]} - keep ))
  if [ "$excess" -gt 0 ]; then
    rm -f "${all[@]:0:$excess}"
  fi

  printf '%s\n' "$path"
}

ensure_unsent() {
  ensure_dirs
  mkdir -p "$UNSENT" || die "cannot create $UNSENT"
  chmod 700 "$UNSENT" 2>/dev/null || true
}

# The saved recordings, oldest first (names start with the UTC time saved).
unsent_audio() {
  local f
  shopt -s nullglob
  for f in "$UNSENT"/*; do
    case "$f" in
      *.json|*/.*) continue ;;
    esac
    [ -f "$f" ] && printf '%s\n' "$f"
  done
}

# Reads or writes the JSON record beside a saved recording.
#   recording_meta read <json>  -> purpose TAB attempts TAB saved-at TAB reason
#   recording_meta write <json> <purpose> <attempts> <reason> [<saved-at>]
recording_meta() {
  python3 - "$@" <<'PY'
import json, os, sys, tempfile
mode, path = sys.argv[1], sys.argv[2]
def flat(value):
    return " ".join(str(value).split())
if mode == "read":
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError):
        doc = {}
    attempts = doc.get("attempts", 0)
    if not isinstance(attempts, int) or attempts < 0:
        attempts = 0
    purpose = doc.get("purpose") if doc.get("purpose") in ("firstmate", "dictate") else "firstmate"
    print("\t".join([purpose, str(attempts), flat(doc.get("saved_at", "")), flat(doc.get("last_reason", ""))]))
    raise SystemExit(0)
purpose, attempts, reason = sys.argv[3], int(sys.argv[4]), sys.argv[5]
saved_at = sys.argv[6] if len(sys.argv) > 6 else None
if saved_at is None:
    try:
        with open(path, encoding="utf-8") as fh:
            saved_at = json.load(fh).get("saved_at", "")
    except (OSError, ValueError):
        saved_at = ""
doc = {
    "schema": "fm-desk-voice-recording.v1",
    "purpose": purpose,
    "saved_at": saved_at,
    "attempts": attempts,
    "last_reason": reason,
}
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp.")
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, ensure_ascii=False)
    fh.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, path)
PY
}

keep() {
  local purpose=firstmate reason='' src ext stamp id dest
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --purpose)
        [ "$#" -ge 2 ] || refuse "--purpose needs firstmate or dictate"
        case "$2" in
          firstmate|dictate) purpose=$2 ;;
          *) refuse "--purpose needs firstmate or dictate: $2" ;;
        esac
        shift 2
        ;;
      --reason)
        [ "$#" -ge 2 ] || refuse "--reason needs a text"
        reason=$2
        shift 2
        ;;
      --) shift; break ;;
      -*) refuse "unexpected option: $1" ;;
      *) break ;;
    esac
  done
  [ "$#" -eq 1 ] || refuse "usage: fm-desk-voice.sh keep [--purpose firstmate|dictate] [--reason <text>] <audio-file>"
  src=$1
  [ -f "$src" ] && [ ! -L "$src" ] || refuse "no such recording: $src"
  ext=$(printf '%s' "${src##*.}" | tr '[:upper:]' '[:lower:]')
  case "$ext" in
    wav|mp3|m4a|webm|ogg) ;;
    *) refuse "not an audio recording: $src" ;;
  esac

  ensure_unsent
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  id=$(python3 -c 'import secrets; print(secrets.token_hex(4))')
  dest="$UNSENT/$stamp-$id.$ext"
  # The record goes first, so a retry never meets audio without one.
  recording_meta write "$UNSENT/$stamp-$id.json" "$purpose" 1 "$reason" "$stamp" \
    || die "cannot write the recording record"
  if ! mv -- "$src" "$dest"; then
    rm -f "$UNSENT/$stamp-$id.json"
    die "cannot move $src into $UNSENT"
  fi
  chmod 600 "$dest" 2>/dev/null || true
  printf '%s\n' "$dest"
}

recordings() {
  [ "$#" -eq 0 ] || refuse "usage: fm-desk-voice.sh recordings"
  local f
  [ -d "$UNSENT" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    printf '%s\t%s\n' "$f" "$(recording_meta read "${f%.*}.json")"
  done < <(unsent_audio)
}

# Transcribes one saved recording again and delivers its words; see the header.
retry_one() {  # <path>
  local path=$1 meta purpose attempts reason text outcome err rc=0
  if [ ! -f "$path" ]; then
    printf 'gone\t%s\n' "$path"
    return 0
  fi
  meta=$(recording_meta read "${path%.*}.json")
  IFS=$'\t' read -r purpose attempts _ reason <<<"$meta"
  err=$(mktemp "${TMPDIR:-/tmp}/fm-desk-voice-retry.XXXXXX") || die "cannot create a temporary file"
  text=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-deepgram-stt.sh" "$path" 2>"$err") || rc=$?
  if [ "$rc" != 0 ]; then
    reason=$(sed -n 's/^fm-deepgram-stt: //p' "$err" 2>/dev/null | tail -n 1)
    reason="transcription failed${reason:+: $reason}"
  fi
  rm -f "$err"
  case "$text" in
    *[![:space:]]*) ;;
    *) text='' ;;
  esac
  if [ "$rc" = 0 ] && [ -z "$text" ]; then
    reason="no speech heard"
  elif [ "$rc" = 0 ] && [ "$purpose" = dictate ]; then
    text=$(plain_line "$text") || die "cannot prepare the transcript"
    rm -f "$path" "${path%.*}.json"
    printf 'transcript\t%s\t%s\n' "$path" "$text"
    return 0
  elif [ "$rc" = 0 ]; then
    if outcome=$(send --source desk-floater-retry -- "$text") && [ -n "$outcome" ]; then
      rm -f "$path" "${path%.*}.json"
      printf 'delivered\t%s\t%s\n' "$path" "$outcome"
      return 0
    fi
    reason="delivery failed"
  fi
  attempts=$(( ${attempts:-0} + 1 ))
  recording_meta write "${path%.*}.json" "$purpose" "$attempts" "$reason" \
    || note "could not update the record for $path"
  printf 'unsent\t%s\t%s\t%s\n' "$path" "$attempts" "$(plain_line "$reason")"
}

retry() (
  local lock="$STATE/desk-voice/.retry.lock" path dir unsent_real
  local -a paths=()
  ensure_unsent
  unsent_real=$(cd -P "$UNSENT" && pwd) || die "cannot read $UNSENT"
  for path in "$@"; do
    case "$path" in
      /*) ;;
      *) path="$PWD/$path" ;;
    esac
    dir=$(cd -P "$(dirname "$path")" 2>/dev/null && pwd) || dir=''
    [ "$dir" = "$unsent_real" ] || refuse "not a saved recording in $UNSENT: $path"
    case "$path" in
      *.json|*/.*) refuse "not a saved recording: $path" ;;
    esac
    paths+=("$UNSENT/$(basename "$path")")
  done
  if [ "${#paths[@]}" -eq 0 ]; then
    while IFS= read -r path; do
      [ -n "$path" ] && paths+=("$path")
    done < <(unsent_audio)
  fi
  [ "${#paths[@]}" -gt 0 ] || return 0
  if ! fm_lock_try_acquire "$lock"; then
    for path in "${paths[@]}"; do
      printf 'busy\t%s\n' "$path"
    done
    return 0
  fi
  trap 'fm_lock_release "$lock"' EXIT
  for path in "${paths[@]}"; do
    retry_one "$path"
  done
)

pending() {
  ensure_dirs
  local f
  shopt -s nullglob
  for f in "$INBOX"/*.json; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"
  done
}

drain() {
  local print_json=false f base dest text
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --print) print_json=true; shift ;;
      -*) refuse "unexpected option: $1" ;;
      *) break ;;
    esac
  done
  ensure_dirs
  shopt -s nullglob
  for f in "$INBOX"/*.json; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    dest="$PROCESSED/$base"
    if [ "$print_json" = true ]; then
      cat "$f"
    else
      text=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8")).get("transcript",""))' "$f") \
        || die "cannot read $f"
      printf '%s\n' "$text"
    fi
    mv "$f" "$dest" || die "cannot move $f to processed"
  done
}

main() {
  [ "$#" -gt 0 ] || { usage; exit 2; }
  case "$1" in
    --help|-h) usage; exit 0 ;;
    send) shift; send "$@" ;;
    deliver) shift; deliver "$@" ;;
    ring) shift; ring "$@" ;;
    shot) shift; shot "$@" ;;
    keep) shift; keep "$@" ;;
    recordings) shift; recordings "$@" ;;
    retry) shift; retry "$@" ;;
    pending) shift; pending "$@" ;;
    drain) shift; drain "$@" ;;
    *) refuse "unknown command: $1" ;;
  esac
}

main "$@"
