#!/usr/bin/env bash
# Desk-voice delivery: captain-input transcripts and screenshots from the Mac
# floater.
#
# Usage:
#   fm-desk-voice.sh send [--source <name>] [--image <png>]... [<transcript text...>]
#   fm-desk-voice.sh deliver [--source <name>] [--image <png>]... [<transcript text...>]
#   fm-desk-voice.sh shot [--display <n>]
#   fm-desk-voice.sh pending
#   fm-desk-voice.sh drain [--print]
#   fm-desk-voice.sh --help
#
# WHY: the floater is mouth/ears only. Transcripts meant for Firstmate must not
# be pasted into random terminals, and the floater must not act as a second
# Firstmate. The only terminal this script ever types into is the primary
# session that holds this home's session lock. (The floater's separate
# dictation mode types only into the text box the captain chose and never
# reaches this script; see docs/desk-floater.md.)
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
# typed words become keypresses. A screen showing a selection dialog (a
# pointer on a numbered option, or an Enter to select / Esc to cancel footer)
# is refused too, whatever the composer reads. Delivery goes through
# the backend's submit primitive (bin/fm-backend.sh fm_backend_send_text_submit),
# so any backend that can report a pane's root pid below can be added. The
# text is sent as the captain's plain words: control characters, newlines, and
# Unicode line separators become spaces, so nothing can submit early or reach
# the pane as a key.
# Outcomes, one line on stdout, exit 0:
#   sent: <backend> <target>              typed and submit confirmed
#   sent-unconfirmed: <backend> <target> (<verdict>)
#                                         typed and Enter sent, submit not
#                                         proven; never re-sent to the mailbox
#   mailbox: <path>                       the pane could not be resolved, its
#                                         composer was not empty or pending,
#                                         it showed a selection dialog, or
#                                         the backend reported send-failed, its
#                                         known-undelivered verdict; the
#                                         message went to the mailbox below
# A message therefore reaches the primary exactly one way.
#
# deliver is the mailbox path. Transcripts land under
#   $FM_HOME/state/desk-voice/inbox/<utc>-<id>.json
# and a single wake is appended so the primary can see and drain them.
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

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$SCRIPT_DIR/fm-supervisor-target-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

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

  # Best-effort macOS notice so a human at the desk knows something landed.
  if command -v osascript >/dev/null 2>&1; then
    osascript -e 'display notification "Desk voice transcript ready" with title "Firstmate"' \
      >/dev/null 2>&1 || true
  fi

  printf '%s\n' "$path"
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
# composer classifier reads a pointer on a numbered option as a bare agent
# prompt holding text, so this is checked here. An unreadable screen counts.
shows_selection_dialog() {  # <backend> <target>
  local screen
  screen=$(fm_backend_capture "$1" "$2" "${FM_COMPOSER_CAPTURE_LINES:-20}" 2>/dev/null) || return 0
  printf '%s\n' "$screen" | grep -Eiq '(❯|›)[[:space:]]*[0-9]+\.|enter to select|esc to cancel'
}

# Type <line> into the lock-holding primary's own pane and submit it. Prints
# "<verdict><TAB><backend><TAB><target>" once the pane is proven to host the
# primary and show its chat input, or nothing and returns 1 when it is not
# (nothing was typed). Call it
# in a subshell: it replaces the pane environment with the primary's own.
primary_submit() {  # <line>
  local lock="$STATE/.lock" pid envs kv backend target root verdict
  [ -f "$lock" ] && [ ! -L "$lock" ] || return 1
  pid=$(head -n 1 "$lock" 2>/dev/null) || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  fm_harness_holder_alive "$pid" || return 1
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
  case "$(fm_backend_composer_state "$backend" "$target" 2>/dev/null)" in
    empty|pending) ;;
    *) return 1 ;;
  esac
  ! shows_selection_dialog "$backend" "$target" || return 1
  verdict=$(fm_backend_send_text_submit "$backend" "$target" "$1" 3 0.4 0.5) || verdict=send-failed
  printf '%s\t%s\t%s\n' "${verdict:-send-failed}" "$backend" "$target"
}

send() {
  local source text line result='' verdict backend target path image
  local -a image_args=()
  parse_transcript_args "$@"
  source=$ARG_SOURCE
  text=$ARG_TEXT
  line=$(plain_line "$(message_text)") || die "cannot prepare transcript"
  [ -n "$line" ] || refuse "nothing to deliver"

  if result=$(primary_submit "$line") && [ -n "$result" ]; then
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
  path=$(deliver --source "$source" ${image_args[@]+"${image_args[@]}"} -- "$text")
  printf 'mailbox: %s\n' "$path"
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
  tmp="$SHOTS/.tmp-${name}.png"
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
    shot) shift; shot "$@" ;;
    pending) shift; pending "$@" ;;
    drain) shift; drain "$@" ;;
    *) refuse "unknown command: $1" ;;
  esac
}

main "$@"
