#!/usr/bin/env bash
# Behavior tests for the Claude Stop hook that speaks the primary's final reply
# (bin/fm-claude-reply-speak.sh).
#
# The hook runs hermetically as a child of a fake harness (a bash symlink named
# "claude") whose pid is written into the fixture home's state/.lock, the same
# shape tests/fm-claude-stop-autoarm.test.sh uses. Most cases swap the speaker
# for a stub through FM_REPLY_SPEAK_CMD that records each line and refuses a
# decision request with exit 2, as the register does. The integration cases run
# the real bin/fm-speak.sh against a fake register owner and a fake speaker, so
# no audio is ever played and Deepgram is never called.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME and $$ expand inside the fake harness child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset DEEPGRAM_API_KEY GLASSES_ANNOUNCE_CONFIG || true
export FM_DEEPGRAM_ENV_FILE=/dev/null

TMP_ROOT=$(fm_test_tmproot fm-claude-reply-speak)
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"
export FAKE_CLAUDE

install_hook_scripts() {
  local dir=$1 script
  mkdir -p "$dir/bin"
  for script in fm-claude-reply-speak.sh fm-primary-scope-lib.sh fm-session-lock-lib.sh \
    fm-hook-host-lib.sh fm-wake-lib.sh fm-cursor-lib.sh; do
    cp "$ROOT/bin/$script" "$dir/bin/$script"
  done
  chmod +x "$dir/bin/fm-claude-reply-speak.sh"
}

# A stand-in for bin/fm-speak.sh with its observable contract: a refused line
# exits 2 and is not kept, an accepted line is recorded and kept in
# state/speak-last.
install_speak_stub() {
  local dir=$1
  cat > "$dir/speak-stub" <<'EOF'
#!/usr/bin/env bash
text=$*
case "$text" in
  *"Shall I"*) printf 'refused: %s\n' "$text" >> "$FM_HOME/refused.log"; exit 2 ;;
esac
printf '%s\n' "$text" >> "$FM_HOME/spoken.log"
printf '%s\n' "$text" > "$FM_HOME/state/speak-last"
EOF
  chmod +x "$dir/speak-stub"
}

make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_hook_scripts "$dir"
  install_speak_stub "$dir"
  printf '%s\n' "$dir"
}

# Build the Stop payload the harness delivers, with the reply as
# last_assistant_message; "-" omits the field.
payload() {  # <reply|->
  if [ "$1" = - ]; then
    printf '%s\n' '{"session_id":"sess-speak","hook_event_name":"Stop","stop_hook_active":false}'
  else
    jq -cn --arg m "$1" '{session_id:"sess-speak",hook_event_name:"Stop",stop_hook_active:false,last_assistant_message:$m}'
  fi
}

# Run the hook as a child of the fake harness that holds the fixture's session
# lock. Extra environment comes from exported variables.
run_hook() {  # <dir> <reply|->
  local dir=$1
  payload "$2" | FM_HOME="$dir" FM_REPLY_SPEAK_CMD="${SPEAK_CMD:-$dir/speak-stub}" \
    FM_REPLY_SPEAK_SETTLE_MS="${SETTLE_MS:-0}" "$FAKE_CLAUDE" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      "$FM_HOME/bin/fm-claude-reply-speak.sh"
    '
}

# Run the hook as a process whose ancestry does not hold the lock.
run_hook_without_lock() {  # <dir> <reply>
  local dir=$1
  payload "$2" | FM_HOME="$dir" FM_REPLY_SPEAK_CMD="$dir/speak-stub" \
    FM_REPLY_SPEAK_SETTLE_MS=0 "$dir/bin/fm-claude-reply-speak.sh"
}

spoken() { cat "$1/spoken.log" 2>/dev/null || true; }

test_plain_reply_is_spoken() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/plain")
  out=$(run_hook "$dir" "Captain, the fix landed and the checks are green." 2>&1)
  assert_equals "" "$out" "the hook must print nothing"
  assert_equals "Captain, the fix landed and the checks are green." "$(spoken "$dir")" \
    "a plain reply must be spoken in full"
  pass "plain reply is spoken in full"
}

