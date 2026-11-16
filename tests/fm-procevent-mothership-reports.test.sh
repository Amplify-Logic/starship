#!/usr/bin/env bash
# Behavioral tests for how a Mothership room card hears about the work the owner
# took on for it (bin/fm-procevent-mothership.sh "OUTCOMES ON THE CARD"): the
# adapter's report and blocked-scan, and the real lifecycle steps that call them,
# bin/fm-spawn.sh (fake tmux, real git worktree), the real watcher through
# bin/fm-watch-checkpoint.sh, bin/fm-pr-check.sh, the shared PR merge outcome in
# bin/fm-merge-outcome-lib.sh, and bin/fm-merge-local.sh. A scripted stand-in
# for the Mothership link records what each send would have told the room; the
# rooms, projects and cards are invented.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

ADAPTER="$ROOT/bin/fm-procevent-mothership.sh"
TMP_ROOT=$(fm_test_tmproot fm-procevent-mothership-reports)
STUB_BIN="$TMP_ROOT/bin"
mkdir -p "$STUB_BIN"

# The stand-in link. $MS_STUB is its directory. progress, problem and result
# each append one line to `sent` naming the card, room, project, tags, link,
# client id and text. Like the real link, a send the room's allow-list in
# $MOTHERSHIP_CONFIG does not let through (its project, and one of the entry's
# tags when it names any) stops with "Not sent", and a text holding a line of
# `words` is refused; neither is recorded. A `down` file makes every send fail
# as an unreachable room, and a `slow` file makes each one take three seconds.
cat > "$STUB_BIN/mothership" <<'SH'
#!/usr/bin/env bash
set -u
d=${MS_STUB:?}
cmd=${1-}
[ "$#" -eq 0 ] || shift
case "$cmd" in progress|problem|result) ;; *) echo "unexpected command: $cmd" >&2; exit 1 ;; esac
card=$1
shift
room='' project='' tags='' link='' cid='' text=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --room) room=$2; shift 2 ;;
    --project) project=$2; shift 2 ;;
    --tag) tags="$tags${tags:+,}$2"; shift 2 ;;
    --link) link=$2; shift 2 ;;
    --cid) cid=$2; shift 2 ;;
    *) text=$1; shift ;;
  esac
done
[ ! -e "$d/slow" ] || sleep 3
if ! jq -e --arg r "$room" --arg p "$project" --arg t "$tags" \
  'any(.rooms[$r].allow[]?; .project == $p and ((.tags // []) | length == 0 or any(.[]; . as $x | $t | split(",") | index($x))))' \
  "${MOTHERSHIP_CONFIG:?}" >/dev/null 2>&1; then
  echo "Not sent: room $room's allow-list does not let this project through." >&2
  exit 1
fi
if [ -s "$d/words" ] && printf '%s\n' "$text" | grep -qiFf "$d/words"; then
  echo "Refused: a private word was found in text, line 1." >&2
  exit 1
fi
[ ! -e "$d/down" ] || { echo "Could not reach the room at https://room.example.test" >&2; exit 3; }
printf '%s card=%s room=%s project=%s tags=%s link=%s cid=%s text=%s\n' \
  "$cmd" "$card" "$room" "$project" "$tags" "$link" "$cid" "$text" >> "$d/sent"
echo '{"ok":true}'
SH
chmod +x "$STUB_BIN/mothership"

PR_URL=https://github.com/acme/sample/pull/7

# make_home <name>: a home with an empty backlog, the room config and a
# stand-in directory; prints the case directory.
make_home() {
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/home/config" "$h/home/state" "$h/home/data" "$h/home/projects" "$h/stub"
  fm_test_tasks_toml "$h/home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$h/home/data/backlog.md"
  printf '%s\n' '{"default":"alpha","rooms":{"alpha":{"url":"https://room.example.test","allow":[{"project":"sample"},{"project":"studio","tags":["alpha"]}]}}}' > "$h/rooms.json"
  printf '%s\n' "$h"
}

