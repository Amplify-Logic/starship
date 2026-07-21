#!/usr/bin/env bash
# Quota-aware automated primary orchestrator handoff.
#
# Usage:
#   fm-primary-handoff.sh status
#   fm-primary-handoff.sh check
#   fm-primary-handoff.sh execute [--from PROFILE] [--to PROFILE] [--reason TEXT]
#   fm-primary-handoff.sh run
#   fm-primary-handoff.sh --help
#
# Opt-in via local gitignored config/primary-handoff (JSON).
# Absent or enabled:false is a no-op and does not change primary launch behavior.
# docs/primary-handoff.md owns the atomic-lock protocol and failure modes.
# This header owns commands, flags, state paths, and test seams.
#
# Commands:
#   status   Print config, active profile, session lock, and handoff record.
#   check    One evaluation: if enabled and over threshold, run execute.
#   execute  Run the atomic handoff protocol once (manual or from check/run).
#   run      Polling supervisor loop (single-instance per FM_HOME).
#
# Auto-rotation (check/run) only triggers for quota-monitored providers:
# claude, codex, grok. When the active primary is pi, kimi-k3, or opencode,
# min_remaining is "na" and check never auto-hands-off; use `execute --force`
# (or wait until a monitored provider is active again). Accepted limitation.
#
# State:
#   state/.primary-active     written by fm-primary.sh on real launches
#   state/.primary-handoff    durable phase record for in-flight/completed handoff
#   state/.primary-handoff.lock          coordination lock (wake-lib portable lock)
#   state/.primary-handoff-daemon.lock   run-loop singleton
#
# Test seams:
#   FM_HANDOFF_QUOTA_JSON / FM_HANDOFF_QUOTA_AXI
#   FM_HANDOFF_SIGNAL_CMD / FM_HANDOFF_WAIT_DEAD_CMD / FM_HANDOFF_LAUNCH_CMD
#   FM_HANDOFF_INJECT_FAIL=flush|signal|wait_dead|release|pre_launch|launch|post_launch
#   FM_HANDOFF_WAIT_DEAD_SECS / FM_HANDOFF_NOW / FM_HANDOFF_SKIP_CLI_CHECK
set -u

SCRIPT_DIR=$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -P -- "$SCRIPT_DIR/.." && pwd -P)}
FM_HOME=${FM_HOME:-$FM_ROOT}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}

# shellcheck source=bin/fm-primary-handoff-lib.sh
. "$FM_ROOT/bin/fm-primary-handoff-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$FM_ROOT/bin/fm-wake-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

cmd_status() {
  local active lock_status
  fm_handoff_load_config || exit 1
  printf 'config: %s\n' "$FM_HANDOFF_MODE"
  if [ "$FM_HANDOFF_MODE" = enabled ]; then
    printf 'threshold_percent_remaining: %s\n' "$FM_HANDOFF_THRESHOLD"
    printf 'chain: %s\n' "$FM_HANDOFF_CHAIN_JSON"
  fi
  if active=$(fm_handoff_read_active_profile 2>/dev/null); then
    printf 'active_profile: %s\n' "$active"
  else
    printf 'active_profile: unknown\n'
  fi
  lock_status=$(FM_HOME="$FM_HOME" "$FM_ROOT/bin/fm-lock.sh" status)
  printf '%s\n' "$lock_status"
  if [ -f "$(fm_handoff_state_path)" ]; then
    printf 'handoff_record:\n'
    sed 's/^/  /' "$(fm_handoff_state_path)"
  else
    printf 'handoff_record: none\n'
  fi
}

abort_record() {
  local msg=$1
  phase=aborted
  error=$msg
  fm_handoff_write_record
  fm_handoff_log "$msg"
  return 1
}

fail_record() {
  local msg=$1
  phase=failed
  error=$msg
  fm_handoff_write_record
  fm_handoff_log "$msg"
  return 1
}

# Release cmd_execute's coordination lock and clear its EXIT trap; reads the
# caller's $coord via dynamic scoping.
release_coord() {
  fm_lock_release "$coord" 2>/dev/null || true
  trap - EXIT
}

