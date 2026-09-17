#!/usr/bin/env bash
# tests/lib.sh - shared primitives for firstmate behavior tests.
#
# Source this from a test file:
#   # shellcheck source=tests/lib.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# It provides the boilerplate every test file used to re-roll: ok/not-ok
# reporters, a self-cleaning temp root, fakebin/PATH-shim helpers, deterministic
# git identity and fixture builders, state/<id>.meta writers, and the common
# string/exit-code/file assertions. Shared fake-toolchain and spawn-world
# builders live in tests/fixtures.sh; wake-queue mocks in wake-helpers.sh;
# secondmate-lifecycle mocks in secondmate-helpers.sh. Suite-specific fakes
# that encode a single test's terminal or lifecycle assumptions still belong
# with the tests that own them.
#
# ROOT is exported as the firstmate repo root (this file lives in tests/), so a
# sourcing test can use "$ROOT/bin/..." without recomputing it.

# Idempotent guard: behavior-area helper files (secondmate-helpers.sh,
# wake-helpers.sh, fixtures.sh) source this library for ROOT/fail/pass, and the
# test that includes them may also source it directly. Re-sourcing must not wipe
# the registered-cleanup array or reset state.
if [ -n "${FM_TEST_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_LIB_SOURCED=1

# Pin the fixture umask. Firstmate's state-root and process-event contracts
# refuse group- or world-writable state directories, and a permissive ambient
# umask (e.g. 0002) makes every `mkdir state` fixture fail that contract before
# the behavior under test can even run. 022 is the conventional default this
# suite's fixtures were written against.
umask 022

# Fixture Git isolation for every suite that reaches this library; the helper's
# header owns the invariant and the layers it deliberately leaves in force.
# shellcheck source=tests/git-config-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/git-config-helpers.sh"

# Exempt firstmate's own test suite from the gate-lifecycle refusal
# (bin/fm-gate-refuse-lib.sh). The no-mistakes gate runs this suite FROM a gate
# worktree - the exact environment that guard refuses - so without this every
# test that drives the real fm-spawn/fm-send/fm-teardown would be refused during
# firstmate's own validation. A confused gate agent never sources this helper, so
# the boundary against the real hazard is unaffected. tests/fm-gate-refuse.test.sh
# strips this to verify real refusal.
export FM_GATE_REFUSE_BYPASS=1

# Clear the task-worker marker bin/fm-spawn.sh exports into ship and scout
# panes. This suite builds git-init fixture repositories whose primary checkout
# it runs a copied bin/fm-test-run.sh in, and that runner refuses the primary
# under the marker. A case that verifies the refusal sets FM_TASK_ID itself.
unset FM_TASK_ID

# Clear the tasks-axi env overrides. An operator shell exports TASKS_AXI_FILE
# (and may export TASKS_AXI_BACKEND) at its real home's backlog, and tasks-axi
# resolves that env AHEAD of the .tasks.toml a fixture copies, so a suite that
# seeds a temp home with bare `tasks-axi` would silently write the operator's
# live backlog instead - tests/fm-public-followup.test.sh did exactly that. Every
# fixture addresses its own data/backlog.md through its copied .tasks.toml, an
# explicit --file, or bin/fm-tasks-axi.sh; a case that verifies the wrapper
# against an ambient override sets TASKS_AXI_FILE itself.
unset TASKS_AXI_FILE TASKS_AXI_BACKEND

# Drop the inherited operational-home overrides. Every production entry point a
# fixture drives - watcher, arm, daemon, lock script - prefers an inherited
# FM_ROOT_OVERRIDE/FM_STATE_OVERRIDE over its own resolution, so a single value
# leaked from the invoking environment (a live firstmate lane is the observed
# case) silently rebinds a fixture onto a REAL home's state: it steals the watch
# lock, touches the liveness beacon, and a fixture --restart TERMs the real
# fleet watcher. A suite that needs an override sets it explicitly AFTER
# sourcing this library, which is how every current suite already works.
# tests/fm-supervision-test-isolation.test.sh owns the regression coverage.
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE

# Resolve the repo root from this library's own location. Consumed by sourcing
# test files, not by this library, so it reads as "unused" here.
# shellcheck disable=SC2034
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- reporters --------------------------------------------------------------

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

# --- self-cleaning temp root ------------------------------------------------
#
# fm_test_tmproot <prefix> echoes a fresh temp dir and registers it for removal
# on EXIT/INT/TERM. A test file that needs extra teardown (e.g. killing a
# daemon) should define its own EXIT trap and call fm_test_cleanup from inside
# it so registered dirs are still removed.
#
# The call site is almost always `TMP_ROOT=$(fm_test_tmproot prefix)`, which
# forks a subshell to capture stdout. Anything that function does to the
# current shell's state - an array append, a trap - dies with that subshell
# and never reaches the real caller, so registration cannot go through
# in-process state. `$$` is the one thing bash keeps stable across that
# boundary (it always resolves to the invoking shell's PID, not the
# subshell's - see `man bash` on `$$`), so fm_test_tmproot records the
# directory in a `$$`-keyed registry file instead, and the trap that reaps
# that file is armed once, here, at source time - which always runs in the
# real caller, never a subshell.

FM_TEST_CLEANUP_DIRS=()
FM_TEST_CLEANUP_REGISTRY=$(mktemp "${TMPDIR:-/tmp}/.fm-test-cleanup.$$.XXXXXX") || return 1

fm_test_pid_identity() {
  local pid=$1
  FM_STATE_OVERRIDE="${TMPDIR:-/tmp}" bash -c \
    '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$pid"
}

FM_TEST_OWNER_IDENTITY=$(fm_test_pid_identity "$$") || {
  rm -f "$FM_TEST_CLEANUP_REGISTRY"
  return 1
}

# Hermetic operational home for EVERY suite. Paired with the unset above, a
# spawned watcher, arm, daemon, or lock script that carries no override still
# resolves every FM_HOME-derived path into this suite's own temp tree - never
# into a real firstmate home, and never into this worktree's own state. A suite
# that needs a different fixture home sets FM_HOME itself AFTER sourcing this
# library.
FM_TEST_HERMETIC_HOME=$(mktemp -d "${TMPDIR:-/tmp}/fm-hermetic-home.XXXXXX") || {
  rm -f "$FM_TEST_CLEANUP_REGISTRY"
  return 1
}
mkdir -p "$FM_TEST_HERMETIC_HOME/state"
FM_TEST_CLEANUP_DIRS+=("$FM_TEST_HERMETIC_HOME")
export FM_HOME="$FM_TEST_HERMETIC_HOME"

# --- process-event runner reaping -------------------------------------------
#
# A process-event runner is detached into its own process group and reparents to
# init, so removing a fixture directory does not stop one: only sweeping the home
# that owns it does. Registration goes through a `$$`-keyed registry file for the
# same reason the temp roots do - a fixture home is almost always built inside a
# command substitution (`home=$(make_home x)`), and an array append there never
# reaches the caller, so a suite that tracked its homes in a shell array was
# silently tracking nothing and left every runner it started behind.
#
# The sweep is scoped to the exact home (and its claim root when the suite uses a
# private one). It never matches on a script or process name, which would reach
# into another home's live runners.

FM_TEST_PROCEVENT_REGISTRY=$(mktemp "${TMPDIR:-/tmp}/.fm-test-procevent.$$.XXXXXX") || return 1

fm_test_track_procevent_home() {  # <home> [claim-root]
  [ -n "${1:-}" ] || return 1
  printf '%s\t%s\n' "$1" "${2-}" >> "$FM_TEST_PROCEVENT_REGISTRY"
}

fm_test_reap_procevent_homes() {
  local home claim_root seen=$'\n'
  [ -f "$FM_TEST_PROCEVENT_REGISTRY" ] || return 0
  while IFS=$'\t' read -r home claim_root; do
    [ -n "$home" ] || continue
    case "$seen" in *$'\n'"$home"$'\n'*) continue ;; esac
    seen+="$home"$'\n'
    [ -d "$home/state/procevent" ] || continue
    if [ -n "$claim_root" ]; then
      FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_PROCEVENT_CLAIM_ROOT="$claim_root" \
        "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
    else
      FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
        "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
    fi
  done < "$FM_TEST_PROCEVENT_REGISTRY"
  rm -f "$FM_TEST_PROCEVENT_REGISTRY"
}

