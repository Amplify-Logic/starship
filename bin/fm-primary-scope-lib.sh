#!/usr/bin/env bash
# Shared scope predicates for tracked hooks: the marker-or-plain-checkout test
# for a genuine firstmate primary home, and the session-lock ancestry test for
# whether this hook's own harness session already acquired that home's lock.
# This file is sourced by hook entrypoints and has no side effects on source.

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

# Return 0 when the session lock in state dir $1 records a live PID inside this
# process's own ancestry, which means this harness session already acquired it
# and bin/fm-session-start.sh has already run here.
# One owner for that decision: the session-start nudge uses it to stay silent,
# and the continuity PreToolUse gate uses it to scope its recovery guidance.
# Walks at most eight parents, matching bin/fm-lock.sh and Pi's lockOwnership().
# Any uncertainty - no lock, an unreadable or non-numeric holder, a dead holder,
# an unreadable parent - returns non-zero, so a caller never treats an unproven
# lock as owned by this session.
fm_session_lock_in_ancestry() {
  local state=$1 lock_pid pid=$$ _
  [ -f "$state/.lock" ] || return 1
  IFS= read -r lock_pid < "$state/.lock" 2>/dev/null || return 1
  case "$lock_pid" in
    ''|*[!0-9]*|1) return 1 ;;
  esac
  kill -0 "$lock_pid" 2>/dev/null || return 1
  for _ in 1 2 3 4 5 6 7 8; do
    [ "$pid" = "$lock_pid" ] && return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}
