#!/usr/bin/env bash
# Regression tests for fm-spawn.sh's agent-up verification (bin/fm-spawn.sh,
# spawn_wait_agent_up / spawn_refuse_agent_never_started).
#
# The bug these pin: until an agent actually owns the pane, everything typed
# there is SHELL input. When the launch never started the agent, nothing ever
# read the brief, yet fm-spawn still reported "spawned", so the pane looked
# alive and a later steer "succeeded" into that same shell. kimi and rovo make
# it worse, because their brief pointer is TYPED into the pane after the launch
# rather than named on it.
#
# Asserted here, with a fake tmux whose window inventory and pane_current_command
# drive the shared liveness owner (fm_backend_tmux_agent_state):
#   1. kimi's post-launch brief is typed only AFTER the agent is proven up.
#   2. A pane still proven to be a bare shell refuses loudly at the bound,
#      without typing the brief. Dispatch is transactional, so the refusal rolls
#      this task's provisional record back and says so, names what does survive
#      (the endpoint, the local copy, the brief), and hands back the exact
#      re-spawn rather than an in-pane relaunch that would leave a worker the
#      backlog does not own.
#   3. The happy path is unchanged: the launch line still names the brief file
#      and the spawn still reports success.
#   4. A harness/backend pair whose liveness cannot be read (pi's generic node
#      process on tmux) neither refuses nor stalls to the bound.
#   5. The wait is bounded, and its knobs are validated before anything is
#      typed into the pane.
#   6. A structurally gone endpoint refuses on the FIRST read rather than
#      waiting out a bound whose answer can never change.
#
# One case needs a different backend, because the state it pins is one tmux can
# never report:
#   7. A backend with NO liveness reader at all (fake Orca) cannot run the check.
#      That is an unsupported check, not a failed one, so kimi still spawns
#      there and warns instead of losing a capability that worked before.
#   8. A raw `--harness "<command>"` (the unverified-adapter escape hatch) is
#      never gated: its pane may legitimately never read as a known agent.
#   9. A refused --relaunch rolls nothing back: it says the replacement record
#      was already published and kept, and hands back the same --relaunch,
#      never a fresh spawn.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-agent-up)

# make_case <name> <harness> <launch-binary>: a home, a real worktree, and a
# fake tmux that records an ORDERED event log so "typed before proven up" is
# directly observable:
#   probe:<command>   one pane_current_command read (what the liveness owner saw)
#   literal:<text>    one `send-keys -l` literal (the launch line, or the brief)
#   key:<name>        one special key
# The reported pane command walks FM_FAKE_COMMAND_SEQ (one per line, last line
# repeating forever), so a case can model a shell that becomes an agent, or one
# that never does.
make_case() {
  local name=$1 harness=$2 launch_binary=$3 fakebin
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  EVENT_LOG="$CASE_DIR/events.log"
  COMMAND_SEQ="$CASE_DIR/pane-command-seq"
  COMMAND_COUNT="$CASE_DIR/pane-command-count"
  WINDOW_LOG="$CASE_DIR/windows.log"
  KIMI_STATE="$CASE_DIR/kimi-state"
  ID="agentup-$name"
  fakebin=$(fm_fakebin "$CASE_DIR")
  FAKEBIN_DIR=$fakebin

  mkdir -p "$HOME_DIR/data/$ID" "$HOME_DIR/projects" "$HOME_DIR/config" "$HOME_DIR/state" \
    "$HOME_DIR/user-home/.kimi-code"
  # A kimi spawn installs its turn-end hook into the launching user's own Kimi
  # config and refuses when it is absent, so the pinned throwaway HOME gets one.
  printf '# test config\n' > "$HOME_DIR/user-home/.kimi-code/config.toml"
  printf '%s\n' "$harness" > "$HOME_DIR/config/crew-harness"
  # A multi-line brief is the shape that spills through a shell, so fixtures use
  # one rather than a single tidy line.
  cat > "$HOME_DIR/data/$ID/brief.md" <<EOF
# Task
## Captain's intent
brief for $ID
second line of the brief

## Firstmate spec
Exercise the agent-up verification.
EOF
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  touch "$HOME_DIR/state/.last-watcher-beat"
  : > "$EVENT_LOG"
  : > "$KIMI_STATE"

  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_FAKE_EVENT_LOG:?}
