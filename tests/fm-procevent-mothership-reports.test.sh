#!/usr/bin/env bash
# Behavioral tests for how a Mothership room hears about a task
# (bin/fm-procevent-mothership.sh "OUTCOMES IN THE ROOM"): a card about the work
# the owner took on for it, and the room's Ships view about a job of a project
# the owner shared with that room. They drive the adapter's report and
# blocked-scan, and the real lifecycle steps that call them, bin/fm-spawn.sh
# (fake tmux, real git worktree), the real watcher through
# bin/fm-watch-checkpoint.sh, bin/fm-pr-check.sh, the shared PR merge outcome in
# bin/fm-merge-outcome-lib.sh, bin/fm-merge-local.sh and bin/fm-teardown.sh. A
# scripted stand-in for the Mothership link records what each send would have
# told the room; the rooms, projects and cards are invented.
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
# client id and text, a progress --landing as `landing`; job appends one line
# naming the job id, room, project, tags, title, state, link, client id and
# text, or `drop` for --drop. Like the real link, a send the room's allow-list in
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
case "$cmd" in progress|problem|result|job) ;; *) echo "unexpected command: $cmd" >&2; exit 1 ;; esac
card=$1
shift
room='' project='' tags='' link='' cid='' text='' title='' state='' drop=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --room) room=$2; shift 2 ;;
    --project) project=$2; shift 2 ;;
    --tag) tags="$tags${tags:+,}$2"; shift 2 ;;
    --link) link=$2; shift 2 ;;
    --cid) cid=$2; shift 2 ;;
    --title) title=$2; shift 2 ;;
    --state) state=$2; shift 2 ;;
    --drop) drop=1; shift ;;
    --landing) [ "$cmd" = progress ] || { echo "--landing on $cmd" >&2; exit 1; }; cmd=landing; shift ;;
    -*) echo "unexpected option: $1" >&2; exit 1 ;;
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
if [ "$cmd" = job ] && [ -n "$drop" ]; then
  printf 'drop id=%s room=%s project=%s tags=%s cid=%s\n' "$card" "$room" "$project" "$tags" "$cid" >> "$d/sent"
elif [ "$cmd" = job ]; then
  printf 'job id=%s room=%s project=%s tags=%s title=%s state=%s link=%s cid=%s text=%s\n' \
    "$card" "$room" "$project" "$tags" "$title" "$state" "$link" "$cid" "$text" >> "$d/sent"
else
  printf '%s card=%s room=%s project=%s tags=%s link=%s cid=%s text=%s\n' \
    "$cmd" "$card" "$room" "$project" "$tags" "$link" "$cid" "$text" >> "$d/sent"
fi
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

add_task() {  # <dir> <task-id> <repo> <body> [kind]
  in_home "$1" "$ROOT/bin/fm-tasks-axi.sh" add "$2" "Room work for $2" --kind "${5:-ship}" --repo "$3" --body "$4" >/dev/null \
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
  assert_contains "$help" "report [--detach] <task-id> <event>" "help names report"
  assert_contains "$help" "OUTCOMES IN THE ROOM" "help explains what the room hears"
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
landing card=c6 room=alpha project=studio tags=alpha link= cid=fm-room-t1-pr-$(printf '%s' "$PR_URL" | cksum | awk '{ print $1 }') text=Ready for review: $PR_URL
problem card=c6 room=alpha project=studio tags=alpha link= cid=fm-room-t1-blocked-$(printf 'blocked [at=1790000100]: the build needs a key' | cksum | awk '{ print $1 }') text=Held up by a blocker; looking into it.
result card=c6 room=alpha project=studio tags=alpha link=$PR_URL cid=fm-room-t1-merged text=Done: the change has landed.
EOF
)" "$(sent_of "$h")" "the card heard each event once, in the task's project with its allow-list tag, and none of the blocker's own words"
  [ -z "$(wakes_of "$h")" ] || fail "a told card woke the first mate: $(wakes_of "$h")"
  out=$(in_home "$h" "$ADAPTER" report room-t1 dropped 2>&1) || fail "a card's drop failed: $out"
  assert_contains "$out" "nothing to report" "a card hears nothing of a cleanup"
  assert_equals 4 "$(sent_of "$h" | grep -c .)" "the cleanup sent nothing to the card"
  pass "a task's card hears that work started, its PR as about to land, a blocker and that it landed, each once, and nothing after it landed"
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
  add_task "$h" room-q5 private-notes "Not a ref: notmothership: alpha/q5"
  for out in q1 q2 q3 q4; do
    in_home "$h" "$ADAPTER" report "room-$out" started >/dev/null 2>&1 || fail "report room-$out failed"
  done
  out=$(in_home "$h" "$ADAPTER" report room-q5 started 2>&1) || fail "report room-q5 failed: $out"
  assert_equals "nothing to report: room-q5 serves no room card and its project is shared with no room" "$out" "a ref glued to a word is no ref"
  assert_equals "$(printf 'q1\nq2\nq3\nq4')" "$(sent_of "$h" | sed -E 's/^progress card=([^ ]*) .*$/\1/')" \
    "a ref in quotes, backticks or parentheses names its card, without the closing mark or trailing dots"
  pass "a ref quoted, backticked or parenthesised in the body still tells its card"
}

