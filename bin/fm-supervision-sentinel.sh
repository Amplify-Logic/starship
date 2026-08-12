#!/usr/bin/env bash
# Host-owned supervision-outage sentinel for one firstmate home.
#
# The watcher and away-mode daemon can both be reaped with their harness-hosted
# background task, so neither process can be the final detector of its own
# death. On macOS, `arm` registers this script as a home-scoped launchd agent.
# launchd invokes `scheduled-check` every FM_SENTINEL_INTERVAL_SECS (default 60), outside
# the harness process tree. A check uses the same in-flight count, watcher-lock
# identity, and beacon freshness predicates as the turn-end and continuity
# guards. It writes one durable outage marker and reuses config/wedge-alarm's
# active channels for a loud notification.
#
# This sentinel deliberately NEVER starts, stops, or signals a watcher or the
# away-mode daemon. A generic host process cannot safely recreate a harness
# completion notification or the daemon's supervisor-pane target. Automatic
# restart here could also race the existing singleton and away-mode ownership.
# The existing guarded recovery path remains human/agent-owned.
#
# Usage:
#   fm-supervision-sentinel.sh arm         Idempotently register unless deliberately disarmed.
#                                          Exits 0 only on a verified registration, 1 on a
#                                          retryable failure, 3 only on positive evidence that
#                                          this host lacks a capability the scheduled check needs
#                                          (so a long-lived caller can stop retrying the impossible
#                                          without ever inferring that from an ambiguous error),
#                                          and 4 on a deliberate no-op (a durably disarmed home,
#                                          FM_SUPERVISION_SENTINEL_MODE=off, or a non-primary
#                                          scope), which is neither protection nor a failure.
#   fm-supervision-sentinel.sh enable      Explicitly re-enable and register this home's agent.
#   fm-supervision-sentinel.sh disarm      Explicitly uninstall and durably mark this home disarmed.
#   fm-supervision-sentinel.sh check       Report one marker-only health verdict; never notify.
#                                          Exits 0 when healthy or idle, 1 on a detected outage.
#   fm-supervision-sentinel.sh note-outage Record an outage marker only; never notify, never print.
#
# `scheduled-check` is the launchd-only entry point. It alone records host-service
# liveness and crosses the external-alert boundary; every other mode is
# marker-only, returns promptly, and honors the durable disarm record.
#
# `note-outage` is the only mode an in-harness turn-end or continuity hook may
# use. Those hooks must render their blocking banner immediately, so they record
# durable evidence with local writes alone and never cross the active-channel
# boundary. External alert delivery belongs to the scheduled host check.
# `check` is the operator-facing diagnostic of the same predicates: it evaluates
# and refreshes the marker, clears it once the home is healthy again, and reports
# its verdict on stdout with a non-zero exit on a detected outage, but it never
# notifies and never forges host liveness. A suppressed launchd registration is
# reported there too, so the state that disables host monitoring is never silent.
#
# Environment:
#   FM_HOME                            Operational home (default: tracked root).
#   FM_ROOT_OVERRIDE                   Tracked code root override.
#   FM_STATE_OVERRIDE                  State directory override.
#   FM_CONFIG_OVERRIDE                 Alert configuration directory override.
#   FM_GUARD_GRACE                     Watcher-beacon grace seconds for THIS process
#                                      (default 300). The generated manifest always
#                                      pins the durable default, never this value.
#   FM_SUPERVISION_SENTINEL_MODE=off   Disable automatic registration and checks.
#   FM_SENTINEL_INTERVAL_SECS          launchd check interval (default 60, minimum 15).
#   FM_SENTINEL_REALARM_SECS           first repeat ALERT delay (default 300, minimum 60).
#   FM_SENTINEL_MAX_REALARM_SECS       exponential repeat-ALERT cap (default 3600, minimum 300).
#   FM_SENTINEL_ARM_RETRY_SECS         first launchd REGISTRATION retry delay (default 60, minimum 15).
#   FM_SENTINEL_ARM_RETRY_MAX_SECS     exponential registration-retry cap (default 3600, minimum 60).
#   FM_SENTINEL_CLAIM_LEASE_SECS       failed/in-progress delivery retry lease (default 30).
#   FM_SENTINEL_CHECK_WAIT_SECS        bounded wait for a registration's first scheduled check (default 15).
#   FM_SENTINEL_PLATFORM               uname override for tests.
#   FM_SENTINEL_LAUNCHCTL              launchctl path override for tests.
#   FM_SENTINEL_DOMAIN                 launchd domain override for tests.
#
# There is deliberately no notifier-override knob: the generated manifest never
# carries FM_WEDGE_ALARM_EXEC, so nothing can redirect this home's external alert
# delivery through the launchd job.
# End usage.
set -u

FM_SENTINEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_SENTINEL_DIR/.." && pwd -P)}"
FM_SENTINEL_ROOT_CANON=$(cd "$FM_ROOT" 2>/dev/null && pwd -P) || exit 1
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_SENTINEL_HOME_CANON=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || exit 1
FM_SENTINEL_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_SENTINEL_WATCH="$FM_SENTINEL_DIR/fm-watch.sh"
FM_SENTINEL_ALERT_OWNER="$FM_SENTINEL_DIR/fm-supervise-daemon.sh"
# The durable configured beacon grace. The generated manifest pins THIS value and
# never the ambient FM_GUARD_GRACE of whoever happened to run the arm, so service
# identity is a function of durable configuration alone: a one-off
# `FM_GUARD_GRACE=30 bin/fm-watch-arm.sh` can neither reconfigure the host check's
# outage threshold for every later scheduled run nor move the manifest digest and
# force a bootout/bootstrap on the next ordinary arm. An ambient value still
# applies to the evaluation this process performs, which is what a guard-invoked
# mode needs to match its caller's own grace.
FM_SENTINEL_DEFAULT_GRACE=300
FM_SENTINEL_GRACE=${FM_GUARD_GRACE:-$FM_SENTINEL_DEFAULT_GRACE}
FM_SENTINEL_INTERVAL=${FM_SENTINEL_INTERVAL_SECS:-60}
FM_SENTINEL_REALARM=${FM_SENTINEL_REALARM_SECS:-300}
FM_SENTINEL_MAX_REALARM=${FM_SENTINEL_MAX_REALARM_SECS:-3600}
FM_SENTINEL_ARM_RETRY=${FM_SENTINEL_ARM_RETRY_SECS:-60}
FM_SENTINEL_ARM_RETRY_MAX=${FM_SENTINEL_ARM_RETRY_MAX_SECS:-3600}
FM_SENTINEL_CLAIM_LEASE=${FM_SENTINEL_CLAIM_LEASE_SECS:-30}
FM_SENTINEL_CHECK_WAIT=${FM_SENTINEL_CHECK_WAIT_SECS:-15}
FM_SENTINEL_JOB_PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin

# shellcheck source=bin/fm-supervision-lib.sh
. "$FM_SENTINEL_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$FM_SENTINEL_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$FM_SENTINEL_DIR/fm-wake-lib.sh"