# in_home <dir> <command...>: run one real script against the case home.
in_home() {
  local h=$1
  shift
  env -u FM_TRACE_CONTEXT FM_ROOT_OVERRIDE='' FM_HOME="$h/home" \
    FM_STATE_OVERRIDE="$h/home/state" FM_DATA_OVERRIDE="$h/home/data" \
    FM_PROJECTS_OVERRIDE="$h/home/projects" FM_CONFIG_OVERRIDE="$h/home/config" \
    MS_STUB="$h/stub" FM_MOTHERSHIP_BIN="$STUB_BIN/mothership" MOTHERSHIP_CONFIG="$h/rooms.json" "$@"
}

add_task() {  # <dir> <task-id> <repo> <body>
  in_home "$1" "$ROOT/bin/fm-tasks-axi.sh" add "$2" "Room work for $2" --kind ship --repo "$3" --body "$4" >/dev/null \
    || fail "could not file $2"
}

sent_of() { cat "$1/stub/sent" 2>/dev/null; }
wakes_of() { cat "$1/home/state/.wake-queue" 2>/dev/null; }

wait_for_sent() {  # <dir> <line-count> [tries of 0.1s]
  local _
  for _ in $(seq 1 "${3:-100}"); do
    [ "$(sent_of "$1" | grep -c .)" -ge "$2" ] && return 0
    sleep 0.1
  done
  return 1
}

need_tools() {
  command -v tasks-axi >/dev/null 2>&1 || { pass "skip: tasks-axi not found"; return 1; }
  command -v perl >/dev/null 2>&1 || { pass "skip: perl not found"; return 1; }
}

test_help() {
  local help
  if help=$("$ADAPTER" --help 2>&1); then fail "help exited zero"; fi
  assert_contains "$help" "report [--detach] <task-id> started|pr|blocked|merged" "help names report"
  assert_contains "$help" "OUTCOMES ON THE CARD" "help explains what the card hears"
  pass "help names report and blocked-scan"
}

test_report_tells_the_card_each_event_once() {
  local h out
  need_tools || return 0
  h=$(make_home events)
  add_task "$h" room-t1 studio "Picked up from the room. mothership: alpha/c6."

  out=$(in_home "$h" "$ADAPTER" report room-t1 started 2>&1) || fail "report started failed: $out"
  assert_equals "told: room-t1: the alpha room heard that work on it started" "$out" "started is told"
  out=$(in_home "$h" "$ADAPTER" report room-t1 started 2>&1) || fail "report started again failed: $out"
  assert_contains "$out" "already told" "a repeat is not sent again"
  in_home "$h" "$ADAPTER" report room-t1 pr --pr "$PR_URL" >/dev/null 2>&1 || fail "report pr failed"
  printf 'working [at=1790000000]: setup done\nblocked [at=1790000100]: the build needs a key\n' > "$h/home/state/room-t1.status"
  in_home "$h" "$ADAPTER" report room-t1 blocked >/dev/null 2>&1 || fail "report blocked failed"
  in_home "$h" "$ADAPTER" report room-t1 merged --pr "$PR_URL" >/dev/null 2>&1 || fail "report merged failed"
  out=$(in_home "$h" "$ADAPTER" report room-t1 pr --pr https://github.com/acme/sample/pull/8 2>&1) || fail "a late report failed: $out"
  assert_contains "$out" "already heard that it landed" "nothing but the result after it"
  assert_equals "$(cat <<EOF
progress card=c6 room=alpha project=studio tags=alpha link= cid=fm-room-t1-started text=Work has started.
progress card=c6 room=alpha project=studio tags=alpha link= cid=fm-room-t1-pr-$(printf '%s' "$PR_URL" | cksum | awk '{ print $1 }') text=Ready for review: $PR_URL
problem card=c6 room=alpha project=studio tags=alpha link= cid=fm-room-t1-blocked-$(printf 'blocked [at=1790000100]: the build needs a key' | cksum | awk '{ print $1 }') text=Held up by a blocker; looking into it.
result card=c6 room=alpha project=studio tags=alpha link=$PR_URL cid=fm-room-t1-merged text=Done: the change has landed.
EOF
)" "$(sent_of "$h")" "the card heard each event once, in the task's project with its allow-list tag, and none of the blocker's own words"
  [ -z "$(wakes_of "$h")" ] || fail "a told card woke the first mate: $(wakes_of "$h")"
  pass "a task's card hears that work started, its PR, a blocker and that it landed, each once, and nothing after it landed"
}