test_no_card_sends_nothing() {
  local h out
  need_tools || return 0
  h=$(make_home nocard)
  add_task "$h" plain-t1 private-notes "Ordinary work with no room behind it."
  out=$(in_home "$h" "$ADAPTER" report plain-t1 started 2>&1) || fail "report failed: $out"
  assert_equals "nothing to report: plain-t1 serves no room card and its project is shared with no room" "$out" "a task with no card in an unshared project has nothing to report"
  for event in working waits blocked merged dropped; do
    printf 'blocked [at=1790000100]: stuck\n' > "$h/home/state/plain-t1.status"
    out=$(in_home "$h" "$ADAPTER" report plain-t1 "$event" 2>&1) || fail "report $event failed: $out"
    assert_contains "$out" "shared with no room" "an unshared project has nothing to report on $event"
  done
  out=$(in_home "$h" "$ADAPTER" report plain-t1 pr --pr "$PR_URL" 2>&1) || fail "report pr failed: $out"
  assert_contains "$out" "shared with no room" "an unshared project has nothing to report on its PR"
  : > "$h/home/state/plain-t1.meta"
  in_home "$h" "$ADAPTER" blocked-scan >/dev/null 2>&1 || fail "a scan failed"
  out=$(in_home "$h" "$ADAPTER" report never-filed started 2>&1) || fail "report on an unknown task failed: $out"
  assert_contains "$out" "serves no room card" "a task the backlog does not hold has nothing to report"
  in_home "$h" "$ADAPTER" report --detach plain-t1 started >/dev/null 2>&1 || fail "a detached report failed"
  sleep 0.5
  [ ! -e "$h/home/state/mothership" ] || fail "a task with no card created state: $(ls -R "$h/home/state/mothership")"
  [ -z "$(sent_of "$h")" ] || fail "a task with no card sent something: $(sent_of "$h")"
  [ -z "$(wakes_of "$h")" ] || fail "a task with no card woke the first mate: $(wakes_of "$h")"
  pass "a task that serves no room card, in a project no room is shared, sends nothing and creates no state"
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

# job_lines <dir>: what the Ships view heard, without the parts every line of
# one case shares: "<state>|<title>|<link>|<text>" per send, or "drop".
job_lines() {
  sent_of "$1" | sed -E \
    -e 's/^job id=[^ ]* room=[^ ]* project=[^ ]* tags=[^ ]* title=(.*) state=([^ ]*) link=([^ ]*) cid=[^ ]* text=(.*)$/\2|\1|\3|\4/' \
    -e 's/^drop id=.*$/drop/'
}

test_a_shared_job_shows_each_state() {
  local h out
  need_tools || return 0
  h=$(make_home job-states)
  add_task "$h" job-t1 sample "Ordinary work for a shared project."
  printf 'working [at=1780000000]: a line from before the room followed it\n' > "$h/home/state/job-t1.status"
  out=$(in_home "$h" "$ADAPTER" report job-t1 started 2>&1) || fail "report started failed: $out"
  assert_equals "told: job-t1: the alpha room heard that work on it started" "$out" "started is told"
  assert_equals "job id=job-t1 room=alpha project=sample tags= title=Room work for job-t1 state=working link= cid=fm-job-t1-started text=Work has started." \
    "$(sent_of "$h")" "the job shows under its task id, title and project, with a fixed line"
  out=$(in_home "$h" "$ADAPTER" report job-t1 working 2>&1) || fail "report working failed: $out"
  assert_contains "$out" "already told" "a line from before the room followed the task is not told"

  printf 'working [at=1790000000]: setup done\n' >> "$h/home/state/job-t1.status"
  out=$(in_home "$h" "$ADAPTER" report job-t1 working 2>&1) || fail "report working failed: $out"
  assert_contains "$out" "still working" "a line that leaves the state as it was sends nothing"
  printf 'needs-decision [at=1790000100]: which of two colours\n' >> "$h/home/state/job-t1.status"
  in_home "$h" "$ADAPTER" report job-t1 waits >/dev/null 2>&1 || fail "report waits failed"
  out=$(in_home "$h" "$ADAPTER" report job-t1 waits 2>&1) || fail "report waits again failed: $out"
  assert_contains "$out" "already told" "a decision is told once"
  out=$(in_home "$h" "$ADAPTER" report job-t1 blocked 2>&1) || fail "report blocked with no blocker failed: $out"
  assert_contains "$out" "nothing to report" "a blocked report with a newer decision line tells nothing"
  printf 'blocked [at=1790000200]: the build needs a key\n' >> "$h/home/state/job-t1.status"
  in_home "$h" "$ADAPTER" report job-t1 blocked >/dev/null 2>&1 || fail "report blocked failed"
  printf 'working [at=1790000300]: back at it\n' >> "$h/home/state/job-t1.status"
  in_home "$h" "$ADAPTER" report job-t1 working >/dev/null 2>&1 || fail "report working after the blocker failed"
  in_home "$h" "$ADAPTER" report job-t1 pr --pr "$PR_URL" >/dev/null 2>&1 || fail "report pr failed"
  in_home "$h" "$ADAPTER" report job-t1 merged --pr "$PR_URL" >/dev/null 2>&1 || fail "report merged failed"
  out=$(in_home "$h" "$ADAPTER" report job-t1 pr --pr https://github.com/acme/sample/pull/8 2>&1) || fail "a late report failed: $out"
  assert_contains "$out" "already heard that it landed" "nothing but the drop after it landed"
  out=$(in_home "$h" "$ADAPTER" report job-t1 dropped 2>&1) || fail "report dropped failed: $out"
  assert_contains "$out" "landing stays in the room" "a landed job is not taken off the view"
  assert_equals "$(cat <<EOT
working|Room work for job-t1||Work has started.
waits|Room work for job-t1||Waiting on a decision.
error|Room work for job-t1||Held up by a blocker; looking into it.
working|Room work for job-t1||Work is under way.
landing|Room work for job-t1|$PR_URL|Built and about to land.
done|Room work for job-t1|$PR_URL|Landed.
EOT
)" "$(job_lines "$h")" "the job moved through each state once, with none of the status log's own words"
  [ ! -e "$h/home/state/mothership/tasks/job-t1.json" ] || fail "a landed and cleaned-up job is still followed"
  [ -z "$(wakes_of "$h")" ] || fail "a told job woke the first mate: $(wakes_of "$h")"

  # A project the allow-list names only with tags carries them.
  add_task "$h" job-t2 studio "Work for the tagged project."
  in_home "$h" "$ADAPTER" report job-t2 started >/dev/null 2>&1 || fail "report started for the tagged project failed"
  assert_contains "$(sent_of "$h" | tail -n 1)" "job id=job-t2 room=alpha project=studio tags=alpha " "the job carries the allow-list's tag"
  pass "a job of a shared project shows on the Ships view as it starts, waits, is blocked, resumes, is about to land and lands"
}

test_a_dropped_job_leaves_the_view() {
  local h out long
  need_tools || return 0
  h=$(make_home job-drop)
  add_task "$h" job-d1 sample "Work that will be dropped."
  in_home "$h" "$ADAPTER" report job-d1 started >/dev/null 2>&1 || fail "report started failed"
  out=$(in_home "$h" "$ADAPTER" report job-d1 dropped 2>&1) || fail "report dropped failed: $out"
  assert_equals "told: job-d1: the alpha room heard that it was dropped" "$out" "the drop is told"
  assert_equals "drop id=job-d1 room=alpha project=sample tags= cid=fm-job-d1-dropped" "$(sent_of "$h" | tail -n 1)" "a dropped job is taken off the view"
  [ ! -e "$h/home/state/mothership/tasks/job-d1.json" ] || fail "a dropped job is still followed"
  out=$(in_home "$h" "$ADAPTER" report job-d1 dropped 2>&1) || fail "a second drop failed: $out"
  assert_contains "$out" "never showed in a room" "nothing follows a drop"
  assert_equals 2 "$(sent_of "$h" | grep -c .)" "the second drop sent nothing"

  long=job-with-a-very-long-task-id-that-the-room-cannot-take-whole
  add_task "$h" "$long" sample "Work with a long id."
  in_home "$h" "$ADAPTER" report "$long" started >/dev/null 2>&1 || fail "report started for a long id failed"
  out=$(sent_of "$h" | tail -n 1 | sed -E 's/^job id=([^ ]*) .*$/\1/')
  [ "${#out}" -le 48 ] || fail "a long task id became a job id the room cannot take: $out"
  assert_contains "$out" "job-with-a-very-long-task-id" "a long job id keeps the start of the task id"
  pass "a job cleaned up without landing is taken off the view once, and a long task id fits the room"
}

test_a_finished_report_settles_the_card() {
  local h out
  need_tools || return 0
  h=$(make_home finished)
  add_task "$h" room-r1 studio "Look into it for the room. mothership: alpha/r1." scout
  out=$(in_home "$h" "$ADAPTER" report room-r1 finished 2>&1) || fail "report finished failed: $out"
  assert_equals "told: room-r1: the alpha room heard that it finished with a report" "$out" "finished is told"
  out=$(in_home "$h" "$ADAPTER" report room-r1 finished 2>&1) || fail "report finished again failed: $out"
  assert_contains "$out" "already told" "a repeat is not sent again"
  out=$(in_home "$h" "$ADAPTER" report room-r1 pr --pr "$PR_URL" 2>&1) || fail "a late report failed: $out"
  assert_contains "$out" "already heard that it finished with a report" "nothing follows the finished line"
  out=$(in_home "$h" "$ADAPTER" report room-r1 dropped 2>&1) || fail "a card's drop failed: $out"
  assert_contains "$out" "nothing to report" "a card hears nothing of a cleanup"

  add_task "$h" room-r2 sample "A guide for the room. mothership: alpha/r2. The room may read it: mothership-report: https://docs.example.test/r2." scout
  add_task "$h" room-r3 sample "A draft. mothership: alpha/r3. mothership-report: /private/notes/r3.md" scout
  in_home "$h" "$ADAPTER" report room-r2 finished >/dev/null 2>&1 || fail "report finished with a pointer failed"
  in_home "$h" "$ADAPTER" report room-r3 finished >/dev/null 2>&1 || fail "report finished with a local pointer failed"
  assert_equals "$(cat <<'EOF'
result card=r1 room=alpha project=studio tags=alpha link= cid=fm-room-r1-finished text=Done: finished with a report, which the ship's owner holds.
result card=r2 room=alpha project=sample tags= link=https://docs.example.test/r2 cid=fm-room-r2-finished text=Done: finished with a report.
result card=r3 room=alpha project=sample tags= link= cid=fm-room-r3-finished text=Done: finished with a report, which the ship's owner holds.
EOF
)" "$(sent_of "$h")" "each card heard one fixed finished line, with a link only for a report the task names for the room"
  [ -z "$(wakes_of "$h")" ] || fail "a told card woke the first mate: $(wakes_of "$h")"

  add_task "$h" job-r4 sample "A report on shared work, with no card." scout
  in_home "$h" "$ADAPTER" report job-r4 started >/dev/null 2>&1 || fail "report started for a job failed"
  out=$(in_home "$h" "$ADAPTER" report job-r4 finished 2>&1) || fail "report finished for a job failed: $out"
  assert_equals "drop id=job-r4 room=alpha project=sample tags= cid=fm-job-r4-dropped" "$(sent_of "$h" | tail -n 1)" \
    "a job that finished with a report leaves the Ships view as a cleanup does"
  pass "a report-only task's card hears one fixed finished line, with a link only when the task names one for the room, and nothing after it"
}

