#!/usr/bin/env bash
# Quota- and context-aware automated primary orchestrator handoff.
#
# Usage:
#   fm-primary-handoff.sh status
#   fm-primary-handoff.sh check
#   fm-primary-handoff.sh execute [--from PROFILE] [--to PROFILE] [--reason TEXT]
#   fm-primary-handoff.sh execute --fresh [--delay SECONDS]
#   fm-primary-handoff.sh fresh check|ask|go [--from web|desk|terminal]
#   fm-primary-handoff.sh run
#   fm-primary-handoff.sh --help
#
# Opt-in via local gitignored config/primary-handoff (JSON).
# Absent or enabled:false starts no handoff and does not change primary launch
# behavior; check/run/execute still reconcile an interrupted nonterminal record.
# docs/primary-handoff.md owns the atomic-lock protocol and failure modes.
# This header owns commands, flags, state paths, and test seams.
#
# Commands:
#   status   Print config, active profile, session lock, and handoff record.
#   check    One evaluation: if enabled and a trigger fires, run execute.
#   execute  Run the atomic handoff protocol once (manual or from check/run).
#   run      Polling supervisor loop (single-instance per FM_HOME).
#   fresh    A fresh session on the owner's word (docs/primary-handoff.md
#            "Fresh session"): the same profile, a new empty session.
#            check  prints `ready: <words>`, exit 0, or `refused: <words>`,
#                   exit 3. Refusals: away or quiet mode, a merge under way
#                   (bin/fm-merge-running-lib.sh), a handover already running,
#                   an ask still waiting (FM_FRESH_ASK_WAIT_SECS, default
#                   1800; --from web or desk only), no live first mate, a
#                   profile it cannot read, or no launch route. --from names
#                   where the press came from; the default, terminal, is the
#                   first mate's own step, which a waiting ask never refuses
#                   and whose refusal clears that ask.
#                   Every step first settles a handover record no controller
#                   is finishing any more (no `fresh go` controller, no
#                   coordination lock holder and no live `run` daemon, which
#                   recovers its own records): complete when a first mate
#                   holds the lock, else aborted. It never launches a first
#                   mate.
#            ask    the same refusals, then one captain inbox note asking the
#                   first mate to load the fresh skill. Prints
#                   `asked: <words>`.
#            go     run by the first mate itself once it has saved what it
#                   learned: the same refusals,
#                   then `execute --fresh --delay FM_FRESH_GRACE_SECS` (default
#                   10, so its caller can finish its reply) in its own process
#                   session, so stopping this session
#                   never stops it. Prints `started: <words>`.
#   execute --fresh is a same-runtime rotation (from == to) of the live
#   profile: the live lock holder's own launch line, else
#   state/.primary-active. It runs with config/primary-handoff absent or disabled and ignores
#   the cooldown, but never takes --force: away mode and a merge under way
#   refuse with exit 3, and every coordination and live-owner gate holds.
#
# Trigger axes (both under enabled:true):
#   quota   - threshold_percent_remaining vs quota-axi (claude/codex/grok only)
#   context - threshold_context_percent_used vs state/.primary-context
#             (written by fm-status-bar.sh). Context triggers SAME-RUNTIME
#             rotation (from == to) so a fresh empty session takes over.
# Quota still walks the configured chain to the next distinct profile.
# When both fire, quota (cross-runtime) wins because same-runtime refresh
# cannot restore provider quota.
#
# Auto-rotation (check/run) only fires quota for quota-monitored providers:
# claude, codex, grok. Context can fire for any profile that has a durable
# context sample. When neither axis has a usable signal, check never
# auto-hands-off; use `execute --force`. Accepted limitation.
#
# Safety refusals (unless --force): canonical away posture or legacy quiet
# flag, and cooldown. Coordination and live-owner gates are never bypassed.
#
# Launch routes (custom, herdr, tmux) are chosen from the outgoing process at
# planning; bin/fm-primary-handoff-lib.sh "launch routes" owns the rules.
#
# State:
#   state/.primary-active     written by fm-primary.sh on real launches
#   state/.primary-context    durable context sample from fm-status-bar.sh
#   state/.primary-handoff    durable phase record for in-flight/completed handoff
#   state/.primary-handoff.lock          coordination lock (wake-lib portable lock)
#   state/.primary-handoff-daemon.lock   run-loop singleton
#   state/.primary-handoff-launch.TOKEN.lock  per-generation launcher lifetime lock
#   state/.lock-handoff                  token/profile/PID/identity acknowledgement
#   state/.primary-fresh                 a fresh-session ask (asked_at, from) or
#                                        the controller `fresh go` started (pid)
#   state/.primary-fresh.log             that controller's output
# The internal `launch TOKEN PROFILE` entry is generation-checked and serialized;
# runtime routes must enter through it, and custom commands must stay in the
# foreground for their launch lifetime. FM_HANDOFF_TOKEN/FM_HANDOFF_PROFILE are
# inherited by the incoming session lock acquisition; neither is a credential.
# Records retain outgoing_identity to reject PID reuse during recovery, and
# shutdown_requested=no|yes; yes is persisted before any signal and never
# reverts, so an empty or yes value means the outgoing may be shutting down.
#
# Test seams:
#   FM_HANDOFF_QUOTA_JSON / FM_HANDOFF_QUOTA_AXI
#   FM_HANDOFF_CONTEXT_USED (override durable context used_percent)
#   FM_HANDOFF_SIGNAL_CMD / FM_HANDOFF_WAIT_DEAD_CMD / FM_HANDOFF_LAUNCH_CMD
#   FM_HANDOFF_PREFLIGHT_CMD (required with a custom launch route)
#   FM_HANDOFF_STARTUP_SECS (default 60, bounded ownership acknowledgement)
#   FM_HANDOFF_INJECT_CRASH=planning|flushing|releasing|launching|complete
#   FM_HANDOFF_INJECT_FAIL=flush|signal|wait_dead|release|pre_launch|launch|post_launch
#   FM_HANDOFF_WAIT_DEAD_SECS / FM_HANDOFF_NOW / FM_HANDOFF_SKIP_CLI_CHECK
#   FM_HANDOFF_HERDR_BIN (default herdr) / FM_HANDOFF_PROC_ENV_CMD (prints a
#   pid's environment as KEY=VALUE lines)
#   FM_FRESH_GRACE_SECS / FM_FRESH_ASK_WAIT_SECS
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
# shellcheck source=bin/fm-merge-running-lib.sh
. "$FM_ROOT/bin/fm-merge-running-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

