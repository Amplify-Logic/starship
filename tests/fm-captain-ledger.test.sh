#!/usr/bin/env bash
# Behavior tests for the captain ledger (bin/fm-captain-ledger.sh): its Claude
# prompt-submit writer, driven through the tracked .claude/settings.json
# registration, and its pending and mark commands.
#
# Every writer runs as a child of a fake harness (a bash symlink named
# "claude") whose pid is the home's session lock, from a git checkout that
# passes the primary-scope check, exactly as a primary's own hook runs. Every
# prompt text here is invented.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LEDGER_SH="$ROOT/bin/fm-captain-ledger.sh"
OPERATIONAL="$ROOT/bin/fm-operational-input.sh"
command -v jq >/dev/null 2>&1 || fail "test host must provide jq"

TMP_ROOT=$(fm_test_tmproot fm-captain-ledger)
fm_git_identity fmtest fmtest@example.invalid
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"
trap fm_test_cleanup EXIT
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_TASK_ID CLAUDE_PROJECT_DIR

PERU="Move the venue deposit from 2 November to 1 February."

# A primary checkout: a plain git repo with AGENTS.md and this repo's bin.
PRIMARY_ROOT="$TMP_ROOT/primary"
mkdir -p "$PRIMARY_ROOT"
git init -q "$PRIMARY_ROOT"
git -C "$PRIMARY_ROOT" commit -q --allow-empty -m init
: > "$PRIMARY_ROOT/AGENTS.md"
ln -s "$ROOT/bin" "$PRIMARY_ROOT/bin"

# The tracked registration's command string.
HOOK_CMD=$(jq -r '.hooks.UserPromptSubmit[].hooks[] | select(.command | contains("fm-captain-ledger.sh")) | .command' \
  "$ROOT/.claude/settings.json")
[ -n "$HOOK_CMD" ] || fail "the tracked Claude settings do not register the captain ledger on UserPromptSubmit"

make_home() {  # <name>: a home opted in through config/captain-ledger
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  : > "$home/config/captain-ledger"
  printf '%s\n' "$home"
}

prompt_payload() {  # <text> [<event>]
  jq -cn --arg t "$1" --arg e "${2:-UserPromptSubmit}" \
    '{session_id: "sess-ledger", hook_event_name: $e, prompt: $t}'
}

# Deliver one payload to the tracked registration as the lock-owning primary
# session of <home> rooted at <root>, and keep whatever it printed.
submit_raw() {  # <home> <payload> [<root>]
  local home=$1 root=${3:-$PRIMARY_ROOT}
  printf '%s' "$2" | FM_HOME="$home" ROOT_DIR="$root" HOOK_CMD="$HOOK_CMD" "$FAKE_CLAUDE" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    env CLAUDE_PROJECT_DIR="$ROOT_DIR" bash -c "cd \"\$CLAUDE_PROJECT_DIR\" && $HOOK_CMD"
  ' > "$home/hook.out" 2>&1
}

submit() {  # <home> <text> [<root>]
  submit_raw "$1" "$(prompt_payload "$2")" "${3:-$PRIMARY_ROOT}" || fail "the ledger hook exited non-zero"
  [ ! -s "$1/hook.out" ] || fail "the ledger hook printed: $(cat "$1/hook.out")"
}

texts() { jq -r '.text' "$1/data/captain-ledger.jsonl" 2>/dev/null; }
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
pending() { FM_HOME="$1" "$LEDGER_SH" pending; }
mark() { FM_HOME="$1" "$LEDGER_SH" mark ${2:+"$2"} >/dev/null || fail "mark failed"; }

