# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/fm-supervision-lib.sh
#
# Reports whether a firstmate home needs supervision (fm_supervision_status
# below is the single owner of that condition set), and whether its watcher has
# a fresh liveness beacon (state/.last-watcher-beat, touched every poll cycle,
# within the grace window).
# bin/fm-turnend-guard.sh uses the PID-strict fm_watcher_healthy from
# bin/fm-wake-lib.sh for its block decision. bin/fm-guard.sh uses the model-aware
# fm_watcher_supervision_verdict (also in bin/fm-wake-lib.sh), which owns what a
# live watcher process means per supervision model. The status fields here retain
# the beacon-age details used in their messages.

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

fm_sup_format_duration() {
  local total=$1 days hours minutes seconds out=
  days=$((total / 86400))
  hours=$(((total % 86400) / 3600))
  minutes=$(((total % 3600) / 60))
  seconds=$((total % 60))
  [ "$days" -gt 0 ] && out="${days}d "
  [ "$hours" -gt 0 ] && out="${out}${hours}h "
  [ "$minutes" -gt 0 ] && out="${out}${minutes}m "
  printf '%s%ss\n' "$out" "$seconds"
}

_FM_SUP_LIB_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || _FM_SUP_LIB_DIR=.

# Lazy loaders, so a home whose tasks declare nothing idle never pays for the
# status classifier or the bounded runner on the hook paths that source this.
# The classifier restores its caller's nounset setting around the timeout
# library it sources, so loading it covers both.
_fm_sup_require_classify() {
  command -v status_declared_wait_line >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-classify-lib.sh
  . "$_FM_SUP_LIB_DIR/fm-classify-lib.sh" 2>/dev/null
}

# fm_sup_agent_liveness <meta-file>
# Prints alive, dead, or unknown for the task's recorded agent: the
# recovery-grade fm_backend_agent_alive verdict, read in a bounded child so
# the backend library's globals never leak into the hook that sourced this.
# FM_SUP_LIVENESS_PROBE is a test seam invoked as `<probe> <meta-file>`.
# Anything but a clean `dead` - a timeout, an unreadable endpoint, a backend
# with no classifier - prints unknown.
fm_sup_agent_liveness() {  # <meta-file>
  local meta=$1 verdict
  _fm_sup_require_classify || { printf 'unknown'; return 0; }
  if [ -n "${FM_SUP_LIVENESS_PROBE:-}" ]; then
    verdict=$(fm_run_timed "${FM_SUP_LIVENESS_TIMEOUT:-5}" "$FM_SUP_LIVENESS_PROBE" "$meta" 2>/dev/null)
  else
    # shellcheck disable=SC2016 # Expanded by the child shell, not here.
    verdict=$(fm_run_timed "${FM_SUP_LIVENESS_TIMEOUT:-5}" bash -c \
      '. "$1/fm-backend.sh" && fm_backend_agent_alive "$(fm_backend_of_meta "$2")" "$(fm_backend_target_of_meta "$2")"' \
      _ "$_FM_SUP_LIB_DIR" "$meta" 2>/dev/null)
  fi
  case "$verdict" in
    alive|dead) printf '%s' "$verdict" ;;
    *) printf 'unknown' ;;
  esac
}

# fm_sup_task_inert <state-dir> <task-id>
# True when a task's record is present but nothing about it can change while
# supervision is down, so it is not in flight. Both halves are required:
#   1. It declares itself idle: its metadata carries a non-empty standing=
#      (a standing service record, not a dispatched worker), or its status
#      log's declared wait (status_declared_wait_line) is a paused: or
#      captain-held line.
#   2. No agent can be running for it: no window= was ever recorded, or the
#      recorded agent reads confidently dead. A worker that declared a wait
#      and is still alive - or whose liveness cannot be read - stays in flight.
# A task still counts, whatever it declares, when the watcher has scheduled
# work on it: a secondmate (a supervisor whose liveness the watcher owns), any
# state/<id>.check.sh poll - a registered custom check or an unbound one such
# as a PR merge poll - or a pause naming the time it clears (`until`), which
# the watcher rechecks.
fm_sup_task_inert() {  # <state-dir> <task-id>
  local state=$1 id=$2 meta line standing='' window='' kind='' status wait
  meta="$state/$id.meta"
  [ -e "$state/$id.check.sh" ] && return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      standing=?*) standing=1 ;;
      window=*) window=${line#window=} ;;
      kind=*) kind=${line#kind=} ;;
    esac
  done < "$meta" 2>/dev/null || return 1
  [ "$kind" = secondmate ] && return 1
  if [ -z "$standing" ]; then
    status="$state/$id.status"
    # Cheap pre-filter: a log that never mentions either wait verb cannot end
    # in one, so ordinary tasks never load the classifier.
    grep -Fq -e "${FM_CLASSIFY_PAUSED_VERB:-paused}" -e "${FM_CLASSIFY_CAPTAIN_HELD_VERB:-captain-held}" \
      "$status" 2>/dev/null || return 1
    _fm_sup_require_classify || return 1
    wait=$(status_declared_wait_line "$status")
    [ -n "$wait" ] || return 1
    status_paused_until "$wait" >/dev/null && return 1
  fi
  [ -n "$window" ] || return 0
  [ "$(fm_sup_agent_liveness "$meta")" = dead ]
}

