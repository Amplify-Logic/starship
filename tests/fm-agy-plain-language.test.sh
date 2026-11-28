#!/usr/bin/env bash
# Behavior tests for the plain-language check on an Antigravity (agy) first
# mate: bin/fm-agy-plain-language.sh as registered in tracked .agents/hooks.json.
#
# The fixture home holds a copy of bin/ and the tracked .agents/hooks.json, and
# each case drives the hooks the way agy does: every command the hooks file
# registers for an event runs in turn from the home with the event's payload on
# stdin, as a child of a fake `agy` process whose pid holds the home session
# lock. The transcript is a JSON-lines file in agy's own step shape, named by
# the payload's transcriptPath. No agy binary or model is involved.
# shellcheck disable=SC2016 # single quotes are deliberate: variables expand inside the fake harness child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-agy-plain-language)
fm_git_identity fmtest fmtest@example.invalid
command -v jq >/dev/null 2>&1 || fail "test host must provide jq"

# The session lock recognises agy by its bare process name, so the fake harness
# is a small compiled program named agy that runs `bash -c <cmd>` as its child.
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
CC_BIN=$(command -v cc 2>/dev/null || command -v gcc 2>/dev/null || true)
[ -n "$CC_BIN" ] || fail "a C compiler is required to build the fake agy process"
cat > "$TMP_ROOT/fake-agy.c" <<'C'
#include <errno.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv) {
  int status;
  pid_t child;
  if (argc != 3 || strcmp(argv[1], "-c") != 0) return 64;
  child = fork();
  if (child < 0) return 70;
  if (child == 0) {
    execl("/bin/bash", "bash", "-c", argv[2], (char *)0);
    _exit(127);
  }
  while (waitpid(child, &status, 0) < 0) {
    if (errno != EINTR) return 71;
  }
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
  return 72;
}
C
"$CC_BIN" -o "$FAKEBIN/agy" "$TMP_ROOT/fake-agy.c" \
  || fail "could not build the fake agy process"
FAKE_AGY="$FAKEBIN/agy"

make_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state" "$dir/data" "$dir/config" "$dir/.agents"
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  cp -R "$ROOT/bin" "$dir/bin"
  cp "$ROOT/.agents/hooks.json" "$dir/.agents/hooks.json"
  printf '%s\n' "$dir"
}

# Writes an agy transcript whose last model step is the reply.
write_transcript() {  # <file> <reply>
  {
    jq -cn '{step_index:0,source:"USER_EXPLICIT",type:"USER_INPUT",status:"DONE",content:"<USER_REQUEST>\nhow is it going?\n</USER_REQUEST>"}'
    jq -cn '{step_index:1,source:"MODEL",type:"PLANNER_RESPONSE",status:"DONE",content:"Let me look.",tool_calls:[{name:"run_command",args:{CommandLine:"git worktree list"}}]}'
    jq -cn '{step_index:2,source:"MODEL",type:"GENERIC",status:"DONE",content:"worktree output"}'
    jq -cn --arg c "$2" '{step_index:3,source:"MODEL",type:"PLANNER_RESPONSE",status:"DONE",content:$c}'
  } > "$1"
}

stop_payload() {  # <transcript> [termination-reason] [conversation-id]
  jq -cn --arg t "$1" --arg r "${2-NO_TOOL_CALL}" --arg c "${3-conv-1}" \
    '{hookEventName:"Stop",conversationId:$c,transcriptPath:$t,terminationReason:$r,executionNum:0,fullyIdle:true,continuationActive:false,error:""}'
}

before_model_payload() {  # [conversation-id] [invocation-number]
  jq -cn --arg c "${1-conv-1}" --argjson n "${2-1}" \
    '{hookEventName:"PreInvocation",conversationId:$c,invocationNum:$n,initialNumSteps:4,lastUserInput:"how is it going?"}'
}