FM_SENTINEL_STATE=$(cd "$FM_SENTINEL_STATE" 2>/dev/null && pwd -P) || exit 1
FM_SENTINEL_MARKER="$FM_SENTINEL_STATE/.supervision-outage-alarm"
FM_SENTINEL_ARM_LOCK="$FM_SENTINEL_STATE/.supervision-sentinel-arm.lock"
FM_SENTINEL_CHECK_LOCK="$FM_SENTINEL_STATE/.supervision-sentinel-check.lock"
FM_SENTINEL_PLIST="$FM_SENTINEL_STATE/.supervision-sentinel.plist"
FM_SENTINEL_LOADED_DIGEST="$FM_SENTINEL_STATE/.supervision-sentinel.loaded-digest"
FM_SENTINEL_LAST_CHECK="$FM_SENTINEL_STATE/.supervision-sentinel-last-check"
FM_SENTINEL_DISARMED="$FM_SENTINEL_STATE/$FM_SUP_DISARM_RECORD_NAME"
FM_SENTINEL_ARM_FAILURE="$FM_SENTINEL_STATE/$FM_SUP_ARM_RECORD_NAME"
FM_SENTINEL_CLAIM_TOKEN=
FM_SENTINEL_FORCE_ARM=0

fm_sentinel_usage() {
  awk '
    /^# Usage:/ { printing = 1 }
    /^# End usage\./ { exit }
    printing { sub(/^# ?/, ""); print }
  ' "$0"
}

fm_sentinel_mode_enabled() {
  case "${FM_SUPERVISION_SENTINEL_MODE:-auto}" in
    off|false|0|disabled) return 1 ;;
    *) return 0 ;;
  esac
}

fm_sentinel_positive_integer() { # <value> <fallback> [minimum]
  local value=$1 fallback=$2 minimum=${3:-1}
  case "$value" in
    ''|*[!0-9]*) printf '%s\n' "$fallback" ;;
    *)
      if [ "$value" -lt "$minimum" ]; then
        printf '%s\n' "$fallback"
      else
        printf '%s\n' "$value"
      fi
      ;;
  esac
}

fm_sentinel_normalize_tunables() {
  FM_SENTINEL_GRACE=$(fm_sentinel_positive_integer "$FM_SENTINEL_GRACE" "$FM_SENTINEL_DEFAULT_GRACE" 1)
  FM_SENTINEL_REALARM=$(fm_sentinel_positive_integer "$FM_SENTINEL_REALARM" 300 60)
  FM_SENTINEL_MAX_REALARM=$(fm_sentinel_positive_integer "$FM_SENTINEL_MAX_REALARM" 3600 300)
  [ "$FM_SENTINEL_MAX_REALARM" -ge "$FM_SENTINEL_REALARM" ] || FM_SENTINEL_MAX_REALARM=$FM_SENTINEL_REALARM
  # Registration retry has its own bounds. Reusing the repeat-ALERT tunables meant
  # a captain who asked for faster outage reminders also silently shortened the
  # launchd retry cooldown, and vice versa: two unrelated schedules, one knob.
  FM_SENTINEL_ARM_RETRY=$(fm_sentinel_positive_integer "$FM_SENTINEL_ARM_RETRY" 60 15)
  FM_SENTINEL_ARM_RETRY_MAX=$(fm_sentinel_positive_integer "$FM_SENTINEL_ARM_RETRY_MAX" 3600 60)
  [ "$FM_SENTINEL_ARM_RETRY_MAX" -ge "$FM_SENTINEL_ARM_RETRY" ] || FM_SENTINEL_ARM_RETRY_MAX=$FM_SENTINEL_ARM_RETRY
  FM_SENTINEL_CLAIM_LEASE=$(fm_sentinel_positive_integer "$FM_SENTINEL_CLAIM_LEASE" 30 1)
  FM_SENTINEL_CHECK_WAIT=$(fm_sentinel_positive_integer "$FM_SENTINEL_CHECK_WAIT" 15 1)
}

fm_sentinel_xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

fm_sentinel_label() {
  local hash
  [ -x /usr/bin/shasum ] || return 1
  hash=$(printf '%s\t%s' "$FM_SENTINEL_HOME_CANON" "$FM_SENTINEL_STATE" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}') || return 1
  [ -n "$hash" ] || return 1
  printf 'works.earendil.firstmate.supervision-sentinel-v1.%s\n' "$hash"
}

fm_sentinel_plist_digest() {
  [ -x /usr/bin/shasum ] || return 1
  /usr/bin/shasum -a 256 "$FM_SENTINEL_PLIST" | /usr/bin/awk '{print $1}'
}

fm_sentinel_check_recent() { # <max-age-seconds>
  [ "$(fm_path_age "$FM_SENTINEL_LAST_CHECK")" -le "$1" ]
}

# The only positive evidence a caller that never held the arm lock may act on:
# launchd is holding this exact service AND a scheduled check has completed for
# this home recently enough to prove the service can observe it.
fm_sentinel_service_verified() { # <launchctl> <service> <max-check-age>
  "$1" print "$2" >/dev/null 2>&1 || return 1
  fm_sentinel_check_recent "$3"
}

# Names the concrete evidence that is missing when a contended arm never observed
# a verified service. A caller that cannot register must never report success, and
# must not report a bare failure either: whichever half of the proof is absent is
# what an operator has to repair.
fm_sentinel_report_unverified_service() { # <launchctl> <service> <max-check-age>
  local launchctl=$1 service=$2 max_age=$3
  if ! "$launchctl" print "$service" >/dev/null 2>&1; then
    printf 'supervision sentinel: another arm for this home held the registration lock without publishing a service, and launchd is not holding %s; host outage monitoring is NOT active. Run %s enable\n' \
      "$service" "$FM_SENTINEL_DIR/fm-supervision-sentinel.sh" >&2
    return 0
  fi
  printf 'supervision sentinel: another arm for this home held the registration lock; launchd is holding %s but no scheduled check has completed in the last %ss, so host outage monitoring is UNVERIFIED. Run %s enable\n' \
    "$service" "$max_age" "$FM_SENTINEL_DIR/fm-supervision-sentinel.sh" >&2
}

# Bounded wait for launchd to complete one scheduled one-shot check. It polls the
# recorded proof rather than launchctl's own state, because only a completed check
# shows the host service can actually observe this home. The deadline is computed
# once so a failed wait costs a few forks per poll instead of per 50ms tick.
fm_sentinel_wait_for_check() {
  local deadline
  deadline=$(( $(date +%s) + FM_SENTINEL_CHECK_WAIT ))
  while :; do
    fm_sentinel_check_recent 10 && return 0
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 0.2
  done
}

