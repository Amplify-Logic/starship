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
# string/exit-code/file assertions. It deliberately does NOT bundle the
# behavior-specific fake tmux/treehouse/no-mistakes mocks: those encode terminal
# and lifecycle assumptions that differ per suite and belong with the tests that
# own them.
#
# ROOT is exported as the firstmate repo root (this file lives in tests/), so a
# sourcing test can use "$ROOT/bin/..." without recomputing it.

# Idempotent guard: behavior-area helper files (secondmate-helpers.sh,
# wake-helpers.sh) source this library for ROOT/fail/pass, and the test that
# includes them may also source it directly. Re-sourcing must not wipe the
# registered-cleanup array or reset state.
if [ -n "${FM_TEST_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_LIB_SOURCED=1

# Exempt firstmate's own test suite from the gate-lifecycle refusal
# (bin/fm-gate-refuse-lib.sh). The no-mistakes gate runs this suite FROM a gate
# worktree - the exact environment that guard refuses - so without this every
# test that drives the real fm-spawn/fm-send/fm-teardown would be refused during
# firstmate's own validation. A confused gate agent never sources this helper, so
# the boundary against the real hazard is unaffected. tests/fm-gate-refuse.test.sh
# strips this to verify real refusal.
export FM_GATE_REFUSE_BYPASS=1

# Never let a behavior fixture register a real per-home launchd sentinel.
# The sentinel's own suite overrides this and uses a fake launchctl transport.
export FM_SUPERVISION_SENTINEL_MODE=off

# Supervision tests are hermetic by construction: no spawned watcher, arm,
# daemon, or lock script may ever resolve a REAL firstmate home, even when the
# invoking environment is itself a live firstmate lane that exports FM_HOME.
# Every production entry point prefers an inherited FM_HOME over its
# script-relative root, so one leaked value would silently rebind a fixture
# watcher onto the primary home's state - stealing its watch lock, touching its
# beat, and letting a fixture --restart TERM the real fleet watcher. Drop every
# inherited operational-home variable at source time; suites that need one set
# it explicitly AFTER sourcing this library, which is how every current suite
# already works. The regression owner for this guarantee is
# tests/fm-supervision-test-isolation.test.sh.
FM_TEST_OPERATIONAL_ENV="FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK"
for _fm_test_var in $FM_TEST_OPERATIONAL_ENV; do
  unset "$_fm_test_var" || true
done
unset _fm_test_var

# Drop the agent-up wait's inter-poll pacing for the suite. fm-spawn waits for a
# real agent to own the endpoint after launch, and a fake tmux or herdr reports a
# liveness answer the shared owner cannot attribute, so every fixture spawn pays
# the production pacing before proceeding - measured at ~21s on one spawn-heavy
# file alone, which is what pushed the former unsharded portable-serial CI lane
# past its 20m hang tripwire. Production pacing is unaffected: this is the
# suite's own knob, set
# once here rather than in each of the ~38 files that drive a real spawn, exactly
# as the two exports above are. A test that needs a specific bound (the agent-up
# suite itself) still sets FM_SPAWN_AGENT_UP_SLEEP / _MAX_POLLS explicitly.
export FM_SPAWN_AGENT_UP_SLEEP=0

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
# on EXIT. The first call installs the cleanup trap. A test file that needs
# extra teardown (e.g. killing a daemon) should define its own EXIT trap and
# call fm_test_cleanup from inside it so registered dirs are still removed.

FM_TEST_CLEANUP_DIRS=()

# Hermetic operational home for EVERY suite. Combined with the inherited-env
# unset above, a spawned watcher, arm, daemon, or lock script that omits
# FM_STATE_OVERRIDE still resolves every FM_HOME-derived path into this suite's
# own temp tree - never into a real firstmate home. A suite that needs a
# different fixture home sets FM_HOME itself AFTER sourcing this library.
# tests/fm-supervision-test-isolation.test.sh owns the regression coverage.
FM_TEST_HERMETIC_HOME=$(mktemp -d "${TMPDIR:-/tmp}/fm-hermetic-home.XXXXXX")
mkdir -p "$FM_TEST_HERMETIC_HOME/state"
if [ "${#FM_TEST_CLEANUP_DIRS[@]}" -eq 0 ]; then
  trap fm_test_cleanup EXIT
fi
FM_TEST_CLEANUP_DIRS+=("$FM_TEST_HERMETIC_HOME")
FM_TEST_CLEANUP_REGISTRY="$FM_TEST_HERMETIC_HOME/cleanup-dirs"
: > "$FM_TEST_CLEANUP_REGISTRY"
export FM_HOME="$FM_TEST_HERMETIC_HOME"

# Watchers, arms, and daemons spawned by a suite are tracked here and reaped by
# the EXIT cleanup, so an ordinary suite exit can never leak a supervision
# process that outlives its fixture. Tracking is cheap and idempotent; a pid
# that already exited is skipped.
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
fm_test_pid_command_line() {  # <pid>
  local pid=$1 cmd
  [ -n "$pid" ] || return 1
  if [ -r "/proc/$pid/cmdline" ]; then
    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline")
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
    done < "/proc/$pid/cmdline"
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
      cmd=$(tr '\0' ' ' < "$proc/cmdline")
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
  local pid i alive
  for pid in "${FM_TEST_CHILD_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    fm_test_kill_scoped -TERM "$pid"
  done
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    fm_test_kill_scoped -TERM "$pid"
  done <<EOF
$(fm_test_descendant_pids "${BASHPID:-$$}")
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
$(fm_test_descendant_pids "${BASHPID:-$$}")
EOF
  fm_test_kill_cleanup_dir_exes -KILL
  return 0
}

fm_test_cleanup() {
  local d
  fm_test_reap_children
  while IFS= read -r d; do
    [ -n "$d" ] && rm -rf "$d"
  done < "$FM_TEST_CLEANUP_REGISTRY"
  for d in "${FM_TEST_CLEANUP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}

fm_test_tmproot() {
  local prefix=${1:-fm-test} root
  root=$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX")
  if [ "${#FM_TEST_CLEANUP_DIRS[@]}" -eq 0 ]; then
    trap fm_test_cleanup EXIT
  fi
  FM_TEST_CLEANUP_DIRS+=("$root")
  printf '%s\n' "$root" >> "$FM_TEST_CLEANUP_REGISTRY"
  # shellcheck disable=SC2034 # Read by the caller after the registration.
  FM_TEST_LAST_TMPROOT=$root
  printf '%s\n' "$root"
}

# --- fakebin / PATH shims ---------------------------------------------------
#
# fm_fakebin <dir> creates <dir>/fakebin and echoes it; prepend it to PATH to
# shadow real tools with stubs. fm_fake_exit0 drops trivial exit-0 stubs for the
# named tools into a fakebin dir.

fm_fakebin() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  printf '%s\n' "$fakebin"
}

# fm_install_compatible_tasks_axi <fakebin-dir>: drop a PATH stub that satisfies
# bin/fm-tasks-axi-lib.sh's fm_tasks_axi_compatible probe AND
# bin/fm-decision-hold.sh's require_tasks_axi (hold --help exposes --kind captain).
# Scout teardown success fixtures need this when the host PATH is sanitized
# (e.g. no-mistakes gate worktrees without nvm), otherwise decision-hold refuses
# with "compatible tasks-axi is required" before the adapter-under-test runs.
fm_install_compatible_tasks_axi() {
  local fb=$1
  mkdir -p "$fb"
  cat > "$fb/tasks-axi" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  --version)
    printf '%s\n' '0.2.3'
    exit 0
    ;;
  update)
    if [ "${2:-}" = --help ]; then
      printf '%s\n' 'usage: tasks-axi update <id> [flags]'
      printf '%s\n' '  --body-file <path>'
      printf '%s\n' '  --archive-body'
      exit 0
    fi
    ;;
  mv)
    if [ "${2:-}" = --help ]; then
      printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>'
      exit 0
    fi
    ;;
  hold)
    if [ "${2:-}" = --help ]; then
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