test_registration_records_the_captain_prompt() {
  local home entry
  home=$(make_home records)
  submit "$home" "$PERU"
  assert_present "$home/data/captain-ledger.jsonl" "the hook did not create the ledger"
  assert_equals "$PERU" "$(texts "$home")" "the ledger must hold the submitted prompt as said"
  entry=$(jq -c '{seq, session, epoch: (.epoch | type)}' "$home/data/captain-ledger.jsonl")
  assert_equals '{"seq":1,"session":"sess-ledger","epoch":"number"}' "$entry" \
    "an entry must carry its seq, the session id, and an epoch"
  assert_equals 600 "$(mode_of "$home/data/captain-ledger.jsonl")" "the ledger must be created owner-only"
  pass "ledger: the tracked prompt-submit registration writes the captain's prompt before the hook returns"
}

# Without the opt-in flag the hook records nothing and creates nothing, while
# pending and mark keep reconciling what a ledger already holds.
test_a_home_without_the_flag_records_nothing() {
  local home
  home=$(make_home not-opted-in)
  rm -f "$home/config/captain-ledger"
  submit "$home" "$PERU"
  assert_absent "$home/data/captain-ledger.jsonl" "a home without config/captain-ledger must record nothing"
  : > "$home/config/captain-ledger"
  submit "$home" "$PERU"
  assert_equals "$PERU" "$(texts "$home")" "the flag must switch the recording on"
  rm -f "$home/config/captain-ledger"
  submit "$home" "Keep the review on Thursday."
  assert_equals "$PERU" "$(texts "$home")" "removing the flag must stop the recording"
  assert_contains "$(pending "$home")" "Move the venue deposit" "pending must still list words recorded while the flag was on"
  mark "$home"
  assert_equals "" "$(pending "$home")" "mark must still reconcile a ledger with the flag off"
  pass "ledger: only a home with config/captain-ledger records, and pending and mark still reconcile without it"
}

test_operational_and_harness_started_input_is_dropped() {
  local home wake brief guard steer
  home=$(make_home dropped)
  wake=$(printf 'signal: demo.status' | "$OPERATIONAL" encode watcher)
  brief=$(printf '# Task\nBuild the thing.' | "$OPERATIONAL" encode launch-brief)
  guard=$(printf 'the watcher is down' | "$OPERATIONAL" encode turn-end-guard)
  steer=$(printf 'rebase onto main' | "$OPERATIONAL" encode from-firstmate)
  submit "$home" "$wake"
  submit "$home" "$brief"
  submit "$home" "$guard"
  submit "$home" "$steer"
  submit "$home" $'\n\n<task-notification>\n<summary>Stop hook feedback</summary>\n</task-notification>'
  submit "$home" $'  \n\t'
  submit_raw "$home" "$(jq -cn --arg t "$PERU" '{hook_event_name: "UserPromptSubmit", prompt: $t, cursor_version: "x"}')"
  submit_raw "$home" "$(prompt_payload "$PERU" Stop)"
  submit_raw "$home" 'not json at all'
  assert_absent "$home/data/captain-ledger.jsonl" \
    "a wake, a launch brief, a guard follow-up, a steer, a rewake, a blank prompt, a Cursor payload, another event, or garbage was recorded"
  submit "$home" "kept"
  assert_equals "kept" "$(texts "$home")" "a captain prompt after dropped input must still be recorded"
  pass "ledger: operational input, the <task-notification> rewake, foreign and non-prompt payloads record nothing"
}

test_an_operational_label_stripped_of_its_mark_is_dropped() {
  local home digest
  home=$(make_home stripped)
  digest=$(printf 'Supervisor escalate (3 events): demo stalled' | "$OPERATIONAL" encode away-supervisor)
  # Claude Code removes invisible characters from typed input, so the digest
  # reaches the hook without its leading U+2063 mark.
  submit "$home" "${digest#$'\xE2\x81\xA3'}"
  assert_absent "$home/data/captain-ledger.jsonl" "an away-supervisor digest stripped of its mark was recorded"
  submit "$home" "Why did the FIRSTMATE_OP: v1 watcher: wake fire twice?"
  assert_equals "Why did the FIRSTMATE_OP: v1 watcher: wake fire twice?" "$(texts "$home")" \
    "a captain prompt that mentions the operational label mid-sentence must still be recorded"
  pass "ledger: an operational label stripped of its mark records nothing, a mention of it mid-sentence is kept"
}