# fm_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT      count of state/*.meta tasks that can still change
#                         state (fm_sup_task_inert above owns the exclusion)
#   FM_SUP_IN_FLIGHT_IDS  those tasks' IDs, comma-separated, or "(none)"
#   FM_SUP_SOURCES        count of registered process-to-event sources
#   FM_SUP_CHECKS         count of registered custom checks: a state/<id>.check.sh
#                         with the state/<id>.check-trust binding that
#                         bin/fm-check-register.sh writes. Task PR polls carry no
#                         such binding and are torn down with their task, and the
#                         relay shim keeps its own trust path, so neither counts
#                         here. Presence of the binding is the whole test: whether
#                         those bytes are still the registered ones is the check
#                         sweep's call at execution time, and a home whose check
#                         no longer validates needs the watcher precisely so the
#                         sweep can report the rejection instead of going quiet.
#   FM_SUP_NEEDED         true/false - in-flight work, an X-mode relay poll, a
#                         registered event source (a source is a wait on an
#                         external process, not a task, so it has no metadata),
#                         or a registered custom check
#   FM_SUP_WATCHER_FRESH  true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC    human-readable beacon age, for banners ("never" if absent)
#   FM_SUP_QUEUE_PENDING  true/false - state/.wake-queue has unread records
#   FM_SUP_OUTAGE_SUMMARY one canonical sentence naming how long supervision has
#                         been down and which tasks are exposed, spelled once
#                         here so every surface that reports an outage - the
#                         continuity pre-tool denial, the away-mode alarm, the
#                         shift alarm - says the same thing. It is deliberately
#                         longer and more explicit than FM_SUP_BEACON_DESC,
#                         which stays a compact field for banners: a denial an
#                         operator reads once, mid-incident, must not make them
#                         infer the duration from "unknown".
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} meta source check id beat m age duration
  FM_SUP_IN_FLIGHT=0
  FM_SUP_IN_FLIGHT_IDS=
  FM_SUP_NEEDED=false
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC=never
  FM_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    fm_sup_task_inert "$state" "$id" && continue
    FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
    if [ -n "$FM_SUP_IN_FLIGHT_IDS" ]; then
      FM_SUP_IN_FLIGHT_IDS="$FM_SUP_IN_FLIGHT_IDS, $id"
    else
      FM_SUP_IN_FLIGHT_IDS=$id
    fi
  done
  # shellcheck disable=SC2034 # Read by callers after sourcing.
  [ -n "$FM_SUP_IN_FLIGHT_IDS" ] || FM_SUP_IN_FLIGHT_IDS='(none)'
  FM_SUP_SOURCES=0
  for source in "$state"/procevent/*.source; do
    [ -e "$source" ] || continue
    FM_SUP_SOURCES=$((FM_SUP_SOURCES + 1))
  done
  FM_SUP_CHECKS=0
  for check in "$state"/*.check.sh; do
    [ -e "$check" ] || continue
    id=${check##*/}
    id=${id%.check.sh}
    if [ "$id" = x-watch ]; then
      continue
    fi
    [ -e "$state/$id.check-trust" ] || continue
    FM_SUP_CHECKS=$((FM_SUP_CHECKS + 1))
  done
  if [ "$FM_SUP_IN_FLIGHT" -gt 0 ] \
    || [ -f "$state/x-watch.check.sh" ] \
    || [ "$FM_SUP_SOURCES" -gt 0 ] \
    || [ "$FM_SUP_CHECKS" -gt 0 ]; then
    FM_SUP_NEEDED=true
  fi

  duration='unknown duration (unknown since when; watcher beat file missing or unreadable)'
  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat")
    if [ -n "$m" ]; then
      age=$(( $(date +%s) - m ))
      FM_SUP_BEACON_DESC="${age}s ago"
      if [ "$age" -lt 0 ]; then
        # A wall-clock rollback, or a state volume restored from a machine whose
        # clock ran ahead, leaves a beat in the future. That is not an outage
        # duration, so the summary says so rather than reporting a negative or
        # enormous window.
        duration="unknown duration (unknown since when; watcher beat timestamp is $(fm_sup_format_duration "$(( -age ))") in the future)"
      else
        duration="at least $(fm_sup_format_duration "$age") since the last watcher beat"
        [ "$age" -lt "$grace" ] && FM_SUP_WATCHER_FRESH=true
      fi
    else
      # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
      FM_SUP_BEACON_DESC=unknown
    fi
  fi

  # shellcheck disable=SC2034 # Read by callers after sourcing.
  FM_SUP_OUTAGE_SUMMARY="SUPERVISION OUTAGE: down for $duration; $FM_SUP_IN_FLIGHT task(s) in flight: $FM_SUP_IN_FLIGHT_IDS."
  # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
  [ -s "$state/.wake-queue" ] && FM_SUP_QUEUE_PENDING=true
  return 0
}