# Ceiling on how long a fixture's blocking stub may keep polling. A stub that
# waits for a trigger file by re-running `sleep` is a high-frequency source of
# process spawns, and one that outlives its test - because the test was killed
# before any cleanup ran - is what turned leftover fixtures into a host-wide
# process storm. Every blocking stub this suite writes stops itself at this
# bound, so an escaped one is bounded in duration and cost on its own, before
# its owner's guard reaps it.
FM_TEST_STUB_MAX_BLOCK_SECONDS=${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}
export FM_TEST_STUB_MAX_BLOCK_SECONDS

# Watchers, arms, and daemons a suite spawns are tracked here and reaped by the
# cleanup below, so an ordinary suite exit can never leak a supervision process
# that outlives its fixture and holds a lock, or a sleep assertion, that the
# next suite then reads as live. Tracking is idempotent and a pid that already
# exited is skipped.
FM_TEST_CHILD_PIDS=()

# fm_test_track_pid <pid>: register a background child for cleanup reaping.
fm_test_track_pid() {
  local pid=$1
  case "$pid" in
    ''|*[!0-9]*) return 0 ;;
  esac
  FM_TEST_CHILD_PIDS+=("$pid")
}

# Print this shell's whole live descendant subtree, innermost generation last.
# Scoped strictly to the calling test process's own tree: no command-name
# patterns are ever matched, so a sibling firstmate home running the same
# scripts can never be touched by a suite's teardown. Prefer /proc children
# on Linux; pgrep -P is the portable fallback.
fm_test_descendant_pids() {  # <pid>
  local parent=$1 kid kids
  kids=
  if [ -r "/proc/$parent/task/$parent/children" ]; then
    kids=$(cat "/proc/$parent/task/$parent/children" 2>/dev/null || true)
  fi
  if [ -z "$kids" ]; then
    kids=$(pgrep -P "$parent" 2>/dev/null || true)
  fi
  for kid in $kids; do
    case "$kid" in
      ''|*[!0-9]*) continue ;;
    esac
    printf '%s\n' "$kid"
    fm_test_descendant_pids "$kid"
  done
}