test_a_session_without_the_lock_records_nothing() {
  local home holder
  home=$(make_home unowned)
  sleep 30 &
  holder=$!
  printf '%s\n' "$holder" > "$home/state/.lock"
  prompt_payload "$PERU" | FM_HOME="$home" "$FAKE_CLAUDE" -c \
    'cd "$1" && CLAUDE_PROJECT_DIR="$1" bash -c "$2"' _ "$PRIMARY_ROOT" "$HOOK_CMD" \
    || fail "the ledger hook exited non-zero for a session without the lock"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  rm -f "$home/state/.lock"
  prompt_payload "$PERU" | FM_HOME="$home" "$FAKE_CLAUDE" -c \
    'cd "$1" && CLAUDE_PROJECT_DIR="$1" bash -c "$2"' _ "$PRIMARY_ROOT" "$HOOK_CMD" \
    || fail "the ledger hook exited non-zero for a session with no lock at all"
  assert_absent "$home/data/captain-ledger.jsonl" "a session that does not hold the fleet lock recorded a prompt"
  pass "ledger: a read-only second session and a session with no lock record nothing"
}

test_a_crewmate_records_nothing() {
  local home worktree
  home=$(make_home crew)
  worktree="$TMP_ROOT/crew-worktree"
  git -C "$PRIMARY_ROOT" worktree add -q --detach "$worktree" >/dev/null 2>&1 || fail "could not add a linked worktree"
  : > "$worktree/AGENTS.md"
  ln -s "$ROOT/bin" "$worktree/bin"
  submit "$home" "from a linked worktree" "$worktree"
  FM_TASK_ID=demo-task submit "$home" "from a task worker pane"
  assert_absent "$home/data/captain-ledger.jsonl" "a crewmate's prompt reached the captain ledger"
  pass "ledger: a crew worktree and a task worker pane record nothing"
}

test_a_long_prompt_keeps_its_head_and_tail() {
  local home long text
  home=$(make_home long)
  long="HEAD$(awk 'BEGIN { for (i = 0; i < 5000; i++) printf "x" }')TAIL"
  submit "$home" "$long"
  text=$(texts "$home")
  [ "${#text}" -eq 4000 ] || fail "a capped entry must hold 4000 characters with its note, got ${#text}"
  case "$text" in HEAD*TAIL) ;; *) fail "a capped entry must keep the prompt's head and tail" ;; esac
  assert_contains "$text" "[ledger truncated: " "a capped entry must say how much it left out"
  pass "ledger: a prompt over 4000 characters is capped with its head, its tail, and a truncation note"
}

test_pending_mark_and_return() {
  local home out
  home=$(make_home cycle)
  assert_equals "" "$(pending "$home")" "pending must print nothing before any captain words"
  submit "$home" "$PERU"
  out=$(pending "$home")
  assert_contains "$out" "UNRECONCILED CAPTAIN WORDS (1 since $(date +%Y-%m-%d))" "pending must count the entry and date the oldest"
  assert_contains "$out" "$PERU" "pending must preview the captain's words"
  assert_contains "$out" "$home/data/captain-ledger.jsonl" "pending must name the ledger"
  assert_contains "$out" "fm-captain-ledger.sh mark 1." "pending must say to mark through the newest entry it showed"
  mark "$home"
  assert_equals "" "$(pending "$home")" "pending must be silent once every entry is marked"
  submit "$home" "Keep the review on Thursday."
  out=$(pending "$home")
  assert_contains "$out" "UNRECONCILED CAPTAIN WORDS (1 since " "a new prompt after mark must bring the section back with a count of 1"
  assert_contains "$out" "Keep the review on Thursday." "the new prompt must be previewed"
  assert_not_contains "$out" "$PERU" "a marked entry must not reappear"
  pass "ledger: pending lists unmarked words, mark silences it, and a new prompt brings it back with a count of 1"
}

