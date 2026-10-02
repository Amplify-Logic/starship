#!/usr/bin/env bash
# Behavior tests for quota-aware primary orchestrator handoff, including the
# never-two-live-session-lock-holders invariant under failure injection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-primary-handoff)
HOME_FIX="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
# run_execute pins PATH to the fakebin plus /usr/bin:/bin so the stubs and seam
# commands decide resolution. fm-primary-handoff-lib.sh reads
# config/primary-handoff with jq, which is outside that pin on Homebrew hosts,
# so link the host's own jq in rather than widening the pin. No case here
# asserts the no-jq refusal, so nothing is retired by making jq resolve.
fm_fake_real_tool "$FAKEBIN" jq || fail "jq is required to run this suite"
mkdir -p "$HOME_FIX/state" "$HOME_FIX/config" "$HOME_FIX/data"
SIGNAL_LOG="$TMP_ROOT/signal.log"
LAUNCH_LOG="$TMP_ROOT/launch.log"
HOLDER_BIN="$TMP_ROOT/harness/codex"
mkdir -p "${HOLDER_BIN%/*}"
ln -s /bin/bash "$HOLDER_BIN"
for cli in pi claude codex opencode grok agent; do
  printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/$cli"
  chmod +x "$FAKEBIN/$cli"
done

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
  "chain": ["claude-fable", "pi", "codex"]
}
JSON
  else
    cat > "$HOME_FIX/config/primary-handoff" <<JSON
{
  "enabled": true,
  "threshold_percent_remaining": $threshold,
  "poll_seconds": 60,
  "cooldown_seconds": 300,
  "chain": ["claude-fable", "pi", "codex"]
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
  printf '%s\n' "$FAKE_HOLDER_PID" >> "$HOME_FIX/holders"
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
  local holder
  : > "$HOME_FIX/unlink-go"
  : > "$HOME_FIX/ack-go"
  while IFS= read -r holder; do
    case "$holder" in ''|*[!0-9]*) continue ;; esac
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
  done < <(cat "$HOME_FIX/holders" 2>/dev/null)
  : > "$HOME_FIX/holders"
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
    "$HOME_FIX/state/.afk-contract" \
    "$HOME_FIX/state/.lock-handoff" \
    "$HOME_FIX/state/.lock-session" \
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
  printf '%s\n' "$$" >> "$HOME_FIX/holders"
  # A synthetic harness runs the real acquisition/acknowledgement path and
  # stays foreground, just as fm-primary's exec holds the launch lifetime lock.
  # shellcheck disable=SC2016 # expressions belong to the synthetic child
  exec "$HOLDER_BIN" -c '
    sleep "${FM_TEST_STARTUP_DELAY:-0}"
    if [ "${FM_TEST_UNRELATED:-0}" = 1 ]; then unset FM_HANDOFF_TOKEN; fi
    "$ROOT/bin/fm-lock.sh" || exit 1
    : > "$HOME_FIX/state/.last-watcher-beat"
    while :; do sleep 1; done
  '
}

run_execute() {
  PATH="$FAKEBIN:/usr/bin:/bin" \
  FM_HOME="$HOME_FIX" \
  FM_HANDOFF_QUOTA_JSON="$TMP_ROOT/quota.json" \
  FM_HANDOFF_SIGNAL_CMD='signal_kill' \
  FM_HANDOFF_WAIT_DEAD_CMD='wait_dead_ok' \
  FM_HANDOFF_LAUNCH_CMD='launch_incoming' \
  FM_HANDOFF_PREFLIGHT_CMD=true \
  FM_HANDOFF_STARTUP_SECS=10 \
  FM_HANDOFF_SKIP_CLI_CHECK=1 \
  FM_HANDOFF_WAIT_DEAD_SECS=3 \
  "$@"
}

# Export seam functions for eval'd command strings.
export -f signal_kill wait_dead_ok launch_incoming
export SIGNAL_LOG LAUNCH_LOG HOME_FIX FAKE_INCOMING_PID ROOT HOLDER_BIN