test_decision_reply_speaks_notice() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/decision")
  run_hook "$dir" "Captain, the PR is green. Shall I merge it?"
  assert_grep 'Shall I merge it' "$dir/refused.log" "the reply itself must reach the register first"
  assert_equals "Captain, a decision is waiting for you on screen." "$(spoken "$dir")" \
    "a refused decision reply must be replaced by the on-screen notice"
  pass "decision reply is replaced by the on-screen notice"
}

test_markdown_reply_speaks_first_paragraph() {
  local dir reply
  dir=$(make_primary_dir "$TMP_ROOT/markdown")
  reply=$(cat <<'EOF'
## Summary

| Item | State |
| --- | --- |
| fix | green |

Captain, the **fix** is in `main` and [the review](https://example.invalid/r) found nothing.
It is live now.

```sh
echo not spoken
```

Second paragraph is not spoken.
EOF
)
  run_hook "$dir" "$reply"
  assert_equals "Captain, the fix is in main and the review found nothing. It is live now." \
    "$(spoken "$dir")" "only the first plain paragraph, cleaned of markdown, must be spoken"
  pass "markdown reply speaks only the first plain paragraph"
}

test_list_paragraph_is_joined() {
  local dir reply
  dir=$(make_primary_dir "$TMP_ROOT/list")
  reply=$(printf '%s\n' "Captain, two results:" "- the fix merged" "1. the docs are current")
  run_hook "$dir" "$reply"
  assert_equals "Captain, two results: the fix merged the docs are current" "$(spoken "$dir")" \
    "list markers must be stripped from the spoken paragraph"
  pass "list markers are stripped"
}

test_empty_and_tool_only_turns_are_silent() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/empty")
  run_hook "$dir" ""
  run_hook "$dir" "   "
  run_hook "$dir" -
  assert_absent "$dir/spoken.log" "an empty or tool-only turn must stay silent"
  assert_absent "$dir/refused.log" "an empty turn must not reach the register"
  pass "empty and tool-only turns are silent"
}

test_code_only_reply_is_silent() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/code-only")
  run_hook "$dir" "$(printf '%s\n' '```' 'ls -la' '```')"
  assert_absent "$dir/spoken.log" "a reply with no plain paragraph must stay silent"
  pass "code-only reply is silent"
}

test_routine_shipshape_is_silent() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/shipshape")
  run_hook "$dir" "Captain, shipshape."
  run_hook "$dir" "$(printf '\n  Captain, shipshape.  \n\n')"
  assert_absent "$dir/spoken.log" "the routine shipshape reply must not be spoken"
  pass "routine shipshape reply is silent"
}

test_shipshape_near_misses_are_spoken() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/shipshape-near")
  run_hook "$dir" "captain, shipshape"
  assert_equals "captain, shipshape" "$(spoken "$dir")" \
    "only the exact routine line is routine"
  pass "shipshape near misses are spoken"
}

test_shipshape_opener_is_dropped_one_line() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/shipshape-one-line")
  run_hook "$dir" "Captain, shipshape. But the deploy failed and needs your approval."
  assert_equals "But the deploy failed and needs your approval." "$(spoken "$dir")" \
    "a shipshape opener must be dropped and the news after it spoken"
  pass "one-line shipshape opener is dropped, the news is spoken"
}

test_shipshape_opener_is_dropped_two_paragraphs() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/shipshape-two-para")
  run_hook "$dir" "$(printf '%s\n\n%s\n' "Captain, shipshape." \
    "The finances fix merged and the deploy is running; I'll report when it lands.")"
  assert_equals "The finances fix merged and the deploy is running; I'll report when it lands." \
    "$(spoken "$dir")" "a shipshape first paragraph must be dropped and the next paragraph spoken"
  pass "two-paragraph shipshape opener is dropped, the news is spoken"
}

