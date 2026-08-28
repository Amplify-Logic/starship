#!/usr/bin/env bash
# tests/fm-watch-caffeinate.test.sh - watcher process-lifetime sleep assertion.
# Spawn and cleanup are proven against a PATH stub, never the real caffeinate.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-caffeinate-tests)
STATE_DIR="$TMP_ROOT/state"
mkdir -p "$STATE_DIR"
export FM_STATE_OVERRIDE="$STATE_DIR"

# Load watcher functions without acquiring the singleton lock.
# shellcheck source=/dev/null
. "$WATCH"

mark_pr_check_migration_complete() {
  local state=$1
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$state/.pr-check-migration-v1"
  chmod 0600 "$state/.pr-check-migration-scan-v1" "$state/.pr-check-migration-v1"
}

install_uname() {  # <dir> <os-name>
  mkdir -p "$1"
  printf '%s\n' '#!/bin/sh' "printf '%s\\n' '$2'" > "$1/uname"
  chmod +x "$1/uname"
}

live_stub_count() {  # <log> [watched-pid]
  local log=$1 want=${2:-} pid rest watched live=0
  [ -f "$log" ] || { printf '0\n'; return; }
  while read -r pid rest; do
    [ -n "$pid" ] || continue
    case "$rest" in
      *-w\ *)
        watched=${rest##*-w }
        watched=${watched%% *}
        ;;
      *) watched= ;;
    esac
    if [ -n "$want" ] && [ "$watched" != "$want" ]; then
      continue
    fi
    kill -0 "$pid" 2>/dev/null || continue
    live=$((live + 1))
  done < "$log"
  printf '%s\n' "$live"
}

reset_assertion() {
  watch_release_sleep_assertion
}