test_disabled_is_noop() {
  local out status=0
  : > "$LAUNCH_LOG"
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

test_disabled_force_uses_default_chain() {
  local out status=0
  : > "$LAUNCH_LOG"
  rm -f "$HOME_FIX/config/primary-handoff"
  write_active claude-fable
  start_fake_holder
  out=$(run_execute "$ROOT/bin/fm-primary-handoff.sh" execute --force 2>&1) || status=$?
  expect_code 0 "$status" "forced handoff under disabled config should use the default chain: $out"
  assert_contains "$(cat "$HOME_FIX/state/.primary-handoff")" 'to=claude-opus' "default chain successor not chosen"
  assert_contains "$(cat "$HOME_FIX/state/.primary-handoff")" 'phase=complete' "forced handoff did not complete"
  [ "$(cat "$LAUNCH_LOG")" = 'launch claude-opus' ] || fail "expected one claude-opus launch: $(cat "$LAUNCH_LOG")"
  cleanup_holders
  pass "execute --force without --to walks the default chain when handoff is disabled"
}

test_disabled_check_recovers_crashed_force() {
  local out status=0 i
  : > "$LAUNCH_LOG"
  rm -f "$HOME_FIX/config/primary-handoff"
  write_active claude-fable
  start_fake_holder
  out=$(FM_HANDOFF_INJECT_CRASH=launching run_execute \
    "$ROOT/bin/fm-primary-handoff.sh" execute --force --to pi 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "launching crash did not interrupt controller: $out"
  for i in {1..3}; do
    out=$(run_execute "$ROOT/bin/fm-primary-handoff.sh" check 2>&1) || true
    if grep -q '^phase=complete$' "$HOME_FIX/state/.primary-handoff"; then break; fi
  done
  assert_contains "$(cat "$HOME_FIX/state/.primary-handoff")" 'phase=complete' "disabled check did not recover: $out"
  [ "$(cat "$LAUNCH_LOG")" = 'launch pi' ] || fail "expected one pi launch: $(cat "$LAUNCH_LOG")"
  [ "$(live_holder_count)" = 1 ] || fail "recovery left no live owner"
  out=$(run_execute "$ROOT/bin/fm-primary-handoff.sh" check 2>&1)
  assert_contains "$out" 'handoff: disabled' "check should report disabled once reconciled"
  cleanup_holders
  pass "check reconciles a crashed forced handoff before reporting disabled"
}

test_launcher_lock_is_generation_bound() {
  local out status=0 other_pid other_lock
  : > "$LAUNCH_LOG"
  write_enabled_config
  write_active claude-fable
  start_fake_holder
  sleep 60 &
  other_pid=$!
  printf '%s\n' "$other_pid" >> "$HOME_FIX/holders"
  other_lock="$HOME_FIX/state/.primary-handoff-launch.1-2-3-4.lock"
  mkdir -p "$other_lock"
  printf '%s\n' "$other_pid" > "$other_lock/pid"
  out=$(run_execute "$ROOT/bin/fm-primary-handoff.sh" execute --to pi 2>&1) || status=$?
  expect_code 0 "$status" "first generation should complete: $out"
  out=$(run_execute "$ROOT/bin/fm-primary-handoff.sh" execute --force --to codex 2>&1) || status=$?
  expect_code 0 "$status" "live earlier launcher blocked the next generation: $out"
  assert_contains "$(cat "$HOME_FIX/state/.primary-handoff")" 'to=codex' "second generation target missing"
  assert_contains "$(cat "$HOME_FIX/state/.primary-handoff")" 'phase=complete' "second generation did not complete"
  [ "$(wc -l < "$LAUNCH_LOG" | tr -d ' ')" = 2 ] || fail "expected one launch per generation: $(cat "$LAUNCH_LOG")"
  [ "$(live_holder_count)" = 1 ] || fail "second generation left no single live owner"
  [ "$(cat "$other_lock/pid" 2>/dev/null)" = "$other_pid" ] || fail "an unrelated live generation's launch lock was removed"
  rm -rf "$other_lock"
  cleanup_holders
  pass "incoming launcher reuse and cleanup are bound to the matching generation"
}

test_recovery_preflight_failure_preserves_outgoing() {
  local out status=0
  : > "$SIGNAL_LOG"
  : > "$LAUNCH_LOG"
  write_enabled_config
  write_active claude-fable
  start_fake_holder
  FM_HANDOFF_INJECT_CRASH=releasing run_execute \
    "$ROOT/bin/fm-primary-handoff.sh" execute --to pi > "$TMP_ROOT/crash.out" 2>&1 || true
  assert_contains "$(cat "$HOME_FIX/state/.primary-handoff")" 'shutdown_requested=no' "pre-signal crash should prove no shutdown request"
  out=$(run_execute env FM_HANDOFF_PREFLIGHT_CMD=false \
    "$ROOT/bin/fm-primary-handoff.sh" check 2>&1) || status=$?
  assert_contains "$(cat "$HOME_FIX/state/.primary-handoff")" 'phase=aborted' "failed recovery preflight left the attempt nonterminal: $out"
  kill -0 "$FAKE_HOLDER_PID" || fail "failed recovery preflight stopped the outgoing primary"
  [ ! -s "$SIGNAL_LOG" ] && [ ! -s "$LAUNCH_LOG" ] || fail "failed recovery preflight signalled or launched"
  cleanup_holders
  pass "recovery preflight failure aborts while the unsignalled outgoing primary stays the owner"
}

signal_request_only() {
  printf 'signal %s\n' "$1" >> "$SIGNAL_LOG"
}
export -f signal_request_only

test_delayed_shutdown_survives_preflight_outage() {
  local out status=0 i
  : > "$SIGNAL_LOG"
  : > "$LAUNCH_LOG"
  write_enabled_config
  write_active claude-fable
  start_fake_holder
  out=$(run_execute env FM_HANDOFF_SIGNAL_CMD=signal_request_only FM_HANDOFF_WAIT_DEAD_CMD=false \
    "$ROOT/bin/fm-primary-handoff.sh" execute --to pi 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "shutdown timeout should leave the attempt pending: $out"
  [ "$(cat "$SIGNAL_LOG")" = "signal $FAKE_HOLDER_PID" ] || fail "outgoing shutdown was not requested once"
  kill -0 "$FAKE_HOLDER_PID" || fail "outgoing should still be live after the timeout"
  out=$(run_execute env FM_HANDOFF_PREFLIGHT_CMD=false \
    "$ROOT/bin/fm-primary-handoff.sh" check 2>&1) || true
  assert_contains "$(cat "$HOME_FIX/state/.primary-handoff")" 'phase=releasing' "preflight outage abandoned a signalled outgoing: $out"
  assert_contains "$(cat "$HOME_FIX/state/.primary-handoff")" 'shutdown_requested=yes' "shutdown evidence was lost"
  [ ! -s "$LAUNCH_LOG" ] || fail "preflight outage launched while the outgoing was live"
  stop_fake_holder
  for i in {1..3}; do
    out=$(run_execute "$ROOT/bin/fm-primary-handoff.sh" check 2>&1) || true
    if grep -q '^phase=complete$' "$HOME_FIX/state/.primary-handoff"; then break; fi
  done
  assert_contains "$(cat "$HOME_FIX/state/.primary-handoff")" 'phase=complete' "restored route did not replace the exited outgoing: $out"
  [ "$(cat "$LAUNCH_LOG")" = 'launch pi' ] || fail "expected exactly one replacement launch: $(cat "$LAUNCH_LOG")"
  [ "$(live_holder_count)" = 1 ] || fail "recovery left no single live owner"
  cleanup_holders
  pass "a signalled outgoing that exits after a preflight outage is replaced exactly once"
}

test_record_without_target_is_aborted() {
  local out
  : > "$LAUNCH_LOG"
  write_enabled_config
  write_active claude-fable
  start_fake_holder
  FM_HANDOFF_INJECT_CRASH=releasing run_execute \
    "$ROOT/bin/fm-primary-handoff.sh" execute --to pi > "$TMP_ROOT/crash.out" 2>&1 || true
  sed 's/^to=.*/to=/' "$HOME_FIX/state/.primary-handoff" > "$HOME_FIX/record.tmp"
  mv "$HOME_FIX/record.tmp" "$HOME_FIX/state/.primary-handoff"
  out=$(run_execute "$ROOT/bin/fm-primary-handoff.sh" check 2>&1) || true
  assert_contains "$(cat "$HOME_FIX/state/.primary-handoff")" 'phase=aborted' "targetless record stayed nonterminal: $out"
  assert_contains "$(cat "$HOME_FIX/state/.primary-handoff")" 'incomplete handoff record' "targetless record not rejected as incomplete"
  kill -0 "$FAKE_HOLDER_PID" || fail "targetless record recovery stopped the outgoing primary"
  [ ! -s "$LAUNCH_LOG" ] || fail "targetless record recovery launched"
  cleanup_holders
  pass "a handoff record without a target is aborted rather than retried forever"
}

test_recover_only_never_starts_rotation() {
  local out status=0
  : > "$SIGNAL_LOG"
  : > "$LAUNCH_LOG"
  write_enabled_config
  write_quota "$TMP_ROOT/quota.json" 5
  write_active claude-fable
  start_fake_holder
  out=$(run_execute "$ROOT/bin/fm-primary-handoff.sh" execute --recover-only 2>&1) || status=$?
  expect_code 0 "$status" "recover-only with nothing to recover should succeed: $out"
  [ ! -s "$SIGNAL_LOG" ] && [ ! -s "$LAUNCH_LOG" ] || fail "recover-only started a fresh rotation"
  [ ! -f "$HOME_FIX/state/.primary-handoff" ] || fail "recover-only planned a new handoff record"
  kill -0 "$FAKE_HOLDER_PID" || fail "recover-only stopped the healthy primary"
  cleanup_holders
  pass "recovery-only dispatch never falls through into a fresh rotation"
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
  assert_contains "$(cat "$HOME_FIX/state/.primary-handoff")" 'phase=releasing' "timeout must stay recoverable"
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

# L1 fails closed on purpose. Every other fork hook degrades to upstream
# behaviour when its fork file is gone; this one must refuse instead, because
# the upstream-equivalent fallthrough would remove a lock a live primary may
# still hold and put two primaries on one home. Pinned here so the exception
# cannot be quietly turned into a fallthrough later.
test_release_stale_fails_closed_without_the_fork_library() {
  local out status=0 degraded
  mkdir -p "$HOME_FIX/state"
  printf '%s\n' 999999 > "$HOME_FIX/state/.lock"
  degraded="$TMP_ROOT/degraded"
  rm -rf "$degraded"
  mkdir -p "$degraded/bin"
  cp "$ROOT/bin/fm-lock.sh" "$ROOT/bin/fm-primary-scope-lib.sh" "$degraded/bin/"
  chmod +x "$degraded/bin/fm-lock.sh"
  [ ! -e "$degraded/bin/fm-primary-handoff-lib.sh" ] \
    || fail "the degraded tree must not contain the fork library"
  out=$(FM_HOME="$HOME_FIX" "$degraded/bin/fm-lock.sh" release-stale 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "release-stale must refuse when the fork library is absent"
  assert_contains "$out" 'needs bin/fm-primary-handoff-lib.sh' \
    "the refusal must name the missing fork file"
  [ -f "$HOME_FIX/state/.lock" ] \
    || fail "a refused release-stale must leave the lock file in place"
  [ "$(cat "$HOME_FIX/state/.lock")" = 999999 ] \
    || fail "a refused release-stale must not rewrite the lock"
  cleanup_holders
  pass "fm-lock release-stale fails closed when bin/fm-primary-handoff-lib.sh is absent"
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
  assert_contains "$(cat "$HOME_FIX/state/.primary-handoff")" 'phase=launching' "should remain recoverable"
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
  assert_contains "$(cat "$HOME_FIX/state/.primary-handoff")" 'phase=launching' "should remain recoverable"
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
  for cli in pi claude codex opencode grok; do
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
  local out marker command status
  for marker in .afk .afk-contract; do
    for command in check execute; do
      : > "$LAUNCH_LOG"
      : > "$SIGNAL_LOG"
      write_enabled_config 15 50
      write_quota "$TMP_ROOT/quota.json" 5
      write_context_sample 10
      write_active claude-fable
      start_fake_holder
      : > "$HOME_FIX/state/$marker"
      status=0
      out=$(run_execute "$ROOT/bin/fm-primary-handoff.sh" "$command" 2>&1) || status=$?
      expect_code 0 "$status" "$marker $command should soft-skip: $out"
      [ ! -s "$LAUNCH_LOG" ] && [ ! -s "$SIGNAL_LOG" ] || fail "$marker must prevent launch and signal"
      [ "$(cat "$HOME_FIX/state/.lock")" = "$FAKE_HOLDER_PID" ] || fail "away must keep outgoing lock"
      cleanup_holders
    done
  done
  pass "canonical away contract and legacy quiet flag refuse check and execute"
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
  # Display shows used % (rising); sample still stores remaining and derived used.
  assert_contains "$out" '🧠52%' "display must show context used derived from remaining"
  cleanup_holders
  pass "status bar persists context sample while displaying used percent"
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

write_exhausted_chain_config() {
  cat > "$HOME_FIX/config/primary-handoff" <<JSON
{
  "enabled": true,
  "threshold_percent_remaining": 15,
  "threshold_context_percent_used": 50,
  "poll_seconds": 60,
  "cooldown_seconds": 300,
  "chain": ["claude-fable", "claude-opus"]
}
JSON
}

test_check_stays_put_when_chain_exhausted() {
  local out status=0
  : > "$LAUNCH_LOG"
  : > "$SIGNAL_LOG"
  write_exhausted_chain_config
  write_quota "$TMP_ROOT/quota.json" 10
  write_context_sample 80
  write_active claude-opus
  start_fake_holder
  out=$(run_execute "$ROOT/bin/fm-primary-handoff.sh" check 2>&1) || status=$?
  expect_code 0 "$status" "exhausted-chain check must not fail: $out"
  assert_contains "$out" 'handoff: chain exhausted profile=claude-opus' "should report chain exhausted"
  assert_not_contains "$out" 'no usable next profile' "must not log a failure every poll"
  assert_not_contains "$out" 'threshold crossed' "must not start a rotation without a successor"
  assert_not_contains "$(cat "$LAUNCH_LOG")" 'launch' "must not launch when chain is exhausted"
  [ "$(live_holder_count)" = 1 ] || fail "exhausted chain must keep the outgoing holder"
  [ ! -f "$HOME_FIX/state/.primary-handoff" ] || \
    assert_not_contains "$(cat "$HOME_FIX/state/.primary-handoff")" 'phase=failed' "must not record a failed phase"
  cleanup_holders
  pass "check stays put quietly when the chain has no distinct successor"
}

test_check_context_refresh_when_chain_exhausted() {
  local out status=0
  : > "$LAUNCH_LOG"
  : > "$SIGNAL_LOG"
  write_exhausted_chain_config
  write_quota "$TMP_ROOT/quota.json" 10
  write_context_sample 40
  write_active claude-opus
  start_fake_holder
  out=$(run_execute "$ROOT/bin/fm-primary-handoff.sh" check 2>&1) || status=$?
  expect_code 0 "$status" "exhausted-chain context refresh should succeed: $out"
  assert_contains "$out" 'handoff: chain exhausted profile=claude-opus' "should report chain exhausted"
  assert_contains "$out" 'context threshold crossed' "context axis must still fire"
  assert_contains "$out" 'handed_off: claude-opus -> claude-opus' "should same-runtime refresh claude-opus"
  assert_contains "$(cat "$LAUNCH_LOG")" 'launch claude-opus' "should relaunch the same profile"
  assert_contains "$(cat "$HOME_FIX/state/.primary-handoff")" 'trigger=context' "record trigger should be context"
  assert_not_contains "$out" 'no usable next profile' "must not log a quota failure"
  assert_never_two
  cleanup_holders
  pass "exhausted chain still allows a same-profile context refresh"
}

test_claude_opus_chain_profile() {
  local next opus_alias
  next=$(
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-primary-handoff-lib.sh"
    FM_HANDOFF_SKIP_CLI_CHECK=1 fm_handoff_next_profile claude-fable '["claude-fable","claude-opus"]'
  )
  [ "$next" = claude-opus ] || fail "handoff chain did not accept claude-opus after claude-fable"
  opus_alias=$(
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-primary-handoff-lib.sh"
    fm_handoff_normalize_profile opus
  )
  [ "$opus_alias" = claude-opus ] || fail "handoff did not normalize the opus launcher alias"
  pass "handoff accepts claude-opus and the opus alias as launcher profiles"
}

test_astra_registered_profile() {
  local norm cli provider remaining next chain default_config="$TMP_ROOT/astra-default-config"
  mkdir -p "$default_config"
  printf '{"enabled":true}\n' > "$default_config/primary-handoff"
  norm=$(
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-primary-handoff-lib.sh"
    fm_handoff_normalize_profile astra
  )
  [ "$norm" = astra ] || fail "handoff did not accept astra as a launcher profile"
  cli=$(
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-primary-handoff-lib.sh"
    fm_handoff_profile_cli astra
  )
  [ "$cli" = codex ] || fail "handoff did not map astra to the codex CLI"
  provider=$(
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-primary-handoff-lib.sh"
    fm_handoff_profile_provider astra
  )
  [ "$provider" = codex ] || fail "handoff did not map astra to the codex quota provider"
  write_quota "$TMP_ROOT/quota-astra.json" 10
  remaining=$(
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-primary-handoff-lib.sh"
    FM_HANDOFF_QUOTA_JSON="$TMP_ROOT/quota-astra.json" \
      fm_handoff_min_remaining_for_profile astra
  )
  [ "$remaining" = 90 ] || fail "astra did not read the codex quota windows: $remaining"
  next=$(
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-primary-handoff-lib.sh"
    FM_HANDOFF_SKIP_CLI_CHECK=1 fm_handoff_next_profile claude-fable '["claude-fable","astra"]'
  )
  [ "$next" = astra ] || fail "handoff chain did not accept an explicitly configured astra successor"
  chain=$(
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-primary-handoff-lib.sh"
    FM_CONFIG_OVERRIDE="$default_config" fm_handoff_load_config >/dev/null 2>&1
    printf '%s\n' "$FM_HANDOFF_CHAIN_JSON"
  )
  [ "$chain" = '["claude-fable","claude-opus","pi","codex"]' ] || \
    fail "default rotation chain changed: $chain"
  pass "handoff registers astra on the codex CLI and quota pool without joining the default chain"
}

test_cursor_grok_quota_monitored() {
  local norm cli provider remaining unmonitored
  norm=$(
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-primary-handoff-lib.sh"
    fm_handoff_normalize_profile cursor
  )
  [ "$norm" = cursor-grok ] || fail "handoff did not normalize the cursor launcher alias"
  cli=$(
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-primary-handoff-lib.sh"
    fm_handoff_profile_cli cursor-grok
  )
  [ "$cli" = agent ] || fail "handoff did not map cursor-grok to the agent CLI"
  provider=$(
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-primary-handoff-lib.sh"
    fm_handoff_profile_provider cursor-grok
  )
  [ "$provider" = cursor ] || fail "handoff did not map cursor-grok to the cursor quota provider"
  cat > "$TMP_ROOT/quota-cursor.json" <<'JSON'
{
  "providers": [
    {
      "provider": "cursor",
      "state": { "status": "fresh" },
      "windows": [
        { "id": "included_usage", "kind": "monthly", "percentRemaining": 26 },
        { "id": "auto_usage", "kind": "monthly", "percentRemaining": 24 },
        { "id": "api_usage", "kind": "monthly", "percentRemaining": 5 },
        { "id": "grok_bot", "kind": "weekly", "percentRemaining": 3 }
      ]
    }
  ]
}
JSON
  remaining=$(
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-primary-handoff-lib.sh"
    FM_HANDOFF_QUOTA_JSON="$TMP_ROOT/quota-cursor.json" \
      fm_handoff_min_remaining_for_profile cursor-grok
  )
  [ "$remaining" = 24 ] || \
    fail "cursor-grok did not read only the general cursor plan windows: $remaining"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-primary-handoff-lib.sh"
    FM_HANDOFF_QUOTA_JSON="$TMP_ROOT/quota-cursor.json" \
      fm_handoff_over_threshold cursor-grok 30
  ) || fail "cursor-grok did not trip the quota threshold from its plan windows"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-primary-handoff-lib.sh"
    FM_HANDOFF_QUOTA_JSON="$TMP_ROOT/quota-cursor.json" \
      fm_handoff_over_threshold cursor-grok 10
  ) && fail "cursor-grok tripped the quota threshold while it still had headroom"
  unmonitored=$(
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-primary-handoff-lib.sh"
    FM_HANDOFF_QUOTA_JSON="$TMP_ROOT/quota-cursor.json" \
      fm_handoff_min_remaining_for_profile pi
  )
  [ "$unmonitored" = na ] || fail "pi reported a quota window while unmonitored: $unmonitored"
  pass "handoff reads cursor-grok quota from the general cursor plan windows only"
}

test_fable_model_window_rotates_to_opus() {
  local out status=0 fable opus
  : > "$LAUNCH_LOG"
  : > "$SIGNAL_LOG"
  cat > "$TMP_ROOT/quota.json" <<'JSON'
{
  "providers": [
    {
      "provider": "claude",
      "state": { "status": "fresh" },
      "windows": [
        { "id": "five_hour", "kind": "session", "percentRemaining": 80 },
        { "id": "seven_day", "kind": "weekly", "percentRemaining": 70 },
        { "id": "model:fable", "kind": "model", "percentRemaining": 10 },
        { "id": "model:other", "kind": "model", "percentRemaining": 2 }
      ]
    }
  ]
}
JSON
  fable=$(
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-primary-handoff-lib.sh"
    FM_HANDOFF_QUOTA_JSON="$TMP_ROOT/quota.json" fm_handoff_min_remaining_for_profile claude-fable
  )
  [ "$fable" = 10 ] || fail "claude-fable did not read its Fable model window: $fable"
  opus=$(
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-primary-handoff-lib.sh"
    FM_HANDOFF_QUOTA_JSON="$TMP_ROOT/quota.json" fm_handoff_min_remaining_for_profile claude-opus
  )
  [ "$opus" = 70 ] || fail "claude-opus did not read only the general claude windows: $opus"
  write_exhausted_chain_config
  write_context_sample 80
  write_active claude-fable
  start_fake_holder
  out=$(run_execute "$ROOT/bin/fm-primary-handoff.sh" check 2>&1) || status=$?
  expect_code 0 "$status" "Fable model-window check should succeed: $out"
  assert_contains "$out" 'threshold crossed profile=claude-fable min_remaining=10' "Fable window should cross the threshold"
  assert_contains "$out" 'handed_off: claude-fable -> claude-opus' "Fable exhaustion should hand off to claude-opus"
  assert_never_two
  cleanup_holders
  pass "Fable model-window exhaustion rotates claude-fable to claude-opus"
}

# F1: stop precisely at unlink, then exercise a real competing acquisition.
test_stale_release_serializes_acquisition() {
  local release_pid acquire_pid i
  rm -f "$HOME_FIX/unlink-go" "$HOME_FIX/unlink-ready"
  printf '999999\n' > "$HOME_FIX/state/.lock"
  printf 'old-session\n' > "$HOME_FIX/state/.lock-session"
  cat > "$FAKEBIN/rm" <<'SH'
#!/bin/bash
if [ "${2:-}" = "$HOME_FIX/state/.lock" ]; then
  : > "$HOME_FIX/unlink-ready"
  while [ ! -f "$HOME_FIX/unlink-go" ]; do sleep 0.1; done
fi
exec /bin/rm "$@"
SH
  chmod +x "$FAKEBIN/rm"
  PATH="$FAKEBIN:/usr/bin:/bin" FM_HOME="$HOME_FIX" \
    "$ROOT/bin/fm-lock.sh" release-stale > "$TMP_ROOT/release.out" 2>&1 &
  release_pid=$!
  for i in {1..100}; do [ ! -f "$HOME_FIX/unlink-ready" ] || break; sleep 0.1; done
  [ -f "$HOME_FIX/unlink-ready" ] || fail "release never reached unlink"
  # shellcheck disable=SC2016 # expressions belong to the synthetic child
  FM_HOME="$HOME_FIX" "$HOLDER_BIN" -c '
    "$ROOT/bin/fm-lock.sh" > "$HOME_FIX/acquire.out" || exit 1
    : > "$HOME_FIX/acquired"
    while :; do sleep 1; done
  ' &
  acquire_pid=$!
  printf '%s\n' "$acquire_pid" >> "$HOME_FIX/holders"
  sleep 0.3
  [ ! -f "$HOME_FIX/acquired" ] || fail "acquisition bypassed stale-release mutex"
  : > "$HOME_FIX/unlink-go"
  wait "$release_pid" || fail "stale release failed"
  for i in {1..100}; do [ ! -f "$HOME_FIX/acquired" ] || break; sleep 0.1; done
  [ -f "$HOME_FIX/acquired" ] || fail "acquisition did not finish"
  [ "$(cat "$HOME_FIX/state/.lock")" = "$acquire_pid" ] || fail "stale release removed new owner"
  [ ! -e "$HOME_FIX/state/.lock-session" ] || fail "old session identity survived release"
  rm -f "$FAKEBIN/rm"
  cleanup_holders
  pass "stale release excludes concurrent acquisition through unlink and identity cleanup"
}

test_preflight_preserves_outgoing() {
  local mode out status
  for mode in route custom cli config account; do
    : > "$SIGNAL_LOG"
    : > "$LAUNCH_LOG"
    write_enabled_config
    write_active claude-fable
    start_fake_holder
    status=0
    case "$mode" in
      custom)
        out=$(run_execute env FM_HANDOFF_LAUNCH_CMD=missing-handoff-command \
          "$ROOT/bin/fm-primary-handoff.sh" execute --to pi 2>&1) || status=$?
        ;;
      route)
        out=$(run_execute env -u TMUX -u FM_HANDOFF_LAUNCH_CMD \
          "$ROOT/bin/fm-primary-handoff.sh" execute --to pi 2>&1) || status=$?
        ;;
      cli)
        mv "$FAKEBIN/pi" "$FAKEBIN/pi.saved"
        out=$(run_execute "$ROOT/bin/fm-primary-handoff.sh" execute --to pi 2>&1) || status=$?
        mv "$FAKEBIN/pi.saved" "$FAKEBIN/pi"
        ;;
      config)
        printf 'invalid\n' > "$HOME_FIX/config/primary-effort"
        out=$(run_execute "$ROOT/bin/fm-primary-handoff.sh" execute --to claude-opus 2>&1) || status=$?
        rm -f "$HOME_FIX/config/primary-effort"
        ;;
      account)
        printf '#!/bin/sh\necho "Not logged in" >&2\nexit 1\n' > "$FAKEBIN/codex"
        out=$(run_execute "$ROOT/bin/fm-primary-handoff.sh" execute --to codex 2>&1) || status=$?
        printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/codex"
        ;;
    esac
    [ "$status" -ne 0 ] || fail "$mode preflight should refuse: $out"
    [ ! -s "$SIGNAL_LOG" ] && [ ! -s "$LAUNCH_LOG" ] || fail "$mode preflight stopped outgoing"
    kill -0 "$FAKE_HOLDER_PID" || fail "$mode killed outgoing"
    cleanup_holders
  done
  pass "route, explicit target CLI, configuration, and account fail before outgoing signal"
}

