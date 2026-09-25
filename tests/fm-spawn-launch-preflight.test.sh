#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh launch-binary preflight.
#
# These tests use a fake tmux endpoint and real isolated git worktrees.
# The missing-binary case asserts refusal before tmux is touched or task meta is written.
# The healthy cases assert all eight verified launch templates still reach the normal spawn path.
# Raw launch commands remain exempt because arbitrary shell syntax cannot be resolved reliably without executing it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
# PATH is pinned narrow on purpose: the missing-binary case needs 'opencode' to
# be genuinely absent whatever the developer has installed. node is the one
# exception - a claude spawn pre-registers workspace trust through it - so the
# single binary is linked into each case's fakebin rather than the npm bin
# directory (which carries opencode) being put on PATH.
NODE_BIN=$(command -v node 2>/dev/null || true)
# Same reasoning for python3: the kimi turn-end hook validates config.toml with
# tomllib, which macOS's /usr/bin/python3 does not carry.
PYTHON3_BIN=$(command -v python3 2>/dev/null || true)
TMP_ROOT=$(fm_test_tmproot fm-spawn-launch-preflight)

make_spawn_case() {
  local name=$1 harness=$2 launch_binary=${3:-} short_state=${4:-}
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  ENDPOINT_LOG="$CASE_DIR/endpoint.log"
  LAUNCH_LOG="$CASE_DIR/launch.log"
  PROBE_LOG="$CASE_DIR/probe.log"
  WINDOW_LOG="$CASE_DIR/windows.log"
  ID="preflight-$name"
  FAKEBIN_DIR=$(fm_fakebin "$CASE_DIR")
  STATE_DIR_SHORT=

  mkdir -p "$HOME_DIR/data/$ID" "$HOME_DIR/projects" "$HOME_DIR/config" "$HOME_DIR/user-home"
  # A kimi spawn installs its global turn-end hook into the launching user's own
  # Kimi config, and refuses when that config is absent; the pinned throwaway
  # HOME above therefore gets a minimal one.
  mkdir -p "$HOME_DIR/user-home/.kimi-code"
  printf '# test config\n' > "$HOME_DIR/user-home/.kimi-code/config.toml"
  if [ "$short_state" = 1 ]; then
    # prime-agent's per-task daemon socket lives under the state dir and AF_UNIX
    # caps sun_path at 104 bytes, so a TMPDIR-anchored state home is a REAL
    # runtime refusal on macOS, not a test artifact. These cases get a short
    # state dir, symlinked so $HOME_DIR/state assertions keep working. The
    # guard measures the PHYSICAL path (/tmp resolves to /private/tmp on
    # macOS), so the template must stay short enough for the longest case id
    # after that resolution.
    STATE_DIR_SHORT=$(mktemp -d /tmp/pa.XXXXXX)
    FM_TEST_CLEANUP_DIRS+=("$STATE_DIR_SHORT")
    ln -s "$STATE_DIR_SHORT" "$HOME_DIR/state"
  else
    mkdir -p "$HOME_DIR/state"
  fi
  printf '%s\n' "$harness" > "$HOME_DIR/config/crew-harness"
  cat > "$HOME_DIR/data/$ID/brief.md" <<EOF
# Task
## Captain's intent
brief for $ID

## Firstmate spec
Exercise the launch-binary preflight.
EOF
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
  # The launched harness owns the pane once it starts, which is what fm-spawn's
  # agent-up check reads before it reports success or types a post-launch brief.
  *"#{pane_current_command}"*) printf '%s\n' "${FM_FAKE_PANE_COMMAND:-firstmate}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  new-window)
    # Record the created window so list-windows can report it: fm-spawn's
    # agent-up gate reads the window inventory before reporting a spawn as
    # started, and a stub that lists nothing reads as a vanished endpoint.
    prev=
    for arg in "$@"; do
      [ "$prev" != "-n" ] || printf '%s\n' "$arg" >> "${FM_FAKE_WINDOW_LOG:?}"
      prev=$arg
    done
    printf '@42\n'
    exit 0
    ;;
  list-windows)
    [ ! -f "${FM_FAKE_WINDOW_LOG:?}" ] || cat "$FM_FAKE_WINDOW_LOG"
    exit 0
    ;;
  has-session|new-session|set-window-option|kill-window) exit 0 ;;
  send-keys)
    prev=
    for arg in "$@"; do
      if [ "$prev" = "-l" ]; then
        # A spawn types a short line sourcing its staged launch file; log the
        # staged command itself.
        case "$arg" in
          ". '"*"'") staged=${arg#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || arg=$(cat "$staged") ;;
        esac
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
  [ -z "$NODE_BIN" ] || ln -sf "$NODE_BIN" "$FAKEBIN_DIR/node"
  [ -z "$PYTHON3_BIN" ] || ln -sf "$PYTHON3_BIN" "$FAKEBIN_DIR/python3"

  # Once the launch lands, the harness binary is the pane's foreground command.
  # kimi needs that to be readable: its brief is typed into the agent after the
  # launch, so fm-spawn refuses to deliver it until liveness is proven.
  export FM_FAKE_PANE_COMMAND="$launch_binary"
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

# Every case here is a ship spawn, and fm-spawn requires each ship task's
# delivery contract explicitly, so the suite pins one rather than repeating it
# at eleven call sites; no case under test depends on which contract it is.
run_spawn() {
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="${STATE_DIR_SHORT:-$HOME_DIR/state}" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_PANE_COMMAND="${FM_FAKE_PANE_COMMAND:-}" FM_SPAWN_AGENT_UP_SLEEP=0 \
    FM_FAKE_ENDPOINT_LOG="$ENDPOINT_LOG" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    FM_FAKE_PROBE_LOG="$PROBE_LOG" FM_FAKE_WINDOW_LOG="$WINDOW_LOG" \
    GROK_HOME="$HOME_DIR/grok-home" \
    FM_PRIME_AGENT_SOURCE_HOME="$HOME_DIR/no-prime-home" \
    HOME="$HOME_DIR/user-home" CLAUDE_CONFIG_DIR='' \
    PATH="$FAKEBIN_DIR:/usr/bin:/bin" "$SPAWN" "$@" --mode no-mistakes --yolo off 2>&1
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
  local harness launch_binary short_state out status
  # kimi post-launch brief settle is irrelevant to preflight; keep the suite fast.
  export FM_KIMI_BRIEF_SETTLE_SECS=0
  while IFS='|' read -r harness launch_binary short_state; do
    make_spawn_case "present-$harness" "$harness" "$launch_binary" "$short_state"

    out=$(run_spawn "$ID" "$PROJ_DIR")
    status=$?

    [ "$status" -eq 0 ] || printf '%s\n' "$out" >&2
    expect_code 0 "$status" "present $harness launch binary should spawn"
    assert_contains "$out" "spawned $ID harness=$harness" "$harness spawn did not reach the healthy path"
    assert_grep "$launch_binary --version" "$PROBE_LOG" "$harness did not run the expected cheap version probe"
    assert_grep "new-window" "$ENDPOINT_LOG" "$harness did not create the normal tmux endpoint"
    assert_present "$HOME_DIR/state/$ID.meta" "$harness healthy spawn did not write task meta"
    cleanup_task_tmp "$ID"
  done <<'EOF'
claude|claude|
codex|codex|
opencode|opencode|
pi|pi|
grok|grok|
cursor|cursor-agent|
prime-agent|prime-agent|1
EOF
  pass "the verified adapters preflight and spawn normally when their binaries are present"
}

# kimi is held out of the table above because its brief is delivered AFTER the
# launch, through a TUI readiness gate that needs a full rendered-screen
# fixture; tests/fm-kimi-harness.test.sh owns that. What belongs here is that
# the preflight still probes kimi's binary and still lets the endpoint be
# created, so the spawn's own later gate is what decides the outcome.
test_kimi_preflights_and_reaches_its_own_post_launch_gate() {
  local out
  make_spawn_case present-kimi kimi kimi
  out=$(run_spawn "$ID" "$PROJ_DIR") || true
  assert_grep "kimi --version" "$PROBE_LOG" "kimi did not run the expected cheap version probe"
  assert_grep "new-window" "$ENDPOINT_LOG" "kimi did not create the normal tmux endpoint"
  assert_not_contains "$out" "refusing before creating a task endpoint"     "kimi was refused by the launch-binary preflight"
  cleanup_task_tmp "$ID"
  pass "kimi preflights its binary and reaches its own post-launch readiness gate"
}

# Every spawn-driving suite in this tree clears the preflight above with the
# shared tests/lib.sh shim rather than a hand-rolled stub, so that helper is
# what stands between those suites and the missing-binary refusal on any host
# without the real CLI - which is every CI runner. Prove it against the same
# preflight, on the same code path, as the refusal case above: identical
# harness, identical fixture, the shim the only difference.
test_shared_launch_binary_shim_clears_the_preflight() {
  local out status
  make_spawn_case shimmed-opencode opencode opencode
  fm_fake_launch_binary "$FAKEBIN_DIR" opencode

  out=$(run_spawn "$ID" "$PROJ_DIR")
  status=$?

  expect_code 0 "$status" "the shared launch-binary shim should clear the preflight"
  assert_contains "$out" "spawned $ID harness=opencode" "shimmed launch binary did not reach the healthy spawn path"
  assert_grep "new-window" "$ENDPOINT_LOG" "shimmed launch binary did not create the normal tmux endpoint"
  assert_present "$HOME_DIR/state/$ID.meta" "shimmed launch binary did not write task meta"
  cleanup_task_tmp "$ID"
  pass "the shared launch-binary shim clears the preflight that refuses the same spawn without it"
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
  # The raw command runs verbatim; only the spawn's shared environment exports
  # (compact-adviser kill switch, commit-msg hook path) may precede it.
  case "$launch" in
    "custom-agent --flag" | *"; custom-agent --flag") ;;
    *) fail "raw launch command changed"$'\n'"actual: $launch" ;;
  esac
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