# Names the one host capability this sentinel needs and does not have, or exits
# non-zero when the host can run the scheduled check at all. One place decides what
# "unsupported" means, so the arm's exit status, the operator diagnostic, and the
# away-mode ledger can never disagree about it.
#
# Every branch is POSITIVE evidence of an absent capability, never a failed
# attempt: an ambiguous error must stay transient, because a caller that stops
# retrying on ambiguity abandons a backstop that would have recovered on its own.
fm_sentinel_missing_capability() {
  local platform=${FM_SENTINEL_PLATFORM:-$(uname)} launchctl
  if [ "$platform" != Darwin ]; then
    printf 'this host runs %s and has no verified host scheduler for the sentinel (launchd is macOS-only)\n' "$platform"
    return 0
  fi
  launchctl=$(fm_sentinel_launchctl)
  if [ ! -x "$launchctl" ]; then
    printf 'launchctl is missing at %s, so this host cannot register a scheduled check\n' "$launchctl"
    return 0
  fi
  if [ ! -x /usr/bin/shasum ]; then
    printf '/usr/bin/shasum is missing, so this host cannot derive a stable per-home service identity\n'
    return 0
  fi
  return 1
}

# One stdout line naming a missing host capability, on the diagnostic's verdict
# channel. Silent on a host that can run the scheduled check. An OK supervision
# verdict states that this home's watcher is alive; it must never be read as
# promising a host-level backstop the host cannot provide.
fm_sentinel_report_host_capability() {
  local missing
  missing=$(fm_sentinel_missing_capability) || return 0
  printf 'supervision sentinel: NOTE - %s, so host-level outage alarms are UNAVAILABLE here and only the in-session turn-end and continuity guards apply\n' \
    "$missing"
}

fm_sentinel_domain() {
  printf '%s\n' "${FM_SENTINEL_DOMAIN:-gui/$(id -u)}"
}

fm_sentinel_launchctl() {
  printf '%s\n' "${FM_SENTINEL_LAUNCHCTL:-/bin/launchctl}"
}

fm_sentinel_plist_env() { # <key> <value>
  printf '      <key>%s</key>\n      <string>%s</string>\n' \
    "$(fm_sentinel_xml_escape "$1")" "$(fm_sentinel_xml_escape "$2")"
}

fm_sentinel_write_plist() { # <label> <interval>
  local label=$1 interval=$2 pending
  pending=$(mktemp "$FM_SENTINEL_STATE/.supervision-sentinel.plist.XXXXXX") || return 1
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
    printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    printf '%s\n' '<plist version="1.0">' '<dict>'
    printf '  <key>Label</key>\n  <string>%s</string>\n' "$(fm_sentinel_xml_escape "$label")"
    printf '%s\n' '  <key>ProgramArguments</key>' '  <array>'
    printf '    <string>%s</string>\n' "$(fm_sentinel_xml_escape "$FM_SENTINEL_DIR/fm-supervision-sentinel.sh")"
    printf '%s\n' '    <string>scheduled-check</string>' '  </array>'
    printf '%s\n' '  <key>EnvironmentVariables</key>' '  <dict>'
    fm_sentinel_plist_env FM_HOME "$FM_SENTINEL_HOME_CANON"
    fm_sentinel_plist_env FM_ROOT_OVERRIDE "$FM_SENTINEL_ROOT_CANON"
    fm_sentinel_plist_env FM_GUARD_GRACE "$FM_SENTINEL_DEFAULT_GRACE"
    fm_sentinel_plist_env FM_SENTINEL_INTERVAL_SECS "$interval"
    fm_sentinel_plist_env FM_SENTINEL_REALARM_SECS "$FM_SENTINEL_REALARM"
    fm_sentinel_plist_env FM_SENTINEL_MAX_REALARM_SECS "$FM_SENTINEL_MAX_REALARM"
    fm_sentinel_plist_env FM_SENTINEL_CLAIM_LEASE_SECS "$FM_SENTINEL_CLAIM_LEASE"
    fm_sentinel_plist_env PATH "$FM_SENTINEL_JOB_PATH"
    if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
      fm_sentinel_plist_env FM_STATE_OVERRIDE "$FM_SENTINEL_STATE"
    fi
    if [ -n "${FM_CONFIG_OVERRIDE:-}" ]; then
      fm_sentinel_plist_env FM_CONFIG_OVERRIDE "$FM_CONFIG_OVERRIDE"
    fi
    # No notifier-override knob belongs here. FM_WEDGE_ALARM_EXEC replaces EVERY
    # channel before any real notifier, so a manifest that carried one would
    # redirect this home's whole external-alert path for as long as the service
    # stays loaded; an override that exits non-zero would leave delivery pending
    # and retry silently forever, which is the exact failure this sentinel exists
    # to prevent. A test that needs to intercept delivery runs its own copy of
    # this script beside a stub alert owner instead.
    printf '%s\n' '  </dict>'
    printf '%s\n' '  <key>RunAtLoad</key>' '  <true/>'
    printf '  <key>StartInterval</key>\n  <integer>%s</integer>\n' "$interval"
    printf '%s\n' '  <key>ProcessType</key>' '  <string>Background</string>'
    printf '%s\n' '</dict>' '</plist>'
  } > "$pending" || { rm -f "$pending"; return 1; }
  chmod 600 "$pending" || { rm -f "$pending"; return 1; }
  mv -f "$pending" "$FM_SENTINEL_PLIST"
}

# Records one more consecutive registration failure and the deadline before this
# home may pay for another launchd bootout/bootstrap plus its bounded liveness
# wait.
#
# A host whose launchd service is retained but never completes a scheduled check
# (no `git` on the pinned job PATH, a home that became a linked worktree, a
# broken state volume) can never converge. Without this cooldown, every watcher
# and away-mode entry paid a full bootout plus bootstrap plus a bounded wait and
# churned the service forever. The cooldown never claims monitoring is healthy:
# the caller still fails, the warning still says the alarm is unavailable, and
# every later session start reports the suppressed state until it is repaired.
#
# The deadline and its validity bound are written together here and read back
# through the shared reader in fm-supervision-lib.sh, so the schedule lives in
# exactly one place and the session-start banner cannot drift from what the arm
# path actually enforces.
fm_sentinel_record_arm_failure() { # <service>
  local service=$1 failures delay now pending
  fm_supervision_arm_failure_status "$FM_SENTINEL_STATE"
  failures=$((FM_SUP_ARM_FAILURES + 1))
  now=$(date +%s)
  delay=$(fm_sentinel_backoff_delay "$failures" "$FM_SENTINEL_ARM_RETRY" "$FM_SENTINEL_ARM_RETRY_MAX")
  pending=$(mktemp "$FM_SENTINEL_ARM_FAILURE.XXXXXX") || return 1
  {
    printf 'state=arm-failed\n'
    printf 'failures=%s\n' "$failures"
    printf 'failed_at=%s\n' "$now"
    printf 'retry_after_secs=%s\n' "$delay"
    printf 'retry_at=%s\n' "$((now + delay))"
    printf 'home=%s\n' "$FM_SENTINEL_HOME_CANON"
    printf 'service=%s\n' "$service"
    printf 'recover=%s enable\n' "$FM_SENTINEL_DIR/fm-supervision-sentinel.sh"
  } > "$pending" || { rm -f "$pending"; return 1; }
  chmod 600 "$pending" || { rm -f "$pending"; return 1; }
  mv -f "$pending" "$FM_SENTINEL_ARM_FAILURE"
}