# True when path $1 is this repo worktree or a registered fixture temp dir,
# or a file inside one of those. Used by path-scoped teardown only.
fm_test_path_is_scoped() {  # <path>
  local path=$1 dir
  [ -n "$path" ] || return 1
  case "$path" in
    "$ROOT"|"$ROOT"/*) return 0 ;;
  esac
  for dir in "${FM_TEST_CLEANUP_DIRS[@]:-}"; do
    [ -n "$dir" ] || continue
    case "$path" in
      "$dir"|"$dir"/*) return 0 ;;
    esac
  done
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    case "$path" in
      "$dir"|"$dir"/*) return 0 ;;
    esac
  done < "$FM_TEST_CLEANUP_REGISTRY"
  return 1
}

# Untruncated argv for pid $1. Linux `ps -o command=` without -ww clips to
# the window width (often 80), which drops the fixture path and makes
# path-scoped teardown miss the child; /proc cmdline is the full argv.
#
# Every /proc probe in this teardown path is best-effort and absorbs its own
# failure. A pid can exit between the readability check and the read, which
# fails the read with ESRCH or removes the entry outright, and a vanished pid is
# simply not a kill candidate. Left unabsorbed, that race aborts teardown from
# inside the EXIT trap of a suite running with errexit, so a file whose every
# assertion passed still reports a non-zero exit.
fm_test_pid_command_line() {  # <pid>
  local pid=$1 cmd
  [ -n "$pid" ] || return 1
  if [ -r "/proc/$pid/cmdline" ]; then
    cmd=$(tr '\0' ' ' 2>/dev/null < "/proc/$pid/cmdline") || cmd=
    cmd=${cmd%"${cmd##*[![:space:]]}"}
    [ -n "$cmd" ] || return 1
    printf '%s\n' "$cmd"
    return 0
  fi
  cmd=$(LC_ALL=C ps -ww -o args= -p "$pid" 2>/dev/null) || return 1
  [ -n "$cmd" ] || return 1
  printf '%s\n' "$cmd"
}

# True when pid $1's command line references a path inside THIS repo worktree
# or one of this suite's registered temp dirs. This is the ONLY kill authority
# in test teardown: a descendant that fails the check - the primary home's own
# live supervision among them, which shares every script name we use - is left
# strictly alone.
fm_test_pid_is_path_scoped() {  # <pid>
  local pid=$1 cmd dir arg fd target
  [ -n "$pid" ] || return 1
  if [ -r "/proc/$pid/cmdline" ]; then
    while IFS= read -r -d '' arg || [ -n "${arg:-}" ]; do
      fm_test_path_is_scoped "$arg" && return 0
      arg=
    done 2>/dev/null < "/proc/$pid/cmdline" || true
    target=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
    target=${target% (deleted)}
    fm_test_path_is_scoped "$target" && return 0
    for fd in /proc/"$pid"/fd/*; do
      [ -e "$fd" ] || continue
      target=$(readlink "$fd" 2>/dev/null) || continue
      for dir in "${FM_TEST_CLEANUP_DIRS[@]:-}"; do
        [ -n "$dir" ] || continue
        case "$target" in
          "$dir"|"$dir"/*) return 0 ;;
        esac
      done
      while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        case "$target" in
          "$dir"|"$dir"/*) return 0 ;;
        esac
      done < "$FM_TEST_CLEANUP_REGISTRY"
    done
  fi
  cmd=$(fm_test_pid_command_line "$pid") || return 1
  [ -n "$cmd" ] || return 1
  case "$cmd" in
    *"$ROOT"/*) return 0 ;;
  esac
  for dir in "${FM_TEST_CLEANUP_DIRS[@]:-}"; do
    [ -n "$dir" ] || continue
    case "$cmd" in
      *"$dir"/*) return 0 ;;
    esac
  done
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    case "$cmd" in
      *"$dir"/*) return 0 ;;
    esac
  done < "$FM_TEST_CLEANUP_REGISTRY"
  return 1
}

fm_test_kill_scoped() {  # <-TERM|-KILL> <pid>...
  local signal=$1 pid
  shift
  for pid in "$@"; do
    [ -n "$pid" ] || continue
    kill -0 "$pid" 2>/dev/null || continue
    fm_test_pid_is_path_scoped "$pid" || continue
    kill "$signal" "$pid" 2>/dev/null || true
  done
}

# Linux: signal every process whose exe or cmdline references a registered
# fixture temp dir. mktemp paths are unique to this suite, so this does not
# need a parent-pid walk; pgrep -P misses some CI children and left the
# isolation long-runner and busy-loop alive.
fm_test_kill_cleanup_dir_exes() {  # <-TERM|-KILL>
  local signal=$1 proc pid target dir cmd
  [ -d /proc ] || return 0
  for proc in /proc/[0-9]*; do
    pid=${proc#/proc/}
    case "$pid" in
      ''|*[!0-9]*) continue ;;
    esac
    [ "$pid" = "${BASHPID:-$$}" ] && continue
    target=$(readlink "$proc/exe" 2>/dev/null) || target=
    target=${target%' (deleted)'}
    cmd=
    if [ -r "$proc/cmdline" ]; then
      cmd=$(tr '\0' ' ' 2>/dev/null < "$proc/cmdline") || cmd=
      cmd=${cmd%"${cmd##*[![:space:]]}"}
    fi
    for dir in "${FM_TEST_CLEANUP_DIRS[@]:-}"; do
      [ -n "$dir" ] || continue
      case "$target" in
        "$dir"|"$dir"/*)
          kill "$signal" "$pid" 2>/dev/null || true
          continue 2
          ;;
      esac
      case "$cmd" in
        *"$dir"/*)
          kill "$signal" "$pid" 2>/dev/null || true
          continue 2
          ;;
      esac
    done
    while IFS= read -r dir; do
      [ -n "$dir" ] || continue
      case "$target" in
        "$dir"|"$dir"/*)
          kill "$signal" "$pid" 2>/dev/null || true
          break
          ;;
      esac
      case "$cmd" in
        *"$dir"/*)
          kill "$signal" "$pid" 2>/dev/null || true
          break
          ;;
      esac
    done < "$FM_TEST_CLEANUP_REGISTRY"
  done
}

# Stop every supervision process this suite spawned so no watcher, arm, or
# daemon outlives its fixture. Candidates come from tracked pids and the
# suite's own descendant tree, but EVERY kill is gated on fm_test_pid_is_path_
# scoped: only processes whose command path lies inside this worktree or a
# registered fixture temp dir are ever signalled. TERM first with a bounded
# grace, then KILL whatever remains.
fm_test_reap_children() {
  local pid i alive root_pid
  # Capture before command substitution: inside $(...), BASHPID is the subshell
  # so pgrep would miss this shell's background children (Linux bash 4+).
  root_pid=${BASHPID:-$$}
  for pid in "${FM_TEST_CHILD_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    fm_test_kill_scoped -TERM "$pid"
  done
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    fm_test_kill_scoped -TERM "$pid"
  done <<EOF
$(fm_test_descendant_pids "$root_pid")
EOF
  fm_test_kill_cleanup_dir_exes -TERM
  i=0
  while [ "$i" -lt 30 ]; do
    alive=0
    for pid in "${FM_TEST_CHILD_PIDS[@]:-}"; do
      [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && alive=1
    done
    [ "$alive" -eq 1 ] || break
    sleep 0.1
    i=$((i + 1))
  done
  for pid in "${FM_TEST_CHILD_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    fm_test_kill_scoped -KILL "$pid"
  done
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    fm_test_kill_scoped -KILL "$pid"
  done <<EOF
$(fm_test_descendant_pids "$root_pid")
EOF
  fm_test_kill_cleanup_dir_exes -KILL
  return 0
}

fm_test_cleanup() {
  local d pid
  for pid in "${FM_TEST_CHILD_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
  done
  fm_test_reap_children
  fm_test_reap_procevent_homes
  for d in "${FM_TEST_CLEANUP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  if [ -f "$FM_TEST_CLEANUP_REGISTRY" ]; then
    while IFS= read -r d; do
      [ -n "$d" ] && rm -rf "$d"
    done < "$FM_TEST_CLEANUP_REGISTRY"
    rm -f "$FM_TEST_CLEANUP_REGISTRY"
  fi
}

fm_test_tmproot() {
  local prefix=${1:-fm-test} root tmp_base
  tmp_base=${TMPDIR:-/tmp}
  tmp_base=${tmp_base%/}
  root=$(mktemp -d "$tmp_base/${prefix}.XXXXXX") || return 1
  root=$(cd -P -- "$root" && pwd -P) || return 1
  if ! printf '%s\n%s\n' "$$" "$FM_TEST_OWNER_IDENTITY" > "$root/.fm-test-fixture" ||
    ! printf '%s\n' "$root" >> "$FM_TEST_CLEANUP_REGISTRY"; then
    rm -rf "$root"
    return 1
  fi
  printf '%s\n' "$root"
}

trap fm_test_cleanup EXIT
trap 'fm_test_cleanup; exit 130' INT
trap 'fm_test_cleanup; exit 143' TERM
trap 'fm_test_cleanup; exit 129' HUP
trap 'fm_test_cleanup; exit 131' QUIT

# fm_test_reap_orphans: best-effort sweep for fixture roots left behind by a
# prior run that was killed hard enough to skip the traps above (e.g. a
# SIGKILL timeout). Only removes directories carrying the .fm-test-fixture
# marker fm_test_tmproot writes, so it never touches unrelated fm-* tmp dirs
# from real (non-test) firstmate commands. The marker identifies the owning
# shell across PID reuse, so the same live owner always wins over the age
# fallback for dead or unowned roots.
FM_TEST_ORPHAN_MAX_AGE_SECONDS=${FM_TEST_ORPHAN_MAX_AGE_SECONDS:-3600}

fm_test_reap_orphans() {
  local marker dir mtime now owner_pid owner_identity current_identity
  now=$(date +%s)
  for marker in "${TMPDIR:-/tmp}"/fm-*/.fm-test-fixture; do
    [ -e "$marker" ] || continue
    owner_pid=$(sed -n '1p' "$marker" 2>/dev/null) || owner_pid=
    owner_identity=$(sed -n '2,$p' "$marker" 2>/dev/null) || owner_identity=
    case "$owner_pid" in
      '' | *[!0-9]*) ;;
      *)
        current_identity=$(fm_test_pid_identity "$owner_pid" 2>/dev/null) || current_identity=
        if [ -n "$owner_identity" ] && [ "$current_identity" = "$owner_identity" ]; then
          continue
        fi
        ;;
    esac
    mtime=$(stat -c %Y "$marker" 2>/dev/null || stat -f %m "$marker" 2>/dev/null) || continue
    [ $((now - mtime)) -ge "$FM_TEST_ORPHAN_MAX_AGE_SECONDS" ] || continue
    dir=$(dirname "$marker")
    if [ -d "$dir" ] && [ ! -L "$dir" ]; then
      find "$dir" -type d -exec chmod u+rwx {} + 2>/dev/null || true
    fi
    rm -rf "$dir"
  done
}