test_prime_agent_default_model_folds_to_free_route() {
  local out status launch
  make_spawn_case pa-default prime-agent prime-agent 1

  out=$(run_spawn "$ID" "$PROJ_DIR")
  status=$?

  expect_code 0 "$status" "prime-agent spawn with no --model should succeed"
  launch=$(cat "$LAUNCH_LOG")
  # The CLI's own default is a PAID route (verified 2026-08-07: a model-less
  # launch 401s on the free Zen key), so fm-spawn always emits an explicit
  # validated --model; absent --model folds to the verified-free Zen model.
  assert_contains "$launch" "--model 'opencode/deepseek-v4-flash-free'" \
    "prime-agent launch did not carry the folded free default model"
  assert_contains "$launch" "PRIME_AGENT_CODING_AGENT_DIR=" "prime-agent launch lost its containment agent dir"
  assert_contains "$launch" "PRIME_AGENT_KERNEL_VENV=" "prime-agent launch lost its kernel-venv containment"
  assert_contains "$launch" "--daemon-socket" "prime-agent launch lost its per-task daemon socket"
  assert_grep "model=opencode/deepseek-v4-flash-free" "$HOME_DIR/state/$ID.meta" \
    "prime-agent meta did not record the folded launch model"
  cleanup_task_tmp "$ID"
  pass "prime-agent absent --model folds to the verified-free route, contained and socket-scoped"
}

