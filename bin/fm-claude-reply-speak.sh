#!/usr/bin/env bash
# Claude Stop hook that speaks the primary's final reply through desk voice-out.
#
# Registered in tracked .claude/settings.json as a Stop command hook with
# "async": true, so the turn ends at once and this runs in the background.
# It is the structural backstop behind AGENTS.md section 9's voice-out duty: the
# model is still asked to speak its own shortened line, and this hook speaks the
# final reply whenever the model did not.
#
# What it speaks: the Stop payload's `last_assistant_message`, which is the exact
# final reply, reduced to a spoken line before bin/fm-speak.sh shapes it:
#   - a leading routine "Captain, shipshape." is dropped first, so that line is
#     never spoken and the news after it is;
#   - only the first plain paragraph, with headings, tables, fenced code, and
#     rules dropped, and list markers, emphasis, backticks, and link targets
#     stripped, because the register would otherwise read pipes and code aloud;
#   - at most 60 words, cut back to the last full sentence inside that cap when
#     one exists.
# When the register refuses the line (bin/fm-speak.sh exit 2, which is how it
# refuses a line that asks the captain to decide), the hook speaks the fixed
# notice "Captain, a decision is waiting for you on screen." instead, so the
# captain still hears that the screen needs him without the choice being put to
# him by voice.
#
# What stays silent:
#   - an empty or missing `last_assistant_message`, such as a turn that ended on
#     tool calls only;
#   - the routine no-news reply: exactly "Captain, shipshape." after trimming,
#     so a bare routine update costs no speech;
#   - a turn in which bin/fm-speak.sh already handed a line over: the hook
#     records a signature of state/speak-last (mtime plus checksum) after each
#     Stop it accounts for, including after its own speech, and a different
#     signature at the next Stop means someone spoke during this turn. Its own
#     speech therefore never silences the next turn;
#   - a Stop superseded by a newer Stop: each Stop writes a fresh token to
#     state/.reply-speak-stop, waits FM_REPLY_SPEAK_SETTLE_MS (default 2000),
#     and speaks only while its token is still the latest. That drops the
#     mid-turn line when another Stop hook blocked the stop and a newer Stop
#     arrived within the settle window. A continuation that runs longer than the
#     window can still speak both lines; the final reply is then spoken as well,
#     because the hook's own speech is not counted as the model's.
#   - a muted or not-opted-in home: bin/fm-speak.sh owns both and exits 0
#     without a sound.
#
# Scope, so workers never speak: every worktree of this repo loads the same
# tracked settings, so the hook runs only in the plain primary checkout (not a
# linked crew or scout worktree, and not a secondmate home, whose chat the
# captain does not read) AND only when this session's harness ancestry holds the
# home session lock - the same scope and identity tests
# bin/fm-claude-stop-autoarm.sh uses, without its stale-lock recovery. A
# Cursor-delivered payload stands down through bin/fm-hook-host-lib.sh, and the
# settings entry's GROK_* guard keeps it inert under Grok.
#
# Never blocks and never prints: every path exits 0 with no stdout, and
# bin/fm-speak.sh's diagnostics are discarded.
#
# Environment overrides, for tests and unusual layouts:
#   FM_REPLY_SPEAK_CMD           speak command (default: bin/fm-speak.sh)
#   FM_REPLY_SPEAK_SETTLE_MS     wait before the superseded check (default 2000)
#   FM_ROOT_OVERRIDE, FM_HOME, FM_STATE_OVERRIDE  as for the other hooks
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SPEAK="${FM_REPLY_SPEAK_CMD:-$SCRIPT_DIR/fm-speak.sh}"
STOP_TOKEN_FILE="$STATE/.reply-speak-stop"
SEEN_FILE="$STATE/.reply-speak-seen"
SPEAK_LAST="$STATE/speak-last"
DECISION_NOTICE="Captain, a decision is waiting for you on screen."

ROUTINE_LINE="Captain, shipshape."
MAX_WORDS=60

SETTLE_MS=${FM_REPLY_SPEAK_SETTLE_MS:-2000}
case "$SETTLE_MS" in ''|*[!0-9]*) SETTLE_MS=2000 ;; esac

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0

# --- scope: the lock-holding primary session only ---------------------------
fm_root_is_secondmate_home "$FM_ROOT" && exit 0
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
fm_session_lock_owned_by_self "$STATE" || exit 0

