#!/usr/bin/env bash
# Behavior tests for the opt-in twice-daily dropped-threads digest and its schedule.
#
# Contracts under test:
#   - A home with no `enabled = true` line is completely inert.
#   - The digest lists live and aged captain holds with their due dates, open
#     questions from work under way, other held items whose date has arrived,
#     and unheld in-flight tasks whose newest stamped status event is older than
#     stale_hours, most pressing first, in one spoken sentence plus a short list
#     with no links in it.
#   - Each slot publishes once, at or after its local time; a morning missed
#     while asleep is caught up later that day unless the evening time has also
#     passed; nothing is published before the morning time.
#   - When nothing is waiting the slot's record says so and nothing is spoken.
#   - It only reports: the backlog, status logs and wake queue are untouched and
#     no captain inbox note is written.
#   - A failed collection writes nothing, so the next run retries the slot.
#   - Local configuration is validated and unknown keys are refused.
#   - The schedule renders, installs and removes against a temporary home and a
#     fake launchd transport, and refuses a home that never opted in.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DIGEST="$ROOT/bin/fm-dropped-threads.sh"
SCHEDULE="$ROOT/bin/fm-dropped-threads-schedule.sh"
TMP_ROOT=$(fm_test_tmproot fm-dropped-threads-tests)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# Monday 2026-10-05 in Europe/Amsterdam (CEST, UTC+2).
T_0700=1791176400   # 07:00 local - before the 08:30 morning time
T_0845=1791182700   # 08:45 local
T_1400=1791201600   # 14:00 local
T_1945=1791222300   # 19:45 local
T_STALE=1791007200  # 2026-10-03 08:00 local - two days before T_0845

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat >"$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat >"$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat >"$FAKEBIN/speak" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_SPEAK_LOG"
SH
chmod +x "$FAKEBIN/no-mistakes" "$FAKEBIN/tmux" "$FAKEBIN/speak"

new_home() {  # <dir> [enabled]
  local h=$1
  mkdir -p "$h/config" "$h/state" "$h/data" "$h/projects/work"
  if [ "${2:-true}" = true ]; then
    printf 'enabled = true\n' >"$h/config/dropped-threads"
  fi
  printf '' >"$h/speak.log"
}

write_fixture() {  # <home>
  local h=$1 gen
  cat >"$h/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] quiet-task - Rebuild the bridge page (repo: alpha) (kind: ship) (since 2026-10-01)
- [ ] asking-task - Pick the sign-in provider (repo: alpha) (kind: ship) (since 2026-10-04)
- [ ] busy-task - Fresh work that reported an hour ago (repo: alpha) (kind: ship) (since 2026-10-04)
## Queued
- [ ] due-hold - Approve the eval spend https://example.com/secret-page (repo: alpha) (kind: captain) (since 2026-09-20) (hold: approve the spend) (hold-kind: captain) (hold-until: 2026-09-28)
  Captain hold set: 2026-10-01T09:00:00Z
- [ ] live-hold - Choose the memory policy (repo: alpha) (kind: captain) (since 2026-10-02) (hold: choose a policy) (hold-kind: captain)
  Captain hold set: 2026-10-02T09:00:00Z
- [ ] aged-hold - Decide the old licence question (repo: alpha) (kind: captain) (since 2026-08-01) (hold: licence) (hold-kind: captain)
- [ ] later-hold - Rotate keys before launch (repo: alpha) (kind: captain) (since 2026-09-26) (hold: rotate later) (hold-kind: captain) (hold-until: 2026-10-26)
  Captain hold set: 2026-09-26T09:00:00Z
- [ ] arrived-gate - Weekly fleet scorecard (repo: alpha) (kind: scout) (since 2026-09-26) (hold: weekly) (hold-kind: future) (hold-until: 2026-10-03)
- [ ] future-gate - Monthly backlog sweep (repo: alpha) (kind: scout) (since 2026-10-01) (hold: monthly) (hold-kind: future) (hold-until: 2026-11-02)
- [ ] plain-queued - Ordinary queued work (repo: alpha) (kind: ship) (since 2026-10-01)

## Done
- [x] done-task - Finished work (repo: alpha) (kind: ship) (merged 2026-10-01)
EOF
  local id
  for id in quiet-task asking-task busy-task; do
    fm_write_meta "$h/state/$id.meta" \
      "window=firstmate:fm-$id" \
      "worktree=$h/projects/work" \
      "project=alpha" \
      "harness=claude" \
      "kind=ship" \
      "mode=no-mistakes" \
      "yolo=off"
  done
  printf 'working [at=%s]: setup done\n' "$T_STALE" >"$h/state/quiet-task.status"
  printf 'needs-decision [at=%s] [key=provider]: Apple or Google first? See https://example.com/x\n' \
    "$((T_0845 - 600))" >"$h/state/asking-task.status"
  # The worker stopped its turn after asking, through its own busy-state record,
  # so the snapshot keeps the open question rather than clearing it as resumed.
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$h/state" asking-task)
  "$ROOT/bin/fm-busy-event.sh" apply "$h/state" asking-task idle --gen "$gen" \
    --source claude-hook --event stop
  printf 'working [at=%s]: setup done\n' "$((T_0845 - 3600))" >"$h/state/busy-task.status"
}

