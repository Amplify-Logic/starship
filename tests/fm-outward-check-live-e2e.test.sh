#!/usr/bin/env bash
# Live guard for the worker outward-action check (bin/fm-outward-check.py).
#
# tests/fm-outward-check.test.sh pins the classification, the permissions, the
# refusal text and the hooks bin/fm-spawn.sh writes, with payloads shaped like
# Claude Code's. Only a real worker can show that Claude Code still names the
# claude.ai connector tools mcp__claude_ai_<connector>__<action>, still runs a
# PreToolUse hook matched by "mcp__claude_ai_.*|mcp__claude-in-chrome__.*"
# with permissions bypassed and honours its refusal, and still hands a
# PostToolUse hook the connector's answer in a shape the organizer record can
# read. This guard checks all three against the
# Google Calendar connector of the account `claude` is logged in to:
#   1. delete_event on an event id that does not exist is refused by the hook
#      and recorded, and never reaches Google.
#   2. list_events over this year records at least one event organizer.
#   3. With the home's No Block switch on, the same delete reaches Google, which
#      answers that the event does not exist, so nothing changes either way.
# It reads the account's calendar and submits prompts, so it is opt-in:
#   FM_OUTWARD_CHECK_LIVE_E2E=1 bash tests/fm-outward-check-live-e2e.test.sh
# It fails, rather than passing over a half it could not check, when the
# connector is not offered to the worker. Refresh
# docs/verification/outward-check.md from its output.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_OUTWARD_CHECK_LIVE_E2E python3 claude jq git

CHECK="$ROOT/bin/fm-outward-check.py"
LAB=$(fm_test_tmproot fm-outward-check-live)
PROJ="$LAB/project"
HOME_DIR="$LAB/home"
mkdir -p "$PROJ/.claude" "$HOME_DIR/state" "$HOME_DIR/config"
git -C "$PROJ" init -q
args="--state '$HOME_DIR/state' --task live-1"
jq -n \
  --arg pre "python3 '$CHECK' hook --config '$HOME_DIR/config' $args || { echo 'refused: the check could not run' >&2; exit 2; }" \
  --arg post "python3 '$CHECK' seen $args >/dev/null 2>&1 || true" \
  '{hooks: {
     PreToolUse: [{matcher: "mcp__claude_ai_.*|mcp__claude-in-chrome__.*", hooks: [{type: "command", command: $pre, timeout: 15}]}],
     PostToolUse: [{matcher: "mcp__claude_ai_.*", hooks: [{type: "command", command: $post, timeout: 15}]}]}}' \
  > "$PROJ/.claude/settings.local.json"

worker() {  # <out-file> <prompt>
  (cd "$PROJ" && claude -p "$2" --dangerously-skip-permissions --model haiku \
    --output-format stream-json --verbose < /dev/null > "$1" 2>&1) || true
}

tool_results() {  # <out-file> <tool>: the results of every call to <tool>, one JSON string per line
  jq -c --arg tool "$2" '
    select(.type == "assistant") | .message.content[]? | select(.type == "tool_use" and .name == $tool) | .id
  ' "$1" | while IFS= read -r id; do
    jq -c --argjson id "$id" 'select(.type == "user") | .message.content[]? | select(.type == "tool_result" and .tool_use_id == $id) | .content | tostring' "$1"
  done
}

DELETE="mcp__claude_ai_Google_Calendar__delete_event"
PROMPT="First call mcp__claude_ai_Google_Calendar__list_events once with startTime \"2026-01-01T00:00:00\", endTime \"2026-12-31T00:00:00\" and pageSize 3. Then call $DELETE exactly once with eventId \"fm-outward-live-no-such-event\". If a call is refused, do not retry it or work around it. Then report what the delete tool returned."

worker "$LAB/refused.jsonl" "$PROMPT"
result=$(tool_results "$LAB/refused.jsonl" "$DELETE")
[ -n "$result" ] || fail "the worker never called $DELETE; is the Google Calendar connector offered to claude -p? $(tail -c 400 "$LAB/refused.jsonl")"
assert_contains "$result" "Starship refused $DELETE" "Claude Code did not deliver the hook's refusal"
assert_not_contains "$result" "could not be found" "a refused delete reached Google"
assert_grep '"decision": "refuse"' "$HOME_DIR/state/outward-check.log" "the refusal was not recorded"
pass "a real Claude worker with permissions bypassed has a connector delete refused by the hook before it reaches the connector"

count=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$HOME_DIR/state/live-1.outward-seen.json" 2>/dev/null || echo 0)
[ "$count" -ge 1 ] || fail "list_events recorded no event organizer; the PostToolUse answer shape may have changed"
pass "the PostToolUse hook reads event organizers from the real connector answer ($count recorded)"

printf 'no block\n' > "$HOME_DIR/config/outward-permissions"
worker "$LAB/allowed.jsonl" "Call $DELETE exactly once with eventId \"fm-outward-live-no-such-event\". Then report what it returned."
result=$(tool_results "$LAB/allowed.jsonl" "$DELETE")
assert_not_contains "$result" "Starship refused" "No Block did not let the delete through"
assert_contains "$result" "could not be found" "with No Block the delete should reach Google and find no such event"
assert_grep '"by": "no block"' "$HOME_DIR/state/outward-check.log" "the No Block action was not recorded"
printf 'claude %s\n' "$(claude --version 2>/dev/null)"
pass "with No Block on, the same delete reaches the connector, and the action is recorded"