test_a_quoted_ref_is_read() {
  local h out
  need_tools || return 0
  h=$(make_home quoted)
  add_task "$h" room-q1 sample 'File it with "mothership: alpha/q1".'
  # shellcheck disable=SC2016 # literal backticks in the body
  add_task "$h" room-q2 sample 'Taken on for `mothership: alpha/q2`.'
  add_task "$h" room-q3 sample "Taken on (mothership: alpha/q3)."
  add_task "$h" room-q4 sample "Taken on as 'mothership: alpha/q4'..."
  add_task "$h" room-q5 sample "Not a ref: notmothership: alpha/q5"
  for out in q1 q2 q3 q4; do
    in_home "$h" "$ADAPTER" report "room-$out" started >/dev/null 2>&1 || fail "report room-$out failed"
  done
  out=$(in_home "$h" "$ADAPTER" report room-q5 started 2>&1) || fail "report room-q5 failed: $out"
  assert_equals "nothing to report: room-q5 serves no room card" "$out" "a ref glued to a word is no ref"
  assert_equals "$(printf 'q1\nq2\nq3\nq4')" "$(sent_of "$h" | sed -E 's/^progress card=([^ ]*) .*$/\1/')" \
    "a ref in quotes, backticks or parentheses names its card, without the closing mark or trailing dots"
  pass "a ref quoted, backticked or parenthesised in the body still tells its card"
}

test_no_card_sends_nothing() {
  local h out
  need_tools || return 0
  h=$(make_home nocard)
  add_task "$h" plain-t1 sample "Ordinary work with no room behind it."
  out=$(in_home "$h" "$ADAPTER" report plain-t1 started 2>&1) || fail "report failed: $out"
  assert_equals "nothing to report: plain-t1 serves no room card" "$out" "a task with no card has nothing to report"
  out=$(in_home "$h" "$ADAPTER" report never-filed started 2>&1) || fail "report on an unknown task failed: $out"
  assert_contains "$out" "serves no room card" "a task the backlog does not hold has nothing to report"
  in_home "$h" "$ADAPTER" report --detach plain-t1 started >/dev/null 2>&1 || fail "a detached report failed"
  sleep 0.5
  [ ! -e "$h/home/state/mothership" ] || fail "a task with no card created state: $(ls -R "$h/home/state/mothership")"
  [ -z "$(sent_of "$h")" ] || fail "a task with no card sent something: $(sent_of "$h")"
  [ -z "$(wakes_of "$h")" ] || fail "a task with no card woke the first mate: $(wakes_of "$h")"
  pass "a task that serves no room card sends nothing and creates no state"
}

test_a_refused_send_tells_the_first_mate() {
  local h out started elapsed
  need_tools || return 0
  h=$(make_home refused)
  add_task "$h" room-t2 other "mothership: alpha/c7"
  if out=$(in_home "$h" "$ADAPTER" report room-t2 started 2>&1); then fail "a send outside the allow-list counted as told"; fi
  assert_contains "$out" "failed: room-t2: the alpha room was not told that work on it started: Not sent: room alpha's allow-list does not let this project through." "the refusal is named"
  assert_contains "$(wakes_of "$h")" "check: mothership-report: the alpha room's card for room-t2 was not told that work on it started: Not sent" "the first mate is told"
  assert_contains "$(wakes_of "$h")" "bin/fm-procevent-mothership.sh report room-t2 started sends it again" "the wake names how to send it again"

  add_task "$h" room-t3 sample "mothership: alpha/c8"
  printf 'review\n' > "$h/stub/words"
  if out=$(in_home "$h" "$ADAPTER" report room-t3 pr --pr "$PR_URL" 2>&1); then fail "a send the word check refused counted as told"; fi
  assert_contains "$out" "Refused: a private word was found" "the word check's refusal is named"
  assert_contains "$(wakes_of "$h")" "report room-t3 pr --pr $PR_URL sends it again" "the wake carries the PR address to send again"
  : > "$h/stub/words"
  touch "$h/stub/down"
  if out=$(in_home "$h" "$ADAPTER" report room-t3 pr --pr "$PR_URL" 2>&1); then fail "an unreachable room counted as told"; fi
  assert_contains "$out" "Could not reach the room" "an unreachable room is named"
  rm -f "$h/stub/down"
  out=$(in_home "$h" "$ADAPTER" report room-t3 pr --pr "$PR_URL" 2>&1) || fail "the send again failed: $out"
  assert_contains "$out" "told: room-t3" "a send that failed is sent when run again"
  assert_equals 1 "$(sent_of "$h" | grep -c .)" "only the send that got through reached the room"

  # A lifecycle step never waits on the room, and never fails because of it.
  mkdir -p "$h/home/state/mothership"
  touch "$h/stub/slow"
  started=$(date +%s)
  in_home "$h" "$ADAPTER" report --detach room-t3 started >/dev/null 2>&1 || fail "a detached report failed"
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -le 1 ] || fail "a detached report waited ${elapsed}s on the room"
  wait_for_sent "$h" 2 || fail "the detached report never reached the room: $(sent_of "$h")"
  rm -f "$h/stub/slow"
  touch "$h/stub/down"
  in_home "$h" "$ADAPTER" report --detach room-t3 merged >/dev/null 2>&1 || fail "a detached report that will fail exited nonzero"
  pass "a send the allow-list, the word check or the network stops wakes the first mate, is sent again on request, and never holds up a step"
}

