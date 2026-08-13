#!/usr/bin/env bash
# Regression tests for fm-spawn.sh's agent-up verification (bin/fm-spawn.sh,
# spawn_wait_agent_up / spawn_refuse_agent_never_started).
#
# The bug these pin: until an agent actually owns the pane, everything typed
# there is SHELL input. When the launch never started the agent, the brief - on
# the launch line for every verified adapter except kimi, typed separately for
# kimi - landed in a bare shell as continuation soup, no agent ever read it, and
# fm-spawn still reported "spawned", so the pane looked alive and a later steer
# "succeeded" into that same shell.
#
# Asserted here, with a fake tmux whose pane_current_command drives the shared
# liveness owner (fm_backend_tmux_agent_alive):
#   1. kimi's post-launch brief is typed only AFTER the agent is proven up.
#   2. A pane still proven to be a bare shell refuses loudly at the bound, in
#      both delivery shapes, without typing the brief and without tearing the
#      task down, and names the exact recovery - a single file-pointer relaunch
#      where the launch line can carry a brief, and an explicit two-step launch
#      plus fm-send delivery where it cannot (kimi).
#   3. The happy path is unchanged: the launch line still carries the brief and
#      the spawn still reports success.
#   4. A harness/backend pair whose liveness cannot be read (pi's generic node
#      process on tmux) neither refuses nor stalls to the bound.
#   5. The wait is bounded, and its knobs are validated before anything is
#      typed into the pane.
#
# Two cases need a different backend than the fake tmux above, because the state
# they pin is one tmux can never report:
#   6. A backend with NO liveness reader at all (fake Orca) cannot run the check.
#      That is an unsupported check, not a failed one, so kimi still spawns
#      there and warns instead of losing a capability that worked before.
#   7. A structurally gone endpoint (fake Herdr's pane_not_found) refuses on the
#      first read rather than waiting out a bound that can never change, and
#      tells the caller to re-spawn rather than to relaunch into a dead pane.
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
  ID="agentup-$name"
  fakebin=$(fm_fakebin "$CASE_DIR")
  FAKEBIN_DIR=$fakebin

  mkdir -p "$HOME_DIR/data/$ID" "$HOME_DIR/projects" "$HOME_DIR/config" "$HOME_DIR/state"
  printf '%s\n' "$harness" > "$HOME_DIR/config/crew-harness"
  # A multi-line brief is the shape that spills through a shell, so fixtures use
  # one rather than a single tidy line.
  printf 'brief for %s\nsecond line of the brief\n' "$ID" > "$HOME_DIR/data/$ID/brief.md"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  touch "$HOME_DIR/state/.last-watcher-beat"
  : > "$EVENT_LOG"

  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_FAKE_EVENT_LOG:?}
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
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
  new-window) printf '@42\n'; exit 0 ;;
  list-windows|has-session|new-session|set-window-option|kill-window) exit 0 ;;
  send-keys)
    prev=
    for arg in "$@"; do
      case "$prev" in
        -l) printf 'literal:%s\n' "$arg" >> "$log" ;;
      esac
      prev=$arg
    done
    case "$*" in
      *" Enter") printf 'key:Enter\n' >> "$log" ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
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
    FM_KIMI_BRIEF_SETTLE_SECS=0 \
    FM_SPAWN_AGENT_UP_SLEEP=0 \
    GROK_HOME="$HOME_DIR/grok-home" \
    PATH="$FAKEBIN_DIR:/usr/bin:/bin" \
    "$@" \
    "$SPAWN" "$ID" "$PROJ_DIR" 2>&1
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
  # kimi's launch line carries no brief, so the launch-brief literal IS the
  # separate post-launch delivery being ordered against the liveness proof.
  brief_at=$(event_line 'literal:.*launch-brief:')
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
  assert_no_grep 'launch-brief:' "$EVENT_LOG" \
    "the brief was typed into a pane that was still a bare shell"
  cleanup_task_tmp "$ID"
  pass "a bare shell refuses loudly at the bound instead of receiving the brief"
}