cmd_status() {
  local active lock_status ctx_used
  fm_handoff_load_config || exit 1
  printf 'config: %s\n' "$FM_HANDOFF_MODE"
  if [ "$FM_HANDOFF_MODE" = enabled ]; then
    printf 'threshold_percent_remaining: %s\n' "$FM_HANDOFF_THRESHOLD"
    if [ -n "$FM_HANDOFF_CONTEXT_USED_THRESHOLD" ]; then
      printf 'threshold_context_percent_used: %s\n' "$FM_HANDOFF_CONTEXT_USED_THRESHOLD"
    else
      printf 'threshold_context_percent_used: disabled\n'
    fi
    printf 'chain: %s\n' "$FM_HANDOFF_CHAIN_JSON"
  fi
  if active=$(fm_handoff_read_active_profile 2>/dev/null); then
    printf 'active_profile: %s\n' "$active"
  else
    printf 'active_profile: unknown\n'
  fi
  ctx_used=$(fm_handoff_context_used_percent)
  printf 'context_used_percent: %s\n' "$ctx_used"
  lock_status=$(FM_HOME="$FM_HOME" "$FM_ROOT/bin/fm-lock.sh" status)
  printf '%s\n' "$lock_status"
  if [ -f "$(fm_handoff_state_path)" ]; then
    printf 'handoff_record:\n'
    sed 's/^/  /' "$(fm_handoff_state_path)"
  else
    printf 'handoff_record: none\n'
  fi
}