kimi_state=$(cat "${FM_FAKE_KIMI_STATE:?}" 2>/dev/null || true)
# The rendered Kimi screen for the current delivery stage. `ready` carries the
# fresh-launch banner the readiness gate matches; `delivered` carries the
# echoed pointer and a nonzero context percentage, which is what confirms
# delivery. The composer box is empty in both, as a settled Kimi pane's is.
kimi_screen() {
  case "$kimi_state" in
    ready)
      printf 'Welcome to Kimi Code!\ncontext: 0%% (0/256k)\n╭────────────────────────────────╮\n│ >                              │\n╰────────────────────────────────╯\n'
      ;;
    pointer-typed)
      printf 'context: 0%% (0/256k)\n╭────────────────────────────────╮\n│ > Read the brief at            │\n│                                │\n╰────────────────────────────────╯\n'
      ;;
    delivered)
      printf '✨ Read the brief at %s and follow it exactly.\ncontext: 1%% (2k/256k)\n╭────────────────────────────────╮\n│ >                              │\n╰────────────────────────────────╯\n' "${FM_FAKE_BRIEF_REAL:-}"
      ;;
    *) printf 'shell starting\n$ \n' ;;
  esac
}
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{cursor_y}"*)
    case "$kimi_state" in
      ready|pointer-typed|delivered) printf '3\n' ;;
      *) printf '1\n' ;;
    esac
    exit 0
    ;;
  *"#{pane_current_command}"*)
    countfile=${FM_FAKE_COMMAND_COUNT:?}
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    line=$(sed -n "${n}p" "${FM_FAKE_COMMAND_SEQ:?}" || true)
    [ -n "$line" ] || line=$(awk 'NF{l=$0} END{print l}' "$FM_FAKE_COMMAND_SEQ")
    printf 'probe:%s\n' "$line" >> "$log"
    printf '%s\n' "$line"
    exit 0
    ;;
  *"#{pane_pid}"*) exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  # The liveness owner reads the window inventory before the pane command, so a
  # stub that lists nothing reads as a structurally gone endpoint.
  new-window)
    prev=
    for arg in "$@"; do
      [ "$prev" != "-n" ] || printf '%s\n' "$arg" >> "${FM_FAKE_WINDOW_LOG:?}"
      prev=$arg
    done
    printf '@42\n'
    exit 0
    ;;
  list-windows)
    # FM_FAKE_WINDOW_VANISH models a window that was killed after it was
    # created: new-window still succeeds, but the inventory no longer lists it,
    # which is exactly what the liveness owner reads as a gone endpoint.
    [ -n "${FM_FAKE_WINDOW_VANISH:-}" ] && exit 0
    [ ! -f "${FM_FAKE_WINDOW_LOG:?}" ] || cat "$FM_FAKE_WINDOW_LOG"
    exit 0
    ;;
  has-session|new-session|set-window-option|kill-window) exit 0 ;;
  capture-pane)
    start= end= prev=
    for arg in "$@"; do
      case "$prev" in
        -S) start=$arg ;;
        -E) end=$arg ;;
      esac
      case "$arg" in -S|-E) prev=$arg ;; *) prev= ;; esac
    done
    case "$start:$end" in
      *[!0-9:]*|'':*|*:'') kimi_screen ;;
      *) kimi_screen | awk -v start="$start" -v end="$end" 'NR - 1 >= start && NR - 1 <= end' ;;
    esac
    exit 0
    ;;
  send-keys)
    prev=
    literal=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then
        # A spawn types a short line sourcing its staged launch file; record
        # the staged command itself.
        case "$arg" in
          ". '"*"'") staged=${arg#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || arg=$(cat "$staged") ;;
        esac
      fi
      case "$prev" in
        -l) printf 'literal:%s\n' "$arg" >> "$log"; [ -n "$literal" ] || literal=$arg ;;
      esac
      prev=$arg
    done
    # Advance the Kimi delivery stage the same way a real pane would: the
    # launch line starts the TUI, the first Enter brings it up ready, the
    # pointer is typed next, and the Enter after that delivers it.
    if [ -n "$literal" ]; then
      case "$literal" in
        *' --auto') printf 'launched\n' > "${FM_FAKE_KIMI_STATE:?}" ;;
        *) printf 'pointer-typed\n' > "${FM_FAKE_KIMI_STATE:?}" ;;
      esac
    fi
    case "$*" in
      *" Enter")
        printf 'key:Enter\n' >> "$log"
        case "$kimi_state" in
          launched) printf 'ready\n' > "${FM_FAKE_KIMI_STATE:?}" ;;
          pointer-typed) printf 'delivered\n' > "${FM_FAKE_KIMI_STATE:?}" ;;
        esac
        ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  # PATH is pinned narrow so the harness stubs decide resolution, but two real
  # tools are needed: node records Claude workspace trust, and python3 with
  # tomllib validates the Kimi config the turn-end hook edits.
  # Absence is tolerated here: the cases that need them gate on their own.
  fm_fake_real_tool "$fakebin" node python3 || true
  cat > "$fakebin/$launch_binary" <<'SH'