cmd_execute() {
  local from_arg='' to_arg='' reason_arg='' force=0
  local active next remaining coord
  # Record fields are globals so fm_handoff_write_record can see them.
  phase=''
  from=''
  to=''
  reason=''
  token=''
  outgoing_pid=''
  incoming_pid=''
  started_at=''
  error=''
  completed_at=''
  cooldown_until=''

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --from)
        [ "$#" -ge 2 ] || { fm_handoff_log "--from requires a profile"; return 2; }
        from_arg=$2
        shift 2
        ;;
      --to)
        [ "$#" -ge 2 ] || { fm_handoff_log "--to requires a profile"; return 2; }
        to_arg=$2
        shift 2
        ;;
      --reason)
        [ "$#" -ge 2 ] || { fm_handoff_log "--reason requires text"; return 2; }
        reason_arg=$2
        shift 2
        ;;
      --force)
        force=1
        shift
        ;;
      *)
        fm_handoff_log "unknown execute argument: $1"
        return 2
        ;;
    esac
  done

  fm_handoff_load_config || return 1
  if [ "$FM_HANDOFF_MODE" != enabled ] && [ "$force" -ne 1 ]; then
    fm_handoff_log "handoff disabled (config/primary-handoff absent or enabled:false)"
    return 0
  fi
  if [ "$FM_HANDOFF_MODE" != enabled ]; then
    # --force with disabled/absent config still needs a chain for next-profile.
    FM_HANDOFF_MODE=enabled
    FM_HANDOFF_THRESHOLD=${FM_HANDOFF_THRESHOLD:-15}
    FM_HANDOFF_COOLDOWN_SECONDS=${FM_HANDOFF_COOLDOWN_SECONDS:-300}
    FM_HANDOFF_CHAIN_JSON=${FM_HANDOFF_CHAIN_JSON:-'["claude-fable","pi","codex","kimi-k3"]'}
  fi

  mkdir -p "$STATE" "$CONFIG" || return 1
  coord=$(fm_handoff_coord_lock)
  if ! fm_lock_try_acquire "$coord"; then
    fm_handoff_log "another handoff supervisor holds the coordination lock"
    return 1
  fi
  # shellcheck disable=SC2064
  trap 'fm_lock_release "'"$coord"'" 2>/dev/null || true' EXIT

  if fm_handoff_in_cooldown && [ "$force" -ne 1 ]; then
    fm_handoff_log "handoff cooldown active; skipping"
    release_coord
    return 0
  fi

  if [ -n "$from_arg" ]; then
    active=$(fm_handoff_normalize_profile "$from_arg") || {
      release_coord
      fm_handoff_die "invalid --from profile: $from_arg"
      return 1
    }
  else
    active=$(fm_handoff_read_active_profile) || {
      release_coord
      fm_handoff_die "no state/.primary-active profile; pass --from"
      return 1
    }
  fi

  if [ -n "$to_arg" ]; then
    next=$(fm_handoff_normalize_profile "$to_arg") || {
      release_coord
      fm_handoff_die "invalid --to profile: $to_arg"
      return 1
    }
  else
    next=$(fm_handoff_next_profile "$active") || {
      release_coord
      fm_handoff_die "no usable next profile after $active in chain"
      return 1
    }
  fi

  if ! fm_handoff_session_live_holder; then
    release_coord
    fm_handoff_die "session lock is not held by a live harness; refusing handoff"
    return 1
  fi
  outgoing_pid=$FM_HANDOFF_LIVE_HOLDER_PID

  remaining=$(fm_handoff_min_remaining_for_profile "$active")
  reason=${reason_arg:-quota:min_remaining=$remaining}
  token=$(printf '%s-%s' "$(fm_handoff_now)" "$outgoing_pid")
  started_at=$(fm_handoff_now)
  phase=planning
  from=$active
  to=$next
  error=
  incoming_pid=
  completed_at=
  cooldown_until=
  fm_handoff_write_record || {
    release_coord
    return 1
  }
  fm_handoff_assert_never_two_live_holders || {
    abort_record "invariant failed at planning"
    release_coord
    return 1
  }

  phase=flushing
  fm_handoff_write_record
  if ! fm_handoff_flush_durable; then
    abort_record "flush failed; outgoing still holds the session lock"
    release_coord
    return 1
  fi
  fm_handoff_assert_never_two_live_holders || {
    abort_record "invariant failed after flush"
    release_coord
    return 1
  }

  phase=releasing
  fm_handoff_write_record
  if ! fm_handoff_signal_outgoing "$outgoing_pid"; then
    abort_record "failed to signal outgoing pid $outgoing_pid"
    release_coord
    return 1
  fi
  if ! fm_handoff_wait_outgoing_dead "$outgoing_pid"; then
    abort_record "outgoing pid $outgoing_pid did not release; incoming not launched"
    release_coord
    return 1
  fi
  if ! fm_handoff_release_session_lock_stale; then
    abort_record "release-stale refused; incoming not launched"
    release_coord
    return 1
  fi
  if ! fm_handoff_assert_never_two_live_holders --require-free; then
    abort_record "session lock still live after release; incoming not launched"
    release_coord
    return 1
  fi

  phase=launching
  fm_handoff_write_record
  if ! fm_handoff_launch_incoming "$next"; then
    fail_record "incoming launch failed for $next; session lock left free for recovery"
    release_coord
    return 1
  fi
  if [ "${FM_HANDOFF_INJECT_FAIL:-}" = post_launch ]; then
    fail_record "injected failure at post_launch"
    release_coord
    return 1
  fi

  # Launch seams may acquire the lock asynchronously. Prefer observing a new
  # live holder; otherwise trust a successful launch command in test mode.
  if fm_handoff_session_live_holder; then
    if [ "$FM_HANDOFF_LIVE_HOLDER_PID" = "$outgoing_pid" ]; then
      fail_record "incoming launch left outgoing pid as lock holder"
      release_coord
      return 1
    fi
    incoming_pid=$FM_HANDOFF_LIVE_HOLDER_PID
  elif [ -n "${FM_HANDOFF_LAUNCH_CMD:-}" ]; then
    incoming_pid=${FM_HANDOFF_FAKE_INCOMING_PID:-0}
  else
    fail_record "incoming did not acquire the session lock"
    release_coord
    return 1
  fi

  fm_handoff_assert_never_two_live_holders || {
    fail_record "invariant failed after launch"
    release_coord
    return 1
  }

  phase=complete
  error=
  completed_at=$(fm_handoff_now)
  cooldown_until=$((completed_at + FM_HANDOFF_COOLDOWN_SECONDS))
  fm_handoff_write_record
  fm_handoff_write_active "$next" "$incoming_pid"
  fm_handoff_log "handed off primary $from -> $to (reason=$reason)"
  printf 'handed_off: %s -> %s\n' "$from" "$to"
  release_coord
  return 0
}

