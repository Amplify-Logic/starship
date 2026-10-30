#!/usr/bin/env bash
# Once-per-local-day morning intake gate for a scheduled daily report.
#
# Usage:
#   fm-morning-intake.sh run [--force]
#   fm-morning-intake.sh claim
#   fm-morning-intake.sh complete --report FILE (--lavish FILE | --no-lavish REASON)
#                                 [--source-watermark VALUE]
#   fm-morning-intake.sh fail --reason TEXT
#   fm-morning-intake.sh rearm --reason TEXT
#   fm-morning-intake.sh check
#   fm-morning-intake.sh arm-check
#   fm-morning-intake.sh disarm-check
#   fm-morning-intake.sh pending
#   fm-morning-intake.sh acknowledge [REPORT]
#   fm-morning-intake.sh status
#   fm-morning-intake.sh reset
#   fm-morning-intake.sh interval
#   fm-morning-intake.sh --help
#
# This is a LOCAL GATE ONLY. It never reads a source system, never spawns an
# agent, never starts a session, and never takes the per-home session lock or
# the watcher lock, so it cannot compete with a live fleet. The one lock it does
# take is a private mutex over its own record (data/morning-intake/state.lock),
# so the scheduled run, the watcher check and a live claim cannot clobber each
# other's read-modify-write. `run` decides whether today's intake is
# owed and, when it is, records the durable armed state and appends one wake.
# The orchestrator does the actual ingestion and report writing, then calls
# `complete`; the intake is not finished until that call verifies a report.
# When that report is a captain-facing to-do, needs-you or waiting-on-you
# surface, the orchestrator loads the `daily-todo-freshness` skill before
# writing it.
#
# THE DAY'S PAGE IS PART OF COMPLETION, NOT AN EXTRA. Since the captain made
# the Lavish page the standard surface for the daily to-do, a markdown report
# alone is not the deliverable, so `complete` refuses without `--lavish`
# naming an existing, non-empty .html file under this home's .lavish/
# directory. A day that genuinely cannot have one completes with
# `--no-lavish REASON` instead: the reason is written into the day's durable
# record and printed by `status`, so a skipped page is visible rather than
# indistinguishable from a rendered one. The two are mutually exclusive and
# one of them is required.
#
# Two delivery paths reach the orchestrator, and neither one starts a session:
#
#   Live session - `arm-check` writes state/<label>.check.sh and binds it with
#   bin/fm-check-register.sh, so the running watcher executes it on its own slow
#   cadence and wakes the live primary through the established check path. The
#   shim runs `check`, which prints one line only while an intake is actually
#   owed and stays silent once that state has been surfaced, apart from the
#   12-hour backstop owned by check_signal below. `arm-check` is
#   idempotent: re-running it converges on the same registered state, and it
#   rebinds a shim whose bytes drifted away from the recorded binding. Nothing
#   re-creates that shim by itself, so `pending` reports it as lost while an
#   intake is armed or owed and names `arm-check` as the repair.
#
#   No session running - nothing is delivered at the time the job fires. The
#   armed state and the pending marker are durable, and the next session's
#   bootstrap section surfaces them through `pending`. So on a closed or
#   logged-out laptop the intake is QUEUED UNTIL FIRSTMATE NEXT STARTS. It is
#   not running, and nothing about this makes it start on lid-open.
#
# `run` is the scheduled entry point (bin/fm-morning-intake-schedule.sh installs
# it on macOS launchd) and is also the manual command: run it by hand at any
# time, with --force to arm an intake outside the configured window. --force
# does not clear the day's retry budget: on a spent budget it refuses and names
# `reset`, which is the single owner of that budget, rather than arming work
# `claim` would then refuse.
#
# Opening is defined as the FIRST AVAILABLE MORNING, not a lid-open event: there
# is no hardware event here. A laptop asleep or offline past the threshold arms
# the intake on the first run after it wakes, which is the catch-up path.
#
# The completion watermark (data/morning-intake/last-complete) advances ONLY in
# `complete`, and only after the named report is verified as a non-empty regular
# file. `fail` records a visible failure and never advances it, so a corrected
# source message published after a same-day failure is still ingested by the
# next run while attempts remain.
#
# Opt-in is per home and per device: with no `enabled = true` line in private
# config/morning-intake this command is inert, so cloning the repo or seeding
# another home never enrolls it.
#
# Configuration lives in private, gitignored config/morning-intake as
# `key = value` lines. Unknown keys are refused rather than ignored, so no
# secret, channel id, or account path can be parked in this file; those belong
# in the orchestrator's own private records.
#   enabled            true to arm this home (default false)
#   timezone           IANA zone for the local day, refused unless it actually
#                      resolves here (default: host local time)
#   start_time         HH:MM start-of-morning threshold (default 06:00)
#   interval_seconds   scheduled poll cadence (default 900)
#   max_attempts       bounded retries per local day (default 3)
#   retry_after_seconds  re-arm a claim that never completed (default 1800)
#   report_dir         directory the day's report must be written into
#   label              slug used in the wake key and diagnostic line
#                      (default morning-intake)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG_FILE="$CONFIG/morning-intake"
LAVISH_DIR="${FM_LAVISH_OVERRIDE:-$FM_HOME/.lavish}"
INTAKE_DIR="$DATA/morning-intake"
STATE_FILE="$INTAKE_DIR/state"
COMPLETE_FILE="$INTAKE_DIR/last-complete"
SOURCE_FILE="$INTAKE_DIR/source-watermark"
PENDING_FILE="$INTAKE_DIR/pending-report"
LOG_FILE="$INTAKE_DIR/log"
STATE_LOCK="$INTAKE_DIR/state.lock"