test_delayed_ack_and_recovery() {
  local out status=0
  : > "$LAUNCH_LOG"
  write_enabled_config
  write_active claude-fable
  start_fake_holder
  out=$(FM_TEST_STARTUP_DELAY=1 run_execute "$ROOT/bin/fm-primary-handoff.sh" execute --to pi 2>&1) || status=$?
  expect_code 0 "$status" "delayed startup must complete: $out"
  assert_contains "$(cat "$HOME_FIX/state/.primary-handoff")" 'phase=complete' "delayed startup never completed"
  [ "$(wc -l < "$LAUNCH_LOG" | tr -d ' ')" = 1 ] || fail "delayed startup launched twice"
  out=$(run_execute "$ROOT/bin/fm-primary-handoff.sh" check 2>&1)
  assert_contains "$out" 'cooldown' "completed recovery lacks cooldown"
  cleanup_holders
  pass "delayed launch waits for a bound live-owner acknowledgement exactly once"
}

test_crash_recovery() {
  local crash out status i
  for crash in planning flushing releasing launching complete post_launch; do
    : > "$LAUNCH_LOG"
    write_enabled_config
    write_quota "$TMP_ROOT/quota.json" 5
    write_active claude-fable
    start_fake_holder
    status=0
    if [ "$crash" = post_launch ]; then
      out=$(FM_HANDOFF_INJECT_FAIL=post_launch run_execute \
        "$ROOT/bin/fm-primary-handoff.sh" execute --to pi 2>&1) || status=$?
    else
      out=$(FM_HANDOFF_INJECT_CRASH=$crash run_execute \
        "$ROOT/bin/fm-primary-handoff.sh" execute --to pi 2>&1) || status=$?
    fi
    [ "$status" -ne 0 ] || fail "$crash did not interrupt controller: $out"
    # A launcher may still be acquiring while the restarted controller runs.
    for i in {1..3}; do
      out=$(run_execute "$ROOT/bin/fm-primary-handoff.sh" check 2>&1) || true
      if grep -q '^phase=complete$' "$HOME_FIX/state/.primary-handoff"; then break; fi
    done
    assert_contains "$(cat "$HOME_FIX/state/.primary-handoff")" 'phase=complete' "$crash did not recover: $out"
    [ "$(wc -l < "$LAUNCH_LOG" | tr -d ' ')" = 1 ] || fail "$crash duplicated incoming launch"
    [ "$(live_holder_count)" = 1 ] || fail "$crash left no live owner"
    kill -0 "$FAKE_HOLDER_PID" 2>/dev/null && fail "$crash left outgoing live with incoming"
    cleanup_holders
  done
  pass "controller death at each durable phase and after dispatch recovers with one launch"
}