#!/usr/bin/env bash
set -u
[ "$#" -eq 1 ] && [ "$1" = "--version" ]
SH
  chmod +x "$fakebin/$launch_binary"
}

# set_command_sequence <line...>: what pane_current_command reports, in order.
set_command_sequence() {
  printf '%s\n' "$@" > "$COMMAND_SEQ"
  rm -f "$COMMAND_COUNT"
}

run_spawn() {
  env \
    FM_ROOT_OVERRIDE='' \
    FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 \
    TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    FM_FAKE_EVENT_LOG="$EVENT_LOG" \
    FM_FAKE_COMMAND_SEQ="$COMMAND_SEQ" \
    FM_FAKE_COMMAND_COUNT="$COMMAND_COUNT" \
    FM_FAKE_WINDOW_LOG="$WINDOW_LOG" \
    FM_FAKE_KIMI_STATE="$KIMI_STATE" \
    FM_FAKE_BRIEF_REAL="$HOME_DIR/data/$ID/launch-brief.md" \
    HOME="$HOME_DIR/user-home" \
    CLAUDE_CONFIG_DIR='' \
    FM_KIMI_BRIEF_SETTLE_SECS=0 \
    FM_SPAWN_AGENT_UP_SLEEP=0 \
    GROK_HOME="$HOME_DIR/grok-home" \
    PATH="$FAKEBIN_DIR:/usr/bin:/bin" \
    "$@" \
    "$SPAWN" "$ID" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# A scout records no delivery contract, so it takes --scout in place of the
# --mode/--yolo run_spawn pins.
run_spawn_scout() {
  env \
    FM_ROOT_OVERRIDE='' \
    FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 \
    TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    FM_FAKE_EVENT_LOG="$EVENT_LOG" \
    FM_FAKE_COMMAND_SEQ="$COMMAND_SEQ" \
    FM_FAKE_COMMAND_COUNT="$COMMAND_COUNT" \
    FM_FAKE_WINDOW_LOG="$WINDOW_LOG" \
    FM_FAKE_KIMI_STATE="$KIMI_STATE" \
    HOME="$HOME_DIR/user-home" \
    CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_AGENT_UP_SLEEP=0 \
    GROK_HOME="$HOME_DIR/grok-home" \
    PATH="$FAKEBIN_DIR:/usr/bin:/bin" \
    "$SPAWN" "$ID" "$PROJ_DIR" --scout 2>&1
}

# run_spawn_args <spawn-arg...>: the run_spawn environment with the spawn's own
# arguments supplied by the case, for the raw-launch and --relaunch shapes.
run_spawn_args() {
  env \
    FM_ROOT_OVERRIDE='' \
    FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 \
    TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    FM_FAKE_EVENT_LOG="$EVENT_LOG" \
    FM_FAKE_COMMAND_SEQ="$COMMAND_SEQ" \
    FM_FAKE_COMMAND_COUNT="$COMMAND_COUNT" \
    FM_FAKE_WINDOW_LOG="$WINDOW_LOG" \
    FM_FAKE_KIMI_STATE="$KIMI_STATE" \
    HOME="$HOME_DIR/user-home" \
    CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_AGENT_UP_SLEEP=0 \
    FM_SPAWN_AGENT_UP_MAX_POLLS=2 \
    GROK_HOME="$HOME_DIR/grok-home" \
    PATH="$FAKEBIN_DIR:/usr/bin:/bin" \
    "$SPAWN" "$@" 2>&1
}

cleanup_task_tmp() { rm -rf "/tmp/fm-$1"; }

# Line number of the first event log entry matching <pattern>, or empty.
event_line() {  # <pattern>
  grep -n -- "$1" "$EVENT_LOG" | head -1 | cut -d: -f1
}

# kimi is the one adapter whose brief firstmate types itself, after the launch.
# It must not be typed while the pane is still a shell: here the pane reports a
# shell for the first reads and only then the agent.
test_kimi_brief_is_typed_only_after_the_agent_is_up() {
  local out status brief_at up_at
  make_case kimi-waits kimi kimi
  set_command_sequence zsh zsh kimi

  out=$(run_spawn)
  status=$?

  expect_code 0 "$status" "kimi spawn should succeed once the agent comes up"
  assert_contains "$out" "spawned $ID harness=kimi" "kimi spawn did not reach the healthy path"
  # kimi's launch line carries no brief, so the pointer typed afterwards IS the
  # separate delivery being ordered against the liveness proof.
  brief_at=$(event_line 'literal:Read the brief at')
  up_at=$(event_line 'probe:kimi')
  [ -n "$brief_at" ] || fail "kimi brief was never delivered"
  [ -n "$up_at" ] || fail "the agent was never observed up"
  [ "$brief_at" -gt "$up_at" ] \
    || fail "kimi brief was typed at event $brief_at, before the agent was proven up at event $up_at"
  cleanup_task_tmp "$ID"
  pass "kimi's post-launch brief is typed only after the agent is proven up"
}

# The spill itself, in the shape where firstmate does the typing: the pane never
# stops being a bare shell, so the brief must never be typed into it.
test_dead_shell_refuses_before_typing_the_brief() {
  local out status
  make_case kimi-dead kimi kimi
  set_command_sequence zsh

  out=$(run_spawn FM_SPAWN_AGENT_UP_MAX_POLLS=4)
  status=$?

  expect_code 1 "$status" "a pane still sitting at a bare shell should refuse"
  assert_contains "$out" "no agent is running" "refusal did not say the agent never started"
  assert_contains "$out" "4 poll(s) x 0s" "refusal did not report the bound it waited out"
  assert_contains "$out" "The brief was NOT delivered" "refusal did not say the brief was withheld"
  assert_not_contains "$out" "spawned $ID" "refused spawn still reported success"
  # tmux CAN report agent liveness, so this is a check that RAN and FAILED. It
  # must stay a hard refusal, never the warn-and-proceed an unsupported check
  # gets (see test_unverified_liveness_backend_still_spawns_and_warns).
  assert_not_contains "$out" "has no agent-liveness reader" \
    "a backend that can read liveness downgraded a proven bare shell to a warning"
  assert_no_grep 'Read the brief at' "$EVENT_LOG" \
    "the brief pointer was typed into a pane that was still a bare shell"
  cleanup_task_tmp "$ID"
  pass "a bare shell refuses loudly at the bound instead of receiving the brief"
}

# Dispatch is transactional: the task record is provisional until the backlog
# commit at the very end of a spawn, so a refusal before that point rolls the
# record back. The refusal therefore has to say what really survives - the
# endpoint, the local copy, and the brief - and hand back a RE-SPAWN, not a
# relaunch inside the pane that would leave a worker the backlog does not own.
test_dead_shell_refusal_is_recoverable_and_actionable() {
  local out status
  make_case claude-dead claude claude
  set_command_sequence zsh

  out=$(run_spawn FM_SPAWN_AGENT_UP_MAX_POLLS=3)
  status=$?

  expect_code 1 "$status" "a launch that never started its agent should refuse"
  assert_contains "$out" "3 poll(s) x 0s" "refusal did not report the bound it waited out"
  assert_contains "$out" "endpoint firstmate:fm-$ID and local copy $WT_DIR both remain" \
    "refusal did not say what survived it"
  assert_contains "$out" "has been rolled back" \
    "refusal did not say the provisional record was rolled back"
  assert_absent "$HOME_DIR/state/$ID.meta" \
    "a refused spawn left a task record the backlog does not own"
  assert_contains "$out" "re-spawn the task with this exact command" \
    "refusal did not hand back a re-spawn"
  assert_contains "$out" "fm-spawn.sh' '$ID' '$PROJ_DIR' --harness 'claude'" \
    "the re-spawn command did not carry this task's own id, project and harness"
  assert_contains "$out" "cd '$WT_DIR' && CLAUDE_CODE_AUTO_COMPACT_WINDOW=500000 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false" \
    "refusal did not report the launch line it actually sent"
  assert_not_contains "$out" "second line of the brief" \
    "the reported launch line pastes the brief inline instead of naming its file"
  cleanup_task_tmp "$ID"
  pass "a refusal names what survived, rolls the record back, and hands back the exact re-spawn"
}

# The same refusal for an adapter whose launch line carries no brief at all.
# Nothing about the recovery changes - the record is rolled back either way -
# but the reported launch line must be that adapter's own.
test_kimi_refusal_reports_its_own_launch_line() {
  local out status
  make_case kimi-recovery kimi kimi
  set_command_sequence zsh

  out=$(run_spawn FM_SPAWN_AGENT_UP_MAX_POLLS=2)
  status=$?

  expect_code 1 "$status" "a kimi spawn into a bare shell should refuse"
  assert_contains "$out" "re-spawn the task with this exact command" \
    "kimi refusal did not hand back a re-spawn"
  assert_contains "$out" "fm-spawn.sh' '$ID' '$PROJ_DIR' --harness 'kimi'" \
    "the re-spawn command did not carry this task's own harness"
  assert_contains "$out" "kimi' --auto" \
    "kimi refusal did not report this task's own kimi launch line"
  assert_not_contains "$out" "second line of the brief" \
    "kimi refusal pasted the brief inline instead of naming its file"
  cleanup_task_tmp "$ID"
  pass "a kimi refusal reports its own launch line and hands back the exact re-spawn"
}

# The happy path must not change: one launch line goes into the pane, it names
# the brief file rather than pasting its text, and the spawn reports success.
test_happy_path_launch_is_unchanged() {
  local out status deliveries
  make_case claude-ok claude claude
  set_command_sequence zsh claude

  out=$(run_spawn)
  status=$?

  expect_code 0 "$status" "a healthy claude spawn should succeed"
  assert_contains "$out" "spawned $ID harness=claude" "healthy spawn did not report success"
  assert_grep 'CLAUDE_CODE_AUTO_COMPACT_WINDOW=500000 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false' \
    "$EVENT_LOG" "the launch line was not sent unchanged"
  assert_grep "encode launch-brief < '$HOME_DIR/data/$ID/launch-brief.md'" "$EVENT_LOG" \
    "the launch line no longer names this task's brief file"
  assert_no_grep 'second line of the brief' "$EVENT_LOG" \
    "the launch line pasted the brief's text instead of naming its file"
  deliveries=$(grep -cF "encode launch-brief < '$HOME_DIR/data/$ID/launch-brief.md'" "$EVENT_LOG" || true)
  [ "$deliveries" = 1 ] \
    || fail "expected the brief to be named on the launch line exactly once, saw $deliveries deliveries"
  assert_present "$HOME_DIR/state/$ID.meta" "healthy spawn did not write task meta"
  cleanup_task_tmp "$ID"
  pass "the healthy launch path is unchanged and still names the brief file on the launch line"
}

# pi execs into a generic node process that cannot be attributed back to pi from
# outside the pane, so liveness is genuinely unavailable. That must not become a
# refusal, and must not burn the whole bound waiting for an answer that will
# never come.
test_unreadable_liveness_warns_without_refusing_or_burning_the_bound() {
  local out status probes
  make_case pi-node pi pi
  set_command_sequence zsh node

  out=$(run_spawn FM_SPAWN_AGENT_UP_MAX_POLLS=40)
  status=$?

  expect_code 0 "$status" "an unreadable-liveness harness should still spawn"
  assert_contains "$out" "spawned $ID harness=pi" "pi spawn did not reach the healthy path"
  assert_contains "$out" "could not confirm that pi actually owns the tmux pane" \
    "the warning did not name the unreadable harness and backend"
  assert_contains "$out" "tmux pane could not be read for the pi harness" \
    "the warning did not explain that the pane was unreadable"
  assert_contains "$out" "may have gone into a shell" \
    "the warning did not explain the unverified delivery risk"
  assert_contains "$out" "fm-peek.sh' '$ID'" "the warning did not say how to inspect the pane"
  assert_contains "$out" "re-spawn the task" \
    "the warning did not say how to recover a pane sitting at a shell"
  # Each inconclusive read costs a few pane queries (the node case also asks
  # whether the process is cursor or prime-agent), so this bounds the number of
  # WAIT ROUNDS loosely rather than exactly: running the 40-poll bound out would
  # cost an order of magnitude more queries than this.
  probes=$(grep -c '^probe:' "$EVENT_LOG" || true)
  [ "$probes" -le 12 ] \
    || fail "unreadable liveness polled $probes times - it should settle in a few reads, not run to the bound"
  cleanup_task_tmp "$ID"
  pass "an unreadable liveness answer warns without refusing or waiting out the bound"
}

# A wait that cannot be trusted to terminate is the thing being removed, so a
# malformed bound is refused rather than silently defaulted - and it is refused
# BEFORE the endpoint is touched. Refusing after the launch line went in would
# report a spawn whose agent is up and already working as a failure, which the
# caller would then retry against an occupied worktree lease.
test_invalid_bound_knobs_are_refused() {
  local out status
  make_case knobs claude claude
  set_command_sequence zsh claude

  out=$(run_spawn FM_SPAWN_AGENT_UP_MAX_POLLS=0)
  status=$?
  expect_code 1 "$status" "a zero poll bound should be refused"
  assert_contains "$out" "FM_SPAWN_AGENT_UP_MAX_POLLS must be a positive integer" \
    "zero poll bound was not refused by name"

  out=$(run_spawn FM_SPAWN_AGENT_UP_SLEEP=half)
  status=$?
  expect_code 1 "$status" "a non-numeric sleep should be refused"
  assert_contains "$out" "FM_SPAWN_AGENT_UP_SLEEP must be a non-negative integer" \
    "non-numeric sleep was not refused by name"

  assert_no_grep 'literal:' "$EVENT_LOG" \
    "a malformed bound was refused only after the launch line had been typed"
  assert_no_grep 'key:Enter' "$EVENT_LOG" \
    "a malformed bound was refused only after the launch line had been submitted"
  cleanup_task_tmp "$ID"
  pass "malformed agent-up bound knobs are refused before anything is typed into the pane"
}

# make_orca_case <name>: the same home/worktree fixture as make_case, driven
# through a fake Orca CLI instead of tmux. Orca is one of the backends with no
# agent-liveness reader (fm_backend_agent_state answers `unverified`), which is
# the state this fixture exists to reach - tmux can never produce it.
make_orca_case() {  # <name> [harness]
  local name=$1 harness=${2:-kimi} fakebin
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  ORCA_LOG="$CASE_DIR/orca.log"
  ORCA_RESP="$CASE_DIR/responses"
  ID="agentup-$name"
  fakebin=$(fm_fakebin "$CASE_DIR")
  FAKEBIN_DIR=$fakebin

  mkdir -p "$HOME_DIR/data/$ID" "$HOME_DIR/projects" "$HOME_DIR/config" "$HOME_DIR/state" \
    "$ORCA_RESP" "$HOME_DIR/user-home/.kimi-code"
  # A kimi spawn installs its turn-end hook into the launching user's own Kimi
  # config and refuses when it is absent, so the pinned throwaway HOME gets one -
  # the same pinning make_case does. Without it this case would read (and write)
  # the launching developer's real ~/.kimi-code, and refuse outright on a host
  # that has never run Kimi, which is every CI runner.
  printf '# test config\n' > "$HOME_DIR/user-home/.kimi-code/config.toml"
  cat > "$HOME_DIR/data/$ID/brief.md" <<EOF
# Task
## Captain's intent
brief for $ID
second line of the brief

## Firstmate spec
Exercise the agent-up verification.
EOF
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  touch "$HOME_DIR/state/.last-watcher-beat"
  : > "$ORCA_LOG"

  cat > "$fakebin/orca" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_ORCA_LOG:?}"
RESP="${FM_ORCA_RESPONSES:?}"
COUNT_FILE="$RESP/.count"
{
  printf 'orca'
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"
if [ "${1:-}" = status ]; then
  printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n'
  exit 0
fi
# A settled Kimi screen: the launch banner the readiness gate matches, a nonzero
# context percentage for the delivery gate, and an empty composer box. Answered
# directly rather than from the numbered response files, because the number of
# reads the gates make is not part of what these cases pin.
if [ "${1:-}" = terminal ] && [ "${2:-}" = read ]; then
  printf '{"ok":true,"result":{"tail":['
  printf '"Welcome to Kimi Code!",'
  printf '"context: 1%% (2k/256k)",'
  printf '"\u256d────────────────────────────────\u256e",'
  printf '"\u2502 >                              \u2502",'
  printf '"\u2570────────────────────────────────\u256f"'
  printf ']}}\n'
  exit 0
fi
n=$(( $(cat "$COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$COUNT_FILE"
if [ -f "$RESP/$n.exit" ]; then
  exit "$(cat "$RESP/$n.exit")"
fi
[ -f "$RESP/$n.out" ] && cat "$RESP/$n.out"
exit 0
SH
  chmod +x "$fakebin/orca"
  cat > "$fakebin/$harness" <<'SH'
#!/usr/bin/env bash
set -u
[ "$#" -eq 1 ] && [ "$1" = "--version" ]
SH
  chmod +x "$fakebin/$harness"
  # Call 1 is the repo lookup (absent), 2 creates it, 3 creates the worktree and
  # hands back the implicit terminal fm-spawn then launches into.
  printf '1\n' > "$ORCA_RESP/1.exit"
  printf '{"ok":true,"result":{"repo":{"id":"repo-%s"}}}\n' "$name" > "$ORCA_RESP/2.out"
  printf '{"ok":true,"result":{"worktree":{"id":"wt-%s","path":"%s"},"terminal":{"handle":"term-%s"}}}\n' \
    "$name" "$WT_DIR" "$name" > "$ORCA_RESP/3.out"
}

# An UNSUPPORTED check is not a failed one. A backend that cannot report agent
# liveness at all could never have proven a spill either way, so the spawn
# proceeds on the settle-and-type path and says once, loudly, that the delivery
# went out unverified. Kimi itself is refused earlier on such a backend, because
# its trust dialog needs a scrollback-free read of the live pane.
test_unverified_non_kimi_backend_still_spawns_and_warns() {
  local out status
  make_orca_case orca-unverified-claude claude

  out=$( env \
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_SPAWN_NO_GUARD=1 \
    FM_SPAWN_AGENT_UP_SLEEP=0 FM_ORCA_LOG="$ORCA_LOG" \
    FM_ORCA_RESPONSES="$ORCA_RESP" PATH="$FAKEBIN_DIR:$PATH" \
    HOME="$HOME_DIR/user-home" CLAUDE_CONFIG_DIR='' \
    "$SPAWN" "$ID" "$PROJ_DIR" claude --backend orca --mode no-mistakes --yolo off 2>&1 )
  status=$?

  expect_code 0 "$status" "claude on an unsupported liveness backend should still spawn"$'\n'"$out"
  assert_contains "$out" "spawned $ID harness=claude" "unsupported non-kimi spawn did not succeed"
  assert_contains "$out" "could not confirm that claude actually owns the orca pane" \
    "unsupported non-kimi warning did not name its harness and backend"
  assert_contains "$out" "orca backend cannot report agent liveness for the claude harness at all" \
    "unsupported non-kimi warning did not explain why verification was unavailable"
  assert_contains "$out" "re-spawn the task" \
    "unsupported non-kimi warning did not include the shared recovery"
  cleanup_task_tmp "$ID"
  pass "an unsupported non-kimi liveness check warns and proceeds"
}

# make_herdr_case <name> <harness> <launch-binary>: a fake Herdr CLI holding its
# workspace/tab/pane state in one JSON file. By default it drops the task's pane
# the moment the launch Enter is sent, which is exactly herdr's pane_not_found
# shape and the only way to reach the `missing` state - tmux has no equivalent.
#
# Two env switches turn the same fake into a HEALTHY herdr endpoint, which is
# what the brief-delivery cases below need:
#   FM_FAKE_HERDR_KEEP_PANE=1   the pane survives the launch Enter.
#   FM_FAKE_HERDR_AGENT=<status> `agent get` reports a registered agent at that
#                                status instead of agent_not_found.
# Every `pane send-text` payload is also written verbatim to its own numbered
# file under $HERDR_SENDTEXT_DIR, because what this suite has to assert about
# the launch is a property of the exact bytes typed into the pane - including
# whether they contain a newline - which the shared arg log cannot preserve.
# A structurally gone endpoint can never come back and host an agent, so
# polling it out to the bound only delays a failure the first read already
# proved. On tmux that state is an empty window inventory: the window fm-spawn
# created is no longer listed, which is exactly what a killed window looks like.

test_missing_endpoint_refuses_on_the_first_read() {
  local out status
  make_case vanish-claude claude claude
  set_command_sequence zsh

  out=$(run_spawn FM_SPAWN_AGENT_UP_MAX_POLLS=40 FM_FAKE_WINDOW_VANISH=1)
  status=$?

  expect_code 1 "$status" "a spawn whose endpoint vanished should refuse"$'\n'"$out"
  assert_contains "$out" "is gone" "refusal did not say the endpoint was gone"
  assert_contains "$out" "liveness read: missing" "refusal did not report the liveness answer"
  assert_contains "$out" "after 1 of 40 poll(s)" \
    "a gone endpoint was polled past the first read, which can never change the answer"
  assert_contains "$out" "there is nothing there to interrupt or type into" \
    "refusal still suggested acting inside a pane that no longer exists"
  assert_contains "$out" "re-spawn the task with this exact command" \
    "refusal did not hand back a re-spawn"
  cleanup_task_tmp "$ID"
  pass "a structurally gone endpoint refuses on the first read and asks for a re-spawn"
}

# A raw `--harness "<command>"` is the escape hatch for an UNVERIFIED adapter,
# which may legitimately never classify as a recognised agent. The gate must
# not run for it: a pane that only ever reads as a shell is the expected shape
# there, and refusing it would roll back a record for a worker that is running.
test_raw_launch_is_not_gated_on_agent_liveness() {
  local out status
  make_case raw-launch claude claude
  set_command_sequence zsh

  out=$(run_spawn_args "$ID" "$PROJ_DIR" --harness 'bash -c true' --mode no-mistakes --yolo off)
  status=$?

  expect_code 0 "$status" "a raw launch command was refused by the agent-up gate"$'\n'"$out"
  assert_not_contains "$out" "no agent is running" \
    "a raw launch was held to a liveness proof its unverified adapter cannot give"
  assert_contains "$out" "spawned $ID" "raw launch did not report success"
  assert_present "$HOME_DIR/state/$ID.meta" "a raw launch's task record was rolled back"
  cleanup_task_tmp "$ID"
  pass "a raw launch command skips the agent-up gate instead of being refused by it"
}

# A --relaunch publishes its replacement record BEFORE the gate runs and rolls
# nothing back when the replacement fails it, so the refusal must not claim a
# rollback or an untouched record, and its recovery has to be the same
# --relaunch rather than a fresh spawn that would provision a second worktree
# and endpoint for a task that already has both.
test_relaunch_refusal_keeps_the_record_and_hands_back_a_relaunch() {
  local out status
  make_case relaunch-dead claude claude
  set_command_sequence zsh claude
  out=$(run_spawn)
  expect_code 0 $? "the first spawn should succeed so there is a record to relaunch"$'\n'"$out"
  cleanup_task_tmp "$ID"

  set_command_sequence zsh
  out=$(run_spawn_args "$ID" --relaunch --harness claude --model opus --effort high)
  status=$?

  expect_code 1 "$status" "a relaunch whose agent never started should refuse"$'\n'"$out"
  assert_contains "$out" "no agent is running" "relaunch refusal did not say the agent never started"
  assert_not_contains "$out" "has been rolled back" \
    "relaunch refusal claimed a rollback of a record that was never provisional"
  assert_contains "$out" "durable record ($HOME_DIR/state/$ID.meta) was already republished for this attempt" \
    "relaunch refusal did not say the replacement record was published and kept"
  assert_present "$HOME_DIR/state/$ID.meta" "a refused relaunch removed the task's record"
  assert_grep 'model=opus' "$HOME_DIR/state/$ID.meta" \
    "the kept record does not carry this attempt's model, so the refusal's republished claim would be false"
  assert_contains "$out" "fm-spawn.sh' '$ID' --relaunch --harness 'claude' --model 'opus' --effort 'high'" \
    "relaunch refusal did not hand back a --relaunch carrying this attempt's harness and axes"
  assert_not_contains "$out" "fm-spawn.sh' '$ID' '$PROJ_DIR'" \
    "relaunch refusal handed back a fresh spawn that would provision a second worktree and endpoint"
  cleanup_task_tmp "$ID"
  pass "a refused relaunch keeps the record and hands back the same --relaunch"
}

# A ship with a registered branch prefix records its brief against that
# branch, so a re-spawn that dropped the prefix would come back on fm/<id> and
# be refused as a branch mismatch; the handed-back command must carry it.
test_respawn_command_carries_the_branch_prefix() {
  local out status
  make_case prefix-dead claude claude
  set_command_sequence zsh
  printf 'Ship branch: feat/%s\n' "$ID" >> "$HOME_DIR/data/$ID/brief.md"

  out=$(run_spawn_args "$ID" "$PROJ_DIR" --mode direct-PR --yolo off --branch-prefix feat/)
  status=$?

  expect_code 1 "$status" "a launch that never started its agent should refuse"$'\n'"$out"
  assert_contains "$out" "re-spawn the task with this exact command" \
    "refusal did not hand back a re-spawn"
  assert_contains "$out" "--yolo 'off' --branch-prefix 'feat/'" \
    "the re-spawn command dropped this ship's branch prefix, so a copy-paste would be refused as a branch mismatch"
  cleanup_task_tmp "$ID"
  pass "the re-spawn command carries a ship's registered branch prefix"
}

test_missing_endpoint_respawn_command_carries_kind_and_axes() {
  local out status
  make_case vanish-scout claude claude
  set_command_sequence zsh

  out=$(FM_FAKE_WINDOW_VANISH=1 run_spawn_scout)
  status=$?

  expect_code 1 "$status" "a scout spawn whose endpoint vanished should refuse"$'\n'"$out"
  assert_contains "$out" "fm-spawn.sh' '$ID'" "refusal did not print the safely quoted re-spawn command"
  assert_contains "$out" "--scout --harness 'claude' --backend 'tmux'" \
    "the re-spawn command dropped this task's kind or resolved axes, so a copy-paste would come back as a different task"
  cleanup_task_tmp "$ID"
  pass "the re-spawn command carries this task's own kind and resolved axes"
}

test_kimi_brief_is_typed_only_after_the_agent_is_up
test_dead_shell_refuses_before_typing_the_brief
test_kimi_refusal_reports_its_own_launch_line
test_dead_shell_refusal_is_recoverable_and_actionable
test_happy_path_launch_is_unchanged
test_unreadable_liveness_warns_without_refusing_or_burning_the_bound
test_invalid_bound_knobs_are_refused
test_unverified_non_kimi_backend_still_spawns_and_warns
test_missing_endpoint_refuses_on_the_first_read
test_missing_endpoint_respawn_command_carries_kind_and_axes
test_respawn_command_carries_the_branch_prefix
test_raw_launch_is_not_gated_on_agent_liveness
test_relaunch_refusal_keeps_the_record_and_hands_back_a_relaunch

echo "# all fm-spawn-agent-up tests passed"
