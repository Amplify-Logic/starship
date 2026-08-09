#!/usr/bin/env bash
# Behavior tests for Claude's narrowly scoped watcher-continuity PreToolUse gate.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-continuity-pretool-check.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-continuity-pretool-tests)
PRIMARY="$TMP_ROOT/primary"
STATE="$PRIMARY/state"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"

mkdir -p "$PRIMARY/bin" "$STATE"
printf '# fixture\n' > "$PRIMARY/AGENTS.md"
git -C "$PRIMARY" init -q

run_command() {
  local command=$1 rc=0
  : > "$OUT"
  : > "$ERR"
  FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
    "$CHECK" --command "$command" > "$OUT" 2> "$ERR" || rc=$?
  return "$rc"
}

expect_allow() {
  local label=$1 command=$2 rc=0
  run_command "$command" || rc=$?
  [ "$rc" -eq 0 ] || fail "$label must allow, got exit $rc: $(cat "$ERR")"
  [ ! -s "$OUT" ] || fail "$label allow wrote stdout: $(cat "$OUT")"
  [ ! -s "$ERR" ] || fail "$label allow wrote stderr: $(cat "$ERR")"
}

expect_deny() {
  local label=$1 command=$2 blocked=$3 expected=${4:-} rc=0 actual
  run_command "$command" || rc=$?
  [ "$rc" -eq 2 ] || fail "$label must deny with exit 2, got $rc"
  [ ! -s "$OUT" ] || fail "$label deny wrote stdout: $(cat "$OUT")"
  jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "deny"' "$ERR" >/dev/null 2>&1 \
    || fail "$label deny omitted Claude's permission decision: $(cat "$ERR")"
  [ -n "$expected" ] || expected="[watcher-continuity] SUPERVISION OUTAGE: down for unknown duration (unknown since when; watcher beat file missing or unreadable); 1 task(s) in flight: task. No live watcher holds this home lock. Drain wakes with bin/fm-wake-drain.sh, the safe mid-session action; run the once-per-session bin/fm-session-start.sh instead only if you have not already run it earlier this session; use fail-closed bin/fm-teardown.sh for completed tasks when needed, then re-arm with bin/fm-watch-arm.sh as a tracked Claude background task before running other fleet commands (blocked: $blocked)"
  actual=$(jq -r '.systemMessage' "$ERR")
  [ "$actual" = "$expected" ] || fail "$label recovery guidance changed: $actual"
}

test_gate_scope_and_recovery_exceptions() {
  expect_allow "idle fleet command" 'bin/fm-crew-state.sh task'
  printf 'project=fixture\n' > "$STATE/task.meta"

  expect_allow "ordinary shell command" 'git status --short'
  expect_allow "fleet-script text as data" "rg -n 'bin/fm-send.sh' docs"
  expect_allow "session start recovery" 'bin/fm-session-start.sh'
  expect_allow "wake drain recovery" 'bin/fm-wake-drain.sh'
  expect_allow "watch arm recovery" 'bin/fm-watch-arm.sh'
  expect_allow "drain then arm recovery" 'bin/fm-wake-drain.sh; bin/fm-watch-arm.sh'
  expect_allow "fail-closed teardown recovery" 'bin/fm-teardown.sh task'
  unsafe_teardown_reason='[watcher-continuity] SUPERVISION OUTAGE: down for unknown duration (unknown since when; watcher beat file missing or unreadable); 1 task(s) in flight: task. No live watcher holds this home lock. During recovery only the ordinary literal bin/fm-teardown.sh is allowed, so drop --force and any shell-expanded arguments and retry the literal invocation (blocked: fm-teardown.sh)'
  expect_deny "forced teardown is not recovery" 'bin/fm-teardown.sh task --force' 'fm-teardown.sh' "$unsafe_teardown_reason"
  expect_deny "nested forced teardown is not recovery" "bash -lc 'bin/fm-teardown.sh task --force'" 'fm-teardown.sh' "$unsafe_teardown_reason"
  # shellcheck disable=SC2016  # single quotes are deliberate: "$TEARDOWN_MODE" is literal test data (an unsafe shell-expanded arg the gate must deny), not an expansion here
  expect_deny "dynamic teardown mode is not recovery" 'bin/fm-teardown.sh task "$TEARDOWN_MODE"' 'fm-teardown.sh' "$unsafe_teardown_reason"
  expect_deny "unrelated fleet command" 'bin/fm-crew-state.sh task' 'fm-crew-state.sh'
  expect_deny "recovery bundled with unrelated fleet command" 'bin/fm-wake-drain.sh; bin/fm-send.sh task hi' 'fm-send.sh'
  # The two denies below, read together with the "session start recovery" allow
  # above, assert the direct-versus-transitive bootstrap boundary so no one
  # assertion reads as contradicting another. The gate classifies the
  # command words it is handed, so every bin/fm-bootstrap.sh in executed
  # position denies, bundled after session start or nested in a literal shell
  # payload alike. The bin/fm-bootstrap.sh that the allowed
  # bin/fm-session-start.sh above runs inside its own process is not a command
  # word this gate sees; permitting it is inherent to allowing the composing
  # recovery script, not a classifier feature, and fm-session-start.sh gates
  # those mutating sweeps on first holding the per-home session lock.
  expect_deny "literal nested fleet command" "bash -lc 'bin/fm-bootstrap.sh'" 'fm-bootstrap.sh'
  expect_deny "direct bootstrap bundled after session start" 'bin/fm-session-start.sh; bin/fm-bootstrap.sh' 'fm-bootstrap.sh'
  pass "continuity gate allows recovery and ordinary commands but denies only other fleet execution"
}

