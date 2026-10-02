#!/usr/bin/env bash
# Shared primary-orchestrator handoff helpers.
# Sourced by bin/fm-primary-handoff.sh and tests, and executed directly by
# bin/fm-lock.sh for the release-stale subcommand the handoff needs.
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

# Durable context-window sample written by fm-status-bar.sh so the handoff
# supervisor can evaluate the context axis out-of-band from the live pane.
fm_handoff_context_path() {
  printf '%s\n' "$STATE/.primary-context"
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
#
# Dual trigger axes (both opt-in under enabled:true):
#   threshold_percent_remaining  - quota remaining; absent defaults to 15
#   threshold_context_percent_used - context USED percent; absent/null disables
#     the context axis entirely (quota-only behavior, as before this axis existed)
fm_handoff_load_config() {
  local path json ctx_raw
  path=$(fm_handoff_config_path)
  # Intentional globals consumed by fm-primary-handoff.sh.
  FM_HANDOFF_MODE=disabled
  FM_HANDOFF_THRESHOLD=15
  FM_HANDOFF_CONTEXT_USED_THRESHOLD=
  FM_HANDOFF_POLL_SECONDS=60
  FM_HANDOFF_COOLDOWN_SECONDS=300
  FM_HANDOFF_CHAIN_JSON='[]'
  export FM_HANDOFF_MODE FM_HANDOFF_THRESHOLD FM_HANDOFF_CONTEXT_USED_THRESHOLD \
    FM_HANDOFF_POLL_SECONDS FM_HANDOFF_COOLDOWN_SECONDS FM_HANDOFF_CHAIN_JSON
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
  # Context axis: absent or null means disabled. Explicit 0 is valid (always fire).
  ctx_raw=$(printf '%s\n' "$json" | jq -r '
    if (.threshold_context_percent_used | type) == "number"
      then (.threshold_context_percent_used | floor | tostring)
      elif (.threshold_context_percent_used | type) == "string"
        and (.threshold_context_percent_used | test("^[0-9]+$"))
      then .threshold_context_percent_used
      else ""
      end
  ')
  FM_HANDOFF_CONTEXT_USED_THRESHOLD=$ctx_raw
  FM_HANDOFF_CHAIN_JSON=$(printf '%s\n' "$json" | jq -c '
    (.chain // ["claude-fable","claude-opus","pi","codex"])
    | if type == "array" and length > 0 then . else empty end
  ' 2>/dev/null) || {
    fm_handoff_log "invalid config/primary-handoff: chain must be a non-empty array"
    return 1
  }
  case "$FM_HANDOFF_THRESHOLD" in ''|*[!0-9]*) FM_HANDOFF_THRESHOLD=15 ;; esac
  case "$FM_HANDOFF_CONTEXT_USED_THRESHOLD" in
    ''|*[!0-9]*) FM_HANDOFF_CONTEXT_USED_THRESHOLD= ;;
    *)
      if [ "$FM_HANDOFF_CONTEXT_USED_THRESHOLD" -gt 100 ]; then
        FM_HANDOFF_CONTEXT_USED_THRESHOLD=100
      fi
      ;;
  esac
  case "$FM_HANDOFF_POLL_SECONDS" in ''|*[!0-9]*) FM_HANDOFF_POLL_SECONDS=60 ;; esac
  case "$FM_HANDOFF_COOLDOWN_SECONDS" in ''|*[!0-9]*) FM_HANDOFF_COOLDOWN_SECONDS=300 ;; esac
  export FM_HANDOFF_MODE FM_HANDOFF_THRESHOLD FM_HANDOFF_CONTEXT_USED_THRESHOLD \
    FM_HANDOFF_POLL_SECONDS FM_HANDOFF_COOLDOWN_SECONDS FM_HANDOFF_CHAIN_JSON
  return 0
}

fm_handoff_normalize_profile() {
  case "$1" in
    claude) printf 'claude-fable\n' ;;
    opus) printf 'claude-opus\n' ;;
    cursor) printf 'cursor-grok\n' ;;
    pi|claude-fable|claude-opus|codex|astra|opencode|grok|cursor-grok|cursor-grok45) printf '%s\n' "$1" ;;
    *) return 1 ;;
  esac
}

fm_handoff_profile_cli() {
  case "$1" in
    pi) printf 'pi\n' ;;
    claude-fable|claude-opus) printf 'claude\n' ;;
    codex|astra) printf 'codex\n' ;;
    opencode) printf 'opencode\n' ;;
    grok) printf 'grok\n' ;;
    cursor-grok|cursor-grok45) printf 'agent\n' ;;
    *) return 1 ;;
  esac
}