# A parent coordinator can reap once before it starts isolated child sections.
# Those children use their own EXIT cleanup and must not spend their bounded
# execution window repeating the same global stale-fixture scan.
if [ "${FM_TEST_SKIP_ORPHAN_REAP:-0}" != 1 ]; then
  fm_test_reap_orphans
fi

# --- live-capability gate ---------------------------------------------------
#
# fm_live_gate <policy> <vars> [tool ...]
#
# The single gate every live-harness guard opens with, so "can this host run
# this guard for real, and should it?" is decided in one place instead of in
# two dozen hand-rolled env checks. It returns 0 when the guard should run, and
# otherwise ends the script with one runner-readable line:
#
#   skip: live: <tool> absent                 this host cannot run the guard
#   skip: live: disabled by <VAR>=0           an explicit local opt-out
#   skip: live: opt-in; set <VAR>=1 to run    a guard that spends model tokens
#
# <policy> is default-on for a guard that spends no model tokens, so it runs
# wherever its tools are installed - notably on the machine the product and its
# validation actually run on - and opt-in for a guard that submits prompts,
# which stays deliberate. <vars> is the guard's own control variable, or a
# comma-separated list when a guard has more than one entry point.
#
# Setting any of those variables to 1 (or FM_LIVE=1, for every guard at once)
# both turns the guard on and makes an absent tool a hard failure rather than a
# skip, which is how "run it after a harness upgrade" keeps proving the guard
# actually ran. Setting one to 0 (or FM_LIVE=0) turns it off; a guard's own
# variable wins over FM_LIVE.
#
# Sourcing this library also exports FM_GATE_REFUSE_BYPASS=1, which is what
# lets a live guard drive the real fm-spawn/fm-send/fm-teardown from inside a
# no-mistakes gate worktree instead of being refused by
# bin/fm-gate-refuse-lib.sh.