# kimi's launch template has no __ENCODED_BRIEF__ placeholder at all (--prompt
# cannot combine with --yolo, and there is no positional interactive brief), so
# a single rendered relaunch would silently start an agent with no brief. Its
# refusal must print a TWO-STEP recovery instead, and must never claim a
# brief-carrying relaunch it cannot produce.
test_kimi_refusal_prints_a_two_step_file_pointer_recovery() {
  local out status
  make_case kimi-recovery kimi kimi
  set_command_sequence zsh

  out=$(run_spawn FM_SPAWN_AGENT_UP_MAX_POLLS=2)
  status=$?

  expect_code 1 "$status" "a kimi spawn into a bare shell should refuse"
  assert_contains "$out" "2. Start kimi in the same pane" \
    "kimi refusal did not print the step that launches the TUI"
  assert_contains "$out" "cd '$WT_DIR' && KIMI_CODE_HOME=" \
    "kimi refusal did not render the launch from this task's own template"
  assert_contains "$out" "3. Wait for the TUI to accept input" \
    "kimi refusal did not print the separate brief-delivery step"
  assert_contains "$out" "fm-send.sh' '$ID' 'Read $HOME_DIR/data/$ID/brief.md and execute it fully" \
    "kimi refusal did not deliver the brief as a file pointer through fm-send"
  assert_not_contains "$out" "it points at the brief file instead of pasting it" \
    "kimi refusal claimed a brief-carrying relaunch its launch line cannot carry"
  assert_not_contains "$out" "second line of the brief" \
    "kimi refusal pasted the brief inline instead of pointing at its file"
  cleanup_task_tmp "$ID"
  pass "a kimi refusal prints the two-step recovery and names the brief file"
}

# The same spill in the shape where the brief rides the launch line: it is
# already gone into the shell, so the refusal's job is to stop the silence - and
# to leave the task recoverable with the exact recovery spelled out.
test_dead_shell_refusal_is_recoverable_and_actionable() {
  local out status
  make_case claude-dead claude claude
  set_command_sequence zsh

  out=$(run_spawn FM_SPAWN_AGENT_UP_MAX_POLLS=3)
  status=$?

  expect_code 1 "$status" "a launch that never started its agent should refuse"
  assert_contains "$out" "3 poll(s) x 0s" "refusal did not report the bound it waited out"
  assert_contains "$out" "Nothing was torn down" "refusal did not state the task survived"
  assert_present "$HOME_DIR/state/$ID.meta" "refusal removed the task's durable record"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$ID.meta" "refusal dropped the task's worktree"
  assert_contains "$out" "--key C-c" "refusal did not say to interrupt the pane"
  assert_contains "$out" "Read $HOME_DIR/data/$ID/brief.md and execute it fully" \
    "refusal did not offer the file-pointer relaunch"
  assert_contains "$out" "cd '$WT_DIR' && CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions" \
    "recovery relaunch was not rendered from this task's own launch template"
  assert_not_contains "$out" "second line of the brief" \
    "the recovery relaunch pastes the brief inline instead of pointing at its file"
  cleanup_task_tmp "$ID"
  pass "a refusal leaves the task recoverable and prints the exact one-line file-pointer relaunch"
}

