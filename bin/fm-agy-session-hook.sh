#!/usr/bin/env bash
# Antigravity (agy) first mate conversation record (.agents/hooks.json).
#
# The web page (bin/fm-web.py) reads a Claude first mate's conversation from
# Claude Code's own session registry; agy keeps no such registry, but every agy
# hook payload names the conversation and its JSON-lines transcript. This hook
# writes them to state/.agy-session so the page can read the agy first mate's
# conversation the same way:
#
#   {"pid":<state/.lock pid>,"conversationId":"<id>","transcriptPath":"<abs>"}
#
# One JSON object on one line, replaced atomically. pid is the session lock's
# holder when the record was written, so a reader trusts the record only while
# that same holder still owns the lock; bin/fm-web.py owns that check and the
# transcript reading. This hook is the record's only writer.
#
# Registered for PreInvocation only, listed first there; agy runs it before
# every model call, after bin/fm-sessionstart-agy.sh has taken the lock at
# SessionStart, so a /clear's new conversation is recorded at its first model
# call. A payload
# naming the conversation, transcript and lock holder already recorded returns
# at once, so the per-call cost is one small file read.
#
# Scope: only a genuine primary or secondmate home (never a crew or scout
# worktree) whose session lock this hook's own harness ancestry holds, the
# tests bin/fm-agy-plain-language.sh uses, so a worker never overwrites it.
#
# Never blocks: every path exits 0 and prints {}.
#
# Usage: fm-agy-session-hook.sh   (payload on stdin)
# Environment overrides, for tests and unusual layouts:
#   FM_ROOT_OVERRIDE, FM_HOME, FM_STATE_OVERRIDE  as for the other hooks
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RECORD="$STATE/.agy-session"

quiet() {
  printf '{}\n'
  exit 0
}

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || quiet
command -v jq >/dev/null 2>&1 || quiet
[ -d "$STATE" ] || quiet

FIELDS=$(printf '%s' "$PAYLOAD" | jq -r '
  [(.conversationId // "" | strings), (.transcriptPath // "" | strings)] | @tsv' 2>/dev/null) || quiet
CONVERSATION=${FIELDS%%$'\t'*}
TRANSCRIPT=${FIELDS#*$'\t'}
case "$CONVERSATION" in
  ''|*[!A-Za-z0-9-]*) quiet ;;
esac
case "$TRANSCRIPT" in
  /*.jsonl) ;;
  *) quiet ;;
esac
LOCK_PID=$(head -n 1 "$STATE/.lock" 2>/dev/null || true)
case "$LOCK_PID" in
  ''|*[!0-9]*) quiet ;;
esac

WANTED=$(jq -cn --argjson p "$LOCK_PID" --arg c "$CONVERSATION" --arg t "$TRANSCRIPT" \
  '{pid: $p, conversationId: $c, transcriptPath: $t}' 2>/dev/null) || quiet
[ "$(cat "$RECORD" 2>/dev/null || true)" != "$WANTED" ] || quiet

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$FM_ROOT" "$STATE" || quiet
fm_session_lock_owned_by_self "$STATE" || quiet

TMP=$(mktemp "$RECORD.XXXXXX" 2>/dev/null) || quiet
if printf '%s\n' "$WANTED" > "$TMP" 2>/dev/null && mv -f "$TMP" "$RECORD" 2>/dev/null; then
  :
else
  rm -f "$TMP" 2>/dev/null || true
fi
quiet
