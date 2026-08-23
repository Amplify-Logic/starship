#!/usr/bin/env bash
# fm-send per-task supervisor steer counter (state/<id>.steers).
#
# Teardown's capability outcome log records how many supervisor steers a task
# received, so every confirmed text submit to a task-selector target must
# append exactly one line to that task's volatile counter file. These tests pin
# that behavior hermetically (stubbed tmux, no real agent):
#   1. Confirmed sends to an exact-id or stable-label task target count once each.
#   2. Explicit backend targets never write a counter (no task identity).
#   3. The --key path never counts.
#   4. A swallowed Enter (pending verdict) is not a delivered steer and never counts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-steer-count)

# The same hermetic submit stub used across the fm-send suites: display-message
# yields a numeric cursor_y; capture-pane's FM_STEER_COMPOSER value decides the
# verdict - an empty bordered composer reads "empty" (submit landed), a bordered
# composer with text reads "pending" (Enter swallowed).
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys) exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '0\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '%s\n' "${FM_STEER_COMPOSER:-$(printf '\xe2\x94\x82 \xe2\x94\x82')}"; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/tmux" "$fb/sleep"
  printf '%s\n' "$fb"
}

setup_home() {  # <name> -> echoes home dir with a crewmate task meta
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  fm_write_meta "$home/state/build.meta" \
    "window=sess:fm-build" "worktree=$home/wt" "project=$home/p" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  printf '%s\n' "$home"
}

run_send() {  # <fakebin> <home> <fm-send args...>
  local fb=$1 home=$2; shift 2
  # Extra caller environment (e.g. FM_STEER_COMPOSER) may prefix the call.
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_SETTLE=0 \
    "$SEND" "$@" 2>/dev/null
}

test_confirmed_sends_count_once_each() {
  local dir fb home rc
  dir="$TMP_ROOT/count"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  home=$(setup_home count)
  run_send "$fb" "$home" "fm-build" "fix the flaky test"; rc=$?
  expect_code 0 "$rc" "first confirmed steer should succeed"
  run_send "$fb" "$home" "build" "rerun the suite"; rc=$?
  expect_code 0 "$rc" "second confirmed steer should succeed"
  [ "$(wc -l < "$home/state/build.steers" | tr -d ' ')" = 2 ] \
    || fail "two confirmed steers must append two counter lines"$'\n'"--- counter ---"$'\n'"$(cat "$home/state/build.steers")"
  pass "fm-send appends one steer line per confirmed task-target submit"
}

test_explicit_target_never_counts() {
  local dir fb home rc
  dir="$TMP_ROOT/explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  home=$(setup_home explicit)
  run_send "$fb" "$home" "sess:win" "hello there"; rc=$?
  expect_code 0 "$rc" "explicit-target send should succeed"
  [ ! -e "$home/state/build.steers" ] \
    || fail "an explicit backend target without task identity must not write a counter"
  pass "explicit backend targets leave no steer counter"
}

test_explicit_recorded_target_never_counts() {
  local dir fb home rc
  dir="$TMP_ROOT/explicit-recorded"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  home=$(setup_home explicit-recorded)
  run_send "$fb" "$home" "sess:fm-build" "hello recorded endpoint"; rc=$?
  expect_code 0 "$rc" "explicit recorded-target send should succeed"
  [ ! -e "$home/state/build.steers" ] \
    || fail "an explicit backend target matching task metadata must not write a counter"
  pass "explicit recorded backend targets leave no steer counter"
}

test_key_path_never_counts() {
  local dir fb home rc
  dir="$TMP_ROOT/keypath"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  home=$(setup_home keypath)
  run_send "$fb" "$home" "build" --key Enter; rc=$?
  expect_code 0 "$rc" "--key send should succeed"
  [ ! -e "$home/state/build.steers" ] \
    || fail "the --key path is not a steer and must not write a counter"
  pass "the --key path leaves no steer counter"
}

test_swallowed_enter_never_counts() {
  local dir fb home rc
  dir="$TMP_ROOT/pending"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  home=$(setup_home pending)
  FM_STEER_COMPOSER="$(printf '\xe2\x94\x82 leftover \xe2\x94\x82')" \
    run_send "$fb" "$home" "build" "this enter will be swallowed"; rc=$?
  [ "$rc" -ne 0 ] || fail "a swallowed Enter must fail the send loudly, got exit 0"
  [ ! -e "$home/state/build.steers" ] \
    || fail "a submit firstmate could not confirm must not count as a steer"
  pass "unconfirmed submits leave no steer counter"
}

test_confirmed_sends_count_once_each
test_explicit_target_never_counts
test_explicit_recorded_target_never_counts
test_key_path_never_counts
test_swallowed_enter_never_counts

echo "# all fm-send-steer-count tests passed"
