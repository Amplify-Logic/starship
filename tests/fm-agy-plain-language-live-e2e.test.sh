#!/usr/bin/env bash
# Opt-in live guard for the plain-language check on an Antigravity (agy) first
# mate (bin/fm-agy-plain-language.sh, registered in tracked .agents/hooks.json).
#
# The check depends on what agy emits: the Stop payload's transcriptPath, the
# transcript's PLANNER_RESPONSE step holding the final reply, and a
# PreInvocation hook's injectSteps reaching the model. tests/fm-agy-plain-language.test.sh
# pins the logic against fixtures; this guard proves those agy facts against
# the installed agy binary. It stages the working tree as a throwaway home,
# asks agy for a reply that uses internal terms, then resumes that same
# conversation and asks the model to repeat the terms the injected notice
# named. It uses agy's own signed-in configuration as it is: it never changes
# HOME or agy's settings and never starts a sign-in.
# FM_AGY_LIVE_MODEL selects a model; without it agy uses its own default.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_AGY_PLAIN_LANGUAGE_LIVE,FM_AGY_PLAIN_LANGUAGE_LIVE_E2E agy jq

AGY_BIN=${FM_AGY_BIN:-$(command -v agy 2>/dev/null || true)}
[ -n "$AGY_BIN" ] && [ -x "$AGY_BIN" ] \
  || fail "agy not found; install it or set FM_AGY_BIN"
AGY_VERSION=$("$AGY_BIN" --version 2>/dev/null | head -n 1)

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-agy-plain-live.XXXXXX") || fail "could not create isolated agy lab"
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

# One agy process takes both turns, as an interactive first mate does: agy's
# stream-json input runs one turn per line in a single conversation. The
# process is the home's lock holder from the start, so the hooks see the
# lock-holding first mate whatever the session-start digest does.
mkfifo "$LAB/in" || fail "could not create the input pipe"
(cd "$HOME_DIR" && exec env -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  "$AGY_BIN" --print= --input-format stream-json --output-format stream-json \
  "${AGY_MODEL_ARGS[@]}" --dangerously-skip-permissions \
  < "$LAB/in" > "$LAB/out" 2> "$LAB/err") &
AGY_PID=$!
printf '%s\n' "$AGY_PID" > "$HOME_DIR/state/.lock"
exec 3> "$LAB/in"

turn() {  # <prompt>
  jq -cn --arg c "$1" '{event:"user",message:{role:"user",content:$c}}' >&3
}
# Prints the response of result <n> once agy has written it.
result() {  # <n>
  local i=0 response
  while [ "$i" -lt 600 ]; do
    response=$(jq -c 'select(.event == "result") | .result' "$LAB/out" 2>/dev/null | sed -n "${1}p")
    if [ -n "$response" ]; then
      printf '%s' "$response" | jq -e '.status == "SUCCESS"' >/dev/null 2>&1 \
        || fail "agy $AGY_VERSION turn $1 did not succeed: $response"
      printf '%s' "$response" | jq -r '.response // ""'
      return 0
    fi
    kill -0 "$AGY_PID" 2>/dev/null || break
    sleep 0.5
    i=$((i + 1))
  done
  fail "agy $AGY_VERSION gave no result for turn $1: $(tail -c 2000 "$LAB/out" "$LAB/err" 2>/dev/null)"
}

turn "Reply with exactly this sentence and nothing else: The worktree teardown is finished."
REPLY=$(result 1)
assert_contains "$REPLY" "worktree" "agy $AGY_VERSION did not give the reply the guard asked for: $REPLY"
[ -s "$HOME_DIR/state/.plain-language-note" ] \
  || fail "agy $AGY_VERSION: the Stop hook recorded no notice for a reply using internal terms, so the transcript reply was not read"
pass "agy plain-language live ($AGY_VERSION): the Stop hook reads the final reply from agy's transcript"

# Only the notice names the AGENTS.md section, so a right answer proves it
# arrived; the answer itself uses no internal term, so no new notice follows.
turn "A system note about a plain-language check should have reached you just now. If it did, reply with only the number of the AGENTS.md section it cites, as digits. If no such note reached you, reply with only NONE."
REPLY=$(result 2)
exec 3>&-
wait "$AGY_PID" 2>/dev/null || true
assert_contains "$REPLY" "9" "agy $AGY_VERSION: the injected notice did not reach the next model call: $REPLY"
[ ! -e "$HOME_DIR/state/.plain-language-note" ] \
  || fail "agy $AGY_VERSION: the notice was not consumed when it was delivered"
pass "agy plain-language live ($AGY_VERSION): the next model call receives the notice once"
