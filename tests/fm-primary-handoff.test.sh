#!/usr/bin/env bash
# Behavior tests for quota-aware primary orchestrator handoff, including the
# never-two-live-session-lock-holders invariant under failure injection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-primary-handoff)
HOME_FIX="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
mkdir -p "$HOME_FIX/state" "$HOME_FIX/config" "$HOME_FIX/data"
SIGNAL_LOG="$TMP_ROOT/signal.log"
LAUNCH_LOG="$TMP_ROOT/launch.log"

write_enabled_config() {
  local threshold=${1:-15}
  local context_used=${2:-}
  if [ -n "$context_used" ]; then
    cat > "$HOME_FIX/config/primary-handoff" <<JSON
{
  "enabled": true,
  "threshold_percent_remaining": $threshold,
  "threshold_context_percent_used": $context_used,
  "poll_seconds": 60,
  "cooldown_seconds": 300,
  "chain": ["claude-fable", "pi", "codex", "kimi-k3"]
}
JSON
  else
    cat > "$HOME_FIX/config/primary-handoff" <<JSON
{
  "enabled": true,
  "threshold_percent_remaining": $threshold,
  "poll_seconds": 60,
  "cooldown_seconds": 300,
  "chain": ["claude-fable", "pi", "codex", "kimi-k3"]
}
JSON
  fi
}

write_context_sample() {
  local remaining=$1
  local used=$((100 - remaining))
  cat > "$HOME_FIX/state/.primary-context" <<EOF
schema=fm-primary-context.v1
remaining_percent=$remaining
used_percent=$used
updated_at=1
EOF
}

write_quota() {
  local file=$1 claude_rem=$2
  cat > "$file" <<JSON
{
  "providers": [
    {
      "provider": "claude",
      "state": { "status": "fresh" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": $claude_rem },
        { "id": "seven_day", "kind": "weekly", "percentRemaining": 80 }
      ]
    },
    {
      "provider": "codex",
      "state": { "status": "fresh" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": 90 },
        { "id": "weekly", "kind": "weekly", "percentRemaining": 90 }
      ]
    }
  ]
}
JSON
}

write_active() {
  local profile=$1
  cat > "$HOME_FIX/state/.primary-active" <<EOF
schema=fm-primary-active.v1
profile=$profile
pid=
started_at=1
updated_at=1
EOF
}

start_fake_holder() {
  # Args contain "claude" so fm-lock.sh holder_alive treats this as a harness.
  bash -c 'while :; do sleep 5; done' claude-primary-handoff-test &
  FAKE_HOLDER_PID=$!
  printf '%s\n' "$FAKE_HOLDER_PID" > "$HOME_FIX/state/.lock"
}

stop_fake_holder() {
  if [ -n "${FAKE_HOLDER_PID:-}" ]; then
    kill "$FAKE_HOLDER_PID" 2>/dev/null || true
    wait "$FAKE_HOLDER_PID" 2>/dev/null || true
    FAKE_HOLDER_PID=
  fi
}

cleanup_holders() {
  stop_fake_holder
  if [ -n "${FAKE_INCOMING_PID:-}" ]; then
    kill "$FAKE_INCOMING_PID" 2>/dev/null || true
    wait "$FAKE_INCOMING_PID" 2>/dev/null || true
    FAKE_INCOMING_PID=
  fi
  if [ -n "${FAKE_WORKER_PID:-}" ]; then
    kill "$FAKE_WORKER_PID" 2>/dev/null || true
    wait "$FAKE_WORKER_PID" 2>/dev/null || true
    FAKE_WORKER_PID=
  fi
  rm -f "$HOME_FIX/state/.lock" "$HOME_FIX/state/.primary-handoff" \
    "$HOME_FIX/state/.primary-handoff.flush" \
    "$HOME_FIX/state/.primary-active" \
    "$HOME_FIX/state/.primary-context" \
    "$HOME_FIX/state/.last-watcher-beat" \
    "$HOME_FIX/state/.afk" \
    "$HOME_FIX/state/.wake-queue" \
    "$HOME_FIX/state/worker1.meta" \
    "$HOME_FIX/state/worker1.status"
}
trap 'cleanup_holders; fm_test_cleanup' EXIT