# The happy path must not change: the launch line still carries the brief inline
# and the spawn still reports success.
test_happy_path_launch_is_unchanged() {
  local out status deliveries
  make_case claude-ok claude claude
  set_command_sequence zsh claude

  out=$(run_spawn)
  status=$?

  expect_code 0 "$status" "a healthy claude spawn should succeed"
  assert_contains "$out" "spawned $ID harness=claude" "healthy spawn did not report success"
  assert_grep 'literal:CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions' \
    "$EVENT_LOG" "the launch line was not sent unchanged"
  assert_grep 'second line of the brief' "$EVENT_LOG" \
    "the launch line no longer carries the brief"
  deliveries=$(grep -c '^literal:.*launch-brief:' "$EVENT_LOG" || true)
  [ "$deliveries" = 1 ] \
    || fail "expected the brief to ride the launch line exactly once, saw $deliveries deliveries"
  assert_present "$HOME_DIR/state/$ID.meta" "healthy spawn did not write task meta"
  cleanup_task_tmp "$ID"
  pass "the healthy launch path is unchanged and still carries the brief on the launch line"
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
  assert_contains "$out" "brief may have gone into a shell" \
    "the warning did not explain the unverified delivery risk"
  assert_contains "$out" "fm-peek.sh' '$ID'" "the warning did not say how to inspect the pane"
  assert_contains "$out" "fm-send.sh' '$ID' --key C-c" \
    "the warning did not reuse the refusal recovery"
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

  mkdir -p "$HOME_DIR/data/$ID" "$HOME_DIR/projects" "$HOME_DIR/config" "$HOME_DIR/state" "$ORCA_RESP"
  printf 'brief for %s\nsecond line of the brief\n' "$ID" > "$HOME_DIR/data/$ID/brief.md"
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
# liveness at all could never have proven the spill either way, so refusing
# there would delete kimi-on-Orca outright rather than fix anything. It must
# proceed on the pre-existing settle-and-type path, and say once, loudly, that
# the delivery went out unverified.
test_unverified_liveness_backend_still_spawns_and_warns() {
  local out status warnings
  make_orca_case orca-unverified

  out=$( env \
    FM_ROOT_OVERRIDE='' \
    FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 \
    FM_KIMI_BRIEF_SETTLE_SECS=0 \
    FM_SPAWN_AGENT_UP_SLEEP=0 \
    FM_ORCA_LOG="$ORCA_LOG" \
    FM_ORCA_RESPONSES="$ORCA_RESP" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$ID" "$PROJ_DIR" kimi --backend orca 2>&1 )
  status=$?

  expect_code 0 "$status" "kimi on a backend with no liveness reader should still spawn"$'\n'"$out"
  assert_contains "$out" "spawned $ID harness=kimi" "an unsupported liveness check removed a working spawn"
  assert_contains "$out" "orca backend cannot report agent liveness for the kimi harness at all" \
    "the spawn did not name the backend whose check could not run"
  assert_contains "$out" "UNVERIFIED" "the warning did not say the brief delivery was unverified"
  warnings=$(printf '%s\n' "$out" | grep -c 'cannot report agent liveness' || true)
  [ "$warnings" = 1 ] || fail "expected exactly one unverified-backend warning, saw $warnings"
  assert_grep 'launch-brief:' "$ORCA_LOG" "the brief was never delivered through the Orca terminal"
  cleanup_task_tmp "$ID"
  pass "an unsupported liveness check warns and proceeds instead of removing a working spawn"
}

test_unverified_non_kimi_backend_still_spawns_and_warns() {
  local out status
  make_orca_case orca-unverified-claude claude

  out=$( env \
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_SPAWN_NO_GUARD=1 \
    FM_SPAWN_AGENT_UP_SLEEP=0 FM_ORCA_LOG="$ORCA_LOG" \
    FM_ORCA_RESPONSES="$ORCA_RESP" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$ID" "$PROJ_DIR" claude --backend orca 2>&1 )
  status=$?

  expect_code 0 "$status" "claude on an unsupported liveness backend should still spawn"$'\n'"$out"
  assert_contains "$out" "spawned $ID harness=claude" "unsupported non-kimi spawn did not succeed"
  assert_contains "$out" "could not confirm that claude actually owns the orca pane" \
    "unsupported non-kimi warning did not name its harness and backend"
  assert_contains "$out" "orca backend cannot report agent liveness for the claude harness at all" \
    "unsupported non-kimi warning did not explain why verification was unavailable"
  assert_contains "$out" "fm-send.sh' '$ID' --key C-c" \
    "unsupported non-kimi warning did not include the shared recovery"
  cleanup_task_tmp "$ID"
  pass "an unsupported non-kimi liveness check warns and proceeds"
}

# make_herdr_case <name> <harness> <launch-binary>: a fake Herdr CLI holding its
# workspace/tab/pane state in one JSON file. It drops the task's pane the moment
# the launch Enter is sent, which is exactly herdr's pane_not_found shape and
# the only way to reach the `missing` state - tmux has no equivalent.
make_herdr_case() {  # <name> <harness> <launch-binary>
  local name=$1 harness=$2 launch_binary=$3 fakebin
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  HERDR_STATE_FILE="$CASE_DIR/herdr-state.json"
  HERDR_LOG="$CASE_DIR/herdr.log"
  HERDR_GONE_MARK="$CASE_DIR/pane-gone"
  HERDR_WT_ROOT="$CASE_DIR/worktrees"
  ID="agentup-$name"
  fakebin=$(fm_fakebin "$CASE_DIR")
  FAKEBIN_DIR=$fakebin

  mkdir -p "$HOME_DIR/data/$ID" "$HOME_DIR/projects" "$HOME_DIR/config" "$HOME_DIR/state" "$HERDR_WT_ROOT"
  printf '%s\n' "$harness" > "$HOME_DIR/config/crew-harness"
  printf 'brief for %s\nsecond line of the brief\n' "$ID" > "$HOME_DIR/data/$ID/brief.md"
  fm_git_init_commit "$PROJ_DIR"
  touch "$HOME_DIR/state/.last-watcher-beat"
  printf '{"next":1,"workspaces":[],"tabs":[]}\n' > "$HERDR_STATE_FILE"
  : > "$HERDR_LOG"
  rm -f "$HERDR_GONE_MARK"

  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
state=${FM_FAKE_HERDR_STATE:?}
log=${FM_FAKE_HERDR_LOG:?}
gone=${FM_FAKE_HERDR_GONE_MARK:?}
{
  for arg in "$@"; do printf '<%s>' "$arg"; done
  printf '\n'
} >> "$log"

save() { local tmp="$state.tmp.$$"; cat > "$tmp" && mv "$tmp" "$state"; }
query() { jq "$@" "$state"; }
args=("$@")
cmd=${1:-}; sub=${2:-}; workspace= label= cwd=
tokens=()
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --workspace) workspace=${args[$((i+1))]:-} ;;
    --label) label=${args[$((i+1))]:-} ;;
    --cwd) cwd=${args[$((i+1))]:-} ;;
    --token) tokens+=("${args[$((i+1))]:-}") ;;
  esac