# fm_supervision_needed <state-dir> [grace-seconds]
# Exit 0 (true) exactly when the home needs a watcher.
fm_supervision_needed() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ]
}

# fm_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly when supervision is needed and no watcher has a fresh
# beacon. Exit 1 (false) otherwise.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  [ "$FM_SUP_NEEDED" = true ] && [ "$FM_SUP_WATCHER_FRESH" = false ]
}

# Canonical basename of the durable host-sentinel registration-failure record.
# Every producer and consumer derives its path from this, so the filename is
# spelled exactly once in the tree.
FM_SUP_ARM_RECORD_NAME=.supervision-sentinel.arm-failure

# Canonical basename of the durable host-sentinel deliberate-disarm record,
# shared for the same reason: the session-start banner and the sentinel must
# never disagree about which file marks a deliberately disarmed home.
# shellcheck disable=SC2034 # Read by callers after sourcing.
FM_SUP_DISARM_RECORD_NAME=.supervision-sentinel.disarmed

# Exit status `bin/fm-supervision-sentinel.sh arm` uses for a positively proven
# missing HOST capability, as distinct from a failed registration attempt (exit 1).
# A caller may stop retrying only on this status. Giving up on an ambiguous error
# would silently abandon a recoverable outage backstop, so anything short of
# specific evidence that this host lacks a capability stays transient and keeps its
# retry schedule.
# shellcheck disable=SC2034 # Read by callers after sourcing.
FM_SUP_SENTINEL_UNSUPPORTED_EXIT=3

# Exit status `bin/fm-supervision-sentinel.sh arm` uses for a deliberate no-op:
# a durably disarmed home, FM_SUPERVISION_SENTINEL_MODE=off, or a non-primary
# scope. The sentinel declined on purpose rather than tried and lost, so a
# caller must neither treat the home as protected nor spend failure evidence,
# retries, or backoff on it; exit 0 is reserved for a verified registration.
# shellcheck disable=SC2034 # Read by callers after sourcing.
FM_SUP_SENTINEL_NOOP_EXIT=4

# Canonical basename of the durable away-mode host-alarm availability ledger:
# one tab-separated `<iso-timestamp> <unavailable|restored> <detail>` row per
# transition, appended by the away daemon and folded into the return catch-up by
# bin/fm-afk-return.sh. An away stretch with no host alarm is not re-derivable
# after the fact, so this record is historical evidence: only the return catch-up
# that surfaces it may clear it, never a fresh away entry.
# shellcheck disable=SC2034 # Read by callers after sourcing.
FM_SUP_AWAY_GAP_NAME=.supervision-sentinel.away-gap

# Canonical basename of the armed glasses-shift record written by
# bin/fm-shift.sh start and removed by bin/fm-shift.sh stop. While it exists the
# host sentinel supervises the home even with no crew task in flight: a shift's
# questions arrive as mailbox events, never as state/*.meta tasks, so the
# in-flight count alone would read a dead watcher during a shift as idle.
# shellcheck disable=SC2034 # Read by callers after sourcing.
FM_SUP_SHIFT_RECORD_NAME=.shift

