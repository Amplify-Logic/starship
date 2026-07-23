#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh launch-binary preflight.
#
# These tests use a fake tmux endpoint and real isolated git worktrees.
# The missing-binary case asserts refusal before tmux is touched or task meta is written.
# The healthy cases assert all seven verified launch templates still reach the normal spawn path.
# Raw launch commands remain exempt because arbitrary shell syntax cannot be resolved reliably without executing it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-launch-preflight)

make_spawn_case() {
  local name=$1 harness=$2 launch_binary=${3:-}
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  ENDPOINT_LOG="$CASE_DIR/endpoint.log"
  LAUNCH_LOG="$CASE_DIR/launch.log"
  PROBE_LOG="$CASE_DIR/probe.log"
  ID="preflight-$name"
  FAKEBIN_DIR=$(fm_fakebin "$CASE_DIR")

  mkdir -p "$HOME_DIR/data/$ID" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config"
  printf '%s\n' "$harness" > "$HOME_DIR/config/crew-harness"
  printf 'brief for %s\n' "$ID" > "$HOME_DIR/data/$ID/brief.md"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  touch "$HOME_DIR/state/.last-watcher-beat"
  : > "$ENDPOINT_LOG"
  : > "$LAUNCH_LOG"

  cat > "$FAKEBIN_DIR/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_ENDPOINT_LOG:?}"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  new-window) printf '@42\n'; exit 0 ;;
  list-windows|has-session|new-session|set-window-option|kill-window) exit 0 ;;
  send-keys)
    prev=
    for arg in "$@"; do
      if [ "$prev" = "-l" ]; then
        printf '%s\n' "$arg" >> "${FM_FAKE_LAUNCH_LOG:?}"
      fi
      prev=$arg
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN_DIR/tmux"
  fm_fake_exit0 "$FAKEBIN_DIR" treehouse

  if [ -n "$launch_binary" ]; then
    cat > "$FAKEBIN_DIR/$launch_binary" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s %s\n' "$(basename "$0")" "$*" >> "${FM_FAKE_PROBE_LOG:?}"
[ "$#" -eq 1 ] && [ "$1" = "--version" ]
SH
    chmod +x "$FAKEBIN_DIR/$launch_binary"
  fi
}

run_spawn() {
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_ENDPOINT_LOG="$ENDPOINT_LOG" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    FM_FAKE_PROBE_LOG="$PROBE_LOG" GROK_HOME="$HOME_DIR/grok-home" \
    PATH="$FAKEBIN_DIR:/usr/bin:/bin" "$SPAWN" "$@" 2>&1
}

cleanup_task_tmp() {
  rm -rf "/tmp/fm-$1"
}

test_missing_verified_binary_refuses_before_endpoint_creation() {
  local out status
  make_spawn_case missing-opencode opencode

  out=$(run_spawn "$ID" "$PROJ_DIR")
  status=$?

  expect_code 1 "$status" "missing verified launch binary should fail"
  assert_contains "$out" \
    "error: harness 'opencode' launch binary 'opencode' was not found (install: npm install -g opencode-ai); refusing before creating a task endpoint" \
    "missing-binary refusal did not name the binary and exact install hint"
  [ ! -s "$ENDPOINT_LOG" ] || fail "missing-binary refusal touched tmux before failing"
  assert_absent "$HOME_DIR/state/$ID.meta" "missing-binary refusal wrote task meta"
  assert_absent "$PROBE_LOG" "missing binary unexpectedly ran a version probe"
  pass "missing verified binary is refused before endpoint creation or meta"
}