done

case "$cmd $sub" in
  'status --json')
    printf '{"client":{"version":"0.7.4","protocol":16},"server":{"running":true}}\n'
    ;;
  'workspace list') query '{result:{workspaces:.workspaces}}' ;;
  'workspace create')
    n=$(query -r .next); ws="w$n"; tab="$ws:t1"; pane="$ws:p1"
    query --arg ws "$ws" --arg lbl "$label" --arg tab "$tab" --arg pane "$pane" --arg cwd "$cwd" '
      .next += 1 |
      .workspaces += [{workspace_id:$ws,"label":$lbl,tokens:{}}] |
      .tabs += [{workspace_id:$ws,tab_id:$tab,pane_id:$pane,"label":"1",cwd:$cwd,tokens:{}}]' | save
    jq -n --arg ws "$ws" --arg tab "$tab" --arg pane "$pane" \
      '{result:{workspace:{workspace_id:$ws},tab:{tab_id:$tab},root_pane:{pane_id:$pane}}}'
    ;;
  'workspace report-metadata')
    target=${3:-}
    for token in "${tokens[@]}"; do
      key=${token%%=*}; value=${token#*=}
      query --arg id "$target" --arg key "$key" --arg value "$value" \
        '.workspaces |= map(if .workspace_id == $id then (.tokens[$key]=$value) else . end)' | save
    done
    ;;
  'workspace rename')
    target=${3:-}; value=${4:-}
    query --arg id "$target" --arg value "$value" \
      '.workspaces |= map(if .workspace_id == $id then .label=$value else . end)' | save
    ;;
  'tab list') query --arg ws "$workspace" '{result:{tabs:[.tabs[]|select(.workspace_id==$ws)]}}' ;;
  'tab create')
    n=$(query -r .next); tab="$workspace:t$n"; pane="$workspace:p$n"
    query --arg ws "$workspace" --arg tab "$tab" --arg pane "$pane" --arg lbl "$label" --arg cwd "$cwd" '
      .next += 1 |
      .tabs += [{workspace_id:$ws,tab_id:$tab,pane_id:$pane,"label":$lbl,cwd:$cwd,tokens:{}}]' | save
    jq -n --arg tab "$tab" --arg pane "$pane" '{result:{tab:{tab_id:$tab},root_pane:{pane_id:$pane}}}'
    ;;
  'tab rename')
    target=${3:-}; value=${4:-}
    query --arg id "$target" --arg value "$value" \
      '.tabs |= map(if .tab_id == $id then .label=$value else . end)' | save
    ;;
  'pane list')
    query --arg ws "$workspace" '{result:{panes:[.tabs[]|select(.workspace_id==$ws)|{workspace_id,tab_id,pane_id,tokens}]}}'
    ;;
  'pane report-metadata')
    target=${3:-}
    for token in "${tokens[@]}"; do
      key=${token%%=*}; value=${token#*=}
      query --arg id "$target" --arg key "$key" --arg value "$value" \
        '.tabs |= map(if .pane_id == $id then (.tokens[$key]=$value) else . end)' | save
    done
    ;;
  'pane get')
    target=${3:-}
    if [ -f "$gone" ]; then
      printf '{"error":{"code":"pane_not_found"}}\n'
      exit 0
    fi
    query --arg id "$target" '{result:{pane:(.tabs[]|select(.pane_id==$id)|{pane_id,workspace_id,tab_id,foreground_cwd:.cwd,cwd:.cwd})}}'
    ;;
  'pane run')
    target=${3:-}; command=${4:-}
    if [ "$command" = 'treehouse get' ]; then
      project=$(query -r --arg id "$target" '.tabs[]|select(.pane_id==$id)|.cwd')
      safe=${target//[:\/]/_}; wt="$FM_FAKE_WT_ROOT/$safe"
      git -C "$project" worktree add -q --detach "$wt" HEAD
      query --arg id "$target" --arg wt "$wt" \
        '.tabs |= map(if .pane_id == $id then .cwd=$wt else . end)' | save
    fi
    ;;
  'pane send-keys')
    # Submitting the launch is where this pane structurally disappears.
    : > "$gone"
    ;;
  'pane send-text') : ;;
  'agent get') printf '{"error":{"code":"agent_not_found"}}\n' ;;
  *) : ;;
