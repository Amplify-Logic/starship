#!/usr/bin/env bash
# Behavior tests for the Antigravity (agy) first mate conversation record:
# bin/fm-agy-session-hook.sh as registered in tracked .agents/hooks.json, and
# the web page (bin/fm-web.py conversation) reading the agy conversation that
# record names.
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

TMP_ROOT=$(fm_test_tmproot fm-agy-session-hook)
fm_git_identity fmtest fmtest@example.invalid
command -v jq >/dev/null 2>&1 || fail "test host must provide jq"
command -v python3 >/dev/null 2>&1 || fail "test host must provide python3"

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

CONV1=c0ffee00-1111-2222-3333-444444444444
CONV2=c0ffee00-5555-6666-7777-888888888888

make_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state" "$dir/data" "$dir/config" "$dir/.agents"
  git init -q -b main "$dir"
  : > "$dir/AGENTS.md"
  git -C "$dir" add AGENTS.md
  git -C "$dir" commit -q -m init
  cp -R "$ROOT/bin" "$dir/bin"
  cp "$ROOT/.agents/hooks.json" "$dir/.agents/hooks.json"
  printf '%s\n' "$dir"
}

transcript_of() {  # <dir> <conversation>
  printf '%s\n' "$1/gemini/brain/$2/.system_generated/logs/transcript_full.jsonl"
}

write_transcript() {  # <file> <words> <reply>
  mkdir -p "$(dirname "$1")"
  {
    jq -cn --arg w "$2" '{step_index:0,source:"USER_EXPLICIT",type:"USER_INPUT",status:"DONE",created_at:"2026-11-28T10:00:00Z",content:("<USER_REQUEST>\n" + $w + "\n</USER_REQUEST>")}'
    jq -cn --arg r "$3" '{step_index:1,source:"MODEL",type:"PLANNER_RESPONSE",status:"DONE",created_at:"2026-11-28T10:00:01Z",content:$r}'
  } > "$1"
}

before_model_payload() {  # <conversation> <transcript>
  jq -cn --arg c "$1" --arg t "$2" \
    '{hookEventName:"PreInvocation",conversationId:$c,transcriptPath:$t,invocationNum:0,initialNumSteps:1,lastUserInput:"hi"}'
}