# Map a primary profile onto the quota-axi provider whose general account
# windows bound it. An empty result means the profile is unmonitored on the
# quota axis. cursor-grok runs on the cursor account, whose plan windows
# bound every model it routes to. A provider whose general window ids the
# producer stops reporting degrades to `na`, the same as an unmonitored
# profile, rather than reading a narrower window as an account bound; only
# the profile's own model window (fm_handoff_profile_model_window) still reads.
fm_handoff_profile_provider() {
  case "$1" in
    claude|claude-fable|claude-opus|opus) printf 'claude\n' ;;
    codex|astra) printf 'codex\n' ;;
    grok) printf 'grok\n' ;;
    cursor|cursor-grok|cursor-grok45) printf 'cursor\n' ;;
    *) printf '\n' ;;
  esac
}

# Map a primary profile onto the one quota-axi model window that bounds it
# beyond its provider's general windows. An empty result means only the
# general windows apply. claude-fable is additionally bounded by the Fable
# weekly window, so its exhaustion rotates to claude-opus, which is not.
fm_handoff_profile_model_window() {
  case "$1" in
    claude-fable) printf 'model:fable\n' ;;
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
          schema|phase|from|to|reason|token|outgoing_pid|outgoing_identity|shutdown_requested|incoming_pid|identity|started_at|updated_at|error|profile|pid|completed_at|cooldown_until|trigger|remaining_percent|used_percent)
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
    "trigger=${trigger:-}" \
    "token=${token:-}" \
    "outgoing_pid=${outgoing_pid:-}" \
    "outgoing_identity=${outgoing_identity:-}" \
    "shutdown_requested=${shutdown_requested:-}" \
    "incoming_pid=${incoming_pid:-}" \
    "started_at=${started_at:-}" \
    "updated_at=$updated" \
    "error=${error:-}" \
    "completed_at=${completed_at:-}" \
    "cooldown_until=${cooldown_until:-}" || return 1
  if [ "${FM_HANDOFF_INJECT_CRASH:-}" = "${phase:-}" ]; then
    local current
    fm_current_pid current || return 1
    kill -KILL "$current"
  fi
}

fm_handoff_read_record() {
  local path
  path=$(fm_handoff_state_path)
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
  fm_handoff_read_kv_file "$path"
}

# Persist a context-window sample for the handoff supervisor.
# Callers pass remaining_percent (0-100); used_percent is derived as 100 - remaining.
# The status bar displays used % and derives remaining as 100 - used before calling.
# Best-effort: never fails the caller (status-bar render must stay inert-safe).
fm_handoff_write_context_sample() {
  local remaining=$1 path now used
  path=$(fm_handoff_context_path)
  case "$remaining" in
    ''|--|*[!0-9]*) return 0 ;;
  esac
  if [ "$remaining" -gt 100 ]; then
    remaining=100
  fi
  used=$((100 - remaining))
  now=$(fm_handoff_now)
  mkdir -p "$(dirname -- "$path")" 2>/dev/null || return 0
  fm_handoff_write_kv_file "$path" \
    "schema=fm-primary-context.v1" \
    "remaining_percent=$remaining" \
    "used_percent=$used" \
    "updated_at=$now" 2>/dev/null || return 0
  return 0
}

# Print used_percent from the durable sample, or "na".
fm_handoff_context_used_percent() {
  local path used
  if [ -n "${FM_HANDOFF_CONTEXT_USED:-}" ]; then
    printf '%s\n' "$FM_HANDOFF_CONTEXT_USED"
    return 0
  fi
  path=$(fm_handoff_context_path)
  [ -f "$path" ] || { printf 'na\n'; return 0; }
  used=$(awk -F= '$1 == "used_percent" { print $2; exit }' "$path")
  case "$used" in
    ''|*[!0-9]*) printf 'na\n' ;;
    *) printf '%s\n' "$used" ;;
  esac
}

# Return 0 when context USED is at or above the configured threshold.
# Disabled (empty threshold) or missing sample => not over threshold.
fm_handoff_context_over_threshold() {
  local threshold=${1:-$FM_HANDOFF_CONTEXT_USED_THRESHOLD} used
  case "$threshold" in ''|*[!0-9]*) return 1 ;; esac
  used=$(fm_handoff_context_used_percent)
  case "$used" in
    na|'') return 1 ;;
    *) awk -v u="$used" -v t="$threshold" 'BEGIN { exit ((u + 0 >= t + 0) ? 0 : 1) }' ;;
  esac
}

