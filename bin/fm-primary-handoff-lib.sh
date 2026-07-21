#!/usr/bin/env bash
# Shared primary-orchestrator handoff helpers.
# Sourced by bin/fm-primary-handoff.sh and tests.
# docs/primary-handoff.md owns the protocol narrative; this file owns the
# state-machine helpers and the never-two-live-holders assertion.
#
# shellcheck shell=bash

FM_HANDOFF_SCHEMA=fm-primary-handoff.v1
FM_HANDOFF_ACTIVE_SCHEMA=fm-primary-active.v1

fm_handoff_now() {
  if [ -n "${FM_HANDOFF_NOW:-}" ]; then
    printf '%s\n' "$FM_HANDOFF_NOW"
  else
    date +%s
  fi
}

fm_handoff_log() {
  printf 'fm-primary-handoff: %s\n' "$*" >&2
}

fm_handoff_die() {
  fm_handoff_log "$*"
  return 1
}

fm_handoff_config_path() {
  printf '%s\n' "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/primary-handoff"
}

fm_handoff_state_path() {
  printf '%s\n' "$STATE/.primary-handoff"
}

fm_handoff_active_path() {
  printf '%s\n' "$STATE/.primary-active"
}

fm_handoff_coord_lock() {
  printf '%s\n' "$STATE/.primary-handoff.lock"
}

fm_handoff_session_lock() {
  printf '%s\n' "$STATE/.lock"
}

# Load FM_HANDOFF_* globals from config.
# Sets FM_HANDOFF_MODE to enabled|disabled.
# Returns 0 even when disabled; non-zero only on malformed enabled config.
# Must not be called inside a command substitution: the globals are the API.
fm_handoff_load_config() {
  local path json
  path=$(fm_handoff_config_path)
  # Intentional globals consumed by fm-primary-handoff.sh.
  FM_HANDOFF_MODE=disabled
  FM_HANDOFF_THRESHOLD=15
  FM_HANDOFF_POLL_SECONDS=60
  FM_HANDOFF_COOLDOWN_SECONDS=300
  FM_HANDOFF_CHAIN_JSON='[]'
  export FM_HANDOFF_MODE FM_HANDOFF_THRESHOLD FM_HANDOFF_POLL_SECONDS \
    FM_HANDOFF_COOLDOWN_SECONDS FM_HANDOFF_CHAIN_JSON
  [ -f "$path" ] || return 0
  command -v jq >/dev/null 2>&1 || {
    fm_handoff_log "jq required to read $path"
    return 1
  }
  json=$(cat "$path") || return 1
  if ! printf '%s\n' "$json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    fm_handoff_log "invalid config/primary-handoff: not a JSON object"
    return 1
  fi
  if [ "$(printf '%s\n' "$json" | jq -r 'if .enabled == true then "1" else "0" end')" != 1 ]; then
    return 0
  fi
  FM_HANDOFF_MODE=enabled
  FM_HANDOFF_THRESHOLD=$(printf '%s\n' "$json" | jq -r '.threshold_percent_remaining // 15')
  FM_HANDOFF_POLL_SECONDS=$(printf '%s\n' "$json" | jq -r '.poll_seconds // 60')
  FM_HANDOFF_COOLDOWN_SECONDS=$(printf '%s\n' "$json" | jq -r '.cooldown_seconds // 300')
  FM_HANDOFF_CHAIN_JSON=$(printf '%s\n' "$json" | jq -c '
    (.chain // ["claude-fable","pi","codex","kimi-k3"])
    | if type == "array" and length > 0 then . else empty end
  ' 2>/dev/null) || {
    fm_handoff_log "invalid config/primary-handoff: chain must be a non-empty array"
    return 1
  }
  case "$FM_HANDOFF_THRESHOLD" in ''|*[!0-9]*) FM_HANDOFF_THRESHOLD=15 ;; esac
  case "$FM_HANDOFF_POLL_SECONDS" in ''|*[!0-9]*) FM_HANDOFF_POLL_SECONDS=60 ;; esac
  case "$FM_HANDOFF_COOLDOWN_SECONDS" in ''|*[!0-9]*) FM_HANDOFF_COOLDOWN_SECONDS=300 ;; esac
  export FM_HANDOFF_MODE FM_HANDOFF_THRESHOLD FM_HANDOFF_POLL_SECONDS \
    FM_HANDOFF_COOLDOWN_SECONDS FM_HANDOFF_CHAIN_JSON
  return 0
}