# Cleared only where a scheduled host check has actually been observed: the
# converged fast path and a verified registration. An explicit `enable` bypasses
# the cooldown but must not erase the evidence before it earns that.
fm_sentinel_clear_arm_failure() {
  rm -f "$FM_SENTINEL_ARM_FAILURE" 2>/dev/null || true
}

# One stdout line describing a suppressed registration, on the same verdict
# channel the operator-facing diagnostic reports through. Silent when this home has
# no failure record.
fm_sentinel_report_arm_state() {
  fm_supervision_arm_failure_status "$FM_SENTINEL_STATE"
  [ "$FM_SUP_ARM_FAILED" = true ] || return 0
  printf 'supervision sentinel: WARNING - launchd registration for this home failed %s time(s), so host outage monitoring is NOT active' \
    "$FM_SUP_ARM_FAILURES"
  if [ "$FM_SUP_ARM_RETRY_IN" -gt 0 ]; then
    printf '; automatic retry is suppressed for another %ss' "$FM_SUP_ARM_RETRY_IN"
  elif [ "$FM_SUP_ARM_RETRY_STALE" = true ]; then
    printf '; its retry deadline is stale (unreadable or beyond its own recorded window) and suppresses nothing, so the next watcher or away-mode entry will try again'
  else
    printf '; the retry cooldown has expired and the next watcher or away-mode entry will try again'
  fi
  printf '. Run %s enable to retry now\n' "$FM_SENTINEL_DIR/fm-supervision-sentinel.sh"
}

# launchd transport body. Runs only while this home's arm lock is held, so it may
# return early anywhere: fm_sentinel_arm owns the single matching release.
fm_sentinel_register_service() { # <launchctl> <domain> <service> <digest> <loaded-digest>
  local launchctl=$1 domain=$2 service=$3 digest=$4 loaded_digest=$5 i rc=0
  if "$launchctl" print "$service" >/dev/null 2>&1; then
    "$launchctl" enable "$service" >/dev/null 2>&1 || true
    if [ "$loaded_digest" = "$digest" ]; then
      "$launchctl" kickstart "$service" >/dev/null 2>&1 || true
      fm_sentinel_wait_for_check && return 0
      printf 'supervision sentinel: loaded home service did not complete a check\n' >&2
      return 1
    fi
    # The tracked script path or launch settings changed. Reload only this exact
    # home service; never sweep launchd labels or supervision processes.
    "$launchctl" bootout "$service" >/dev/null 2>&1 || true
    i=0
    while [ "$i" -lt 40 ] && "$launchctl" print "$service" >/dev/null 2>&1; do
      sleep 0.05
      i=$((i + 1))
    done
    if "$launchctl" print "$service" >/dev/null 2>&1; then
      printf 'supervision sentinel: prior home service did not retire for a manifest reload\n' >&2
      return 1
    fi
  fi
  rm -f "$FM_SENTINEL_LAST_CHECK" 2>/dev/null || true
  "$launchctl" bootstrap "$domain" "$FM_SENTINEL_PLIST" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ] && ! "$launchctl" print "$service" >/dev/null 2>&1; then
    printf 'supervision sentinel: launchd registration failed for this home (exit %s)\n' "$rc" >&2
    return 1
  fi
  "$launchctl" enable "$service" >/dev/null 2>&1 || true
  if ! "$launchctl" print "$service" >/dev/null 2>&1; then
    printf 'supervision sentinel: launchd did not retain this home service\n' >&2
    return 1
  fi
  if ! fm_sentinel_wait_for_check; then
    printf 'supervision sentinel: launchd retained the home service but no check completed\n' >&2
    return 1
  fi
  return 0
}

# Registration body. Runs only while this home's arm lock is held, so it may
# return early anywhere: fm_sentinel_arm owns the single matching release.
fm_sentinel_arm_registration() { # <launchctl> <domain> <label> <service> <interval>
  local launchctl=$1 domain=$2 label=$3 service=$4 interval=$5 digest loaded_digest pending rc
  if ! fm_sentinel_write_plist "$label" "$interval"; then
    printf 'supervision sentinel: could not write %s\n' "$FM_SENTINEL_PLIST" >&2
    fm_sentinel_record_arm_failure "$service" || true
    return 1
  fi
  digest=$(fm_sentinel_plist_digest) || { fm_sentinel_record_arm_failure "$service" || true; return 1; }
  loaded_digest=$(cat "$FM_SENTINEL_LOADED_DIGEST" 2>/dev/null || true)
  # Converged: this exact service is loaded on the current manifest and a
  # scheduled one-shot check landed recently. That is the only state that proves
  # host monitoring works, and it costs no launchd mutation, so a healthy home
  # never consults the failure cooldown below.
  if [ "$loaded_digest" = "$digest" ] \
    && fm_sentinel_service_verified "$launchctl" "$service" $((interval * 2 + 15)); then
    "$launchctl" enable "$service" >/dev/null 2>&1 || true
    fm_sentinel_clear_arm_failure
    return 0
  fi
  # An explicit `enable` is the documented recovery action, so it bypasses the
  # cooldown. It deliberately does NOT erase the record here: only a verified
  # registration below may do that, so a failed enable keeps the evidence and its
  # escalating count instead of resetting to a fresh first failure.
  fm_supervision_arm_failure_status "$FM_SENTINEL_STATE"
  if [ "$FM_SUP_ARM_RETRY_IN" -gt 0 ] && [ "$FM_SENTINEL_FORCE_ARM" -ne 1 ]; then
    printf 'supervision sentinel: host registration for this home failed %s time(s); no launchd retry for %ss and host outage monitoring is NOT active. Fix launchd, then run %s enable\n' \
      "$FM_SUP_ARM_FAILURES" "$FM_SUP_ARM_RETRY_IN" "$FM_SENTINEL_DIR/fm-supervision-sentinel.sh" >&2
    return 1
  fi
  fm_sentinel_register_service "$launchctl" "$domain" "$service" "$digest" "$loaded_digest"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    fm_sentinel_record_arm_failure "$service" || true
    return "$rc"
  fi
  pending="$FM_SENTINEL_LOADED_DIGEST.pending.$$"
  if ! printf '%s\n' "$digest" > "$pending" || ! mv -f "$pending" "$FM_SENTINEL_LOADED_DIGEST"; then
    rm -f "$pending"
    printf 'supervision sentinel: could not record the loaded manifest identity\n' >&2
    fm_sentinel_record_arm_failure "$service" || true
    return 1
  fi
  fm_sentinel_clear_arm_failure
  return 0
}