# Canonical basename of the away-mode flag. A shift's lifetime is strictly
# contained inside away mode's: bin/fm-shift.sh start establishes away mode
# before it writes the shift record, and its stop tears no artifact down until
# that flag is gone. Spelled once here so every reader of the pair agrees.
# shellcheck disable=SC2034 # Read by callers after sourcing.
FM_SUP_AFK_FLAG_NAME=.afk

# fm_sup_shift_armed <state-dir>
# THE single definition of "a glasses shift is armed": the shift record exists
# AND away mode is still active. Both conditions, always, at every read site.
#
# Why both: bin/fm-afk-return.sh, the away-mode return owner, knows nothing about
# the shift and removes nothing of its own, so an ordinary captain return leaves
# the record, the registered check and the config/wedge-alarm block behind. A
# read path testing the record alone then treats that leftover as a live shift:
# the host sentinel keeps supervising an idle home and speaks a repeating
# "supervision down" line into glasses that are on a charger. Requiring the flag
# makes every read path agree with the write path that already assumed it.
#
# Having the record without the flag is a STALE shift, not an armed one, and it
# is not nothing: the record and the alarm block are still on disk and still
# need standing down. Callers that report state to a human must say so rather
# than reporting simply "not armed" - fm_sup_shift_stale below is that question.
fm_sup_shift_armed() {
  local state=$1
  [ -f "$state/$FM_SUP_SHIFT_RECORD_NAME" ] && [ -e "$state/$FM_SUP_AFK_FLAG_NAME" ]
}

# fm_sup_shift_stale <state-dir>
# True when a shift record outlived away mode. The artifacts are still present
# and still capture the home's alarm channel, so this is the state a human must
# be told about and `bin/fm-shift.sh stop` is what clears it.
fm_sup_shift_stale() {
  local state=$1
  [ -f "$state/$FM_SUP_SHIFT_RECORD_NAME" ] && [ ! -e "$state/$FM_SUP_AFK_FLAG_NAME" ]
}

# Canonical basename of the host sentinel's launchd-liveness proof: the epoch of
# the last scheduled check that resolved this home. Only launchd's private entry
# point writes it. A registration is verified, and a shift may rely on the host
# alarm, only while this proof is recent.
# shellcheck disable=SC2034 # Read by callers after sourcing.
FM_SUP_LAST_CHECK_NAME=.supervision-sentinel-last-check

# Canonical basename of the host sentinel's launchd job manifest. The interval
# the loaded job actually runs on is recorded there and nowhere else, so every
# reader derives the path from this name rather than spelling it again.
# shellcheck disable=SC2034 # Read by callers after sourcing.
FM_SUP_PLIST_NAME=.supervision-sentinel.plist

# fm_supervision_loaded_interval <state-dir>
# Print the check interval the registered launchd job runs on, read back from the
# job manifest that registration wrote. The ambient FM_SENTINEL_INTERVAL_SECS of
# whoever happens to be asking says nothing about the loaded job, so a read-only
# surface that judged a liveness proof against it would refuse a home armed with a
# non-default interval and offer a fix that changes nothing. Fails closed: a
# manifest that is missing or carries no usable interval returns non-zero rather
# than a guess, because the caller cannot then prove the job's schedule at all.
fm_supervision_loaded_interval() {
  local plist="$1/$FM_SUP_PLIST_NAME" interval
  [ -f "$plist" ] || return 1
  interval=$(awk '
    /<key>StartInterval<\/key>/ { want = 1; next }
    want && match($0, /<integer>[0-9]+<\/integer>/) {
      print substr($0, RSTART + 9, RLENGTH - 19); exit
    }
    want { exit }' "$plist" 2>/dev/null) || return 1
  case "$interval" in ''|*[!0-9]*) return 1 ;; esac
  [ "$interval" -gt 0 ] || return 1
  printf '%s\n' "$interval"
}

# The launchctl the host sentinel registers and verifies through. Tests point it
# at a fake so no sentinel path ever touches real launchd.
fm_supervision_sentinel_launchctl() {
  printf '%s\n' "${FM_SENTINEL_LAUNCHCTL:-/bin/launchctl}"
}