test_blocked_scan_tells_each_new_blocker_once() {
  local h out lock _
  need_tools || return 0
  h=$(make_home blocked)
  add_task "$h" room-t4 sample "mothership: alpha/c9"
  : > "$h/home/state/room-t4.meta"
  printf 'blocked [at=1780000000]: an old blocker from an earlier run\n' > "$h/home/state/room-t4.status"
  in_home "$h" "$ADAPTER" report room-t4 started >/dev/null 2>&1 || fail "report started failed"
  in_home "$h" "$ADAPTER" blocked-scan >/dev/null 2>&1 || fail "a quiet scan failed"
  sleep 0.5
  assert_equals 1 "$(sent_of "$h" | grep -c .)" "a blocker from before the card followed the task is not told"

  printf 'blocked [at=1790000200]: waiting on a login\n' >> "$h/home/state/room-t4.status"
  in_home "$h" "$ADAPTER" blocked-scan >/dev/null 2>&1 || fail "scan failed"
  wait_for_sent "$h" 2 || fail "the new blocker was not told: $(sent_of "$h")"
  in_home "$h" "$ADAPTER" blocked-scan >/dev/null 2>&1 || fail "scan again failed"
  printf 'working [at=1790000300]: back at it\n' >> "$h/home/state/room-t4.status"
  in_home "$h" "$ADAPTER" blocked-scan >/dev/null 2>&1 || fail "scan after work resumed failed"
  sleep 0.5
  assert_equals 2 "$(sent_of "$h" | grep -c .)" "one blocker is told once"
  printf 'blocked [at=1790000400]: a second blocker\n' >> "$h/home/state/room-t4.status"
  in_home "$h" "$ADAPTER" blocked-scan >/dev/null 2>&1 || fail "scan for the second blocker failed"
  wait_for_sent "$h" 3 || fail "the second blocker was not told: $(sent_of "$h")"
  out=$(sent_of "$h" | grep -c '^problem card=c9 room=alpha project=sample tags= link= cid=fm-room-t4-blocked-')
  assert_equals 2 "$out" "each new blocker is one problem line with its own client id"

  # The detached send records what it told after the room answers, still
  # holding the task's lock, and a scan leaves a held task for the next poll,
  # so the cleanup is checked once that send is done.
  lock="$h/home/state/mothership/.task-room-t4.lock"
  for _ in $(seq 1 50); do { [ -e "$lock" ] || [ -L "$lock" ]; } || break; sleep 0.1; done
  rm -f "$h/home/state/room-t4.meta"
  in_home "$h" "$ADAPTER" blocked-scan >/dev/null 2>&1 || fail "scan after cleanup failed"
  [ ! -e "$h/home/state/mothership/tasks/room-t4.json" ] || fail "a cleaned-up task is still followed"
  pass "the blocker scan tells the card about each new blocked line once and stops following a cleaned-up task"
}