test_a_private_project_tells_no_room() {
  local h out event
  need_tools || return 0
  h=$(make_home private)
  # Both projects are on the alpha room's allow-list; only studio stays shareable.
  printf '# Projects that never leave this machine\n  sample  \n' > "$h/home/config/private-projects"
  add_task "$h" priv-c1 sample "Taken on for the room. mothership: alpha/p1."
  add_task "$h" priv-j1 sample "Ordinary work for a private project."
  add_task "$h" open-j1 studio "Ordinary work for a shared project."
  printf 'blocked [at=1790000100]: the build needs a key\n' > "$h/home/state/priv-c1.status"
  printf 'blocked [at=1790000100]: the build needs a key\n' > "$h/home/state/priv-j1.status"
  for event in started blocked merged finished; do
    out=$(in_home "$h" "$ADAPTER" report priv-c1 "$event" 2>&1) || fail "card report $event failed: $out"
    assert_equals "nothing to report: priv-c1 is private work, which config/private-projects keeps from every room" "$out" "a private card hears nothing of $event"
    out=$(in_home "$h" "$ADAPTER" report priv-j1 "$event" 2>&1) || fail "job report $event failed: $out"
    assert_contains "$out" "is private work" "a private job shows nothing on $event"
  done
  out=$(in_home "$h" "$ADAPTER" report priv-c1 pr --pr "$PR_URL" 2>&1) || fail "card report pr failed: $out"
  assert_contains "$out" "is private work" "a private card hears nothing of its landing"
  [ -z "$(sent_of "$h")" ] || fail "a private project reached the room: $(sent_of "$h")"
  [ ! -e "$h/home/state/mothership/tasks/priv-c1.json" ] && [ ! -e "$h/home/state/mothership/tasks/priv-j1.json" ] \
    || fail "a private project left room state"
  in_home "$h" "$ADAPTER" report open-j1 started >/dev/null 2>&1 || fail "a shared job failed beside a private one"
  assert_contains "$(sent_of "$h")" "job id=open-j1 room=alpha project=studio" "a project off the private list still shows"

  # A list that is there but cannot be read lets nothing through.
  rm -f "$h/home/config/private-projects"
  mkdir "$h/home/config/private-projects"
  add_task "$h" open-j2 studio "More work for the shared project."
  out=$(in_home "$h" "$ADAPTER" report open-j2 started 2>&1) || fail "report with an unreadable list failed: $out"
  assert_contains "$out" "is private work" "an unreadable private list keeps every task from the room"
  out=$(in_home "$h" "$ADAPTER" report priv-c1 started 2>&1) || fail "card report with an unreadable list failed: $out"
  assert_contains "$out" "is private work" "an unreadable private list keeps every card from the room"
  assert_equals 1 "$(sent_of "$h" | grep -c .)" "nothing more was sent while the list could not be read"
  [ -z "$(wakes_of "$h")" ] || fail "private work woke the first mate: $(wakes_of "$h")"
  pass "a project in config/private-projects tells no room, card or job, whatever the allow-list says, and an unreadable list tells nothing"
}