DEFAULT_START_TIME=06:00
DEFAULT_INTERVAL=900
DEFAULT_MAX_ATTEMPTS=3
DEFAULT_RETRY_AFTER=1800
DEFAULT_LABEL=morning-intake

CFG_ENABLED=false
CFG_TIMEZONE=
CFG_START_TIME=$DEFAULT_START_TIME
CFG_INTERVAL=$DEFAULT_INTERVAL
CFG_MAX_ATTEMPTS=$DEFAULT_MAX_ATTEMPTS
CFG_RETRY_AFTER=$DEFAULT_RETRY_AFTER
CFG_REPORT_DIR=
CFG_LABEL=$DEFAULT_LABEL

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-morning-intake: %s\n' "$*" >&2
  exit 2
}

# --- configuration ----------------------------------------------------------

require_positive_int() {
  local key=$1 value=$2
  case "$value" in
    ''|*[!0-9]*|0) die "$key must be a positive integer: $value" ;;
  esac
}

# date(1) treats a zone it cannot resolve as UTC and still exits 0, which would
# silently move both the local day and the start-of-morning threshold. The zone
# is therefore proven to resolve before anything is timed by it.
timezone_resolves() {
  local zone=$1 zonedir=${TZDIR:-/usr/share/zoneinfo} abbrev
  case "$zone" in
    UTC|Etc/UTC|GMT|Etc/GMT|Universal|Zulu) return 0 ;;
  esac
  if [ -d "$zonedir" ]; then
    [ -f "$zonedir/$zone" ]
    return
  fi
  # No zone database to read: fall back to the observable effect, since only an
  # unresolved zone reports UTC where a named non-UTC zone was configured.
  abbrev=$(TZ="$zone" date +%Z 2>/dev/null) || return 1
  case "$abbrev" in
    ''|UTC|GMT|-00|+00) return 1 ;;
  esac
  return 0
}