digest() {  # <home> <now> <args...>
  local h=$1 now=$2
  shift 2
  PATH="$FAKEBIN:$PATH" TZ=Europe/Amsterdam FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" \
    FM_DROPPED_THREADS_NOW="$now" FM_DROPPED_THREADS_SPEAK="$FAKEBIN/speak" \
    FAKE_SPEAK_LOG="$h/speak.log" "$DIGEST" "$@"
}

spoken_count() {
  local n
  n=$(grep -c '[^[:space:]]' "$1/speak.log" 2>/dev/null) || true
  printf '%s\n' "${n:-0}"
}

test_inert_without_opt_in() {
  local h out code
  h="$TMP_ROOT/no-optin"
  new_home "$h" false
  write_fixture "$h"
  out=$(digest "$h" "$T_0845" run) && code=0 || code=$?
  expect_code 0 "$code" 'run on a home with no config'
  [ -z "$out" ] || fail "un-enrolled home produced output: $out"
  assert_absent "$h/data/dropped-threads" 'un-enrolled home wrote a digest'
  [ "$(spoken_count "$h")" = 0 ] || fail 'un-enrolled home spoke'

  printf 'enabled = false\n' >"$h/config/dropped-threads"
  out=$(digest "$h" "$T_0845" run) && code=0 || code=$?
  expect_code 0 "$code" 'run on a home with enabled = false'
  assert_absent "$h/data/dropped-threads" 'a home with enabled = false wrote a digest'
  pass 'a home that never opted in stays inert'
}

test_preview_lists_the_dropped_threads() {
  local h out
  h="$TMP_ROOT/preview"
  new_home "$h" false
  write_fixture "$h"
  out=$(digest "$h" "$T_0845" preview) || fail 'preview failed'
  printf '%s' "$out" | jq -e '
    .schema == "fm-dropped-threads.v1"
    and .slot == "morning" and .local_date == "2026-10-05"
    and .at == "2026-10-05T06:45:00Z"
    and .counts == {decisions:3,questions:1,time_gates:1,quiet_tasks:1,total:6}
    and ([.items[].id] == ["asking-task","due-hold","arrived-gate","quiet-task","live-hold","aged-hold"])
    and ([.items[].kind] == ["question","decision","time-gate","quiet-task","decision","decision"])
    and (.items[1].due == "2026-09-28") and (.items[1].text | test("due 28 Sep"))
    and (.items[2].due == "2026-10-03") and (.items[3].text | test("no news for 2 days"))
    and (.items[4].due == null)
    and ([.items[].text | test("https?://")] | any | not)
    and .more == 0
    and .spoken == "Six things are waiting on you: three decisions held for you, one question from work under way, one set-aside item whose date has come, and one task with no news for a day."
  ' >/dev/null || fail "preview did not compose the expected record: $out"
  assert_absent "$h/data/dropped-threads" 'preview wrote a record'
  [ "$(spoken_count "$h")" = 0 ] || fail 'preview spoke'

  printf 'enabled = false\nmax_items = 2\nstale_hours = 72\n' >"$h/config/dropped-threads"
  out=$(digest "$h" "$T_0845" preview --slot evening) || fail 'bounded preview failed'
  printf '%s' "$out" | jq -e '
    .slot == "evening" and (.items | length) == 2 and .more == 3
    and .counts.quiet_tasks == 0 and .counts.total == 5
  ' >/dev/null || fail "max_items and stale_hours were not honoured: $out"
  pass 'the digest lists decisions, questions, arrived dates and quiet tasks, most pressing first'
}