fm_handoff_normalize_profile() {
  case "$1" in
    claude) printf 'claude-fable\n' ;;
    kimi) printf 'kimi-k3\n' ;;
    pi|claude-fable|codex|opencode|grok|kimi-k3) printf '%s\n' "$1" ;;
    *) return 1 ;;
  esac
}

fm_handoff_profile_cli() {
  case "$1" in
    pi) printf 'pi\n' ;;
    claude-fable) printf 'claude\n' ;;
    codex) printf 'codex\n' ;;
    opencode) printf 'opencode\n' ;;
    grok) printf 'grok\n' ;;
    kimi-k3) printf 'kimi\n' ;;
    *) return 1 ;;
  esac
}

fm_handoff_profile_provider() {
  case "$1" in
    claude|claude-fable) printf 'claude\n' ;;
    codex) printf 'codex\n' ;;
    grok) printf 'grok\n' ;;
    *) printf '\n' ;;
  esac
}

# Write path from `key=value` arguments (never relies on caller locals).
fm_handoff_write_kv_file() {
  local path=$1
  shift
  local tmp pair key value
  tmp=$(mktemp "$path.XXXXXX") || return 1
  {
    for pair in "$@"; do
      key=${pair%%=*}
      value=${pair#*=}
      printf '%s=%s\n' "$key" "$value"
    done
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

# shellcheck disable=SC2034 # dynamic nameref-style write via eval below is intentional
fm_handoff_read_kv_file() {
  local path=$1
  local line key value
  [ -f "$path" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    case "$line" in
      \#*) continue ;;
      *=*)
        key=${line%%=*}
        value=${line#*=}
        case "$key" in
          schema|phase|from|to|reason|token|outgoing_pid|incoming_pid|started_at|updated_at|error|profile|pid|completed_at|cooldown_until)
            printf -v "$key" '%s' "$value"
            ;;
        esac
        ;;
    esac
  done < "$path"
}

fm_handoff_write_active() {
  local profile=$1 pid=${2:-} path now
  path=$(fm_handoff_active_path)
  now=$(fm_handoff_now)
  fm_handoff_write_kv_file "$path" \
    "schema=$FM_HANDOFF_ACTIVE_SCHEMA" \
    "profile=$profile" \
    "pid=$pid" \
    "started_at=$now" \
    "updated_at=$now"
}

fm_handoff_read_active_profile() {
  local path profile
  path=$(fm_handoff_active_path)
  [ -f "$path" ] || return 1
  profile=$(awk -F= '$1 == "profile" { print $2; exit }' "$path")
  [ -n "$profile" ] || return 1
  fm_handoff_normalize_profile "$profile"
}

fm_handoff_write_record() {
  local path updated
  path=$(fm_handoff_state_path)
  updated=$(fm_handoff_now)
  fm_handoff_write_kv_file "$path" \
    "schema=$FM_HANDOFF_SCHEMA" \
    "phase=${phase:-}" \
    "from=${from:-}" \
    "to=${to:-}" \
    "reason=${reason:-}" \
    "token=${token:-}" \
    "outgoing_pid=${outgoing_pid:-}" \
    "incoming_pid=${incoming_pid:-}" \
    "started_at=${started_at:-}" \
    "updated_at=$updated" \
    "error=${error:-}" \
    "completed_at=${completed_at:-}" \
    "cooldown_until=${cooldown_until:-}"
}

fm_handoff_read_record() {
  local path
  path=$(fm_handoff_state_path)
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
  fm_handoff_read_kv_file "$path"
}

fm_handoff_clear_record() {
  rm -f "$(fm_handoff_state_path)"
}

# Returns 0 when the session lock is held by a live harness. Sets
# FM_HANDOFF_LIVE_HOLDER_PID when true (consumed by fm-primary-handoff.sh).
fm_handoff_session_live_holder() {
  local lock old
  FM_HANDOFF_LIVE_HOLDER_PID=
  export FM_HANDOFF_LIVE_HOLDER_PID
  lock=$(fm_handoff_session_lock)
  [ -f "$lock" ] || return 1
  old=$(cat "$lock" 2>/dev/null || true)
  case "$old" in ''|*[!0-9]*) return 1 ;; esac
  if FM_HOME="$FM_HOME" "$FM_ROOT/bin/fm-lock.sh" status 2>/dev/null | grep -q "held by live harness pid $old"; then
    FM_HANDOFF_LIVE_HOLDER_PID=$old
    export FM_HANDOFF_LIVE_HOLDER_PID
    return 0
  fi
  return 1
}

# HARD INVARIANT: at most one live harness may hold state/.lock.
# Also refuse when a launch is about to happen while any live holder exists.
# Optional expected_max_live (default 1).
fm_handoff_assert_never_two_live_holders() {
  local lock old status live=0
  lock=$(fm_handoff_session_lock)
  if [ -f "$lock" ]; then
    old=$(cat "$lock" 2>/dev/null || true)
    case "$old" in
      ''|*[!0-9]*) ;;
      *)
        status=$(FM_HOME="$FM_HOME" "$FM_ROOT/bin/fm-lock.sh" status 2>/dev/null || true)
        case "$status" in
          *"held by live harness pid $old"*) live=1 ;;
        esac
        ;;
    esac
  fi
  if [ "$live" -gt 1 ]; then
    fm_handoff_die "invariant violated: counted $live live session-lock holders"
    return 1
  fi
  # A single file can only record one PID; the dual-holder failure mode is
  # "launch while a live holder still exists". Callers pass --require-free to
  # enforce the pre-launch gate.
  if [ "${1:-}" = --require-free ] && [ "$live" -ne 0 ]; then
    fm_handoff_die "invariant refuse: session lock still held by live harness pid ${old:-unknown}; will not launch incoming"
    return 1
  fi
  return 0
}

