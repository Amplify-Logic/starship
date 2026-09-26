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
# exits 2, reports the register's reason on stderr, and is not kept; an accepted
# line is recorded and kept as the next numbered entry in state/speak-history/.
# Like the installed register, it refuses an approval word even inside news.
install_speak_stub() {
  local dir=$1
  cat > "$dir/speak-stub" <<'EOF'
#!/usr/bin/env bash
text=$*
case "$text" in
  *"Shall I"*|*approved*)
    printf 'refused: %s\n' "$text" >> "$FM_HOME/refused.log"
    printf 'refused: asks the captain to decide; announcements carry news, not decisions\n' >&2
    exit 2 ;;
  *"Unspeakable"*)
    printf 'refused: %s\n' "$text" >> "$FM_HOME/refused.log"
    printf 'refused: nothing speakable left after removing URLs, paths, and ids\n' >&2
    exit 2 ;;
esac
printf '%s\n' "$text" >> "$FM_HOME/spoken.log"
n=$(ls "$FM_HOME/state/speak-history" 2>/dev/null | sort -n | tail -n 1)
n=$(( ${n:-0} + 1 ))
mkdir -p "$FM_HOME/state/speak-history/$n"
printf '%s\n' "$text" > "$FM_HOME/state/speak-history/$n/text"
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

test_decision_reply_falls_back_to_first_sentence() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/decision")
  run_hook "$dir" "Captain, the PR is green. Shall I merge it?"
  assert_grep 'Shall I merge it' "$dir/refused.log" "the reply itself must reach the register first"
  assert_equals "Captain, the PR is green. The choice is on screen." "$(spoken "$dir")" \
    "a refused decision reply must fall back to its first sentence and point at the choice"
  rm -f "$dir/spoken.log"
  run_hook "$dir" "$(printf '%s\n' "Captain, the PR is green. Shall I merge it?" "" \
    "The checks ran twice on both platforms and the reviewers left no comments on any of the changed files.")"
  assert_equals "Captain, the PR is green. The choice is on screen." "$(spoken "$dir")" \
    "a refused decision with more to read must still point at the choice, not at more"
  pass "decision reply falls back to its first sentence plus the choice pointer"
}

test_decision_only_reply_speaks_notice() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/decision-only")
  run_hook "$dir" "Shall I merge the green PR now?"
  assert_equals "Captain, a decision is waiting for you on screen." "$(spoken "$dir")" \
    "a reply that is nothing but a decision must be replaced by the decision notice"
  pass "decision-only reply speaks the decision notice"
}

test_non_decision_refusal_never_claims_a_decision() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/not-decision")
  run_hook "$dir" "Unspeakable lead only."
  assert_equals "Captain, my reply is on screen." "$(spoken "$dir")" \
    "a refusal that is not a decision must not say a decision is waiting"
  rm -f "$dir/spoken.log"
  run_hook "$dir" "Unspeakable first sentence. The fix merged."
  assert_equals "Captain, my reply is on screen." "$(spoken "$dir")" \
    "a refused first sentence must fall back to the plain on-screen notice"
  pass "a refusal that is not a decision speaks the plain on-screen notice"
}

test_decision_refusal_of_news_never_claims_a_decision() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/approved-news")
  run_hook "$dir" "Captain, Alex approved the draft and it went out."
  assert_grep 'Alex approved the draft' "$dir/refused.log" "the news must reach the register first"
  assert_equals "Captain, my reply is on screen." "$(spoken "$dir")" \
    "news the register mistakes for a decision must not be announced as one"
  rm -f "$dir/spoken.log"
  run_hook "$dir" "Captain, the review is closed. Alex approved the draft."
  assert_equals "Captain, the review is closed. More on screen." "$(spoken "$dir")" \
    "the fallback for mistaken news must point at more, not at a choice"
  pass "a decision refusal of plain news never claims a decision"
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
  assert_equals "Captain, the fix is in main and the review found nothing. It is live now. More on screen." \
    "$(spoken "$dir")" "only the first plain paragraph, cleaned of markdown, must be spoken, pointing at the rest"
  pass "markdown reply speaks only the first plain paragraph"
}

