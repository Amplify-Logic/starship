#!/usr/bin/env bash
# tests/fm-supervision-test-isolation.test.sh - supervision tests are hermetic.
#
# A supervision test spawns REAL watchers, arms, and daemons. Every one of those
# entry points prefers an inherited FM_HOME over its script-relative root, so a
# single leaked operational-home variable from the invoking environment (a live
# firstmate lane exporting FM_HOME is the observed case) silently rebinds a
# fixture watcher onto the primary home's state: it steals the real watch lock,
# touches the real liveness beacon, and a fixture --restart TERMs the real fleet
# watcher. This suite pins the guarantees that make that impossible again:
#   1. tests/lib.sh drops every inherited operational-home variable at source.
#   2. A real watcher started with NO overrides resolves only the hermetic
#      fixture home and never writes into a planted foreign home.
#   3. A real `fm-watch-arm.sh --restart` started against the suite's own empty
#      home cannot see, stop, or rewrite anything in a planted foreign home.
#   4. Suite teardown reaps ONLY path-scoped children - processes whose command
#      path lies inside this worktree or a registered fixture temp dir - so no
#      supervision process outlives its fixture and no same-named process
#      outside that scope (a real home's live supervision) is ever signalled.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"

TMP_ROOT=$(fm_test_tmproot fm-supervision-test-isolation)

# Hermetic fake tmux so a spawned watcher never lists a real terminal session.
ISOLATION_FAKEBIN=$(fm_fakebin "$TMP_ROOT/bin")
cat > "$ISOLATION_FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows|capture-pane|display-message) exit 0 ;;
esac
exit 1
SH
chmod +x "$ISOLATION_FAKEBIN/tmux"

plant_foreign_home() {  # <label>; echoes the planted home dir
  local label=$1 dir state
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-isolation-foreign-$label.XXXXXX")
  FM_TEST_CLEANUP_DIRS+=("$dir")
  state="$dir/state"
  mkdir -p "$state"
  printf 'sentinel-marker\n' > "$state/marker"
  printf '%s\n' "$dir"
}

test_lib_source_drops_inherited_operational_home() {
  local out
  # A lane environment poisons every operational-home variable before the test
  # process even exists; sourcing the shared library must drop the poison and
  # pin the hermetic fixture home in its place.
  # shellcheck disable=SC2016 # single quotes are deliberate: $0 carries the lib path
  out=$(env FM_HOME=/Users/you/starship \
    FM_ROOT_OVERRIDE=/Users/you/starship \
    FM_STATE_OVERRIDE=/Users/you/starship/state \
    bash -c '
      . "$0"
      printf "home=%s\n" "${FM_HOME:-unset}"
      printf "root_override=%s\n" "${FM_ROOT_OVERRIDE:-unset}"
      printf "state_override=%s\n" "${FM_STATE_OVERRIDE:-unset}"
    ' "$ROOT/tests/lib.sh")
  assert_contains "$out" "root_override=unset" "lib.sh must drop an inherited FM_ROOT_OVERRIDE"
  assert_contains "$out" "state_override=unset" "lib.sh must drop an inherited FM_STATE_OVERRIDE"
  case "$out" in
    *home=/Users/you/starship*|*home=unset*)
      fail "lib.sh did not replace an inherited FM_HOME with the hermetic home: $out"
      ;;
  esac
  case "$out" in
    *home=*/fm-hermetic-home.*) : ;;
    *) fail "lib.sh pinned an unexpected operational home: $out" ;;
  esac
  pass "isolation: sourcing tests/lib.sh drops every inherited operational-home variable"
}

test_watcher_with_no_overrides_resolves_only_the_hermetic_home() {
  local foreign foreign_state out watcher_pid i
  foreign=$(plant_foreign_home watcher)
  foreign_state="$foreign/state"

  # No FM_STATE_OVERRIDE and no per-spawn FM_HOME: the watcher must fall back to
  # the suite's hermetic FM_HOME (pinned by wake-helpers after lib.sh dropped
  # whatever the invoking lane exported) and never touch the planted home.
  out="$TMP_ROOT/watcher.out"
  PATH="$ISOLATION_FAKEBIN:$PATH" FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>&1 &
  watcher_pid=$!
  fm_test_track_pid "$watcher_pid"

  i=0
  while [ "$i" -lt 60 ]; do
    [ -e "$FM_HOME/state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$FM_HOME/state/.last-watcher-beat" ] || fail "watcher never beat inside the hermetic home: $(cat "$out")"
  [ "$(cat "$FM_HOME/state/.watch.lock/pid" 2>/dev/null || true)" = "$watcher_pid" ] \
    || fail "watcher singleton lock is not inside the hermetic home"
  assert_absent "$foreign_state/.watch.lock" "a no-override watcher created a watch lock in a planted foreign home"
  assert_absent "$foreign_state/.last-watcher-beat" "a no-override watcher beat inside a planted foreign home"
  assert_absent "$foreign_state/.lock" "a no-override watcher wrote a session lock in a planted foreign home"
  assert_absent "$foreign_state/.watch-deliveries.log" "a no-override watcher wrote delivery records in a planted foreign home"
  [ "$(cat "$foreign_state/marker" 2>/dev/null || true)" = "sentinel-marker" ] \
    || fail "a no-override watcher modified a planted foreign home"
  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true
  pass "isolation: a watcher with no overrides binds only the hermetic fixture home"
}