esac
SH
  chmod +x "$fakebin/herdr"
  fm_fake_exit0 "$fakebin" treehouse
  cat > "$fakebin/$launch_binary" <<'SH'
#!/usr/bin/env bash
set -u
[ "$#" -eq 1 ] && [ "$1" = "--version" ]
SH
  chmod +x "$fakebin/$launch_binary"
}

run_herdr_spawn() {  # <extra-spawn-args...>
  env \
    FM_ROOT_OVERRIDE='' \
    FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 \
    FM_SPAWN_AGENT_UP_SLEEP=0 \
    FM_SPAWN_AGENT_UP_MAX_POLLS=40 \
    FM_FAKE_HERDR_STATE="$HERDR_STATE_FILE" \
    FM_FAKE_HERDR_LOG="$HERDR_LOG" \
    FM_FAKE_HERDR_GONE_MARK="$HERDR_GONE_MARK" \
    FM_FAKE_WT_ROOT="$HERDR_WT_ROOT" \
    HERDR_SESSION="fm-agentup-fake" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$ID" "$PROJ_DIR" --harness claude --backend herdr "$@" 2>&1
}

# A structurally gone pane can never come back and host an agent, so polling it
# out to the bound only delays a failure the first read already proved - and the
# in-pane recovery the bare-shell refusal prints would be a dead instruction
# there, since there is no pane left to interrupt or type into.
test_missing_endpoint_refuses_on_the_first_read() {
  local out status gone_line polls_after
  command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found (required by the herdr adapter)'; return 0; }
  make_herdr_case herdr-missing claude claude

  out=$(run_herdr_spawn)
  status=$?

  expect_code 1 "$status" "a spawn whose endpoint vanished should refuse"$'\n'"$out"
  assert_contains "$out" "is gone" "refusal did not say the endpoint was gone"
  assert_contains "$out" "RE-SPAWN the task onto a fresh endpoint" \
    "refusal did not tell the caller to re-spawn"
  assert_not_contains "$out" "--key C-c" \
    "refusal told the caller to interrupt a pane that no longer exists"
  assert_not_contains "$out" "Send this ONE-LINE relaunch" \
    "refusal told the caller to relaunch into a pane that no longer exists"
  assert_not_contains "$out" "delivery proceeded UNVERIFIED" \
    "a gone endpoint was downgraded from refusal to an unverified warning"
  gone_line=$(grep -n '<pane><send-keys>' "$HERDR_LOG" | head -1 | cut -d: -f1)
  [ -n "$gone_line" ] || fail "the launch was never submitted, so the endpoint never went missing"
  polls_after=$(awk -v n="$gone_line" 'NR > n && /<pane><get>/' "$HERDR_LOG" | wc -l | tr -d ' ')
  [ "$polls_after" -le 2 ] \
    || fail "a gone endpoint was polled $polls_after times out of a 40-poll bound instead of refusing on the first read"
  cleanup_task_tmp "$ID"
  pass "a structurally gone endpoint refuses on the first read and asks for a re-spawn"
}