test_list_paragraph_is_joined() {
  local dir reply
  dir=$(make_primary_dir "$TMP_ROOT/list")
  reply=$(printf '%s\n' "Captain, two results:" "- the fix merged" "1. the docs are current")
  run_hook "$dir" "$reply"
  assert_equals "Captain, two results: the fix merged the docs are current." "$(spoken "$dir")" \
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
  assert_equals "captain, shipshape." "$(spoken "$dir")" \
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
  local dir reply out
  dir=$(make_primary_dir "$TMP_ROOT/long")
  reply="Captain, the first sentence has exactly ten words in it here. Then $(printf 'word %.0s' $(seq 1 70))end."
  run_hook "$dir" "$reply"
  assert_equals "Captain, the first sentence has exactly ten words in it here. More on screen." "$(spoken "$dir")" \
    "an over-long lead must be cut back to the last whole sentence inside the cap, pointing at the rest"
  rm -f "$dir/spoken.log"
  run_hook "$dir" "$(printf 'word %.0s' $(seq 1 80))"
  out=$(spoken "$dir")
  assert_equals "80" "$(printf '%s' "$out" | wc -w | tr -d ' ')" \
    "a first sentence longer than the cap is kept whole for the register to cut"
  assert_equals "word." "${out##* }" "a lead with no closing full stop must be given one"
  pass "long leads are cut back to whole sentences inside the cap"
}

test_lead_written_to_the_rule_is_kept_whole() {
  local dir lead
  dir=$(make_primary_dir "$TMP_ROOT/whole-lead")
  lead="Captain, the filming-rights check is done and nobody was contacted. The app already has footage from three places with no written OK, so you and Alex need to decide what to do; the options are on screen."
  run_hook "$dir" "$(printf '%s\n' "$lead" "" "**A.** Ask for permission" "**B.** Remove the footage")"
  assert_equals "$lead" "$(spoken "$dir")" \
    "a lead of about 35 words must be spoken whole, with no pointer when it already says on screen"
  pass "a lead written to the about-35-word rule is spoken whole"
}

test_lead_keeps_at_most_three_sentences() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/three")
  run_hook "$dir" "Captain, one is done. Two is done. Three is done. Four is done."
  assert_equals "Captain, one is done. Two is done. Three is done. More on screen." "$(spoken "$dir")" \
    "the lead must stop at three sentences and point at the rest"
  pass "the lead stops at three sentences"
}

test_numbers_do_not_split_sentences() {
  local dir reply
  dir=$(make_primary_dir "$TMP_ROOT/numbers")
  reply="Captain, Herdr 0.9.1 is out and we run 0.7.4 today. Codex 5.5 is ready. The update is small."
  run_hook "$dir" "$reply"
  assert_equals "$reply" "$(spoken "$dir")" \
    "version numbers and decimals must not count as sentence ends"
  pass "numbers with dots stay inside their sentence"
}

test_trailing_list_lead_in_is_dropped() {
  local dir reply
  dir=$(make_primary_dir "$TMP_ROOT/lead-in")
  reply=$(printf '%s\n' "Captain, it's mostly not the AI models. There are two kinds of key involved:" "" \
    "- the model keys" "- the service keys")
  run_hook "$dir" "$reply"
  assert_equals "Captain, it's mostly not the AI models. More on screen." "$(spoken "$dir")" \
    "a closing list lead-in must be dropped and the rest pointed at"
  rm -f "$dir/spoken.log"
  run_hook "$dir" "$(printf '%s\n' "Captain, three things landed:" "" "- the fix" "- the docs")"
  assert_equals "Captain, three things landed. More on screen." "$(spoken "$dir")" \
    "a lead-in that is the only sentence must end with a full stop instead, pointing at the list"
  pass "a trailing list lead-in is dropped, or closed when it is the whole lead"
}