test_unrelated_owner_is_not_acknowledged() {
  local out status=0 i
  : > "$LAUNCH_LOG"
  : > "$SIGNAL_LOG"
  write_enabled_config
  write_active claude-fable
  start_fake_holder
  out=$(FM_TEST_UNRELATED=1 run_execute env FM_HANDOFF_STARTUP_SECS=1 \
    "$ROOT/bin/fm-primary-handoff.sh" execute --to pi 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "unbound incoming was acknowledged: $out"
  assert_contains "$(cat "$HOME_FIX/state/.primary-handoff")" 'phase=launching' "timeout lost recovery record"
  : > "$SIGNAL_LOG"
  for i in {1..3}; do
    out=$(run_execute env FM_HANDOFF_STARTUP_SECS=1 "$ROOT/bin/fm-primary-handoff.sh" check 2>&1) || true
    if grep -q '^phase=aborted$' "$HOME_FIX/state/.primary-handoff"; then break; fi
  done
  assert_contains "$out" 'unrelated live owner' "recovery did not reject foreign owner"
  [ ! -s "$SIGNAL_LOG" ] || fail "recovery signalled unrelated owner"
  [ "$(wc -l < "$LAUNCH_LOG" | tr -d ' ')" = 1 ] || fail "recovery launched over unrelated owner"
  cleanup_holders
  pass "an unrelated live owner cannot satisfy startup acknowledgement or be stopped by recovery"
}

test_pending_startup_reuses_launcher() {
  local out status=0
  : > "$LAUNCH_LOG"
  write_enabled_config
  write_active claude-fable
  start_fake_holder
  out=$(FM_TEST_STARTUP_DELAY=3 run_execute env FM_HANDOFF_STARTUP_SECS=1 \
    "$ROOT/bin/fm-primary-handoff.sh" execute --to pi 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "pending startup did not time out: $out"
  assert_contains "$(cat "$HOME_FIX/state/.primary-handoff")" 'phase=launching' "timeout must stay recoverable"
  status=0
  out=$(run_execute "$ROOT/bin/fm-primary-handoff.sh" check 2>&1) || status=$?
  expect_code 0 "$status" "pending launcher did not recover: $out"
  assert_contains "$(cat "$HOME_FIX/state/.primary-handoff")" 'phase=complete' "pending launch not completed"
  [ "$(wc -l < "$LAUNCH_LOG" | tr -d ' ')" = 1 ] || fail "pending launcher was duplicated"
  cleanup_holders
  pass "startup timeout retains recovery and reuses the existing launcher"
}

test_reused_outgoing_identity_is_not_signalled() {
  local out status=0
  : > "$SIGNAL_LOG"
  : > "$LAUNCH_LOG"
  write_enabled_config
  write_active claude-fable
  start_fake_holder
  FM_HANDOFF_INJECT_CRASH=releasing run_execute \
    "$ROOT/bin/fm-primary-handoff.sh" execute --to pi > "$TMP_ROOT/crash.out" 2>&1 || true
  # Model PID reuse without ever signalling an unrelated real process.
  sed 's/^outgoing_identity=.*/outgoing_identity=different-incarnation/' \
    "$HOME_FIX/state/.primary-handoff" > "$HOME_FIX/record.tmp"
  mv "$HOME_FIX/record.tmp" "$HOME_FIX/state/.primary-handoff"
  out=$(run_execute "$ROOT/bin/fm-primary-handoff.sh" execute --force 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "reused PID should refuse even with force: $out"
  [ ! -s "$SIGNAL_LOG" ] && [ ! -s "$LAUNCH_LOG" ] || fail "reused PID was signalled or launched over"
  cleanup_holders
  pass "recovery checks outgoing process identity even under force"
}

test_tmux_route_carries_acknowledgement() {
  local out status=0
  : > "$LAUNCH_LOG"
  write_enabled_config
  write_active claude-fable
  start_fake_holder
  cat > "$FAKEBIN/tmux" <<'SH'
#!/bin/bash
case "$1" in
  display-message) printf 'fixture-session\n' ;;
  new-window) bash -c "$5" </dev/null >/dev/null 2>&1 & ;;
  *) exit 1 ;;
esac
SH
  cat > "$FAKEBIN/pi" <<'SH'
#!/bin/bash
printf 'launch pi\n' >> "$LAUNCH_LOG"
printf '%s\n' "$$" >> "$HOME_FIX/holders"
exec "$HOLDER_BIN" -c '
  sleep 1
  "$ROOT/bin/fm-lock.sh" || exit 1
  while :; do sleep 1; done
'
SH
  chmod +x "$FAKEBIN/tmux" "$FAKEBIN/pi"
  out=$(run_execute env -u FM_HANDOFF_LAUNCH_CMD -u TMUX_PANE -u HERDR_PANE_ID TMUX=fixture \
    "$ROOT/bin/fm-primary-handoff.sh" execute --to pi 2>&1) || status=$?
  expect_code 0 "$status" "stubbed tmux route did not finish: $out"
  assert_contains "$(cat "$HOME_FIX/state/.primary-handoff")" 'phase=complete' "tmux route did not acknowledge"
  [ "$(wc -l < "$LAUNCH_LOG" | tr -d ' ')" = 1 ] || fail "tmux route launched more than once"
  cleanup_holders
  rm -f "$FAKEBIN/tmux"
  printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/pi"
  pass "tmux dispatch through the real primary launcher carries a bound acquisition acknowledgement"
}