test_a_resolved_line_puts_a_job_back_to_work() {
  local h out lock _
  need_tools || return 0
  h=$(make_home job-resolved)
  lock="$h/home/state/mothership/.task-job-r1.lock"
  add_task "$h" job-r1 sample "Work that gets unblocked."
  : > "$h/home/state/job-r1.meta"
  in_home "$h" "$ADAPTER" report job-r1 started >/dev/null 2>&1 || fail "report started failed"
  printf 'blocked [at=1790000100]: the build needs a key\n' >> "$h/home/state/job-r1.status"
  in_home "$h" "$ADAPTER" blocked-scan >/dev/null 2>&1 || fail "scan for the blocker failed"
  wait_for_sent "$h" 2 || fail "the blocker was not shown: $(sent_of "$h")"
  for _ in $(seq 1 50); do { [ -e "$lock" ] || [ -L "$lock" ]; } || break; sleep 0.1; done
  # The first mate's answer closes the blocker; the worker writes no working: line.
  printf 'resolved [at=1790000200]: key provided\n' >> "$h/home/state/job-r1.status"
  in_home "$h" "$ADAPTER" blocked-scan >/dev/null 2>&1 || fail "scan after the answer failed"
  wait_for_sent "$h" 3 || fail "the resolved blocker left the job held up: $(sent_of "$h")"
  for _ in $(seq 1 50); do { [ -e "$lock" ] || [ -L "$lock" ]; } || break; sleep 0.1; done
  printf 'needs-decision [at=1790000300]: which of two colours\n' >> "$h/home/state/job-r1.status"
  out=$(in_home "$h" "$ADAPTER" report job-r1 waits 2>&1) || fail "report waits failed: $out"
  printf 'resolved [key=colour] [at=1790000400]: answered: blue\n' >> "$h/home/state/job-r1.status"
  out=$(in_home "$h" "$ADAPTER" report job-r1 working 2>&1) || fail "report after the decision failed: $out"
  printf 'resolved [at=1790000500]: a phase ended\n' >> "$h/home/state/job-r1.status"
  out=$(in_home "$h" "$ADAPTER" report job-r1 working 2>&1) || fail "report for a resolved line while working failed: $out"
  assert_contains "$out" "still working" "a resolved line while the job works sends nothing"

  # Held up again after its PR is ready: once resolved, it is about to land again.
  in_home "$h" "$ADAPTER" report job-r1 pr --pr "$PR_URL" >/dev/null 2>&1 || fail "report pr failed"
  printf 'blocked [at=1790000600]: CI needs a secret\n' >> "$h/home/state/job-r1.status"
  in_home "$h" "$ADAPTER" report job-r1 blocked >/dev/null 2>&1 || fail "report blocked after the PR failed"
  printf 'resolved [at=1790000700]: secret added\n' >> "$h/home/state/job-r1.status"
  out=$(in_home "$h" "$ADAPTER" report job-r1 working 2>&1) || fail "report after the post-PR blocker failed: $out"
  printf 'working [at=1790000800]: addressing review feedback\n' >> "$h/home/state/job-r1.status"
  out=$(in_home "$h" "$ADAPTER" report job-r1 working 2>&1) || fail "report for review work failed: $out"
  assert_contains "$out" "still landing" "work on a ready PR leaves the job about to land"
  assert_equals "$(cat <<EOT
working|Room work for job-r1||Work has started.
error|Room work for job-r1||Held up by a blocker; looking into it.
working|Room work for job-r1||Work is under way.
waits|Room work for job-r1||Waiting on a decision.
working|Room work for job-r1||Work is under way.
landing|Room work for job-r1|$PR_URL|Built and about to land.
error|Room work for job-r1||Held up by a blocker; looking into it.
landing|Room work for job-r1|$PR_URL|Built and about to land.
EOT
)" "$(job_lines "$h")" "a resolved blocker or decision puts the job back to working, or to about to land once its PR is ready"
  pass "a resolved line moves a held-up or waiting job back to working, or back to landing after its PR, and sends nothing when the state stays"
}