test_blocked_scan_never_waits_on_a_send() {
  local h lock started elapsed _
  need_tools || return 0
  h=$(make_home scan-busy)
  lock="$h/home/state/mothership/.task-room-t5.lock"
  add_task "$h" room-t5 sample "mothership: alpha/c10"
  : > "$h/home/state/room-t5.meta"
  in_home "$h" "$ADAPTER" report room-t5 started >/dev/null 2>&1 || fail "report started failed"

  # A new blocker while a send to a slow room holds the task's record.
  touch "$h/stub/slow"
  printf 'blocked [at=1790000700]: waiting on a login\n' >> "$h/home/state/room-t5.status"
  in_home "$h" "$ADAPTER" report --detach room-t5 pr --pr "$PR_URL" >/dev/null 2>&1 || fail "a detached report failed"
  for _ in $(seq 1 50); do { [ -e "$lock" ] || [ -L "$lock" ]; } && break; sleep 0.1; done
  { [ -e "$lock" ] || [ -L "$lock" ]; } || fail "the detached send never held the task's record"
  started=$(date +%s)
  in_home "$h" "$ADAPTER" blocked-scan >/dev/null 2>&1 || fail "a scan beside a send failed"
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -le 1 ] || fail "the scan waited ${elapsed}s on a send to the room"
  wait_for_sent "$h" 2 || fail "the PR send never reached the room: $(sent_of "$h")"
  rm -f "$h/stub/slow"
  for _ in $(seq 1 50); do { [ -e "$lock" ] || [ -L "$lock" ]; } || break; sleep 0.1; done
  in_home "$h" "$ADAPTER" blocked-scan >/dev/null 2>&1 || fail "the next scan failed"
  wait_for_sent "$h" 3 || fail "the blocker left for the next poll was never told: $(sent_of "$h")"
  assert_contains "$(sent_of "$h" | sed -n 3p)" "problem card=c10" "the next poll tells the blocker"

  # A cleaned-up task while its landing is still being sent.
  touch "$h/stub/slow"
  in_home "$h" "$ADAPTER" report --detach room-t5 merged --pr "$PR_URL" >/dev/null 2>&1 || fail "a detached merged report failed"
  for _ in $(seq 1 50); do { [ -e "$lock" ] || [ -L "$lock" ]; } && break; sleep 0.1; done
  rm -f "$h/home/state/room-t5.meta"
  started=$(date +%s)
  in_home "$h" "$ADAPTER" blocked-scan >/dev/null 2>&1 || fail "a scan beside the landing send failed"
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -le 1 ] || fail "the scan waited ${elapsed}s to stop following a cleaned-up task"
  wait_for_sent "$h" 4 || fail "the landing never reached the room: $(sent_of "$h")"
  for _ in $(seq 1 50); do { [ -e "$lock" ] || [ -L "$lock" ]; } || break; sleep 0.1; done
  in_home "$h" "$ADAPTER" blocked-scan >/dev/null 2>&1 || fail "the scan after the landing failed"
  [ ! -e "$h/home/state/mothership/tasks/room-t5.json" ] || fail "a cleaned-up task is still followed"
  pass "the blocker scan never waits on a send that holds a task, and picks the task up on the next poll"
}

# The real lifecycle steps. Sets PROJ_DIR WT_DIR FAKEBIN for one case home.
make_lifecycle() {  # <dir> <task-id>
  local h=$1 task=$2
  PROJ_DIR="$h/sample"
  WT_DIR="$h/wt"
  mkdir -p "$h/home/data/$task" "$h/home/user-home" "$h/home/state/mothership"
  printf 'claude\n' > "$h/home/config/crew-harness"
  printf '%s\n' "$$" > "$h/home/state/.lock"
  touch "$h/home/state/.last-watcher-beat"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "fm/$task"
  cat > "$h/home/data/$task/brief.md" <<EOF
# Task
## Captain's intent
Report $task back to its room card.

## Firstmate spec
Nothing to build.
EOF
  FAKEBIN=$(fm_test_make_spawn_fakebin "$h" no-mistakes)
  # An unreadable forge answer: no draft refusal and no recorded head.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/gh"
  chmod +x "$FAKEBIN/gh"
}

in_lifecycle() {  # <dir> <command...>
  local h=$1
  shift
  in_home "$h" env HOME="$h/home/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" PATH="$FAKEBIN:$PATH" "$@"
}

