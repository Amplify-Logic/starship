#!/usr/bin/env bash
# tests/fm-watch-presentation.test.sh - the watcher's captain-facing pane
# relabel on a coalesced signal set (bin/fm-watch.sh ->
# bin/fm-visible-status.sh --all).
#
# The reported failure: with two dozen task records and a slow Herdr, the
# relabel ran inline on the signal path for minutes, the liveness beacon went
# stale past its budget, and the guard then refused to re-arm supervision
# because the lock was held by a live pid whose heartbeat had lapsed. These
# cases drive a real fm-watch.sh against a fixture fleet of 22 records and a
# deliberately slow backend, and assert the two properties that fix it: the
# beacon keeps advancing while the relabel is still in flight, and one
# coalesced signal set starts at most one relabel pass.
#
# The pass's own bounds (per call, per task, per pass), its published-label
# cache and its single-flight lock live in tests/fm-visible-status.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-presentation)
FLEET=22

# Slow only on the presentation round trips, so the watcher's own backend use
# stays fast and the only delay under test is the relabel's.
install_slow_herdr() {  # <fakebin>
  cat > "$1/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_VISIBLE_HERDR_LOG"
case "$*" in
  *"tab rename"*|*"pane report-metadata"*|*"workspace rename"*)
    sleep "${FM_FAKE_HERDR_SLEEP:-1}" ;;
esac
exit 0
SH
  chmod +x "$1/herdr"
}

write_fleet() {  # <state> <states-file>
  local state=$1 states=$2 i=1 project
  : > "$states"
  while [ "$i" -le "$FLEET" ]; do
    project=$(( (i % 3) + 1 ))
    fm_write_meta "$state/big-$i.meta" \
      "worktree=$state/no-such-worktree" \
      "project=/projects/big-$project" \
      "harness=pi" \
      "model=default" \
      "kind=ship" \
      "backend=herdr" \
      "herdr_session=fm-lab-big" \
      "herdr_workspace_id=bw$project" \
      "herdr_tab_id=bt$i" \
      "herdr_pane_id=bw$project:p$i" \
      "herdr_workspace_managed=1" \
      "herdr_project_name=Big $project" \
      "herdr_project_key=/projects/big-$project"
    printf 'big-%s=working\n' "$i" >> "$states"
    i=$((i + 1))
  done
}

file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

# Wait until the beacon advances once, or the watcher exits. 0 advanced, 1 not.
beacon_advanced() {  # <state> <pid> [limit-ticks]
  local state=$1 pid=$2 limit=${3:-100} beat first now i=0
  beat="$state/.last-watcher-beat"
  first=$(file_mtime "$beat")
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(file_mtime "$beat")
    [ -n "$now" ] && [ "$now" != "$first" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

relabel_calls() {  # <log>
  grep -c 'tab rename bt' "$1" 2>/dev/null || true
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

test_relabel_never_blocks_the_liveness_beacon() {
  local dir state fakebin log states out pid started elapsed inflight i
  dir=$(make_case relabel-detached); state="$dir/state"; fakebin="$dir/fakebin"
  log="$dir/herdr.log"; states="$dir/states"; out="$dir/watch.out"
  install_slow_herdr "$fakebin"
  write_fleet "$state" "$states"
  : > "$log"
  printf 'working: compiling step 2\n' > "$state/big-1.status"
  # A busy crew makes this no-verb note absorbable, so the watcher keeps
  # polling after the coalesced set instead of exiting on it.
  export FM_FAKE_CREW_STATE='state: working · source: run-step · running'
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_VISIBLE_HERDR_LOG="$log" FM_VISIBLE_STATE_FILE="$states" \
    FM_BACKEND_HERDR_PRESENTATION_FORCE=1 FM_FAKE_HERDR_SLEEP=1 \
    "$WATCH" > "$out" &
  pid=$!
  # Wait for the relabel to be provably under way, then prove the beacon is
  # still advancing while it runs. A 22-task pass at one second per round trip
  # needs far longer than the two beats asserted here.
  i=0
  while [ "$(relabel_calls "$log")" -lt 1 ]; do
    kill -0 "$pid" 2>/dev/null || { reap "$pid"; unset FM_FAKE_CREW_STATE; fail "watcher exited before the relabel started: $(cat "$out")"; }
    [ "$i" -lt 300 ] || { reap "$pid"; unset FM_FAKE_CREW_STATE; fail 'the coalesced signal set never started a relabel'; }
    sleep 0.1
    i=$((i + 1))
  done
  started=$SECONDS
  beacon_advanced "$state" "$pid" \
    || { reap "$pid"; unset FM_FAKE_CREW_STATE; fail 'the liveness beacon stopped while the relabel ran'; }
  beacon_advanced "$state" "$pid" \
    || { reap "$pid"; unset FM_FAKE_CREW_STATE; fail 'the liveness beacon advanced only once while the relabel ran'; }
  elapsed=$((SECONDS - started))
  inflight=$(relabel_calls "$log")
  [ "$elapsed" -le 10 ] \
    || { reap "$pid"; unset FM_FAKE_CREW_STATE; fail "the beacon took ${elapsed}s to advance twice while the relabel ran"; }
  [ "$inflight" -lt "$FLEET" ] \
    || { reap "$pid"; unset FM_FAKE_CREW_STATE; fail 'the relabel finished before the beacon advanced, so nothing was proven'; }
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass 'watcher presentation: a slow pane relabel never delays the liveness beacon'
}

test_one_relabel_pass_per_coalesced_set() {
  local dir state fakebin log states out pid i duplicates
  dir=$(make_case relabel-once); state="$dir/state"; fakebin="$dir/fakebin"
  log="$dir/herdr.log"; states="$dir/states"; out="$dir/watch.out"
  install_slow_herdr "$fakebin"
  write_fleet "$state" "$states"
  : > "$log"
  # Two signals seconds apart are one coalesced set, and one relabel.
  printf 'working: compiling step 2\n' > "$state/big-1.status"
  : > "$state/big-2.turn-ended"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · running'
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_VISIBLE_HERDR_LOG="$log" FM_VISIBLE_STATE_FILE="$states" \
    FM_BACKEND_HERDR_PRESENTATION_FORCE=1 FM_FAKE_HERDR_SLEEP=0 \
    "$WATCH" > "$out" &
  pid=$!
  # Let the coalesced set be handled and its pass complete, then keep polling
  # long enough that a per-poll relabel would show up as a second pass.
  i=0
  while [ "$(relabel_calls "$log")" -lt "$FLEET" ]; do
    kill -0 "$pid" 2>/dev/null || break
    [ "$i" -lt 600 ] || break
    sleep 0.1
    i=$((i + 1))
  done
  sleep 4
  duplicates=$(grep -o 'tab rename bt[0-9]* ' "$log" 2>/dev/null | LC_ALL=C sort | uniq -c \
    | awk '$1 > 1 { print }' | wc -l | tr -d '[:space:]')
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  [ "$(relabel_calls "$log")" -ge 1 ] || fail 'the coalesced set started no relabel at all'
  [ "$duplicates" -eq 0 ] \
    || fail "$duplicates task tabs were relabelled more than once for a single coalesced signal set"
  pass 'watcher presentation: one coalesced signal set starts at most one relabel pass'
}

test_relabel_never_blocks_the_liveness_beacon
test_one_relabel_pass_per_coalesced_set