clear_launch_lock() {
  local launch_lock
  launch_lock=$(fm_handoff_launch_lock "$token") || return 0
  fm_lock_remove_path "$launch_lock" || true
}

abort_record() {
  local msg=$1
  phase=aborted
  error=$msg
  fm_handoff_write_record
  clear_launch_lock
  fm_handoff_log "$msg"
  return 1
}

# These helpers run under cmd_execute's coordination lock. A failed or timed
# out launch keeps its durable launching phase so check/run can reconcile it.
complete_record() {
  error=
  completed_at=$(fm_handoff_now)
  cooldown_until=$((completed_at + FM_HANDOFF_COOLDOWN_SECONDS))
  fm_handoff_write_active "$to" "$incoming_pid" || return 1
  phase=complete
  fm_handoff_write_record || return 1
  clear_launch_lock
  fm_handoff_tmux_close_outgoing
  fm_handoff_log "handed off primary $from -> $to (reason=$reason trigger=$trigger)"
  printf 'handed_off: %s -> %s\n' "$from" "$to"
}

finish_launch() {
  phase=launching
  fm_handoff_write_record || return 1
  rm -f "$(fm_handoff_context_path)" || return 1
  if ! fm_handoff_launch_incoming "$to"; then
    error="incoming launch failed for $to; recovery pending"
    fm_handoff_write_record
    fm_handoff_log "$error"
    return 1
  fi
  if [ "${FM_HANDOFF_INJECT_FAIL:-}" = post_launch ] || ! fm_handoff_wait_incoming; then
    error="incoming ownership acknowledgement pending"
    fm_handoff_write_record
    return 1
  fi
  complete_record
}

release_and_launch() {
  # A stale controller must never signal a different owner or a reused PID.
  if ! fm_handoff_session_live_holder \
    || [ "$FM_HANDOFF_LIVE_HOLDER_PID" != "$outgoing_pid" ] \
    || ! fm_pid_identity_matches "$outgoing_pid" "$outgoing_identity"; then
    abort_record "outgoing identity changed before signal; incoming not launched"
    return 1
  fi
  phase=releasing
  fm_handoff_write_record || return 1
  shutdown_requested=yes
  fm_handoff_write_record || return 1
  fm_handoff_tmux_hold_outgoing
  if ! fm_handoff_signal_outgoing "$outgoing_pid"; then
    fm_handoff_tmux_close_outgoing
    abort_record "failed to signal outgoing pid $outgoing_pid"
    return 1
  fi
  if ! fm_handoff_wait_outgoing_dead "$outgoing_pid"; then
    # TERM may finish later. Keep releasing recoverable instead of abandoning
    # the home if the old process exits after this bounded wait.
    error="outgoing pid $outgoing_pid did not release; incoming not launched"
    fm_handoff_write_record
    fm_handoff_log "$error"
    return 1
  fi
  fm_handoff_release_session_lock_stale || return 1
  finish_launch
}

recover_record() {
  fm_handoff_read_record || return 1
  fm_handoff_launch_lock "$token" >/dev/null && [ -n "$outgoing_pid" ] && [ -n "$to" ] \
    && [ "$(fm_handoff_normalize_profile "$to")" = "$to" ] || {
    abort_record "incomplete handoff record; refusing recovery"
    return 1
  }
  if fm_handoff_incoming_acknowledged; then
    complete_record
    return $?
  fi
  if fm_handoff_session_live_holder; then
    if [ "$FM_HANDOFF_LIVE_HOLDER_PID" != "$outgoing_pid" ] \
      || [ -z "$outgoing_identity" ] \
      || ! fm_pid_identity_matches "$outgoing_pid" "$outgoing_identity"; then
      # Acquisition publishes the PID before its acknowledgement under the
      # claim mutex. A still-starting replacement gets the same bounded wait
      # as initial startup before it can be classified as unrelated.
      if [ "$phase" = launching ] && fm_handoff_wait_incoming; then
        complete_record
        return $?
      fi
      abort_record "unrelated live owner; refusing recovery"
      return 1
    fi
    case "$phase" in
      planning|flushing)
        abort_record "interrupted before release; outgoing owner preserved"
        return 0
        ;;
    esac
    fm_handoff_preflight "$to" || {
      [ "$shutdown_requested" = no ] || return 1
      abort_record "target preflight failed; outgoing owner preserved"
      return 1
    }
    release_and_launch
    return $?
  fi
  fm_handoff_preflight "$to" || return 1
  if ! fm_handoff_release_session_lock_stale; then
    # An asynchronous incoming acquire may win after our no-owner snapshot.
    # The release refused safely; reconcile its receipt instead of relaunching.
    fm_handoff_wait_incoming || return 1
    complete_record
    return $?
  fi
  finish_launch
}

