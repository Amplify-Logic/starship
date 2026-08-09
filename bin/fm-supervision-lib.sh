# shellcheck shell=bash
# Shared "supervision missing" predicate.
# Usage: . bin/fm-supervision-lib.sh
#
# True exactly when a firstmate home has in-flight work (a state/<id>.meta
# exists) but no watcher has a fresh liveness beacon (state/.last-watcher-beat,
# touched every poll cycle, within the grace window). bin/fm-guard.sh uses this
# grace-based warning predicate directly; bin/fm-turnend-guard.sh uses the status
# fields here for its banner but performs its end-of-turn block decision with the
# live watcher lock check in bin/fm-wake-lib.sh.

# Portable mtime; Linux stat lacks -f, macOS stat lacks -c.
fm_sup_stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
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

# fm_supervision_status <state-dir> [grace-seconds]
# Populates, for the state dir at $1:
#   FM_SUP_IN_FLIGHT          count of state/*.meta (in-flight tasks)
#   FM_SUP_IN_FLIGHT_IDS      comma-separated task IDs derived from those files
#   FM_SUP_WATCHER_FRESH      true/false - a watcher beacon within the grace window
#   FM_SUP_BEACON_DESC        human-readable beacon age or explicit unknown state
#   FM_SUP_OUTAGE_SUMMARY     canonical outage duration, count, and task-ID wording
#   FM_SUP_QUEUE_PENDING      true/false - state/.wake-queue has unread records
# grace-seconds defaults to $FM_GUARD_GRACE, then 300, matching fm-guard.sh.
# Always returns 0; callers read the vars, or use fm_supervision_unhealthy below.
fm_supervision_status() {
  local state=$1 grace=${2:-${FM_GUARD_GRACE:-300}} meta id beat m now age duration
  FM_SUP_IN_FLIGHT=0
  FM_SUP_IN_FLIGHT_IDS=
  FM_SUP_WATCHER_FRESH=false
  FM_SUP_BEACON_DESC='unknown since when (watcher beat file missing or unreadable)'
  FM_SUP_QUEUE_PENDING=false

  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    FM_SUP_IN_FLIGHT=$((FM_SUP_IN_FLIGHT + 1))
    if [ -n "$FM_SUP_IN_FLIGHT_IDS" ]; then
      FM_SUP_IN_FLIGHT_IDS="$FM_SUP_IN_FLIGHT_IDS, $id"
    else
      FM_SUP_IN_FLIGHT_IDS=$id
    fi
  done
  [ -n "$FM_SUP_IN_FLIGHT_IDS" ] || FM_SUP_IN_FLIGHT_IDS='(none)'

  duration='unknown duration (unknown since when; watcher beat file missing or unreadable)'
  beat="$state/.last-watcher-beat"
  if [ -e "$beat" ]; then
    m=$(fm_sup_stat_mtime "$beat" || true)
    now=$(date +%s 2>/dev/null || true)
    case "$m:$now" in
      *[!0-9:]*) ;;
      :*|*:) ;;
      *)
        age=$((now - m))
        if [ "$age" -lt 0 ]; then
          age=$((-age))
          FM_SUP_BEACON_DESC="unknown since when (watcher beat timestamp is $(fm_sup_format_duration "$age") in the future)"
          duration="unknown duration (unknown since when; watcher beat timestamp is $(fm_sup_format_duration "$age") in the future)"
        else
          # shellcheck disable=SC2034 # Read by callers after sourcing.
          FM_SUP_BEACON_DESC="$(fm_sup_format_duration "$age") ago"
          duration="at least $(fm_sup_format_duration "$age") since the last watcher beat"
          [ "$age" -lt "$grace" ] && FM_SUP_WATCHER_FRESH=true
        fi
        ;;
    esac
  fi

  # shellcheck disable=SC2034 # Read by callers after sourcing.
  FM_SUP_OUTAGE_SUMMARY="SUPERVISION OUTAGE: down for $duration; $FM_SUP_IN_FLIGHT task(s) in flight: $FM_SUP_IN_FLIGHT_IDS."
  # shellcheck disable=SC2034 # Read by callers (fm-guard.sh) after sourcing.
  [ -s "$state/.wake-queue" ] && FM_SUP_QUEUE_PENDING=true
  return 0
}

# fm_supervision_unhealthy <state-dir> [grace-seconds]
# Exit 0 (true) exactly in the dangerous state: in-flight work exists and no
# watcher has a fresh beacon. Exit 1 (false) otherwise, including zero in-flight.
fm_supervision_unhealthy() {
  fm_supervision_status "$@"
  [ "$FM_SUP_IN_FLIGHT" -gt 0 ] && [ "$FM_SUP_WATCHER_FRESH" = false ]
}
