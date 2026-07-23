#!/usr/bin/env bash
# Behavior tests for bin/fm-browse-session.sh: naming, profile isolation,
# purge, and never-auto-connect guard logic (chrome-devtools-axi stubbed).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BROWSE_SH="$ROOT/bin/fm-browse-session.sh"
TMP=$(fm_test_tmproot fm-browse-session)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
HOME_DIR="$TMP/home"
STATE_DIR="$HOME_DIR/state"
mkdir -p "$STATE_DIR"

# Stub axi that records env + argv and never opens a real browser.
install_axi_stub() {
  local fakebin=$1
  mkdir -p "$fakebin"
  cat > "$fakebin/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_BROWSE_TEST_LOG:?}
{
  printf 'argv=%s\n' "$*"
  printf 'SESSION=%s\n' "${CHROME_DEVTOOLS_AXI_SESSION-<unset>}"
  printf 'USER_DATA_DIR=%s\n' "${CHROME_DEVTOOLS_AXI_USER_DATA_DIR-<unset>}"
  if [ -n "${CHROME_DEVTOOLS_AXI_AUTO_CONNECT+x}" ]; then
    printf 'AUTO_CONNECT=%s\n' "$CHROME_DEVTOOLS_AXI_AUTO_CONNECT"
  else
    printf 'AUTO_CONNECT=<unset>\n'
  fi
  if [ -n "${CHROME_DEVTOOLS_AXI_BROWSER_URL+x}" ]; then
    printf 'BROWSER_URL=%s\n' "$CHROME_DEVTOOLS_AXI_BROWSER_URL"
  else
    printf 'BROWSER_URL=<unset>\n'
  fi
} >> "$log"
case "${1:-}" in
  start|stop) exit 0 ;;
  *) echo "stub axi: unexpected command: ${1:-}" >&2; exit 1 ;;
esac
SH
  chmod +x "$fakebin/chrome-devtools-axi"
}

run_browse() {
  PATH="$1:$BASE_PATH" \
  FM_HOME="$HOME_DIR" \
  FM_STATE_OVERRIDE="$STATE_DIR" \
  FM_BROWSE_TEST_LOG="$2" \
    "$BROWSE_SH" "${@:3}"
}