load_config() {
  local line key value
  [ -f "$CONFIG_FILE" ] || return 0
  [ ! -L "$CONFIG_FILE" ] || die "config must be a regular file: $CONFIG_FILE"
  while IFS= read -r line || [ -n "$line" ]; do
    line=$(printf '%s\n' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in
      *=*) ;;
      *) die "config line is not key = value: $line" ;;
    esac
    key=$(printf '%s\n' "${line%%=*}" | tr -d '[:space:]')
    value=$(printf '%s\n' "${line#*=}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    case "$key" in
      enabled)
        case "$value" in
          true|false) CFG_ENABLED=$value ;;
          *) die "enabled must be true or false: $value" ;;
        esac
        ;;
      timezone)
        [ -n "$value" ] || die 'timezone must name an IANA zone'
        case "$value" in
          *[!A-Za-z0-9/_+-]*) die "timezone contains unsupported characters" ;;
        esac
        timezone_resolves "$value" \
          || die "timezone does not resolve on this host: $value"
        CFG_TIMEZONE=$value
        ;;
      start_time)
        printf '%s\n' "$value" | grep -Eq '^([01][0-9]|2[0-3]):[0-5][0-9]$' \
          || die "start_time must be HH:MM in 24-hour form: $value"
        CFG_START_TIME=$value
        ;;
      interval_seconds) require_positive_int interval_seconds "$value"; CFG_INTERVAL=$value ;;
      max_attempts) require_positive_int max_attempts "$value"; CFG_MAX_ATTEMPTS=$value ;;
      retry_after_seconds) require_positive_int retry_after_seconds "$value"; CFG_RETRY_AFTER=$value ;;
      report_dir)
        case "$value" in
          /*) ;;
          *) die "report_dir must be an absolute path: $value" ;;
        esac
        CFG_REPORT_DIR=${value%/}
        ;;
      label)
        # Matches bin/fm-pr-lib.sh fm_task_id_path_safe, which the check
        # registration owner enforces: a label this file accepts but that owner
        # refuses would arm a shim the watcher then rejects on every sweep.
        case "$value" in
          ''|.*|*[!A-Za-z0-9._-]*) die "label must be a leading-dot-free slug of [A-Za-z0-9._-]: $value" ;;
        esac
        CFG_LABEL=$value
        ;;
      *) die "unknown config key: $key" ;;
    esac
  done <"$CONFIG_FILE"
}

enabled() {
  [ "$CFG_ENABLED" = true ]
}

require_enabled() {
  enabled || die "this home is not opted in; add 'enabled = true' to $CONFIG_FILE"
}

# --- clock ------------------------------------------------------------------

now_epoch() {
  local value=${FM_MORNING_INTAKE_NOW:-}
  if [ -n "$value" ]; then
    case "$value" in
      ''|*[!0-9]*) die "FM_MORNING_INTAKE_NOW must be an epoch second: $value" ;;
    esac
    printf '%s\n' "$value"
    return 0
  fi
  date +%s
}

# Render one strftime format for an epoch in the configured zone.
# TZ is scoped to the date call so nothing else in this process is retimed.
local_fmt() {
  local epoch=$1 fmt=$2
  if [ -n "$CFG_TIMEZONE" ]; then
    TZ="$CFG_TIMEZONE" date -r "$epoch" "+$fmt" 2>/dev/null \
      || TZ="$CFG_TIMEZONE" date -d "@$epoch" "+$fmt" 2>/dev/null \
      || die "cannot render local time; date(1) supports neither -r nor -d"
  else
    date -r "$epoch" "+$fmt" 2>/dev/null \
      || date -d "@$epoch" "+$fmt" 2>/dev/null \
      || die "cannot render local time; date(1) supports neither -r nor -d"
  fi
}

local_date() {
  local_fmt "$1" '%Y-%m-%d'
}

# True when the epoch is at or past today's configured start-of-morning.
past_threshold() {
  local epoch=$1 hhmm
  hhmm=$(local_fmt "$epoch" '%H:%M')
  [ "$hhmm" \> "$CFG_START_TIME" ] || [ "$hhmm" = "$CFG_START_TIME" ]
}

# --- durable state ----------------------------------------------------------

write_atomic() {
  local dest=$1 value=$2 parent tmp
  parent=${dest%/*}
  mkdir -p "$parent"
  tmp=$(umask 077; mktemp "$parent/.morning-intake.XXXXXX") || return 1
  printf '%s\n' "$value" >"$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp"
  mv -f "$tmp" "$dest"
}

read_line_file() {
  local file=$1 value=
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  IFS= read -r value <"$file" 2>/dev/null || true
  printf '%s\n' "$value"
}

ST_DATE=
ST_PHASE=idle
ST_ATTEMPTS=0
ST_UPDATED=0
ST_REPORT=
ST_ERROR=
ST_REARMS=0
ST_SURFACED=
ST_LAVISH=
ST_LAVISH_WAIVER=

load_state() {
  local line key value
  ST_DATE=; ST_PHASE=idle; ST_ATTEMPTS=0; ST_UPDATED=0
  ST_REPORT=; ST_ERROR=; ST_REARMS=0; ST_SURFACED=; ST_LAVISH=; ST_LAVISH_WAIVER=
  [ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      date) ST_DATE=$value ;;
      phase) ST_PHASE=$value ;;
      attempts) ST_ATTEMPTS=$value ;;
      updated) ST_UPDATED=$value ;;
      report) ST_REPORT=$value ;;
      error) ST_ERROR=$value ;;
      rearms) ST_REARMS=$value ;;
      surfaced) ST_SURFACED=$value ;;
      lavish) ST_LAVISH=$value ;;
      lavish_waiver) ST_LAVISH_WAIVER=$value ;;
    esac
  done <"$STATE_FILE"
  case "$ST_ATTEMPTS" in ''|*[!0-9]*) ST_ATTEMPTS=0 ;; esac
  case "$ST_UPDATED" in ''|*[!0-9]*) ST_UPDATED=0 ;; esac
  case "$ST_REARMS" in ''|*[!0-9]*) ST_REARMS=0 ;; esac
}

save_state() {
  local body parent tmp
  body=$(printf 'date=%s\nphase=%s\nattempts=%s\nupdated=%s\nrearms=%s\nsurfaced=%s\nreport=%s\nlavish=%s\nlavish_waiver=%s\nerror=%s' \
    "$ST_DATE" "$ST_PHASE" "$ST_ATTEMPTS" "$ST_UPDATED" "$ST_REARMS" \
    "$(sanitize "$ST_SURFACED")" "$(sanitize "$ST_REPORT")" \
    "$(sanitize "$ST_LAVISH")" "$(sanitize "$ST_LAVISH_WAIVER")" \
    "$(sanitize "$ST_ERROR")")
  parent=$INTAKE_DIR
  mkdir -p "$parent"
  tmp=$(umask 077; mktemp "$parent/.morning-intake.XXXXXX") || die 'cannot write state'
  printf '%s\n' "$body" >"$tmp" || { rm -f "$tmp"; die 'cannot write state'; }
  chmod 600 "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

sanitize() {
  printf '%s' "${1:-}" | LC_ALL=C tr '\t\r\n' '   '
}

WAKE_LIB_LOADED=false

load_wake_lib() {
  if [ "$WAKE_LIB_LOADED" != true ]; then
    # shellcheck source=bin/fm-wake-lib.sh disable=SC1091
    . "$SCRIPT_DIR/fm-wake-lib.sh"
    WAKE_LIB_LOADED=true
  fi
}

# The state file is read-modified-written by the scheduled `run`, by the
# watcher's `check`, and by a live `claim`/`complete`/`fail`, all in separate
# processes. They are serialized here on a mutex private to this gate's own
# data directory: not the per-home session lock, not the watcher lock, so a
# live fleet is never competed with.
#
# The watcher's sweep gets the shorter of the two bounds, so a wedged holder can
# never eat into FM_CHECK_TIMEOUT (30s by default); it simply stays silent and
# re-evaluates on the next sweep.
STATE_LOCK_WAIT=${FM_MORNING_INTAKE_LOCK_WAIT:-20}
case "$STATE_LOCK_WAIT" in
  ''|*[!0-9]*|0) die "FM_MORNING_INTAKE_LOCK_WAIT must be a positive integer: $STATE_LOCK_WAIT" ;;
esac
CHECK_LOCK_WAIT=$STATE_LOCK_WAIT
[ "$CHECK_LOCK_WAIT" -le 5 ] || CHECK_LOCK_WAIT=5
STATE_LOCK_HELD=false

lock_state() {
  local timeout=$1
  [ "$STATE_LOCK_HELD" != true ] || return 0
  load_wake_lib
  mkdir -p "$INTAKE_DIR"
  fm_lock_acquire_wait_bounded "$STATE_LOCK" "$timeout" || return 1
  STATE_LOCK_HELD=true
  trap 'unlock_state' EXIT
}

unlock_state() {
  [ "$STATE_LOCK_HELD" = true ] || return 0
  STATE_LOCK_HELD=false
  fm_lock_release "$STATE_LOCK"
}

require_state_lock() {
  lock_state "$STATE_LOCK_WAIT" \
    || die "another morning-intake command still holds $STATE_LOCK"
}

log_event() {
  mkdir -p "$INTAKE_DIR"
  umask 077
  printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ST_PHASE" "$(sanitize "$*")" \
    >>"$LOG_FILE"
}

last_complete_date() {
  read_line_file "$COMPLETE_FILE"
}

# --- wake delivery ----------------------------------------------------------

# One durable `check` wake, appended through the shared queue owner. This is the
# only fleet-visible side effect, and appending is not locking: no session lock
# is taken, no watcher is started, and no other home's state is touched.
enqueue_wake() {
  local day=$1 payload
  payload="$CFG_LABEL due for $day; run '$0 claim' to take it"
  load_wake_lib
  fm_wake_append check "$CFG_LABEL" "$payload"
}

# --- live-session delivery: the registered watcher check ---------------------

STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

check_path() {
  printf '%s/%s.check.sh\n' "$STATE_DIR" "$CFG_LABEL"
}

CHECK_LIB_LOADED=false

load_check_lib() {
  if [ "$CHECK_LIB_LOADED" != true ]; then
    # shellcheck source=bin/fm-pr-lib.sh disable=SC1091
    . "$SCRIPT_DIR/fm-pr-lib.sh"
    # shellcheck source=bin/fm-check-lib.sh disable=SC1091
    . "$SCRIPT_DIR/fm-check-lib.sh"
    CHECK_LIB_LOADED=true
  fi
}

# `armed` means exactly what the watcher means by it, asked of the registration
# owner rather than re-derived here: the shim exists and its current bytes are
# the bytes the trust record binds. A shim whose bytes drifted away from that
# binding reports as unregistered, because that is how a sweep treats it.
check_armed_state() {
  local check
  check=$(check_path)
  if [ ! -e "$check" ] && [ ! -L "$check" ]; then
    printf 'absent\n'
    return 0
  fi
  load_check_lib
  if fm_custom_check_registered "$STATE_DIR" "$CFG_LABEL" 2>/dev/null; then
    printf 'armed\n'
  else
    printf 'unregistered\n'
  fi
}

# The shim is deliberately tiny and byte-stable: it names this script and the
# home it belongs to and nothing else, so registering it once stays valid.
render_check_shim() {
  cat <<SHIM
#!/usr/bin/env bash
# Generated by bin/fm-morning-intake.sh arm-check. Do not edit; re-arm instead.
set -eu
FM_HOME='$FM_HOME' FM_ROOT_OVERRIDE='$ROOT' exec '$SCRIPT_DIR/fm-morning-intake.sh' check
SHIM
}

arm_check() {
  local check tmp
  [ "$#" -eq 0 ] || die 'arm-check takes no arguments'
  require_enabled
  [ -d "$STATE_DIR" ] && [ ! -L "$STATE_DIR" ] || mkdir -p "$STATE_DIR"
  check=$(check_path)
  [ ! -L "$check" ] || die "check path is a symlink: $check"
  umask 077
  tmp=$(mktemp "$STATE_DIR/.morning-intake-check.XXXXXX") || die 'cannot stage the check shim'
  render_check_shim >"$tmp" || { rm -f "$tmp"; die 'cannot write the check shim'; }
  chmod 0700 "$tmp" || { rm -f "$tmp"; die 'cannot set check shim mode'; }
  # Re-arming is idempotent by rewriting the byte-stable shim and rebinding it,
  # so a second run converges on the same registered state and a shim whose
  # bytes drifted is re-registered rather than left for the sweep to reject.
  # The staged file is never left behind on a failed install.
  mv -f "$tmp" "$check" || { rm -f "$tmp"; die "cannot install the check shim: $check"; }
  # The watcher refuses to execute an unregistered custom check, so binding the
  # bytes through the registration owner is what makes this path live. An
  # unregistered shim left in state/ is worse than no shim at all: the watcher
  # rejects it and wakes the primary about it on every sweep, and the PR-check
  # migration owner starts reporting the home as unmigrated. So arming is
  # all-or-nothing, the way bin/fm-bootstrap.sh x_mode_setup already is.
  if ! "$SCRIPT_DIR/fm-check-register.sh" "$CFG_LABEL"; then
    rm -f -- "$check" 2>/dev/null || true
    rm -f -- "$STATE_DIR/$CFG_LABEL.check-trust" 2>/dev/null || true
    [ ! -e "$check" ] \
      || die "check registration failed and the shim could not be removed: $check"
    die "check registration failed for $CFG_LABEL"
  fi
}

disarm_check() {
  local check
  [ "$#" -eq 0 ] || die 'disarm-check takes no arguments'
  check=$(check_path)
  rm -f "$check" "$STATE_DIR/$CFG_LABEL.check-trust"
  printf 'disarmed: %s\n' "$check"
}

# The watcher contract: print exactly one line when firstmate should wake, print
# nothing otherwise, and finish well inside FM_CHECK_TIMEOUT. Suppression is by
# state signature, so a still-owed intake wakes the primary once per state and
# any real state change re-arms the signal. An unchanged state wakes again at
# most every CHECK_BACKSTOP seconds, which bounds a wake lost before delivery.
CHECK_BACKSTOP=43200

check_signal() {
  local epoch day signature seen line=
  [ "$#" -eq 0 ] || die 'check takes no arguments'
  enabled || return 0
  epoch=$(now_epoch)
  day=$(local_date "$epoch")
  # A sweep that cannot get the lock quickly stays silent rather than blocking
  # the watcher or overwriting a claim in flight; the next sweep re-evaluates.
  lock_state "$CHECK_LOCK_WAIT" || return 0
  load_state
  [ "$ST_DATE" = "$day" ] || { unlock_state; return 0; }
  case "$ST_PHASE" in
    due)
      line="$CFG_LABEL due for $day; take it with '$SCRIPT_DIR/fm-morning-intake.sh claim'"
      ;;
    claimed)
      [ $((epoch - ST_UPDATED)) -ge "$CFG_RETRY_AFTER" ] || { unlock_state; return 0; }
      line="$CFG_LABEL claim for $day stalled after $((epoch - ST_UPDATED))s"
      ;;
    failed)
      line="$CFG_LABEL failed for $day (attempt $ST_ATTEMPTS of $CFG_MAX_ATTEMPTS): ${ST_ERROR:-unspecified failure}"
      ;;
    *) unlock_state; return 0 ;;
  esac
  signature="$ST_PHASE:$ST_ATTEMPTS:$ST_REARMS:$ST_UPDATED"
  seen=${ST_SURFACED##*|}
  case "$seen" in ''|*[!0-9]*) seen=0 ;; esac
  if [ "$ST_SURFACED" = "$signature|$seen" ] && [ "$epoch" -ge "$seen" ] && [ $((epoch - seen)) -lt "$CHECK_BACKSTOP" ]; then
    unlock_state
    return 0
  fi
  ST_SURFACED="$signature|$epoch"
  save_state
  unlock_state
  printf '%s\n' "$line"
}

# --- commands ---------------------------------------------------------------

run_intake() {
  local force=false epoch day complete age reason
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force) force=true; shift ;;
      *) die "unknown run argument: $1" ;;
    esac
  done

  if ! enabled; then
    # Inert by design on a home that never opted in.
    return 0
  fi
  epoch=$(now_epoch)
  day=$(local_date "$epoch")
  require_state_lock
  load_state
  complete=$(last_complete_date)

  if [ "$ST_DATE" != "$day" ]; then
    # A new local day resets attempts; yesterday's failure never blocks today.
    ST_DATE=$day; ST_PHASE=idle; ST_ATTEMPTS=0; ST_REARMS=0; ST_REPORT=; ST_ERROR=; ST_SURFACED=
    ST_LAVISH=; ST_LAVISH_WAIVER=
  fi

  if [ "$force" != true ]; then
    if [ "$complete" = "$day" ]; then
      return 0
    fi
    past_threshold "$epoch" || return 0
    case "$ST_PHASE" in
      due)
        # Already armed for today: never enqueue a second wake for one day.
        return 0
        ;;
      claimed)
        age=$((epoch - ST_UPDATED))
        [ "$age" -ge "$CFG_RETRY_AFTER" ] || return 0
        reason="claim did not complete within ${CFG_RETRY_AFTER}s"
        ;;
      failed)
        reason="retrying after: ${ST_ERROR:-unspecified failure}"
        ;;
      *) reason='first arm of the local day' ;;
    esac
    if [ "$ST_ATTEMPTS" -ge "$CFG_MAX_ATTEMPTS" ]; then
      # Visible, terminal-for-today failure state. No silent success, no loop.
      printf 'MORNING_INTAKE: %s failed for %s after %s attempts - %s\n' \
        "$CFG_LABEL" "$day" "$ST_ATTEMPTS" "${ST_ERROR:-no report completed}"
      return 0
    fi
  else
    reason='manual --force arm'
    # --force buys a manual arm outside the configured window. It does NOT buy
    # a fresh budget: bounded retry is a hard requirement and `reset` is the
    # single owner of the budget. Arming past an exhausted budget would set the
    # day due and wake the primary for work `claim` then refuses, so refuse
    # here instead, before any state is written or any wake is appended.
    [ "$ST_ATTEMPTS" -lt "$CFG_MAX_ATTEMPTS" ] \
      || die "attempt budget exhausted for $day ($ST_ATTEMPTS/$CFG_MAX_ATTEMPTS); give it back with '$0 reset' before forcing an arm"
  fi

  ST_PHASE=due
  ST_UPDATED=$epoch
  ST_SURFACED=
  save_state
  log_event "armed: $reason"
  enqueue_wake "$day" || die 'could not append the wake record'
  printf 'MORNING_INTAKE: %s due for %s (%s)\n' "$CFG_LABEL" "$day" "$reason"
}

claim_intake() {
  local epoch day
  [ "$#" -eq 0 ] || die 'claim takes no arguments'
  require_enabled
  epoch=$(now_epoch)
  day=$(local_date "$epoch")
  require_state_lock
  load_state
  [ "$ST_DATE" = "$day" ] || die "no intake is armed for $day; run '$0 run --force' first"
  case "$ST_PHASE" in
    due|failed) ;;
    claimed)
      [ $((epoch - ST_UPDATED)) -ge "$CFG_RETRY_AFTER" ] \
        || die "an intake claim for $day is still active"
      ;;
    *) die "no intake is armed for $day (phase: $ST_PHASE)" ;;
  esac
  [ "$ST_ATTEMPTS" -lt "$CFG_MAX_ATTEMPTS" ] \
    || die "attempt budget exhausted for $day ($ST_ATTEMPTS/$CFG_MAX_ATTEMPTS)"
  ST_ATTEMPTS=$((ST_ATTEMPTS + 1))
  ST_PHASE=claimed
  ST_UPDATED=$epoch
  ST_ERROR=
  ST_SURFACED=
  save_state
  log_event "claimed attempt $ST_ATTEMPTS"
  printf 'local_date: %s\n' "$day"
  printf 'attempt: %s of %s\n' "$ST_ATTEMPTS" "$CFG_MAX_ATTEMPTS"
  printf 'todo_composition: write action metadata and details-only morning HTML per %s/fm-todo-render.sh --help; render the unified page before complete\n' "$SCRIPT_DIR"
  printf 'source_watermark: %s\n' "$(read_line_file "$SOURCE_FILE")"
  [ -z "$CFG_REPORT_DIR" ] || printf 'report_dir: %s\n' "$CFG_REPORT_DIR"
}

# The day's Lavish page. A captain-facing surface is the deliverable, so this
# is proven the same way the report is - an existing, non-empty regular file,
# under this home's own .lavish/ directory and named .html - rather than taken
# on the orchestrator's word. When a matching morning fragment exists,
# completion composes it through bin/fm-todo-render.sh before publishing success.
require_lavish_page() {
  local page=$1
  case "$page" in
    /*) ;;
    *) die "--lavish must be an absolute path: $page" ;;
  esac
  case "/$page/" in
    */../*) die "--lavish must not contain a .. path component: $page" ;;
  esac
  case "$page" in
    "$LAVISH_DIR"/*) ;;
    *) die "--lavish must name a page under $LAVISH_DIR: $page" ;;
  esac
  case "$page" in
    *.html) ;;
    *) die "--lavish must name an .html page: $page" ;;
  esac
  [ -f "$page" ] && [ ! -L "$page" ] || die "lavish page is not a regular file: $page"
  [ -s "$page" ] || die "lavish page is empty: $page"
}

complete_intake() {
  local report='' watermark='' lavish='' waiver='' epoch day
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --report) [ "$#" -ge 2 ] || die '--report requires a value'; report=$2; shift 2 ;;
      --lavish) [ "$#" -ge 2 ] || die '--lavish requires a value'; lavish=$2; shift 2 ;;
      --no-lavish) [ "$#" -ge 2 ] || die '--no-lavish requires a reason'; waiver=$2; shift 2 ;;
      --source-watermark) [ "$#" -ge 2 ] || die '--source-watermark requires a value'; watermark=$2; shift 2 ;;
      *) die "unknown complete argument: $1" ;;
    esac
  done
  require_enabled
  [ -n "$report" ] || die '--report is required'
  case "$report" in
    /*) ;;
    *) die "--report must be an absolute path: $report" ;;
  esac
  # The watermark advances only behind a report that actually exists. A partial
  # or aborted intake therefore cannot mark the day done.
  [ -f "$report" ] && [ ! -L "$report" ] || die "report is not a regular file: $report"
  [ -s "$report" ] || die "report is empty: $report"
  if [ -n "$CFG_REPORT_DIR" ]; then
    case "$report" in
      "$CFG_REPORT_DIR"/*) ;;
      *) die "report is outside the configured report_dir: $report" ;;
    esac
  fi
  # The page is proved after the report, so the primary deliverable's own
  # refusal is still the one an operator sees when both are wrong.
  [ -z "$lavish" ] || [ -z "$waiver" ] \
    || die 'pass --lavish or --no-lavish, not both'
  if [ -n "$lavish" ]; then
    require_lavish_page "$lavish"
  else
    [ -n "$waiver" ] \
      || die "--lavish is required; the day's page under $LAVISH_DIR is the captain-facing deliverable, or complete with --no-lavish REASON"
  fi
  epoch=$(now_epoch)
  day=$(local_date "$epoch")
  require_state_lock
  load_state
  [ "$ST_DATE" = "$day" ] || die "no intake is armed for $day"
  [ "$ST_PHASE" = claimed ] || die "complete requires a claimed intake (phase: $ST_PHASE)"

  if [ -n "$lavish" ] && [ -f "${lavish%.html}.morning.html" ]; then
    FM_TODO_RENDER_NOW="$epoch" "$SCRIPT_DIR/fm-todo-render.sh" render \
      --out "$lavish" --date "$day" \
      || die 'morning composition failed; intake remains claimed'
  fi

  ST_PHASE=complete
  ST_UPDATED=$epoch
  ST_REPORT=$report
  ST_LAVISH=$lavish
  ST_LAVISH_WAIVER=$waiver
  ST_ERROR=
  save_state
  write_atomic "$PENDING_FILE" "$report" || die 'cannot record the pending report'
  [ -z "$watermark" ] || write_atomic "$SOURCE_FILE" "$watermark" \
    || die 'cannot record the source watermark'
  # Last, and only now: the day is done.
  write_atomic "$COMPLETE_FILE" "$day" || die 'cannot advance the completion watermark'
  if [ -n "$lavish" ]; then
    log_event "completed with report $report and page $lavish"
    printf 'MORNING_INTAKE: %s complete for %s - report %s, page %s\n' \
      "$CFG_LABEL" "$day" "$report" "$lavish"
  else
    log_event "completed with report $report and no page: $waiver"
    printf 'MORNING_INTAKE: %s complete for %s - report %s, NO PAGE: %s\n' \
      "$CFG_LABEL" "$day" "$report" "$waiver"
  fi
}

fail_intake() {
  local reason='' epoch day
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) [ "$#" -ge 2 ] || die '--reason requires a value'; reason=$2; shift 2 ;;
      *) die "unknown fail argument: $1" ;;
    esac
  done
  require_enabled
  [ -n "$reason" ] || die '--reason is required'
  epoch=$(now_epoch)
  day=$(local_date "$epoch")
  require_state_lock
  load_state
  [ "$ST_DATE" = "$day" ] || die "no intake is armed for $day"
  # An attempt that was never claimed is still an attempt. Counting it here is
  # what keeps the retry budget honest: without it a failure recorded before a
  # claim would leave attempts at zero and let `run` re-arm on every poll, all
  # day, and the exhausted terminal state would never be reached. `reset`
  # remains the only way to give a spent budget back.
  case "$ST_PHASE" in
    claimed|failed) ;;
    *) ST_ATTEMPTS=$((ST_ATTEMPTS + 1)) ;;
  esac
  ST_PHASE=failed
  ST_UPDATED=$epoch
  ST_ERROR=$reason
  ST_SURFACED=
  save_state
  log_event "failed: $reason"
  printf 'MORNING_INTAKE: %s failed for %s (attempt %s of %s) - %s\n' \
    "$CFG_LABEL" "$day" "$ST_ATTEMPTS" "$CFG_MAX_ATTEMPTS" "$reason"
}

# Re-arm an already-completed day. This exists for exactly one case: the source
# published a revision after the day's report completed, so the day's content is
# stale even though its watermark is set. Bounded by max_attempts so a revision
# storm cannot loop.
rearm_intake() {
  local reason='' epoch day
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) [ "$#" -ge 2 ] || die '--reason requires a value'; reason=$2; shift 2 ;;
      *) die "unknown rearm argument: $1" ;;
    esac
  done
  require_enabled
  [ -n "$reason" ] || die '--reason is required'
  epoch=$(now_epoch)
  day=$(local_date "$epoch")
  require_state_lock
  load_state
  if [ "$ST_DATE" != "$day" ]; then
    # Same new-local-day reset `run` performs: yesterday's spent budget and
    # yesterday's report path never carry into today's first re-arm.
    ST_DATE=$day; ST_PHASE=idle; ST_ATTEMPTS=0; ST_REARMS=0; ST_REPORT=; ST_ERROR=; ST_SURFACED=
    ST_LAVISH=; ST_LAVISH_WAIVER=
  fi
  [ "$ST_ATTEMPTS" -lt "$CFG_MAX_ATTEMPTS" ] \
    || die "attempt budget exhausted for $day ($ST_ATTEMPTS/$CFG_MAX_ATTEMPTS)"
  ST_PHASE=due
  ST_UPDATED=$epoch
  ST_REARMS=$((ST_REARMS + 1))
  ST_REPORT=
  # The page is re-proved by the next `complete`, never inherited from the
  # revision this re-arm just superseded.
  ST_LAVISH=
  ST_LAVISH_WAIVER=
  ST_ERROR=
  ST_SURFACED=
  save_state
  log_event "rearmed: $reason"
  enqueue_wake "$day" || die 'could not append the wake record'
  printf 'MORNING_INTAKE: %s re-armed for %s - %s\n' "$CFG_LABEL" "$day" "$reason"
}

safe_pending_report() {
  local report
  report=$(read_line_file "$PENDING_FILE")
  [ -n "$report" ] || return 1
  case "$report" in
    /*) ;;
    *) return 1 ;;
  esac
  if [ -n "$CFG_REPORT_DIR" ]; then
    case "$report" in
      "$CFG_REPORT_DIR"/*) ;;
      *) return 1 ;;
    esac
  fi
  [ -f "$report" ] && [ ! -L "$report" ] || return 1
  printf '%s\n' "$report"
}

# True when this local day still has intake work: an armed, claimed or failed
# record for today, or a day past its threshold whose completion watermark has
# not been written yet. Callers must have loaded state.
intake_armed_or_owed() {
  local epoch=$1 day=$2
  if [ "$ST_DATE" = "$day" ]; then
    case "$ST_PHASE" in
      due|claimed|failed) return 0 ;;
    esac
  fi
  [ "$(last_complete_date)" != "$day" ] || return 1
  past_threshold "$epoch"
}

# Read-only. Prints at most one diagnostic-convention line per condition, and
# nothing at all on a home that is not opted in or has nothing owed.
pending() {
  local report day epoch armed
  [ "$#" -eq 0 ] || die 'pending takes no arguments'
  enabled || return 0
  load_state
  epoch=$(now_epoch)
  day=$(local_date "$epoch")
  report=$(safe_pending_report 2>/dev/null || true)
  if [ -n "$report" ]; then
    printf 'MORNING_INTAKE: new %s report at %s\n' "$CFG_LABEL" "$report"
  fi
  if [ "$ST_DATE" = "$day" ]; then
    case "$ST_PHASE" in
      due)
        printf 'MORNING_INTAKE: %s due for %s - claim it with %s claim\n' \
          "$CFG_LABEL" "$day" "$0"
        ;;
      claimed)
        [ $((epoch - ST_UPDATED)) -lt "$CFG_RETRY_AFTER" ] || \
          printf 'MORNING_INTAKE: %s claim for %s stalled after %ss - rerun %s run\n' \
            "$CFG_LABEL" "$day" "$((epoch - ST_UPDATED))" "$0"
        ;;
      failed)
        printf 'MORNING_INTAKE: %s failed for %s (attempt %s of %s) - %s\n' \
          "$CFG_LABEL" "$day" "$ST_ATTEMPTS" "$CFG_MAX_ATTEMPTS" "${ST_ERROR:-unspecified failure}"
        ;;
    esac
  fi
  # Nothing re-creates the live-session shim once it is gone, so a cleaned or
  # half-registered state directory silently drops that delivery path and
  # leaves this session-start surface as the only one. Report the loss where an
  # operator already looks, and name the one command that repairs it. This
  # stays read-only on purpose: re-arming writes into state/, and session start
  # must not pay a mutation on every home just to keep a per-device opt-in.
  intake_armed_or_owed "$epoch" "$day" || return 0
  armed=$(check_armed_state)
  [ "$armed" != armed ] || return 0
  printf 'MORNING_INTAKE: %s live check is %s for %s - re-arm it with %s arm-check\n' \
    "$CFG_LABEL" "$armed" "$day" "$0"
}

acknowledge() {
  local expected=${1:-} current
  current=$(safe_pending_report 2>/dev/null || true)
  [ -n "$current" ] || return 0
  if [ -n "$expected" ] && [ "$expected" != "$current" ]; then
    die "pending report changed (current: $current)"
  fi
  rm -f "$PENDING_FILE"
}

# Prints only the declared operating knobs and durable state. No config value
# outside the known-key set can exist, so there is nothing else to withhold.
status_intake() {
  local epoch
  [ "$#" -eq 0 ] || die 'status takes no arguments'
  load_state
  epoch=$(now_epoch)
  printf 'config: %s\n' "$CONFIG_FILE"
  printf 'enabled: %s\n' "$CFG_ENABLED"
  printf 'timezone: %s\n' "${CFG_TIMEZONE:-<host local time>}"
  printf 'start_time: %s\n' "$CFG_START_TIME"
  printf 'interval_seconds: %s\n' "$CFG_INTERVAL"
  printf 'max_attempts: %s\n' "$CFG_MAX_ATTEMPTS"
  printf 'retry_after_seconds: %s\n' "$CFG_RETRY_AFTER"
  printf 'report_dir: %s\n' "${CFG_REPORT_DIR:-<unset>}"
  printf 'label: %s\n' "$CFG_LABEL"
  printf 'local_date_now: %s\n' "$(local_date "$epoch")"
  printf 'last_complete: %s\n' "$(last_complete_date)"
  printf 'source_watermark: %s\n' "$(read_line_file "$SOURCE_FILE")"
  printf 'state_date: %s\n' "$ST_DATE"
  printf 'state_phase: %s\n' "$ST_PHASE"
  printf 'state_attempts: %s\n' "$ST_ATTEMPTS"
  printf 'state_rearms: %s\n' "$ST_REARMS"
  printf 'state_surfaced: %s\n' "$ST_SURFACED"
  printf 'check_armed: %s\n' "$(check_armed_state)"
  printf 'state_report: %s\n' "$ST_REPORT"
  printf 'state_lavish: %s\n' "$ST_LAVISH"
  printf 'state_lavish_waiver: %s\n' "$ST_LAVISH_WAIVER"
  printf 'state_error: %s\n' "$ST_ERROR"
}

reset_intake() {
  [ "$#" -eq 0 ] || die 'reset takes no arguments'
  require_enabled
  require_state_lock
  load_state
  ST_PHASE=idle
  ST_ATTEMPTS=0
  ST_REARMS=0
  ST_ERROR=
  ST_UPDATED=$(now_epoch)
  save_state
  log_event 'reset attempt budget'
  printf 'reset: %s attempt budget cleared for %s\n' "$CFG_LABEL" "${ST_DATE:-<no armed day>}"
}

# The interval is read by the schedule owner, which must not duplicate parsing.
print_interval() {
  [ "$#" -eq 0 ] || die 'interval takes no arguments'
  printf '%s\n' "$CFG_INTERVAL"
}

load_config

case "${1:-}" in
  run) shift; run_intake "$@" ;;
  claim) shift; claim_intake "$@" ;;
  complete) shift; complete_intake "$@" ;;
  fail) shift; fail_intake "$@" ;;
  rearm) shift; rearm_intake "$@" ;;
  check) shift; check_signal "$@" ;;
  arm-check) shift; arm_check "$@" ;;
  disarm-check) shift; disarm_check "$@" ;;
  pending) shift; pending "$@" ;;
  acknowledge) shift; [ "$#" -le 1 ] || die 'acknowledge accepts at most one report path'; acknowledge "${1:-}" ;;
  status) shift; status_intake "$@" ;;
  reset) shift; reset_intake "$@" ;;
  interval) shift; print_interval "$@" ;;
  -h|--help) usage ;;
  '') usage; exit 2 ;;
  *) die "unknown command: $1" ;;
esac