# Runs every command .agents/hooks.json registers for <event>, in order, from
# <dir>, with the payload on stdin, and prints each command's stdout on its own
# line. With lock=1 the fake agy parent holds <home>'s session lock. <after>,
# when given, runs last inside the same fake agy, so it sees that lock holder
# alive.
run_event() {  # <dir> <home> <event> <payload> [lock] [after]
  local dir=$1 home=$2 event=$3 payload=$4 lock=${5:-1} after=${6:-}
  local commands
  commands=$(jq -r --arg e "$event" '
    .[] | (.[$e] // [])[] | if has("hooks") then .hooks[] else . end | .command
  ' "$dir/.agents/hooks.json")
  [ -n "$commands" ] || return 0
  printf '%s\n' "$commands" > "$home/state/.test-commands"
  printf '%s' "$payload" > "$home/state/.test-payload"
  ( cd "$dir" && env -u CLAUDECODE -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID \
      -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI -u GROK_AGENT \
      -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_TASK_ID \
      HOOK_LOCK="$lock" HOOK_HOME="$home" HOOK_AFTER="$after" "$FAKE_AGY" -c '
        [ "$HOOK_LOCK" != 1 ] || printf "%s\n" "$PPID" > "$HOOK_HOME/state/.lock"
        while IFS= read -r cmd; do
          sh -c "$cmd" < "$HOOK_HOME/state/.test-payload"
          printf "\n"
        done < "$HOOK_HOME/state/.test-commands"
        [ -z "$HOOK_AFTER" ] || eval "$HOOK_AFTER"
      ' )
}

assert_only_empty_objects() {  # <output>
  local line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    printf '%s' "$line" | jq -e 'type == "object"' >/dev/null 2>&1 \
      || fail "every PreInvocation hook must print one JSON object, got: $line"
  done <<EOF
$1
EOF
}

# The reproduction end to end: an agy first mate's model call records its
# conversation, and the web page then reads that conversation instead of
# saying no session is recorded.
test_a_model_call_records_the_conversation_the_page_reads() {
  local dir file out record page
  dir=$(make_home "$TMP_ROOT/record")
  file=$(transcript_of "$dir" "$CONV1")
  write_transcript "$file" "how is the fleet?" "Two workers are live."
  out=$(run_event "$dir" "$dir" PreInvocation "$(before_model_payload "$CONV1" "$file")" 1 \
    'python3 "$HOOK_HOME/bin/fm-web.py" conversation --home "$HOOK_HOME" > "$HOOK_HOME/state/.test-page"')
  assert_only_empty_objects "$out"
  [ -f "$dir/state/.agy-session" ] || fail "a model call by the lock holder must record its conversation"
  record=$(cat "$dir/state/.agy-session")
  assert_equals "$CONV1|$file" "$(jq -r '[.conversationId, .transcriptPath] | join("|")' <<<"$record")" \
    "the record names the conversation and its transcript"
  assert_equals "$(cat "$dir/state/.lock")" "$(jq -r .pid <<<"$record")" "the record names the lock holder"
  page=$(cat "$dir/state/.test-page")
  assert_equals "$CONV1|idle" "$(jq -r '[.session, .state] | join("|")' <<<"$page")" "the page reads the recorded conversation"
  assert_equals "<p>how is the fleet?</p>|<p>Two workers are live.</p>" \
    "$(jq -r '[.items[].html] | join("|")' <<<"$page")" "the page shows the owner's words and the reply"
  pass "an agy model call records its conversation and the page reads it"
}

# /clear starts a new conversation; its first model call replaces the record.
test_a_new_conversation_replaces_the_record() {
  local dir file1 file2
  dir=$(make_home "$TMP_ROOT/clear")
  file1=$(transcript_of "$dir" "$CONV1")
  file2=$(transcript_of "$dir" "$CONV2")
  write_transcript "$file1" "first" "one"
  write_transcript "$file2" "second" "two"
  run_event "$dir" "$dir" PreInvocation "$(before_model_payload "$CONV1" "$file1")" >/dev/null
  run_event "$dir" "$dir" PreInvocation "$(before_model_payload "$CONV2" "$file2")" >/dev/null
  assert_equals "$CONV2|$file2" "$(jq -r '[.conversationId, .transcriptPath] | join("|")' "$dir/state/.agy-session")" \
    "the new conversation replaces the old one"
  pass "a new conversation replaces the record"
}

# Only the home's own lock holder writes the record: a session without the
# lock and a crew worktree never do.
test_only_the_lock_holder_in_a_home_records() {
  local dir file wt out
  dir=$(make_home "$TMP_ROOT/scope")
  file=$(transcript_of "$dir" "$CONV1")
  write_transcript "$file" "hi" "hello"
  printf '%s\n' "$$" > "$dir/state/.lock"
  out=$(run_event "$dir" "$dir" PreInvocation "$(before_model_payload "$CONV1" "$file")" 0)
  assert_only_empty_objects "$out"
  [ ! -e "$dir/state/.agy-session" ] || fail "a session that does not hold the lock must not record"
  wt="$TMP_ROOT/scope-wt"
  git -C "$dir" worktree add -q --detach "$wt" >/dev/null 2>&1 || fail "could not make a test worktree"
  mkdir -p "$wt/state" "$wt/.agents"
  cp -R "$ROOT/bin" "$wt/bin"
  cp "$ROOT/.agents/hooks.json" "$wt/.agents/hooks.json"
  out=$(run_event "$wt" "$wt" PreInvocation "$(before_model_payload "$CONV1" "$file")" 1)
  assert_only_empty_objects "$out"
  [ ! -e "$wt/state/.agy-session" ] || fail "a crew worktree must not record"
  pass "only the lock-holding session of a home records its conversation"
}

# Broken or unsafe payloads write nothing and still answer with JSON.
test_broken_or_unsafe_payloads_record_nothing() {
  local dir file out payload
  dir=$(make_home "$TMP_ROOT/broken")
  file=$(transcript_of "$dir" "$CONV1")
  write_transcript "$file" "hi" "hello"
  for payload in 'not json' '{}' \
    "$(before_model_payload "../../etc" "$file")" \
    "$(before_model_payload "$CONV1" "relative/transcript.jsonl")" \
    "$(before_model_payload "$CONV1" "/tmp/transcript.txt")"; do
    out=$(run_event "$dir" "$dir" PreInvocation "$payload")
    assert_only_empty_objects "$out"
    [ ! -e "$dir/state/.agy-session" ] || fail "payload must record nothing: $payload"
  done
  pass "broken or unsafe payloads record nothing"
}

test_a_model_call_records_the_conversation_the_page_reads
test_a_new_conversation_replaces_the_record
test_only_the_lock_holder_in_a_home_records
test_broken_or_unsafe_payloads_record_nothing
