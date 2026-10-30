#!/usr/bin/env bash
# Behavior tests for the opt-in morning intake gate and its schedule.
#
# Contracts under test:
#   - A home with no `enabled = true` line is completely inert, so cloning the
#     repo or seeding another home never enrolls a device.
#   - The intake arms once per configured local day, at or after the threshold;
#     repeat scheduled polls neither re-arm nor enqueue a second wake.
#   - A morning missed while asleep or offline is caught up by the first run
#     after the threshold, on the real local date, with no simulated sleep.
#   - The wake actually drives an intake to a completed, acknowledged report:
#     arm -> registered watcher check -> claim -> report -> complete -> pending
#     -> acknowledge, through the same commands a live orchestrator runs.
#   - A failed or partial intake cannot advance the completion watermark, and a
#     corrected source message after a same-day failure is still ingested.
#   - The day's Lavish page is part of completion, not an extra: `complete`
#     refuses without a real, non-empty page under the home's own .lavish/
#     directory, and a day that genuinely cannot have one completes only with a
#     reason recorded in the day's durable record.
#   - Retries are bounded and the exhausted state stays visible, including for a
#     failure recorded before any claim, and only `reset` gives the budget back.
#   - Writes to the durable record are serialized, so a watcher sweep cannot
#     overwrite a claim that a live orchestrator is holding.
#   - Arming the watcher check is all-or-nothing: a registration failure leaves
#     no shim behind for the watcher to reject on every sweep.
#   - Losing that shim is detectable: while an intake is armed or owed, the
#     read-only session-start surface reports an absent or unregistered live
#     check and names `arm-check`, and re-arming is idempotent and rebinds a
#     shim whose bytes drifted.
#   - `run --force` arms outside the configured window but never overrides the
#     bounded retry budget; only `reset` gives that budget back.
#   - A timezone that does not resolve is refused instead of silently becoming
#     UTC, and `rearm` on a new local day starts from a fresh budget.
#   - No existing fleet is overridden: no session lock is taken, no watcher is
#     started, and a foreign home's records are untouched.
#   - Local configuration stays private: unknown keys are refused rather than
#     parked, and status prints only declared knobs.
#   - Install and uninstall work against a temporary home and a fake launchd
#     transport, and refuse a home that never opted in.
#   - The session-start bootstrap hook is guarded: run from an add-on that
#     carries the hook but not bin/fm-morning-intake.sh, bootstrap still exits 0
#     and its output is exactly what the built-in hook prints minus the intake
#     lines, so a missing gate script never breaks session start, and the
#     add-on's same-named hook replaces the built-in one.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INTAKE="$ROOT/bin/fm-morning-intake.sh"
SCHEDULE="$ROOT/bin/fm-morning-intake-schedule.sh"
TMP_ROOT=$(fm_test_tmproot fm-morning-intake-tests)

# 2026-09-10 in Europe/Amsterdam (CEST, UTC+2).
T_0530=1789011000   # 05:30 local - before the 06:00 threshold
T_0700=1789016400   # 07:00 local
T_0715=1789017300
T_1100=1789031400   # 11:00 local - a laptop that woke late
T_NEXT_0700=1789102800  # 2026-09-11 07:00 local

new_home() {
  local h=$1
  mkdir -p "$h/config" "$h/state" "$h/reports"
  cat >"$h/config/morning-intake" <<EOF
enabled = true
timezone = Europe/Amsterdam
start_time = 06:00
report_dir = $h/reports
max_attempts = 2
retry_after_seconds = 1800
EOF
}

# The day's Lavish page, which `complete` now proves alongside the report.
# Written as a real file under the home's own .lavish/ so the gate's check is
# exercised rather than stubbed out.
new_page() {
  local h=$1 day=${2:-2026-09-10}
  mkdir -p "$h/.lavish"
  printf '<!doctype html><title>Today</title><p>page</p>\n' \
    >"$h/.lavish/today-$day.html"
  printf '%s\n' "$h/.lavish/today-$day.html"
}

# Every invocation pins the clock instead of sleeping or suspending anything.
at() {
  local h=$1 now=$2
  shift 2
  FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" FM_MORNING_INTAKE_NOW="$now" "$INTAKE" "$@"
}

queue_lines() {
  grep -c '[^[:space:]]' "$1/state/.wake-queue" 2>/dev/null || printf '0\n'
}

state_field() {
  awk -F= -v k="$2" '$1 == k { print $2 }' "$1/data/morning-intake/state"
}

# Portable permission bits. Platform-detected, never the `stat -f || stat -c`
# fallback: GNU stat's -f succeeds with a filesystem dump, so the GNU branch
# would never run on Linux (see fm-watch-triage.test.sh).
file_mode() {
  if [ "$(uname)" = Darwin ]; then stat -f %Lp "$1" 2>/dev/null; else stat -c %a "$1" 2>/dev/null; fi
}