# Runtime entry point, separate from the controller. The lifetime lock makes
# re-sending a launch after a controller crash safe even before startup claims
# the session lock. Exec preserves its PID; stale recovery happens on exit.
cmd_launch() {
  local expected_token=${1:-} expected_profile=${2:-}
  [ -n "$expected_profile" ] || return 2
  launch_lock=$(fm_handoff_launch_lock "$expected_token") || return 2
  fm_lock_try_acquire "$launch_lock" || return 0
  trap 'fm_lock_release "$launch_lock"' EXIT
  trap 'exit 1' HUP INT TERM
  fm_handoff_read_record || return 1
  [ "$phase" = launching ] && [ "$token" = "$expected_token" ] \
    && [ "$to" = "$expected_profile" ] || return 1
  fm_handoff_assert_never_two_live_holders --require-free || return 1
  export FM_HANDOFF_TOKEN=$token FM_HANDOFF_PROFILE=$to
  if [ -n "${FM_HANDOFF_LAUNCH_CMD:-}" ]; then
    # shellcheck disable=SC2086
    $FM_HANDOFF_LAUNCH_CMD "$to"
  else
    exec "$FM_ROOT/bin/fm-primary.sh" "$to"
  fi
}

# Subshell trap scope preserves the run loop's independent singleton cleanup.
cmd_execute() (

  local from_arg='' to_arg='' reason_arg='' force=0 recover_only=0 fresh=0 delay=0
  local active next remaining coord
  local FM_HANDOFF_MODE FM_HANDOFF_THRESHOLD FM_HANDOFF_CONTEXT_USED_THRESHOLD
  local FM_HANDOFF_COOLDOWN_SECONDS FM_HANDOFF_CHAIN_JSON FM_HANDOFF_POLL_SECONDS
  # Record fields are globals so fm_handoff_write_record can see them.
  phase=''
  from=''
  to=''
  reason=''
  trigger=''
  token=''
  outgoing_pid=''
  outgoing_identity=''
  shutdown_requested=''
  incoming_pid=''
  started_at=''
  error=''
  completed_at=''
  cooldown_until=''
  route=''
  herdr_session=''
  herdr_pane=''
  herdr_workspace=''
  tmux_pane=''

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
      --recover-only)
        recover_only=1
        shift
        ;;
      --fresh)
        fresh=1
        shift
        ;;
      --delay)
        [ "$#" -ge 2 ] || { fm_handoff_log "--delay requires seconds"; return 2; }
        delay=$2
        case "$delay" in ''|*[!0-9]*) fm_handoff_log "--delay requires whole seconds"; return 2 ;; esac
        shift 2
        ;;
      *)
        fm_handoff_log "unknown execute argument: $1"
        return 2
        ;;
    esac
  done

  if [ "$fresh" -eq 1 ] && [ "$force" -eq 1 ]; then
    fm_handoff_log "--fresh never takes --force: a fresh session keeps every refusal"
    return 2
  fi
  [ "$delay" -eq 0 ] || sleep "$delay"
  fm_handoff_load_config || return 1

  mkdir -p "$STATE" "$CONFIG" || return 1
  coord=$(fm_handoff_coord_lock)
  if ! fm_lock_try_acquire "$coord"; then
    fm_handoff_log "another handoff supervisor holds the coordination lock"
    return 1
  fi
  trap 'fm_lock_release "$coord" 2>/dev/null || true' EXIT
  trap 'exit 1' HUP INT TERM

  if fm_handoff_afk_active && [ "$force" -ne 1 ]; then
    fm_handoff_log "away or quiet mode active; refusing handoff"
    [ "$fresh" -eq 0 ] || return 3
    return 0
  fi

  if fm_handoff_rotation_in_progress; then
    recover_record
    return $?
  fi
  [ "$recover_only" -eq 0 ] || return 0

  if [ "$fresh" -eq 1 ]; then
    # A manual fresh session: the owner's explicit ask, so neither a disabled
    # config nor the cooldown stops it; a merge under way does.
    if fm_merge_running_any "$STATE"; then
      fm_handoff_log "a merge is under way; refusing a fresh session"
      return 3
    fi
  elif [ "$FM_HANDOFF_MODE" != enabled ]; then
    if [ "$force" -ne 1 ]; then
      fm_handoff_log "handoff disabled (config/primary-handoff absent or enabled:false)"
      return 0
    fi
    # --force with disabled/absent config still needs a chain for next-profile.
    FM_HANDOFF_CHAIN_JSON='["claude-fable","claude-opus","pi","codex"]'
  fi

  if fm_handoff_in_cooldown && [ "$force" -ne 1 ] && [ "$fresh" -ne 1 ]; then
    fm_handoff_log "handoff cooldown active; skipping"
    return 0
  fi

  if [ -n "$from_arg" ]; then
    active=$(fm_handoff_normalize_profile "$from_arg") || {
      fm_handoff_die "invalid --from profile: $from_arg"
      return 1
    }
  elif [ "$fresh" -eq 1 ] && fm_handoff_session_live_holder \
    && active=$(fm_handoff_profile_from_pid "$FM_HANDOFF_LIVE_HOLDER_PID"); then
    # The live process is the truth: the marker goes stale once config stops writing it.
    :
  elif active=$(fm_handoff_read_active_profile 2>/dev/null); then
    :
  else
    fm_handoff_die "no state/.primary-active profile; pass --from"
    return 1
  fi

  if [ "$fresh" -eq 1 ]; then
    next=$active
  elif [ -n "$to_arg" ]; then
    next=$(fm_handoff_normalize_profile "$to_arg") || {
      fm_handoff_die "invalid --to profile: $to_arg"
      return 1
    }
  else
    next=$(fm_handoff_next_profile "$active") || {
      fm_handoff_die "no usable next profile after $active in chain"
      return 1
    }
  fi

  if ! fm_handoff_session_live_holder; then
    fm_handoff_die "session lock is not held by a live harness; refusing handoff"
    return 1
  fi
  outgoing_pid=$FM_HANDOFF_LIVE_HOLDER_PID
  outgoing_identity=$(fm_pid_identity "$outgoing_pid") || return 1
  fm_handoff_route_detect "$outgoing_pid" || return 1
  fm_handoff_preflight "$next" || return 1

  remaining=$(fm_handoff_min_remaining_for_profile "$active")
  if [ -n "$reason_arg" ]; then
    reason=$reason_arg
  elif [ "$fresh" -eq 1 ]; then
    reason=manual:fresh-session
  elif [ "$active" = "$next" ]; then
    reason="context:used=$(fm_handoff_context_used_percent)"
  else
    reason="quota:min_remaining=$remaining"
  fi
  case "$reason" in
    context:*) trigger=context ;;
    quota:*) trigger=quota ;;
    *) trigger=manual ;;
  esac
  token="$(fm_handoff_now)-$$-$RANDOM-$RANDOM"
  started_at=$(fm_handoff_now)
  phase=planning
  from=$active
  to=$next
  error=
  shutdown_requested=no
  incoming_pid=
  completed_at=
  cooldown_until=
  fm_handoff_write_record || {
    return 1
  }
  fm_handoff_assert_never_two_live_holders || {
    abort_record "invariant failed at planning"
    return 1
  }

  phase=flushing
  fm_handoff_write_record || return 1
  if ! fm_handoff_flush_durable; then
    abort_record "flush failed; outgoing still holds the session lock"
    return 1
  fi
  fm_handoff_assert_never_two_live_holders || {
    abort_record "invariant failed after flush"
    return 1
  }

  release_and_launch
)

