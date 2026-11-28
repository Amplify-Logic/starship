#!/usr/bin/env bash
# Shared scope predicates for tracked hooks: the marker-or-plain-checkout test
# for a genuine firstmate primary home, and the session-lock ancestry test for
# whether this hook's own harness session already acquired that home's lock.
# This file is sourced by hook entrypoints and has no side effects on source.
# fm_primary_root_matches is split out so a caller can confirm primary-home
# identity before its gitignored state dir exists, such as to create it.

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

# Return 0 when a first mate session that resolved home $1 with state dir $2
# would attach to the home that supervises this task worker. A worker pane
# carries that home's FM_HOME, so a first mate started from it (a trial, say)
# silently inherits it unless the launch names another home. The supervising
# home is read from the FM_TASK_INBOX path bin/fm-spawn.sh exports into every
# worker launch (<state>/<task-id>.inbox), so the answer does not depend on
# FM_HOME itself and an explicit FM_HOME naming a different home passes. A
# worker marker without that path cannot prove the home is a different one, so
# it counts as attaching. bin/fm-session-start.sh and bin/fm-primary.sh refuse
# on this answer before reading or writing anything in the home.
fm_primary_attaches_worker_home() {  # <home> <state>
  local sup_state sup_home home state
  fm_is_task_worker || return 1
  [ -n "${FM_TASK_INBOX:-}" ] || return 0
  sup_state=$(cd -P "${FM_TASK_INBOX%/*}" 2>/dev/null && pwd -P) || sup_state=${FM_TASK_INBOX%/*}
  sup_home=$(cd -P "$sup_state/.." 2>/dev/null && pwd -P) || sup_home=${sup_state%/*}
  home=$(cd -P "$1" 2>/dev/null && pwd -P) || home=$1
  state=$(cd -P "$2" 2>/dev/null && pwd -P) || state=$2
  [ "$state" = "$sup_state" ] || [ "$home" = "$sup_home" ]
}

# Print the refusal for fm_primary_attaches_worker_home on stderr, prefixed by
# the calling script's name $1, for home $2.
fm_primary_worker_home_refusal() {  # <script-name> <home>
  printf '%s: refusing to start a first mate session on %s: it is the home supervising task worker %s, inherited through this shell'"'"'s worker environment.\n' \
    "$1" "$2" "${FM_TASK_ID:-}" >&2
  printf '%s: to try a first mate from a worker, give it its own home and a clean environment: env -u FM_TASK_ID -u FM_TASK_INBOX FM_HOME=<trial home> <command>\n' "$1" >&2
}

# Unset the worker-only variables a first mate launched from a worker shell must
# not carry: with them the new session counts as a worker, so its own startup
# and hooks stand down. bin/fm-primary.sh calls this before it starts the CLI.
fm_clear_task_worker_env() {
  unset FM_TASK_ID FM_TASK_INBOX
}

# Return 0 when $1 is a genuine primary root, regardless of whether its state
# dir exists yet. A valid secondmate marker force-includes a linked secondmate
# home. Otherwise only a plain checkout is primary, never a linked task
# worktree.
fm_primary_root_matches() {
  local root=$1 dirs git_dir git_common_dir
  if ! fm_root_is_secondmate_home "$root"; then
    # One git process prints both answers, one per line.
    dirs=$(git -C "$root" rev-parse --git-dir --git-common-dir 2>/dev/null) || return 1
    case "$dirs" in
      *$'\n'*) ;;
      *) return 1 ;;
    esac
    git_dir=${dirs%%$'\n'*}
    git_common_dir=${dirs#*$'\n'}
    [ "$git_dir" = "$git_common_dir" ] || return 1
  fi
  [ -f "$root/AGENTS.md" ] || return 1
  [ -d "$root/bin" ] || return 1
}

# Return 0 when $1 is a genuine primary root whose effective state dir $2
# already exists.
fm_primary_scope_matches() {
  local root=$1 state=$2
  fm_primary_root_matches "$root" && [ -d "$state" ]
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