cmd_check() {
  local active remaining
  fm_handoff_load_config || return 1
  if [ "$FM_HANDOFF_MODE" != enabled ]; then
    printf 'handoff: disabled\n'
    return 0
  fi
  if fm_handoff_in_cooldown; then
    printf 'handoff: cooldown\n'
    return 0
  fi
  active=$(fm_handoff_read_active_profile) || {
    printf 'handoff: no active profile\n'
    return 0
  }
  remaining=$(fm_handoff_min_remaining_for_profile "$active")
  if ! fm_handoff_over_threshold "$active"; then
    printf 'handoff: ok profile=%s min_remaining=%s threshold=%s\n' \
      "$active" "$remaining" "$FM_HANDOFF_THRESHOLD"
    return 0
  fi
  printf 'handoff: threshold crossed profile=%s min_remaining=%s threshold=%s\n' \
    "$active" "$remaining" "$FM_HANDOFF_THRESHOLD"
  cmd_execute --from "$active" --reason "quota:min_remaining=$remaining"
}

cmd_run() {
  local daemon_lock
  fm_handoff_load_config || return 1
  if [ "$FM_HANDOFF_MODE" != enabled ]; then
    fm_handoff_log "handoff disabled; run loop exits"
    return 0
  fi
  mkdir -p "$STATE" || return 1
  daemon_lock="$STATE/.primary-handoff-daemon.lock"
  if ! fm_lock_try_acquire "$daemon_lock"; then
    fm_handoff_log "handoff run loop already active in this home"
    return 1
  fi
  # shellcheck disable=SC2064
  trap 'fm_lock_release "'"$daemon_lock"'" 2>/dev/null || true' EXIT
  fm_handoff_log "run loop started poll=${FM_HANDOFF_POLL_SECONDS}s threshold=${FM_HANDOFF_THRESHOLD}"
  while :; do
    fm_handoff_load_config || exit 1
    [ "$FM_HANDOFF_MODE" = enabled ] || {
      fm_handoff_log "handoff disabled; run loop exiting"
      break
    }
    cmd_check || true
    sleep "$FM_HANDOFF_POLL_SECONDS"
  done
  fm_lock_release "$daemon_lock"
  trap - EXIT
  return 0
}

CMD=${1:-}
case "$CMD" in
  -h|--help|'') usage; exit 0 ;;
  status) shift; cmd_status "$@" ;;
  check) shift; cmd_check "$@" ;;
  execute) shift; cmd_execute "$@" ;;
  run) shift; cmd_run "$@" ;;
  *)
    fm_handoff_log "unknown command: $CMD"
    usage
    exit 2
    ;;
esac