test_held_work_is_not_a_quiet_task() {
  local h out id
  h="$TMP_ROOT/held-in-flight"
  new_home "$h" false
  cat >"$h/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] dated-work - Paused until next month (repo: alpha) (kind: ship) (since 2026-10-01) (hold: wait for launch) (hold-kind: captain) (hold-until: 2026-11-02)
  Captain hold set: 2026-10-01T09:00:00Z
- [ ] blocked-work - Waiting on a blocker blocked-by: blocker-task (repo: alpha) (kind: ship) (since 2026-10-01) (hold: needs the blocker) (hold-kind: captain)
  Captain hold set: 2026-10-01T09:00:00Z
- [ ] blocker-task - The blocker (repo: alpha) (kind: ship) (since 2026-10-01)
## Queued
## Done
EOF
  for id in dated-work blocked-work blocker-task; do
    fm_write_meta "$h/state/$id.meta" \
      "window=firstmate:fm-$id" \
      "worktree=$h/projects/work" \
      "project=alpha" \
      "harness=claude" \
      "kind=ship" \
      "mode=no-mistakes" \
      "yolo=off"
    printf 'working [at=%s]: setup done\n' "$T_STALE" >"$h/state/$id.status"
  done
  out=$(digest "$h" "$T_0845" preview) || fail 'preview failed'
  printf '%s' "$out" | jq -e '
    .counts.quiet_tasks == 1 and .counts.total == 1
    and ([.items[].id] == ["blocker-task"])
  ' >/dev/null || fail "a captain-held in-flight task was reported as quiet: $out"
  pass 'in-flight work the captain set aside or blocked is not reported as quiet'
}

test_each_slot_publishes_once() {
  local h out
  h="$TMP_ROOT/slots"
  new_home "$h"
  write_fixture "$h"

  out=$(digest "$h" "$T_0700" run) || fail 'early run failed'
  [ -z "$out" ] || fail "a run before the morning time published: $out"
  assert_absent "$h/data/dropped-threads/latest.json" 'a run before the morning time wrote a record'

  out=$(digest "$h" "$T_0845" run) || fail 'morning run failed'
  assert_contains "$out" 'published 2026-10-05 morning' 'the morning run did not publish'
  [ -f "$h/data/dropped-threads/digests/2026-10-05-morning.json" ] || fail 'no morning record'
  cmp -s "$h/data/dropped-threads/latest.json" "$h/data/dropped-threads/digests/2026-10-05-morning.json" \
    || fail 'latest is not the morning record'
  [ "$(spoken_count "$h")" = 1 ] || fail 'the morning digest was not spoken exactly once'
  assert_contains "$(cat "$h/speak.log")" 'Six things are waiting on you' 'the spoken line is not the digest sentence'

  out=$(digest "$h" "$T_0845" run) || fail 'repeat morning run failed'
  [ -z "$out" ] || fail "a repeat run published again: $out"
  out=$(digest "$h" "$T_1400" run) || fail 'midday run failed'
  [ -z "$out" ] || fail "a midday run published again: $out"
  [ "$(spoken_count "$h")" = 1 ] || fail 'a repeat run spoke again'

  out=$(digest "$h" "$T_1945" run) || fail 'evening run failed'
  assert_contains "$out" 'published 2026-10-05 evening' 'the evening run did not publish'
  [ "$(jq -r .slot "$h/data/dropped-threads/latest.json")" = evening ] || fail 'latest is not the evening record'
  [ "$(spoken_count "$h")" = 2 ] || fail 'the evening digest was not spoken'

  out=$(digest "$h" "$T_1945" latest)
  assert_contains "$out" '2026-10-05 evening: Six things are waiting on you' 'latest did not print the sentence'
  assert_contains "$out" '- Approve the eval spend (due 28 Sep)' 'latest did not print the list'
  digest "$h" "$T_1945" latest --json | jq -e '.slot == "evening"' >/dev/null \
    || fail 'latest --json did not print the record'
  pass 'each slot publishes once at or after its time and is spoken once'
}