fm_live_gate() {
  local policy=$1 vars=$2
  shift 2
  local var value rest primary requested=0 disabled_by='' tool
  local -a var_list=()

  case "$policy" in
    default-on | opt-in) ;;
    *) fail "fm_live_gate: unknown policy '$policy' (expected default-on or opt-in)" ;;
  esac

  rest=$vars
  while [ -n "$rest" ]; do
    var=${rest%%,*}
    if [ "$var" = "$rest" ]; then
      rest=''
    else
      rest=${rest#*,}
    fi
    [ -n "$var" ] && var_list+=("$var")
  done
  [ "${#var_list[@]}" -gt 0 ] || fail "fm_live_gate: at least one control variable is required"
  primary=${var_list[0]}

  for var in "${var_list[@]}"; do
    value=${!var:-}
    case "$value" in
      1) requested=1 ;;
      0) [ -n "$disabled_by" ] || disabled_by=$var ;;
    esac
  done

  if [ "$requested" -eq 0 ]; then
    if [ -n "$disabled_by" ]; then
      printf 'skip: live: disabled by %s=0\n' "$disabled_by"
      exit 0
    fi
    case "${FM_LIVE:-}" in
      0)
        printf 'skip: live: disabled by FM_LIVE=0\n'
        exit 0
        ;;
      1) requested=1 ;;
      *)
        if [ "$policy" = opt-in ]; then
          printf 'skip: live: opt-in; set %s=1 to run\n' "$primary"
          exit 0
        fi
        ;;
    esac
  fi

  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 && continue
    if [ "$requested" -eq 1 ]; then
      printf 'not ok - %s was requested but %s is not installed\n' "$primary" "$tool" >&2
      exit 1
    fi
    printf 'skip: live: %s absent\n' "$tool"
    exit 0
  done

  return 0
}

# --- fakebin / PATH shims ---------------------------------------------------
#
# fm_fakebin <dir> creates <dir>/fakebin and echoes it; prepend it to PATH to
# shadow real tools with stubs. fm_fake_exit0 drops trivial exit-0 stubs for the
# named tools into a fakebin dir. fm_fake_crash_injector drops the shim a fake
# uses to crash the process under test deterministically. fm_fake_version_tool
# drops a stub for a tool whose installed version bootstrap gates, so a fixture
# cannot be reported as an unparseable build simply for answering `--version`
# with nothing.

fm_fakebin() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  printf '%s\n' "$fakebin"
}

fm_fake_exit0() {
  local fakebin=$1 tool
  shift
  for tool in "$@"; do
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
}

# fm_install_fake_caffeinate <fakebin>: drop a PATH stub that mimics
# `caffeinate -ims -w <pid>` without touching the host's real sleep assertion -
# a test must never keep the developer's own machine awake. It stays alive until
# the watched pid exits, or until it is killed, so a test can assert both the
# spawn and the cleanup. When FM_FAKE_CAFFEINATE_LOG is set, each invocation
# appends "<stub-pid> <args>".
fm_install_fake_caffeinate() {
  local fakebin=$1
  mkdir -p "$fakebin"
  cat > "$fakebin/caffeinate" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${FM_FAKE_CAFFEINATE_LOG:-}" ]; then
  printf '%s %s\n' "$$" "$*" >> "$FM_FAKE_CAFFEINATE_LOG"
fi
watched=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -w)
      shift
      watched=${1:-}
      ;;
  esac
  [ "$#" -gt 0 ] && shift