test_pointer_names_what_waits_on_screen() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/pointers")
  run_hook "$dir" "$(printf '%s\n' "Captain, the night jobs lack their keys." "" \
    "**A.** Keychain" "**B.** A file" "" "I'd go with A.")"
  assert_equals "Captain, the night jobs lack their keys. The choice is on screen." "$(spoken "$dir")" \
    "lettered options must point at the choice"
  rm -f "$dir/spoken.log"
  run_hook "$dir" "$(printf '%s\n' "Captain, the catch-up is green." "" "Say \"land it\" when you want it merged.")"
  assert_equals "Captain, the catch-up is green. The choice is on screen." "$(spoken "$dir")" \
    "an instruction to reply with a quoted phrase must point at the choice"
  rm -f "$dir/spoken.log"
  run_hook "$dir" "$(printf '%s\n' "Captain, the floater is rebuilt." "" "- **Rebuild:** say \"rebuild the floater\" when you are at the desk.")"
  assert_equals "Captain, the floater is rebuilt. The choice is on screen." "$(spoken "$dir")" \
    "a list item telling the captain what to say must point at the choice"
  rm -f "$dir/spoken.log"
  run_hook "$dir" "$(printf '%s\n' "Captain, stop works from the Mac." "" "Tell me: did the text say \"Stopped\" or something else?")"
  assert_equals "Captain, stop works from the Mac. There's a question for you on screen." "$(spoken "$dir")" \
    "a quoted word inside a question is not a choice"
  rm -f "$dir/spoken.log"
  run_hook "$dir" "$(printf '%s\n' "Captain, the draft is ready." "" "Should it go to Alex as well?")"
  assert_equals "Captain, the draft is ready. There's a question for you on screen." "$(spoken "$dir")" \
    "a later paragraph ending in a question mark must point at the question"
  rm -f "$dir/spoken.log"
  run_hook "$dir" "$(printf '%s\n' "Captain, the floater needs one more try." "" "1. tap" "2. speak" "3. tap again")"
  assert_equals "Captain, the floater needs one more try. The steps are on screen." "$(spoken "$dir")" \
    "a numbered list must point at the steps"
  rm -f "$dir/spoken.log"
  run_hook "$dir" "$(printf '%s\n' "Captain, the fix merged." "" "Details follow here.")"
  assert_equals "Captain, the fix merged." "$(spoken "$dir")" \
    "a complete lead followed only by a one-line sign-off must get no pointer"
  rm -f "$dir/spoken.log"
  run_hook "$dir" "$(printf '%s\n' "Captain, the fix merged." "" "The cause was a stale cache." "" "The retry now clears it.")"
  assert_equals "Captain, the fix merged. More on screen." "$(spoken "$dir")" \
    "further paragraphs after the lead must point at the rest"
  rm -f "$dir/spoken.log"
  run_hook "$dir" "$(printf '%s\n' "Captain, the fix merged." "" "- the cache" "- the retry")"
  assert_equals "Captain, the fix merged. More on screen." "$(spoken "$dir")" \
    "a bulleted list after the lead must point at the rest"
  rm -f "$dir/spoken.log"
  run_hook "$dir" "$(printf '%s\n' "Captain, the fix merged." "" "PR: https://example.invalid/pr/1")"
  assert_equals "Captain, the fix merged. More on screen." "$(spoken "$dir")" \
    "a link after the lead must point at the rest"
  rm -f "$dir/spoken.log"
  run_hook "$dir" "$(printf '%s\n' "Captain, the emails are drafted; the drafts are below." "" "1. one" "2. two")"
  assert_equals "Captain, the emails are drafted; the drafts are below." "$(spoken "$dir")" \
    "a lead that already points at the screen must get no second pointer"
  rm -f "$dir/spoken.log"
  run_hook "$dir" "$(printf '%s\n' "Captain, CPU stayed below half all night." "" "**A.** Keep it" "**B.** Scale down")"
  assert_equals "Captain, CPU stayed below half all night. The choice is on screen." "$(spoken "$dir")" \
    "the word below in news must not hide the choice pointer"
  pass "the pointer names a choice, a question, steps, more, or nothing"
}