fm_sentinel_arm() {
  local missing launchctl label domain service interval max_check_age deadline rc
  fm_sentinel_mode_enabled || return "$FM_SUP_SENTINEL_NOOP_EXIT"
  # Primary scope first: a child task worktree or a non-primary home is a silent
  # no-op on every platform, so an unsupported host reports its real limitation
  # only where the sentinel would genuinely have been the outage backstop.
  fm_primary_scope_matches "$FM_ROOT" "$FM_SENTINEL_STATE" || return "$FM_SUP_SENTINEL_NOOP_EXIT"
  # A missing host capability exits with its own status so a long-lived caller can
  # stop retrying something that can never succeed, while every ambiguous failure
  # below keeps exit 1 and stays retryable.
  if missing=$(fm_sentinel_missing_capability); then
    printf 'supervision sentinel: %s, so host-level outage alarms are UNAVAILABLE here and only the in-session turn-end and continuity guards apply\n' \
      "$missing" >&2
    return "$FM_SUP_SENTINEL_UNSUPPORTED_EXIT"
  fi
  if [ -f "$FM_SENTINEL_DISARMED" ] && [ "$FM_SENTINEL_FORCE_ARM" -ne 1 ]; then
    printf 'supervision sentinel: deliberately disarmed for this home; run %s enable to restore host monitoring\n' "$0" >&2
    return "$FM_SUP_SENTINEL_NOOP_EXIT"
  fi
  fm_sentinel_normalize_tunables
  interval=$(fm_sentinel_positive_integer "$FM_SENTINEL_INTERVAL" 60 15)
  launchctl=$(fm_sentinel_launchctl)
  # shasum is present but produced nothing: a tool failure, not a missing host
  # capability, so this stays a retryable attempt rather than a permanent verdict.
  label=$(fm_sentinel_label) || { printf 'supervision sentinel: SHA-256 service identity could not be derived for this home\n' >&2; return 1; }
  domain=$(fm_sentinel_domain)
  service="$domain/$label"

  max_check_age=$((interval * 2 + 15))
  if ! fm_lock_try_acquire "$FM_SENTINEL_ARM_LOCK"; then
    # Another home-scoped arm is already converging on the same launchd label.
    # Wait out the holder's OWN legitimate convergence bound - a bootout drain plus
    # the bounded first-check wait - instead of giving up after a fraction of it and
    # telling the captain the alarm is unavailable while registration is in fact
    # succeeding.
    deadline=$(( $(date +%s) + FM_SENTINEL_CHECK_WAIT + 5 ))
    while :; do
      if fm_sentinel_service_verified "$launchctl" "$service" "$max_check_age"; then
        return 0
      fi
      [ "$(date +%s)" -lt "$deadline" ] || break
      sleep 0.2
    done
    # The holder is itself a harness-tracked process, and being reaped mid-arm is
    # the exact failure this sentinel exists to cover. Such a holder leaves the
    # lock behind and no failure record at all, so make one short attempt to take
    # it over rather than trusting the absent record. `fm_lock_try_acquire` only
    # reclaims a lock whose owner pid is provably gone, so this can never evict a
    # holder that is still converging.
    if ! fm_lock_try_acquire "$FM_SENTINEL_ARM_LOCK"; then
      # Nothing was registered here and nothing proves the service works, so this
      # caller reports the missing evidence rather than an unearned success.
      fm_sentinel_report_unverified_service "$launchctl" "$service" "$max_check_age"
      return 1
    fi
  fi
  fm_sentinel_arm_registration "$launchctl" "$domain" "$label" "$service" "$interval"
  rc=$?
  fm_lock_release "$FM_SENTINEL_ARM_LOCK" 2>/dev/null || true
  return "$rc"
}

fm_sentinel_write_disarmed() { # <service>
  local service=$1 pending
  pending=$(mktemp "$FM_SENTINEL_DISARMED.XXXXXX") || return 1
  {
    printf 'state=disarmed\n'
    printf 'disarmed_at=%s\n' "$(date +%s)"
    printf 'home=%s\n' "$FM_SENTINEL_HOME_CANON"
    printf 'service=%s\n' "$service"
    printf 'reenable=%s enable\n' "$FM_SENTINEL_DIR/fm-supervision-sentinel.sh"
  } > "$pending" || { rm -f "$pending"; return 1; }
  chmod 600 "$pending" || { rm -f "$pending"; return 1; }
  mv -f "$pending" "$FM_SENTINEL_DISARMED"
}

# Uninstall body. Runs only while this home's arm lock is held, so it may return
# early anywhere: fm_sentinel_disarm owns the single matching release.
fm_sentinel_disarm_service() { # <launchctl> <service>
  local launchctl=$1 service=$2 i
  if "$launchctl" print "$service" >/dev/null 2>&1; then
    if ! "$launchctl" bootout "$service" >/dev/null 2>&1; then
      printf 'supervision sentinel: exact home service could not be uninstalled\n' >&2
      return 1
    fi
    i=0
    while [ "$i" -lt 100 ] && "$launchctl" print "$service" >/dev/null 2>&1; do
      sleep 0.05
      i=$((i + 1))
    done
    if "$launchctl" print "$service" >/dev/null 2>&1; then
      printf 'supervision sentinel: exact home service remained loaded after disarm\n' >&2
      return 1
    fi
  fi
  # The durable record must land before the generated artifacts are removed, so
  # a partial disarm can never look like an ordinary unregistered home.
  if ! fm_sentinel_write_disarmed "$service"; then
    printf 'supervision sentinel: service is absent but the durable disarm record could not be written\n' >&2
    return 1
  fi
  rm -f "$FM_SENTINEL_PLIST" "$FM_SENTINEL_LOADED_DIGEST" "$FM_SENTINEL_LAST_CHECK" \
    "$FM_SENTINEL_MARKER" "$FM_SENTINEL_ARM_FAILURE" 2>/dev/null || true
  return 0
}

fm_sentinel_disarm() {
  local missing launchctl label domain service rc
  fm_primary_scope_matches "$FM_ROOT" "$FM_SENTINEL_STATE" || {
    printf 'supervision sentinel: disarm is valid only in this home primary scope\n' >&2
    return 1
  }
  if missing=$(fm_sentinel_missing_capability); then
    printf 'supervision sentinel: %s, so there is no host service here to disarm\n' "$missing" >&2
    return 1
  fi
  launchctl=$(fm_sentinel_launchctl)
  label=$(fm_sentinel_label) || { printf 'supervision sentinel: SHA-256 service identity could not be derived for this home\n' >&2; return 1; }
  domain=$(fm_sentinel_domain)
  service="$domain/$label"
  if ! fm_lock_try_acquire "$FM_SENTINEL_ARM_LOCK"; then
    printf 'supervision sentinel: this home is already changing its host-service registration\n' >&2
    return 1
  fi
  fm_sentinel_disarm_service "$launchctl" "$service"
  rc=$?
  fm_lock_release "$FM_SENTINEL_ARM_LOCK" 2>/dev/null || true
  [ "$rc" -eq 0 ] || return "$rc"
  printf 'supervision sentinel: disarmed for this home; session start will keep reporting this state\n'
}