# A live process holding the gate's own state mutex, so contention is real
# rather than simulated. Nothing is slept for: every command under contention is
# given a one-second bound through FM_MORNING_INTAKE_LOCK_WAIT and returns
# inside it. HOLDER_PID is killed by release_state_lock.
HOLDER_PID=
hold_state_lock() {
  local h=$1 lock
  lock="$h/data/morning-intake/state.lock"
  mkdir -p "$lock"
  sleep 10 &
  HOLDER_PID=$!
  # Detached so terminating it later is not reported as a job status line.
  disown "$HOLDER_PID" 2>/dev/null || true
  printf '%s\n' "$HOLDER_PID" >"$lock/pid"
  ( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$HOLDER_PID" >"$lock/pid-identity" 2>/dev/null ) || true
}

release_state_lock() {
  local h=$1
  [ -z "$HOLDER_PID" ] || kill "$HOLDER_PID" 2>/dev/null || true
  HOLDER_PID=
  rm -rf "$h/data/morning-intake/state.lock"
}

test_inert_without_opt_in() {
  local h out code
  h="$TMP_ROOT/no-optin"
  mkdir -p "$h/config" "$h/state"

  # No config file at all: the scheduled entry point must do nothing.
  out=$(at "$h" "$T_0700" run) && code=0 || code=$?
  expect_code 0 "$code" 'run on a home with no config'
  [ -z "$out" ] || fail "un-enrolled home produced output: $out"
  assert_absent "$h/data/morning-intake/state" 'un-enrolled home wrote durable state'
  assert_absent "$h/state/.wake-queue" 'un-enrolled home enqueued a wake'

  # Present but disabled is equally inert, and pending stays silent too.
  printf 'enabled = false\n' >"$h/config/morning-intake"
  out=$(at "$h" "$T_0700" run)
  [ -z "$out" ] || fail "disabled home produced output: $out"
  out=$(at "$h" "$T_0700" pending)
  [ -z "$out" ] || fail "disabled home surfaced a bootstrap line: $out"

  pass 'a home without an explicit opt-in is completely inert, so no clone or device self-enrolls'
}

test_daily_gate_and_no_duplicate_wake() {
  local h out code
  h="$TMP_ROOT/gate"
  new_home "$h"

  out=$(at "$h" "$T_0530" run)
  [ -z "$out" ] || fail "armed before the configured threshold: $out"
  [ "$(queue_lines "$h")" = 0 ] || fail 'a pre-threshold poll enqueued a wake'

  out=$(at "$h" "$T_0700" run)
  assert_contains "$out" 'MORNING_INTAKE: morning-intake due for 2026-09-10' \
    'the first poll past the threshold did not arm the local day'
  [ "$(queue_lines "$h")" = 1 ] || fail 'arming did not enqueue exactly one wake'

  # The scheduled job keeps firing every interval all morning. That must not
  # re-arm the day or enqueue a second wake.
  out=$(at "$h" "$T_0715" run)
  [ -z "$out" ] || fail "a repeat poll re-armed an already-armed day: $out"
  out=$(at "$h" "$T_1100" run)
  [ -z "$out" ] || fail "a later repeat poll re-armed an already-armed day: $out"
  [ "$(queue_lines "$h")" = 1 ] || fail 'repeat polls enqueued duplicate wakes'

  out=$(at "$h" "$T_0700" run --force)
  assert_contains "$out" 'manual --force arm' 'the retained manual command did not force an arm'

  pass 'the intake arms once per local day past the threshold, and repeat wakes never duplicate it'
}

test_missed_morning_catches_up() {
  local h out
  h="$TMP_ROOT/catchup"
  new_home "$h"

  # The machine was asleep or offline through 06:00 and the job never ran. The
  # first run after it wakes must arm the SAME local day, not wait for tomorrow.
  out=$(at "$h" "$T_1100" run)
  assert_contains "$out" 'due for 2026-09-10' 'a morning missed while asleep was not caught up'
  assert_contains "$out" 'first arm of the local day' 'the catch-up arm was misreported'

  pass 'a morning missed while the laptop was asleep or offline is caught up on the first later run'
}

# The end-to-end path: the wake leads to a real report that is completed and
# acknowledged, driven through the same commands an orchestrator would run.
test_wake_drives_intake_to_acknowledged_report() {
  local h out report armed
  h="$TMP_ROOT/e2e"
  new_home "$h"
  report="$h/reports/2026-09-10.md"

  at "$h" "$T_0700" run >/dev/null

  # The live-session delivery path is a registered watcher check, so the running
  # watcher can execute it and wake the primary.
  at "$h" "$T_0700" arm-check >/dev/null
  assert_present "$h/state/morning-intake.check.sh" 'arm-check did not write the watcher shim'
  assert_present "$h/state/morning-intake.check-trust" 'arm-check did not bind the shim bytes'
  [ "$(file_mode "$h/state/morning-intake.check.sh")" = 700 ] \
    || fail 'the watcher shim is not a private mode-0700 file'
  armed=$(at "$h" "$T_0700" status | awk '$1 == "check_armed:" { print $2 }')
  [ "$armed" = armed ] || fail "check state after arming is '$armed', not armed"

  # Executing the shim the way the watcher does: one line means wake.
  out=$(FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" FM_MORNING_INTAKE_NOW="$T_0715" \
    "$h/state/morning-intake.check.sh")
  assert_contains "$out" 'morning-intake due for 2026-09-10' \
    'the registered check did not signal the live primary'
  [ "$(printf '%s\n' "$out" | grep -c '[^[:space:]]')" = 1 ] \
    || fail 'the watcher check printed more than the single wake line'

  # Still owed, but already surfaced: silence, so one owed intake wakes once.
  out=$(FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" FM_MORNING_INTAKE_NOW="$T_0715" \
    "$h/state/morning-intake.check.sh")
  [ -z "$out" ] || fail "the check re-woke the primary for an already-surfaced intake: $out"

  out=$(at "$h" "$T_0715" claim)
  assert_contains "$out" 'local_date: 2026-09-10' 'claim did not name the day to ingest'
  assert_contains "$out" 'attempt: 1 of 2' 'claim did not report the bounded attempt'

  printf '# intake 2026-09-10\nfindings\n' >"$report"
  out=$(at "$h" "$T_0715" complete --report "$report" --lavish "$(new_page "$h")" \
    --source-watermark 1789023821.730139)
  assert_contains "$out" 'complete for 2026-09-10' 'complete did not confirm the finished intake'
  [ "$(cat "$h/data/morning-intake/last-complete")" = 2026-09-10 ] \
    || fail 'a verified report did not advance the completion watermark'
  [ "$(cat "$h/data/morning-intake/source-watermark")" = 1789023821.730139 ] \
    || fail 'complete did not record the source watermark'

  out=$(at "$h" "$T_0715" pending)
  [ "$out" = "MORNING_INTAKE: new morning-intake report at $report" ] \
    || fail "the bootstrap surface did not offer the finished report: $out"

  at "$h" "$T_0715" acknowledge "$report"
  out=$(at "$h" "$T_0715" pending)
  [ -z "$out" ] || fail "an acknowledged report still surfaced: $out"
  assert_present "$report" 'acknowledgement deleted the durable report'

  # A completed day is closed to the scheduler until the next local day.
  out=$(at "$h" "$T_1100" run)
  [ -z "$out" ] || fail "a completed day re-armed on a later poll: $out"
  out=$(at "$h" "$T_NEXT_0700" run)
  assert_contains "$out" 'due for 2026-09-11' 'the next local day did not arm'

  pass 'a wake drives the intake through claim, report, completion and acknowledgement'
}

test_failure_cannot_advance_watermark_and_correction_still_lands() {
  local h out code report
  h="$TMP_ROOT/failure"
  new_home "$h"
  report="$h/reports/2026-09-10.md"

  at "$h" "$T_0700" run >/dev/null
  at "$h" "$T_0700" claim >/dev/null

  # A partial intake that names a report it never wrote must be refused.
  out=$(at "$h" "$T_0700" complete --report "$h/reports/missing.md" 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'complete accepted a report that does not exist'
  assert_contains "$out" 'report is not a regular file' 'the refusal did not name the missing report'
  assert_absent "$h/data/morning-intake/last-complete" \
    'a refused completion advanced the watermark'

  # An empty report is equally not a completed intake.
  : >"$report"
  out=$(at "$h" "$T_0700" complete --report "$report" 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'complete accepted an empty report'
  assert_absent "$h/data/morning-intake/last-complete" \
    'an empty report advanced the watermark'

  # A report written outside the configured directory is refused too.
  printf 'body\n' >"$TMP_ROOT/outside.md"
  out=$(at "$h" "$T_0700" complete --report "$TMP_ROOT/outside.md" 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'complete accepted a report outside report_dir'
  assert_absent "$h/data/morning-intake/last-complete" \
    'an out-of-tree report advanced the watermark'

  # An explicit failure is visible and still does not close the day.
  out=$(at "$h" "$T_0700" fail --reason 'source read timed out')
  assert_contains "$out" 'failed for 2026-09-10' 'the failure was not reported'
  assert_contains "$out" 'source read timed out' 'the failure reason was dropped'
  assert_absent "$h/data/morning-intake/last-complete" 'a failure advanced the watermark'
  out=$(at "$h" "$T_0715" pending)
  assert_contains "$out" 'failed for 2026-09-10' 'the failure state is not visible at session start'

  # The source then publishes a correction on the SAME date. Having already seen
  # a failure notice for today must not discard it: the next run re-arms.
  out=$(at "$h" "$T_1100" run)
  assert_contains "$out" 'due for 2026-09-10' \
    'a same-date failure notice suppressed the corrected intake'
  assert_contains "$out" 'source read timed out' 'the retry did not carry the prior failure reason'
  at "$h" "$T_1100" claim >/dev/null
  printf '# corrected intake\ncorrected findings\n' >"$report"
  out=$(at "$h" "$T_1100" complete --report "$report" --lavish "$(new_page "$h")")
  assert_contains "$out" 'complete for 2026-09-10' 'the corrected intake could not complete'
  [ "$(cat "$h/data/morning-intake/last-complete")" = 2026-09-10 ] \
    || fail 'the corrected intake did not advance the watermark'

  pass 'failed and partial intakes never advance the watermark, and a same-date correction still lands'
}

test_retries_are_bounded_and_exhaustion_is_visible() {
  local h out
  h="$TMP_ROOT/bounded"
  new_home "$h"   # max_attempts = 2

  at "$h" "$T_0700" run >/dev/null
  at "$h" "$T_0700" claim >/dev/null
  at "$h" "$T_0700" fail --reason 'attempt one failed' >/dev/null
  at "$h" "$T_0715" run >/dev/null
  at "$h" "$T_0715" claim >/dev/null
  at "$h" "$T_0715" fail --reason 'attempt two failed' >/dev/null

  # The budget is spent: the scheduler must stop re-arming and say so, rather
  # than looping every interval or falling quiet as if the day had succeeded.
  out=$(at "$h" "$T_1100" run)
  assert_contains "$out" 'failed for 2026-09-10 after 2 attempts' \
    'the exhausted retry budget was not reported'
  assert_absent "$h/data/morning-intake/last-complete" \
    'exhausting the retries advanced the watermark'
  [ "$(queue_lines "$h")" = 2 ] || fail 'the exhausted state kept enqueueing wakes'

  # A new local day starts a fresh budget: yesterday never blocks today.
  out=$(at "$h" "$T_NEXT_0700" run)
  assert_contains "$out" 'due for 2026-09-11' "yesterday's exhausted budget blocked the next day"

  pass 'retries are bounded per local day, exhaustion stays visible, and the next day starts fresh'
}

test_no_existing_fleet_is_overridden() {
  local h other out
  h="$TMP_ROOT/isolation"
  other="$TMP_ROOT/other-home"
  new_home "$h"
  mkdir -p "$other/state" "$other/data"
  printf 'held by another session\n' >"$other/state/.session.lock"
  printf 'other-home records\n' >"$other/data/backlog.md"
  printf 'other queue row\n' >"$other/state/.wake-queue"

  at "$h" "$T_0700" run >/dev/null
  at "$h" "$T_0700" arm-check >/dev/null

  # The gate touches nothing outside its own home.
  [ "$(cat "$other/state/.session.lock")" = 'held by another session' ] \
    || fail "the intake disturbed another home's session lock"
  [ "$(cat "$other/data/backlog.md")" = 'other-home records' ] \
    || fail "the intake wrote into another home's records"
  [ "$(cat "$other/state/.wake-queue")" = 'other queue row' ] \
    || fail "the intake appended to another home's wake queue"

  # It takes no fleet lock either, so it cannot compete with a live session that
  # holds this home's lock. The only mutex it does take is private to its own
  # data directory, and it is released rather than leaked.
  assert_absent "$h/state/.session.lock" 'the intake created a session lock'
  assert_absent "$h/state/.watch.lock" 'the intake created a watcher lock'
  for out in "$h/state"/*lock*; do
    [ ! -e "$out" ] || fail "the intake created a lock file in state: $out"
  done
  assert_absent "$h/data/morning-intake/state.lock" 'the intake leaked its own state mutex'

  # A live session already holding this home's lock is not displaced.
  printf 'live session\n' >"$h/state/.session.lock"
  out=$(at "$h" "$T_0715" run)
  [ "$(cat "$h/state/.session.lock")" = 'live session' ] \
    || fail "the intake overwrote this home's live session lock"

  # And it never starts an agent or a watcher itself, nor names a fleet lock.
  assert_no_grep 'fm-spawn' "$INTAKE" 'the intake gate spawns an agent'
  assert_no_grep 'fm-watch' "$INTAKE" 'the intake gate starts a watcher'
  assert_no_grep '.session.lock' "$INTAKE" 'the intake gate names the per-home session lock'
  assert_no_grep '.watch.lock' "$INTAKE" 'the intake gate names the watcher lock'

  pass 'the intake never takes a fleet lock, starts an agent, or touches another home'
}

# The finding this covers: the watcher check, the launchd run and a live claim
# all read-modify-write one file from separate processes, so an unserialized
# sweep could write back a stale snapshot over a claim in flight and make the
# finished report unacceptable.
test_state_writes_are_serialized() {
  local h out code
  h="$TMP_ROOT/serialized"
  new_home "$h"

  at "$h" "$T_0700" run >/dev/null
  at "$h" "$T_0700" claim >/dev/null
  [ "$(state_field "$h" phase)" = claimed ] || fail 'the claim did not take the day'

  hold_state_lock "$h"

  # The watcher sweep must stay silent and leave the claim exactly as it found
  # it, rather than blocking the watcher or writing back its own snapshot.
  out=$(FM_MORNING_INTAKE_LOCK_WAIT=1 at "$h" "$T_0715" check) && code=0 || code=$?
  expect_code 0 "$code" 'a contended watcher check did not exit cleanly'
  [ -z "$out" ] || fail "a contended watcher check still signalled: $out"
  [ "$(state_field "$h" phase)" = claimed ] || fail 'a contended watcher check overwrote the claim'
  [ "$(state_field "$h" attempts)" = 1 ] || fail 'a contended watcher check reset the attempt count'

  # Every other writer refuses with a named error instead of proceeding from a
  # snapshot it cannot safely write back.
  out=$(FM_MORNING_INTAKE_LOCK_WAIT=1 at "$h" "$T_0715" run 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'a contended scheduled run proceeded anyway'
  assert_contains "$out" 'still holds' 'the contended run did not name the held mutex'

  release_state_lock "$h"

  # Contention is not a wedge: with the holder gone the day completes normally.
  printf '# intake 2026-09-10
findings
' >"$h/reports/2026-09-10.md"
  out=$(at "$h" "$T_0715" complete --report "$h/reports/2026-09-10.md" --lavish "$(new_page "$h")")
  assert_contains "$out" 'complete for 2026-09-10' 'the day could not complete after contention cleared'
  assert_absent "$h/data/morning-intake/state.lock" 'the state mutex was left behind'

  pass 'durable-state writes are serialized, so a watcher sweep never clobbers a claim in flight'
}

# A failure recorded before any claim is still an attempt. Without that the
# scheduled job re-arms and wakes the primary on every poll, all morning, and
# the visible exhausted state is never reached.
test_pre_claim_failure_spends_an_attempt() {
  local h out
  h="$TMP_ROOT/preclaim"
  new_home "$h"   # max_attempts = 2

  at "$h" "$T_0700" run >/dev/null
  out=$(at "$h" "$T_0700" fail --reason 'connector auth expired')
  assert_contains "$out" 'attempt 1 of 2' 'a failure before any claim did not spend an attempt'
  [ "$(state_field "$h" attempts)" = 1 ] || fail 'the pre-claim failure left the budget untouched'

  out=$(at "$h" "$T_0715" run)
  assert_contains "$out" 'due for 2026-09-10' 'the second attempt was not armed'
  out=$(at "$h" "$T_0715" fail --reason 'connector auth still expired')
  assert_contains "$out" 'attempt 2 of 2' 'the second pre-claim failure did not spend an attempt'

  # Budget spent without a single claim: the scheduler must stop re-arming and
  # say so, rather than looping every interval for the rest of the day.
  out=$(at "$h" "$T_1100" run)
  assert_contains "$out" 'failed for 2026-09-10 after 2 attempts'     'pre-claim failures never reached the visible exhausted state'
  [ "$(queue_lines "$h")" = 2 ] || fail 'the exhausted state kept enqueueing wakes'
  assert_absent "$h/data/morning-intake/last-complete" 'a pre-claim failure advanced the watermark'

  # Claiming is refused too, so nothing is woken for work it cannot take.
  out=$(at "$h" "$T_1100" claim 2>&1) && : || true
  assert_contains "$out" 'attempt budget exhausted' 'an exhausted budget still handed out a claim'

  # reset is the only way back, and it is deliberate.
  at "$h" "$T_1100" reset >/dev/null
  out=$(at "$h" "$T_1100" run)
  assert_contains "$out" 'due for 2026-09-10' 'reset did not give the budget back'

  pass 'a failure recorded before any claim spends an attempt, so pre-claim failures cannot re-arm forever'
}

test_lost_check_output_is_retried_after_backstop() {
  local h out
  h="$TMP_ROOT/check-lost"
  new_home "$h"
  at "$h" "$T_0700" run >/dev/null
  at "$h" "$T_0700" fail --reason 'fixture failure' >/dev/null
  at "$h" "$T_0700" check >/dev/null
  out=$(at "$h" $((T_0700 + 300)) check)
  [ -z "$out" ] || fail "an unchanged failure woke the primary on the next sweep: $out"
  out=$(at "$h" $((T_0700 + 43199)) check)
  [ -z "$out" ] || fail "an unchanged failure woke the primary inside the backstop: $out"
  out=$(at "$h" $((T_0700 + 43200)) check)
  assert_contains "$out" 'fixture failure' 'lost morning wake was permanently suppressed'
  out=$(at "$h" $((T_0700 + 43500)) check)
  [ -z "$out" ] || fail "the backstop became a wake loop: $out"
  pass 'an unresolved morning failure is re-woken only by the 12-hour backstop'
}

# An unregistered shim is worse than no shim: bin/fm-watch.sh rejects it and
# wakes the primary about it on every sweep.
test_arm_check_leaves_no_unregistered_shim() {
  local h out code
  h="$TMP_ROOT/armfail"
  new_home "$h"

  # Registration fails when the trust destination cannot be written.
  mkdir -p "$h/state/morning-intake.check-trust"
  out=$(at "$h" "$T_0700" arm-check 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'a failed registration was reported as success'
  assert_contains "$out" 'check registration failed' 'the refusal did not name the failed registration'
  assert_absent "$h/state/morning-intake.check.sh"     'a failed registration left an unregistered shim for the watcher to reject'
  [ "$(at "$h" "$T_0700" status | awk '$1 == "check_armed:" { print $2 }')" = absent ]     || fail 'status reported a check that is not armed'

  # A label the registration owner would refuse is refused up front instead.
  rm -rf "$h/state/morning-intake.check-trust"
  printf 'enabled = true
timezone = Europe/Amsterdam
label = .intake
' >"$h/config/morning-intake"
  out=$(at "$h" "$T_0700" arm-check 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'a label the check registrar refuses was accepted'
  assert_contains "$out" 'leading-dot-free slug' 'the refusal did not explain the label rule'
  assert_absent "$h/state/.intake.check.sh" 'a refused label still staged a shim'

  pass 'arming the watcher check is all-or-nothing, so no unregistered shim is ever left in state'
}

test_unresolvable_timezone_is_refused() {
  local h out code
  h="$TMP_ROOT/timezone"
  new_home "$h"

  # date(1) answers in UTC for a zone it cannot resolve and still exits 0, which
  # would move both the local day and the 06:00 threshold by the zone's offset.
  printf 'enabled = true
timezone = Europe/Amsterdm
' >"$h/config/morning-intake"
  out=$(at "$h" "$T_0700" run 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'an unresolvable timezone was accepted'
  assert_contains "$out" 'timezone does not resolve' 'the refusal did not name the unresolved zone'
  assert_absent "$h/data/morning-intake/state" 'an unresolvable timezone still armed a day'

  # status must not echo the typo back as if it were a working configuration.
  out=$(at "$h" "$T_0700" status 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'status reported an unresolvable timezone as valid'

  # The configured zone still resolves, and it is the zone the day is read in.
  new_home "$h"
  out=$(at "$h" "$T_0530" status)
  assert_contains "$out" 'local_date_now: 2026-09-10' 'the resolvable zone did not drive the local day'

  pass 'a timezone that does not resolve fails closed instead of silently becoming UTC'
}

test_rearm_starts_a_new_day_with_a_fresh_budget() {
  local h out
  h="$TMP_ROOT/rearm"
  new_home "$h"   # max_attempts = 2

  # Yesterday spent its whole budget and left a report path behind.
  mkdir -p "$h/data/morning-intake"
  cat >"$h/data/morning-intake/state" <<EOF
date=2026-09-09
phase=complete
attempts=2
updated=1788930000
rearms=1
surfaced=
report=$h/reports/2026-09-09.md
error=
EOF

  out=$(at "$h" "$T_0700" rearm --reason 'source published a correction')
  assert_contains "$out" 're-armed for 2026-09-10' "yesterday's spent budget blocked today's re-arm"
  [ "$(state_field "$h" attempts)" = 0 ] || fail "the re-arm carried yesterday's attempt count into today"
  [ -z "$(state_field "$h" report)" ] || fail "the re-arm carried yesterday's report path into today"

  # Today's budget is genuinely fresh: both attempts are available.
  at "$h" "$T_0700" claim >/dev/null
  at "$h" "$T_0700" fail --reason 'first attempt of the re-armed day' >/dev/null
  out=$(at "$h" "$T_0715" run)
  assert_contains "$out" 'due for 2026-09-10' 'the re-armed day had only a partial budget'

  # Within one day the budget is still bounded, so a revision storm cannot loop.
  at "$h" "$T_0715" claim >/dev/null
  out=$(at "$h" "$T_0715" rearm --reason 'another correction' 2>&1) && : || true
  assert_contains "$out" 'attempt budget exhausted' 'a same-day re-arm ignored the bounded budget'

  pass 're-arming on a new local day starts from a fresh budget and drops the stale report path'
}

test_both_schedules_share_one_launchd_writer() {
  local out home
  home="$TMP_ROOT/upstream-home"
  mkdir -p "$home/config"

  assert_grep 'fm-launchd-schedule-lib.sh' "$SCHEDULE"     'the intake schedule no longer uses the shared launchd writer'
  assert_grep 'fm-launchd-schedule-lib.sh' "$ROOT/bin/fm-upstream-watch-schedule.sh"     'the upstream-watch schedule does not use the shared launchd writer'

  # Sharing the writer must not have moved the other owner's contract.
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-upstream-watch-schedule.sh" render)
  assert_contains "$out" '<integer>604800</integer>' 'the shared writer changed the weekly upstream default'
  assert_contains "$out" 'dev.firstmate.upstream-watch.' 'the shared writer changed the per-home upstream label'
  assert_contains "$out" 'fm-upstream-watch.sh' 'the shared writer changed the upstream program'
  assert_contains "$out" '<key>RunAtLoad</key>' 'the shared writer dropped RunAtLoad from the upstream schedule'

  # Each home still gets its own label, so one home never disturbs another.
  [ "$(FM_HOME="$TMP_ROOT/home-a" FM_ROOT_OVERRIDE="$ROOT" "$SCHEDULE" render | awk '/<string>dev.firstmate/ { print; exit }')"     != "$(FM_HOME="$TMP_ROOT/home-b" FM_ROOT_OVERRIDE="$ROOT" "$SCHEDULE" render | awk '/<string>dev.firstmate/ { print; exit }')" ]     || fail 'two different homes render the same launchd label'

  pass 'both schedule owners render through one launchd writer, per home, with no change to the upstream contract'
}

test_local_configuration_stays_private() {
  local h out code
  h="$TMP_ROOT/privacy"
  new_home "$h"

  # An unknown key is refused, not silently ignored, so no channel id, token, or
  # account path can be parked in this file and later echoed.
  printf 'enabled = true\nslack_token = shhh-not-a-real-secret\n' >"$h/config/morning-intake"
  out=$(at "$h" "$T_0700" run 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'an unknown config key was accepted'
  assert_contains "$out" 'unknown config key: slack_token' 'the refusal did not name the rejected key'
  assert_not_contains "$out" 'shhh-not-a-real-secret' 'the refusal echoed the rejected value'

  # status prints only declared knobs and durable state.
  new_home "$h"
  out=$(at "$h" "$T_0700" status)
  assert_contains "$out" 'enabled: true' 'status omitted the opt-in state'
  assert_contains "$out" 'timezone: Europe/Amsterdam' 'status omitted the configured zone'
  assert_contains "$out" 'local_date_now: 2026-09-10' 'status omitted the resolved local day'
  assert_not_contains "$out" 'shhh-not-a-real-secret' 'status leaked a rejected value'

  # The private surfaces this feature writes are ignored by git.
  git -C "$ROOT" check-ignore -q "$ROOT/config/morning-intake" \
    || fail 'config/morning-intake is not gitignored'
  git -C "$ROOT" check-ignore -q "$ROOT/data/morning-intake/state" \
    || fail 'data/morning-intake state is not gitignored'
  git -C "$ROOT" check-ignore -q "$ROOT/state/morning-intake.check.sh" \
    || fail 'the generated watcher shim is not gitignored'

  pass 'unknown config keys are refused, status prints only declared knobs, and every private path is ignored'
}

test_install_and_uninstall_on_a_temp_home() {
  local h out code fakebin agents
  h="$TMP_ROOT/install"
  new_home "$h"
  agents="$TMP_ROOT/LaunchAgents"
  mkdir -p "$agents"

  # A fake launchd transport so the suite never loads a real agent.
  fakebin="$TMP_ROOT/fakebin"
  mkdir -p "$fakebin"
  cat >"$fakebin/launchctl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LAUNCHCTL_LOG"
FAKE
  chmod +x "$fakebin/launchctl"

  schedule() {
    FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" \
    FM_MORNING_INTAKE_LAUNCH_AGENTS_DIR="$agents" \
    FM_MORNING_INTAKE_LAUNCHCTL="$fakebin/launchctl" \
    FAKE_LAUNCHCTL_LOG="$TMP_ROOT/launchctl.log" \
      "$SCHEDULE" "$@"
  }

  # The schedule reads the cadence back through `interval`, so that contract has
  # to be discoverable from the gate's own --help rather than only from source.
  out=$(at "$h" "$T_0700" --help 2>&1)
  assert_contains "$out" 'fm-morning-intake.sh interval' \
    'the interval contract the schedule depends on is missing from --help'

  out=$(schedule render)
  assert_contains "$out" '<key>StartInterval</key>' 'the rendered schedule omitted StartInterval'
  assert_contains "$out" '<integer>900</integer>' 'the default cadence is not the 900s poll'
  assert_contains "$out" '<key>RunAtLoad</key>' 'the schedule does not run at load, so login never catches up'
  assert_contains "$out" '<string>run</string>' 'the schedule does not call the intake gate'
  assert_contains "$out" 'dev.firstmate.morning-intake.' 'the label is not the per-home intake label'

  # The cadence comes from private config through the gate owner, not a second parser.
  printf 'enabled = true\ntimezone = Europe/Amsterdam\nreport_dir = %s\ninterval_seconds = 300\n' \
    "$h/reports" >"$h/config/morning-intake"
  out=$(schedule render)
  assert_contains "$out" '<integer>300</integer>' 'private cadence configuration was ignored'
  new_home "$h"

  if [ "$(uname)" != Darwin ]; then
    pass 'the schedule renders an inspectable per-home launchd definition (install skipped: not macOS)'
    return 0
  fi

  : >"$TMP_ROOT/launchctl.log"
  # Arm a real day first, so remove can be checked against durable history that
  # actually exists rather than an empty home.
  at "$h" "$T_0700" run >/dev/null
  out=$(schedule install)
  assert_contains "$out" "installed: $agents/" 'install did not report the written definition'
  assert_present "$agents"/dev.firstmate.morning-intake.*.plist 'install wrote no plist'
  assert_grep 'bootstrap gui/' "$TMP_ROOT/launchctl.log" 'install did not load the agent'
  assert_present "$h/state/morning-intake.check.sh" 'install did not arm the live-session check'

  out=$(schedule status)
  assert_contains "$out" 'installed definition' 'status did not show the installed definition'
  assert_contains "$out" 'check_armed: armed' 'status did not report the armed live check'

  out=$(schedule remove)
  assert_contains "$out" 'removed: ' 'remove did not report the deleted definition'
  assert_absent "$agents"/dev.firstmate.morning-intake.*.plist 'remove left the plist behind'
  assert_absent "$h/state/morning-intake.check.sh" 'remove left the watcher check armed'
  assert_grep 'bootout gui/' "$TMP_ROOT/launchctl.log" 'remove did not unload the agent'
  # Uninstalling the schedule is not the same as discarding intake history.
  assert_present "$h/data/morning-intake/state" 'remove discarded the durable intake record'

  # And a home that never opted in cannot be enrolled by install.
  printf 'enabled = false\n' >"$h/config/morning-intake"
  out=$(schedule install 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'install enrolled a home that never opted in'
  assert_contains "$out" 'not opted in' 'the install refusal did not name the missing opt-in'

  pass 'install, status and remove work against a temporary home and refuse a home without an opt-in'
}

# Nothing re-creates state/<label>.check.sh once it is gone, so losing it
# silently drops the live-session delivery path. The loss has to be detectable
# through the read-only surface bootstrap already calls, and re-arming has to
# be safe to repeat.
test_lost_live_check_is_reported_and_rearming_is_idempotent() {
  local h out first second armed
  h="$TMP_ROOT/checkloss"
  new_home "$h"

  at "$h" "$T_0700" run >/dev/null
  at "$h" "$T_0700" arm-check >/dev/null

  # A healthy registered check has nothing to repair.
  out=$(at "$h" "$T_0715" pending)
  assert_contains "$out" 'morning-intake due for 2026-09-10' 'the armed intake was not surfaced'
  assert_not_contains "$out" 'arm-check' 'a healthy live check was reported as lost'

  # The shim is deleted with the intake still armed: the watcher path is gone
  # and only this surface can say so.
  rm -f "$h/state/morning-intake.check.sh" "$h/state/morning-intake.check-trust"
  out=$(at "$h" "$T_0715" pending)
  assert_contains "$out" 'morning-intake due for 2026-09-10' 'the owed intake stopped being surfaced'
  assert_contains "$out" 'live check is absent' 'a deleted watcher shim was not reported'
  assert_contains "$out" 'arm-check' 'the repair line did not name the command that fixes it'
  # Detection is read-only: it reports the loss, it does not re-arm.
  assert_absent "$h/state/morning-intake.check.sh" 'the read-only pending surface wrote a shim'

  # A shim left without its binding is the worse case, because the watcher
  # rejects it on every sweep. It is reported as unregistered, not as armed.
  at "$h" "$T_0715" arm-check >/dev/null
  rm -f "$h/state/morning-intake.check-trust"
  out=$(at "$h" "$T_0715" pending)
  assert_contains "$out" 'live check is unregistered' 'a half-registered shim was reported as healthy'

  # Re-arming an already-armed home converges: same shim, same binding, no
  # duplicated or orphaned file left in state/.
  at "$h" "$T_0715" arm-check >/dev/null
  first=$(ls -A "$h/state"; cat "$h/state/morning-intake.check.sh"; cat "$h/state/morning-intake.check-trust")
  at "$h" "$T_0715" arm-check >/dev/null
  second=$(ls -A "$h/state"; cat "$h/state/morning-intake.check.sh"; cat "$h/state/morning-intake.check-trust")
  [ "$first" = "$second" ] || fail 'a second arm-check did not converge on the same registered state'
  out=$(at "$h" "$T_0715" pending)
  assert_not_contains "$out" 'arm-check' 'a re-armed check was still reported as lost'

  # A shim whose bytes drifted away from the recorded binding is re-registered
  # rather than left for the watcher to reject.
  printf '#!/usr/bin/env bash\necho drifted\n' >"$h/state/morning-intake.check.sh"
  chmod 0700 "$h/state/morning-intake.check.sh"
  armed=$(at "$h" "$T_0715" status | awk '$1 == "check_armed:" { print $2 }')
  [ "$armed" = unregistered ] || fail "a drifted shim reported as '$armed', not unregistered"
  at "$h" "$T_0715" arm-check >/dev/null
  second=$(ls -A "$h/state"; cat "$h/state/morning-intake.check.sh"; cat "$h/state/morning-intake.check-trust")
  [ "$first" = "$second" ] || fail 'arm-check did not rebind a shim whose bytes had drifted'
  ( . "$ROOT/bin/fm-pr-lib.sh"; . "$ROOT/bin/fm-check-lib.sh"
    fm_custom_check_registered "$h/state" morning-intake ) \
    || fail 'the re-armed shim is not registered by the registration owner'

  # And a home that never opted in stays silent about all of it, even with an
  # owed-looking record and no shim at all.
  printf 'enabled = false\n' >"$h/config/morning-intake"
  rm -f "$h/state/morning-intake.check.sh" "$h/state/morning-intake.check-trust"
  out=$(at "$h" "$T_0715" pending)
  [ -z "$out" ] || fail "a home that never opted in surfaced a repair line: $out"

  pass 'a lost or unregistered live check is reported at session start, and re-arming is idempotent'
}

# --force is the retained manual arm, not a budget override: bounded retry is a
# requirement and `reset` is the single owner of the budget.
test_force_never_overrides_the_bounded_retry_budget() {
  local h out code
  h="$TMP_ROOT/force"
  new_home "$h"   # max_attempts = 2

  # The manual behavior the intent keeps: arming outside the configured window
  # on a day that still has budget.
  out=$(at "$h" "$T_0530" run --force)
  assert_contains "$out" 'due for 2026-09-10' 'force did not arm outside the configured window'
  [ "$(queue_lines "$h")" = 1 ] || fail 'a forced arm did not enqueue exactly one wake'

  # Spend the day's whole budget.
  at "$h" "$T_0700" claim >/dev/null
  at "$h" "$T_0700" fail --reason 'attempt one failed' >/dev/null
  at "$h" "$T_0715" claim >/dev/null
  at "$h" "$T_0715" fail --reason 'attempt two failed' >/dev/null

  # Forcing now would set the day due and wake the primary for work `claim`
  # refuses. It must refuse instead, and change nothing.
  out=$(at "$h" "$T_1100" run --force 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'force armed a day whose retry budget was spent'
  assert_contains "$out" 'attempt budget exhausted' 'the refusal did not name the spent budget'
  assert_contains "$out" 'reset' 'the refusal did not name reset as the recovery'
  [ "$(state_field "$h" phase)" = failed ] || fail 'a refused force still set the day due'
  [ "$(state_field "$h" attempts)" = 2 ] || fail 'a refused force moved the attempt count'
  [ "$(queue_lines "$h")" = 1 ] || fail 'a refused force still enqueued a wake for the primary'
  assert_absent "$h/data/morning-intake/last-complete" 'a refused force advanced the watermark'

  # reset owns the budget, and force arms normally once it has been given back.
  at "$h" "$T_1100" reset >/dev/null
  out=$(at "$h" "$T_1100" run --force)
  assert_contains "$out" 'due for 2026-09-10' 'force did not arm after reset gave the budget back'
  [ "$(queue_lines "$h")" = 2 ] || fail 'the forced arm after reset enqueued no wake'
  out=$(at "$h" "$T_1100" claim)
  assert_contains "$out" 'attempt: 1 of 2' 'the forced arm handed out no claim after reset'

  pass 'run --force arms outside the window but never overrides the bounded retry budget'
}

test_bootstrap_surfaces_the_intake() {
  local h out
  h="$TMP_ROOT/bootstrap-hook"
  new_home "$h"
  at "$h" "$T_0700" run >/dev/null
  # Session-start bootstrap reaches the intake through the built-in bootstrap
  # hook (bin/fm-addon.sh, hooks/bootstrap/10-morning-intake).
  out=$(FM_HOME="$h" "$ROOT/bin/fm-addon.sh" hooks bootstrap)
  assert_contains "$out" "$ROOT/hooks/bootstrap/10-morning-intake" 'the built-in bootstrap hook is not listed'
  out=$(FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" FM_MORNING_INTAKE_NOW="$T_0715" "$ROOT/bin/fm-addon.sh" run bootstrap)
  assert_contains "$out" 'MORNING_INTAKE:' 'the bootstrap hook point did not surface the owed intake'

  pass 'the session-start bootstrap section surfaces an owed, failed, or finished intake'
}

# The bootstrap side of this capability is a guarded hook:
# hooks/bootstrap/10-morning-intake runs the gate only when it is executable
# beside the hook. That guard is the whole promise that a copy without the gate
# script still starts cleanly, and no other case in any suite removes the
# script, so nothing else can catch the day someone makes the intake a hard
# dependency of session start. The control run is part of the assertion: it
# proves the silence below is caused by the missing file rather than by a
# fixture that had nothing to say.
test_bootstrap_without_the_intake_script_degrades_to_upstream() {
  local h report fakebin degraded entry control degraded_out expected code

  h="$TMP_ROOT/bootstrap-degrade"
  new_home "$h"
  # Pin the runtime backend so the tool probes are the same in both runs no
  # matter which terminal the suite is running inside.
  printf '%s\n' tmux >"$h/config/backend"
  report="$h/reports/2026-09-10.md"
  at "$h" "$T_0700" run >/dev/null
  at "$h" "$T_0715" claim >/dev/null
  printf '# intake 2026-09-10\nfindings\n' >"$report"
  at "$h" "$T_0715" complete --report "$report" --lavish "$(new_page "$h")" >/dev/null

  # gh is the only probe that would otherwise reach the network.
  fakebin=$(fm_fakebin "$h")
  fm_fake_exit0 "$fakebin" gh

  # An add-on carrying the same-named hook and every intake file but the gate
  # script, built by symlink so the real checkout is never mutated.
  # fm-morning-intake-schedule.sh deliberately stays: the guard names the gate
  # script alone. The control run has no add-on, so the built-in hook runs; the
  # degraded run names this add-on, whose hook replaces the built-in one.
  degraded="$h/degraded-addon"
  mkdir -p "$degraded/bin" "$degraded/hooks/bootstrap"
  ln -s "$ROOT/hooks/bootstrap/10-morning-intake" "$degraded/hooks/bootstrap/10-morning-intake"
  ln -s "$ROOT/bin/fm-morning-intake-schedule.sh" "$degraded/bin/fm-morning-intake-schedule.sh"
  [ ! -e "$degraded/bin/fm-morning-intake.sh" ] \
    || fail 'the degraded add-on must not contain the intake gate script'
  assert_present "$degraded/bin/fm-morning-intake-schedule.sh" \
    'the degraded add-on lost a file the guard does not name'

  control=$(PATH="$fakebin:$PATH" FM_HOME="$h" FM_ROOT_OVERRIDE="$h" \
    FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null) && code=0 || code=$?
  expect_code 0 "$code" 'bootstrap failed with the intake gate present'
  assert_contains "$control" "MORNING_INTAKE: new morning-intake report at $report" \
    'bootstrap did not surface the finished report, so the degraded run proves nothing'

  printf 'path = %s\n' "$degraded" >"$h/config/addon"
  degraded_out=$(PATH="$fakebin:$PATH" FM_HOME="$h" FM_ROOT_OVERRIDE="$h" \
    FM_BOOTSTRAP_DETECT_ONLY=1 "$ROOT/bin/fm-bootstrap.sh" 2>"$h/degraded.err") \
    && code=0 || code=$?
  expect_code 0 "$code" 'an absent bin/fm-morning-intake.sh blocked bootstrap'
  printf '%s\n' "$degraded_out" | grep -q '^MORNING_INTAKE:' \
    && fail "bootstrap reported an intake with no gate script: $degraded_out"

  # The guard itself, not just its effect. bin/fm-bootstrap.sh runs under set -u
  # alone, so dropping the -x test would still exit 0 and still print no intake
  # line; the only trace left is the shell naming the missing file on stderr.
  # Nothing in an unmodified bootstrap mentions the gate script outside the
  # guarded call, so any mention here is the guard gone.
  grep -q fm-morning-intake "$h/degraded.err" \
    && fail "bootstrap called the intake gate without its guard: $(cat "$h/degraded.err")"

  # Exactly upstream behaviour: everything the control printed apart from the
  # intake lines, and nothing invented in their place.
  expected=$(printf '%s\n' "$control" | grep -v '^MORNING_INTAKE:' || true)
  [ "$degraded_out" = "$expected" ] || fail \
    "an absent intake gate changed the rest of bootstrap; expected [$expected] but got [$degraded_out]"

  pass 'bootstrap without bin/fm-morning-intake.sh still completes and degrades to upstream output'
}

# The captain made the Lavish page the standard daily to-do surface, so a
# markdown report alone is no longer the deliverable. This pins the gate: the
# page is proved like the report, a skipped page is a recorded reason rather
# than a silent omission, and neither refusal advances the day.
test_completion_requires_the_days_page() {
  local h report out code page
  h="$TMP_ROOT/lavish-gate"
  new_home "$h"
  report="$h/reports/2026-09-10.md"
  at "$h" "$T_0700" run >/dev/null
  at "$h" "$T_0700" claim >/dev/null
  printf '# intake 2026-09-10\nfindings\n' >"$report"

  # A verified report with no page is not a completed intake.
  out=$(at "$h" "$T_0700" complete --report "$report" 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'complete accepted a report with no day page'
  assert_contains "$out" '--lavish is required' 'the refusal did not name the missing page'
  assert_absent "$h/data/morning-intake/last-complete" \
    'a completion with no page advanced the watermark'

  # A page that does not exist is refused exactly like a missing report.
  mkdir -p "$h/.lavish"
  out=$(at "$h" "$T_0700" complete --report "$report" \
    --lavish "$h/.lavish/today-2026-09-10.html" 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'complete accepted a page that does not exist'
  assert_contains "$out" 'lavish page is not a regular file' \
    'the refusal did not name the absent page'

  # An empty page is not a page.
  : >"$h/.lavish/today-2026-09-10.html"
  out=$(at "$h" "$T_0700" complete --report "$report" \
    --lavish "$h/.lavish/today-2026-09-10.html" 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'complete accepted an empty page'
  assert_contains "$out" 'lavish page is empty' 'the refusal did not name the empty page'

  # A page outside the home's own .lavish/ directory is refused.
  printf '<p>elsewhere</p>\n' >"$TMP_ROOT/elsewhere.html"
  out=$(at "$h" "$T_0700" complete --report "$report" \
    --lavish "$TMP_ROOT/elsewhere.html" 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'complete accepted a page outside the home .lavish directory'
  assert_contains "$out" 'must name a page under' 'the refusal did not name the expected directory'
  assert_absent "$h/data/morning-intake/last-complete" \
    'a refused page advanced the watermark'

  # A real page completes the day and is recorded.
  page=$(new_page "$h")
  out=$(at "$h" "$T_0700" complete --report "$report" --lavish "$page")
  assert_contains "$out" "page $page" 'complete did not confirm the page it accepted'
  [ "$(state_field "$h" lavish)" = "$page" ] \
    || fail 'the accepted page was not written into the day record'

  # The deliberate exception, on a second day: no page, but a recorded reason.
  at "$h" "$T_NEXT_0700" run >/dev/null
  at "$h" "$T_NEXT_0700" claim >/dev/null
  printf '# intake 2026-09-11\nfindings\n' >"$h/reports/2026-09-11.md"
  out=$(at "$h" "$T_NEXT_0700" complete --report "$h/reports/2026-09-11.md" \
    --no-lavish 'the help desk was unreachable all morning, nothing verified to publish')
  assert_contains "$out" 'NO PAGE: the help desk was unreachable' \
    'a waived page was not reported as a waiver'
  assert_contains "$(at "$h" "$T_NEXT_0700" status)" \
    'state_lavish_waiver: the help desk was unreachable' \
    'the waiver reason was not kept in the day record'
  [ "$(state_field "$h" lavish)" = '' ] \
    || fail 'a waived day carried a page path forward'

  # Both at once is a contradiction, not a preference.
  out=$(at "$h" "$T_NEXT_0700" complete --report "$h/reports/2026-09-11.md" \
    --lavish "$page" --no-lavish 'reason' 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'complete accepted both a page and a waiver'
  assert_contains "$out" 'not both' 'the contradiction was not named'

  pass "the day's page is part of completion, and skipping it is a recorded reason rather than a silent omission"
}

test_inert_without_opt_in
test_daily_gate_and_no_duplicate_wake
test_missed_morning_catches_up
test_wake_drives_intake_to_acknowledged_report
test_failure_cannot_advance_watermark_and_correction_still_lands
test_completion_requires_the_days_page
test_retries_are_bounded_and_exhaustion_is_visible
test_no_existing_fleet_is_overridden
test_state_writes_are_serialized
test_pre_claim_failure_spends_an_attempt
test_arm_check_leaves_no_unregistered_shim
test_lost_check_output_is_retried_after_backstop
test_unresolvable_timezone_is_refused
test_rearm_starts_a_new_day_with_a_fresh_budget
test_both_schedules_share_one_launchd_writer
test_local_configuration_stays_private
test_install_and_uninstall_on_a_temp_home
test_lost_live_check_is_reported_and_rearming_is_idempotent
test_force_never_overrides_the_bounded_retry_budget
test_bootstrap_surfaces_the_intake
test_bootstrap_without_the_intake_script_degrades_to_upstream

test_completion_composes_morning_and_preserves_failure() {
  local h page report out code
  h="$TMP_ROOT/composition"
  new_home "$h"
  at "$h" "$T_0700" run >/dev/null
  at "$h" "$T_0700" claim >/dev/null
  page=$(new_page "$h")
  report="$h/reports/composition.md"
  printf 'source-verified report\n' >"$report"
  printf '<h2>Calendar</h2><p>Meeting details</p>\n' >"${page%.html}.morning.html"
  printf '{invalid\n' >"${page%.html}.morning.json"
  out=$(at "$h" "$T_0715" complete --report "$report" --lavish "$page" 2>&1) && code=0 || code=$?
  expect_code 2 "$code" 'invalid morning metadata must prevent completion'
  [ ! -f "$h/data/morning-intake/last-complete" ] || fail 'failed composition advanced completion'
  printf '{"version":1,"date":"2026-09-10","actions":[]}\n' >"${page%.html}.morning.json"
  at "$h" "$T_0715" complete --report "$report" --lavish "$page" >/dev/null
  assert_contains "$(cat "$page")" '<h2>Needs you now<small>' 'morning completion did not compose the page'
  assert_contains "$(cat "$page")" 'Meeting details' 'composition lost morning details'
  pass 'morning completion composes the page and failed composition preserves the claim'
}

test_completion_composes_morning_and_preserves_failure