done
if [ -n "$watched" ]; then
  while kill -0 "$watched" 2>/dev/null; do
    sleep 0.05
  done
fi
exit 0
SH
  chmod +x "$fakebin/caffeinate"
}


# fm_install_fake_tmux_pane <fakebin> <calls>: drop a PATH stub that answers the
# status companion's pane probe with pane `%42` for the first <calls> calls and
# fails afterwards, so a follow loop runs exactly <calls> refreshes and then
# exits because its primary pane is gone. The call tally lives in the file named
# by FM_STATUS_BAR_TMUX_COUNT, which the caller must point at a fresh path.
fm_install_fake_tmux_pane() {
  local fakebin=$1 calls=$2
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
count=0
[ ! -f "\$FM_STATUS_BAR_TMUX_COUNT" ] || count=\$(<"\$FM_STATUS_BAR_TMUX_COUNT")
count=\$((count + 1))
printf '%s\n' "\$count" > "\$FM_STATUS_BAR_TMUX_COUNT"
[ "\$count" -le $calls ] || exit 1
printf '%s\n' '%42'
SH
  chmod +x "$fakebin/tmux"
}

# fm_install_compatible_tasks_axi <fakebin-dir>: drop a PATH stub that satisfies
# bin/fm-tasks-axi-lib.sh's fm_tasks_axi_compatible probe AND
# bin/fm-decision-hold.sh's require_tasks_axi (hold --help exposes --kind captain).
# Scout teardown success fixtures need this when the host PATH is sanitized
# (e.g. no-mistakes gate worktrees without nvm), otherwise decision-hold refuses
# with "compatible tasks-axi is required" before the adapter-under-test runs.
# The reported version is read from the library's own floor rather than pinned
# here, so a creator-side bump of FM_TASKS_AXI_MIN cannot leave this stub quietly
# below it - which is exactly how the scout teardown fixtures started refusing.
fm_install_compatible_tasks_axi() {
  local fb=$1 floor
  mkdir -p "$fb"
  floor=$(sed -n 's/^FM_TASKS_AXI_MIN=\([0-9][0-9.]*\)$/\1/p' "$ROOT/bin/fm-tasks-axi-lib.sh" | head -1)
  [ -n "$floor" ] || {
    echo "fm_install_compatible_tasks_axi: no FM_TASKS_AXI_MIN in $ROOT/bin/fm-tasks-axi-lib.sh" >&2
    return 1
  }
  cat > "$fb/tasks-axi" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  --version)
    printf '%s\n' '$floor'
    exit 0
    ;;
  update)
    if [ "\${2:-}" = --help ]; then
      printf '%s\n' 'usage: tasks-axi update <id> [flags]'
      printf '%s\n' '  --body-file <path>'
      printf '%s\n' '  --archive-body'
      exit 0
    fi
    ;;
  mv)
    if [ "\${2:-}" = --help ]; then
      printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>'
      exit 0
    fi
    ;;
  hold)
    if [ "\${2:-}" = --help ]; then
      printf '%s\n' 'usage: tasks-axi hold <id> [flags]'
      printf '%s\n' '  --kind captain'
      printf '%s\n' '  --reason <text>'
      exit 0
    fi
    ;;
  show)
    # No durable holds in these fixtures: absent task is fine for verify with
    # decisions_reviewed=1 and empty decision_keys.
    exit 1
    ;;
esac
exit 0
SH
  chmod +x "$fb/tasks-axi"
  # Probe the stub exactly as the gates will, so a drifted floor or helptext
  # fails loudly here instead of surfacing as "compatible tasks-axi is required"
  # from whatever gate the case installed this stub to get past.
  # A child process, not a `( PATH=...; . lib; ... )` subshell: assigning PATH
  # inside a subshell of this sourced library is an SC2030 whose SC2031 partner
  # then fires on every `PATH="$fakebin:$PATH" cmd` in every suite that sources
  # this file, which is the whole canonical set under CI's --external-sources.
  PATH="$fb:$PATH" bash -c 'set -u; . "$1"; fm_tasks_axi_compatible' \
    fm-tasks-axi-probe "$ROOT/bin/fm-tasks-axi-lib.sh" || {
    echo "fm_install_compatible_tasks_axi: stub in $fb does not satisfy fm_tasks_axi_compatible" >&2
    return 1
  }
}

# fm_fake_crash_injector <fakebin>
# Drops an `fm-crash-inject <pid>` shim that a PATH fake calls to simulate a
# hard crash of the process under test. It SIGKILLs <pid> and then returns only
# once that process is observably gone, so the fake never resumes work while its
# victim could still be running. Sleeping a fixed interval instead makes the
# injection a wall-clock bet that a loaded host loses: the fake wakes up and
# completes the very operation the case needs left unfinished. Exits non-zero
# with a diagnostic if the target outlives the signal, so a broken injection
# fails loudly rather than silently changing what the case measures.
fm_fake_crash_injector() {
  local fakebin=$1
  cat > "$fakebin/fm-crash-inject" <<'SH'
#!/usr/bin/env bash
set -u
target=${1:?fm-crash-inject: <pid> required}
case "$target" in
  ''|*[!0-9]*)
    echo "fm-crash-inject: '$target' is not a pid" >&2
    exit 1
    ;;