# The re-spawn command must BE the command to run. A bare `fm-spawn.sh <id>
# <path>` re-resolves the harness from config and the backend from detection and
# comes back kind=ship, so a scout would silently return as a crewmate - the
# recovery would quietly change what the task is.
test_missing_endpoint_respawn_command_carries_kind_and_axes() {
  local out status
  command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found (required by the herdr adapter)'; return 0; }
  make_herdr_case herdr-missing-scout claude claude

  out=$(run_herdr_spawn --scout)
  status=$?

  expect_code 1 "$status" "a scout spawn whose endpoint vanished should refuse"$'\n'"$out"
  assert_contains "$out" "fm-spawn.sh' '$ID'" "refusal did not print the safely quoted re-spawn command"
  assert_contains "$out" "--scout --harness 'claude' --backend 'herdr'" \
    "the re-spawn command dropped this task's kind or resolved axes, so a copy-paste would come back as a different task"
  assert_not_contains "$out" "Re-spawn with the same axis flags you used here" \
    "the refusal still asks the reader to reconstruct flags the command should already carry"
  cleanup_task_tmp "$ID"
  pass "the re-spawn command carries this task's own kind and resolved axes"
}

test_kimi_brief_is_typed_only_after_the_agent_is_up
test_dead_shell_refuses_before_typing_the_brief
test_kimi_refusal_prints_a_two_step_file_pointer_recovery
test_dead_shell_refusal_is_recoverable_and_actionable
test_happy_path_launch_is_unchanged
test_unreadable_liveness_warns_without_refusing_or_burning_the_bound
test_invalid_bound_knobs_are_refused
test_unverified_liveness_backend_still_spawns_and_warns
test_unverified_non_kimi_backend_still_spawns_and_warns
test_missing_endpoint_refuses_on_the_first_read
test_missing_endpoint_respawn_command_carries_kind_and_axes

echo "# all fm-spawn-agent-up tests passed"