test_a_failure_is_told_to_the_card_and_the_job() {
  local h out lock t _ line
  need_tools || return 0
  h=$(make_home failed)
  add_task "$h" room-f1 sample "Taken on for the room. mothership: alpha/f1."
  add_task "$h" job-x1 studio "Ordinary work for a shared project."
  for t in room-f1 job-x1; do
    : > "$h/home/state/$t.meta"
    in_home "$h" "$ADAPTER" report "$t" started >/dev/null 2>&1 || fail "report started for $t failed"
  done
  # A worker that stops writes a failed: line and nothing else.
  line='failed [at=1790000100]: cannot build the secret-codename target'
  printf '%s\n' "$line" > "$h/home/state/room-f1.status"
  printf '%s\n' "$line" > "$h/home/state/job-x1.status"
  out=$(in_home "$h" "$ADAPTER" report room-f1 blocked 2>&1) || fail "a blocked report beside a failure failed: $out"
  assert_contains "$out" "nothing to report" "a failure is not told as a blocker"
  in_home "$h" "$ADAPTER" blocked-scan >/dev/null 2>&1 || fail "scan for the failure failed"
  wait_for_sent "$h" 4 || fail "the failure was not told: $(sent_of "$h")"
  for t in room-f1 job-x1; do
    lock="$h/home/state/mothership/.task-$t.lock"
    for _ in $(seq 1 50); do { [ -e "$lock" ] || [ -L "$lock" ]; } || break; sleep 0.1; done
  done
  in_home "$h" "$ADAPTER" blocked-scan >/dev/null 2>&1 || fail "a second scan failed"
  sleep 0.5
  assert_equals "problem card=f1 room=alpha project=sample tags= link= cid=fm-room-f1-failed-$(printf '%s' "$line" | cksum | awk '{ print $1 }') text=Stopped on a failure; looking into it." \
    "$(sent_of "$h" | grep '^problem ')" "the card hears the failure once as a problem, with a fixed line"
  assert_equals "error|Room work for job-x1||Stopped on a failure; looking into it." \
    "$(job_lines "$h" | grep '^error|')" "the job shows the failure once as an error, with a fixed line"
  pass "a failed: line shows the job as an error and tells the card a problem, each once, with none of the worker's words"
}

test_no_link_runs_nothing() {
  local h out
  need_tools || return 0
  h=$(make_home nolink)
  rm -f "$h/rooms.json"
  add_task "$h" job-n1 sample "Work in a home with no room link."
  # shellcheck disable=SC2016 # expanded by the inner shell
  in_home "$h" bash -c '. "$1/bin/fm-mothership-report-lib.sh" && fm_mothership_report "$FM_HOME" "$FM_STATE_OVERRIDE" "$FM_CONFIG_OVERRIDE" job-n1 started' \
    _ "$ROOT" || fail "the lifecycle call failed with no link"
  in_home "$h" "$ADAPTER" report --detach job-n1 started >/dev/null 2>&1 || fail "a detached report failed with no link"
  sleep 0.5
  [ ! -e "$h/home/state/mothership" ] || fail "a home with no room link created state: $(ls -R "$h/home/state/mothership")"
  [ -z "$(sent_of "$h")" ] || fail "a home with no room link sent something: $(sent_of "$h")"
  [ -z "$(wakes_of "$h")" ] || fail "a home with no room link woke the first mate: $(wakes_of "$h")"
  pass "a home with no room link runs no report and creates no state"
}

test_a_failing_job_report_tells_the_first_mate() {
  local h out
  need_tools || return 0
  h=$(make_home job-down)
  add_task "$h" job-f1 sample "Work while the room is down."
  touch "$h/stub/down"
  if out=$(in_home "$h" "$ADAPTER" report job-f1 started 2>&1); then fail "an unreachable room counted as told"; fi
  assert_contains "$out" "failed: job-f1: the alpha room was not told that work on it started: Could not reach the room" "the failure is named"
  assert_contains "$(wakes_of "$h")" "check: mothership-report: the alpha room's Ships view for job-f1 was not told that work on it started" "the first mate is told"
  rm -f "$h/stub/down"
  out=$(in_home "$h" "$ADAPTER" report job-f1 started 2>&1) || fail "the send again failed: $out"
  assert_contains "$out" "told: job-f1" "a failed send goes through when run again"
  pass "a job send the room cannot take wakes the first mate and goes through when run again"
}