# Every deny above ran with no state/.lock at all, the genuine pre-lock case, so
# each asserted the guidance that names the once-per-session entry point. With
# this test's own pid recorded as the lock holder, the gate's ancestry walk
# resolves the holder inside the hook's own process ancestry and drops that
# clause instead of inviting an out-of-contract mid-session re-run.
test_lock_holding_session_gets_guidance_without_session_start() {
  local held_reason
  printf '%s\n' "$$" > "$STATE/.lock"
  held_reason='[watcher-continuity] SUPERVISION OUTAGE: down for unknown duration (unknown since when; watcher beat file missing or unreadable); 1 task(s) in flight: task. No live watcher holds this home lock. Drain wakes with bin/fm-wake-drain.sh, the safe mid-session action; use fail-closed bin/fm-teardown.sh for completed tasks when needed, then re-arm with bin/fm-watch-arm.sh as a tracked Claude background task before running other fleet commands (blocked: fm-crew-state.sh)'
  expect_deny "lock-holding session guidance" 'bin/fm-crew-state.sh task' 'fm-crew-state.sh' "$held_reason"
  # The ancestry walk scopes guidance text only: the classification is unchanged,
  # so session start stays allowed exactly as it is without the lock.
  expect_allow "session start while holding the lock" 'bin/fm-session-start.sh'
  rm -f "$STATE/.lock"
  pass "continuity gate omits the session-start clause for a session that already holds the home lock"
}

test_deny_quantifies_stale_outage_and_names_every_task() {
  local rc=0 actual
  printf 'project=fixture\n' > "$STATE/task2.meta"
  touch -t 202001010000 "$STATE/.last-watcher-beat"
  run_command 'bin/fm-crew-state.sh task' || rc=$?
  [ "$rc" -eq 2 ] || fail "stale outage must deny an unrelated fleet command, got exit $rc"
  actual=$(jq -r '.systemMessage' "$ERR")
  assert_contains "$actual" 'SUPERVISION OUTAGE: down for at least ' "continuity denial omitted the computed outage duration"
  assert_contains "$actual" '2 task(s) in flight: task, task2' "continuity denial omitted the in-flight count or task identities"
  rm -f "$STATE/task2.meta" "$STATE/.last-watcher-beat"
  pass "continuity denial quantifies a stale outage and names every task in flight"
}

test_live_lock_allows_fleet_command_even_with_stale_beacon() {
  local holder identity rc=0
  sleep 300 &
  holder=$!
  identity=$(FM_STATE_OVERRIDE="$STATE" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$holder") \
    || fail "could not identify live continuity fixture"
  mkdir -p "$STATE/.watch.lock"
  printf '%s\n' "$holder" > "$STATE/.watch.lock/pid"
  printf '%s\n' "$PRIMARY" > "$STATE/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$STATE/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$STATE/.watch.lock/pid-identity"
  touch -t 200001010000 "$STATE/.last-watcher-beat"

  run_command 'bin/fm-crew-state.sh task' || rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$rc" -eq 0 ] || fail "identity-matched live lock must allow fleet command even when its beacon is stale"
  [ ! -s "$ERR" ] || fail "live-lock allow wrote stderr: $(cat "$ERR")"
  pass "continuity gate classifies the lock by live PID identity rather than beacon age"
}

test_child_worktree_and_malformed_input_fail_open() {
  local child="$TMP_ROOT/child" rc=0
  rm -rf "$STATE/.watch.lock"
  git -C "$PRIMARY" config user.name fixture
  git -C "$PRIMARY" config user.email fixture@example.test
  git -C "$PRIMARY" add AGENTS.md
  git -C "$PRIMARY" commit -qm fixture
  git -C "$PRIMARY" worktree add -q -b fixture-child "$child"
  mkdir -p "$child/bin" "$child/state"
  FM_ROOT_OVERRIDE="$child" FM_HOME="$child" FM_STATE_OVERRIDE="$child/state" \
    "$CHECK" --command 'bin/fm-send.sh task hi' > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "linked child worktree must be out of continuity-gate scope"

  expect_allow "malformed dynamic shell" "bin/fm-send.sh 'unterminated"
  printf '%s' '{not-json' | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
    "$CHECK" > "$OUT" 2> "$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "malformed Claude transport must fail open"
  pass "continuity gate excludes child worktrees and fails open on opaque input"
}

test_claude_hook_registration_preserves_stop_backstop() {
  jq -e '
    [.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command]
      | any(contains("fm-continuity-pretool-check.sh"))
  ' "$ROOT/.claude/settings.json" >/dev/null || fail "Claude settings omit the continuity PreToolUse hook"
  jq -e '
    .hooks.Stop == [{"hooks":[{"type":"command","command":"\"$CLAUDE_PROJECT_DIR\"/bin/fm-turnend-guard.sh"}]}]
  ' "$ROOT/.claude/settings.json" >/dev/null || fail "Claude Stop turn-end backstop changed"
  pass "Claude wires the continuity gate while preserving the existing Stop backstop byte-for-byte"
}

test_gate_scope_and_recovery_exceptions
test_lock_holding_session_gets_guidance_without_session_start
test_deny_quantifies_stale_outage_and_names_every_task
test_live_lock_allows_fleet_command_even_with_stale_beacon
test_child_worktree_and_malformed_input_fail_open
test_claude_hook_registration_preserves_stop_backstop