# --- deterministic git identity and fixtures --------------------------------

# fm_git_identity [name] [email]: export a fixed author/committer identity so
# fixture commits never depend on the host git config.
fm_git_identity() {
  export GIT_AUTHOR_NAME=${1:-fmtest} GIT_AUTHOR_EMAIL=${2:-fmtest@example.invalid}
  export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
}

# fm_git_init_commit <dir>: create a git repo at <dir> with a README and one
# commit. Uses an inline identity so it works whether or not fm_git_identity was
# called.
fm_git_init_commit() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
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

# fm_git_worktree <repo> <worktree> <branch>: init <repo> with one commit, then
# add a worktree on a fresh branch.
fm_git_worktree() {
  local repo=$1 worktree=$2 branch=$3
  fm_git_init_commit "$repo"
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

# fm_write_secondmate_meta <file> <home> [window] [projects]: write the standard
# kind=secondmate meta block used across the secondmate suites. window defaults
# to firstmate:fm-<basename-of-home-dir's parent id>? No - window is explicit;
# defaults to firstmate:fm-domain and projects to alpha to match the common case.
fm_write_secondmate_meta() {
  local file=$1 home=$2 window=${3:-firstmate:fm-domain} projects=${4:-alpha}
  fm_write_meta "$file" \
    "window=$window" \
    "worktree=$home" \
    "project=$home" \
    "harness=echo" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "home=$home" \
    "projects=$projects"
}

# --- common assertions ------------------------------------------------------

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