fm_sentinel_enable() {
  fm_primary_scope_matches "$FM_ROOT" "$FM_SENTINEL_STATE" || {
    printf 'supervision sentinel: enable is valid only in this home primary scope\n' >&2
    return 1
  }
  # The explicit command is the deliberate override for the durable disarm
  # record, a process-local MODE=off setting, and a registration-retry cooldown.
  # The arm-failure record is cleared only by a verified registration, so a
  # failed enable leaves the suppressed state visible at the next session start.
  FM_SUPERVISION_SENTINEL_MODE=auto
  FM_SENTINEL_FORCE_ARM=1
  if ! fm_sentinel_arm; then
    printf 'supervision sentinel: re-enable failed; durable disarm record preserved\n' >&2
    return 1
  fi
  rm -f "$FM_SENTINEL_DISARMED" || {
    printf 'supervision sentinel: host service is live but the stale disarm record could not be cleared\n' >&2
    return 1
  }
  printf 'supervision sentinel: enabled for this home\n'
}

fm_sentinel_episode_key() {
  local beat m pid
  beat="$FM_SENTINEL_STATE/.last-watcher-beat"
  m=$(fm_sup_stat_mtime "$beat" 2>/dev/null || printf 'absent')
  pid=$(cat "$FM_SENTINEL_STATE/.watch.lock/pid" 2>/dev/null || printf 'none')
  printf 'beat:%s|lock:%s\n' "$m" "$pid"
}

fm_sentinel_marker_field() { # <field>
  [ -f "$FM_SENTINEL_MARKER" ] || return 1
  /usr/bin/awk -F= -v want="$1" '$1 == want { sub(/^[^=]*=/, ""); print; exit }' "$FM_SENTINEL_MARKER"
}

# The recorded human-facing summary: the one record line that is not a key=value
# field (fm_sentinel_summary always leads with an uppercase alarm word).
fm_sentinel_marker_summary() {
  [ -f "$FM_SENTINEL_MARKER" ] || return 1
  /usr/bin/awk '!/^[A-Za-z_][A-Za-z0-9_]*=/ { print; exit }' "$FM_SENTINEL_MARKER"
}

fm_sentinel_write_alarm_record() { # <delivery> <claim> <attempt> <episode> <summary> [delivered] [count] [next]
  local delivery=$1 claim=$2 attempt=$3 episode=$4 summary=$5 delivered=${6:-} count=${7:-0} next=${8:-} pending
  pending=$(mktemp "$FM_SENTINEL_STATE/.supervision-outage-alarm.XXXXXX") || return 1
  {
    printf 'state=outage\n'
    printf 'delivery=%s\n' "$delivery"
    printf 'claim=%s\n' "$claim"
    printf 'attempt_at=%s\n' "$attempt"
    [ -z "$delivered" ] || printf 'delivered_at=%s\n' "$delivered"
    printf 'delivery_count=%s\n' "$count"
    [ -z "$next" ] || printf 'next_alert_at=%s\n' "$next"
    printf 'episode=%s\n' "$episode"
    printf '%s\n' "$summary"
  } > "$pending" || { rm -f "$pending"; return 1; }
  mv -f "$pending" "$FM_SENTINEL_MARKER" || { rm -f "$pending"; return 1; }
}

# Exponential delay for the <attempt>-th event, doubling <base> up to <cap>. The
# bounds are arguments rather than globals so the repeat-alert schedule and the
# launchd registration-retry schedule stay independently configurable.
fm_sentinel_backoff_delay() { # <attempt-count> <base-seconds> <cap-seconds>
  local count=$1 base=$2 cap=$3 delay i=1
  delay=$base
  while [ "$i" -lt "$count" ] && [ "$delay" -lt "$cap" ]; do
    if [ "$delay" -gt $((cap / 2)) ]; then
      delay=$cap
    else
      delay=$((delay * 2))
    fi
    i=$((i + 1))
  done
  [ "$delay" -le "$cap" ] || delay=$cap
  printf '%s\n' "$delay"
}

fm_sentinel_clear_alarm() { # [claim-token]
  local token=${1:-} current
  fm_lock_try_acquire "$FM_SENTINEL_CHECK_LOCK" || return 0
  if [ -n "$token" ]; then
    current=$(fm_sentinel_marker_field claim 2>/dev/null || true)
    if [ "$current" != "$token" ]; then
      fm_lock_release "$FM_SENTINEL_CHECK_LOCK" 2>/dev/null || true
      return 0
    fi
  fi
  rm -f "$FM_SENTINEL_MARKER" 2>/dev/null || true
  fm_lock_release "$FM_SENTINEL_CHECK_LOCK" 2>/dev/null || true
}

fm_sentinel_claim_alarm() { # <episode-key> <summary>
  local key=$1 summary=$2 now delivery delivered_at next_alert_at attempt_at deliveries elapsed token episode new_episode=0
  FM_SENTINEL_CLAIM_TOKEN=
  now=$(date +%s)
  # A wedged claim lock must not silence the alarm. Return the storage-failure
  # class so the caller still attempts the active channel without dedup state.
  fm_lock_try_acquire "$FM_SENTINEL_CHECK_LOCK" || return 2
  delivery=$(fm_sentinel_marker_field delivery 2>/dev/null || true)
  delivered_at=$(fm_sentinel_marker_field delivered_at 2>/dev/null || true)
  next_alert_at=$(fm_sentinel_marker_field next_alert_at 2>/dev/null || true)
  attempt_at=$(fm_sentinel_marker_field attempt_at 2>/dev/null || true)
  episode=$(fm_sentinel_marker_field episode 2>/dev/null || true)
  deliveries=$(fm_sentinel_marker_field delivery_count 2>/dev/null || printf '0')
  case "$deliveries" in ''|*[!0-9]*) deliveries=0 ;; esac
  # A changed episode key means the watcher lock pid or beacon evidence moved:
  # the watcher recovered and was reaped again between two scheduled checks. That
  # flapping outage is genuinely new, so it restarts the repeat schedule instead
  # of inheriting a backoff that can already be an hour long. Only an unchanged,
  # continuous outage keeps backing off.
  if [ -n "$episode" ] && [ "$episode" != "$key" ]; then
    new_episode=1
    deliveries=0
  fi
  if [ "$delivery" = sent ] && [ "$new_episode" -eq 0 ]; then
    case "$next_alert_at" in
      ''|*[!0-9]*)
        case "$delivered_at" in
          ''|*[!0-9]*) ;;
          *) next_alert_at=$((delivered_at + FM_SENTINEL_REALARM)) ;;
        esac
        ;;
    esac
    case "$next_alert_at" in
      ''|*[!0-9]*) ;;
      *)
        elapsed=$((next_alert_at - now))
        if [ "$elapsed" -gt 0 ] && [ "$elapsed" -le "$FM_SENTINEL_MAX_REALARM" ]; then
          fm_lock_release "$FM_SENTINEL_CHECK_LOCK" 2>/dev/null || true
          return 1
        fi
        ;;
    esac
  elif [ "$delivery" = pending ]; then
    # The short claim lease still applies to a new episode: it only defers by
    # FM_SENTINEL_CLAIM_LEASE_SECS, and honoring it keeps a delivery that is
    # still in flight from being duplicated by a concurrent check.
    case "$attempt_at" in
      ''|*[!0-9]*) ;;
      *)
        elapsed=$((now - attempt_at))
        if [ "$elapsed" -ge 0 ] && [ "$elapsed" -lt "$FM_SENTINEL_CLAIM_LEASE" ]; then
          fm_lock_release "$FM_SENTINEL_CHECK_LOCK" 2>/dev/null || true
          return 1
        fi
        ;;
    esac
  fi
  token="${BASHPID:-$$}-$now-${RANDOM:-0}"
  if ! fm_sentinel_write_alarm_record pending "$token" "$now" "$key" "$summary" '' "$deliveries"; then
    fm_lock_release "$FM_SENTINEL_CHECK_LOCK" 2>/dev/null || true
    return 2
  fi
  FM_SENTINEL_CLAIM_TOKEN=$token
  fm_lock_release "$FM_SENTINEL_CHECK_LOCK" 2>/dev/null || true
  return 0
}

