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
NOTIFY="$TMP_ROOT/notify"
NOTIFY_LOG="$TMP_ROOT/notify.log"

mkdir -p "$PRIMARY/bin" "$STATE"
printf '# fixture\n' > "$PRIMARY/AGENTS.md"
git -C "$PRIMARY" init -q
cat > "$NOTIFY" <<SH
#!/usr/bin/env bash
printf '%s\t%s\n' "\$1" "\$2" >> "$NOTIFY_LOG"
SH
chmod +x "$NOTIFY"

run_command() {
  local command=$1 rc=0
  : > "$OUT"
  : > "$ERR"
  if [ "${RUN_FROM_HARNESS:-0}" = 1 ]; then
    # The single quotes deliberately prevent shell expansion inside the JavaScript fixture.
    # shellcheck disable=SC2016
    FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      FM_SUPERVISION_SENTINEL_MODE=auto FM_WEDGE_ALARM_CHANNEL=osascript FM_WEDGE_ALARM_EXEC="$NOTIFY" \
      node -e '
        const fs = require("node:fs");
        const { spawnSync } = require("node:child_process");
        fs.writeFileSync(`${process.env.FM_STATE_OVERRIDE}/.lock`, `${process.pid}\n`);
        const result = spawnSync(process.argv[1], ["--command", process.argv[2]], { stdio: "inherit" });
        process.exit(result.status ?? 1);
      ' "$CHECK" "$command" codex > "$OUT" 2> "$ERR" || rc=$?
  else
    FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$STATE" \
      FM_SUPERVISION_SENTINEL_MODE=auto FM_WEDGE_ALARM_CHANNEL=osascript FM_WEDGE_ALARM_EXEC="$NOTIFY" \
      "$CHECK" --command "$command" > "$OUT" 2> "$ERR" || rc=$?
  fi
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
  # The session-start disarm banner names exactly one host-sentinel command, so
  # exactly that literal invocation is a recovery exception and nothing else is.
  expect_allow "exact sentinel enable improves recovery" 'bin/fm-supervision-sentinel.sh enable'
  expect_allow "nested exact sentinel enable improves recovery" "bash -lc 'bin/fm-supervision-sentinel.sh enable'"
  unsafe_sentinel_reason='[watcher-continuity] SUPERVISION OUTAGE: down for unknown duration (unknown since when; watcher beat file missing or unreadable); 1 task(s) in flight: task. During recovery only the literal bin/fm-supervision-sentinel.sh enable is allowed; arm, disarm, check, and every other host-sentinel invocation stays blocked until supervision is healthy (blocked: fm-supervision-sentinel.sh)'
  expect_deny "sentinel disarm reduces safety" 'bin/fm-supervision-sentinel.sh disarm' 'fm-supervision-sentinel.sh' "$unsafe_sentinel_reason"
  expect_deny "sentinel arm is not explicit enable" 'bin/fm-supervision-sentinel.sh arm' 'fm-supervision-sentinel.sh' "$unsafe_sentinel_reason"
  expect_deny "sentinel check is not explicit enable" 'bin/fm-supervision-sentinel.sh check' 'fm-supervision-sentinel.sh' "$unsafe_sentinel_reason"
  expect_deny "sentinel scheduled check is not explicit enable" 'bin/fm-supervision-sentinel.sh scheduled-check' 'fm-supervision-sentinel.sh' "$unsafe_sentinel_reason"
  expect_deny "bare sentinel is not explicit enable" 'bin/fm-supervision-sentinel.sh' 'fm-supervision-sentinel.sh' "$unsafe_sentinel_reason"
  expect_deny "sentinel enable with extra args is not exact" 'bin/fm-supervision-sentinel.sh enable now' 'fm-supervision-sentinel.sh' "$unsafe_sentinel_reason"
  expect_deny "over-argued sentinel enable is not recovery" 'bin/fm-supervision-sentinel.sh enable disarm' 'fm-supervision-sentinel.sh' "$unsafe_sentinel_reason"
  # shellcheck disable=SC2016 # Literal dynamic mode is test input and must stay denied.
  expect_deny "dynamic sentinel mode is not exact" 'bin/fm-supervision-sentinel.sh "$MODE"' 'fm-supervision-sentinel.sh' "$unsafe_sentinel_reason"
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
  [ ! -e "$NOTIFY_LOG" ] || fail "continuity hook blocked on an external alert channel: $(cat "$NOTIFY_LOG")"
  assert_contains "$(cat "$STATE/.supervision-outage-alarm")" 'delivery=pending' "continuity hook did not leave host-owned external delivery pending"
  pass "continuity gate allows exact recovery and ordinary commands, denies other fleet execution, and leaves external alerts to the host"
}