# The real lifecycle steps. Sets PROJ_DIR WT_DIR FAKEBIN for one case home.
make_lifecycle() {  # <dir> <task-id> [no-state]
  local h=$1 task=$2
  PROJ_DIR="$h/sample"
  WT_DIR="$h/wt"
  mkdir -p "$h/home/data/$task" "$h/home/user-home"
  [ "${3-}" = no-state ] || mkdir -p "$h/home/state/mothership"
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
  assert_equals "$(printf 'progress Work has started.\nproblem Held up by a blocker; looking into it.\nlanding Ready for review: %s\nresult Done: the change has landed. %s' "$PR_URL" "$PR_URL")" \
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

test_lifecycle_steps_show_a_job() {
  local h task=job-pr1 out
  need_tools || return 0
  h=$(make_home lifecycle-job)
  make_lifecycle "$h" "$task" no-state
  add_task "$h" "$task" sample "Ordinary work for a shared project."

  out=$(in_lifecycle "$h" "$ROOT/bin/fm-spawn.sh" "$task" "$PROJ_DIR" --mode direct-PR --yolo off 2>&1) \
    || fail "spawn failed: $out"
  wait_for_sent "$h" 1 || fail "dispatch did not show the job: $(sent_of "$h")"
  printf 'needs-decision [at=1790000500]: which of two colours\n' >> "$h/home/state/$task.status"
  out=$(in_lifecycle "$h" env FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 10 2>&1)
  wait_for_sent "$h" 2 || fail "the watcher did not show the wait: $(sent_of "$h") ($out)"
  printf 'done [at=1790000600]: PR %s\n' "$PR_URL" >> "$h/home/state/$task.status"
  out=$(in_lifecycle "$h" "$ROOT/bin/fm-pr-check.sh" "$task" "$PR_URL" 2>&1) || fail "PR registration failed: $out"
  wait_for_sent "$h" 3 || fail "the PR was not shown: $(sent_of "$h")"
  # shellcheck disable=SC2016 # expanded by the inner shell
  out=$(in_lifecycle "$h" bash -c '. "$1/bin/fm-merge-outcome-lib.sh" && fm_merge_outcome_report "$FM_HOME" "$FM_STATE_OVERRIDE" "$2" "$3" poll' \
    _ "$ROOT" "$task" "$PR_URL" 2>&1) || fail "the merge outcome was not recorded: $out"
  wait_for_sent "$h" 4 || fail "the merge was not shown: $(sent_of "$h")"
  sleep 0.5
  assert_equals "$(printf 'working|Room work for %s||Work has started.\nwaits|Room work for %s||Waiting on a decision.\nlanding|Room work for %s|%s|Built and about to land.\ndone|Room work for %s|%s|Landed.' \
    "$task" "$task" "$task" "$PR_URL" "$task" "$PR_URL")" "$(job_lines "$h")" \
    "dispatch, the watcher, the PR registration and the merge each moved the job on once"
  pass "the real dispatch, watcher, PR registration and merge steps show a shared job on the Ships view"
}

test_teardown_drops_an_unlanded_job() {
  local h task=job-td1 out
  need_tools || return 0
  h=$(make_home lifecycle-drop)
  make_lifecycle "$h" "$task" no-state
  add_task "$h" "$task" sample "Work that is given up."
  out=$(in_lifecycle "$h" "$ROOT/bin/fm-spawn.sh" "$task" "$PROJ_DIR" --mode direct-PR --yolo off 2>&1) \
    || fail "spawn failed: $out"
  wait_for_sent "$h" 1 || fail "dispatch did not show the job: $(sent_of "$h")"
  out=$(in_lifecycle "$h" "$ROOT/bin/fm-teardown.sh" "$task" --force 2>&1) || fail "teardown failed: $out"
  wait_for_sent "$h" 2 || fail "cleanup did not take the job off the view: $(sent_of "$h") ($out)"
  assert_equals "drop id=$task room=alpha project=sample tags= cid=fm-$task-dropped" "$(sent_of "$h" | sed -n 2p)" \
    "cleaning up work that never landed takes its job off the view"
  pass "cleaning up a job that never landed takes it off the Ships view"
}

test_teardown_tells_the_card_a_report_finished() {
  local h task=room-sc1 out
  need_tools || return 0
  h=$(make_home lifecycle-report)
  make_lifecycle "$h" "$task"
  add_task "$h" "$task" sample "Investigate for the room. mothership: alpha/c13" scout
  out=$(in_lifecycle "$h" "$ROOT/bin/fm-spawn.sh" "$task" "$PROJ_DIR" --scout 2>&1) || fail "scout spawn failed: $out"
  wait_for_sent "$h" 1 || fail "dispatch did not tell the card: $(sent_of "$h")"
  printf '# Findings\nSecret detail the room must never read.\n' > "$h/home/data/$task/report.md"
  printf 'done [at=1790000600]: report written\n' >> "$h/home/state/$task.status"
  in_lifecycle "$h" "$ROOT/bin/fm-captain-hold.sh" complete "$task" --none >/dev/null 2>&1 || fail "the report's completion gate failed"
  out=$(in_lifecycle "$h" "$ROOT/bin/fm-teardown.sh" "$task" 2>&1) || fail "scout cleanup failed: $out"
  wait_for_sent "$h" 2 || fail "cleanup did not tell the card the report finished: $(sent_of "$h") ($out)"
  sleep 0.5
  assert_equals "result card=c13 room=alpha project=sample tags= link= cid=fm-$task-finished text=Done: finished with a report, which the ship's owner holds." \
    "$(sent_of "$h" | sed -n 2p)" "cleaning up a scout with its report tells the card it finished"
  assert_equals 2 "$(sent_of "$h" | grep -c .)" "the card heard nothing else"
  if sent_of "$h" | grep -q 'Secret detail'; then fail "the report's own words reached the room"; fi

  h=$(make_home lifecycle-report-nolink)
  task=room-sc2
  rm -f "$h/rooms.json"
  make_lifecycle "$h" "$task" no-state
  add_task "$h" "$task" sample "Investigate. mothership: alpha/c14" scout
  out=$(in_lifecycle "$h" "$ROOT/bin/fm-spawn.sh" "$task" "$PROJ_DIR" --scout 2>&1) || fail "scout spawn with no link failed: $out"
  printf '# Findings\n' > "$h/home/data/$task/report.md"
  in_lifecycle "$h" "$ROOT/bin/fm-captain-hold.sh" complete "$task" --none >/dev/null 2>&1 || fail "the report's completion gate failed"
  out=$(in_lifecycle "$h" "$ROOT/bin/fm-teardown.sh" "$task" 2>&1) || fail "scout cleanup with no link failed: $out"
  sleep 0.5
  [ ! -e "$h/home/state/mothership" ] || fail "a home with no room link created state: $(ls -R "$h/home/state/mothership")"
  [ -z "$(sent_of "$h")" ] || fail "a home with no room link sent something: $(sent_of "$h")"

  h=$(make_home lifecycle-report-down)
  task=room-sc3
  make_lifecycle "$h" "$task"
  add_task "$h" "$task" sample "Investigate. mothership: alpha/c15" scout
  touch "$h/stub/down"
  out=$(in_lifecycle "$h" "$ROOT/bin/fm-spawn.sh" "$task" "$PROJ_DIR" --scout 2>&1) || fail "scout spawn with the room down failed: $out"
  printf '# Findings\n' > "$h/home/data/$task/report.md"
  in_lifecycle "$h" "$ROOT/bin/fm-captain-hold.sh" complete "$task" --none >/dev/null 2>&1 || fail "the report's completion gate failed"
  touch "$h/stub/slow"
  out=$(in_lifecycle "$h" "$ROOT/bin/fm-teardown.sh" "$task" 2>&1) || fail "scout cleanup failed because the room was down: $out"
  [ ! -e "$h/home/state/$task.meta" ] || fail "cleanup did not finish with the room down"
  for _ in $(seq 1 100); do
    wakes_of "$h" | grep -q 'not told that it finished with a report' && break
    sleep 0.1
  done
  assert_contains "$(wakes_of "$h")" "the alpha room's card for $task was not told that it finished with a report" "the failed send is reported to the first mate"
  assert_contains "$(wakes_of "$h")" "report $task finished sends it again" "the wake names how to send it again"
  pass "cleaning up a scout with its report tells the card it finished, sends nothing without a link, and finishes whatever the room does"
}

test_teardown_of_a_held_scout_leaves_the_card_open() {
  local h task=room-sc4 out
  need_tools || return 0
  h=$(make_home lifecycle-report-held)
  make_lifecycle "$h" "$task"
  add_task "$h" "$task" sample "Investigate for the room. mothership: alpha/c17" scout
  out=$(in_lifecycle "$h" "$ROOT/bin/fm-spawn.sh" "$task" "$PROJ_DIR" --scout 2>&1) || fail "scout spawn failed: $out"
  wait_for_sent "$h" 1 || fail "dispatch did not tell the card: $(sent_of "$h")"
  printf '# Findings\n' > "$h/home/data/$task/report.md"
  printf 'done [at=1790000600]: report written\n' >> "$h/home/state/$task.status"
  in_lifecycle "$h" "$ROOT/bin/fm-captain-hold.sh" hold "$task" --reason "the captain must choose the follow-up" >/dev/null 2>&1 \
    || fail "could not hold the scout's task for the captain"
  in_lifecycle "$h" "$ROOT/bin/fm-captain-hold.sh" complete "$task" --none >/dev/null 2>&1 || fail "the report's completion gate failed"
  out=$(in_lifecycle "$h" "$ROOT/bin/fm-teardown.sh" "$task" 2>&1) || fail "held scout cleanup failed: $out"
  in_lifecycle "$h" "$ROOT/bin/fm-captain-hold.sh" open "$task" >/dev/null 2>&1 || fail "cleanup closed the captain-held task: $out"
  sleep 1
  assert_equals 1 "$(sent_of "$h" | grep -c .)" "a scout still held for the captain tells its card nothing at cleanup: $(sent_of "$h")"
  out=$(in_home "$h" "$ADAPTER" report "$task" pr --pr "$PR_URL" 2>&1) || fail "a later report failed: $out"
  assert_equals "told: $task: the alpha room heard that it is about to land" "$out" "a later report still reaches the card"
  pass "cleaning up a scout whose task is held for the captain leaves its card open for later reports"
}

test_teardown_of_a_landed_ship_with_a_report_keeps_the_landing() {
  local h task=room-local2 out
  need_tools || return 0
  h=$(make_home lifecycle-local-report)
  make_lifecycle "$h" "$task"
  add_task "$h" "$task" sample "mothership: alpha/c16"
  out=$(in_lifecycle "$h" "$ROOT/bin/fm-spawn.sh" "$task" "$PROJ_DIR" --mode local-only --yolo off 2>&1) \
    || fail "spawn failed: $out"
  wait_for_sent "$h" 1 || fail "dispatch did not tell the card: $(sent_of "$h")"
  printf '# Notes\n' > "$h/home/data/$task/report.md"
  printf 'done: ready in branch\n' >> "$h/home/state/$task.status"
  printf 'landed\n' > "$WT_DIR/landed.txt"
  git -C "$WT_DIR" add landed.txt
  git -C "$WT_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'landed'
  printf 'local_done_head=%s\n' "$(git -C "$WT_DIR" rev-parse HEAD)" >> "$h/home/state/$task.meta"
  touch "$h/stub/down"
  out=$(in_lifecycle "$h" "$ROOT/bin/fm-merge-local.sh" "$task" 2>&1) || fail "local merge failed: $out"
  for _ in $(seq 1 100); do
    wakes_of "$h" | grep -q 'not told that it landed' && break
    sleep 0.1
  done
  assert_contains "$(wakes_of "$h")" "report $task merged sends it again" "the failed landing send is reported to the first mate"
  rm -f "$h/stub/down"
  out=$(in_lifecycle "$h" "$ROOT/bin/fm-teardown.sh" "$task" 2>&1) || fail "cleanup after the landing failed: $out"
  sleep 1
  assert_equals 1 "$(sent_of "$h" | grep -c .)" "cleaning up a landed ship tells its card nothing: $(sent_of "$h")"
  out=$(in_home "$h" "$ADAPTER" report "$task" merged 2>&1) || fail "sending the landing again failed: $out"
  assert_equals "told: $task: the alpha room heard that it landed" "$out" "the landing is sent again"
  assert_equals "result card=c16 room=alpha project=sample tags= link= cid=fm-$task-merged text=Done: the change has landed." \
    "$(sent_of "$h" | sed -n 2p)" "the card hears that the change landed"
  pass "cleaning up a landed ship that kept a report never tells its card a report finished, so a re-sent landing still reaches it"
}

test_lifecycle_without_a_link_or_with_a_failing_room() {
  local h task=job-nl1 out
  need_tools || return 0
  h=$(make_home lifecycle-nolink)
  rm -f "$h/rooms.json"
  make_lifecycle "$h" "$task" no-state
  add_task "$h" "$task" sample "Work in a home with no room link."
  out=$(in_lifecycle "$h" "$ROOT/bin/fm-spawn.sh" "$task" "$PROJ_DIR" --mode direct-PR --yolo off 2>&1) \
    || fail "spawn with no room link failed: $out"
  printf 'done [at=1790000600]: PR %s\n' "$PR_URL" >> "$h/home/state/$task.status"
  out=$(in_lifecycle "$h" "$ROOT/bin/fm-pr-check.sh" "$task" "$PR_URL" 2>&1) || fail "PR registration with no room link failed: $out"
  sleep 0.5
  [ ! -e "$h/home/state/mothership" ] || fail "a home with no room link created state: $(ls -R "$h/home/state/mothership")"
  [ -z "$(sent_of "$h")" ] || fail "a home with no room link sent something: $(sent_of "$h")"

  h=$(make_home lifecycle-down)
  task=job-dn1
  make_lifecycle "$h" "$task" no-state
  add_task "$h" "$task" sample "Work while the room is down."
  touch "$h/stub/down" "$h/stub/slow"
  out=$(in_lifecycle "$h" "$ROOT/bin/fm-spawn.sh" "$task" "$PROJ_DIR" --mode direct-PR --yolo off 2>&1) \
    || fail "spawn failed because the room was down: $out"
  grep -q '^kind=ship' "$h/home/state/$task.meta" 2>/dev/null || fail "the dispatch did not record its task with the room down"
  printf 'done [at=1790000600]: PR %s\n' "$PR_URL" >> "$h/home/state/$task.status"
  out=$(in_lifecycle "$h" "$ROOT/bin/fm-pr-check.sh" "$task" "$PR_URL" 2>&1) || fail "PR registration failed because the room was down: $out"
  grep -q "^pr=$PR_URL" "$h/home/state/$task.meta" || fail "the PR was not recorded with the room down"
  for _ in $(seq 1 100); do
    [ "$(wakes_of "$h" | grep -c 'mothership-report')" -ge 2 ] && break
    sleep 0.1
  done
  assert_contains "$(wakes_of "$h")" "the alpha room's Ships view for $task was not told that it is about to land" "the failed sends are reported to the first mate"
  [ -z "$(sent_of "$h")" ] || fail "a down room recorded a send: $(sent_of "$h")"
  pass "with no room link nothing runs, and a room that cannot be reached never changes or fails a step"
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
  test_a_local_landing_reports_to_the_card \
  test_a_shared_job_shows_each_state \
  test_a_dropped_job_leaves_the_view \
  test_a_finished_report_settles_the_card \
  test_a_private_project_tells_no_room \
  test_a_resolved_line_puts_a_job_back_to_work \
  test_a_failure_is_told_to_the_card_and_the_job \
  test_no_link_runs_nothing \
  test_a_failing_job_report_tells_the_first_mate \
  test_lifecycle_steps_show_a_job \
  test_teardown_drops_an_unlanded_job \
  test_teardown_tells_the_card_a_report_finished \
  test_teardown_of_a_held_scout_leaves_the_card_open \
  test_teardown_of_a_landed_ship_with_a_report_keeps_the_landing \
  test_lifecycle_without_a_link_or_with_a_failing_room