test_prime_agent_billed_route_refused_before_endpoint_creation() {
  local out status model
  for model in anthropic/claude-opus-5 anthropic/claude-pro-max opencode/gpt-5.6-sol openai/gpt-5; do
    make_spawn_case "pa-billed-$(printf '%s' "$model" | tr '/.' '--')" prime-agent prime-agent 1

    out=$(run_spawn "$ID" "$PROJ_DIR" --model "$model")
    status=$?

    expect_code 1 "$status" "billed/unverified prime-agent route $model should fail"
    assert_contains "$out" \
      "error: prime-agent model '$model' is not a subscription-quota route" \
      "refusal for $model did not name the route guard"
    [ ! -s "$ENDPOINT_LOG" ] || fail "billed-route refusal for $model touched tmux before failing"
    assert_absent "$HOME_DIR/state/$ID.meta" "billed-route refusal for $model wrote task meta"
  done
  pass "prime-agent per-token-billed and unverified routes are refused before endpoint creation"
}

test_prime_agent_subscription_routes_pass_the_guard() {
  local out status model
  for model in opencode/big-pickle opencode/deepseek-v4-flash-free openai-codex/gpt-5.6-sol; do
    make_spawn_case "pa-ok-$(printf '%s' "$model" | tr '/.' '--')" prime-agent prime-agent 1

    out=$(run_spawn "$ID" "$PROJ_DIR" --model "$model")
    status=$?

    expect_code 0 "$status" "subscription-quota prime-agent route $model should spawn"
    assert_contains "$out" "spawned $ID harness=prime-agent" "$model did not reach the healthy spawn path"
    cleanup_task_tmp "$ID"
  done
  pass "prime-agent subscription-quota routes pass the guard"
}

test_missing_verified_binary_refuses_before_endpoint_creation
test_present_verified_binaries_spawn_as_before
test_kimi_preflights_and_reaches_its_own_post_launch_gate
test_shared_launch_binary_shim_clears_the_preflight
test_raw_launch_command_remains_exempt
test_hanging_version_probe_times_out_before_endpoint_creation
test_sigterm_ignoring_probe_is_killed_after_grace
test_timed_out_probe_leaves_no_wrapper_descendants
test_probe_closes_stdin
test_invalid_probe_timeout_knob_refuses
test_prime_agent_default_model_folds_to_free_route
test_prime_agent_billed_route_refused_before_endpoint_creation
test_prime_agent_subscription_routes_pass_the_guard

echo "# all fm-spawn launch-preflight tests passed"