# Every deny above ran with no state/.lock at all, the genuine pre-lock case, so
# each asserted the guidance that names the once-per-session entry point and the
# "session start recovery" allow above covered the genuine first run. With this
# a harness-like Node parent recorded as the lock holder, the gate's ancestry
# walk resolves the holder inside the hook's own process ancestry: the guidance
# drops that clause, and session-start itself is denied as a mid-session attempt.
test_lock_holding_session_rerun_refused() {
  local held_reason rerun_reason
  RUN_FROM_HARNESS=1
  held_reason='[watcher-continuity] SUPERVISION OUTAGE: down for unknown duration (unknown since when; watcher beat file missing or unreadable); 1 task(s) in flight: task. No live watcher holds this home lock. Drain wakes with bin/fm-wake-drain.sh, the safe mid-session action; use fail-closed bin/fm-teardown.sh for completed tasks when needed, then re-arm with bin/fm-watch-arm.sh as a tracked Claude background task before running other fleet commands (blocked: fm-crew-state.sh)'
  expect_deny "lock-holding session guidance" 'bin/fm-crew-state.sh task' 'fm-crew-state.sh' "$held_reason"
  rerun_reason='[watcher-continuity] SUPERVISION OUTAGE: down for unknown duration (unknown since when; watcher beat file missing or unreadable); 1 task(s) in flight: task. No live watcher holds this home lock. This session'\''s own ancestry already holds the home session lock, so the once-per-session bin/fm-session-start.sh has already run here and a mid-session re-run is not a recovery action. Drain wakes with bin/fm-wake-drain.sh, the safe mid-session action; use fail-closed bin/fm-teardown.sh for completed tasks when needed, then re-arm with bin/fm-watch-arm.sh as a tracked Claude background task before running other fleet commands (blocked: fm-session-start.sh)'
  expect_deny "mid-session session-start re-run" 'bin/fm-session-start.sh' 'fm-session-start.sh' "$rerun_reason"
  expect_deny "nested mid-session session-start re-run" "bash -lc 'bin/fm-session-start.sh'" 'fm-session-start.sh' "$rerun_reason"
  # The other recovery allowances are unaffected by session-lock ownership.
  expect_allow "wake drain while holding the lock" 'bin/fm-wake-drain.sh'
  expect_allow "watch arm while holding the lock" 'bin/fm-watch-arm.sh'
  expect_allow "fail-closed teardown while holding the lock" 'bin/fm-teardown.sh task'
  expect_allow "exact sentinel enable while holding the lock" 'bin/fm-supervision-sentinel.sh enable'
  unset RUN_FROM_HARNESS
  rm -f "$STATE/.lock"
  pass "continuity gate refuses a mid-session session-start re-run and keeps every other allowance for the lock-holding session"
}

