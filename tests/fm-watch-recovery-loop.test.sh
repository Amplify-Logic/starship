#!/usr/bin/env bash
# Pin the Pi/OpenCode recovery-loop fix: one announcement per generation, and a
# handling successor that keeps supervising instead of going blind.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-recovery-loop)
export NODE_NO_WARNINGS=1

install_pi_watch_extension_fixture() {
  local repo=$1
  mkdir -p \
    "$repo/.pi/extensions/lib" \
    "$repo/node_modules/@earendil-works/pi-coding-agent" \
    "$repo/node_modules/@earendil-works/pi-tui" \
    "$repo/node_modules/typebox" \
    "$repo/bin"
  cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$repo/.pi/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-native-contract.ts" "$repo/.pi/extensions/lib/fm-native-contract.ts"
  cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$repo/.pi/extensions/lib/fm-async-exec.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$repo/.pi/extensions/lib/fm-calm-visibility.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  chmod +x "$repo/bin/fm-operational-input.sh"
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
export function getMarkdownTheme() { return {}; }
export class UserMessageComponent {
  render() { return []; }
  invalidate() {}
}
JS
  cat > "$repo/node_modules/@earendil-works/pi-tui/package.json" <<'JSON'
{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-tui/index.js" <<'JS'
export class Box {
  addChild() {}
  clear() {}
  setBgFn() {}
}
export class Container {}
export class Text {}
JS
  cat > "$repo/node_modules/typebox/package.json" <<'JSON'
{"name":"typebox","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/typebox/index.js" <<'JS'
export const Type = {
  Object(properties) {
    return { type: "object", properties, additionalProperties: false };
  },
};
JS
}

# T1: a lost --handling-delivered handshake must not re-announce forever.
# The real Pi extension drives the real arm/watcher, with only the handshake
# RPC forced to fail. After the first recovery follow-up, wait past the old
# ~52s loop period so a regression would emit a second follow-up.
test_unacknowledged_recovery_is_announced_once_per_generation() {
  local repo home plugin fakebin out status lock_pid messages
  repo="$TMP_ROOT/t1-root"
  home="$TMP_ROOT/t1-home"
  fakebin="$TMP_ROOT/t1-fakebin"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$fakebin"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$repo/bin/fm-watch-arm.sh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --handling-delivered ]; then
  exit 1
fi
export FM_ROOT_OVERRIDE="$ROOT"
export PATH="$fakebin:\$PATH"
exec "$ROOT/bin/fm-watch-arm.sh" "\$@"
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  : > "$home/state/seed.meta"
  printf 'pending:downtime:seed.1.aaa\n' > "$home/state/.watcher-down"
  chmod 600 "$home/state/.watcher-down"
  printf '%s\t1\tcheck\tseed\tcheck: seed recovery\n' "$(date +%s)" > "$home/state/.wake-queue"
  out=$(
    PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" \
      FM_STATE_OVERRIDE="$home/state" PATH="$fakebin:$PATH" \
      FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const prompts = [];
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompts.push(String(message));
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!tool) throw new Error("Pi watch tool was not registered");
await tool.execute("tool-call-t1", {}, undefined, undefined, {});
const deadline = Date.now() + 75000;
let firstAt = 0;
while (Date.now() < deadline) {
  const rearm = prompts.filter((message) => message.includes("check: seed recovery"));
  if (rearm.length > 1) {
    throw new Error(`unbounded recovery loop: ${rearm.length} recovery follow-ups`);
  }
  if (rearm.length === 1 && firstAt === 0) firstAt = Date.now();
  if (firstAt && Date.now() - firstAt >= 55000) break;
  await new Promise((resolve) => setTimeout(resolve, 200));
}
const rearm = prompts.filter((message) => message.includes("check: seed recovery"));
if (rearm.length !== 1) {
  throw new Error(`expected exactly one recovery follow-up, got ${rearm.length}: ${prompts.join(" || ")}`);
}
const lockPid = existsSync(`${process.env.FM_HOME}/state/.watch.lock/pid`)
  ? readFileSync(`${process.env.FM_HOME}/state/.watch.lock/pid`, "utf8").trim()
  : "";
if (!/^[0-9]+$/.test(lockPid)) throw new Error("successor watcher lock pid missing");
try {
  process.kill(Number(lockPid), 0);
} catch {
  throw new Error(`successor watcher ${lockPid} is not alive`);
}
const marker = readFileSync(`${process.env.FM_HOME}/state/.watcher-down`, "utf8").trim();
if (!marker.startsWith("announced:") && !marker.startsWith("pending:")) {
  throw new Error(`successor did not keep a live recovery episode: ${marker}`);
}
console.log(`T1_MESSAGES=${rearm.length}`);
console.log(`T1_LOCK_PID=${lockPid}`);
console.log(`T1_MARKER=${marker}`);
process.exit(0);
EOF
  )
  status=$?
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '%s\n' "$out"
  fi
  lock_pid=$(sed -n 's/^T1_LOCK_PID=//p' <<<"$out" | tail -1)
  messages=$(sed -n 's/^T1_MESSAGES=//p' <<<"$out" | tail -1)
  if [ -n "$lock_pid" ]; then
    kill -TERM "$lock_pid" 2>/dev/null || true
  fi
  expect_code 0 "$status" "an unacknowledged recovery must be announced at most once per generation: $out"
  [ "$messages" = 1 ] || fail "T1 did not report a single recovery follow-up: $out"
  pass "unacknowledged recovery is announced at most once per generation and the successor stays alive"
}

# T2: a handling successor must enter its poll loop and surface a real crew
# event within a bounded startup-and-poll budget instead of sitting in a
# pre-loop wait that refreshes the liveness beacon and then exits with a
# synthetic rearm-resurface.
test_handling_successor_does_not_go_blind() {
  local dir home state fakebin child event_start now out
  dir=$(make_case recovery-gap-successor)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"
  : > "$state/crew.meta"
  printf 'pending:downtime:gap.1.aaa\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 \
    FM_WATCH_HANDLING_SUCCESSOR=1 "$WATCH" > "$out" 2>&1 &
  child=$!
  now=0
  while [ "$now" -lt 40 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] && break
    sleep 0.1
    now=$((now + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not take the watcher lock"; }
  sleep 0.4
  printf 'done: crew finished its task\n' >> "$state/crew.status"
  event_start=$(date +%s)
  now=0
  while [ "$now" -lt 20 ]; do
    if grep -q '^signal:' "$out" 2>/dev/null; then
      break
    fi
    sleep 0.5
    now=$((now + 1))
  done
  if ! grep -q '^signal:' "$out" 2>/dev/null; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    fail "handling successor did not surface the crew event within the bounded startup-and-poll budget (waited $(( $(date +%s) - event_start ))s): $(cat "$out")"
  fi
  grep -F 'crew.status' "$out" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not name the crew status file: $(cat "$out")"; }
  grep "$(printf '\tsignal\tcrew.status\t')" "$state/.wake-queue" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not enqueue a durable row for the crew event"; }
  ! grep -E '^check: (rearm-resurface$|queued wake: )' "$out" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor emitted synthetic recovery instead of supervising: $(cat "$out")"; }
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf 'T2_WATCH_OUTPUT=%s\n' "$(tr '\n' ' ' < "$out")"
    printf 'T2_QUEUE_ROW=%s\n' "$(grep "$(printf '\tsignal\tcrew.status\t')" "$state/.wake-queue" | tail -1)"
  fi
  kill -TERM "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  pass "a resurfacing handling successor stays alive and supervises instead of going blind"
}

# Captain input queued while a cycle runs - a Starship Voice or glasses note
# through bin/fm-inbox.sh, or a desk-voice mailbox transcript - must close the
# cycle with its own reason. Before, a handling successor never re-announced
# queued rows and an announced episode waited on them, so the note sat queued
# until an unrelated event woke the primary. Rows already queued when the cycle
# started belong to the wake that started it and must not wake it again.
captain_input_watch_bg() {  # <dir> <out> [extra env assignments...]
  local dir=$1 out=$2
  shift 2
  mkdir -p "$dir/home/data"
  : > "$dir/state/crew.meta"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 env "$@" "$WATCH" > "$out" 2>&1 &
}

wait_for_lock_holder() {  # <state> <pid>
  local i=0
  while [ "$i" -lt 300 ]; do
    [ "$(cat "$1/.watch.lock/pid" 2>/dev/null || true)" = "$2" ] && [ -e "$1/.last-watcher-beat" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

test_handling_successor_surfaces_a_captain_note_queued_mid_handling() {
  local dir state out child id rc
  dir=$(make_case captain-note-successor)
  state="$dir/state"
  out="$dir/watch.out"
  # The predecessor's wake is being handled: its row is queued and presented.
  append_wake "$state" check "inbox:1-old" "check: captain inbox note 1-old - already delivered"
  printf 'announced:handling:gap.1.bbb\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  captain_input_watch_bg "$dir" "$out" FM_WATCH_HANDLING_SUCCESSOR=1
  child=$!
  wait_for_lock_holder "$state" "$child" \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not take the watcher lock: $(cat "$out")"; }
  sleep 2.5
  if ! is_live_non_zombie "$child"; then
    fail "a row queued before the successor started woke it again: $(cat "$out")"
  fi
  id=$(FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" \
    "$ROOT/bin/fm-inbox.sh" note "connection test ping" | sed -n 's/^queued //p')
  [ -n "$id" ] || { kill -TERM "$child" 2>/dev/null || true; fail "the note was not queued"; }
  rc=0
  wait_for_exit "$child" 60 || rc=$?
  [ "$rc" -ne 124 ] || fail "the handling successor never surfaced the captain note queued mid-handling: $(cat "$out")"
  grep -F "check: captain inbox note $id - connection test ping" "$out" >/dev/null \
    || fail "the wake did not name the new captain note: $(cat "$out")"
  ! grep -F '1-old' "$out" >/dev/null || fail "the already-delivered row was surfaced again: $(cat "$out")"
  [ "$(grep -c "inbox:" "$state/.wake-queue")" = 2 ] \
    || fail "surfacing must leave the durable rows for the drain to present and acknowledge"
  pass "a handling successor surfaces a captain note queued while the primary is handling"
}

test_handling_cycle_names_new_captain_input() {
  local dir state out child rc
  dir=$(make_case captain-input-handling)
  state="$dir/state"
  out="$dir/watch.out"
  append_wake "$state" check "inbox:1-old" "check: captain inbox note 1-old - presented, not yet acknowledged"
  printf 'pending:handling:gap.2.ccc\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  captain_input_watch_bg "$dir" "$out"
  child=$!
  wait_for_lock_holder "$state" "$child" \
    || { kill -TERM "$child" 2>/dev/null || true; fail "watcher did not take the lock: $(cat "$out")"; }
  sleep 2.5
  if ! is_live_non_zombie "$child"; then
    fail "an episode still being handled was re-presented without new input: $(cat "$out")"
  fi
  append_wake "$state" check "desk-voice" "desk-voice: $state/desk-voice/inbox/fixture.json"
  append_wake "$state" check "inbox:2-new" "check: captain inbox note 2-new - second"
  rc=0
  wait_for_exit "$child" 60 || rc=$?
  [ "$rc" -ne 124 ] || fail "new captain input while an episode is handled never woke the watcher: $(cat "$out")"
  grep -Fx "check: desk-voice: $state/desk-voice/inbox/fixture.json" "$out" >/dev/null \
    || fail "the wake did not name the new captain input: $(cat "$out")"
  ! grep -E 'rearm-resurface|queued wake: ' "$out" >/dev/null || fail "the wake reported generic recovery instead of the captain input: $(cat "$out")"
  pass "captain input queued while an episode is handled wakes the watcher under its own name"
}

# T3: a row appended after the predecessor closes but before its handling
# successor can inspect the queue must survive the handoff and reach main.
test_handling_successor_resurfaces_a_row_appended_during_startup() {
  local dir home state fakebin child blocker now out
  dir=$(make_case recovery-startup-append)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"
  printf 'pending:downtime:later.1.aaa\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  printf '%s\t1\tstale\tfm-demo\tstale: fm-demo (the delivered wake)\n' "$(date +%s)" > "$state/.wake-queue"
  printf '1\n' > "$state/.wake-queue.seq"
  out="$dir/watch.out"

  FM_HOME="$home" FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || exit 1
    : > "$2/queue-held"
    while [ ! -e "$2/append-now" ]; do sleep 0.02; done
    fm_wake_append_locked check inbox:n1 "check: captain inbox note n1 - from Basecamp" || exit 1
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$state" &
  blocker=$!
  now=0
  while [ "$now" -lt 100 ] && [ ! -e "$state/queue-held" ]; do
    sleep 0.02
    now=$((now + 1))
  done
  [ -e "$state/queue-held" ] || { kill "$blocker" 2>/dev/null || true; fail "fixture: queue lock was not held"; }

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 \
    FM_WATCH_HANDLING_SUCCESSOR=1 "$WATCH" > "$out" 2>&1 &
  child=$!
  now=0
  while [ "$now" -lt 40 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] && break
    sleep 0.1
    now=$((now + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] \
    || { kill -TERM "$child" "$blocker" 2>/dev/null || true; fail "handling successor did not take the watcher lock"; }
  : > "$state/append-now"
  wait "$blocker" || { kill -TERM "$child" 2>/dev/null || true; fail "fixture: startup append failed"; }
  now=0
  while [ "$now" -lt 40 ] && [ ! -e "$state/.last-watcher-beat" ]; do
    sleep 0.1
    now=$((now + 1))
  done
  [ -e "$state/.last-watcher-beat" ] \
    || { kill -TERM "$child" 2>/dev/null || true; fail "fixture: handling successor never finished startup"; }
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_recovery_marker_begin_handling "$2/.watcher-down" later.1.aaa || exit 1
    fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || exit 1
    awk -F "\t" "\$2 != 1" "$FM_WAKE_QUEUE" > "$FM_WAKE_QUEUE.tmp" \
      && mv -f "$FM_WAKE_QUEUE.tmp" "$FM_WAKE_QUEUE" || exit 1
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    fm_recovery_marker_handling_settled "$2/.watcher-down"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$state" \
    || { kill -TERM "$child" 2>/dev/null || true; fail "fixture: handled-turn settlement failed"; }

  now=0
  while [ "$now" -lt 40 ] && kill -0 "$child" 2>/dev/null; do
    sleep 0.25
    now=$((now + 1))
  done
  if kill -0 "$child" 2>/dev/null; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    fail "handling successor never resurfaced the startup-window row: $(cat "$out"; cat "$state/.watcher-down")"
  fi
  wait "$child" 2>/dev/null || true
  [ "$(grep -c '^check: queued wake: check: captain inbox note n1 - from Basecamp$' "$out")" -eq 1 ] \
    || fail "handling successor did not close once with the recovered row's reason: $(cat "$out")"
  grep "$(printf '\tcheck\tinbox:n1\t')" "$state/.wake-queue" >/dev/null \
    || fail "the resurfaced inbox row must stay queued for main"
  grep -E '^(pending|announced):downtime:' "$state/.watcher-down" >/dev/null \
    || fail "the resurfaced close must leave a deliverable downtime episode: $(cat "$state/.watcher-down")"
  pass "a handling successor resurfaces a row appended during startup"
}

# A recovery that finds a queued row closes with that row's own reason. Before,
# every such close read "check: rearm-resurface", so a real event (a morning
# intake, a captain note, a merge) reached the primary looking like an empty
# re-arm. A payload stored without its kind prefix is named by its row kind.
test_recovery_wake_carries_the_queued_row_reason() {
  local dir state out child rc
  dir=$(make_case recovery-names-row)
  state="$dir/state"
  out="$dir/watch.out"
  printf 'acked:handling:done.1.aaa\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  captain_input_watch_bg "$dir" "$out"
  child=$!
  wait_for_lock_holder "$state" "$child" \
    || { kill -TERM "$child" 2>/dev/null || true; fail "watcher did not take the lock: $(cat "$out")"; }
  sleep 1.5
  is_live_non_zombie "$child" || fail "an acknowledged episode woke the watcher: $(cat "$out")"
  append_wake "$state" check morning-intake "morning-intake due for 2026-11-17"
  rc=0
  wait_for_exit "$child" 100 || rc=$?
  [ "$rc" -ne 124 ] || fail "the queued row never woke the watcher: $(cat "$out")"
  grep -Fx 'check: queued wake: check: morning-intake due for 2026-11-17' "$out" >/dev/null \
    || fail "the recovery wake did not carry the queued row's own reason: $(cat "$out")"
  ! grep -F 'rearm-resurface' "$out" >/dev/null \
    || fail "a recovery with a queued row reported the generic re-arm reason: $(cat "$out")"
  grep "$(printf '\tcheck\tmorning-intake\t')" "$state/.wake-queue" >/dev/null \
    || fail "the recovered row must stay queued for the drain to present and acknowledge"
  pass "a recovery wake carries the queued row's own reason"
}

# Claude's hand-over: the handling successor closes on a real event while the
# handling turn is still running, so nobody is attached to deliver its close.
# The turn-end arm then starts a fresh watcher, which must deliver that
# successor's recorded reason instead of reporting the gap as downtime.
test_turn_end_delivers_an_unattended_successor_reason() {
  local dir state succ_out fresh_out child rc reason
  dir=$(make_case unattended-successor)
  state="$dir/state"
  succ_out="$dir/successor.out"
  fresh_out="$dir/fresh.out"
  # The primary already drained and acknowledged the predecessor's wake.
  printf 'acked:handling:pred.1.aaa\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  captain_input_watch_bg "$dir" "$succ_out" FM_WATCH_HANDLING_SUCCESSOR=1
  child=$!
  wait_for_lock_holder "$state" "$child" \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not take the lock: $(cat "$succ_out")"; }
  sleep 1.5
  printf 'working: next step\n' >> "$state/crew.status"
  rc=0
  wait_for_exit "$child" 100 || rc=$?
  [ "$rc" -ne 124 ] || fail "fixture: the successor never closed on the crew event: $(cat "$succ_out")"
  reason=$(grep -E '^signal: ' "$succ_out" | head -n 1)
  [ -n "$reason" ] || fail "fixture: the successor did not close with the crew signal: $(cat "$succ_out")"
  captain_input_watch_bg "$dir" "$fresh_out"
  child=$!
  rc=0
  wait_for_exit "$child" 100 || rc=$?
  [ "$rc" -ne 124 ] || fail "the turn-end watcher never delivered the dropped close: $(cat "$fresh_out")"
  grep -Fx "check: queued wake: $reason" "$fresh_out" >/dev/null \
    || fail "the turn-end wake did not carry the successor's recorded reason '$reason': $(cat "$fresh_out")"
  ! grep -F 'rearm-resurface' "$fresh_out" >/dev/null \
    || fail "a normal hand-over was reported as downtime: $(cat "$fresh_out")"
  pass "the turn end delivers an unattended handling successor's recorded reason"
}

# Rows a live supervision-branch grant holds are the branch's to present and
# acknowledge. A downtime recovery whose queue holds only those rows must not
# wake main, even with work in flight; once the grant is gone the row is
# main's again and wakes it under its own reason.
test_branch_held_rows_do_not_wake_main() {
  local dir state out child rc
  dir=$(make_case branch-held-recovery)
  state="$dir/state"
  out="$dir/watch.out"
  printf 'pending:downtime:held.1.aaa\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  append_wake "$state" signal held.status "signal: held by the branch"
  FM_STATE_OVERRIDE="$state" bash "$ROOT/bin/fm-wake-grant.sh" activate "$$" held-grant \
    || fail "fixture: could not activate the branch grant"
  FM_STATE_OVERRIDE="$state" bash "$ROOT/bin/fm-wake-grant.sh" publish held-grant 1 \
    || fail "fixture: could not publish the branch grant"
  captain_input_watch_bg "$dir" "$out"
  child=$!
  wait_for_lock_holder "$state" "$child" \
    || { kill -TERM "$child" 2>/dev/null || true; fail "watcher did not take the lock: $(cat "$out")"; }
  sleep 3
  is_live_non_zombie "$child" \
    || fail "a recovery whose only queued row a live branch grant holds woke main: $(cat "$out")"
  rm -f "$state/.branch-eligible-rows" "$state/.branch-eligible-owner"
  rc=0
  wait_for_exit "$child" 100 || rc=$?
  [ "$rc" -ne 124 ] || fail "the row stayed silent after the branch grant ended: $(cat "$out")"
  grep -Fx 'check: queued wake: signal: held by the branch' "$out" >/dev/null \
    || fail "the released row did not wake main under its own reason: $(cat "$out")"
  pass "rows a live branch grant holds do not wake main; released, they do"
}

# A row the current handling turn's drain already presented is being handled:
# a fresh watcher at that turn's end must not wake main for it again, while a
# row appended afterwards, never presented, still wakes it.
test_presented_rows_do_not_wake_main_again() {
  local dir state out child rc
  dir=$(make_case presented-recovery)
  state="$dir/state"
  out="$dir/watch.out"
  mkdir -p "$dir/home/data"
  # The delivered wake's row, then the handling successor's startup announcing
  # that episode, as on every Claude hand-over.
  append_wake "$state" check merged-fixture "check: merge landed: fixture"
  printf 'announced:downtime:hand.1.aaa\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  printf '%s\n' "$$" > "$state/.lock"
  printf 'session-one\n' > "$state/.lock-session"
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" > "$dir/drain.out" 2>&1 \
    || fail "fixture: the handling drain failed: $(cat "$dir/drain.out")"
  grep -F 'check: merge landed: fixture' "$dir/drain.out" >/dev/null \
    || fail "fixture: the drain did not present the row: $(cat "$dir/drain.out")"
  [ "$(cat "$state/.watcher-down")" = 'announced:handling:hand.1.aaa' ] \
    || fail "fixture: the drain did not begin handling the announced episode: $(cat "$state/.watcher-down")"
  captain_input_watch_bg "$dir" "$out"
  child=$!
  wait_for_lock_holder "$state" "$child" \
    || { kill -TERM "$child" 2>/dev/null || true; fail "watcher did not take the lock: $(cat "$out")"; }
  sleep 3
  is_live_non_zombie "$child" \
    || fail "a row the current handling turn was already shown woke main again: $(cat "$out")"
  append_wake "$state" check later-fixture "check: later event"
  rc=0
  wait_for_exit "$child" 100 || rc=$?
  [ "$rc" -ne 124 ] || fail "a row appended after the presentation never woke main: $(cat "$out")"
  grep -Fx 'check: queued wake: check: later event' "$out" >/dev/null \
    || fail "the new row did not wake main under its own reason: $(cat "$out")"
  pass "a row already presented to the current handling turn does not wake main again"
}

# The Claude hand-over as it runs: main's drain presents the delivered row
# to the live session, the handling successor then exits through its own
# cleanup (republishing the handled episode as pending downtime), and the
# turn-end arm starts a fresh watcher. Leaves the successor's exit marker in
# the case's state for the caller to arm against.
presented_row_then_successor_exit() {  # <dir>
  local dir=$1 state="$1/state" child
  mkdir -p "$dir/home/data"
  append_wake "$state" check merged-fixture "check: merge landed: fixture"
  printf 'pending:downtime:hand.2.aaa\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  printf '%s\n' "$$" > "$state/.lock"
  printf 'session-one\n' > "$state/.lock-session"
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" > "$dir/drain.out" 2>&1 \
    || fail "fixture: the handling drain failed: $(cat "$dir/drain.out")"
  grep -F 'check: merge landed: fixture' "$dir/drain.out" >/dev/null \
    || fail "fixture: the drain did not present the row: $(cat "$dir/drain.out")"
  captain_input_watch_bg "$dir" "$dir/successor.out" FM_WATCH_HANDLING_SUCCESSOR=1
  child=$!
  wait_for_lock_holder "$state" "$child" \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not take the lock: $(cat "$dir/successor.out")"; }
  sleep 1
  is_live_non_zombie "$child" \
    || fail "fixture: the handling successor closed on the row it was handed: $(cat "$dir/successor.out")"
  kill -TERM "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  [ "$(cat "$state/.watcher-down")" = 'pending:downtime:hand.2.aaa' ] \
    || fail "fixture: the successor's exit did not republish the handled episode as pending downtime: $(cat "$state/.watcher-down")"
}

# After the successor's exit the presented, unacknowledged row is still being
# handled by the same session: the turn-end arm must not wake main for it.
# A row appended afterwards, never presented, still wakes it.
test_successor_exit_does_not_wake_main_for_a_presented_row() {
  local dir state out child rc
  dir=$(make_case successor-exit-presented)
  state="$dir/state"
  out="$dir/watch.out"
  presented_row_then_successor_exit "$dir"
  captain_input_watch_bg "$dir" "$out"
  child=$!
  wait_for_lock_holder "$state" "$child" \
    || { kill -TERM "$child" 2>/dev/null || true; fail "watcher did not take the lock: $(cat "$out")"; }
  sleep 3
  is_live_non_zombie "$child" \
    || fail "the turn-end arm woke main again for a row its handling turn was already shown: $(cat "$out")"
  append_wake "$state" check later-fixture "check: later event"
  rc=0
  wait_for_exit "$child" 100 || rc=$?
  [ "$rc" -ne 124 ] || fail "a row appended after the presentation never woke main: $(cat "$out")"
  grep -Fx 'check: queued wake: check: later event' "$out" >/dev/null \
    || fail "the new row did not wake main under its own reason: $(cat "$out")"
  ! grep -F 'merge landed' "$out" >/dev/null \
    || fail "the already-presented row was named again: $(cat "$out")"
  pass "a handling successor's exit does not wake main again for a row already presented to that session"
}

# The same presented row left unacknowledged when a different session takes
# the session lock was never handled by that session: it must resurface.
test_new_session_resurfaces_a_presented_unacknowledged_row() {
  local dir state out child rc holder
  dir=$(make_case new-session-presented)
  state="$dir/state"
  out="$dir/watch.out"
  presented_row_then_successor_exit "$dir"
  sleep 60 &
  holder=$!
  printf '%s\n' "$holder" > "$state/.lock"
  captain_input_watch_bg "$dir" "$out"
  child=$!
  rc=0
  wait_for_exit "$child" 100 || rc=$?
  kill -TERM "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$rc" -ne 124 ] || fail "a new session never saw the unacknowledged row resurface: $(cat "$out")"
  grep -Fx 'check: queued wake: check: merge landed: fixture' "$out" >/dev/null \
    || fail "the resurfaced wake did not name the unacknowledged row: $(cat "$out")"
  pass "a new session resurfaces a row presented to the previous session but never acknowledged"
}

# A heartbeat queued after the handling session was shown a real event wakes
# main, but the wake names the heartbeat that caused it, never the event that
# session already handled.
test_recovery_wake_does_not_name_a_presented_row() {
  local dir state out child rc
  dir=$(make_case presented-label)
  state="$dir/state"
  out="$dir/watch.out"
  presented_row_then_successor_exit "$dir"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "fixture: heartbeat append failed"
  captain_input_watch_bg "$dir" "$out"
  child=$!
  rc=0
  wait_for_exit "$child" 100 || rc=$?
  [ "$rc" -ne 124 ] || fail "the unpresented heartbeat never woke main: $(cat "$out")"
  grep -Fx 'check: queued wake: heartbeat' "$out" >/dev/null \
    || fail "the wake did not name the heartbeat that caused it: $(cat "$out")"
  ! grep -F 'merge landed' "$out" >/dev/null \
    || fail "the wake named a row the handling session was already shown: $(cat "$out")"
  pass "a recovery wake names the unpresented row that caused it, not a row already shown"
}

# The recovery count's fail-safe: a queue that exists but cannot be read is
# uncertainty, which counts as one row so the recovery still runs instead of
# retiring the episode as if nothing were queued.
test_unreadable_queue_still_counts_for_recovery() {
  local dir state count
  if [ "$(id -u)" = 0 ]; then
    pass "an unreadable queue still counts for recovery (skipped: root reads any file)"
    return 0
  fi
  dir=$(make_case unreadable-queue)
  state="$dir/state"
  append_wake "$state" check unread-fixture "check: unread event"
  chmod 000 "$state/.wake-queue"
  count=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_wake_main_recovery_count' _ "$ROOT/bin/fm-wake-lib.sh")
  chmod 600 "$state/.wake-queue"
  [ "$count" = 1 ] || fail "an unreadable queue counted $count rows for recovery instead of 1"
  pass "an unreadable queue still counts for recovery"
}

# A /clear starts a new conversation in the same process: the lock keeps its
# pid and only the recorded session id changes. The presented row was never
# acknowledged by the new conversation, so it must resurface.
test_cleared_session_resurfaces_a_presented_unacknowledged_row() {
  local dir state out child rc
  dir=$(make_case cleared-session-presented)
  state="$dir/state"
  out="$dir/watch.out"
  presented_row_then_successor_exit "$dir"
  printf 'session-two\n' > "$state/.lock-session"
  captain_input_watch_bg "$dir" "$out"
  child=$!
  rc=0
  wait_for_exit "$child" 100 || rc=$?
  [ "$rc" -ne 124 ] || fail "a /clear-started session never saw the unacknowledged row resurface: $(cat "$out")"
  grep -Fx 'check: queued wake: check: merge landed: fixture' "$out" >/dev/null \
    || fail "the resurfaced wake did not name the unacknowledged row: $(cat "$out")"
  pass "a session re-keyed by /clear in the same process resurfaces a presented, unacknowledged row"
}

# A genuine outage that left rows main was never shown resurfaces them once,
# naming the newest.
test_genuine_outage_with_queued_rows_resurfaces_once() {
  local dir state out child rc
  dir=$(make_case genuine-outage-rows)
  state="$dir/state"
  out="$dir/watch.out"
  printf 'pending:downtime:outage.2.aaa\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  append_wake "$state" check older-fixture "check: older event"
  append_wake "$state" check newer-fixture "check: newer event"
  captain_input_watch_bg "$dir" "$out"
  child=$!
  rc=0
  wait_for_exit "$child" 100 || rc=$?
  [ "$rc" -ne 124 ] || fail "an outage that left queued rows never resurfaced: $(cat "$out")"
  [ "$(grep -c '^check: ' "$out")" -eq 1 ] \
    || fail "the outage did not resurface exactly once: $(cat "$out")"
  grep -Fx 'check: queued wake: check: newer event' "$out" >/dev/null \
    || fail "the outage resurface did not name the newest queued row: $(cat "$out")"
  pass "a genuine outage with queued rows resurfaces once, naming the newest"
}

# A genuine outage - the watcher died with work in flight and left nothing
# queued - still resurfaces once under the generic reason, and a later arm on
# the same unacknowledged episode stays quiet.
test_genuine_outage_keeps_one_generic_recovery() {
  local dir state out child rc
  dir=$(make_case genuine-outage)
  state="$dir/state"
  out="$dir/first.out"
  printf 'pending:downtime:outage.1.aaa\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  captain_input_watch_bg "$dir" "$out"
  child=$!
  rc=0
  wait_for_exit "$child" 100 || rc=$?
  [ "$rc" -ne 124 ] || fail "a genuine outage with work in flight never resurfaced: $(cat "$out")"
  [ "$(grep -c '^check: rearm-resurface$' "$out")" -eq 1 ] \
    || fail "a genuine outage did not resurface once under the generic reason: $(cat "$out")"
  out="$dir/second.out"
  captain_input_watch_bg "$dir" "$out"
  child=$!
  wait_for_lock_holder "$state" "$child" \
    || { kill -TERM "$child" 2>/dev/null || true; fail "second watcher did not take the lock: $(cat "$out")"; }
  sleep 2.5
  is_live_non_zombie "$child" || fail "the announced outage was resurfaced a second time: $(cat "$out")"
  kill -TERM "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  pass "a genuine outage resurfaces exactly once under the generic reason"
}

test_handling_successor_does_not_go_blind
test_handling_successor_resurfaces_a_row_appended_during_startup
test_recovery_wake_carries_the_queued_row_reason
test_turn_end_delivers_an_unattended_successor_reason
test_genuine_outage_keeps_one_generic_recovery
test_branch_held_rows_do_not_wake_main
test_presented_rows_do_not_wake_main_again
test_successor_exit_does_not_wake_main_for_a_presented_row
test_new_session_resurfaces_a_presented_unacknowledged_row
test_cleared_session_resurfaces_a_presented_unacknowledged_row
test_recovery_wake_does_not_name_a_presented_row
test_unreadable_queue_still_counts_for_recovery
test_genuine_outage_with_queued_rows_resurfaces_once
test_unacknowledged_recovery_is_announced_once_per_generation
test_handling_successor_surfaces_a_captain_note_queued_mid_handling
test_handling_cycle_names_new_captain_input
