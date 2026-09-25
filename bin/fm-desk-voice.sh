#!/usr/bin/env bash
# Desk-voice mailbox: durable captain-input transcripts from the Mac floater.
#
# Usage:
#   fm-desk-voice.sh deliver [--source <name>] <transcript text...>
#   fm-desk-voice.sh pending
#   fm-desk-voice.sh drain [--print]
#   fm-desk-voice.sh --help
#
# WHY: the floater is mouth/ears only. Transcripts meant for Firstmate must not
# be pasted into random terminals, and the floater must not act as a second
# Firstmate. (Its separate dictation mode types only into the text box the
# captain chose and never reaches this mailbox; see docs/desk-floater.md.)
# Transcripts land under
#   $FM_HOME/state/desk-voice/inbox/<utc>-<id>.json
# and a single wake is appended so the primary can see and drain them.
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

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

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

write_transcript_json() {  # <path> <stamp> <id> <source> <text>
  python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import json, sys
path, stamp, rid, source, text = sys.argv[1:6]
doc = {
    "schema": "fm-desk-voice-transcript.v1",
    "id": rid,
    "created_at": stamp,
    "source": source,
    "transcript": text,
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, ensure_ascii=False)
    fh.write("\n")
PY
}

deliver() {
  local source=desk-floater text='' id stamp path tmp
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source)
        [ "$#" -ge 2 ] || refuse "--source needs a name"
        source=$2
        shift 2
        ;;
      --) shift; break ;;
      -*) refuse "unexpected option: $1" ;;
      *) break ;;
    esac
  done
  [ "$#" -gt 0 ] || refuse "nothing to deliver"
  text=$*
  case "$text" in
    *[![:space:]]*) ;;
    *) refuse "nothing to deliver" ;;
  esac

  ensure_dirs
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  id=$(python3 -c 'import secrets; print(secrets.token_hex(4))')
  path="$INBOX/${stamp}-${id}.json"
  tmp=$(mktemp "$INBOX/.tmp.XXXXXX") || die "cannot create temp transcript"

  if ! write_transcript_json "$tmp" "$stamp" "$id" "$source" "$text"; then
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
    deliver) shift; deliver "$@" ;;
    pending) shift; pending "$@" ;;
    drain) shift; drain "$@" ;;
    *) refuse "unknown command: $1" ;;
  esac
}

main "$@"