test_present_verified_binaries_spawn_as_before() {
  local harness launch_binary out status
  # kimi post-launch brief settle is irrelevant to preflight; keep the suite fast.
  export FM_KIMI_BRIEF_SETTLE_SECS=0
  while IFS='|' read -r harness launch_binary; do
    make_spawn_case "present-$harness" "$harness" "$launch_binary"

    out=$(run_spawn "$ID" "$PROJ_DIR")
    status=$?

    expect_code 0 "$status" "present $harness launch binary should spawn"
    assert_contains "$out" "spawned $ID harness=$harness" "$harness spawn did not reach the healthy path"
    assert_grep "$launch_binary --version" "$PROBE_LOG" "$harness did not run the expected cheap version probe"
    assert_grep "new-window" "$ENDPOINT_LOG" "$harness did not create the normal tmux endpoint"
    assert_present "$HOME_DIR/state/$ID.meta" "$harness healthy spawn did not write task meta"
    cleanup_task_tmp "$ID"
  done <<'EOF'
claude|claude
codex|codex
opencode|opencode
pi|pi
grok|grok
cursor|agent
kimi|kimi
EOF
  pass "all seven verified adapters preflight and spawn normally when their binaries are present"
}

test_raw_launch_command_remains_exempt() {
  local out status launch
  make_spawn_case raw-exempt claude

  out=$(run_spawn "$ID" "$PROJ_DIR" "custom-agent --flag")
  status=$?

  expect_code 0 "$status" "raw launch command should remain exempt from verified-adapter preflight"
  assert_contains "$out" "spawned $ID harness=custom-agent" "raw launch command did not spawn"
  assert_absent "$PROBE_LOG" "raw launch command unexpectedly ran a first-word probe"
  launch=$(cat "$LAUNCH_LOG")
  [ "$launch" = "custom-agent --flag" ] || fail "raw launch command changed"$'\n'"actual: $launch"
  cleanup_task_tmp "$ID"
  pass "raw launch command stays exempt from preflight and is sent unchanged"
}

test_hanging_version_probe_times_out_before_endpoint_creation() {
  local out status
  make_spawn_case hang-probe opencode
  cat > "$FAKEBIN_DIR/opencode" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s %s\n' "$(basename "$0")" "$*" >> "${FM_FAKE_PROBE_LOG:?}"
sleep 60
SH
  chmod +x "$FAKEBIN_DIR/opencode"

  out=$(FM_SPAWN_PROBE_TIMEOUT_SECS=1 run_spawn "$ID" "$PROJ_DIR")
  status=$?

  expect_code 1 "$status" "hanging version probe should fail"
  assert_contains "$out" \
    "error: harness 'opencode' launch binary 'opencode' --version probe timed out after 1s (raise with FM_SPAWN_PROBE_TIMEOUT_SECS); refusing before creating a task endpoint" \
    "timeout refusal did not name the binary and override knob"
  [ ! -s "$ENDPOINT_LOG" ] || fail "timed-out probe touched tmux before failing"
  assert_absent "$HOME_DIR/state/$ID.meta" "timed-out probe wrote task meta"
  pass "hanging version probe times out and refuses before endpoint creation or meta"
}

test_sigterm_ignoring_probe_is_killed_after_grace() {
  local out status
  make_spawn_case hang-sigterm opencode
  cat > "$FAKEBIN_DIR/opencode" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s %s\n' "$(basename "$0")" "$*" >> "${FM_FAKE_PROBE_LOG:?}"
trap '' TERM
while :; do sleep 1; done
SH
  chmod +x "$FAKEBIN_DIR/opencode"

  out=$(FM_SPAWN_PROBE_TIMEOUT_SECS=1 run_spawn "$ID" "$PROJ_DIR")
  status=$?

  expect_code 1 "$status" "SIGTERM-ignoring probe should still fail via SIGKILL escalation"
  assert_contains "$out" \
    "error: harness 'opencode' launch binary 'opencode' --version probe timed out after 1s (raise with FM_SPAWN_PROBE_TIMEOUT_SECS); refusing before creating a task endpoint" \
    "SIGTERM-ignoring probe did not produce the timeout refusal"
  [ ! -s "$ENDPOINT_LOG" ] || fail "SIGTERM-ignoring probe touched tmux before failing"
  assert_absent "$HOME_DIR/state/$ID.meta" "SIGTERM-ignoring probe wrote task meta"
  pass "SIGTERM-ignoring probe is force-killed after a bounded grace period"
}