cmd_check() {
  local active remaining ctx_used next
  fm_handoff_load_config || return 1
  if fm_handoff_rotation_in_progress; then
    cmd_execute --recover-only
    return $?
  fi
  if [ "$FM_HANDOFF_MODE" != enabled ]; then
    printf 'handoff: disabled\n'
    return 0
  fi
  if fm_handoff_afk_active; then
    printf 'handoff: afk\n'
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
  ctx_used=$(fm_handoff_context_used_percent)

  # Quota wins when both fire: same-runtime refresh cannot restore quota.
  if fm_handoff_over_threshold "$active"; then
    if next=$(fm_handoff_next_profile "$active" 2>/dev/null); then
      printf 'handoff: threshold crossed profile=%s min_remaining=%s threshold=%s\n' \
        "$active" "$remaining" "$FM_HANDOFF_THRESHOLD"
      cmd_execute --from "$active" --to "$next" --reason "quota:min_remaining=$remaining"
      return $?
    fi
    printf 'handoff: chain exhausted profile=%s min_remaining=%s threshold=%s\n' \
      "$active" "$remaining" "$FM_HANDOFF_THRESHOLD"
  fi

  if fm_handoff_context_over_threshold; then
    printf 'handoff: context threshold crossed profile=%s used=%s threshold=%s\n' \
      "$active" "$ctx_used" "$FM_HANDOFF_CONTEXT_USED_THRESHOLD"
    # Same-runtime: exit and respawn the same profile for a fresh session.
    cmd_execute --from "$active" --to "$active" \
      --reason "context:used=$ctx_used"
    return $?
  fi

  printf 'handoff: ok profile=%s min_remaining=%s context_used=%s quota_threshold=%s context_threshold=%s\n' \
    "$active" "$remaining" "$ctx_used" "$FM_HANDOFF_THRESHOLD" \
    "${FM_HANDOFF_CONTEXT_USED_THRESHOLD:-disabled}"
  return 0
}

