#!/usr/bin/env bash
# Shared scope predicates for tracked hooks: the marker-or-plain-checkout test
# for a genuine firstmate primary home, and the session-lock ancestry test for
# whether this hook's own harness session already acquired that home's lock.
# This file is sourced by hook entrypoints and has no side effects on source.

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$'

# The same harnesses as exact names. Keep in sync with FM_HARNESS_RE. Used only
# for the stricter path evidence below, where the loose regex would also match
# ordinary firstmate paths such as bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi)

# Print the exact harness name carried by executable path $1 - its own basename
# or any directory component - or return 1.
#
# This exists because Claude Code's native installer names the per-session
# executable by its version (~/.local/share/claude/versions/2.1.220), so the
# basename identifies nothing while the install path still says claude. Matching
# whole path components only is what keeps that widening safe: an ordinary path
# such as a firstmate hook script under ~/.claude/hooks has no "claude" path
# component and is correctly not a harness process.
fm_harness_path_name() {  # <path>
  local path=$1 name
  [ -n "$path" ] || return 1
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "/$path/" in
      */"$name"/*) printf '%s' "$name"; return 0 ;;
    esac
  done
  return 1
}

# True when the process described by command name $1 and full argument string $2
# is a verified harness. Sets FM_HARNESS_IS_CLAUDE for the ancestry walk.
#
# Evidence, in order:
#   1. the basename of the reported command name, against FM_HARNESS_RE.
#   2. an exact harness component in that command path or in argv[0]. Both are
#      needed because the two platforms report different things: macOS reports
#      argv[0] in `ps -o comm=`, while procps on Linux reports the kernel exec
#      name and ignores argv[0] entirely, so a version-named Claude Code binary
#      is identified by its install path on macOS and by argv[0] on Linux.
#   3. a bare interpreter (node, python) running a harness script path.
FM_HARNESS_IS_CLAUDE=0
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name
  FM_HARNESS_IS_CLAUDE=0
  base=$(basename -- "$comm")
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
    case "$base" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  argv0=${args%% *}
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
        case "$args" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
        return 0
      fi
      ;;
  esac
  return 1
}

# Fork-preserving loose liveness evidence: before path-component identity
# existed, holder liveness accepted any harness word anywhere in the command
# line. Keep that leniency but only for whole argv tokens at a name boundary,
# so a real profile launcher named codex-primary still reads as a live holder
# while an ordinary script merely living under ~/.claude/hooks does not.
fm_harness_loose_args_match() {  # <args>
  local name
  for name in "${FM_HARNESS_NAMES[@]}"; do
    if printf '%s' "$1" | grep -Eq "(^|[[:space:]/])$name([^[:alnum:]]|$)"; then
      return 0
    fi
  done
  return 1
}

fm_harness_holder_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  if fm_harness_process_matches "$comm" "$args"; then
    return 0
  fi
  # Ownership walks never use the loose tier; only the live-holder predicate
  # does.
  fm_harness_loose_args_match "$args"
}

# Walk this process's ancestry (at most eight parents, matching bin/fm-lock.sh
# and Pi's lockOwnership()) and print this session's contiguous verified-harness
# ancestry, innermost pid first, or return 1 when no ancestor is a harness.
#
# The walk climbs freely until the first harness match, because the caller is
# normally an ordinary shell several levels below its session. After that first
# match it stops at the first non-harness ancestor, so it can never cross a gap
# into an unrelated harness further up the real process tree - for example the
# live session that launched a test as its own subprocess.
#
# For every harness except Claude the innermost match is the session, which is
# where e.g. Pi's shared signed-wrapper ancestry actually holds the lock. Claude
# Code instead runs hooks several levels below the session inside its own nested
# worker chain with no non-harness process between them, so which pid in that
# run is the session cannot be read off the ancestry at all: the whole
# contiguous run is reported and the callers decide what they need from it.
fm_harness_ancestry_pids() {
  local pid=$$ comm args extending=0 printed=0
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if fm_harness_process_matches "$comm" "$args"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  [ "$printed" -eq 1 ]
}

# True when $1 is one of this session's own contiguous harness ancestors.
fm_harness_ancestry_contains() {  # <pid>
  local wanted=$1 pid pids
  [ -n "$wanted" ] || return 1
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$wanted" ] && return 0
  done <<EOF
$pids
EOF
  return 1
}

# Print the one pid that identifies this session when the session lock is being
# WRITTEN: the outermost pid of the contiguous run. That is the pid that lives
# as long as the session - a Claude worker several levels in is reaped when its
# hook returns, and a lock naming it would look stale moments later while the
# session is still running. Every non-Claude harness reports a single pid, so
# this is its innermost match unchanged.
fm_harness_ancestry_pid() {
  local pids pid outermost=''
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$pids
EOF
  [ -n "$outermost" ] || return 1
  printf '%s\n' "$outermost"
}

# Return 0 when $1 carries a genuine secondmate-home marker.
fm_root_is_secondmate_home() {
  local marker="$1/.fm-secondmate-home" id LC_ALL=C
  [ -L "$marker" ] && return 1
  [ -f "$marker" ] || return 1
  IFS= read -r id < "$marker" 2>/dev/null || return 1
  id=${id//[[:space:]]/}
  [ -n "$id" ] || return 1
  case "$id" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Return 0 when $1 is a genuine primary root whose effective state dir is $2.
# A valid secondmate marker force-includes a linked secondmate home.
# Otherwise only a plain checkout is primary, never a linked task worktree.
fm_primary_scope_matches() {
  local root=$1 state=$2 git_dir git_common_dir
  if ! fm_root_is_secondmate_home "$root"; then
    git_dir=$(git -C "$root" rev-parse --git-dir 2>/dev/null) || return 1
    git_common_dir=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
    [ "$git_dir" = "$git_common_dir" ] || return 1
  fi
  [ -f "$root/AGENTS.md" ] || return 1
  [ -d "$root/bin" ] || return 1
  [ -d "$state" ] || return 1
}

# Print this process's relation to the session lock in state dir $1:
#   free      no live harness holder is recorded - the lock file is missing,
#             unreadable, non-numeric, pid 1, or its holder is dead or not a
#             harness - so a session-start run here would be the genuine first
#             acquisition.
#   ancestry  the recorded holder is this very process, or a live harness
#             holder sits inside this process's own contiguous harness
#             ancestry - this harness session already acquired the lock and
#             bin/fm-session-start.sh has already run here.
#   foreign   a live harness holder exists outside this process's ancestry -
#             another session owns the home.
# One owner for that decision: the session-start nudge and the continuity
# PreToolUse gate both consume it rather than re-deriving lock ownership.
# Harness identity is read from executable-path components and argv[0] as well
# as command basenames, so a version-named per-session executable (identified
# by neither basename alone) is still recognized as a live holder instead of
# being misread as a stale one. Ownership beyond the exact self-pid is
# membership in the whole contiguous harness ancestry rather than one chosen
# pid, because the holder sits at an unknown depth inside a Claude session's
# nested worker chain.
fm_session_lock_relation() {
  local state=$1 lock_pid
  [ -f "$state/.lock" ] || { echo free; return 0; }
  IFS= read -r lock_pid < "$state/.lock" 2>/dev/null || { echo free; return 0; }
  case "$lock_pid" in
    ''|*[!0-9]*|1) echo free; return 0 ;;
  esac
  kill -0 "$lock_pid" 2>/dev/null || { echo free; return 0; }
  [ "$lock_pid" = "$$" ] && { echo ancestry; return 0; }
  if ! fm_harness_holder_alive "$lock_pid"; then
    echo free
    return 0
  fi
  if fm_harness_ancestry_contains "$lock_pid"; then
    echo ancestry
  else
    echo foreign
  fi
}

# Return 0 only when fm_session_lock_relation resolves "ancestry" for state dir
# $1: this harness session provably already holds the home session lock.
fm_session_lock_in_ancestry() {
  [ "$(fm_session_lock_relation "$1")" = ancestry ]
}