fm_sentinel_mark_delivered() { # <claim-token> <episode> <summary>
  local token=$1 key=$2 summary=$3 current now deliveries delay next
  now=$(date +%s)
  fm_lock_try_acquire "$FM_SENTINEL_CHECK_LOCK" || return 1
  current=$(fm_sentinel_marker_field claim 2>/dev/null || true)
  if [ "$current" != "$token" ]; then
    fm_lock_release "$FM_SENTINEL_CHECK_LOCK" 2>/dev/null || true
    return 1
  fi
  deliveries=$(fm_sentinel_marker_field delivery_count 2>/dev/null || printf '0')
  case "$deliveries" in ''|*[!0-9]*) deliveries=0 ;; esac
  deliveries=$((deliveries + 1))
  delay=$(fm_sentinel_backoff_delay "$deliveries" "$FM_SENTINEL_REALARM" "$FM_SENTINEL_MAX_REALARM")
  next=$((now + delay))
  fm_sentinel_write_alarm_record sent "$token" "$now" "$key" "$summary" "$now" "$deliveries" "$next"
  current=$?
  fm_lock_release "$FM_SENTINEL_CHECK_LOCK" 2>/dev/null || true
  return "$current"
}

fm_sentinel_record_check() {
  local pending="$FM_SENTINEL_LAST_CHECK.pending.$$"
  if ! printf '%s\n' "$(date +%s)" > "$pending" || ! mv -f "$pending" "$FM_SENTINEL_LAST_CHECK"; then
    rm -f "$pending"
    return 1
  fi
}

fm_sentinel_summary() {
  printf 'SUPERVISION DOWN: %s task(s) in flight; last watcher beat: %s (grace %ss). No automatic restart was attempted; see %s\n' \
    "$FM_SUP_IN_FLIGHT" "$FM_SUP_BEACON_DESC" "$FM_SENTINEL_GRACE" "$FM_SENTINEL_MARKER"
}

# Durable, notifier-free outage evidence for every marker-only mode.
#
# Refresh is deliberately narrow. A record whose delivery is already committed
# (`sent`) or whose claim token belongs to a scheduled check still inside its
# lease keeps its claim, delivery_count, and repeat schedule untouched: only the
# scheduled host check owns those. Everything else is unclaimed evidence, and it
# is rewritten whenever the outage episode or the reported summary moved, so the
# human-facing record on a home with no working host check (Linux, a failed arm)
# can never freeze on the first outage ever observed. A same-episode refresh
# preserves delivery_count so a changed task count cannot rewind the backoff.
fm_sentinel_record_pending() { # <episode-key> <summary>
  local key=$1 summary=$2 delivery claim attempt episode deliveries now
  fm_lock_try_acquire "$FM_SENTINEL_CHECK_LOCK" || return 0
  deliveries=0
  if [ -e "$FM_SENTINEL_MARKER" ]; then
    delivery=$(fm_sentinel_marker_field delivery 2>/dev/null || true)
    claim=$(fm_sentinel_marker_field claim 2>/dev/null || true)
    attempt=$(fm_sentinel_marker_field attempt_at 2>/dev/null || true)
    episode=$(fm_sentinel_marker_field episode 2>/dev/null || true)
    if [ "$delivery" != pending ]; then
      fm_lock_release "$FM_SENTINEL_CHECK_LOCK" 2>/dev/null || true
      return 0
    fi
    if [ -n "$claim" ]; then
      now=$(date +%s)
      case "$attempt" in
        ''|*[!0-9]*) ;;
        *)
          if [ "$now" -ge "$attempt" ] && [ $((now - attempt)) -lt "$FM_SENTINEL_CLAIM_LEASE" ]; then
            fm_lock_release "$FM_SENTINEL_CHECK_LOCK" 2>/dev/null || true
            return 0
          fi
          ;;
      esac
    fi
    if [ "$episode" = "$key" ]; then
      deliveries=$(fm_sentinel_marker_field delivery_count 2>/dev/null || printf '0')
      case "$deliveries" in ''|*[!0-9]*) deliveries=0 ;; esac
      if [ "$(fm_sentinel_marker_summary 2>/dev/null || true)" = "$summary" ]; then
        fm_lock_release "$FM_SENTINEL_CHECK_LOCK" 2>/dev/null || true
        return 0
      fi
    fi
  fi
  # An unclaimed record with attempt_at=0 leaves no delivery lease to wait out,
  # so the next scheduled host check claims and alerts on this episode at once.
  fm_sentinel_write_alarm_record pending '' 0 "$key" "$summary" '' "$deliveries" || true
  fm_lock_release "$FM_SENTINEL_CHECK_LOCK" 2>/dev/null || true
  return 0
}

# Marker-only mode for the in-harness turn-end and continuity guards.
#
# Those hooks must render their blocking banner immediately: a Stop hook that
# outruns its harness timeout loses the block itself, which is the very backstop
# this sentinel exists to strengthen. So a guard records durable evidence with
# local writes alone and never forks the alert owner, never backgrounds notifier
# work, and never writes the launchd-liveness proof. The scheduled host check
# remains the sole owner of external alert delivery.
fm_sentinel_note_outage() {
  fm_sentinel_check note
}