# --- a fresh session on the owner's word -------------------------------------
#
# docs/primary-handoff.md "Fresh session" owns why and the flow; the header
# owns the commands. Every refusal is one plain sentence after `refused: `,
# exit 3, so the web page, the bridge strip and the desk show it as it is.

fresh_pending_path() {
  printf '%s\n' "$STATE/.primary-fresh"
}

# The live pid of a controller `fresh go` started that has not finished, or 1.
fresh_pending_pid() {
  local pid
  pid=$(awk -F= '$1 == "pid" { print $2; exit }' "$(fresh_pending_path)" 2>/dev/null)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  fm_pid_alive "$pid" || return 1
  printf '%s\n' "$pid"
}

# Seconds since `fresh ask` last asked the first mate, while that ask is still
# waiting on it (at most FM_FRESH_ASK_WAIT_SECS, default 1800), else 1.
fresh_ask_age() {
  local asked now wait=${FM_FRESH_ASK_WAIT_SECS:-1800}
  asked=$(awk -F= '$1 == "asked_at" { print $2; exit }' "$(fresh_pending_path)" 2>/dev/null)
  case "$asked" in ''|*[!0-9]*) return 1 ;; esac
  now=$(fm_handoff_now)
  [ "$asked" -le "$now" ] && [ "$((now - asked))" -lt "$wait" ] || return 1
  printf '%s\n' "$((now - asked))"
}