fm_handoff_quota_json() {
  local quota_cmd
  if [ -n "${FM_HANDOFF_QUOTA_JSON:-}" ]; then
    cat "$FM_HANDOFF_QUOTA_JSON"
    return $?
  fi
  quota_cmd=${FM_HANDOFF_QUOTA_AXI:-quota-axi}
  command -v "$quota_cmd" >/dev/null 2>&1 || return 1
  "$quota_cmd" --json
}

# Print min general-window percentRemaining for a primary profile, or "na".
fm_handoff_min_remaining_for_profile() {
  local profile=$1 provider quota
  profile=$(fm_handoff_normalize_profile "$profile") || { printf 'na\n'; return 0; }
  provider=$(fm_handoff_profile_provider "$profile")
  [ -n "$provider" ] || { printf 'na\n'; return 0; }
  quota=$(fm_handoff_quota_json) || { printf 'na\n'; return 0; }
  printf '%s\n' "$quota" | jq -r --arg p "$provider" '
    def general_ids:
      if $p == "claude" then ["five_hour","seven_day"]
      elif $p == "codex" then ["five_hour","weekly"]
      elif $p == "grok" then ["five_hour","weekly"]
      else []
      end;
    ([.providers[]? | select(.provider == $p) | .windows[]? as $window
      | select(((general_ids | index($window.id)) != null)
        and (($window.kind? // "") != "model")
        and (($window.percentRemaining? | type) == "number"))
      | $window.percentRemaining] | if length == 0 then "na" else min end)
  ' 2>/dev/null || printf 'na\n'
}

fm_handoff_over_threshold() {
  local profile=$1 threshold=${2:-$FM_HANDOFF_THRESHOLD} remaining
  remaining=$(fm_handoff_min_remaining_for_profile "$profile")
  case "$remaining" in
    na|'') return 1 ;;
    *) awk -v r="$remaining" -v t="$threshold" 'BEGIN { exit ((r + 0 <= t + 0) ? 0 : 1) }' ;;
  esac
}

fm_handoff_next_profile() {
  local current=$1 chain_json=${2:-$FM_HANDOFF_CHAIN_JSON} found=0 entry norm cli
  current=$(fm_handoff_normalize_profile "$current") || return 1
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    norm=$(fm_handoff_normalize_profile "$entry") || continue
    if [ "$found" -eq 0 ]; then
      [ "$norm" = "$current" ] && found=1
      continue
    fi
    cli=$(fm_handoff_profile_cli "$norm") || continue
    if [ "${FM_HANDOFF_SKIP_CLI_CHECK:-0}" = 1 ] || command -v "$cli" >/dev/null 2>&1; then
      printf '%s\n' "$norm"
      return 0
    fi
    fm_handoff_log "skipping chain profile $norm: '$cli' not on PATH"
  done < <(printf '%s\n' "$chain_json" | jq -r '.[]' 2>/dev/null)
  return 1
}

