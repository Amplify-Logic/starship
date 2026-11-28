#!/usr/bin/env bash
# Opt-in live guard for the web page reading an Antigravity (agy) first mate's
# conversation: bin/fm-agy-session-hook.sh (registered in tracked
# .agents/hooks.json) records the conversation, and bin/fm-web.py reads agy's
# transcript.
#
# Both depend on what agy emits: the PreInvocation payload's conversationId and
# transcriptPath, and the transcript's step shape (USER_INPUT with the words
# inside <USER_REQUEST>, PLANNER_RESPONSE with tool_calls, GENERIC with each
# call's output). tests/fm-agy-session-hook.test.sh and tests/fm-web.test.sh
# pin the logic against fixtures; this guard proves those agy facts against the
# installed agy binary. It stages the working tree as a throwaway home, asks agy
# to run one command and reply, and reads the page's conversation while that
# agy process still holds the home lock. It uses agy's own signed-in
# configuration as it is: it never changes HOME or agy's settings and never
# starts a sign-in.
# FM_AGY_LIVE_MODEL selects a model; without it agy uses its own default.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_AGY_WEB_TRANSCRIPT_LIVE,FM_AGY_WEB_TRANSCRIPT_LIVE_E2E agy jq python3

AGY_BIN=${FM_AGY_BIN:-$(command -v agy 2>/dev/null || true)}
[ -n "$AGY_BIN" ] && [ -x "$AGY_BIN" ] \
  || fail "agy not found; install it or set FM_AGY_BIN"
AGY_VERSION=$("$AGY_BIN" --version 2>/dev/null | head -n 1)

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-agy-web-live.XXXXXX") || fail "could not create isolated agy lab"
HOME_DIR="$LAB/home"
trap '[ -x "$HOME_DIR/bin/fm-watch-arm.sh" ] && FM_HOME="$HOME_DIR" "$HOME_DIR/bin/fm-watch-arm.sh" --stop >/dev/null 2>&1; rm -rf -- "$LAB"' EXIT

# A model name that carries its own level, such as gemini-4-neon-medium,
# refuses an --effort flag, so the low effort is asked for only without one.
AGY_MODEL_ARGS=(--effort low)
[ -z "${FM_AGY_LIVE_MODEL:-}" ] || AGY_MODEL_ARGS=(--model "$FM_AGY_LIVE_MODEL")

mkdir -p "$HOME_DIR"
(cd "$ROOT" && tar --exclude=.git --exclude=state --exclude=projects --exclude=node_modules -cf - .) \
  | (cd "$HOME_DIR" && tar -xf -) \
  || fail "could not stage the working tree into the throwaway home"
git init -q -b main "$HOME_DIR"
git -C "$HOME_DIR" add -A >/dev/null 2>&1 || true
git -C "$HOME_DIR" -c user.email=fmtest@example.invalid -c user.name=fmtest \
  commit -q -m "live-e2e fixture" >/dev/null 2>&1 || true
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config"

# One agy process, kept open after its turn as an interactive first mate is,
# holds the home lock from the start, so the hook sees the lock-holding first
# mate and the page sees a live holder.
mkfifo "$LAB/in" || fail "could not create the input pipe"
(cd "$HOME_DIR" && exec env -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  "$AGY_BIN" --print= --input-format stream-json --output-format stream-json \
  "${AGY_MODEL_ARGS[@]}" --dangerously-skip-permissions \
  < "$LAB/in" > "$LAB/out" 2> "$LAB/err") &
AGY_PID=$!
printf '%s\n' "$AGY_PID" > "$HOME_DIR/state/.lock"
exec 3> "$LAB/in"

# Waits for the first result and fails unless it succeeded.
wait_result() {
  local i=0 response
  while [ "$i" -lt 600 ]; do
    response=$(jq -c 'select(.event == "result") | .result' "$LAB/out" 2>/dev/null | sed -n 1p)
    if [ -n "$response" ]; then
      printf '%s' "$response" | jq -e '.status == "SUCCESS"' >/dev/null 2>&1 \
        || fail "agy $AGY_VERSION turn did not succeed: $response"
      return 0
    fi
    kill -0 "$AGY_PID" 2>/dev/null || break
    sleep 0.5
    i=$((i + 1))
  done
  fail "agy $AGY_VERSION gave no result: $(tail -c 2000 "$LAB/out" "$LAB/err" 2>/dev/null)"
}

jq -cn '{event:"user",message:{role:"user",content:"Run the shell command `echo WEB_PROBE_OUT` once, then reply with exactly WEB_PROBE_DONE"}}' >&3
wait_result

[ -s "$HOME_DIR/state/.agy-session" ] \
  || fail "agy $AGY_VERSION: no model call recorded its conversation, so PreInvocation carried no conversationId or transcriptPath"
RECORD=$(cat "$HOME_DIR/state/.agy-session")
TRANSCRIPT=$(jq -r .transcriptPath <<<"$RECORD")
[ -f "$TRANSCRIPT" ] || fail "agy $AGY_VERSION: the recorded transcript does not exist: $RECORD"
pass "agy web transcript live ($AGY_VERSION): a model call records the conversation and its transcript"

PAGE=$(env -u FM_HOME python3 "$HOME_DIR/bin/fm-web.py" conversation --home "$HOME_DIR") \
  || fail "agy $AGY_VERSION: the page's conversation read failed: $PAGE"
exec 3>&-
wait "$AGY_PID" 2>/dev/null || true
assert_equals "$(jq -r .conversationId <<<"$RECORD")" "$(jq -r .session <<<"$PAGE")" \
  "agy $AGY_VERSION: the page did not read the recorded conversation"
assert_equals idle "$(jq -r .state <<<"$PAGE")" "agy $AGY_VERSION: a finished turn should read idle: $PAGE"
assert_contains "$(jq -r '[.items[] | select(.kind == "user") | .html] | join(" ")' <<<"$PAGE")" "echo WEB_PROBE_OUT" \
  "agy $AGY_VERSION: the owner's words are not shown: $PAGE"
assert_not_contains "$(jq -r '[.items[] | select(.kind == "user") | .html] | join(" ")' <<<"$PAGE")" "ADDITIONAL_METADATA" \
  "agy $AGY_VERSION: agy's own metadata leaked into the owner's words"
assert_contains "$(jq -r '[.items[] | select(.kind == "tool" and .name == "Bash" and .pending == false) | .result] | join(" ")' <<<"$PAGE")" \
  "WEB_PROBE_OUT" "agy $AGY_VERSION: the command's output did not reach its call: $PAGE"
assert_contains "$(jq -r '[.items[] | select(.kind == "assistant") | .html] | join(" ")' <<<"$PAGE")" "WEB_PROBE_DONE" \
  "agy $AGY_VERSION: the reply is not shown: $PAGE"
pass "agy web transcript live ($AGY_VERSION): the page shows the words, the command with its output, and the reply"