# One health evaluation, with capabilities granted by mode name and never
# inferred from a flag whose meaning has to be cross-referenced:
#
#   scheduled   launchd's private entry point. The ONLY mode that publishes host
#               liveness and crosses the external-alert boundary. Retires a
#               recovered episode. Silent on stdout.
#   diagnostic  the operator's `check`. Marker-only, no notifier, but reports its
#               verdict on stdout and exits non-zero on a detected outage.
#               Retires a recovered episode.
#   note        the in-harness turn-end and continuity hooks. Marker-only and
#               completely silent so a blocking banner is never delayed, and it
#               never retires an episode: a hook only reports what it measured.
#
# Every mode honors the durable disarm record: a deliberately disarmed home
# evaluates nothing, records no outage evidence, and stays silent on every
# EXTERNAL channel until an explicit verified `enable`. The scheduled entry point
# still records its local host-liveness proof first, because that proof is what
# `enable`'s bounded registration wait observes: the launchd job keeps running
# while the home is disarmed, and a proof gated behind the disarm record would
# make the one documented recovery command time out forever.
fm_sentinel_check() { # <scheduled|diagnostic|note>
  local mode=$1 record_host=0 clear_on_recovery=1 report=0 claim_rc key summary
  case "$mode" in
    scheduled) record_host=1 ;;
    diagnostic) report=1 ;;
    note) clear_on_recovery=0 ;;
    *) printf 'supervision sentinel: unknown check mode %s\n' "$mode" >&2; return 2 ;;
  esac
  fm_sentinel_normalize_tunables
  if ! fm_sentinel_mode_enabled; then
    [ "$report" -eq 0 ] || printf 'supervision sentinel: disabled for this process by FM_SUPERVISION_SENTINEL_MODE=%s; no check ran\n' \
      "${FM_SUPERVISION_SENTINEL_MODE:-auto}"
    return 0
  fi
  if ! fm_primary_scope_matches "$FM_ROOT" "$FM_SENTINEL_STATE"; then
    [ "$report" -eq 0 ] || printf 'supervision sentinel: %s is not a primary home for this state directory; nothing to check\n' \
      "$FM_SENTINEL_HOME_CANON"
    return 0
  fi
  fm_supervision_status "$FM_SENTINEL_STATE" "$FM_SENTINEL_GRACE"
  if [ "$record_host" -eq 1 ]; then
    # Publish liveness only for launchd's private entry point, and only once this
    # process has provably resolved this home and read its supervision state - that
    # is the whole claim the proof makes. Guard-owned modes never reach this, so
    # they still cannot forge host-service health.
    #
    # It is recorded HERE rather than from an exit trap because a registration waits
    # a bounded FM_SENTINEL_CHECK_WAIT_SECS for this proof while the alert delivery
    # below has no aggregate bound: from the trap, one slow notifier channel pushed
    # the proof past that wait and a perfectly healthy launchd service was recorded
    # as a registration failure with a retry cooldown behind it.
    #
    # It also lands BEFORE the disarm gate below: the proof is a local marker, not
    # an alert, and gating it on the disarm record deadlocked `enable`, whose
    # registration wait needs a launchd-spawned check to complete while the home
    # is still disarmed.
    fm_sentinel_record_check || true
  fi
  if [ -f "$FM_SENTINEL_DISARMED" ]; then
    [ "$report" -eq 0 ] || printf 'supervision sentinel: host monitoring is DISARMED for this home; run %s enable to restore it\n' \
      "$FM_SENTINEL_DIR/fm-supervision-sentinel.sh"
    return 0
  fi
  if [ "$FM_SUP_IN_FLIGHT" -eq 0 ]; then
    [ "$clear_on_recovery" -eq 0 ] || fm_sentinel_clear_alarm
    if [ "$report" -eq 1 ]; then
      printf 'supervision sentinel: OK - no task metadata in flight for this home; nothing to supervise\n'
      fm_sentinel_report_host_capability
      fm_sentinel_report_arm_state
    fi
    return 0
  fi
  if fm_watcher_healthy "$FM_SENTINEL_STATE" "$FM_SENTINEL_WATCH" "$FM_SENTINEL_GRACE" "$FM_HOME"; then
    [ "$clear_on_recovery" -eq 0 ] || fm_sentinel_clear_alarm
    if [ "$report" -eq 1 ]; then
      printf 'supervision sentinel: OK - %s task(s) in flight with a live identity-matched watcher; last beat %s (grace %ss)\n' \
        "$FM_SUP_IN_FLIGHT" "$FM_SUP_BEACON_DESC" "$FM_SENTINEL_GRACE"
      fm_sentinel_report_host_capability
      fm_sentinel_report_arm_state
    fi
    return 0
  fi

  summary=$(fm_sentinel_summary)
  key=$(fm_sentinel_episode_key)
  if [ "$record_host" -ne 1 ]; then
    fm_sentinel_record_pending "$key" "$summary"
    if [ "$report" -eq 1 ]; then
      printf '%s\n' "$summary"
      printf 'supervision sentinel: this mode is marker-only; external alert delivery is PENDING and owned by the scheduled host check\n'
      fm_sentinel_report_host_capability
      fm_sentinel_report_arm_state
      return 1
    fi
    return 0
  fi
  fm_sentinel_claim_alarm "$key" "$summary"
  claim_rc=$?
  [ "$claim_rc" -eq 1 ] && return 0

  # A competing recovery may have landed after the claim. Revalidate before
  # crossing the active-alert boundary, and clear only this claim if healthy.
  fm_supervision_status "$FM_SENTINEL_STATE" "$FM_SENTINEL_GRACE"
  if [ "$FM_SUP_IN_FLIGHT" -eq 0 ] || fm_watcher_healthy "$FM_SENTINEL_STATE" "$FM_SENTINEL_WATCH" "$FM_SENTINEL_GRACE" "$FM_HOME"; then
    [ -z "$FM_SENTINEL_CLAIM_TOKEN" ] || fm_sentinel_clear_alarm "$FM_SENTINEL_CLAIM_TOKEN"
    return 0
  fi

  if [ ! -x "$FM_SENTINEL_ALERT_OWNER" ]; then
    return 1
  fi
  if FM_WEDGE_ALARM_TITLE='firstmate: SUPERVISION DOWN' \
    FM_WEDGE_ALARM_LOG_FILE="$FM_SENTINEL_STATE/.supervision-sentinel.log" \
    "$FM_SENTINEL_ALERT_OWNER" --active-alert "$summary" "$FM_SENTINEL_MARKER"; then
    [ -z "$FM_SENTINEL_CLAIM_TOKEN" ] || fm_sentinel_mark_delivered "$FM_SENTINEL_CLAIM_TOKEN" "$key" "$summary" || true
    return 0
  fi
  # Leave delivery=pending so the next scheduled check retries after the short
  # claim lease instead of suppressing a notification that never landed.
  return 1
}

case "${1:-}" in
  arm) [ "$#" -eq 1 ] || { fm_sentinel_usage >&2; exit 2; }; fm_sentinel_arm ;;
  enable) [ "$#" -eq 1 ] || { fm_sentinel_usage >&2; exit 2; }; fm_sentinel_enable ;;
  disarm) [ "$#" -eq 1 ] || { fm_sentinel_usage >&2; exit 2; }; fm_sentinel_disarm ;;
  check) [ "$#" -eq 1 ] || { fm_sentinel_usage >&2; exit 2; }; fm_sentinel_check diagnostic ;;
  note-outage) [ "$#" -eq 1 ] || { fm_sentinel_usage >&2; exit 2; }; fm_sentinel_note_outage ;;
  scheduled-check) [ "$#" -eq 1 ] || { fm_sentinel_usage >&2; exit 2; }; fm_sentinel_check scheduled ;;
  -h|--help) fm_sentinel_usage ;;
  *) fm_sentinel_usage >&2; exit 2 ;;
esac