test_long_reply_is_capped() {
  local dir reply words
  dir=$(make_primary_dir "$TMP_ROOT/long")
  reply="Captain, the first sentence has exactly ten words in it here. $(printf 'word %.0s' $(seq 1 70))end."
  run_hook "$dir" "$reply"
  assert_equals "Captain, the first sentence has exactly ten words in it here." "$(spoken "$dir")" \
    "an over-long line must be cut back to the last full sentence inside the cap"
  rm -f "$dir/spoken.log"
  run_hook "$dir" "$(printf 'word %.0s' $(seq 1 80))"
  words=$(spoken "$dir" | wc -w | tr -d ' ')
  assert_equals "60" "$words" "a line with no sentence end must be capped at 60 words"
  pass "long replies are capped at about 60 words"
}

test_model_already_spoke_is_silent_then_next_turn_speaks() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/already-spoke")
  run_hook "$dir" "Captain, turn one is done."
  assert_equals "Captain, turn one is done." "$(spoken "$dir")" "baseline turn must be spoken"
  # Turn two: the model spoke its own line through bin/fm-speak.sh.
  sleep 1
  printf 'Captain, turn two spoken by the model.\n' > "$dir/state/speak-last"
  rm -f "$dir/spoken.log"
  run_hook "$dir" "Captain, turn two is done."
  assert_absent "$dir/spoken.log" "a turn the model already spoke must not be spoken twice"
  # Turn three: the model forgot, and the hook's own earlier line must not count.
  run_hook "$dir" "Captain, turn three is done."
  assert_equals "Captain, turn three is done." "$(spoken "$dir")" "a turn the model forgot must be spoken"
  rm -f "$dir/spoken.log"
  run_hook "$dir" "Captain, turn four is done."
  assert_equals "Captain, turn four is done." "$(spoken "$dir")" \
    "the hook's own speech must not silence the following turn"
  pass "already-spoken turns are skipped and later turns still speak"
}

test_superseded_stop_is_dropped() {
  local dir pid
  dir=$(make_primary_dir "$TMP_ROOT/superseded")
  (SETTLE_MS=1500; run_hook "$dir" "Captain, this mid-turn line was superseded.") &
  pid=$!
  sleep 0.5
  run_hook "$dir" "Captain, this is the real final reply."
  wait "$pid"
  assert_equals "Captain, this is the real final reply." "$(spoken "$dir")" \
    "a Stop superseded by a newer Stop must not be spoken"
  pass "a superseded Stop is dropped"
}

test_worker_worktree_is_inert() {
  local base dir
  base="$TMP_ROOT/worker-base"
  dir="$TMP_ROOT/worker-wt"
  fm_git_worktree "$base" "$dir" fm/reply-speak-test
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_hook_scripts "$dir"
  install_speak_stub "$dir"
  run_hook "$dir" "Captain, a worker must never say this."
  assert_absent "$dir/spoken.log" "a linked task worktree must never speak"
  assert_absent "$dir/state/.reply-speak-stop" "a worker session must leave no hook state"
  pass "worker worktree session is a no-op"
}

test_secondmate_home_is_inert() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/secondmate")
  printf 'sm-speak-1\n' > "$dir/.fm-secondmate-home"
  run_hook "$dir" "Captain, a secondmate must not say this."
  assert_absent "$dir/spoken.log" "a secondmate home must never speak"
  pass "secondmate home is a no-op"
}

test_session_without_lock_is_inert() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/no-lock")
  run_hook_without_lock "$dir" "Captain, no lock, no voice."
  printf '999999\n' > "$dir/state/.lock"
  run_hook_without_lock "$dir" "Captain, a foreign lock, no voice."
  assert_absent "$dir/spoken.log" "a session that does not hold the lock must never speak"
  pass "session without the home lock is a no-op"
}

test_cursor_payload_is_inert() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/cursor")
  printf '%s\n' '{"cursor_version":"2026.08.11","last_assistant_message":"Captain, from cursor."}' \
    | FM_HOME="$dir" FM_REPLY_SPEAK_CMD="$dir/speak-stub" FM_REPLY_SPEAK_SETTLE_MS=0 \
      "$FAKE_CLAUDE" -c 'printf "%s\n" "$$" > "$FM_HOME/state/.lock"; "$FM_HOME/bin/fm-claude-reply-speak.sh"'
  assert_absent "$dir/spoken.log" "a Cursor-delivered payload must stand down"
  pass "Cursor-delivered payload is a no-op"
}