# A live holder outside this hook's ancestry means another session owns the
# home: session start belongs to that session, so the attempt is refused and
# the guidance stops naming the once-per-session entry point.
test_foreign_lock_holder_session_start_refused() {
  local holder foreign_reason foreign_guidance
  node -e 'setTimeout(() => {}, 300000)' codex &
  holder=$!
  printf '%s\n' "$holder" > "$STATE/.lock"
  foreign_reason='[watcher-continuity] SUPERVISION OUTAGE: down for unknown duration (unknown since when; watcher beat file missing or unreadable); 1 task(s) in flight: task. No live watcher holds this home lock. Another live session holds the home session lock, so the once-per-session bin/fm-session-start.sh belongs to that session and is not a recovery action here. Drain wakes with bin/fm-wake-drain.sh, the safe mid-session action; use fail-closed bin/fm-teardown.sh for completed tasks when needed, then re-arm with bin/fm-watch-arm.sh as a tracked Claude background task before running other fleet commands (blocked: fm-session-start.sh)'
  expect_deny "ancestry-mismatch session start" 'bin/fm-session-start.sh' 'fm-session-start.sh' "$foreign_reason"
  foreign_guidance='[watcher-continuity] SUPERVISION OUTAGE: down for unknown duration (unknown since when; watcher beat file missing or unreadable); 1 task(s) in flight: task. No live watcher holds this home lock. Drain wakes with bin/fm-wake-drain.sh, the safe mid-session action; use fail-closed bin/fm-teardown.sh for completed tasks when needed, then re-arm with bin/fm-watch-arm.sh as a tracked Claude background task before running other fleet commands (blocked: fm-crew-state.sh)'
  expect_deny "foreign-lock guidance drops the session-start clause" 'bin/fm-crew-state.sh task' 'fm-crew-state.sh' "$foreign_guidance"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  rm -f "$STATE/.lock"
  pass "continuity gate refuses session start when a live foreign session holds the home lock"
}

# A live non-harness process can reuse a stale holder PID, but it does not own
# the session lock and must not block the genuine crash-recovery first run.
test_reused_non_harness_pid_first_run_allowed() {
  local holder
  sleep 300 &
  holder=$!
  printf '%s\n' "$holder" > "$STATE/.lock"
  expect_allow "first session start over a reused non-harness pid" 'bin/fm-session-start.sh'
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  rm -f "$STATE/.lock"
  pass "continuity gate treats a live non-harness holder pid as stale"
}

# A recorded but dead holder is the crash-recovery case: the lock is not live,
# so the next session-start invocation is the genuine first run and stays
# allowed exactly like the no-lock case.
test_dead_lock_holder_first_run_allowed() {
  local dead
  dead=$(bash -c 'echo $$')
  while kill -0 "$dead" 2>/dev/null; do sleep 0.1; done
  printf '%s\n' "$dead" > "$STATE/.lock"
  expect_allow "first session start over a dead holder" 'bin/fm-session-start.sh'
  rm -f "$STATE/.lock"
  pass "continuity gate allows the genuine first session start over a dead lock holder"
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

test_live_lock_with_stale_beacon_still_denies_fleet_command() {
  local holder identity rc=0 actual
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
  [ "$rc" -eq 2 ] || fail "identity-matched live lock with a stale beacon must deny fleet work, got $rc"
  actual=$(jq -r '.systemMessage' "$ERR")
  assert_contains "$actual" 'SUPERVISION OUTAGE: down for at least ' "stale-beacon denial omitted the unambiguous alarm"
  assert_contains "$actual" 'since the last watcher beat' "stale-beacon denial omitted the outage age evidence"
  assert_contains "$actual" '1 task(s) in flight: task' "stale-beacon denial omitted the in-flight task identity"
  pass "continuity gate requires both the identity-matched live lock and a fresh beacon"
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
test_lock_holding_session_rerun_refused
test_foreign_lock_holder_session_start_refused
test_reused_non_harness_pid_first_run_allowed
test_dead_lock_holder_first_run_allowed
test_deny_quantifies_stale_outage_and_names_every_task
test_live_lock_with_stale_beacon_still_denies_fleet_command
test_child_worktree_and_malformed_input_fail_open
test_claude_hook_registration_preserves_stop_backstop