fm_handoff_flush_durable() {
  # Serialize against wake-queue appends, then release. Durable backlog/meta
  # records are already on disk; this is the explicit flush gate.
  # shellcheck source=bin/fm-wake-lib.sh
  . "$FM_ROOT/bin/fm-wake-lib.sh"
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  if [ "${FM_HANDOFF_INJECT_FAIL:-}" = flush ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    fm_handoff_die "injected failure at flush"
    return 1
  fi
  # Touch a flush marker so tests and operators can see the gate ran.
  : > "$STATE/.primary-handoff.flush"
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return 0
}

fm_handoff_signal_outgoing() {
  local pid=$1
  if [ "${FM_HANDOFF_INJECT_FAIL:-}" = signal ]; then
    fm_handoff_die "injected failure at signal"
    return 1
  fi
  if [ -n "${FM_HANDOFF_SIGNAL_CMD:-}" ]; then
    # Intentional word-splitting: test seams may pass a shell function name.
    # shellcheck disable=SC2086
    $FM_HANDOFF_SIGNAL_CMD "$pid"
    return $?
  fi
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -TERM "$pid" 2>/dev/null || true
  return 0
}

fm_handoff_wait_outgoing_dead() {
  local pid=$1
  local budget=${FM_HANDOFF_WAIT_DEAD_SECS:-30}
  local i=0
  if [ "${FM_HANDOFF_INJECT_FAIL:-}" = wait_dead ]; then
    fm_handoff_die "injected failure at wait_dead"
    return 1
  fi
  if [ -n "${FM_HANDOFF_WAIT_DEAD_CMD:-}" ]; then
    # shellcheck disable=SC2086
    $FM_HANDOFF_WAIT_DEAD_CMD "$pid"
    return $?
  fi
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  while [ "$i" -lt "$budget" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    # Still alive but no longer a harness counts as released for lock purposes.
    if ! FM_HOME="$FM_HOME" "$FM_ROOT/bin/fm-lock.sh" status 2>/dev/null | grep -q "held by live harness pid $pid"; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  fm_handoff_die "outgoing harness pid $pid still live after ${budget}s"
  return 1
}

fm_handoff_release_session_lock_stale() {
  if [ "${FM_HANDOFF_INJECT_FAIL:-}" = release ]; then
    fm_handoff_die "injected failure at release"
    return 1
  fi
  FM_HOME="$FM_HOME" "$FM_ROOT/bin/fm-lock.sh" release-stale
}

fm_handoff_launch_incoming() {
  local profile=$1
  if [ "${FM_HANDOFF_INJECT_FAIL:-}" = pre_launch ]; then
    fm_handoff_die "injected failure at pre_launch"
    return 1
  fi
  fm_handoff_assert_never_two_live_holders --require-free || return 1
  if [ "${FM_HANDOFF_INJECT_FAIL:-}" = launch ]; then
    fm_handoff_die "injected failure at launch"
    return 1
  fi
  if [ -n "${FM_HANDOFF_LAUNCH_CMD:-}" ]; then
    # Redirect stdio so a backgrounded incoming process cannot keep a caller's
    # command-substitution pipe open after this script exits.
    # shellcheck disable=SC2086
    $FM_HANDOFF_LAUNCH_CMD "$profile" </dev/null >/dev/null 2>&1
    return $?
  fi
  if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
    tmux new-window -d -n "FIRSTMATE" \
      "cd $(printf '%q' "$FM_ROOT") && env FM_HOME=$(printf '%q' "$FM_HOME") $(printf '%q' "$FM_ROOT/bin/fm-primary.sh") $(printf '%q' "$profile")" \
      </dev/null >/dev/null 2>&1
    return $?
  fi
  fm_handoff_die "no launch seam: set FM_HANDOFF_LAUNCH_CMD or run inside tmux"
  return 1
}

fm_handoff_in_cooldown() {
  local path phase cooldown_until now
  path=$(fm_handoff_state_path)
  [ -f "$path" ] || return 1
  phase=$(awk -F= '$1 == "phase" { print $2; exit }' "$path")
  cooldown_until=$(awk -F= '$1 == "cooldown_until" { print $2; exit }' "$path")
  [ "$phase" = complete ] || return 1
  case "$cooldown_until" in ''|*[!0-9]*) return 1 ;; esac
  now=$(fm_handoff_now)
  [ "$now" -lt "$cooldown_until" ]
}
