#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
# The written PID is the OUTERMOST pid of this session's contiguous harness
# ancestry: a Claude hook several levels down its nested worker chain is reaped
# moments after it returns, so only the topmost pid of the run reliably lives as
# long as the session. Harness identity is read from executable-path components
# and argv[0] as well as command basenames, because version-named per-session
# install layouts identify nothing by basename alone (see
# bin/fm-primary-scope-lib.sh, the single owner of that evidence).
# A live lock held by a pid inside THIS session's own ancestry is recognized as
# this session's own earlier acquisition and kept, never refused or rewritten.
# Usage: fm-lock.sh              acquire; see the acquire exit codes below
#        fm-lock.sh status       print holder and liveness; always exits 0
#        fm-lock.sh release-stale
#          Remove state/.lock only when the recorded holder is dead or not a
#          harness. Refuse while a live harness still holds it. Used by
#          bin/fm-primary-handoff.sh after the outgoing primary has exited.
#
# Acquire exit codes, the single owner of what each refusal means. Every refusal
# withholds the lock identically; only the diagnosis differs, and
# bin/fm-session-start.sh renders each one under its own truthful headline
# instead of blaming a competing session for every refusal:
#   0  acquired, or this session's own earlier acquisition recognized
#   1  another live firstmate session holds the lock
#   3  this session's own harness process was not found in its own ancestry, so
#      the session cannot identify itself and says nothing about any other one
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
mkdir -p "$STATE"
# shellcheck source=bin/fm-primary-scope-lib.sh
source "$SCRIPT_DIR/fm-primary-scope-lib.sh"

harness_pid() {
  fm_harness_ancestry_pid
}

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK")
  if fm_harness_holder_alive "$old"; then echo "lock: held by live harness pid $old"; else echo "lock: stale (pid $old dead or not a harness)"; fi
  exit 0
fi

if [ "${1:-}" = "release-stale" ]; then
  if [ ! -f "$LOCK" ]; then
    echo "lock: free"
    exit 0
  fi
  old=$(cat "$LOCK")
  if fm_harness_holder_alive "$old"; then
    echo "error: refusing to release a live firstmate session lock (pid $old)" >&2
    exit 1
  fi
  current=$(cat "$LOCK" 2>/dev/null || true)
  if [ "$current" != "$old" ]; then
    echo "error: lock holder changed to pid ${current:-none} during release-stale; refusing" >&2
    exit 1
  fi
  rm -f "$LOCK"
  echo "lock released: stale holder pid $old"
  exit 0
fi

me=$(harness_pid) || {
  echo "error: cannot identify this session's own harness process in its ancestry; no claim is made about any other session" >&2
  exit 3
}
if [ -f "$LOCK" ]; then
  old=$(cat "$LOCK")
  if [ "$old" != "$me" ] && fm_harness_holder_alive "$old"; then
    if fm_harness_ancestry_contains "$old"; then
      # This session's own earlier acquisition, recorded from a different depth
      # of the same harness run: recognize it as ours and keep its record.
      echo "lock acquired: harness pid $old"
      exit 0
    fi
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi
echo "$me" > "$LOCK"
echo "lock acquired: harness pid $me"