test_recovery_waits_for_inflight_ack_publication() {
  local out recovery_pid i
  : > "$LAUNCH_LOG"
  write_enabled_config
  write_active claude-fable
  start_fake_holder
  rm -f "$HOME_FIX/ack-go" "$HOME_FIX/ack-ready"
  cat > "$FAKEBIN/mv" <<'SH'
#!/bin/bash
if [ "${2:-}" = "$HOME_FIX/state/.lock-handoff" ]; then
  : > "$HOME_FIX/ack-ready"
  while [ ! -f "$HOME_FIX/ack-go" ]; do sleep 0.1; done
fi
exec /bin/mv "$@"
SH
  chmod +x "$FAKEBIN/mv"
  FM_HANDOFF_INJECT_FAIL=post_launch run_execute \
    "$ROOT/bin/fm-primary-handoff.sh" execute --to pi > "$TMP_ROOT/dispatch.out" 2>&1 || true
  for i in {1..100}; do [ ! -f "$HOME_FIX/ack-ready" ] || break; sleep 0.1; done
  [ -f "$HOME_FIX/ack-ready" ] || fail "incoming never reached acknowledgement publication"
  run_execute "$ROOT/bin/fm-primary-handoff.sh" check > "$TMP_ROOT/recover.out" 2>&1 &
  recovery_pid=$!
  sleep 0.3
  assert_contains "$(cat "$HOME_FIX/state/.primary-handoff")" 'phase=launching' "recovery misclassified an acquisition still publishing its receipt"
  : > "$HOME_FIX/ack-go"
  wait "$recovery_pid" || fail "recovery failed: $(cat "$TMP_ROOT/recover.out")"
  out=$(cat "$HOME_FIX/state/.primary-handoff")
  assert_contains "$out" 'phase=complete' "recovery never acknowledged completed publication"
  [ "$(wc -l < "$LAUNCH_LOG" | tr -d ' ')" = 1 ] || fail "ack publication race duplicated launch"
  rm -f "$FAKEBIN/mv"
  cleanup_holders
  pass "recovery waits for an in-flight acquisition receipt without aborting or launching twice"
}