# Runs every command .agents/hooks.json registers for <event>, in order, from
# the home, with the payload on stdin, and prints each command's stdout on its
# own line. With lock=1 the fake agy parent holds the home session lock.
run_event() {  # <dir> <event> <payload> [lock]
  local dir=$1 event=$2 payload=$3 lock=${4:-1}
  local commands
  commands=$(jq -r --arg e "$event" '
    .[] | (.[$e] // [])[] | if has("hooks") then .hooks[] else . end | .command
  ' "$dir/.agents/hooks.json")
  [ -n "$commands" ] || return 0
  printf '%s\n' "$commands" > "$dir/state/.test-commands"
  printf '%s' "$payload" > "$dir/state/.test-payload"
  ( cd "$dir" && env -u CLAUDECODE -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID \
      -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI -u GROK_AGENT \
      -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
      HOOK_LOCK="$lock" "$FAKE_AGY" -c '
        [ "$HOOK_LOCK" != 1 ] || printf "%s\n" "$PPID" > state/.lock
        while IFS= read -r cmd; do
          sh -c "$cmd" < state/.test-payload
          printf "\n"
        done < state/.test-commands
      ' )
}

# The injected text from a before-model hook output, or nothing.
injected() {  # <output>
  printf '%s\n' "$1" | jq -r 'select(type == "object") | .injectSteps[]?.systemMessage.systemMessage // empty' 2>/dev/null
}

# --- the warning reaches the next model call ---------------------------------

# The reproduction: an agy first mate reply full of internals must earn the
# same quiet warning a Claude first mate gets, at its next model call.
test_internal_terms_warn_at_the_next_model_call() {
  local dir out note reply
  dir=$(make_home "$TMP_ROOT/warn")
  reply="Captain, the worktree teardown failed closed, so the Watcher is idle."
  write_transcript "$dir/transcript.jsonl" "$reply"
  out=$(run_event "$dir" Stop "$(stop_payload "$dir/transcript.jsonl")")
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    printf '%s' "$line" | jq -e 'type == "object"' >/dev/null 2>&1 \
      || fail "every Stop hook must print one JSON object, got: $line"
    if printf '%s' "$line" | jq -e '.decision? // empty | length > 0' >/dev/null 2>&1; then
      fail "the plain-language check must never hold or continue the turn, got: $line"
    fi
  done <<EOF
$out
EOF
  out=$(run_event "$dir" PreInvocation "$(before_model_payload)")
  note=$(injected "$out")
  [ -n "$note" ] || fail "an agy reply with internal terms must inject a warning at the next model call, got: $out"
  assert_contains "$note" 'worktree, teardown, failed closed, watcher' \
    "the warning must name each internal term once, in reply order"
  assert_contains "$note" 'section 9' "the warning must point at the rule it enforces"
  out=$(run_event "$dir" PreInvocation "$(before_model_payload conv-1 2)")
  assert_equals "" "$(injected "$out")" "the warning must be given once, not at every model call"
  pass "internal terms in an agy reply warn the first mate at its next model call, once"
}

# Commands, paths, and links the captain needs to act on are not slips, and a
# plain reply never warns.
test_code_links_and_plain_replies_do_not_warn() {
  local dir out
  dir=$(make_home "$TMP_ROOT/code")
  write_transcript "$dir/transcript.jsonl" "$(printf '%s\n' 'Captain, run `no-mistakes doctor` to see why.' \
    '' '```' 'git worktree list' '```' '' 'Details: [the guide](https://example.invalid/worktree).')"
  run_event "$dir" Stop "$(stop_payload "$dir/transcript.jsonl")" >/dev/null
  out=$(run_event "$dir" PreInvocation "$(before_model_payload)")
  assert_equals "" "$(injected "$out")" "code, a fenced block, or a link target must never warn"
  write_transcript "$dir/transcript.jsonl" "Captain, the fix landed and the checks are green."
  run_event "$dir" Stop "$(stop_payload "$dir/transcript.jsonl")" >/dev/null
  out=$(run_event "$dir" PreInvocation "$(before_model_payload)")
  assert_equals "" "$(injected "$out")" "a plain reply must never warn"
  pass "code, links, and plain replies raise no warning on agy"
}

# A turn that ended for another reason, such as compaction or an error, has no
# new reply to the captain, so the last model step is not scanned again.
test_non_reply_stop_is_not_scanned() {
  local dir out
  dir=$(make_home "$TMP_ROOT/compact")
  write_transcript "$dir/transcript.jsonl" "Captain, the harness is up."
  run_event "$dir" Stop "$(stop_payload "$dir/transcript.jsonl" TERMINAL_CUSTOM_HOOK)" >/dev/null
  out=$(run_event "$dir" PreInvocation "$(before_model_payload)")
  assert_equals "" "$(injected "$out")" "a Stop that is not a reply must never warn"
  pass "a Stop that is not a reply is not scanned"
}

# A warning about one conversation is never handed to another, such as the new
# conversation agy starts after /clear.
test_warning_stays_with_its_conversation() {
  local dir out
  dir=$(make_home "$TMP_ROOT/conversation")
  write_transcript "$dir/transcript.jsonl" "Captain, the harness is up."
  run_event "$dir" Stop "$(stop_payload "$dir/transcript.jsonl" NO_TOOL_CALL conv-1)" >/dev/null
  out=$(run_event "$dir" PreInvocation "$(before_model_payload conv-2 0)")
  assert_equals "" "$(injected "$out")" "a warning must never cross into another conversation"
  out=$(run_event "$dir" PreInvocation "$(before_model_payload conv-1 1)")
  assert_equals "" "$(injected "$out")" "a warning dropped at a conversation change must not come back"
  pass "the warning stays with its conversation"
}

# Workers and sessions that do not hold the home lock are never warned: the
# captain does not read their replies.
test_sessions_without_the_lock_are_not_warned() {
  local dir out
  dir=$(make_home "$TMP_ROOT/no-lock")
  write_transcript "$dir/transcript.jsonl" "Captain, the worktree is ready."
  run_event "$dir" Stop "$(stop_payload "$dir/transcript.jsonl")" 0 >/dev/null
  out=$(run_event "$dir" PreInvocation "$(before_model_payload)")
  assert_equals "" "$(injected "$out")" "a session without the home lock must never be warned"
  pass "the agy check stays in the lock-holding first mate"
}

# The check reads agy's Stop payload and transcript, which may be missing or
# broken; it must still answer every hook with valid JSON and exit 0.
test_missing_or_broken_input_is_quiet() {
  local dir out
  dir=$(make_home "$TMP_ROOT/broken")
  printf 'not json\n{"type":"PLANNER_RESPONSE","content":"Captain, the harness\n' > "$dir/transcript.jsonl"
  out=$(run_event "$dir" Stop "$(stop_payload "$dir/transcript.jsonl")")
  out=$(run_event "$dir" Stop "$(stop_payload "$dir/absent.jsonl")")
  out=$(run_event "$dir" Stop 'not json')
  out=$(run_event "$dir" PreInvocation "$(before_model_payload)")
  assert_equals "" "$(injected "$out")" "broken input must never warn"
  pass "missing or broken input stays quiet"
}

test_internal_terms_warn_at_the_next_model_call
test_code_links_and_plain_replies_do_not_warn
test_non_reply_stop_is_not_scanned
test_warning_stays_with_its_conversation
test_sessions_without_the_lock_are_not_warned
test_missing_or_broken_input_is_quiet