wait_until() {  # <limit> <cmd...>
  local limit=$1 i=0
  shift
  while [ "$i" -lt "$limit" ]; do
    if "$@"; then
      return 0
    fi
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

hold_with_path() {  # <path> <pid>
  hash -r
  PATH="$1" watch_hold_sleep_assertion "$2"
}

zero_live_stubs() {  # <log>
  [ "$(live_stub_count "$1")" = 0 ]
}

pid_is_dead() {  # <pid>
  ! kill -0 "$1" 2>/dev/null
}

log_has_w_pid() {  # <pid> <log>
  grep -qF -- "-w $1" "$2"
}

log_has_at_least_n_lines() {  # <log> <n>
  local n
  n=$(wc -l < "$1" | tr -d '[:space:]')
  [ "$n" -ge "$2" ]
}

# Shared fixture for sourced-function tests. Sets HOLD_FAKEBIN, HOLD_LOG, and
# HOLD_TARGET (a live sleep pid). --missing-caffeinate skips the PATH stub.
begin_sourced_hold() {  # <name> <os> [--missing-caffeinate]
  HOLD_FAKEBIN="$TMP_ROOT/$1/bin"
  HOLD_LOG="$TMP_ROOT/$1.log"
  rm -f "$HOLD_LOG"
  install_uname "$HOLD_FAKEBIN" "$2"
  if [ "${3:-}" = --missing-caffeinate ]; then
    unset FM_FAKE_CAFFEINATE_LOG
  else
    fm_install_fake_caffeinate "$HOLD_FAKEBIN"
    export FM_FAKE_CAFFEINATE_LOG="$HOLD_LOG"
  fi
  reset_assertion
  sleep 30 &
  HOLD_TARGET=$!
  fm_test_track_pid "$HOLD_TARGET"
}

end_sourced_hold() {
  kill "${HOLD_TARGET:-}" 2>/dev/null || true
  wait "${HOLD_TARGET:-}" 2>/dev/null || true
}

test_darwin_stub_spawns_one_child_bound_to_pid() {
  local fakebin log target
  begin_sourced_hold darwin-spawn Darwin
  fakebin=$HOLD_FAKEBIN
  log=$HOLD_LOG
  target=$HOLD_TARGET
  hold_with_path "$fakebin:$PATH" "$target"
  wait_until 40 test -s "$log" || fail "darwin stub did not record a caffeinate spawn"
  grep -F -- "-ims -w $target" "$log" >/dev/null \
    || fail "stub was not spawned as caffeinate -ims -w <pid>: $(cat "$log")"
  [ "$(live_stub_count "$log" "$target")" = 1 ] \
    || fail "expected exactly one live assertion for the watched pid"
  [ -n "${FM_WATCH_CAFFEINATE_PID:-}" ] || fail "caffeinate child pid was not recorded"
  kill -0 "$FM_WATCH_CAFFEINATE_PID" 2>/dev/null \
    || fail "caffeinate child was not recorded as live"
  reset_assertion
  wait_until 40 zero_live_stubs "$log" \
    || fail "release did not stop the caffeinate child"
  end_sourced_hold
  pass "darwin stub spawns one caffeinate -ims -w child bound to the watcher pid"
}

test_spawn_is_idempotent_in_one_process() {
  local fakebin log target first
  begin_sourced_hold idempotent Darwin
  fakebin=$HOLD_FAKEBIN
  log=$HOLD_LOG
  target=$HOLD_TARGET
  hold_with_path "$fakebin:$PATH" "$target"
  wait_until 40 test -s "$log" || fail "first hold did not record a caffeinate spawn"
  first=$FM_WATCH_CAFFEINATE_PID
  hold_with_path "$fakebin:$PATH" "$target"
  [ "$FM_WATCH_CAFFEINATE_PID" = "$first" ] \
    || fail "second hold replaced the live caffeinate child"
  [ "$(wc -l < "$log" | tr -d '[:space:]')" = 1 ] \
    || fail "second hold spawned another caffeinate: $(cat "$log")"
  [ "$(live_stub_count "$log" "$target")" = 1 ] \
    || fail "idempotent hold left a caffeinate pile-up"
  reset_assertion
  end_sourced_hold
  pass "hold is idempotent inside one watcher process"
}

test_child_dies_when_watched_pid_exits() {
  local fakebin log target stub_pid
  begin_sourced_hold dies-with-pid Darwin
  fakebin=$HOLD_FAKEBIN
  log=$HOLD_LOG
  target=$HOLD_TARGET
  hold_with_path "$fakebin:$PATH" "$target"
  wait_until 40 test -s "$log" || fail "stub did not spawn before watched-pid exit"
  stub_pid=$(awk '{print $1; exit}' "$log")
  kill "$target" 2>/dev/null || true
  wait "$target" 2>/dev/null || true
  HOLD_TARGET=
  wait_until 40 pid_is_dead "$stub_pid" \
    || fail "caffeinate stub stayed alive after the watched pid exited"
  wait "$stub_pid" 2>/dev/null || true
  FM_WATCH_CAFFEINATE_PID=
  pass "caffeinate child exits when the watched pid exits"
}

test_hold_respawns_after_child_death() {
  local fakebin log target stub_pid
  begin_sourced_hold respawn Darwin
  fakebin=$HOLD_FAKEBIN
  log=$HOLD_LOG
  target=$HOLD_TARGET
  hold_with_path "$fakebin:$PATH" "$target"
  wait_until 40 test -s "$log" || fail "first hold did not record a caffeinate spawn"
  stub_pid=$(awk '{print $1; exit}' "$log")
  kill "$stub_pid" 2>/dev/null || true
  wait "$stub_pid" 2>/dev/null || true
  wait_until 40 pid_is_dead "$stub_pid" \
    || fail "killed caffeinate child did not exit"
  hold_with_path "$fakebin:$PATH" "$target"
  wait_until 40 log_has_at_least_n_lines "$log" 2 \
    || fail "dead child was not respawned: $(cat "$log")"
  [ "$(live_stub_count "$log" "$target")" = 1 ] \
    || fail "respawn piled up assertions: $(cat "$log")"
  reset_assertion
  end_sourced_hold
  pass "hold respawns caffeinate after the child dies"
}

test_linux_is_a_clean_noop() {
  local fakebin log target
  begin_sourced_hold linux-noop Linux
  fakebin=$HOLD_FAKEBIN
  log=$HOLD_LOG
  target=$HOLD_TARGET
  hold_with_path "$fakebin:$PATH" "$target"
  sleep 0.2
  [ ! -s "$log" ] || fail "linux host spawned caffeinate: $(cat "$log")"
  [ -z "${FM_WATCH_CAFFEINATE_PID:-}" ] || fail "linux host recorded a caffeinate pid"
  end_sourced_hold
  pass "non-Darwin hosts no-op even when a caffeinate stub is on PATH"
}

test_missing_caffeinate_is_a_clean_noop() {
  local fakebin target
  begin_sourced_hold missing Darwin --missing-caffeinate
  fakebin=$HOLD_FAKEBIN
  target=$HOLD_TARGET
  hold_with_path "$fakebin:/bin" "$target"
  [ -z "${FM_WATCH_CAFFEINATE_PID:-}" ] || fail "missing caffeinate still recorded a child"
  end_sourced_hold
  pass "missing caffeinate is a clean no-op on Darwin"
}

test_lock_owner_spawns_and_non_owner_does_not() {
  local dir state fakebin log pid1 pid2 i lock_pid lines
  dir=$(make_case owner-vs-duplicate)
  state="$dir/state"
  fakebin="$dir/fakebin"
  log="$dir/caffeinate.log"
  mark_pr_check_migration_complete "$state"
  : > "$log"
  export FM_FAKE_CAFFEINATE_LOG="$log"
  PATH="$fakebin:$PATH" FM_HOME="$dir" \
    FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/watch-one.out" 2>"$dir/watch-one.err" &
  pid1=$!
  fm_test_track_pid "$pid1"
  i=0
  lock_pid=
  while [ "$i" -lt 80 ]; do
    lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    [ "$lock_pid" = "$pid1" ] && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$lock_pid" = "$pid1" ] || fail "lock-owning watcher did not take the singleton"

  PATH="$fakebin:$PATH" FM_HOME="$dir" \
    FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/watch-two.out" 2>"$dir/watch-two.err" &
  pid2=$!
  fm_test_track_pid "$pid2"
  wait_for_exit "$pid2" 80 || fail "duplicate watcher did not stand down"
  grep -F 'watcher: already running pid ' "$dir/watch-two.out" >/dev/null \
    || fail "duplicate watcher did not report the live singleton"

  if [ "$(uname)" = Darwin ]; then
    wait_until 40 test -s "$log" || fail "lock owner did not spawn stub caffeinate on Darwin"
    grep -F -- "-ims -w $pid1" "$log" >/dev/null \
      || fail "lock owner did not bind the assertion to its pid: $(cat "$log")"
    [ "$(live_stub_count "$log")" = 1 ] \
      || fail "expected one live assertion while the owner runs, got $(live_stub_count "$log")"
    lines=$(wc -l < "$log" | tr -d '[:space:]')
    [ "$lines" = 1 ] || fail "non-owner spawned extra caffeinate rows: $(cat "$log")"
  else
    [ ! -s "$log" ] || fail "non-Darwin real watcher spawned caffeinate: $(cat "$log")"
  fi

  kill "$pid1" 2>/dev/null || true
  wait "$pid1" 2>/dev/null || true
  wait_until 40 zero_live_stubs "$log" \
    || fail "assertion stayed live after the lock-owning watcher exited"
  pass "lock owner holds one assertion; a non-owner adds none; exit clears it"
}

test_successor_does_not_pile_up() {
  local dir state fakebin log pid1 pid2 i lock_pid
  dir=$(make_case successor)
  state="$dir/state"
  fakebin="$dir/fakebin"
  log="$dir/caffeinate.log"
  mark_pr_check_migration_complete "$state"
  : > "$log"
  export FM_FAKE_CAFFEINATE_LOG="$log"
  PATH="$fakebin:$PATH" FM_HOME="$dir" \
    FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/first.out" 2>"$dir/first.err" &
  pid1=$!
  fm_test_track_pid "$pid1"
  i=0
  while [ "$i" -lt 80 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid1" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$pid1" ] \
    || fail "first watcher did not take the lock"
  kill "$pid1" 2>/dev/null || true
  wait "$pid1" 2>/dev/null || true
  wait_until 40 zero_live_stubs "$log" \
    || fail "first watcher's assertion survived its exit"

  PATH="$fakebin:$PATH" FM_HOME="$dir" \
    FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/second.out" 2>"$dir/second.err" &
  pid2=$!
  fm_test_track_pid "$pid2"
  i=0
  lock_pid=
  while [ "$i" -lt 80 ]; do
    lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    [ "$lock_pid" = "$pid2" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$lock_pid" = "$pid2" ] || fail "successor watcher did not take the lock"

  if [ "$(uname)" = Darwin ]; then
    wait_until 40 log_has_w_pid "$pid2" "$log" \
      || fail "successor did not spawn a fresh assertion: $(cat "$log")"
    [ "$(live_stub_count "$log")" = 1 ] \
      || fail "successor chain piled up assertions: $(cat "$log")"
    [ "$(live_stub_count "$log" "$pid1")" = 0 ] \
      || fail "predecessor assertion was still live after successor start"
    [ "$(live_stub_count "$log" "$pid2")" = 1 ] \
      || fail "successor did not hold exactly one live assertion"
  else
    [ ! -s "$log" ] || fail "non-Darwin successor spawned caffeinate: $(cat "$log")"
  fi

  kill "$pid2" 2>/dev/null || true
  wait "$pid2" 2>/dev/null || true
  pass "successor chains keep one live assertion and drop the predecessor's"
}

test_darwin_stub_spawns_one_child_bound_to_pid
test_spawn_is_idempotent_in_one_process
test_child_dies_when_watched_pid_exits
test_hold_respawns_after_child_death
test_linux_is_a_clean_noop
test_missing_caffeinate_is_a_clean_noop
test_lock_owner_spawns_and_non_owner_does_not
test_successor_does_not_pile_up