# --- claim the latest Stop ---------------------------------------------------
# Written before anything can exit, so an empty newer Stop still supersedes an
# older Stop that is waiting out its settle window.
write_atomic() {  # <file> <text>
  local tmp
  tmp=$(mktemp "$1.XXXXXX" 2>/dev/null) || return 1
  if printf '%s\n' "$2" > "$tmp" 2>/dev/null && mv -f "$tmp" "$1" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}
MY_TOKEN="$$.$(date +%s).$RANDOM"
write_atomic "$STOP_TOKEN_FILE" "$MY_TOKEN" || exit 0

speak_last_signature() {
  [ -f "$SPEAK_LAST" ] || { printf 'none\n'; return 0; }
  printf '%s %s\n' "$(fm_path_mtime "$SPEAK_LAST")" "$(cksum < "$SPEAK_LAST" 2>/dev/null)"
}
record_seen() {
  write_atomic "$SEEN_FILE" "$(speak_last_signature)" || true
}

# --- did bin/fm-speak.sh already speak during this turn? ---------------------
# Only a baseline this hook recorded counts; without one (first Stop on a new
# home) the reply is spoken.
SPOKE_THIS_TURN=0
if [ -f "$SEEN_FILE" ]; then
  SEEN=$(cat "$SEEN_FILE" 2>/dev/null || true)
  [ "$SEEN" = "$(speak_last_signature)" ] || SPOKE_THIS_TURN=1
fi
record_seen
[ "$SPOKE_THIS_TURN" -eq 0 ] || exit 0

MSG=$(printf '%s' "$PAYLOAD" | jq -r '.last_assistant_message // empty | strings' 2>/dev/null || true)

# --- routine no-news line: never spoken -------------------------------------
MSG=${MSG#"${MSG%%[![:space:]]*}"}
case "$MSG" in
  "$ROUTINE_LINE"|"$ROUTINE_LINE"[[:space:]]*) MSG=${MSG#"$ROUTINE_LINE"} ;;
esac
case "$MSG" in
  *[![:space:]]*) ;;
  *) exit 0 ;;
esac

# --- spoken line: first plain paragraph, capped ------------------------------
LINE=$(printf '%s\n' "$MSG" | awk '
  /^[[:space:]]*(```|~~~)/ { fence = !fence; if (n) exit; next }
  fence { next }
  /^[[:space:]]*\|/ { if (n) exit; next }
  /^[[:space:]]*#/ { if (n) exit; next }
  /^[[:space:]]*([-*_][[:space:]]*){3,}$/ { if (n) exit; next }
  /^[[:space:]]*$/ { if (n) exit; next }
  {
    line = $0
    sub(/^[[:space:]]*>[[:space:]]*/, "", line)
    sub(/^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]+/, "", line)
    printf "%s ", line
    n++
  }
' | sed -E 's/\[([^]]*)\]\([^)]*\)/\1/g; s/(\*\*|__|`)//g' | awk -v max="$MAX_WORDS" '
  {
    for (i = 1; i <= NF; i++) w[++total] = $i
  }
  END {
    n = total
    if (total > max) {
      n = max
      for (i = max; i >= 10; i--) {
        if (w[i] ~ /[.!?]["\047)]*$/) { n = i; break }
      }
    }
    out = ""
    for (i = 1; i <= n; i++) out = (i == 1 ? w[i] : out " " w[i])
    print out
  }
')
case "$LINE" in
  *[![:space:]]*) ;;
  *) exit 0 ;;
esac

# --- speak only while this Stop is still the latest ---------------------------
still_latest() {
  [ "$(cat "$STOP_TOKEN_FILE" 2>/dev/null || true)" = "$MY_TOKEN" ]
}
if [ "$SETTLE_MS" -gt 0 ]; then
  sleep "$((SETTLE_MS / 1000)).$(printf '%03d' "$((SETTLE_MS % 1000))")"
fi
still_latest || exit 0

rc=0
"$SPEAK" "$LINE" >/dev/null 2>&1 </dev/null || rc=$?
if [ "$rc" -eq 2 ] && still_latest; then
  "$SPEAK" "$DECISION_NOTICE" >/dev/null 2>&1 </dev/null || true
fi
# Account for this hook's own line so the next Stop does not read it as the
# model having spoken during that turn. This is recorded even when a newer Stop
# arrived meanwhile: that Stop already took its baseline before this line was
# handed over, so leaving the line unaccounted would silence the turn after it.
record_seen
exit 0