# fm_supervision_check_max_age <interval-seconds>
# The oldest a launchd-liveness proof may be and still prove the host service can
# observe this home: two scheduled intervals plus slack. The arm path and every
# read-only surface that reports the sentinel as live use this one bound.
fm_supervision_check_max_age() {
  printf '%s\n' "$(( $1 * 2 + 15 ))"
}

# fm_supervision_missing_host_capability
# Names the one host capability the sentinel needs and does not have, or exits
# non-zero when the host can run the scheduled check at all. One place decides
# what "unsupported" means, so the arm's exit status, the operator diagnostic,
# the away-mode ledger, and the shift preflight can never disagree about it.
#
# Every branch is POSITIVE evidence of an absent capability, never a failed
# attempt: an ambiguous error must stay transient, because a caller that stops
# retrying on ambiguity abandons a backstop that would have recovered on its own.
fm_supervision_missing_host_capability() {
  local platform=${FM_SENTINEL_PLATFORM:-$(uname)} launchctl
  if [ "$platform" != Darwin ]; then
    printf 'this host runs %s and has no verified host scheduler for the sentinel (launchd is macOS-only)\n' "$platform"
    return 0
  fi
  launchctl=$(fm_supervision_sentinel_launchctl)
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

# fm_supervision_arm_failure_status <state-dir>
# Reads the durable host-sentinel registration-failure record and populates:
#   FM_SUP_ARM_RECORD       resolved path of the record, set whether or not it exists
#   FM_SUP_ARM_FAILED       true/false - the record exists at all
#   FM_SUP_ARM_FAILURES     recorded consecutive failure count (0 when unreadable)
#   FM_SUP_ARM_RETRY_IN     seconds the retry cooldown still suppresses registration
#   FM_SUP_ARM_RETRY_STALE  true/false - the deadline is unusable, so it suppresses nothing
#
# One snapshot answers every question about the record, so a caller reads the file
# once per operation instead of re-deriving fields through separate wrappers.
#
# The cooldown counts only while retry_at is in the future AND no further away
# than the retry_after_secs recorded atomically beside it. A wall-clock rollback,
# or a state volume restored from a machine whose clock ran ahead, therefore reads
# as stale evidence that suppresses nothing rather than an enormous fake
# suppression window. Both bin/fm-supervision-sentinel.sh (which enforces the
# cooldown) and bin/fm-session-start.sh (which reports it) call this, so the
# displayed window and the enforced window cannot drift apart.
# Always returns 0; callers read the vars.
fm_supervision_arm_failure_status() {
  local state=$1 at after now remaining
  FM_SUP_ARM_RECORD="$state/$FM_SUP_ARM_RECORD_NAME"
  FM_SUP_ARM_FAILED=false
  FM_SUP_ARM_FAILURES=0
  FM_SUP_ARM_RETRY_IN=0
  FM_SUP_ARM_RETRY_STALE=false
  [ -f "$FM_SUP_ARM_RECORD" ] || return 0
  # shellcheck disable=SC2034 # Read by callers after sourcing.
  FM_SUP_ARM_FAILED=true

  FM_SUP_ARM_FAILURES=$(awk -F= '$1 == "failures" { print $2; exit }' "$FM_SUP_ARM_RECORD" 2>/dev/null || true)
  case "$FM_SUP_ARM_FAILURES" in ''|*[!0-9]*) FM_SUP_ARM_FAILURES=0 ;; esac

  at=$(awk -F= '$1 == "retry_at" { print $2; exit }' "$FM_SUP_ARM_RECORD" 2>/dev/null || true)
  after=$(awk -F= '$1 == "retry_after_secs" { print $2; exit }' "$FM_SUP_ARM_RECORD" 2>/dev/null || true)
  case "$at" in ''|*[!0-9]*) FM_SUP_ARM_RETRY_STALE=true; return 0 ;; esac
  case "$after" in ''|*[!0-9]*) FM_SUP_ARM_RETRY_STALE=true; return 0 ;; esac

  now=$(date +%s)
  [ "$now" -lt "$at" ] || return 0
  remaining=$((at - now))
  if [ "$remaining" -gt "$after" ]; then
    # shellcheck disable=SC2034 # Read by callers after sourcing.
    FM_SUP_ARM_RETRY_STALE=true
    return 0
  fi
  # shellcheck disable=SC2034 # Read by callers after sourcing.
  FM_SUP_ARM_RETRY_IN=$remaining
  return 0
}