test_pointer_fits_the_spoken_budget() {
  local dir first second out
  dir=$(make_primary_dir "$TMP_ROOT/budget")
  first="Captain, $(printf 'alpha %.0s' $(seq 1 18))done."
  second="Then $(printf 'beta %.0s' $(seq 1 13))end."
  run_hook "$dir" "$(printf '%s\n' "$first $second" "" "**A.** One" "**B.** Two")"
  assert_equals "$first $second The choice is on screen." "$(spoken "$dir")" \
    "a 35-word lead and the choice pointer fit the budget whole"
  rm -f "$dir/spoken.log"
  run_hook "$dir" "$(printf '%s\n' "$first $second" "" "Should it ship tonight?")"
  out=$(spoken "$dir")
  assert_equals "$first There's a question for you on screen." "$out" \
    "a 35-word lead must be cut back so the question pointer is still spoken"
  rm -f "$dir/spoken.log"
  run_hook "$dir" "$(printf '%s\n' "$first $second gamma gamma done." "" "**A.** One" "**B.** Two")"
  out=$(spoken "$dir")
  assert_equals "$first The choice is on screen." "$out" \
    "a 38-word lead must be cut back so the choice pointer is still spoken"
  [ "$(printf '%s' "$out" | wc -w | tr -d ' ')" -le 41 ] || fail "the spoken line must fit 41 words"
  pass "the lead leaves room for its pointer inside the spoken budget"
}

test_model_already_spoke_is_silent_then_next_turn_speaks() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/already-spoke")
  run_hook "$dir" "Captain, turn one is done."
  assert_equals "Captain, turn one is done." "$(spoken "$dir")" "baseline turn must be spoken"
  # Turn two: the model spoke its own line through bin/fm-speak.sh.
  FM_HOME="$dir" "$dir/speak-stub" "Captain, turn two spoken by the model."
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
  wait_for_audio "$dir" "the fallback line never reached the speaker"
  assert_equals "Captain, the review is ready. The choice is on screen." "$(cat "$dir/audio.log")" \
    "the real register's decision refusal must fall back to the first sentence and the choice pointer"
  assert_equals "Captain, the review is ready. The choice is on screen." "$(cat "$dir/state/speak-history/1/text")" \
    "the fallback must be the kept line"
  pass "real fm-speak: decision reply falls back to its first sentence"
}

test_real_speak_decision_only_speaks_notice() {
  local dir
  dir=$(make_primary_dir "$TMP_ROOT/real-notice")
  install_real_speak_fixture "$dir"
  printf 'enabled = true\n' > "$dir/config/speak"
  run_hook_real_speak "$dir" "Shall I merge the review?"
  wait_for_audio "$dir" "the decision notice never reached the speaker"
  assert_equals "Captain, a decision is waiting for you on screen." "$(cat "$dir/audio.log")" \
    "the register's reason passed through the real fm-speak must select the decision notice"
  pass "real fm-speak: a decision-only reply speaks the decision notice"
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
  assert_absent "$dir/state/speak-history" "nothing must be kept when nothing was spoken"
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
test_decision_reply_falls_back_to_first_sentence
test_decision_only_reply_speaks_notice
test_non_decision_refusal_never_claims_a_decision
test_decision_refusal_of_news_never_claims_a_decision
test_markdown_reply_speaks_first_paragraph
test_list_paragraph_is_joined
test_empty_and_tool_only_turns_are_silent
test_code_only_reply_is_silent
test_routine_shipshape_is_silent
test_shipshape_near_misses_are_spoken
test_shipshape_opener_is_dropped_one_line
test_shipshape_opener_is_dropped_two_paragraphs
test_long_reply_is_capped
test_lead_written_to_the_rule_is_kept_whole
test_lead_keeps_at_most_three_sentences
test_numbers_do_not_split_sentences
test_trailing_list_lead_in_is_dropped
test_pointer_names_what_waits_on_screen
test_pointer_fits_the_spoken_budget
test_model_already_spoke_is_silent_then_next_turn_speaks
test_superseded_stop_is_dropped
test_worker_worktree_is_inert
test_secondmate_home_is_inert
test_session_without_lock_is_inert
test_cursor_payload_is_inert
test_real_speak_speaks_and_falls_back
test_real_speak_decision_only_speaks_notice
test_real_speak_muted_and_not_enabled_stay_silent
test_settings_register_async_primary_hook
