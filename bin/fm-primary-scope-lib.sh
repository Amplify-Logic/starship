#!/usr/bin/env bash
# Shared scope predicates for tracked hooks: the marker-or-plain-checkout test
# for a genuine firstmate primary home, and the session-lock ancestry test for
# whether this hook's own harness session already acquired that home's lock.
# This file is sourced by hook entrypoints and has no side effects on source.

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$'

fm_harness_holder_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  printf '%s' "$(basename -- "$comm") $args" | grep -qE "$FM_HARNESS_RE"
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
#   free      no live holder is recorded - the lock file is missing, unreadable,
#             non-numeric, pid 1, or its holder is dead or not a harness - so a
#             session-start run here would be the genuine first acquisition.
#   ancestry  a live holder sits inside this process's own ancestry, which means
#             this harness session already acquired the lock and
#             bin/fm-session-start.sh has already run here.
#   foreign   a live holder exists outside this process's ancestry, or the
#             ancestry walk could not prove ownership - another session owns the
#             home, and any uncertainty lands here so an unproven lock is never
#             treated as this session's own.
# One owner for that decision: the session-start nudge and the continuity
# PreToolUse gate both consume it rather than re-deriving lock ownership.
# Walks at most eight parents, matching bin/fm-lock.sh and Pi's lockOwnership().
fm_session_lock_relation() {
  local state=$1 lock_pid pid=$$ _
  [ -f "$state/.lock" ] || { echo free; return 0; }
  IFS= read -r lock_pid < "$state/.lock" 2>/dev/null || { echo free; return 0; }
  case "$lock_pid" in
    ''|*[!0-9]*|1) echo free; return 0 ;;
  esac
  kill -0 "$lock_pid" 2>/dev/null || { echo free; return 0; }
  for _ in 1 2 3 4 5 6 7 8; do
    [ "$pid" = "$lock_pid" ] && { echo ancestry; return 0; }
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  if fm_harness_holder_alive "$lock_pid"; then
    echo foreign
  else
    echo free
  fi
}

# Return 0 only when fm_session_lock_relation resolves "ancestry" for state dir
# $1: this harness session provably already holds the home session lock.
fm_session_lock_in_ancestry() {
  [ "$(fm_session_lock_relation "$1")" = ancestry ]
}