test_arm_restart_cannot_touch_a_foreign_home() {
  local foreign foreign_state lockdir out stand_in arm_pid i
  foreign=$(plant_foreign_home restart)
  foreign_state="$foreign/state"
  lockdir="$foreign_state/.watch.lock"
  mkdir -p "$lockdir"

  # A live stand-in recorded as the foreign home's watcher holder: if the arm
  # could resolve the foreign home, --restart would TERM this pid.
  sleep 300 &
  stand_in=$!
  fm_test_track_pid "$stand_in"
  printf '%s\n' "$stand_in" > "$lockdir/pid"

  # The arm runs against the suite's own (empty) hermetic home with no other
  # overrides. A healthy child makes the arm block by design (it is a tracked
  # background task whose completion is the next wake), so the test awaits the
  # honest healthy report, asserts the foreign home was never touched WHILE the
  # arm holds its live cycle, then stops the arm.
  out="$TMP_ROOT/arm-restart.out"
  PATH="$ISOLATION_FAKEBIN:$PATH" FM_ARM_CONFIRM_TIMEOUT=5 "$WATCH_ARM" --restart > "$out" 2>&1 &
  arm_pid=$!
  fm_test_track_pid "$arm_pid"

  i=0
  while [ "$i" -lt 100 ]; do
    grep -Eq '^watcher: (started|healthy)' "$out" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -Eq '^watcher: (started|healthy)' "$out" \
    || fail "restart did not report a live hermetic watcher: $(cat "$out")"

  kill -0 "$stand_in" 2>/dev/null \
    || fail "the restart TERMed a foreign home's recorded watcher holder"
  [ "$(cat "$lockdir/pid" 2>/dev/null || true)" = "$stand_in" ] \
    || fail "the restart rewrote a foreign home's watch lock record"
  assert_absent "$foreign_state/.last-watcher-beat" "the restart beat inside a planted foreign home"
  assert_absent "$foreign_state/.watch-deliveries.log" "the restart wrote delivery records in a planted foreign home"
  [ "$(cat "$foreign_state/marker" 2>/dev/null || true)" = "sentinel-marker" ] \
    || fail "the restart modified a planted foreign home"

  kill -TERM "$arm_pid" 2>/dev/null || true
  wait "$arm_pid" 2>/dev/null || true
  kill "$stand_in" 2>/dev/null || true
  wait "$stand_in" 2>/dev/null || true
  pass "isolation: a restart cannot see or stop a foreign home's watcher"
}

test_teardown_reaps_untracked_background_children() {
  local fixture_pid worktree_pid foreign_pid alive command_sub_root
  # An untracked long-runner INSIDE the fixture tree (its command path lies in a
  # registered temp dir) stands in for a watcher a mid-test fail skipped past:
  # teardown must still reap it.
  command_sub_root=$(fm_test_tmproot fm-isolation-command-sub)
  cat > "$command_sub_root/long-runner" <<'SH'
#!/usr/bin/env bash
sleep 300
SH
  chmod +x "$command_sub_root/long-runner"
  "$command_sub_root/long-runner" &
  fixture_pid=$!
  bash -c 'trap "exit 0" TERM; while :; do :; done' "$ROOT/bin/fm-watch.sh" &
  worktree_pid=$!
  # A live process OUTSIDE every scoped path - plain sleep, the same shape a
  # real firstmate home's own supervision could be running - must survive
  # teardown untouched.
  /bin/sleep 300 &
  foreign_pid=$!
  fm_test_reap_children
  alive=0
  kill -0 "$fixture_pid" 2>/dev/null && alive=1
  wait "$fixture_pid" 2>/dev/null || true
  [ "$alive" -eq 0 ] || fail "teardown left a path-scoped untracked child alive"
  alive=0
  kill -0 "$worktree_pid" 2>/dev/null && alive=1
  wait "$worktree_pid" 2>/dev/null || true
  [ "$alive" -eq 0 ] || fail "teardown left an interpreted worktree child alive"
  alive=0
  kill -0 "$foreign_pid" 2>/dev/null && alive=1
  [ "$alive" -eq 1 ] || fail "teardown killed a process outside every scoped path"
  kill "$foreign_pid" 2>/dev/null || true
  wait "$foreign_pid" 2>/dev/null || true
  pass "isolation: teardown reaps only path-scoped children and never touches anything else"
}

test_lib_source_drops_inherited_operational_home
test_watcher_with_no_overrides_resolves_only_the_hermetic_home
test_arm_restart_cannot_touch_a_foreign_home
test_teardown_reaps_untracked_background_children