test_missed_morning_catch_up() {
  local h out
  h="$TMP_ROOT/catch-up"
  new_home "$h"
  write_fixture "$h"
  out=$(digest "$h" "$T_1400" run) || fail 'late morning run failed'
  assert_contains "$out" 'published 2026-10-05 morning' 'a late wake did not catch up the morning'

  h="$TMP_ROOT/evening-only"
  new_home "$h"
  write_fixture "$h"
  out=$(digest "$h" "$T_1945" run) || fail 'evening-only run failed'
  assert_contains "$out" 'published 2026-10-05 evening' 'the evening run did not publish'
  assert_absent "$h/data/dropped-threads/digests/2026-10-05-morning.json" \
    'a morning already overtaken by the evening was published'
  pass 'a missed morning is caught up unless the evening has already come'
}

test_silent_when_nothing_waits() {
  local h out
  h="$TMP_ROOT/quiet"
  new_home "$h"
  printf '# Backlog\n\n## In flight\n## Queued\n## Done\n' >"$h/data/backlog.md"
  out=$(digest "$h" "$T_0845" latest --json)
  [ "$out" = null ] || fail "latest before any digest was not null: $out"
  out=$(digest "$h" "$T_0845" run) || fail 'empty run failed'
  assert_contains "$out" 'nothing waiting' 'the empty run did not say nothing was waiting'
  jq -e '.spoken == null and .items == [] and .counts.total == 0 and .more == 0' \
    "$h/data/dropped-threads/latest.json" >/dev/null || fail 'the empty record is not empty'
  [ "$(spoken_count "$h")" = 0 ] || fail 'an empty digest was spoken'
  assert_contains "$(digest "$h" "$T_0845" latest)" 'nothing waiting' 'latest did not say nothing was waiting'
  pass 'nothing waiting is recorded and never spoken'
}

