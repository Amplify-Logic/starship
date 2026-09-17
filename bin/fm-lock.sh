#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
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
#   1  another live firstmate session holds the lock, or the lock could not be
#      written or verified
#   3  this session's own harness process was not found in its own ancestry, so
#      the session cannot identify itself and says nothing about any other one
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
mkdir -p "$STATE" 2>/dev/null || {
  echo "error: cannot create session-lock state directory $STATE; operate read-only until resolved" >&2
  exit 1
}

# Harness identity (FM_HARNESS_RE, ancestry walk, holder liveness) is owned by
# the shared session-lock lib so the Claude Stop auto-arm applies the exact
# same identity contract.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# The fork's primary-scope predicates layer on that owner and add the ancestry
# RELATION used below to recognize this session's own earlier acquisition.
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

# release-stale belongs to the fork's primary handoff, and this dispatch FAILS
# CLOSED on purpose: with the fork file missing it refuses the release rather
# than falling through, because the alternative is removing a lock a live
# primary may still hold and putting two primaries on one home. That is the
# declared exception to degrading to upstream behaviour, and it is stated here
# at the call site rather than only in the fork file.
if [ "${1:-}" = "release-stale" ]; then
  [ -x "$SCRIPT_DIR/fm-primary-handoff-lib.sh" ] || {
    echo "error: release-stale needs bin/fm-primary-handoff-lib.sh" >&2
    exit 1
  }
  exec "$SCRIPT_DIR/fm-primary-handoff-lib.sh" release-stale "$LOCK"
fi

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "lock: unreadable"
    exit 0
  }
  if fm_harness_holder_alive "$old"; then echo "lock: held by live harness pid $old"; else echo "lock: stale (pid $old dead or not a harness)"; fi
  exit 0
fi

me=$(fm_harness_ancestry_pid) || {
  echo "error: cannot identify this session's own harness process in its ancestry; no claim is made about any other session" >&2
  exit 3
}
probe=$(mktemp "$STATE/.lock-write.XXXXXX" 2>/dev/null) || {
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
}
rm -f "$probe" 2>/dev/null || {
  echo "error: cannot clean session-lock publication probe; operate read-only until resolved" >&2
  exit 1
}
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
CLAIM_LOCK="$STATE/.lock.acquire"
CLAIM_LOCK_HELD=0
release_claim_lock() {
  if [ "$CLAIM_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=0
  fi
}
trap release_claim_lock EXIT
trap 'exit 1' HUP INT TERM

if [ -f "$LOCK" ] && [ ! -L "$LOCK" ]; then
  old=$(cat "$LOCK" 2>/dev/null || true)
  if [ "$old" = "$me" ]; then
    echo "lock acquired: harness pid $me"
    exit 0
  fi
  if fm_harness_holder_alive "$old"; then
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

if ! fm_lock_try_acquire "$CLAIM_LOCK"; then
  sweep_pid=$(sed -n 's/^pid=//p' "$STATE/.startup-network.status" 2>/dev/null | tail -1)
  if [ -n "${FM_LOCK_HELD_PID:-}" ] && [ "$FM_LOCK_HELD_PID" = "$sweep_pid" ]; then
    echo "error: the prior session's bounded startup sweep is finishing; operate read-only until it releases the fleet lock" >&2
    exit 1
  fi
  fm_lock_acquire_wait "$CLAIM_LOCK"
fi
CLAIM_LOCK_HELD=1

if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
  if [ ! -f "$LOCK" ] || [ -L "$LOCK" ]; then
    echo "error: session lock is not a regular file; operate read-only until resolved" >&2
    exit 1
  fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "error: session lock is unreadable; operate read-only until resolved" >&2
    exit 1
  }
  if [ "$old" != "$me" ] && fm_harness_holder_alive "$old"; then
    if fm_harness_ancestry_contains "$old"; then
      release_claim_lock
      echo "lock acquired: harness pid $old"
      exit 0
    fi
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi
if ! { printf '%s\n' "$me" > "$LOCK"; } 2>/dev/null; then
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
fi
written=$(cat "$LOCK" 2>/dev/null) || {
  echo "error: cannot verify session lock ownership; operate read-only until resolved" >&2
  exit 1
}
if [ ! -f "$LOCK" ] || [ -L "$LOCK" ] || [ "$written" != "$me" ]; then
  echo "error: session lock ownership verification failed; operate read-only until resolved" >&2
  exit 1
fi
release_claim_lock
echo "lock acquired: harness pid $me"