test_lifecycle_steps_report_to_the_card() {
  local h task=room-pr1 out
  need_tools || return 0
  h=$(make_home lifecycle-pr)
  make_lifecycle "$h" "$task"
  add_task "$h" "$task" sample "mothership: alpha/c11"

  out=$(in_lifecycle "$h" "$ROOT/bin/fm-spawn.sh" "$task" "$PROJ_DIR" --mode direct-PR --yolo off 2>&1) \
    || fail "spawn failed: $out"
  wait_for_sent "$h" 1 || fail "dispatch did not tell the card: $(sent_of "$h")"
  printf 'blocked [at=1790000500]: waiting on a login\n' >> "$h/home/state/$task.status"
  out=$(in_lifecycle "$h" env FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 10 2>&1)
  wait_for_sent "$h" 2 || fail "the watcher did not tell the card about the blocker: $(sent_of "$h") ($out)"
  printf 'done [at=1790000600]: PR %s\n' "$PR_URL" >> "$h/home/state/$task.status"
  out=$(in_lifecycle "$h" "$ROOT/bin/fm-pr-check.sh" "$task" "$PR_URL" 2>&1) || fail "PR registration failed: $out"
  wait_for_sent "$h" 3 || fail "the PR was not told: $(sent_of "$h")"
  out=$(in_lifecycle "$h" env FM_PR_CHECK_MERGE=1 "$ROOT/bin/fm-pr-check.sh" "$task" "$PR_URL" 2>&1) \
    || fail "merge-time PR re-record failed: $out"
  # shellcheck disable=SC2016 # expanded by the inner shell
  out=$(in_lifecycle "$h" bash -c '. "$1/bin/fm-merge-outcome-lib.sh" && fm_merge_outcome_report "$FM_HOME" "$FM_STATE_OVERRIDE" "$2" "$3" poll' \
    _ "$ROOT" "$task" "$PR_URL" 2>&1) || fail "the merge outcome was not recorded: $out"
  wait_for_sent "$h" 4 || fail "the merge was not told: $(sent_of "$h")"
  sleep 0.5
  assert_equals "$(printf 'progress Work has started.\nproblem Held up by a blocker; looking into it.\nprogress Ready for review: %s\nresult Done: the change has landed. %s' "$PR_URL" "$PR_URL")" \
    "$(sent_of "$h" | sed -E 's/^([a-z]+) .* link=([^ ]*) cid=[^ ]* text=(.*)$/\1 \3 \2/; s/ $//')" \
    "dispatch, the watcher, the PR registration and the merge each told the card once, and the merge-time re-record told nothing"
  pass "the real dispatch, watcher, PR registration and merge steps tell the card how the work goes"
}

test_a_local_landing_reports_to_the_card() {
  local h task=room-local1 out
  need_tools || return 0
  h=$(make_home lifecycle-local)
  make_lifecycle "$h" "$task"
  add_task "$h" "$task" sample "mothership: alpha/c12"
  out=$(in_lifecycle "$h" "$ROOT/bin/fm-spawn.sh" "$task" "$PROJ_DIR" --mode local-only --yolo off 2>&1) \
    || fail "spawn failed: $out"
  wait_for_sent "$h" 1 || fail "dispatch did not tell the card: $(sent_of "$h")"
  printf 'done: ready in branch\n' >> "$h/home/state/$task.status"
  printf 'landed\n' > "$WT_DIR/landed.txt"
  git -C "$WT_DIR" add landed.txt
  git -C "$WT_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'landed'
  printf 'local_done_head=%s\n' "$(git -C "$WT_DIR" rev-parse HEAD)" >> "$h/home/state/$task.meta"
  out=$(in_lifecycle "$h" "$ROOT/bin/fm-merge-local.sh" "$task" 2>&1) || fail "local merge failed: $out"
  wait_for_sent "$h" 2 || fail "the local landing was not told: $(sent_of "$h")"
  assert_equals "result card=c12 room=alpha project=sample tags= link= cid=fm-room-local1-merged text=Done: the change has landed." \
    "$(sent_of "$h" | sed -n 2p)" "a local landing settles the card with no link"
  pass "a local-only landing tells the card it landed"
}

fm_test_run \
  test_help \
  test_report_tells_the_card_each_event_once \
  test_a_quoted_ref_is_read \
  test_no_card_sends_nothing \
  test_a_refused_send_tells_the_first_mate \
  test_blocked_scan_tells_each_new_blocker_once \
  test_blocked_scan_never_waits_on_a_send \
  test_lifecycle_steps_report_to_the_card \
  test_a_local_landing_reports_to_the_card
