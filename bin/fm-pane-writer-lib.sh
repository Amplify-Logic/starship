#!/usr/bin/env bash
# fm-pane-writer-lib.sh - the one owner of a home's pane-writer lock.
#
# A home's primary pane (a main home's first mate, or a second mate in its own
# home) has several typists:
#   - bin/fm-desk-voice.sh send and ring in that home: the desk floater, the
#     web page, captain inbox rings, and the direct line
#     (bin/fm-direct-line.sh), which all type through desk-voice;
#   - the parent home's steering-inbox doorbell, bin/fm-task-inbox-lib.sh
#     fm_task_inbox_ring, which fm-send, the watcher's re-ring ladder, and the
#     watcher's drain nudge use to reach a local second mate's pane.
# Two of them typing at once interleave into one garbled prompt, so every one
# of them holds this lock across the whole check, type, and Enter span. No
# typist waits for it: on contention desk-voice send uses its mailbox, ring
# leaves its queued wake, and a doorbell is deferred to the next re-ring.
# The owner typing at the keyboard cannot take a lock; the composer checks each
# typist already makes cover that case.
#
# The lock is a directory lock (bin/fm-wake-lib.sh fm_lock_try_acquire), so a
# holder that dies is reaped by the next acquirer. Its path is the one
# desk-voice has always used, so a desk-voice from before this library and one
# from after it still exclude each other.
#
# Requires bin/fm-wake-lib.sh to be sourced first. No side effects on source.

# The lock path for the home whose state directory is <state-dir>.
fm_pane_writer_lock_path() {  # <state-dir>
  printf '%s/desk-voice/.send.lock\n' "$1"
}

# Take <state-dir>'s pane-writer lock without waiting.
# Returns 0 held, 1 another live writer holds it, 2 it cannot be created.
fm_pane_writer_try_acquire() {  # <state-dir>
  local dir="$1/desk-voice"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir" 2>/dev/null || return 2
    chmod 700 "$dir" 2>/dev/null || true
  fi
  fm_lock_try_acquire "$(fm_pane_writer_lock_path "$1")" || return 1
}

# Release a hold this process took with fm_pane_writer_try_acquire.
fm_pane_writer_release() {  # <state-dir>
  fm_lock_release "$(fm_pane_writer_lock_path "$1")"
}