# Print why a fresh session cannot start now, or nothing. <step> is check,
# ask or go; only a press from the web page or the desk waits behind an
# earlier ask, never the first mate's own step.
fresh_refusal() {  # <step> <from>
  local step=$1 from=$2 coord age profile
  # fm_handoff_route_detect sets these; they stay this function's own.
  local route='' herdr_session='' herdr_pane='' herdr_workspace='' tmux_pane=''
  if fm_handoff_afk_active; then
    printf 'The first mate is in away or quiet mode. Come back first, then start a fresh session.\n'
    return 0
  fi
  if fm_merge_running_any "$STATE"; then
    printf 'A merge is under way. Try again once it has finished.\n'
    return 0
  fi
  coord=$(fm_handoff_coord_lock)
  if fm_handoff_rotation_in_progress || fresh_pending_pid >/dev/null \
    || { [ -d "$coord" ] && fm_lock_holder_alive "$coord" "$(cat "$coord/pid" 2>/dev/null)"; }; then
    printf 'A handover to a fresh session is already running.\n'
    return 0
  fi
  if [ "$from" != terminal ] && age=$(fresh_ask_age); then
    printf 'A fresh session was asked for %s. The first mate starts it as soon as it has saved what it learned.\n' \
      "$(fresh_age_words "$age")"
    return 0
  fi
  if ! fm_handoff_session_live_holder; then
    printf 'No first mate session is running, so there is nothing to refresh.\n'
    return 0
  fi
  if ! profile=$(fm_handoff_profile_from_pid "$FM_HANDOFF_LIVE_HOLDER_PID") \
    && ! profile=$(fm_handoff_read_active_profile 2>/dev/null); then
    printf 'Starship cannot tell which first mate is running, so it cannot start the same one fresh.\n'
    return 0
  fi
  # A tmux route starts from the shell that runs `go`, the first mate's own.
  if ! fm_handoff_route_detect "$FM_HANDOFF_LIVE_HOLDER_PID" 2>/dev/null \
    || { [ "$step" = go ] && [ "$route" = tmux ] && [ -z "${TMUX:-}" ]; }; then
    printf 'Starship cannot tell where the first mate runs, so it has nowhere to start the fresh session.\n'
    return 0
  fi
  return 0
}

# Settle a handover record that no controller is finishing any more, so it
# never refuses every later press. A first mate that took the lock completes
# it; otherwise it is cleared as failed. It never launches a first mate.
fresh_settle_stale_handover() (
  local coord launch_lock record_phase record_token daemon
  fm_handoff_rotation_in_progress || return 0
  ! fresh_pending_pid >/dev/null || return 0
  daemon="$STATE/.primary-handoff-daemon.lock"
  if [ -e "$daemon" ] && fm_lock_holder_alive "$daemon" "$(cat "$daemon/pid" 2>/dev/null)"; then
    return 0
  fi
  coord=$(fm_handoff_coord_lock)
  fm_lock_try_acquire "$coord" || return 0
  trap 'fm_lock_release "$coord" 2>/dev/null || true' EXIT
  fm_handoff_rotation_in_progress || return 0
  fm_handoff_read_record || return 0
  record_phase=$(awk -F= '$1 == "phase" { print $2; exit }' "$(fm_handoff_state_path)")
  record_token=$(awk -F= '$1 == "token" { print $2; exit }' "$(fm_handoff_state_path)")
  if [ "$record_phase" = launching ] && fm_handoff_incoming_acknowledged; then
    complete_record >/dev/null
    return 0
  fi
  if launch_lock=$(fm_handoff_launch_lock "$record_token"); then
    fm_lock_try_acquire "$launch_lock" || return 0
  fi
  abort_record "no controller is finishing this handover; cleared so the next press can start" || true
)

fresh_age_words() {  # <seconds>
  local minutes=$(($1 / 60))
  case "$minutes" in
    0) printf 'just now' ;;
    1) printf 'a minute ago' ;;
    *) printf '%s minutes ago' "$minutes" ;;
  esac
}