test_it_only_reports() {
  local h before_backlog before_status
  h="$TMP_ROOT/read-only"
  new_home "$h"
  write_fixture "$h"
  before_backlog=$(cksum <"$h/data/backlog.md")
  before_status=$(cat "$h"/state/*.status | cksum)
  digest "$h" "$T_0845" run >/dev/null || fail 'run failed'
  [ "$(cksum <"$h/data/backlog.md")" = "$before_backlog" ] || fail 'the digest changed the backlog'
  [ "$(cat "$h"/state/*.status | cksum)" = "$before_status" ] || fail 'the digest changed a status log'
  assert_absent "$h/state/.wake-queue" 'the digest woke firstmate'
  assert_absent "$h/state/inbox" 'the digest wrote a captain inbox note'
  pass 'the digest only reports'
}

test_failed_collection_writes_nothing() {
  local h out code
  h="$TMP_ROOT/failure"
  new_home "$h"
  write_fixture "$h"
  out=$(FM_SNAPSHOT_SECONDMATE_CHILDREN=not-a-number digest "$h" "$T_0845" run 2>&1) && code=0 || code=$?
  expect_code 1 "$code" 'a failed collection'
  assert_contains "$out" 'the next run tries again' 'the failure did not say it will retry'
  assert_absent "$h/data/dropped-threads/latest.json" 'a failed collection wrote a record'
  [ "$(spoken_count "$h")" = 0 ] || fail 'a failed collection spoke'
  out=$(digest "$h" "$T_0845" run) || fail 'the retry failed'
  assert_contains "$out" 'published 2026-10-05 morning' 'the retry did not publish the slot'
  pass 'a failed collection writes nothing and the next run retries the slot'
}

test_old_records_are_pruned() {
  local h day
  h="$TMP_ROOT/prune"
  new_home "$h"
  printf '# Backlog\n\n## In flight\n## Queued\n## Done\n' >"$h/data/backlog.md"
  mkdir -p "$h/data/dropped-threads/digests"
  for day in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    printf '{}\n' >"$h/data/dropped-threads/digests/2026-09-$day-morning.json"
    printf '{}\n' >"$h/data/dropped-threads/digests/2026-09-$day-evening.json"
  done
  digest "$h" "$T_0845" run >/dev/null || fail 'run failed'
  assert_absent "$h/data/dropped-threads/digests/2026-09-01-morning.json" 'the oldest date was kept'
  assert_absent "$h/data/dropped-threads/digests/2026-09-01-evening.json" 'the oldest date was kept'
  [ -f "$h/data/dropped-threads/digests/2026-09-02-morning.json" ] || fail 'a date inside the window was pruned'
  [ -f "$h/data/dropped-threads/digests/2026-09-02-evening.json" ] || fail 'a date inside the window was pruned'
  [ -f "$h/data/dropped-threads/digests/2026-10-05-morning.json" ] || fail 'the new record was pruned'
  pass 'records of the newest thirty local dates are kept'
}

test_configuration_is_validated() {
  local h out code
  h="$TMP_ROOT/config"
  new_home "$h"
  printf 'enabled = true\nchannel = secret\n' >"$h/config/dropped-threads"
  out=$(digest "$h" "$T_0845" status 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'an unknown config key'
  assert_contains "$out" 'unknown config key: channel' 'the unknown key was not named'
  printf 'enabled = true\nmorning = 20:00\nevening = 19:30\n' >"$h/config/dropped-threads"
  out=$(digest "$h" "$T_0845" status 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'an evening before the morning'
  printf 'enabled = true\nmorning = 8:30\n' >"$h/config/dropped-threads"
  out=$(digest "$h" "$T_0845" status 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'a malformed time'
  printf 'enabled = true\nmorning = 07:15\nevening = 21:00\ninterval_seconds = 300\n' >"$h/config/dropped-threads"
  out=$(digest "$h" "$T_0845" status) || fail 'status failed'
  assert_contains "$out" 'morning: 07:15' 'status did not print the morning time'
  assert_contains "$out" 'evening: 21:00' 'status did not print the evening time'
  [ "$(digest "$h" "$T_0845" interval)" = 300 ] || fail 'interval did not read the configured cadence'
  pass 'configuration is validated and unknown keys are refused'
}

test_schedule_on_a_temp_home() {
  local h out code agents fakebin
  h="$TMP_ROOT/schedule"
  new_home "$h" false
  agents="$TMP_ROOT/LaunchAgents"
  mkdir -p "$agents"
  fakebin="$TMP_ROOT/launchd-fakebin"
  mkdir -p "$fakebin"
  cat >"$fakebin/launchctl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LAUNCHCTL_LOG"
FAKE
  chmod +x "$fakebin/launchctl"

  schedule() {
    FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" \
    FM_DROPPED_THREADS_LAUNCH_AGENTS_DIR="$agents" \
    FM_DROPPED_THREADS_LAUNCHCTL="$fakebin/launchctl" \
    FAKE_LAUNCHCTL_LOG="$TMP_ROOT/launchctl.log" \
      "$SCHEDULE" "$@"
  }

  out=$(schedule render)
  assert_contains "$out" '<integer>900</integer>' 'the default cadence is not the 900s poll'
  assert_contains "$out" '<key>RunAtLoad</key>' 'the schedule does not run at load'
  assert_contains "$out" '<string>run</string>' 'the schedule does not call run'
  assert_contains "$out" 'fm-dropped-threads.sh' 'the schedule does not call the digest owner'
  assert_contains "$out" 'dev.firstmate.dropped-threads.' 'the label is not the per-home digest label'

  # install requires macOS launchd, so off Darwin it refuses before the opt-in
  # check and only render is exercised.
  if [ "$(uname)" = Darwin ]; then
    out=$(schedule install 2>&1) && code=0 || code=$?
    expect_code 2 "$code" 'install on a home that never opted in'
    assert_contains "$out" 'not opted in' 'the refusal did not say why'
    [ -z "$(ls -A "$agents")" ] || fail 'a refused install wrote a LaunchAgent'

    printf 'enabled = true\ninterval_seconds = 600\n' >"$h/config/dropped-threads"
    out=$(schedule install) || fail 'install failed'
    assert_contains "$out" 'interval_seconds: 600' 'install did not use the configured cadence'
    ls "$agents"/dev.firstmate.dropped-threads.*.plist >/dev/null 2>&1 || fail 'install wrote no LaunchAgent'
    assert_contains "$(cat "$TMP_ROOT/launchctl.log")" 'bootstrap' 'install did not load the agent'
    schedule remove >/dev/null || fail 'remove failed'
    [ -z "$(ls -A "$agents")" ] || fail 'remove left the LaunchAgent behind'
  fi
  pass 'the schedule renders, refuses an un-enrolled home, and installs against a temp home'
}

test_inert_without_opt_in
test_preview_lists_the_dropped_threads
test_held_work_is_not_a_quiet_task
test_each_slot_publishes_once
test_missed_morning_catch_up
test_silent_when_nothing_waits
test_it_only_reports
test_failed_collection_writes_nothing
test_old_records_are_pruned
test_configuration_is_validated
test_schedule_on_a_temp_home
