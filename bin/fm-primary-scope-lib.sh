#!/usr/bin/env bash
# Shared scope predicates for tracked hooks: the marker-or-plain-checkout test
# for a genuine firstmate primary home, and the session-lock ancestry test for
# whether this hook's own harness session already acquired that home's lock.
# This file is sourced by hook entrypoints and has no side effects on source.

# Harness identity - the command-name vocabulary, the ancestry walk, holder
# liveness, and the per-process match - is owned by bin/fm-session-lock-lib.sh.
# This file layers the fork's PRIMARY-SCOPE predicates on top of that owner: the
# marker-or-plain-checkout test for a genuine firstmate primary home, the
# session-lock ancestry relation, and the Cursor argument evidence the primary
# handoff reads. Sourcing the owner here keeps one definition of each shared
# function, so a hook that sources both files cannot get a different answer
# depending on source order.
# shellcheck source=bin/fm-session-lock-lib.sh
. "${BASH_SOURCE%/*}/fm-session-lock-lib.sh"


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

# Return 0 when this process runs in a ship or scout worker pane.
# bin/fm-spawn.sh exports FM_TASK_ID into exactly those panes and never into a
# secondmate or primary, so the marker holds even when a worker's directory
# does not look like a linked task worktree.
fm_is_task_worker() {
  [ -n "${FM_TASK_ID:-}" ]
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