# --- integration with the real bin/fm-speak.sh -------------------------------

install_real_speak_fixture() {  # <dir>
  local dir=$1
  cat > "$dir/shaper" <<'EOF'
#!/usr/bin/env bash
shift
case "$*" in
  *"Shall I"*) printf 'refused: asks the captain to decide\n' >&2; exit 2 ;;
esac
printf '%s\n' "$*"
EOF
  cat > "$dir/speaker" <<EOF
#!/usr/bin/env bash
prev=
for a in "\$@"; do
  [ "\$prev" != -f ] || printf '%s\n' "\$(cat "\$a")" >> "$dir/audio.log"
  prev=\$a
done
EOF
  chmod +x "$dir/shaper" "$dir/speaker"
  mkdir -p "$dir/config"
}

run_hook_real_speak() {  # <dir> <reply>
  (
    export FM_SPEAK_SHAPER="$1/shaper" FM_SPEAK_SAY="$1/speaker"
    SPEAK_CMD="$ROOT/bin/fm-speak.sh"
    run_hook "$1" "$2"
  )
}

wait_for_audio() {  # <dir> <msg>
  local waited=0
  while [ "$waited" -lt 50 ]; do
    [ ! -s "$1/audio.log" ] || return 0
    sleep 0.2
    waited=$((waited + 1))
  done
  fail "$2"
}

test_real_speak_speaks_and_falls_back() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/real-speak")
  install_real_speak_fixture "$dir"
  printf 'enabled = true\n' > "$dir/config/speak"
  run_hook_real_speak "$dir" "Captain, the review is ready. Shall I merge it?"
  wait_for_audio "$dir" "the decision notice never reached the speaker"
  assert_equals "Captain, a decision is waiting for you on screen." "$(cat "$dir/audio.log")" \
    "the real register must accept the on-screen notice in place of the refused reply"
  assert_equals "Captain, a decision is waiting for you on screen." "$(cat "$dir/state/speak-last")" \
    "the notice must be the kept line"
  pass "real fm-speak: decision reply speaks the on-screen notice"
}

test_real_speak_muted_and_not_enabled_stay_silent() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/real-muted")
  install_real_speak_fixture "$dir"
  printf 'enabled = true\n' > "$dir/config/speak"
  : > "$dir/state/speak-muted"
  run_hook_real_speak "$dir" "Captain, muted homes stay quiet."
  rm -f "$dir/state/speak-muted" "$dir/config/speak"
  run_hook_real_speak "$dir" "Captain, homes that never opted in stay quiet."
  sleep 1
  assert_absent "$dir/audio.log" "a muted or not-enabled home must stay silent"
  assert_absent "$dir/state/speak-last" "nothing must be kept when nothing was spoken"
  pass "real fm-speak: muted and not-enabled homes stay silent"
}

# --- registration ------------------------------------------------------------

test_settings_register_async_primary_hook() {
  jq -e '
    [.hooks.Stop[].hooks[] | select(.command | contains("fm-claude-reply-speak.sh"))]
      | length == 1 and (.[0].async == true) and ((.[0].asyncRewake // false) == false)
  ' "$ROOT/.claude/settings.json" >/dev/null \
    || fail "the reply-speak hook must be registered once as an async Stop hook"
  pass "settings register the reply-speak hook as an async Stop hook"
}

test_plain_reply_is_spoken
test_decision_reply_speaks_notice
test_markdown_reply_speaks_first_paragraph
test_list_paragraph_is_joined
test_empty_and_tool_only_turns_are_silent
test_code_only_reply_is_silent
test_routine_shipshape_is_silent
test_shipshape_near_misses_are_spoken
test_shipshape_opener_is_dropped_one_line
test_shipshape_opener_is_dropped_two_paragraphs
test_long_reply_is_capped
test_model_already_spoke_is_silent_then_next_turn_speaks
test_superseded_stop_is_dropped
test_worker_worktree_is_inert
test_secondmate_home_is_inert
test_session_without_lock_is_inert
test_cursor_payload_is_inert
test_real_speak_speaks_and_falls_back
test_real_speak_muted_and_not_enabled_stay_silent
test_settings_register_async_primary_hook
