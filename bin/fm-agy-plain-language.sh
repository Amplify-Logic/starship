#!/usr/bin/env bash
# Antigravity (agy) first mate plain-language check (.agents/hooks.json).
#
# The agy side of the check bin/fm-plain-language-lib.sh owns: after each agy
# reply to the captain, the final reply is scanned with that library's term
# list and skip rules, and the first mate gets the library's notice at its next
# model call, never shown to the captain and never blocking. agy's Stop payload
# carries no reply text and a Stop hook cannot add a note without continuing the
# turn, so the work is split across two registered hooks:
#
#   stop          Stop hook, listed BEFORE bin/fm-turnend-guard-agy.sh because
#                 agy runs Stop hooks one after another and the guard can park
#                 for hours. Only a Stop whose terminationReason is NO_TOOL_CALL
#                 (or absent) ends a reply; any other reason, such as compaction
#                 or an error, is ignored. The reply is the last PLANNER_RESPONSE
#                 step's content in the JSON-lines transcript the payload's
#                 transcriptPath names; an empty one (a turn that ended on tool
#                 calls only) is silent. A hit replaces state/.plain-language-note
#                 with the payload's conversationId and the notice; a clean reply
#                 removes any older note. Always prints {}.
#   before-model  PreInvocation hook. When the note exists it is removed and,
#                 when its conversationId matches the payload's (or either is
#                 empty), printed as {"injectSteps":[{"systemMessage":...}]},
#                 which agy adds to the model's context for that call without
#                 showing it in the chat. A note from another conversation, such
#                 as the one before /clear, is dropped. Otherwise prints {}.
#
# The park's {"decision":"continue"} still wins after this hook's {} (verified),
# so a wake delivered by the park reaches the model together with the note.
#
# Scope, so workers are never warned: both modes act only in the plain primary
# checkout (not a linked crew or scout worktree, and not a secondmate home,
# whose chat the captain does not read) and only when this session's harness
# ancestry holds the home session lock, the same tests
# bin/fm-claude-reply-speak.sh uses. before-model checks for the note first,
# so the hook agy runs before every model call costs one file test when there
# is nothing to deliver.
#
# Never blocks: every path exits 0 and prints exactly one JSON object.
#
# Usage: fm-agy-plain-language.sh stop|before-model   (payload on stdin)
# Environment overrides, for tests and unusual layouts:
#   FM_ROOT_OVERRIDE, FM_HOME, FM_STATE_OVERRIDE  as for the other hooks
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
NOTE_FILE="$STATE/.plain-language-note"
# The reply is the newest model step, so only the transcript's tail is read.
TAIL_LINES=200

MODE=${1:-}

quiet() {
  printf '{}\n'
  exit 0
}

case "$MODE" in
  stop|before-model) ;;
  *) quiet ;;
esac

PAYLOAD=$(cat 2>/dev/null || true)
[ "$MODE" = stop ] || [ -f "$NOTE_FILE" ] || quiet
[ -n "$PAYLOAD" ] || quiet
command -v jq >/dev/null 2>&1 || quiet

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-plain-language-lib.sh
. "$SCRIPT_DIR/fm-plain-language-lib.sh"

fm_root_is_secondmate_home "$FM_ROOT" && quiet
fm_primary_scope_matches "$FM_ROOT" "$STATE" || quiet
fm_session_lock_owned_by_self "$STATE" || quiet

payload_field() {  # <key>
  printf '%s' "$PAYLOAD" | jq -r --arg k "$1" '.[$k] // empty | strings' 2>/dev/null || true
}
CONVERSATION=$(payload_field conversationId)

if [ "$MODE" = before-model ]; then
  NOTE=$(cat "$NOTE_FILE" 2>/dev/null || true)
  rm -f "$NOTE_FILE" 2>/dev/null || true
  NOTE_CONVERSATION=${NOTE%%$'\n'*}
  NOTICE=
  case "$NOTE" in *$'\n'*) NOTICE=${NOTE#*$'\n'} ;; esac
  [ -n "$NOTICE" ] || quiet
  if [ -n "$NOTE_CONVERSATION" ] && [ -n "$CONVERSATION" ] && [ "$NOTE_CONVERSATION" != "$CONVERSATION" ]; then
    quiet
  fi
  jq -cn --arg m "$NOTICE" '{injectSteps: [{systemMessage: {systemMessage: $m}}]}' 2>/dev/null || printf '{}\n'
  exit 0
fi

# --- stop: scan the reply this turn ended on ---------------------------------
TERM_REASON=$(payload_field terminationReason)
[ -z "$TERM_REASON" ] || [ "$TERM_REASON" = NO_TOOL_CALL ] || quiet
TRANSCRIPT=$(payload_field transcriptPath)
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || quiet

REPLY=$(tail -n "$TAIL_LINES" "$TRANSCRIPT" 2>/dev/null \
  | jq -R 'fromjson? | select(type == "object" and .type == "PLANNER_RESPONSE") | (.content // "" | strings)' 2>/dev/null \
  | tail -n 1 | jq -r '. // empty' 2>/dev/null || true)

HITS=
[ -z "$REPLY" ] || HITS=$(fm_plain_language_hits "$REPLY")
if [ -z "$HITS" ]; then
  rm -f "$NOTE_FILE" 2>/dev/null || true
  quiet
fi

TMP=$(mktemp "$NOTE_FILE.XXXXXX" 2>/dev/null) || quiet
if printf '%s\n%s\n' "$CONVERSATION" "$(fm_plain_language_notice "$HITS")" > "$TMP" 2>/dev/null \
  && mv -f "$TMP" "$NOTE_FILE" 2>/dev/null; then
  :
else
  rm -f "$TMP" 2>/dev/null || true
fi
quiet