test_timed_out_probe_leaves_no_wrapper_descendants() {
  local out status child_pid tries
  make_spawn_case hang-descendant opencode
  local child_pid_file="$CASE_DIR/hang-descendant-child.pid"
  cat > "$FAKEBIN_DIR/opencode" <<SH
#!/usr/bin/env bash
set -u
printf '%s %s\n' "\$(basename "\$0")" "\$*" >> "\${FM_FAKE_PROBE_LOG:?}"
bash -c 'trap "" TERM; echo \$\$ > "$child_pid_file"; while :; do sleep 1; done' &
wait
SH
  chmod +x "$FAKEBIN_DIR/opencode"

  out=$(FM_SPAWN_PROBE_TIMEOUT_SECS=1 run_spawn "$ID" "$PROJ_DIR")
  status=$?

  expect_code 1 "$status" "wrapper probe with hanging descendant should time out"
  assert_contains "$out" \
    "error: harness 'opencode' launch binary 'opencode' --version probe timed out after 1s (raise with FM_SPAWN_PROBE_TIMEOUT_SECS); refusing before creating a task endpoint" \
    "wrapper probe did not produce the timeout refusal"
  [ -s "$child_pid_file" ] || fail "wrapper never recorded its descendant pid"
  child_pid=$(cat "$child_pid_file")
  tries=0
  while kill -0 "$child_pid" 2>/dev/null && [ "$tries" -lt 20 ]; do
    sleep 0.1
    tries=$((tries + 1))
  done
  if kill -0 "$child_pid" 2>/dev/null; then
    kill -9 "$child_pid" 2>/dev/null
    fail "TERM-resistant descendant (pid $child_pid) survived the timed-out probe"
  fi
  [ ! -s "$ENDPOINT_LOG" ] || fail "wrapper probe touched tmux before failing"
  assert_absent "$HOME_DIR/state/$ID.meta" "wrapper probe wrote task meta"
  pass "timed-out probe kills TERM-resistant wrapper descendants via its process group"
}

test_probe_closes_stdin() {
  local out status
  make_spawn_case stdin-probe opencode
  cat > "$FAKEBIN_DIR/opencode" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s %s\n' "$(basename "$0")" "$*" >> "${FM_FAKE_PROBE_LOG:?}"
cat >/dev/null
exit 0
SH
  chmod +x "$FAKEBIN_DIR/opencode"

  out=$(FM_SPAWN_PROBE_TIMEOUT_SECS=2 run_spawn "$ID" "$PROJ_DIR" < /dev/zero)
  status=$?

  expect_code 0 "$status" "stdin-reading probe should finish immediately because stdin is closed"
  assert_contains "$out" "spawned $ID harness=opencode" "stdin-closed probe did not reach the healthy spawn path"
  cleanup_task_tmp "$ID"
  pass "version probe runs with stdin closed"
}

test_invalid_probe_timeout_knob_refuses() {
  local out status
  make_spawn_case bad-knob opencode opencode

  out=$(FM_SPAWN_PROBE_TIMEOUT_SECS=soon run_spawn "$ID" "$PROJ_DIR")
  status=$?

  expect_code 1 "$status" "invalid FM_SPAWN_PROBE_TIMEOUT_SECS should fail"
  assert_contains "$out" \
    "error: FM_SPAWN_PROBE_TIMEOUT_SECS must be a positive integer number of seconds (got 'soon'); refusing before creating a task endpoint" \
    "invalid knob refusal did not name the knob and value"
  [ ! -s "$ENDPOINT_LOG" ] || fail "invalid knob touched tmux before failing"
  assert_absent "$HOME_DIR/state/$ID.meta" "invalid knob wrote task meta"
  pass "invalid probe timeout knob is refused before endpoint creation"
}

test_missing_verified_binary_refuses_before_endpoint_creation
test_present_verified_binaries_spawn_as_before
test_raw_launch_command_remains_exempt
test_hanging_version_probe_times_out_before_endpoint_creation
test_sigterm_ignoring_probe_is_killed_after_grace
test_timed_out_probe_leaves_no_wrapper_descendants
test_probe_closes_stdin
test_invalid_probe_timeout_knob_refuses

echo "# all fm-spawn launch-preflight tests passed"