esac
kill -KILL "$target" 2>/dev/null || true
waited=0
while [ "$waited" -lt 600 ]; do
  case "$(ps -o state= -p "$target" 2>/dev/null | tr -d '[:space:]')" in
    ''|Z*) exit 0 ;;
  esac
  waited=$((waited + 1))
  sleep 0.05
done
echo "fm-crash-inject: pid $target still running 30s after SIGKILL" >&2
exit 1
SH
  chmod +x "$fakebin/fm-crash-inject"
}

# fm_fake_blind_ancestry <fakebin>
# Blind the parent-chain walks: a query of the FIELD-FIRST per-pid form those walks
# use - `ps -o comm=|args=|ppid= -p <pid>`, the shape in bin/fm-harness.sh,
# bin/fm-session-lock-lib.sh, bin/fm-sessionstart-nudge.sh and bin/fm-backend.sh's
# cmux ancestor detection - reports a bash ancestor terminating at pid 1, so ancestry
# proves nothing and the marker a case sets is the only evidence left. A case that pins
# its harness with a marker (CLAUDECODE=1 and friends) needs this, because a structural
# ancestor of a DIFFERENT harness outranks a marker - without it, the harness the SUITE
# was launched from decides the verdict.
# Every other ps query reaches the real ps untouched, and the pid-first form is
# deliberately among them: bin/fm-tmux-lib.sh and bin/backends/tmux.sh read pane and
# cursor identity with `ps -p <pid> -o args=`, so intercepting that shape too would make
# a pane assertion under a PATH-wide blind read `bash` and reject every cursor pane.
fm_fake_blind_ancestry() {
  local fakebin=$1 real_ps
  real_ps=$(command -v ps) || return 1
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
case "\$*" in
  '-o comm= -p '*) printf '%s\n' bash ;;
  '-o args= -p '*) printf '%s\n' bash ;;
  '-o ppid= -p '*) printf '%s\n' 1 ;;
  *) exec "$real_ps" "\$@" ;;
esac
SH
  chmod +x "$fakebin/ps"
}

# fm_fake_version_tool <fakebin> <tool> <override-env-var> <default-version>
# The stub answers `--version` with <override-env-var> when that variable is set
# and non-empty, and with <default-version> otherwise; every other invocation
# exits 0. A case that needs to drive a version floor exports the variable.
fm_fake_version_tool() {
  local fakebin=$1 tool=$2 override=$3 default=$4
  cat > "$fakebin/$tool" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf '%s\n' "\${$override:-$default}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/$tool"
}

# fm_fake_launch_binary <fakebin> <binary>...: install PATH stubs for the
# harness launch binaries that bin/fm-spawn.sh's launch-binary preflight
# resolves and `--version`-probes before it will create a task endpoint. A
# fixture that omits one only ever proves that refusal - and only on a host
# where the real CLI is absent, which is every CI runner and almost no
# developer laptop, so the gap passes locally and fails in CI.
#
# Each stub answers --version and exits 0 otherwise, the same shape
# tests/fm-control-relaunch.test.sh already shims its harnesses with.
#
# The install is proven rather than assumed: a stub that is not executable, or
# that fails the very probe the preflight runs, would let a suite go green
# against the refusal it was written to avoid, so each one is probed here.
fm_fake_launch_binary() {
  local fakebin=$1 binary
  shift
  mkdir -p "$fakebin"
  for binary in "$@"; do
    fm_fake_version_tool "$fakebin" "$binary" FM_FAKE_HARNESS_VERSION 1.0.0
    [ -x "$fakebin/$binary" ] || fail "launch-binary shim '$binary' is not executable in $fakebin"
    "$fakebin/$binary" --version >/dev/null 2>&1 \
      || fail "launch-binary shim '$binary' failed the --version probe the spawn preflight runs"
  done
}

# --- portable file timestamps -----------------------------------------------

# fm_touch_epoch <epoch> <path> [path...]: set each path's modification time to
# an absolute epoch second on every supported host.
#
# There is no portable touch(1) flag that takes an epoch: `touch -d @<epoch>` is
# a GNU extension and BSD touch rejects it outright ("out of range or illegal
# time specification"), leaving the file at its current mtime. A test that wants
# a beacon aged 700 seconds then silently measures a brand-new one.
# `touch -t [[CC]YY]MMDDhhmm[.SS]` is POSIX and both accept it, so the only
# host-specific step left is turning the epoch into that stamp, and date(1)
# spells that two incompatible ways. Probe them in this order: GNU date rejects
# `-r <seconds>` (its -r takes a file), while BSD date rejects `-d` as an
# illegal option, so whichever runs is the one that understood the request.
# TZ is pinned to UTC for date and touch so repeated DST hours stay unambiguous.
fm_touch_epoch() {
  local epoch=$1 stamp
  shift
  stamp=$(TZ=UTC0 date -d "@$epoch" +%Y%m%d%H%M.%S 2>/dev/null) \
    || stamp=$(TZ=UTC0 date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null) \
    || fail "fm_touch_epoch: date(1) accepted neither -d @<epoch> nor -r <epoch>"
  TZ=UTC0 touch -t "$stamp" "$@" \
    || fail "fm_touch_epoch: touch -t $stamp failed for $*"
}

# --- deterministic git identity and fixtures --------------------------------

# fm_git_identity [name] [email]: export a fixed author/committer identity so
# fixture commits never depend on the host git config.
fm_git_identity() {
  export GIT_AUTHOR_NAME=${1:-fmtest} GIT_AUTHOR_EMAIL=${2:-fmtest@example.invalid}
  export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
}

