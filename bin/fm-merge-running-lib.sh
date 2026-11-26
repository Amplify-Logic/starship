#!/usr/bin/env bash
# fm-merge-running-lib.sh - a per-home mark that a merge is under way.
#
# bin/fm-pr-merge.sh and bin/fm-merge-local.sh hold one mark each for as long
# as they run, from just before their per-task control lock until they exit.
# A fresh first-mate session (bin/fm-primary-handoff.sh fresh) refuses while
# any mark is held, because stopping the session that started a merge part way
# through can strand the forge call or the local landing it is waiting on.
#
# A mark is a portable lock directory from bin/fm-wake-lib.sh, named
# state/.merge-running.<pid>.lock, so two merges at once hold two marks and a
# mark whose process died reads as not held (fm_lock_holder_alive), even
# before anything removes it.
#
# Callers source bin/fm-wake-lib.sh first; this file adds:
#   fm_merge_running_begin <state-dir>   take this process's mark (best effort:
#                                        a mark that cannot be written never
#                                        stops the merge)
#   fm_merge_running_end                 release it; idempotent
#   fm_merge_running_any <state-dir>     0 while any live merge holds a mark
#
# shellcheck shell=bash

FM_MERGE_RUNNING_MARK=

fm_merge_running_begin() {  # <state-dir>
  local state=$1 current
  fm_current_pid current || return 0
  FM_MERGE_RUNNING_MARK="$state/.merge-running.$current.lock"
  fm_lock_try_acquire "$FM_MERGE_RUNNING_MARK" || FM_MERGE_RUNNING_MARK=
  return 0
}

fm_merge_running_end() {
  [ -n "$FM_MERGE_RUNNING_MARK" ] || return 0
  fm_lock_release "$FM_MERGE_RUNNING_MARK" || true
  FM_MERGE_RUNNING_MARK=
}

fm_merge_running_any() {  # <state-dir>
  local state=$1 mark pid
  for mark in "$state"/.merge-running.*.lock; do
    [ -d "$mark" ] || continue
    pid=$(cat "$mark/pid" 2>/dev/null || true)
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    fm_lock_holder_alive "$mark" "$pid" && return 0
  done
  return 1
}