# The canonical contract owns away posture; the legacy flag also covers quiet.
fm_handoff_afk_active() (
  # Imported globals stay in this subshell; the script is its own lint root.
  # shellcheck source=/dev/null
  . "${BASH_SOURCE%/*}/fm-afk-contract.sh"
  fm_afk_contract_present "$STATE" || [ -e "$STATE/.afk" ]
)

# True when a prior handoff record is mid-flight (not terminal).
fm_handoff_rotation_in_progress() {
  local path phase
  path=$(fm_handoff_state_path)
  [ -f "$path" ] || return 1
  phase=$(awk -F= '$1 == "phase" { print $2; exit }' "$path")
  case "$phase" in
    planning|flushing|releasing|launching) return 0 ;;
    *) return 1 ;;
  esac
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

# Print min percentRemaining over a primary profile's general windows and its
# own model window, or "na".
fm_handoff_min_remaining_for_profile() {
  local profile=$1 provider model_window quota
  profile=$(fm_handoff_normalize_profile "$profile") || { printf 'na\n'; return 0; }
  provider=$(fm_handoff_profile_provider "$profile")
  [ -n "$provider" ] || { printf 'na\n'; return 0; }
  model_window=$(fm_handoff_profile_model_window "$profile")
  quota=$(fm_handoff_quota_json) || { printf 'na\n'; return 0; }
  printf '%s\n' "$quota" | jq -r --arg p "$provider" --arg m "$model_window" '
    def general_ids:
      if $p == "claude" then ["five_hour","seven_day"]
      elif $p == "codex" then ["five_hour","weekly"]
      elif $p == "grok" then ["five_hour","weekly"]
      elif $p == "cursor" then ["included_usage","auto_usage"]
      else []
      end;
    ([.providers[]? | select(.provider == $p) | .windows[]? as $window
      | select(((((general_ids | index($window.id)) != null)
          and (($window.kind? // "") != "model"))
        or ($m != "" and $window.id == $m))
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

# Run the same non-mutating gates as a real primary launch, including explicit
# --to profiles. Custom runtime routes must supply their own preflight command.
fm_handoff_preflight() {
  local profile=$1 launch_cli _ignored
  if [ -n "${FM_HANDOFF_LAUNCH_CMD:-}" ]; then
    read -r launch_cli _ignored <<< "$FM_HANDOFF_LAUNCH_CMD"
    command -v "$launch_cli" >/dev/null 2>&1 || {
      fm_handoff_die "custom launch command unavailable: $launch_cli"
      return 1
    }
    [ -n "${FM_HANDOFF_PREFLIGHT_CMD:-}" ] || {
      fm_handoff_die "custom launch route requires FM_HANDOFF_PREFLIGHT_CMD"
      return 1
    }
    # shellcheck disable=SC2086
    $FM_HANDOFF_PREFLIGHT_CMD "$profile" || return 1
  else
    if [ -z "${TMUX:-}" ] || ! command -v tmux >/dev/null 2>&1 \
      || ! tmux display-message -p '#S' >/dev/null 2>&1; then
      fm_handoff_die "no launch route: set FM_HANDOFF_LAUNCH_CMD or run inside tmux"
      return 1
    fi
  fi
  FM_HOME="$FM_HOME" "$FM_ROOT/bin/fm-primary.sh" "$profile" --preflight
}

fm_handoff_launch_lock() { # <token>
  case "${1:-}" in ''|*[!0-9-]*) return 1 ;; esac
  printf '%s/.primary-handoff-launch.%s.lock\n' "$STATE" "$1"
}

fm_handoff_launch_incoming() {
  local profile=$1
  case "${FM_HANDOFF_INJECT_FAIL:-}" in
    pre_launch|launch) fm_handoff_die "injected failure at ${FM_HANDOFF_INJECT_FAIL}"; return 1 ;;
  esac
  fm_handoff_assert_never_two_live_holders --require-free || return 1
  # A surviving launcher is already starting this generation. Its independent
  # lock survives a controller crash and stays held across the primary's exec.
  local launch_lock launch_pid
  launch_lock=$(fm_handoff_launch_lock "$token") || return 1
  launch_pid=$(cat "$launch_lock/pid" 2>/dev/null || true)
  if fm_pid_alive "$launch_pid"; then return 0; fi
  if [ -n "${FM_HANDOFF_LAUNCH_CMD:-}" ]; then
    "$FM_ROOT/bin/fm-primary-handoff.sh" launch "$token" "$profile" \
      </dev/null >/dev/null 2>&1 &
    return 0
  fi
  tmux new-window -d -n "FIRSTMATE" \
    "cd $(printf '%q' "$FM_ROOT") && env FM_HOME=$(printf '%q' "$FM_HOME") $(printf '%q' "$FM_ROOT/bin/fm-primary-handoff.sh") launch $(printf '%q' "$token") $(printf '%q' "$profile")" \
    </dev/null >/dev/null 2>&1
}

# Called by fm-lock only after verified acquisition, while .lock.acquire is held.
# This receipt binds a launch generation to an actual live session, including
# harnesses whose anchor PID differs from the launcher's exec PID.
fm_handoff_ack_acquired() { # <holder-pid>
  local holder=$1 identity
  if [ -z "${FM_HANDOFF_TOKEN:-}" ]; then
    rm -f "$STATE/.lock-handoff"
    return $?
  fi
  identity=$(fm_pid_identity "$holder") || return 1
  fm_handoff_write_kv_file "$STATE/.lock-handoff" \
    "token=$FM_HANDOFF_TOKEN" "profile=${FM_HANDOFF_PROFILE:-}" \
    "pid=$holder" "identity=$identity"
}

fm_handoff_incoming_acknowledged() {
  local expected_token=$token expected_profile=$to token='' profile='' pid='' identity=''
  fm_handoff_session_live_holder || return 1
  fm_handoff_read_kv_file "$STATE/.lock-handoff" || return 1
  [ -n "$expected_token" ] && [ "$token" = "$expected_token" ] \
    && [ "$profile" = "$expected_profile" ] \
    && [ "$pid" = "$FM_HANDOFF_LIVE_HOLDER_PID" ] \
    && [ "$pid" != "$outgoing_pid" ] && [ -n "$identity" ] || return 1
  fm_pid_identity_matches "$pid" "$identity" || return 1
  incoming_pid=$pid
}

fm_handoff_wait_incoming() {
  local deadline budget=${FM_HANDOFF_STARTUP_SECS:-60}
  case "$budget" in ''|*[!0-9]*) return 1 ;; esac
  deadline=$((SECONDS + budget))
  while :; do
    fm_handoff_incoming_acknowledged && return 0
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep 0.1
  done
  fm_handoff_die "incoming has not acknowledged session-lock ownership; recovery pending"
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

# Serialize the entire stale decision and both identity removals with normal
# acquisition. A subshell owns cleanup so sourced callers keep their traps.
fm_handoff_release_stale() ( # <lock-file>
  local lock=${1:-} old claim
  [ -n "$lock" ] || { echo "error: release-stale needs a lock path" >&2; return 2; }
  # Imported globals stay in this subshell; the library is its own lint root.
  # shellcheck source=/dev/null
  . "${BASH_SOURCE%/*}/fm-wake-lib.sh"
  claim="${lock%/*}/.lock.acquire"
  trap 'fm_lock_release "$claim"' EXIT
  trap 'exit 1' HUP INT TERM
  fm_lock_acquire_wait "$claim" || return 1
  if [ -e "$lock" ] || [ -L "$lock" ]; then
    [ -f "$lock" ] && [ ! -L "$lock" ] || {
      echo "error: session lock is not a regular file; refusing release" >&2
      return 1
    }
    old=$(cat "$lock") || return 1
    if fm_harness_holder_alive "$old"; then
      echo "error: refusing to release a live firstmate session lock (pid $old)" >&2
      return 1
    fi
    rm -f "$lock" || return 1
    echo "lock released: stale holder pid $old"
  else
    echo "lock: free"
  fi
  rm -f "${lock%/*}/.lock-session" "${lock%/*}/.lock-handoff"
)

# Executed, not sourced: bin/fm-lock.sh execs this file for release-stale. Every
# consumer that sources it gets the helpers above and nothing else.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _fm_handoff_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$_fm_handoff_dir/fm-primary-scope-lib.sh"
  case "${1:-}" in
    release-stale) shift; fm_handoff_release_stale "$@" ;;
    *)
      echo "usage: fm-primary-handoff-lib.sh release-stale <lock-file>" >&2
      exit 2
      ;;
  esac
  exit $?
fi