fresh_write_pending() {  # <key=value...>
  fm_handoff_write_kv_file "$(fresh_pending_path)" "schema=fm-primary-fresh.v1" "$@"
}

# Start <command...> in its own process session, so stopping the outgoing
# first mate (whose shell may have run `fresh go`) never stops it too.
fresh_detach() {
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" </dev/null >>"$STATE/.primary-fresh.log" 2>&1 &
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$@" \
      </dev/null >>"$STATE/.primary-fresh.log" 2>&1 &
  else
    nohup "$@" </dev/null >>"$STATE/.primary-fresh.log" 2>&1 &
  fi
  FRESH_DETACHED_PID=$!
}

cmd_fresh() {
  local step=${1:-} from=terminal refusal note
  [ "$#" -eq 0 ] || shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --from)
        [ "$#" -ge 2 ] || { fm_handoff_log "--from requires web, desk or terminal"; return 2; }
        from=$2
        shift 2
        ;;
      *) fm_handoff_log "unknown fresh argument: $1"; return 2 ;;
    esac
  done
  case "$step" in check|ask|go) ;; *) usage; return 2 ;; esac
  case "$from" in web|desk|terminal) ;; *) fm_handoff_log "--from must be web, desk or terminal"; return 2 ;; esac
  fm_handoff_load_config || return 1
  mkdir -p "$STATE" || return 1
  fresh_settle_stale_handover
  refusal=$(fresh_refusal "$step" "$from")
  if [ -n "$refusal" ]; then
    if [ "$from" = terminal ] && fresh_ask_age >/dev/null; then
      rm -f "$(fresh_pending_path)"
    fi
    printf 'refused: %s\n' "$refusal"
    return 3
  fi
  case "$step" in
    check)
      printf 'ready: The first mate can save what it learned and start a fresh session.\n'
      ;;
    ask)
      case "$from" in
        web) note="the Starship web page" ;;
        desk) note="the desk" ;;
        *) note="the terminal" ;;
      esac
      note="Fresh session asked for from $note. Load the fresh skill: save what this session learned, then start the fresh session."
      if ! FM_HOME="$FM_HOME" "$FM_ROOT/bin/fm-inbox.sh" note \
        --request-id "fresh-session-$(fm_handoff_now)" -- "$note" >/dev/null 2>&1; then
        printf 'refused: The ask could not reach the first mate. Try again in a moment.\n'
        return 1
      fi
      fresh_write_pending "asked_at=$(fm_handoff_now)" "from=$from" || true
      printf 'asked: The first mate saves what it learned, then starts the fresh session.\n'
      ;;
    go)
      fresh_detach env FM_HOME="$FM_HOME" "$FM_ROOT/bin/fm-primary-handoff.sh" \
        execute --fresh --delay "${FM_FRESH_GRACE_SECS:-10}"
      fresh_write_pending "pid=$FRESH_DETACHED_PID" "started_at=$(fm_handoff_now)" || true
      printf 'started: This session stops in a few seconds and a fresh one starts in its place; the window stays open until the new one is running.\n'
      ;;
  esac
}

cmd_run() {
  local daemon_lock
  fm_handoff_load_config || return 1
  if [ "$FM_HANDOFF_MODE" != enabled ]; then
    cmd_check || true
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
  fm_handoff_log "run loop started poll=${FM_HANDOFF_POLL_SECONDS}s quota_threshold=${FM_HANDOFF_THRESHOLD} context_threshold=${FM_HANDOFF_CONTEXT_USED_THRESHOLD:-disabled}"
  while :; do
    cmd_check || true
    fm_handoff_load_config || exit 1
    [ "$FM_HANDOFF_MODE" = enabled ] || {
      fm_handoff_log "handoff disabled; run loop exiting"
      break
    }
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
  launch) shift; cmd_launch "$@" ;;
  fresh) shift; cmd_fresh "$@" ;;
  run) shift; cmd_run "$@" ;;
  *)
    fm_handoff_log "unknown command: $CMD"
    usage
    exit 2
    ;;
esac