test_help_exits_zero() {
  local out rc
  set +e
  out=$("$BROWSE_SH" --help 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "--help exit"
  assert_contains "$out" 'fm-browse-session.sh start' "--help usage"
  assert_contains "$out" 'docs/worker-browsing.md' "--help docs pointer"
  pass "fm-browse-session --help exits 0"
}

test_invalid_task_id_refuses() {
  local fakebin log out rc
  fakebin=$(fm_fakebin "$TMP/bad-id")
  install_axi_stub "$fakebin"
  log="$TMP/bad-id/axi.log"
  rm -f "$log"

  set +e
  out=$(run_browse "$fakebin" "$log" start '../evil' 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "path-unsafe id exit"
  assert_contains "$out" 'invalid task id' "path-unsafe id message"
  [ ! -s "$log" ] || fail "axi must not run for invalid id"
  pass "fm-browse-session refuses path-unsafe task ids"
}

test_start_names_session_and_isolates_profile() {
  local fakebin log out rc id profile
  id=task-browse-1
  fakebin=$(fm_fakebin "$TMP/start-ok")
  install_axi_stub "$fakebin"
  log="$TMP/start-ok/axi.log"
  : > "$log"

  set +e
  out=$(
    CHROME_DEVTOOLS_AXI_AUTO_CONNECT=1 \
    CHROME_DEVTOOLS_AXI_BROWSER_URL=http://127.0.0.1:9222 \
      run_browse "$fakebin" "$log" start "$id" 2>&1
  )
  rc=$?
  set -e
  expect_code 0 "$rc" "start exit"
  profile="$STATE_DIR/browse/$id/profile"
  [ -d "$profile" ] || fail "start did not create isolated profile dir"
  [ -f "$STATE_DIR/browse/$id/session.live" ] || fail "start did not write live marker"
  assert_contains "$(cat "$log")" "SESSION=$id" "named session equals task id"
  assert_contains "$(cat "$log")" "USER_DATA_DIR=$profile" "profile dir isolation"
  assert_contains "$(cat "$log")" 'AUTO_CONNECT=<unset>' \
    "never-auto-connect: AUTO_CONNECT stripped despite ambient=1"
  assert_contains "$(cat "$log")" 'BROWSER_URL=<unset>' \
    "never-auto-connect: BROWSER_URL stripped despite ambient attach URL"
  assert_contains "$(cat "$log")" 'argv=start' "start invokes axi start"
  assert_contains "$out" "session=$id" "start reports session"
  pass "start names the session and isolates the profile without auto-connect"
}

test_two_tasks_get_distinct_profiles() {
  local fakebin log a b
  fakebin=$(fm_fakebin "$TMP/two-tasks")
  install_axi_stub "$fakebin"
  log="$TMP/two-tasks/axi.log"
  : > "$log"
  run_browse "$fakebin" "$log" start task-a >/dev/null
  run_browse "$fakebin" "$log" start task-b >/dev/null
  a="$STATE_DIR/browse/task-a/profile"
  b="$STATE_DIR/browse/task-b/profile"
  [ -d "$a" ] && [ -d "$b" ] || fail "both profiles should exist"
  [ "$a" != "$b" ] || fail "profiles must be distinct paths"
  assert_contains "$(run_browse "$fakebin" "$log" list)" 'task_id=task-a' "list shows task-a"
  assert_contains "$(run_browse "$fakebin" "$log" list)" 'task_id=task-b' "list shows task-b"
  pass "two tasks get distinct profile dirs and both appear in list"
}

test_stop_retains_profile_purge_removes() {
  local fakebin log id profile
  id=task-purge-1
  fakebin=$(fm_fakebin "$TMP/purge")
  install_axi_stub "$fakebin"
  log="$TMP/purge/axi.log"
  : > "$log"
  run_browse "$fakebin" "$log" start "$id" >/dev/null
  profile="$STATE_DIR/browse/$id/profile"
  echo cookie > "$profile/marker"
  run_browse "$fakebin" "$log" stop "$id" >/dev/null
  [ -d "$profile" ] || fail "stop without --purge must retain profile"
  [ ! -f "$STATE_DIR/browse/$id/session.live" ] || fail "stop must clear live marker"
  assert_not_contains "$(run_browse "$fakebin" "$log" list)" "task_id=$id" \
    "list must omit stopped session"
  run_browse "$fakebin" "$log" start "$id" >/dev/null
  run_browse "$fakebin" "$log" stop "$id" --purge >/dev/null
  [ ! -e "$STATE_DIR/browse/$id" ] || fail "stop --purge must remove browse root"
  pass "stop retains profile; --purge removes the browse root"
}

test_teardown_source_purges_browse_dir() {
  # Contract: teardown best-effort stops+purges browse state for the task id.
  # shellcheck disable=SC2016
  assert_grep 'fm-browse-session.sh" stop "$ID" --purge' "$ROOT/bin/fm-teardown.sh" \
    "teardown must call browse-session stop --purge"
  # shellcheck disable=SC2016
  assert_grep 'rm -rf "$STATE/browse/$ID"' "$ROOT/bin/fm-teardown.sh" \
    "teardown must remove state/browse/<id>/"
  pass "teardown source includes additive browse purge hook"
}

test_axi_absent_refuses() {
  local fakebin out rc
  fakebin=$(fm_fakebin "$TMP/absent")
  # Empty fakebin first so host axi cannot win; do not install a stub.
  set +e
  out=$(
    PATH="$fakebin:$BASE_PATH" \
    FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$STATE_DIR" \
    env -u FM_BROWSE_AXI \
      "$BROWSE_SH" start task-missing 2>&1
  )
  rc=$?
  set -e
  expect_code 127 "$rc" "missing axi exit"
  assert_contains "$out" 'chrome-devtools-axi not found' "missing axi message"
  pass "fm-browse-session refuses when chrome-devtools-axi is absent"
}

test_help_exits_zero
test_invalid_task_id_refuses
test_start_names_session_and_isolates_profile
test_two_tasks_get_distinct_profiles
test_stop_retains_profile_purge_removes
test_teardown_source_purges_browse_dir
test_axi_absent_refuses