live_holder_count() {
  local status
  status=$(FM_HOME="$HOME_FIX" "$ROOT/bin/fm-lock.sh" status)
  case "$status" in
    *"held by live harness pid"*) printf '1\n' ;;
    *) printf '0\n' ;;
  esac
}

assert_never_two() {
  local count
  count=$(live_holder_count)
  [ "$count" -le 1 ] || fail "never-two-holders invariant broken: live count=$count"
}

signal_kill() {
  local pid=$1
  printf 'signal %s\n' "$pid" >> "$SIGNAL_LOG"
  kill "$pid" 2>/dev/null || true
}

wait_dead_ok() {
  local pid=$1 i=0
  while [ "$i" -lt 20 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

launch_incoming() {
  local profile=$1
  printf 'launch %s\n' "$profile" >> "$LAUNCH_LOG"
  # Args must match fm-lock.sh HARNESS_RE (pi is anchored as ^pi$, so use codex/claude).
  # Detach stdio so command-substitution callers are not held open.
  bash -c 'while :; do sleep 5; done' claude-primary-handoff-incoming \
    </dev/null >/dev/null 2>&1 &
  FAKE_INCOMING_PID=$!
  printf '%s\n' "$FAKE_INCOMING_PID" > "$HOME_FIX/state/.lock"
  # Simulate the incoming primary re-arming supervision after session-start.
  : > "$HOME_FIX/state/.last-watcher-beat"
  return 0
}

run_execute() {
  PATH="$FAKEBIN:/usr/bin:/bin" \
  FM_HOME="$HOME_FIX" \
  FM_HANDOFF_QUOTA_JSON="$TMP_ROOT/quota.json" \
  FM_HANDOFF_SIGNAL_CMD='signal_kill' \
  FM_HANDOFF_WAIT_DEAD_CMD='wait_dead_ok' \
  FM_HANDOFF_LAUNCH_CMD='launch_incoming' \
  FM_HANDOFF_SKIP_CLI_CHECK=1 \
  FM_HANDOFF_WAIT_DEAD_SECS=3 \
  "$@"
}

# Export seam functions for eval'd command strings.
export -f signal_kill wait_dead_ok launch_incoming
export SIGNAL_LOG LAUNCH_LOG HOME_FIX FAKE_INCOMING_PID ROOT

test_disabled_is_noop() {
  local out status=0
  rm -f "$HOME_FIX/config/primary-handoff"
  start_fake_holder
  write_active claude-fable
  write_quota "$TMP_ROOT/quota.json" 5
  out=$(run_execute "$ROOT/bin/fm-primary-handoff.sh" check 2>&1) || status=$?
  expect_code 0 "$status" "disabled check should succeed as no-op"
  assert_contains "$out" 'handoff: disabled' "disabled check should say disabled"
  [ "$(live_holder_count)" = 1 ] || fail "disabled check must not release the live lock"
  assert_not_contains "$(cat "$LAUNCH_LOG" 2>/dev/null || true)" 'launch' "disabled check must not launch"
  cleanup_holders
  pass "disabled config is a no-op and leaves the live session lock alone"
}

test_happy_path_atomic_handoff() {
  local out status=0 record
  : > "$SIGNAL_LOG"
  : > "$LAUNCH_LOG"
  write_enabled_config 15
  write_quota "$TMP_ROOT/quota.json" 10
  write_active claude-fable
  start_fake_holder
  assert_never_two
  out=$(run_execute "$ROOT/bin/fm-primary-handoff.sh" execute --from claude-fable --to pi 2>&1) || status=$?
  expect_code 0 "$status" "happy-path execute should succeed: $out"
  assert_contains "$out" 'handed_off: claude-fable -> pi' "happy path missing handoff line"
  assert_contains "$(cat "$SIGNAL_LOG")" "signal $FAKE_HOLDER_PID" "outgoing was not signaled"
  assert_contains "$(cat "$LAUNCH_LOG")" 'launch pi' "incoming was not launched"
  record=$(cat "$HOME_FIX/state/.primary-handoff")
  assert_contains "$record" 'phase=complete' "record should be complete"
  assert_contains "$record" 'from=claude-fable' "record from wrong"
  assert_contains "$record" 'to=pi' "record to wrong"
  [ -f "$HOME_FIX/state/.primary-handoff.flush" ] || fail "flush marker missing"
  assert_never_two
  [ "$(live_holder_count)" = 1 ] || fail "incoming should hold the lock after happy path"
  incoming_lock=$(cat "$HOME_FIX/state/.lock")
  [ -n "$incoming_lock" ] || fail "lock should have an incoming pid"
  [ "$incoming_lock" != "$FAKE_HOLDER_PID" ] || fail "lock must not still be outgoing"
  cleanup_holders
  pass "happy-path handoff flushes, releases outgoing, launches incoming, one live holder"
}

test_flush_failure_keeps_outgoing_lock() {
  local out status=0
  : > "$LAUNCH_LOG"
  write_enabled_config
  write_quota "$TMP_ROOT/quota.json" 10
  write_active claude-fable
  start_fake_holder
  out=$(
    FM_HANDOFF_INJECT_FAIL=flush \
    run_execute "$ROOT/bin/fm-primary-handoff.sh" execute --from claude-fable --to pi 2>&1
  ) || status=$?
  [ "$status" -ne 0 ] || fail "flush failure should abort"
  assert_contains "$out" 'flush failed' "flush failure message missing"
  [ "$(live_holder_count)" = 1 ] || fail "flush failure must keep outgoing live holder"
  [ "$(cat "$HOME_FIX/state/.lock")" = "$FAKE_HOLDER_PID" ] || fail "outgoing must still own the lock"
  assert_not_contains "$(cat "$LAUNCH_LOG")" 'launch' "flush failure must not launch"
  assert_contains "$(cat "$HOME_FIX/state/.primary-handoff")" 'phase=aborted' "should abort"
  assert_never_two
  cleanup_holders
  pass "flush failure aborts without releasing lock or launching incoming"
}

test_wait_dead_failure_never_launches() {
  local out status=0
  : > "$LAUNCH_LOG"
  write_enabled_config
  write_quota "$TMP_ROOT/quota.json" 10
  write_active claude-fable
  start_fake_holder
  # Signal still runs before wait_dead; the outgoing may die. The safety gate is
  # that incoming is never launched and we never dual-hold.
  out=$(
    FM_HANDOFF_INJECT_FAIL=wait_dead \
    run_execute "$ROOT/bin/fm-primary-handoff.sh" execute --from claude-fable --to pi 2>&1
  ) || status=$?
  [ "$status" -ne 0 ] || fail "wait_dead failure should abort"
  assert_contains "$out" 'did not release' "wait_dead abort message missing"
  assert_not_contains "$(cat "$LAUNCH_LOG")" 'launch' "wait_dead failure must not launch"
  [ "$(live_holder_count)" -le 1 ] || fail "wait_dead failure dual-held"
  assert_contains "$(cat "$HOME_FIX/state/.primary-handoff")" 'phase=aborted' "should abort"
  assert_never_two
  cleanup_holders
  pass "wait_dead failure never launches and never dual-holds"
}

test_signal_failure_keeps_outgoing_lock() {
  local out status=0
  : > "$LAUNCH_LOG"
  write_enabled_config
  write_quota "$TMP_ROOT/quota.json" 10
  write_active claude-fable
  start_fake_holder
  out=$(
    FM_HANDOFF_INJECT_FAIL=signal \
    run_execute "$ROOT/bin/fm-primary-handoff.sh" execute --from claude-fable --to pi 2>&1
  ) || status=$?
  [ "$status" -ne 0 ] || fail "signal failure should abort"
  assert_contains "$out" 'failed to signal' "signal abort message missing"
  [ "$(live_holder_count)" = 1 ] || fail "signal failure must keep outgoing live holder"
  [ "$(cat "$HOME_FIX/state/.lock")" = "$FAKE_HOLDER_PID" ] || fail "outgoing must still own the lock"
  assert_not_contains "$(cat "$LAUNCH_LOG")" 'launch' "signal failure must not launch"
  assert_never_two
  cleanup_holders
  pass "signal failure aborts with outgoing still the sole live holder"
}

test_release_stale_refuses_live_holder() {
  local out status=0
  start_fake_holder
  out=$(FM_HOME="$HOME_FIX" "$ROOT/bin/fm-lock.sh" release-stale 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "release-stale must refuse a live holder"
  assert_contains "$out" 'refusing to release a live' "refusal wording missing"
  [ -f "$HOME_FIX/state/.lock" ] || fail "live lock file must remain"
  assert_never_two
  cleanup_holders
  pass "fm-lock release-stale refuses while a live harness holds the lock"
}

test_pre_launch_failure_leaves_zero_or_one_holder() {
  local out status=0 count
  : > "$LAUNCH_LOG"
  write_enabled_config
  write_quota "$TMP_ROOT/quota.json" 10
  write_active claude-fable
  start_fake_holder
  out=$(
    FM_HANDOFF_INJECT_FAIL=pre_launch \
    run_execute "$ROOT/bin/fm-primary-handoff.sh" execute --from claude-fable --to pi 2>&1
  ) || status=$?
  [ "$status" -ne 0 ] || fail "pre_launch failure should fail the handoff"
  assert_not_contains "$(cat "$LAUNCH_LOG")" 'launch' "pre_launch inject must block launch_incoming"
  count=$(live_holder_count)
  [ "$count" -le 1 ] || fail "pre_launch failure broke never-two invariant"
  # Outgoing was signaled and released; lock should be free (zero holders).
  [ "$count" = 0 ] || fail "expected zero live holders after release+pre_launch fail, got $count"
  assert_contains "$(cat "$HOME_FIX/state/.primary-handoff")" 'phase=failed' "should be failed"
  cleanup_holders
  pass "pre_launch failure leaves zero live holders and never dual-holds"
}

test_launch_failure_never_dual_holds() {
  local out status=0
  : > "$LAUNCH_LOG"
  write_enabled_config
  write_quota "$TMP_ROOT/quota.json" 10
  write_active claude-fable
  start_fake_holder
  out=$(
    FM_HANDOFF_INJECT_FAIL=launch \
    run_execute "$ROOT/bin/fm-primary-handoff.sh" execute --from claude-fable --to pi 2>&1
  ) || status=$?
  [ "$status" -ne 0 ] || fail "launch failure should fail"
  assert_not_contains "$(cat "$LAUNCH_LOG")" 'launch' "launch inject must not call launch seam"
  [ "$(live_holder_count)" -le 1 ] || fail "launch failure dual-held"
  [ "$(live_holder_count)" = 0 ] || fail "launch failure should leave lock free"
  assert_contains "$(cat "$HOME_FIX/state/.primary-handoff")" 'phase=failed' "should be failed"
  cleanup_holders
  pass "launch failure never creates two live holders"
}

test_check_triggers_when_over_threshold() {
  local out status=0
  : > "$SIGNAL_LOG"
  : > "$LAUNCH_LOG"
  write_enabled_config 15
  write_quota "$TMP_ROOT/quota.json" 10
  write_active claude-fable
  start_fake_holder
  out=$(run_execute "$ROOT/bin/fm-primary-handoff.sh" check 2>&1) || status=$?
  expect_code 0 "$status" "threshold check/execute should succeed: $out"
  assert_contains "$out" 'threshold crossed' "should report threshold crossed"
  assert_contains "$out" 'handed_off: claude-fable -> pi' "check should hand off to next chain profile"
  assert_never_two
  cleanup_holders
  pass "check hands off when quota is at or below threshold"
}

test_check_ok_when_under_threshold() {
  local out status=0
  : > "$LAUNCH_LOG"
  write_enabled_config 15
  write_quota "$TMP_ROOT/quota.json" 40
  write_active claude-fable
  start_fake_holder
  out=$(run_execute "$ROOT/bin/fm-primary-handoff.sh" check 2>&1) || status=$?
  expect_code 0 "$status" "under-threshold check should succeed"
  assert_contains "$out" 'handoff: ok' "should report ok"
  assert_not_contains "$(cat "$LAUNCH_LOG")" 'launch' "must not launch under threshold"
  [ "$(live_holder_count)" = 1 ] || fail "under-threshold must keep outgoing"
  cleanup_holders
  pass "check is a no-op when remaining quota is above threshold"
}

test_primary_unchanged_when_handoff_disabled() {
  local out
  rm -f "$HOME_FIX/config/primary-handoff" "$HOME_FIX/state/.primary-active"
  for cli in pi claude codex opencode grok kimi; do
    cat > "$FAKEBIN/$cli" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$FAKEBIN/$cli"
  done
  # Dry-run path must remain identical in spirit: no active marker written.
  out=$(
    PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_DRY_RUN=1 \
    "$ROOT/bin/fm-primary.sh" pi
  )
  assert_contains "$out" "'pi' '--name' 'FIRSTMATE'" "disabled handoff must not alter pi dry-run argv"
  [ ! -f "$HOME_FIX/state/.primary-active" ] || fail "dry-run must not write primary-active"
  # Real exec with disabled config must not write the marker either.
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FIX" "$ROOT/bin/fm-primary.sh" pi >/dev/null
  [ ! -f "$HOME_FIX/state/.primary-active" ] || fail "disabled handoff must not write primary-active on launch"
  # Enabled config writes the marker on real launch.
  write_enabled_config
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FIX" "$ROOT/bin/fm-primary.sh" pi >/dev/null
  [ -f "$HOME_FIX/state/.primary-active" ] || fail "enabled handoff should write primary-active"
  assert_contains "$(cat "$HOME_FIX/state/.primary-active")" 'profile=pi' "active marker profile wrong"
  rm -f "$HOME_FIX/config/primary-handoff" "$HOME_FIX/state/.primary-active"
  pass "fm-primary behavior unchanged when handoff is disabled; marker only when enabled"
}

test_concurrent_coordination_lock() {
  local status=0 out
  write_enabled_config
  write_quota "$TMP_ROOT/quota.json" 10
  write_active claude-fable
  start_fake_holder
  # Steal the coordination lock as another supervisor.
  # shellcheck source=bin/fm-wake-lib.sh
  . "$ROOT/bin/fm-wake-lib.sh"
  STATE="$HOME_FIX/state"
  fm_lock_try_acquire "$STATE/.primary-handoff.lock" || fail "could not acquire coord lock for test"
  out=$(run_execute "$ROOT/bin/fm-primary-handoff.sh" execute --from claude-fable --to pi 2>&1) || status=$?
  fm_lock_release "$STATE/.primary-handoff.lock"
  [ "$status" -ne 0 ] || fail "execute should refuse when coordination lock is held"
  assert_contains "$out" 'coordination lock' "should mention coordination lock"
  assert_not_contains "$(cat "$LAUNCH_LOG" 2>/dev/null || true)" 'launch' "racer must not launch"
  [ "$(live_holder_count)" = 1 ] || fail "racer must leave outgoing holder alone"
  assert_never_two
  cleanup_holders
  pass "coordination lock serializes supervisors without dual session-lock holders"
}

test_context_threshold_detection() {
  local out status=0
  : > "$LAUNCH_LOG"
  # Quota comfortably under threshold so only context can fire.
  write_enabled_config 15 50
  write_quota "$TMP_ROOT/quota.json" 80
  write_context_sample 40
  write_active claude-fable
  start_fake_holder
  out=$(run_execute "$ROOT/bin/fm-primary-handoff.sh" check 2>&1) || status=$?
  expect_code 0 "$status" "context threshold check should succeed: $out"
  assert_contains "$out" 'context threshold crossed' "should report context threshold"
  assert_contains "$out" 'handed_off: claude-fable -> claude-fable' "context should same-runtime rotate"
  assert_contains "$(cat "$LAUNCH_LOG")" 'launch claude-fable' "should launch same profile"
  assert_contains "$(cat "$HOME_FIX/state/.primary-handoff")" 'trigger=context' "record trigger should be context"
  assert_never_two
  cleanup_holders
  pass "context threshold detection triggers same-runtime rotation"
}

test_context_under_threshold_noop() {
  local out status=0
  : > "$LAUNCH_LOG"
  write_enabled_config 15 50
  write_quota "$TMP_ROOT/quota.json" 80
  write_context_sample 60
  write_active claude-fable
  start_fake_holder
  out=$(run_execute "$ROOT/bin/fm-primary-handoff.sh" check 2>&1) || status=$?
  expect_code 0 "$status" "under-context-threshold check should succeed"
  assert_contains "$out" 'handoff: ok' "should report ok"
  assert_not_contains "$(cat "$LAUNCH_LOG")" 'launch' "must not launch under context threshold"
  [ "$(live_holder_count)" = 1 ] || fail "under-context-threshold must keep outgoing"
  cleanup_holders
  pass "check is a no-op when context used is below threshold"
}

test_same_runtime_rotation_via_execute() {
  local out status=0 record
  : > "$SIGNAL_LOG"
  : > "$LAUNCH_LOG"
  write_enabled_config 15 50
  write_quota "$TMP_ROOT/quota.json" 80
  write_active claude-fable
  start_fake_holder
  out=$(run_execute "$ROOT/bin/fm-primary-handoff.sh" execute \
    --from claude-fable --to claude-fable --reason 'context:used=55' 2>&1) || status=$?
  expect_code 0 "$status" "same-runtime execute should succeed: $out"
  assert_contains "$out" 'handed_off: claude-fable -> claude-fable' "same-runtime handoff line"
  assert_contains "$(cat "$LAUNCH_LOG")" 'launch claude-fable' "incoming same profile"
  record=$(cat "$HOME_FIX/state/.primary-handoff")
  assert_contains "$record" 'from=claude-fable' "from wrong"
  assert_contains "$record" 'to=claude-fable' "to wrong"
  assert_contains "$record" 'trigger=context' "trigger wrong"
  assert_contains "$(cat "$HOME_FIX/state/.primary-active")" 'profile=claude-fable' "active stays same profile"
  assert_never_two
  cleanup_holders
  pass "same-runtime execute rotates claude -> claude with one live holder"
}

test_afk_refusal() {
  local out status=0
  : > "$LAUNCH_LOG"
  write_enabled_config 15 50
  write_quota "$TMP_ROOT/quota.json" 5
  write_context_sample 10
  write_active claude-fable
  start_fake_holder
  : > "$HOME_FIX/state/.afk"
  out=$(run_execute "$ROOT/bin/fm-primary-handoff.sh" check 2>&1) || status=$?
  expect_code 0 "$status" "afk check should soft-skip"
  assert_contains "$out" 'handoff: afk' "should report afk"
  assert_not_contains "$(cat "$LAUNCH_LOG")" 'launch' "afk must not launch"
  [ "$(live_holder_count)" = 1 ] || fail "afk must keep outgoing lock"
  cleanup_holders
  pass "away mode refuses automated rotation"
}

test_cooldown_prevents_busy_loop() {
  local out status=0 now
  : > "$LAUNCH_LOG"
  write_enabled_config 15 50
  write_quota "$TMP_ROOT/quota.json" 5
  write_context_sample 10
  write_active claude-fable
  now=1000
  cat > "$HOME_FIX/state/.primary-handoff" <<EOF
schema=fm-primary-handoff.v1
phase=complete
from=claude-fable
to=claude-fable
reason=context:used=60
trigger=context
token=1
outgoing_pid=1
incoming_pid=2
started_at=1
updated_at=1
error=
completed_at=900
cooldown_until=2000
EOF
  start_fake_holder
  out=$(
    FM_HANDOFF_NOW=$now \
    run_execute "$ROOT/bin/fm-primary-handoff.sh" check 2>&1
  ) || status=$?
  expect_code 0 "$status" "cooldown check should soft-skip"
  assert_contains "$out" 'handoff: cooldown' "should report cooldown"
  assert_not_contains "$(cat "$LAUNCH_LOG")" 'launch' "cooldown must not launch"
  [ "$(live_holder_count)" = 1 ] || fail "cooldown must keep outgoing"
  cleanup_holders
  pass "cooldown prevents busy-loop rotation when already over threshold"
}

test_workers_survive_rotation() {
  local out status=0
  : > "$SIGNAL_LOG"
  : > "$LAUNCH_LOG"
  write_enabled_config 15 50
  write_quota "$TMP_ROOT/quota.json" 80
  write_context_sample 40
  write_active claude-fable
  start_fake_holder
  # Worker is an independent live process with durable ownership records.
  bash -c 'while :; do sleep 5; done' worker-survives-handoff \
    </dev/null >/dev/null 2>&1 &
  FAKE_WORKER_PID=$!
  cat > "$HOME_FIX/state/worker1.meta" <<EOF
window=worker1
worktree=/tmp/worker1
project=demo
harness=claude
kind=crewmate
mode=scout
yolo=0
EOF
  printf 'working: before rotation\n' > "$HOME_FIX/state/worker1.status"
  out=$(run_execute "$ROOT/bin/fm-primary-handoff.sh" check 2>&1) || status=$?
  expect_code 0 "$status" "workers-survive check should succeed: $out"
  assert_contains "$out" 'handed_off: claude-fable -> claude-fable' "should rotate"
  kill -0 "$FAKE_WORKER_PID" 2>/dev/null || fail "worker process must still be live after rotation"
  [ -f "$HOME_FIX/state/worker1.meta" ] || fail "worker meta must remain"
  assert_contains "$(cat "$HOME_FIX/state/worker1.meta")" 'project=demo' "worker ownership meta must remain"
  assert_contains "$(cat "$HOME_FIX/state/worker1.status")" 'working: before rotation' "worker status must remain"
  assert_never_two
  cleanup_holders
  pass "workers live before rotation remain live and owned after it"
}

test_watcher_rearmed_after_handoff() {
  local out status=0
  : > "$SIGNAL_LOG"
  : > "$LAUNCH_LOG"
  write_enabled_config 15 50
  write_quota "$TMP_ROOT/quota.json" 80
  write_context_sample 40
  write_active claude-fable
  start_fake_holder
  [ ! -f "$HOME_FIX/state/.last-watcher-beat" ] || fail "precondition: no watcher beat before launch"
  out=$(run_execute "$ROOT/bin/fm-primary-handoff.sh" check 2>&1) || status=$?
  expect_code 0 "$status" "watcher-rearm check should succeed: $out"
  [ -f "$HOME_FIX/state/.last-watcher-beat" ] || fail "incoming launch must re-arm watcher beat"
  assert_never_two
  cleanup_holders
  pass "incoming primary re-arms supervision beacon after handoff"
}

test_wakes_survive_flush() {
  local out status=0 wake_line
  : > "$SIGNAL_LOG"
  : > "$LAUNCH_LOG"
  write_enabled_config 15 50
  write_quota "$TMP_ROOT/quota.json" 80
  write_context_sample 40
  write_active claude-fable
  start_fake_holder
  # Pre-seed a durable wake; flush must not drop it.
  # shellcheck source=bin/fm-wake-lib.sh
  . "$ROOT/bin/fm-wake-lib.sh"
  STATE="$HOME_FIX/state"
  FM_WAKE_QUEUE="$STATE/.wake-queue"
  FM_WAKE_QUEUE_LOCK="$STATE/.wake-queue.lock"
  fm_wake_append signal worker1 'pre-rotation wake' || fail "could not seed wake"
  wake_line=$(cat "$HOME_FIX/state/.wake-queue")
  assert_contains "$wake_line" 'pre-rotation wake' "seed wake missing"
  out=$(run_execute "$ROOT/bin/fm-primary-handoff.sh" check 2>&1) || status=$?
  expect_code 0 "$status" "wake-survival check should succeed: $out"
  [ -f "$HOME_FIX/state/.primary-handoff.flush" ] || fail "flush marker missing"
  assert_contains "$(cat "$HOME_FIX/state/.wake-queue")" 'pre-rotation wake' "wake must survive flush/rotation"
  assert_never_two
  cleanup_holders
  pass "durable wakes arriving before/during rotation are not lost"
}

test_status_bar_persists_context_sample() {
  local input out
  rm -f "$HOME_FIX/state/.primary-context"
  input='{"model":{"display_name":"Claude Fable"},"effort":{"level":"high"},"context_window":{"remaining_percentage":48.2},"rate_limits":{"five_hour":{"used_percentage":12.9}},"cost":{"total_cost_usd":1.0}}'
  out=$(
    printf '%s' "$input" | FM_HOME="$HOME_FIX" FM_PRIMARY_HARNESS=claude \
      "$ROOT/bin/fm-status-bar.sh" --adapter claude
  )
  [ -n "$out" ] || fail "status bar should still render"
  [ -f "$HOME_FIX/state/.primary-context" ] || fail "status bar must persist context sample"
  assert_contains "$(cat "$HOME_FIX/state/.primary-context")" 'remaining_percent=48' "remaining wrong"
  assert_contains "$(cat "$HOME_FIX/state/.primary-context")" 'used_percent=52' "used wrong"
  # Display still shows remaining, not used - do not restyle.
  assert_contains "$out" '🧠48%' "display remaining semantics must be unchanged"
  cleanup_holders
  pass "status bar persists context sample without changing display semantics"
}

test_context_axis_absent_is_quota_only() {
  local out status=0
  : > "$LAUNCH_LOG"
  # No threshold_context_percent_used field: context sample must be ignored.
  write_enabled_config 15
  write_quota "$TMP_ROOT/quota.json" 80
  write_context_sample 10
  write_active claude-fable
  start_fake_holder
  out=$(run_execute "$ROOT/bin/fm-primary-handoff.sh" check 2>&1) || status=$?
  expect_code 0 "$status" "quota-only check should succeed"
  assert_contains "$out" 'handoff: ok' "should report ok when only context is hot but axis disabled"
  assert_contains "$out" 'context_threshold=disabled' "should report context axis disabled"
  assert_not_contains "$(cat "$LAUNCH_LOG")" 'launch' "disabled context axis must not launch"
  cleanup_holders
  pass "absent context threshold leaves quota-only behavior"
}

test_disabled_is_noop
test_happy_path_atomic_handoff
test_flush_failure_keeps_outgoing_lock
test_signal_failure_keeps_outgoing_lock
test_wait_dead_failure_never_launches
test_release_stale_refuses_live_holder
test_pre_launch_failure_leaves_zero_or_one_holder
test_launch_failure_never_dual_holds
test_check_triggers_when_over_threshold
test_check_ok_when_under_threshold
test_primary_unchanged_when_handoff_disabled
test_concurrent_coordination_lock
test_context_threshold_detection
test_context_under_threshold_noop
test_same_runtime_rotation_via_execute
test_afk_refusal
test_cooldown_prevents_busy_loop
test_workers_survive_rotation
test_watcher_rearmed_after_handoff
test_wakes_survive_flush
test_status_bar_persists_context_sample
test_context_axis_absent_is_quota_only

printf 'All primary-handoff tests passed.\n'