test_recovery_waits_for_inflight_ack_publication

test_tmux_route_carries_acknowledgement

test_pending_startup_reuses_launcher
test_reused_outgoing_identity_is_not_signalled

test_stale_release_serializes_acquisition
test_preflight_preserves_outgoing
test_delayed_ack_and_recovery
test_crash_recovery
test_unrelated_owner_is_not_acknowledged

test_disabled_is_noop
test_disabled_force_uses_default_chain
test_disabled_check_recovers_crashed_force
test_launcher_lock_is_generation_bound
test_recovery_preflight_failure_preserves_outgoing
test_delayed_shutdown_survives_preflight_outage
test_record_without_target_is_aborted
test_recover_only_never_starts_rotation
test_astra_registered_profile
test_cursor_grok_quota_monitored
test_happy_path_atomic_handoff
test_flush_failure_keeps_outgoing_lock
test_signal_failure_keeps_outgoing_lock
test_wait_dead_failure_never_launches
test_release_stale_refuses_live_holder
test_release_stale_fails_closed_without_the_fork_library
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
test_claude_opus_chain_profile
test_check_stays_put_when_chain_exhausted
test_check_context_refresh_when_chain_exhausted
test_fable_model_window_rotates_to_opus

printf 'All primary-handoff tests passed.\n'