test_mark_stops_at_the_seq_pending_showed() {
  local home out
  home=$(make_home midturn)
  submit "$home" "first"
  submit "$home" "second"
  submit "$home" "third"
  assert_contains "$(pending "$home")" "fm-captain-ledger.sh mark 3." "pending must name the newest seq it showed"
  submit "$home" "Said while the agent was reconciling."
  mark "$home" 3
  out=$(pending "$home")
  assert_contains "$out" "UNRECONCILED CAPTAIN WORDS (1 since " "a prompt recorded after pending was shown must stay pending"
  assert_contains "$out" "Said while the agent was reconciling." "the mid-turn prompt must still be previewed"
  assert_not_contains "$out" "third" "an entry marked by its seq must not reappear"
  mark "$home" 2
  assert_contains "$(pending "$home")" "(1 since " "mark must never move the cursor backwards"
  mark "$home" 99
  assert_equals 4 "$(cat "$home/state/.captain-ledger-cursor")" "mark must never move the cursor past the newest entry"
  FM_HOME="$home" "$LEDGER_SH" mark 3x >/dev/null 2>&1
  assert_equals 2 "$?" "mark must refuse a seq that is not a number"
  pass "ledger: mark <seq> stops at the seq pending showed, so a mid-turn prompt stays pending"
}

test_pending_bounds_its_previews() {
  local home out n previews
  home=$(make_home bounded)
  for n in $(seq 1 14); do
    submit "$home" "entry $n $(awk 'BEGIN { for (i = 0; i < 300; i++) printf "w" }')"
  done
  out=$(pending "$home")
  assert_contains "$out" "UNRECONCILED CAPTAIN WORDS (14 since " "pending must count every unmarked entry"
  previews=$(printf '%s\n' "$out" | grep -c '^  #')
  assert_equals 12 "$previews" "pending must preview at most 12 entries"
  assert_contains "$out" "(2 earlier entries not shown)" "pending must say how many entries it left out"
  assert_contains "$out" "entry 14 " "pending must preview the newest entries"
  assert_not_contains "$out" "entry 2 " "pending must leave out the oldest entries beyond the bound"
  printf '%s\n' "$out" | grep '^  #' | sed 's/^  #[0-9]* [0-9-]* [0-9:]*  //' | while IFS= read -r line; do
    [ "${#line}" -le 160 ] || fail "a preview ran past 160 characters (${#line})"
  done || exit 1
  pass "ledger: pending previews at most 12 entries of at most 160 characters each"
}

test_seq_survives_a_removed_ledger_and_a_torn_line() {
  local home
  home=$(make_home seq)
  submit "$home" "one"
  submit "$home" "two"
  mark "$home"
  rm -f "$home/data/captain-ledger.jsonl"
  submit "$home" "three"
  assert_equals 3 "$(jq -r '.seq' "$home/data/captain-ledger.jsonl")" "a new entry must stay above the cursor after the ledger is removed"
  assert_contains "$(pending "$home")" "three" "an entry written after the ledger was removed must be pending"
  printf '{"seq":4,"epoch":1,"session":"s","text":"torn' >> "$home/data/captain-ledger.jsonl"
  submit "$home" "after a torn line"
  assert_equals "after a torn line" "$(jq -Rr 'fromjson? | select(.seq == 4) | .text' "$home/data/captain-ledger.jsonl")" \
    "an entry after a torn last line must stay a readable line of its own"
  pass "ledger: seq stays above the cursor, and a torn last line cannot swallow the next entry"
}

test_registration_records_the_captain_prompt
test_a_home_without_the_flag_records_nothing
test_operational_and_harness_started_input_is_dropped
test_an_operational_label_stripped_of_its_mark_is_dropped
test_a_session_without_the_lock_records_nothing
test_a_crewmate_records_nothing
test_a_long_prompt_keeps_its_head_and_tail
test_pending_mark_and_return
test_mark_stops_at_the_seq_pending_showed
test_pending_bounds_its_previews
test_seq_survives_a_removed_ledger_and_a_torn_line

echo "# fm-captain-ledger.test.sh: all assertions passed"