# fm_git_init_commit <dir>: create a git repo at <dir> with a README and one
# commit. Uses an inline identity so it works whether or not fm_git_identity was
# called. The initial branch is pinned rather than inherited from
# init.defaultBranch, so a fixture that names main resolves the same on a
# developer machine and on a runner that still defaults to master.
fm_git_init_commit() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  printf '# %s\n' "$(basename "$dir")" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

# fm_git_add_origin <repo> <bare>: clone <repo> bare into <bare> and register it
# as <repo>'s origin via a file:// URL (so later clones resolve an absolute path).
fm_git_add_origin() {
  local repo=$1 remote=$2 remote_abs
  git clone --quiet --bare "$repo" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$repo" remote add origin "file://$remote_abs"
}

# fm_git_worktree <repo> <worktree> <branch>: initialize <repo> with one commit
# and a local bare origin, then add a worktree on a fresh branch.
fm_git_worktree() {
  local repo=$1 worktree=$2 branch=$3
  fm_git_init_commit "$repo"
  fm_git_add_origin "$repo" "$repo.origin.git"
  git -C "$repo" worktree add --quiet -b "$branch" "$worktree"
}

# --- state/<id>.meta writers ------------------------------------------------

# fm_write_meta <file> <key=val> ...: write the given key=val lines to a meta
# file (truncating any prior content).
fm_write_meta() {
  local file=$1 kv
  shift
  : > "$file"
  for kv in "$@"; do
    printf '%s\n' "$kv" >> "$file"
  done
}

# fm_write_secondmate_meta <file> <home> [window] [projects] [harness]: write the
# standard kind=secondmate meta block used across the secondmate suites. Window
# defaults to firstmate:fm-<id>, projects defaults to alpha, and harness defaults
# to echo to match the common case.
fm_write_secondmate_meta() {
  local file=$1 home=$2 id window projects=${4:-alpha} harness=${5:-echo}
  id=$(basename "$file" .meta)
  window=${3:-firstmate:fm-$id}
  fm_write_meta "$file" \
    "window=$window" \
    "endpoint_task_id=$id" \
    "worktree=$home" \
    "project=$home" \
    "harness=$harness" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "home=$home" \
    "projects=$projects"
}

# --- common assertions ------------------------------------------------------

# assert_equals <expected> <actual> <msg>
assert_equals() {
  [ "$1" = "$2" ] || fail "$3 (expected '$1', got '$2')"
}

# assert_not_equals <unexpected> <actual> <msg>
assert_not_equals() {
  [ "$1" != "$2" ] || fail "$3 (unexpectedly got '$1')"
}

# assert_contains <haystack> <needle> <msg>
assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3 (missing: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
  esac
}

# assert_not_contains <haystack> <needle> <msg>
assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3 (unexpected: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
    *) : ;;
  esac
}

# expect_code <expected> <actual> <label>
expect_code() {
  local expected=$1 actual=$2 label=$3
  [ "$actual" = "$expected" ] || fail "$label: expected exit $expected, got $actual"
}

# assert_grep <pattern> <file> <msg>: fixed-string grep must match in <file>.
# `--` guards patterns that begin with '-' (e.g. backlog/registry lines).
assert_grep() {
  grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_no_grep <pattern> <file> <msg>: fixed-string grep must NOT match.
assert_no_grep() {
  ! grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_absent <path> <msg>: path must not exist.
assert_absent() {
  [ ! -e "$1" ] || fail "$2"
}

# assert_present <path> <msg>: path must exist.
assert_present() {
  [ -e "$1" ] || fail "$2"
}

# fm_test_base_path_sans <base_path> <tool...>: returns the path to a single
# curated directory that resolves every tool <base_path> would have resolved,
# except the named ones. Some hosts have real system binaries (node, orca,
# ...) sitting in BASE_PATH; a fixture that simulates a tool as missing by
# omitting it from fakebin still falls through to that host binary via
# BASE_PATH, silently defeating the simulation. Dropping whole directories
# out of BASE_PATH is not a safe fix: on a usr-merged host /bin, /sbin, and
# /usr/sbin are symlinks that collapse to the same directory as /usr/bin, so
# dropping any one of them because it resolves the excluded tool drops every
# other tool a test still needs (git, awk, sed, ...) too. Building a curated
# directory instead hides only the named tool(s). Use only at the specific
# assertions that simulate a tool as absent - every other case keeps using
# bare BASE_PATH.
fm_test_base_path_sans() {
  local base_path=$1 dir src entry name tool skip
  shift
  local tools=("$@")
  dir=$(fm_test_tmproot fm-base-path-sans) || return 1
  local dirs
  IFS=: read -ra dirs <<< "$base_path"
  for src in "${dirs[@]}"; do
    [ -d "$src" ] || continue
    for entry in "$src"/*; do
      [ -e "$entry" ] || [ -L "$entry" ] || continue
      name=${entry##*/}
      [ -e "$dir/$name" ] && continue
      skip=0
      for tool in "${tools[@]}"; do
        if [ "$name" = "$tool" ]; then
          skip=1
          break
        fi
      done
      [ "$skip" -eq 1 ] && continue
      ln -s "$entry" "$dir/$name" 2>/dev/null || true
    done
  done
  printf '%s\n' "$dir"
}
