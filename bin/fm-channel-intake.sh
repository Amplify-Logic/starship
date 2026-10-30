#!/usr/bin/env bash
# Continuous channel intake: a local, opt-in ledger and repeat-poll gate.
#
# Usage:
#   fm-channel-intake.sh tick
#   fm-channel-intake.sh claim [--source ID]
#   fm-channel-intake.sh observe --source ID --ref REF (--digest TEXT | --digest-file FILE)
#                                [--class CLASS] [--title TEXT] [--link URL]
#                                [--dedup-key KEY] [--thread PARENT] [--reply-marker VALUE]
#                                [--source-epoch EPOCH] [--partner]
#                                [--partner-awaiting-since EPOCH]
# A new item needs a --title; a later re-read of a known one does not.
# --partner marks the ask partner- or customer-facing - a colleague relaying a
# partner question, a customer's own message - and the mark survives every
# later read. --partner-awaiting-since marks it partner-facing and awaiting the
# captain since that epoch second, which ranks it in the day page's partner-
# awaiting tier like a morning action's partner_awaiting and awaiting_since; a
# later read that passes it again moves the time, one that does not keeps it.
#   fm-channel-intake.sh complete --source ID --checkpoint VALUE [--relisted]
#   fm-channel-intake.sh fail --source ID --reason TEXT
#   fm-channel-intake.sh resolve --item KEY --reason TEXT [--waiting]
#   fm-channel-intake.sh items [--state open|waiting|archived|inactive]
#   fm-channel-intake.sh sources
#   fm-channel-intake.sh notify-due
#   fm-channel-intake.sh notify-sent --keys "KEY [KEY ...]"
#   fm-channel-intake.sh brief [--out FILE] [--open]
#   fm-channel-intake.sh todo [--out FILE] [--open]
#   fm-channel-intake.sh check
#   fm-channel-intake.sh arm-check
#   fm-channel-intake.sh disarm-check
#   fm-channel-intake.sh pending
#   fm-channel-intake.sh status
#   fm-channel-intake.sh interval
#   fm-channel-intake.sh --help
#
# WHAT THIS IS. A LOCAL GATE AND LEDGER ONLY. It never reads a source system,
# never opens a network connection, never spawns an agent, never sends a
# message, and never takes the per-home session lock or the watcher lock. It
# decides WHEN a source is worth reading, remembers WHAT has already been seen,
# and renders WHAT the captain still owes. An orchestrator does the actual
# connector read through its own authenticated path and reports back here.
#
# This is the repeat-poll sibling of bin/fm-morning-intake.sh. That gate is
# once per local day: after a day completes its `run` returns early, so a short
# scheduler interval only re-checks a satisfied day gate. This gate is per
# source and per interval instead, which is the whole reason it exists rather
# than being a shorter cadence on the morning gate. Everything else - the
# private mutex over its own record, the durable armed state, the single wake
# per armed cycle, the registered watcher check, and the rule that a watermark
# advances only behind captured output - is deliberately the same discipline.
#
# WHAT IT IS NOT. It writes nothing the Action Deck renders. An item classified
# `automation-candidate` is a PROPOSAL in the brief and nothing more: detecting
# that some device or account needs an action grants no permission to perform
# it, and this gate has no path that prepares, stages, or fires one. Executable
# deck cards stay with the action gateway and its per-action approval.
#
# DELIVERY. Two surfaces, both captain-private, neither of them sent from here:
#   `notify-due` renders ONE grouped, rate-limited, quiet-hours-aware private
#   direct-message payload and prints it. It does not send. The orchestrator
#   sends it on the configured recipient and then calls `notify-sent`, which is
#   what actually stamps the items. So an interrupted send re-renders rather
#   than being silently swallowed.
#   `brief` and `todo` render from the ledger every time, so a correction, a
#   resolution and a completed obligation reconcile across both by construction
#   instead of needing a second reconciliation pass.
#   `complete` additionally refreshes the day's Lavish page through
#   bin/fm-todo-render.sh when one already exists, so the captain's standard
#   to-do surface re-ranks itself on every read instead of being a snapshot of
#   the morning. No page exists yet, or a renderer that fails, is logged and
#   never fails the read.
#   Opening a rendered page is OPT-IN and never automatic. `--open` is what a
#   captain-requested render passes, and it is the only thing that opens
#   anything; a scheduled or background render always omits it, always
#   overwrites the same `--out` path, and never takes focus. The open is a
#   convenience on top of a render that already succeeded, so a missing or
#   failing opener is reported and the command still exits 0.
#
# COVERAGE IS STATED, NEVER IMPLIED. The enrolled sources are exactly the rows
# of the private inventory file, each with its own coverage sentence and its own
# checkpoint. Enrolling some channels does not enrol a workspace. A source whose
# last read failed reports `unknown`, never "nothing new".
#
# TWO DISCLOSED DETECTION LIMITS, both bounded by design and neither hidden:
#   Edit horizon. An in-place edit keeps the original source id, so a forward
#   cursor never returns it again. Re-detection therefore depends on the
#   orchestrator re-reading a bounded recent window (revision_window_seconds)
#   and re-`observe`ing it; the digest comparison here then updates the same
#   item. AN EDIT OLDER THAN THAT WINDOW IS NOT DETECTED. Widening the window
#   costs a proportional re-read on every tick.
#   Thread replies. A cursor read of a channel returns messages whose own id is
#   newer than the cursor, so a reply added to a thread whose parent predates
#   the cursor can appear in no such read. `observe --thread` records a per
#   parent reply marker and `claim` prints the tracked parents back, so the
#   orchestrator can re-read only the threads whose marker advanced. The tracked
#   set is BOUNDED by revision_window_seconds: a parent whose marker has not
#   advanced within that window leaves it, which is what keeps the claim output
#   and the connector work per tick from growing with all thread history. So
#   coverage is parents still inside that bounded set and NOTHING OLDER. No
#   completeness is claimed. docs/channel-intake.md owns both limits in full.
#
# PER-POLL WORK IS BOUNDED, HISTORY IS NOT DISCARDED. Every ledger surface
# reads a whole record directory in one process rather than one per field per
# record, and routine traffic older than the brief horizon that is the only
# place it is rendered (a team update after UPDATE_WINDOW) MOVES out of the
# polled set into `inactive/` with its record intact. Nothing is deleted,
# nothing is auto-resolved: `items` still lists it, `status` still counts it,
# and re-observing the same key restores it rather than opening a second item.
# Anything owed, waiting, corrected or already notified stays in the polled set
# whatever its age, except that a corrected team update leaves once its last
# change is past UPDATE_WINDOW.
#
# NO POLL LOOP CAN RUN AWAY. interval_seconds has a hard floor, a failing
# source backs off geometrically to a bounded ceiling instead of retrying
# harder, and `tick` enqueues at most one wake per armed cycle. A throttle
# reported by a connector is a reason to call `fail` and back off, never a
# reason to measure the ceiling by hitting it.
#
# RE-CHECK ON EVERY PASS. A claim that hands out any source also prints one
# `recheck:` line per open or waiting to-do item that names an external source
# (bin/fm-todo.sh `recheck` owns which items and the columns), so the pass
# re-reads what is already open instead of only what is new, and answers
# each line with `fm-todo.sh verify` or `close`. The claim records the
# listed ids and its own time; every `complete` then prints how many of them
# are still open with no re-read since the claim, and names them. No to-do
# store prints nothing.
#
# SOURCE KINDS. Each inventory row names its source's kind, a slug the home
# chooses. Every kind gets the checkpoint read; these kinds also carry one more
# line on a claim, because a checkpoint read alone misses what they hold:
#   slack-dms        `dms:` read each DM and group DM its coverage sentence
#                    names directly by conversation id, never through search,
#                    and observe every message to the captain, @mention or not.
#   calendar         `calendar:` the window from today through the next two
#                    working days: invites the captain has not answered, and
#                    events whose description asks for preparation.
#   asana*           `relist:` once per local day, every incomplete task
#                    assigned to the captain whatever its modified date;
#                    complete the read that included it with --relisted.
#   slack-announcements  team channels read for what they announce (below).
# Any other kind is read by its checkpoint alone. A ticket system or any other
# kind-specific read a home needs beyond these belongs in its private add-on
# (bin/fm-addon.sh), which may carry its own copy of this gate.
#
# A WAIT HAS A DATE OR A NAMED OWNER. `resolve --waiting` is for work handed
# to someone else. A reason is refused unless it names a date (YYYY-MM-DD, a
# full weekday name or mon/tue/thu/fri, tomorrow, next week, or a day number
# with a month) or states the hand-over to a capitalised name that is not the
# captain's ("waiting on/for Name", "routed to Name", "handed (over) to Name",
# "assigned to Name", "Name will ..."), because a wait left with the captain
# and no date is a park with no end.
#
# TEAM ANNOUNCEMENTS ARE INFORMATION, NOT ASKS. A `slack-announcements` source
# is a set of team channels the orchestrator reads for posts that announce a
# product or feature launch or change, a date or deadline, a price,
# availability or ordering change, or a process or policy change; everything
# else in those channels is not observed at all. A kept post is observed with
# `--class update`, which only a `slack-announcements` source accepts: it is
# never owed, never notifiable and never on the to-do list, the day page shows
# it in its "Updates" fold newest first, and it leaves the polled set like
# routine traffic but only after UPDATE_WINDOW. A post that asks the page's
# owner to act, or sets a deadline that is theirs, is observed with an owed
# class instead.
# docs/channel-intake.md owns which posts are kept, the title and date
# convention, and the durable updates log the orchestrator writes beside it.
#
# Opt-in is per home and per device: with no `enabled = true` line in private
# config/channel-intake this command is inert, so cloning the repo or seeding
# another home never enrols it.
#
# Configuration lives in private, gitignored config/channel-intake as
# `key = value` lines. Unknown keys are refused rather than ignored, so no
# secret or account path can be parked in this file. Source identities are not
# configuration: they live in the private inventory file below.
#   enabled                  true to arm this home (default false)
#   timezone                 IANA zone for the local day and quiet hours,
#                            refused unless it actually resolves here
#   interval_seconds         per-source poll cadence (default 900, floor 300)
#   sources_file             absolute path to the private inventory
#                            (default data/channel-intake/sources.tsv)
#   revision_window_seconds  bounded edit-detection lookback (default 86400)
#   stale_after_seconds      age at which a source reads stale (default 5400)
#   backoff_seconds          first backoff after a failed read (default 900)
#   backoff_max_seconds      backoff ceiling (default 21600)
#   quiet_start              HH:MM start of local quiet hours (default unset)
#   quiet_end                HH:MM end of local quiet hours (default unset)
#   active_start             HH:MM start of the local scanning window; outside
#                            it no source is ever due, so nothing reads and
#                            nothing wakes (default unset, meaning all day)
#   active_end               HH:MM end of the local scanning window; set with
#                            active_start, wraps midnight the same way quiet
#                            hours do (default unset)
#   notify_min_interval_seconds  minimum gap between payloads (default 1800)
#   notify_max_per_day       bounded payloads per local day (default 8)
#   notify_recipient         the private direct-message recipient
#   notify_recipient_verified  true only after the recipient was checked
#                            against the known captain account; notifications
#                            are refused until it is
#   report_dir               directory brief/todo output must be written into
#   open_command             opener for a captain-requested `--open` render
#                            (default `open` on macOS, else `xdg-open`); a
#                            missing or failing opener is reported and the
#                            render still succeeds
#   label                    slug for the wake key and diagnostic line
#                            (default channel-intake)
#   captain_names            words that name the captain, e.g. a first and last
#                            name; a wait handed to one of them is not a
#                            hand-over, and the day page counts a closure by
#                            one of them as the captain's own (default unset)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG_FILE="$CONFIG/channel-intake"
INTAKE_DIR="$DATA/channel-intake"
SOURCE_DIR="$INTAKE_DIR/sources"
THREAD_DIR="$INTAKE_DIR/threads"
ITEM_DIR="$INTAKE_DIR/items"
ARCHIVE_DIR="$INTAKE_DIR/archive"
INACTIVE_DIR="$INTAKE_DIR/inactive"
NOTIFY_FILE="$INTAKE_DIR/notify-state"
ARMED_FILE="$INTAKE_DIR/armed"
LATENCY_LOG="$INTAKE_DIR/latency.log"
LOG_FILE="$INTAKE_DIR/log"
STATE_LOCK="$INTAKE_DIR/state.lock"
RECHECK_FILE="$INTAKE_DIR/recheck"
TODO_STORE="${FM_TODO_STORE_OVERRIDE:-$DATA/todo}"

# The floor is a quota guard, not a preference: below it a laptop awake all day
# multiplies every enrolled source by an unbounded call count.
MIN_INTERVAL=300
DEFAULT_INTERVAL=900
DEFAULT_REVISION_WINDOW=86400
DEFAULT_STALE_AFTER=5400
DEFAULT_BACKOFF=900
DEFAULT_BACKOFF_MAX=21600
DEFAULT_NOTIFY_MIN_INTERVAL=1800
DEFAULT_NOTIFY_MAX_PER_DAY=8
DEFAULT_LABEL=channel-intake

# Notifiable classes are the three the captain named. `outage` is the only one
# that survives quiet hours, which is what "preserve real severity" means here.
NOTIFY_CLASSES='urgent outage deadline'
QUIET_BYPASS_CLASSES='outage'
ALL_CLASSES='urgent outage deadline routine obligation automation-candidate update'
# A kept team announcement stays on the day page's Updates fold this long
# before it leaves the polled set the way routine traffic does.
UPDATE_WINDOW=1209600

CFG_ENABLED=false
CFG_TIMEZONE=
CFG_INTERVAL=$DEFAULT_INTERVAL
CFG_SOURCES_FILE=
CFG_REVISION_WINDOW=$DEFAULT_REVISION_WINDOW
CFG_STALE_AFTER=$DEFAULT_STALE_AFTER
CFG_BACKOFF=$DEFAULT_BACKOFF
CFG_BACKOFF_MAX=$DEFAULT_BACKOFF_MAX
CFG_QUIET_START=
CFG_QUIET_END=
CFG_ACTIVE_START=
CFG_ACTIVE_END=
CFG_NOTIFY_MIN_INTERVAL=$DEFAULT_NOTIFY_MIN_INTERVAL
CFG_NOTIFY_MAX_PER_DAY=$DEFAULT_NOTIFY_MAX_PER_DAY
CFG_NOTIFY_RECIPIENT=
CFG_NOTIFY_VERIFIED=false
CFG_REPORT_DIR=
CFG_OPEN_COMMAND=
CFG_LABEL=$DEFAULT_LABEL
CFG_CAPTAIN_NAMES=

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-channel-intake: %s\n' "$*" >&2
  exit 2
}

# Tabs and newlines would break the one-line `key=value` record format; the
# unit separator would break the column format `scan_records` hands back.
sanitize() {
  printf '%s' "${1:-}" | LC_ALL=C tr '\t\r\n\037' '    '
}

# A NON-whitespace column separator on purpose: tab is an IFS whitespace
# character, so `read` would merge two adjacent empty columns into one and
# shift every later field of the row.
FIELD_SEP=$'\037'

# --- configuration ----------------------------------------------------------

require_positive_int() {
  local key=$1 value=$2
  case "$value" in
    ''|*[!0-9]*|0) die "$key must be a positive integer: $value" ;;
  esac
}

require_hhmm() {
  local key=$1 value=$2
  printf '%s\n' "$value" | grep -Eq '^([01][0-9]|2[0-3]):[0-5][0-9]$' \
    || die "$key must be HH:MM in 24-hour form: $value"
}

# Same contract as bin/fm-morning-intake.sh: date(1) treats a zone it cannot
# resolve as UTC and still exits 0, which would silently move both the local
# day and the quiet-hours window.
timezone_resolves() {
  local zone=$1 zonedir=${TZDIR:-/usr/share/zoneinfo} abbrev
  case "$zone" in
    UTC|Etc/UTC|GMT|Etc/GMT|Universal|Zulu) return 0 ;;
  esac
  if [ -d "$zonedir" ]; then
    [ -f "$zonedir/$zone" ]
    return
  fi
  abbrev=$(TZ="$zone" date +%Z 2>/dev/null) || return 1
  case "$abbrev" in
    ''|UTC|GMT|-00|+00) return 1 ;;
  esac
  return 0
}

load_config() {
  local line key value
  CFG_SOURCES_FILE="$INTAKE_DIR/sources.tsv"
  if [ -f "$CONFIG_FILE" ]; then
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
            *[!A-Za-z0-9/_+-]*) die 'timezone contains unsupported characters' ;;
          esac
          timezone_resolves "$value" \
            || die "timezone does not resolve on this host: $value"
          CFG_TIMEZONE=$value
          ;;
        interval_seconds)
          require_positive_int interval_seconds "$value"
          [ "$value" -ge "$MIN_INTERVAL" ] \
            || die "interval_seconds must be at least ${MIN_INTERVAL}s so an awake laptop cannot run an unbounded poll loop: $value"
          CFG_INTERVAL=$value
          ;;
        sources_file)
          case "$value" in
            /*) ;;
            *) die "sources_file must be an absolute path: $value" ;;
          esac
          CFG_SOURCES_FILE=$value
          ;;
        revision_window_seconds)
          require_positive_int revision_window_seconds "$value"; CFG_REVISION_WINDOW=$value ;;
        stale_after_seconds)
          require_positive_int stale_after_seconds "$value"; CFG_STALE_AFTER=$value ;;
        backoff_seconds) require_positive_int backoff_seconds "$value"; CFG_BACKOFF=$value ;;
        backoff_max_seconds)
          require_positive_int backoff_max_seconds "$value"; CFG_BACKOFF_MAX=$value ;;
        quiet_start) require_hhmm quiet_start "$value"; CFG_QUIET_START=$value ;;
        quiet_end) require_hhmm quiet_end "$value"; CFG_QUIET_END=$value ;;
        active_start) require_hhmm active_start "$value"; CFG_ACTIVE_START=$value ;;
        active_end) require_hhmm active_end "$value"; CFG_ACTIVE_END=$value ;;
        notify_min_interval_seconds)
          require_positive_int notify_min_interval_seconds "$value"
          CFG_NOTIFY_MIN_INTERVAL=$value ;;
        notify_max_per_day)
          require_positive_int notify_max_per_day "$value"; CFG_NOTIFY_MAX_PER_DAY=$value ;;
        notify_recipient)
          [ -n "$value" ] || die 'notify_recipient must not be empty'
          case "$value" in
            *[[:space:]]*) die "notify_recipient must be a single token: $value" ;;
          esac
          CFG_NOTIFY_RECIPIENT=$value
          ;;
        notify_recipient_verified)
          case "$value" in
            true|false) CFG_NOTIFY_VERIFIED=$value ;;
            *) die "notify_recipient_verified must be true or false: $value" ;;
          esac
          ;;
        report_dir)
          case "$value" in
            /*) ;;
            *) die "report_dir must be an absolute path: $value" ;;
          esac
          CFG_REPORT_DIR=${value%/}
          ;;
        open_command)
          [ -n "$value" ] || die 'open_command must not be empty'
          case "$value" in
            *[[:space:]]*) die "open_command must be a single command with no arguments: $value" ;;
          esac
          CFG_OPEN_COMMAND=$value
          ;;
        label)
          # Matches bin/fm-pr-lib.sh fm_task_id_path_safe, which the check
          # registration owner enforces; a label accepted here but refused
          # there would arm a shim the watcher rejects on every sweep.
          case "$value" in
            ''|.*|*[!A-Za-z0-9._-]*) die "label must be a leading-dot-free slug of [A-Za-z0-9._-]: $value" ;;
          esac
          CFG_LABEL=$value
          ;;
        captain_names)
          case "$value" in
            *[!A-Za-z[:space:]\'-]*) die "captain_names must be plain words: $value" ;;
          esac
          CFG_CAPTAIN_NAMES=$value
          ;;
        *) die "unknown config key: $key" ;;
      esac
    done <"$CONFIG_FILE"
  fi
  [ "$CFG_BACKOFF_MAX" -ge "$CFG_BACKOFF" ] \
    || die "backoff_max_seconds must not be below backoff_seconds"
  if [ -n "$CFG_QUIET_START" ] || [ -n "$CFG_QUIET_END" ]; then
    [ -n "$CFG_QUIET_START" ] && [ -n "$CFG_QUIET_END" ] \
      || die 'quiet_start and quiet_end must be set together'
    [ "$CFG_QUIET_START" != "$CFG_QUIET_END" ] \
      || die 'quiet_start and quiet_end must differ; equal bounds would silence every hour of the day'
  fi
  if [ -n "$CFG_ACTIVE_START" ] || [ -n "$CFG_ACTIVE_END" ]; then
    [ -n "$CFG_ACTIVE_START" ] && [ -n "$CFG_ACTIVE_END" ] \
      || die 'active_start and active_end must be set together'
    [ "$CFG_ACTIVE_START" != "$CFG_ACTIVE_END" ] \
      || die 'active_start and active_end must differ; equal bounds would not describe a window'
  fi
}

enabled() {
  [ "$CFG_ENABLED" = true ]
}

require_enabled() {
  enabled || die "this home is not opted in; add 'enabled = true' to $CONFIG_FILE"
}

# --- clock ------------------------------------------------------------------

now_epoch() {
  local value=${FM_CHANNEL_INTAKE_NOW:-}
  if [ -n "$value" ]; then
    case "$value" in
      ''|*[!0-9]*) die "FM_CHANNEL_INTAKE_NOW must be an epoch second: $value" ;;
    esac
    printf '%s\n' "$value"
    return 0
  fi
  date +%s
}

local_fmt() {
  local epoch=$1 fmt=$2
  if [ -n "$CFG_TIMEZONE" ]; then
    TZ="$CFG_TIMEZONE" date -r "$epoch" "+$fmt" 2>/dev/null \
      || TZ="$CFG_TIMEZONE" date -d "@$epoch" "+$fmt" 2>/dev/null \
      || die 'cannot render local time; date(1) supports neither -r nor -d'
  else
    date -r "$epoch" "+$fmt" 2>/dev/null \
      || date -d "@$epoch" "+$fmt" 2>/dev/null \
      || die 'cannot render local time; date(1) supports neither -r nor -d'
  fi
}

local_date() {
  local_fmt "$1" '%Y-%m-%d'
}

# Quiet hours wrap midnight when the end is at or before the start, which is
# the normal overnight case and not an error.
in_quiet_hours() {
  local epoch=$1 hhmm
  [ -n "$CFG_QUIET_START" ] || return 1
  hhmm=$(local_fmt "$epoch" '%H:%M')
  if [ "$CFG_QUIET_START" \< "$CFG_QUIET_END" ]; then
    ! [ "$hhmm" \< "$CFG_QUIET_START" ] && [ "$hhmm" \< "$CFG_QUIET_END" ]
  else
    ! [ "$hhmm" \< "$CFG_QUIET_START" ] || [ "$hhmm" \< "$CFG_QUIET_END" ]
  fi
}

# The scanning window. Unset means all day, which is the historical behavior.
# It wraps midnight on the same rule as quiet hours, so an overnight window is
# expressible rather than an error. This bounds the READ side only: quiet hours
# still own whether an alert payload goes out.
in_active_window() {
  local epoch=$1 hhmm
  [ -n "$CFG_ACTIVE_START" ] || return 0
  hhmm=$(local_fmt "$epoch" '%H:%M')
  if [ "$CFG_ACTIVE_START" \< "$CFG_ACTIVE_END" ]; then
    ! [ "$hhmm" \< "$CFG_ACTIVE_START" ] && [ "$hhmm" \< "$CFG_ACTIVE_END" ]
  else
    ! [ "$hhmm" \< "$CFG_ACTIVE_START" ] || [ "$hhmm" \< "$CFG_ACTIVE_END" ]
  fi
}

# --- durable record helpers -------------------------------------------------

write_atomic() {
  local dest=$1 value=$2 parent tmp
  parent=${dest%/*}
  mkdir -p "$parent"
  tmp=$(umask 077; mktemp "$parent/.channel-intake.XXXXXX") || return 1
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

# One record reader for every key=value record this gate keeps, so the source,
# item and notify records cannot drift into three parsers.
record_field() {
  local file=$1 key=$2
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  awk -F= -v k="$key" '
    index($0, k "=") == 1 { print substr($0, length(k) + 2) }
  ' "$file" | tail -n 1
}

# The same reader for a whole directory of records, in ONE process for the
# directory rather than one per field per record. Every surface that walks the
# ledger - the watcher check twice per sweep, the brief, the to-do list,
# `items`, `status` - needs several fields from every record, and a fork per
# field is what turns a growing ledger into a check that cannot finish inside
# FM_CHECK_TIMEOUT. Emits `path<SEP>field...` per record, in the same order
# `for_each_item` yields; every stored value is sanitized of the separator on
# write, so the columns cannot run together.
scan_records() {
  local dir=$1 files
  shift
  files=$(for_each_item "$dir")
  [ -n "$files" ] || return 0
  # shellcheck disable=SC2016
  printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 awk -v keylist="$*" '
    function flush(   i, out) {
      if (path == "") return
      out = path
      for (i = 1; i <= nk; i++) { out = out "\037" val[i]; val[i] = "" }
      print out
      path = ""
    }
    BEGIN { nk = split(keylist, keys, " ") }
    FNR == 1 { flush(); path = FILENAME }
    {
      for (i = 1; i <= nk; i++) {
        if (index($0, keys[i] "=") == 1) val[i] = substr($0, length(keys[i]) + 2)
      }
    }
    END { flush() }
  '
}

digest_hex() {
  local input=$1 out
  if command -v shasum >/dev/null 2>&1; then
    out=$(printf '%s' "$input" | shasum -a 256 2>/dev/null) || return 1
  elif command -v sha256sum >/dev/null 2>&1; then
    out=$(printf '%s' "$input" | sha256sum 2>/dev/null) || return 1
  else
    die 'no sha256 tool available (shasum or sha256sum required)'
  fi
  printf '%s\n' "${out%% *}"
}

# Ids reach paths, so they are constrained the same way the check label is.
require_id() {
  local what=$1 value=$2
  case "$value" in
    ''|.*|*[!A-Za-z0-9._-]*)
      die "$what must be a leading-dot-free slug of [A-Za-z0-9._-]: $value" ;;
  esac
}

require_class() {
  local value=$1 known
  for known in $ALL_CLASSES; do
    [ "$value" != "$known" ] || return 0
  done
  die "unknown class: $value (known: $ALL_CLASSES)"
}

is_notify_class() {
  local value=$1 known
  for known in $NOTIFY_CLASSES; do
    [ "$value" != "$known" ] || return 0
  done
  return 1
}

is_quiet_bypass_class() {
  local value=$1 known
  for known in $QUIET_BYPASS_CLASSES; do
    [ "$value" != "$known" ] || return 0
  done
  return 1
}

WAKE_LIB_LOADED=false

load_wake_lib() {
  if [ "$WAKE_LIB_LOADED" != true ]; then
    # shellcheck source=bin/fm-wake-lib.sh disable=SC1091
    . "$SCRIPT_DIR/fm-wake-lib.sh"
    WAKE_LIB_LOADED=true
  fi
}

# The ledger is read-modify-written by the scheduled `tick`, by the watcher's
# `check`, and by a live orchestrator's `observe`/`complete`, all in separate
# processes. They serialize on a mutex private to this gate's own data
# directory: not the per-home session lock and not the watcher lock, so a live
# fleet is never competed with. The watcher's sweep gets the shorter bound so a
# wedged holder can never eat into FM_CHECK_TIMEOUT.
STATE_LOCK_WAIT=${FM_CHANNEL_INTAKE_LOCK_WAIT:-20}
case "$STATE_LOCK_WAIT" in
  ''|*[!0-9]*|0) die "FM_CHANNEL_INTAKE_LOCK_WAIT must be a positive integer: $STATE_LOCK_WAIT" ;;
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
    || die "another channel-intake command still holds $STATE_LOCK"
}

log_event() {
  mkdir -p "$INTAKE_DIR"
  umask 077
  printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(sanitize "$*")" >>"$LOG_FILE"
}

# --- the private source inventory -------------------------------------------

# Tab-separated, hand-maintained, gitignored, and the ONLY place a channel id,
# mailbox or board id lives. Tracked code reads it; tracked code never contains
# it. Columns: id, kind, coverage sentence. A row is one enrolled source, so
# the file is also the explicit coverage statement.
INVENTORY_IDS=
INVENTORY_LOADED=false

load_inventory() {
  local line id kind coverage
  [ "$INVENTORY_LOADED" != true ] || return 0
  INVENTORY_LOADED=true
  INVENTORY_IDS=
  [ -n "$CFG_SOURCES_FILE" ] || return 0
  [ -f "$CFG_SOURCES_FILE" ] && [ ! -L "$CFG_SOURCES_FILE" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *[![:space:]]*) ;; *) continue ;; esac
    id=$(printf '%s' "$line" | cut -f1)
    kind=$(printf '%s' "$line" | cut -f2)
    coverage=$(printf '%s' "$line" | cut -f3-)
    [ -n "$kind" ] && [ -n "$coverage" ] \
      || die "inventory row must be id<TAB>kind<TAB>coverage: $CFG_SOURCES_FILE"
    require_id 'source id' "$id"
    require_id 'source kind' "$kind"
    INVENTORY_IDS="$INVENTORY_IDS$id
"
  done <"$CFG_SOURCES_FILE"
}

inventory_field() {
  local id=$1 column=$2
  awk -F'\t' -v want="$id" -v col="$column" '
    /^#/ { next }
    $1 == want { print $col; exit }
  ' "$CFG_SOURCES_FILE" 2>/dev/null
}

source_known() {
  local id=$1 known
  load_inventory
  for known in $INVENTORY_IDS; do
    [ "$known" != "$id" ] || return 0
  done
  return 1
}

source_record() {
  printf '%s/%s/state\n' "$SOURCE_DIR" "$1"
}

# `unknown` is the honest reading for a source that has never completed a read
# or whose last read failed. It is never rendered as "nothing new".
source_status() {
  local id=$1 epoch=$2 rec last_ok failures
  rec=$(source_record "$id")
  last_ok=$(record_field "$rec" last_ok)
  failures=$(record_field "$rec" failures)
  case "$failures" in ''|*[!0-9]*) failures=0 ;; esac
  if [ "$failures" -gt 0 ]; then
    printf 'unknown\n'
    return 0
  fi
  case "$last_ok" in
    ''|*[!0-9]*) printf 'unknown\n'; return 0 ;;
  esac
  if [ $((epoch - last_ok)) -gt "$CFG_STALE_AFTER" ]; then
    printf 'stale\n'
  else
    printf 'fresh\n'
  fi
}

source_due() {
  local id=$1 epoch=$2 rec last_attempt backoff_until last_ok
  # Outside the scanning window nothing is due at all, so the tick enqueues no
  # wake and a claim hands back an empty set. The first tick after the window
  # opens reads immediately, because the interval test below measures the age
  # of the last attempt rather than aligning to the window boundary.
  in_active_window "$epoch" || return 1
  rec=$(source_record "$id")
  backoff_until=$(record_field "$rec" backoff_until)
  case "$backoff_until" in ''|*[!0-9]*) backoff_until=0 ;; esac
  [ "$epoch" -ge "$backoff_until" ] || return 1
  last_ok=$(record_field "$rec" last_ok)
  last_attempt=$(record_field "$rec" last_attempt)
  case "$last_ok" in ''|*[!0-9]*) last_ok=0 ;; esac
  case "$last_attempt" in ''|*[!0-9]*) last_attempt=0 ;; esac
  [ "$last_attempt" -ge "$last_ok" ] || last_attempt=$last_ok
  [ $((epoch - last_attempt)) -ge "$CFG_INTERVAL" ]
}

save_source() {
  local id=$1 checkpoint=$2 last_ok=$3 last_attempt=$4 failures=$5 backoff_until=$6 error=$7
  local last_relist=${8-$(record_field "$(source_record "$1")" last_relist)} body
  body=$(printf 'id=%s\ncheckpoint=%s\nlast_ok=%s\nlast_attempt=%s\nfailures=%s\nbackoff_until=%s\nerror=%s\nlast_relist=%s' \
    "$id" "$(sanitize "$checkpoint")" "$last_ok" "$last_attempt" "$failures" \
    "$backoff_until" "$(sanitize "$error")" "$last_relist")
  mkdir -p "$SOURCE_DIR/$id"
  write_atomic "$(source_record "$id")" "$body" || die "cannot write the source record for $id"
}

# --- items ------------------------------------------------------------------

item_path() {
  printf '%s/%s\n' "$ITEM_DIR" "$1"
}

archive_path() {
  printf '%s/%s\n' "$ARCHIVE_DIR" "$1"
}

item_key() {
  local dedup=$1 source=$2 ref=$3
  if [ -n "$dedup" ]; then
    digest_hex "dedup:$dedup"
  else
    digest_hex "src:$source:$ref"
  fi
}

save_item() {
  local path=$1
  shift
  write_atomic "$path" "$*" || die "cannot write the item record: $path"
}

# THE HOT SET IS BOUNDED, THE HISTORY IS NOT DISCARDED. Routine traffic is
# rendered in exactly one place - the brief's "what changed", bounded by
# BRIEF_WINDOW - and is never owed, never notifiable and never a to-do. Past
# that same existing horizon it is dead weight on every poll, so it MOVES to
# `inactive/` with its record byte-for-byte intact. Nothing is deleted, nothing
# is resolved, nothing is auto-closed: `items` still lists it, `status` still
# counts it, and re-observing the same key restores it to the active set rather
# than opening a second item. Anything owed, waiting, corrected or already
# notified stays where it is, forever, whatever its age - except a corrected
# update, which leaves once its last change is past its own horizon.
RETIRE_MAX_PER_PASS=200

restore_inactive_item() {
  local key=$1 path=$2
  [ ! -f "$path" ] || return 0
  [ -f "$INACTIVE_DIR/$key" ] || return 0
  mkdir -p "$ITEM_DIR"
  mv -f "$INACTIVE_DIR/$key" "$path" \
    || die "cannot restore the inactive item record: $key"
}

retire_inactive_items() {
  local epoch=$1 rows path class state revisions created updated notified retired=0 horizon
  rows=$(scan_records "$ITEM_DIR" class state revisions created updated notified)
  [ -n "$rows" ] || return 0
  while IFS="$FIELD_SEP" read -r path class state revisions created updated notified; do
    [ -n "$path" ] || continue
    # Bounded per pass so a first sweep over a long-running ledger cannot
    # itself become the unbounded step; the remainder drains on later ticks.
    [ "$retired" -lt "$RETIRE_MAX_PER_PASS" ] || break
    [ "$state" = open ] || continue
    case "$class" in
      routine)
        horizon=$BRIEF_WINDOW
        case "$revisions" in ''|0) ;; *) continue ;; esac
        ;;
      update) horizon=$UPDATE_WINDOW ;;
      *) continue ;;
    esac
    [ -z "$notified" ] || continue
    case "$created" in ''|*[!0-9]*) continue ;; esac
    case "$updated" in ''|*[!0-9]*) updated=$created ;; esac
    [ $((epoch - created)) -gt "$horizon" ] || continue
    [ $((epoch - updated)) -gt "$horizon" ] || continue
    mkdir -p "$INACTIVE_DIR" || continue
    mv -f "$path" "$INACTIVE_DIR/${path##*/}" || continue
    retired=$((retired + 1))
  done <<EOF
$rows
EOF
  [ "$retired" -eq 0 ] \
    || log_event "moved $retired routine or update item(s) past their horizon to the inactive set"
}

# The tracked thread set is bounded by the SAME revision window that bounds
# edit re-detection, so `claim` hands back a bounded list and the connector
# work an orchestrator does per tick cannot grow with all thread history.
# A retired marker retires only a re-read hint: every captured item, its
# evidence and its watermark are untouched, and a reply that arrives later on a
# retired parent still lands on the same item key - which for a closed
# obligation means the archived record, never a reopening.
retire_tracked_threads() {
  local epoch=$1 dir parent marker updated legacy retired=0
  [ -d "$THREAD_DIR" ] || return 0
  for dir in "$THREAD_DIR"/*; do
    [ -d "$dir" ] || continue
    while IFS="$FIELD_SEP" read -r parent marker updated; do
      [ -n "$parent" ] || continue
      case "$updated" in
        ''|*[!0-9]*)
          # A marker written before the set was bounded has no recorded age.
          # Adopt it at this sweep rather than retiring a parent whose activity
          # is merely unknown; a genuinely dormant one ages out normally.
          legacy=$marker
          [ -n "$legacy" ] || legacy=$(read_line_file "$parent")
          case "$legacy" in marker=*) legacy=${legacy#marker=} ;; esac
          write_atomic "$parent" \
            "$(printf 'marker=%s\nupdated=%s' "$(sanitize "$legacy")" "$epoch")" || true
          continue
          ;;
      esac
      [ $((epoch - updated)) -gt "$CFG_REVISION_WINDOW" ] || continue
      rm -f "$parent" || continue
      retired=$((retired + 1))
    done <<EOF
$(scan_records "$dir" marker updated)
EOF
  done
  [ "$retired" -eq 0 ] \
    || log_event "retired $retired tracked thread parent(s) with no reply past the revision window"
}

# An edit that lands after an item was resolved annotates the archive record and
# never reopens it: reopening a cleared obligation is a captain decision, not a
# poll's. The annotation is carried outside `item_body` so the archived
# evidence - source, ref, link, provenance, resolution - stays verbatim, and it
# is rewritten rather than appended so each key keeps exactly one line and a
# later edit supersedes an earlier one. An unchanged re-read of the same edit
# is not news: it rewrites nothing AND returns non-zero, so the caller stays
# silent on stdout and in the log instead of re-announcing the same edit on
# every poll for as long as the archived record lives.
annotate_archived_edit() {
  local path=$1 digest=$2 epoch=$3 seen body
  seen=$(record_field "$path" edited_digest)
  if [ "$seen" = "$digest" ]; then
    return 1
  fi
  body=$(grep -v '^edited_after_resolution=' "$path" | grep -v '^edited_digest=') \
    || die "cannot read the archived item record: $path"
  write_atomic "$path" "$(printf '%s\nedited_after_resolution=%s\nedited_digest=%s' \
    "$body" "$epoch" "$digest")" \
    || die "cannot annotate the archived item record: $path"
}

item_body() {
  printf 'key=%s\nsource=%s\nkind=%s\nref=%s\nlink=%s\nclass=%s\ntitle=%s\ndigest=%s\nstate=%s\ncreated=%s\nupdated=%s\nsource_epoch=%s\nnotified=%s\nnotified_digest=%s\nrevisions=%s\nprovenance=%s\nresolution=%s\nresolved_at=%s' \
    "$1" "$2" "$3" "$4" "$(sanitize "$5")" "$6" "$(sanitize "$7")" "$8" "$9" \
    "${10}" "${11}" "${12}" "${13}" "${14}" "${15}" "$(sanitize "${16}")" \
    "$(sanitize "${17}")" "${18}"
  [ -z "${19:-}" ] || printf '\n%s' "${19}"
}

# The partner marks an observe recorded, carried verbatim by every later
# rewrite of the record so a resolve or a notification stamp cannot silently
# demote a partner- or customer-facing ask.
attention_fields() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 0
  grep -E '^(partner_hint|awaiting_since)=' "$1" || true
}

# --- wake delivery ----------------------------------------------------------

enqueue_wake() {
  local payload=$1
  load_wake_lib
  fm_wake_append check "$CFG_LABEL" "$payload"
}

# --- live-session delivery: the registered watcher check ---------------------

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

render_check_shim() {
  cat <<SHIM
#!/usr/bin/env bash
# Generated by bin/fm-channel-intake.sh arm-check. Do not edit; re-arm instead.
set -eu
FM_HOME='$FM_HOME' FM_ROOT_OVERRIDE='$ROOT' exec '$SCRIPT_DIR/fm-channel-intake.sh' check
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
  tmp=$(mktemp "$STATE_DIR/.channel-intake-check.XXXXXX") || die 'cannot stage the check shim'
  render_check_shim >"$tmp" || { rm -f "$tmp"; die 'cannot write the check shim'; }
  chmod 0700 "$tmp" || { rm -f "$tmp"; die 'cannot set check shim mode'; }
  mv -f "$tmp" "$check" || { rm -f "$tmp"; die "cannot install the check shim: $check"; }
  # Arming is all-or-nothing for the same reason the morning gate's is: an
  # unregistered shim left in state/ is worse than no shim, because the watcher
  # rejects it and wakes the primary about it on every sweep.
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

# --- tick -------------------------------------------------------------------

due_source_ids() {
  local epoch=$1 id
  load_inventory
  for id in $INVENTORY_IDS; do
    if source_due "$id" "$epoch"; then
      printf '%s\n' "$id"
    fi
  done
  return 0
}

# The most recent read attempt across every enrolled source. It only ever moves
# forward, because `claim`, `complete` and `fail` all stamp the current epoch,
# so it is the monotonic term a suppression signature needs to tell a genuinely
# recurring condition apart from one already surfaced.
last_attempt_watermark() {
  local id watermark=0 value
  load_inventory
  for id in $INVENTORY_IDS; do
    value=$(record_field "$(source_record "$id")" last_attempt)
    case "$value" in ''|*[!0-9]*) continue ;; esac
    [ "$value" -le "$watermark" ] || watermark=$value
  done
  printf '%s\n' "$watermark"
}

# The scheduled entry point. It decides only WHETHER a read is worth doing and
# records that decision; it reads nothing itself. One wake per armed cycle: the
# armed marker is cleared by `complete`/`fail` on the last due source, so a
# repeat tick over an already-armed cycle stays silent.
tick() {
  local epoch due count armed payload
  [ "$#" -eq 0 ] || die 'tick takes no arguments'
  enabled || return 0
  epoch=$(now_epoch)
  require_state_lock
  # The scheduled entry point owns the housekeeping that keeps every later poll
  # bounded, and it runs whether or not anything is due: both passes are cheap,
  # capped, and move records rather than deleting them.
  retire_inactive_items "$epoch"
  retire_tracked_threads "$epoch"
  due=$(due_source_ids "$epoch")
  count=$(printf '%s' "$due" | grep -c '[^[:space:]]' || true)
  if [ "$count" -eq 0 ]; then
    return 0
  fi
  armed=$(read_line_file "$ARMED_FILE")
  case "$armed" in
    ''|*[!0-9]*) armed=0 ;;
  esac
  # One wake per armed cycle. `claim`, `complete` and `fail` all clear the
  # marker, so a worked cycle re-arms normally. An armed cycle nobody ever took
  # re-arms once its wake is older than the staleness bound, which keeps a lost
  # wake recoverable without turning the marker into a per-tick reminder.
  if [ "$armed" -gt 0 ] && [ $((epoch - armed)) -lt "$CFG_STALE_AFTER" ]; then
    return 0
  fi
  write_atomic "$ARMED_FILE" "$epoch" || die 'cannot record the armed cycle'
  payload="$CFG_LABEL has $count source(s) due; take them with '$0 claim'"
  log_event "armed: $count source(s) due"
  enqueue_wake "$payload" || die 'could not append the wake record'
  printf 'CHANNEL_INTAKE: %s source(s) due for %s\n' "$count" "$CFG_LABEL"
}

# --- claim / complete / fail ------------------------------------------------

claim() {
  local want='' epoch id due any=false parent marker rec
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source) [ "$#" -ge 2 ] || die '--source requires a value'; want=$2; shift 2 ;;
      *) die "unknown claim argument: $1" ;;
    esac
  done
  require_enabled
  epoch=$(now_epoch)
  require_state_lock
  # The set this hands back is bounded before it is printed, so the list is
  # what the orchestrator should actually re-read rather than every parent ever
  # seen.
  retire_tracked_threads "$epoch"
  load_inventory
  if [ -n "$want" ]; then
    require_id 'source id' "$want"
    source_known "$want" || die "source is not in the inventory: $want"
    due=$want
  else
    due=$(due_source_ids "$epoch")
  fi
  printf 'now: %s\n' "$epoch"
  printf 'revision_window_seconds: %s\n' "$CFG_REVISION_WINDOW"
  printf 'revision_window_from: %s\n' "$((epoch - CFG_REVISION_WINDOW))"
  # The tracked set is bounded by the same window, so an orchestrator can state
  # its coverage honestly instead of implying every thread is still watched.
  printf 'thread_tracking_window_seconds: %s\n' "$CFG_REVISION_WINDOW"
  for id in $due; do
    any=true
    printf 'source: %s\tkind: %s\tcheckpoint: %s\tcoverage: %s\n' \
      "$id" "$(inventory_field "$id" 2)" \
      "$(record_field "$(source_record "$id")" checkpoint)" \
      "$(inventory_field "$id" 3)"
    kind_claim_lines "$id" "$(inventory_field "$id" 2)" "$epoch"
    # Tracked thread parents, so the orchestrator can re-read only the threads
    # whose reply marker advanced instead of re-reading every thread.
    if [ -d "$THREAD_DIR/$id" ]; then
      while IFS="$FIELD_SEP" read -r parent marker; do
        [ -n "$parent" ] || continue
        printf 'thread: %s\t%s\t%s\n' "$id" "${parent##*/}" "$marker"
      done <<EOF
$(scan_records "$THREAD_DIR/$id" marker)
EOF
    fi
    # An attempt is recorded before the read, so a read that never reports back
    # still spends its slot and cannot be retried in a tight loop.
    rec=$(source_record "$id")
    save_source "$id" "$(record_field "$rec" checkpoint)" \
      "$(record_field "$rec" last_ok)" "$epoch" \
      "$(record_field "$rec" failures)" "$(record_field "$rec" backoff_until)" \
      "$(record_field "$rec" error)"
  done
  clear_armed
  if [ "$any" = true ]; then
    recheck_claim_lines "$epoch"
  else
    printf 'source: <none due>\n'
  fi
}

# Every pass re-reads what is already open, not only what is new: without it
# an item closes only when the captain says so. The listed ids and the claim
# time are kept so `complete` can say how many were not re-read. Fail-soft and
# bounded like the page refresh: no store, or a store that cannot list, prints
# nothing and never costs the claim.
recheck_claim_lines() {
  local epoch=$1 out ids
  rm -f "$RECHECK_FILE"
  [ -d "$TODO_STORE/items" ] && [ -x "$SCRIPT_DIR/fm-todo.sh" ] || return 0
  out=$(FM_HOME="$FM_HOME" FM_TODO_NOW="$epoch" "$SCRIPT_DIR/fm-todo.sh" recheck 2>/dev/null) || {
    log_event 'recheck list not available: fm-todo.sh recheck failed'
    return 0
  }
  ids=$(printf '%s\n' "$out" | sed -n 's/^recheck: \([^[:space:]]*\).*/\1/p' | tr '\n' ' ')
  write_atomic "$RECHECK_FILE" "$(printf 'claimed=%s\nitems=%s' "$epoch" "${ids% }")" \
    || log_event 'recheck list not recorded'
  [ -z "$out" ] || printf '%s\n' "$out"
}

recheck_report() {
  local since ids out
  since=$(record_field "$RECHECK_FILE" claimed)
  ids=$(record_field "$RECHECK_FILE" items)
  case "$since" in ''|*[!0-9]*) return 0 ;; esac
  [ -n "$ids" ] && [ -x "$SCRIPT_DIR/fm-todo.sh" ] || return 0
  # shellcheck disable=SC2086
  out=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-todo.sh" recheck --since "$since" $ids 2>/dev/null) || return 0
  log_event "recheck: $out"
  printf 'CHANNEL_INTAKE: %s\n' "${out#TODO_RECHECK: }"
}

# The extra read a source kind owes on a claim, beyond its checkpoint read.
kind_claim_lines() {
  local id=$1 kind=$2 epoch=$3
  case "$kind" in
    slack-dms)
      printf 'dms: %s\tread each DM and group DM the coverage sentence names directly by its conversation id with the channel-read tool, never through search; observe every message to the captain since the checkpoint, whether or not it carries an @mention\n' "$id"
      ;;
    calendar)
      printf 'calendar: %s\tfrom: %s\tto: %s\tscope: invites the captain has not answered (responseStatus needsAction), and events in this window whose description asks the captain to prepare or complete something before it; observe each with the time the invite was sent or last updated as --source-epoch, never the event time\n' \
        "$id" "$(local_date "$epoch")" "$(working_days_ahead "$epoch" 2)"
      ;;
    asana*) asana_claim_lines "$id" "$epoch" ;;
  esac
}

# The local date N working days (Monday to Friday) after the epoch's day.
working_days_ahead() {
  local epoch=$1 n=$2 t day
  t=$epoch
  while [ "$n" -gt 0 ]; do
    t=$((t + 86400))
    day=$(local_fmt "$t" '%u')
    [ "$day" -ge 6 ] || n=$((n - 1))
  done
  local_date "$t"
}

# A checkpoint read of Asana returns only tasks modified since it, so a task
# assigned to the captain and left stale never comes back. Once per local day
# the claim hands out a full re-list of every incomplete task assigned to them.
asana_claim_lines() {
  local id=$1 epoch=$2 last
  last=$(record_field "$(source_record "$id")" last_relist)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ "$last" -eq 0 ] || [ "$(local_date "$last")" != "$(local_date "$epoch")" ] || return 0
  printf 'relist: %s\tlast_relist: %s\tscope: every incomplete task assigned to the captain, whatever its modified date or due date; observe each, then complete with --relisted\n' \
    "$id" "$([ "$last" -gt 0 ] && printf '%s' "$last" || printf never)"
}

complete_source() {
  local id='' checkpoint='' epoch relisted=false last_relist kind
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source) [ "$#" -ge 2 ] || die '--source requires a value'; id=$2; shift 2 ;;
      --checkpoint) [ "$#" -ge 2 ] || die '--checkpoint requires a value'; checkpoint=$2; shift 2 ;;
      --relisted) relisted=true; shift ;;
      *) die "unknown complete argument: $1" ;;
    esac
  done
  require_enabled
  [ -n "$id" ] || die '--source is required'
  require_id 'source id' "$id"
  [ -n "$checkpoint" ] || die '--checkpoint is required'
  source_known "$id" || die "source is not in the inventory: $id"
  epoch=$(now_epoch)
  require_state_lock
  # The checkpoint advances ONLY here, and only on a read the orchestrator has
  # already captured. An interrupted read leaves the old checkpoint, so the
  # next tick re-reads that window instead of skipping it.
  kind=$(inventory_field "$id" 2)
  last_relist=$(record_field "$(source_record "$id")" last_relist)
  if [ "$relisted" = true ]; then
    case "$kind" in asana*) ;; *) die '--relisted requires an asana source' ;; esac
    last_relist=$epoch
  fi
  save_source "$id" "$checkpoint" "$epoch" "$epoch" 0 0 '' "$last_relist"
  clear_armed
  log_event "source $id complete at checkpoint $checkpoint"
  printf 'CHANNEL_INTAKE: %s read complete, checkpoint %s\n' "$id" "$checkpoint"
  refresh_todo_page "$epoch"
  recheck_report
}

# The day's page re-ranks itself on every completed read. This is the whole
# reason the ordering is not a once-a-morning decision: an outage observed at
# 15:00 reaches the top of the page on the read that recorded it, with no
# model call and nothing re-verified, because bin/fm-todo-render.sh rebuilds
# the page from this same ledger.
#
# It is deliberately BOUNDED AND FAIL-SOFT. `--if-exists` means a home that
# never wrote today's page has one manufactured for it by a background read,
# and a renderer that is missing or that fails is logged rather than turned
# into a failed read: the checkpoint this command just advanced is the durable
# thing, and losing a page refresh must never cost a completed read.
refresh_todo_page() {
  local epoch=$1 renderer="$SCRIPT_DIR/fm-todo-render.sh" out code
  if [ ! -x "$renderer" ]; then
    log_event 'todo page not refreshed: no renderer at fm-todo-render.sh'
    return 0
  fi
  # This gate's own clock, not a second reading of the wall clock: the page is
  # rendered as of the read that produced it, which is also what keeps a
  # pinned-clock test deterministic across the two commands.
  out=$(FM_TODO_RENDER_NOW="$epoch" "$renderer" render --if-exists 2>&1) && code=0 || code=$?
  if [ "$code" -ne 0 ]; then
    log_event "todo page refresh failed: $out"
    printf 'CHANNEL_INTAKE: the day page was not refreshed - %s\n' "$out"
    return 0
  fi
  log_event "todo page refresh: $out"
  printf '%s\n' "$out"
}

fail_source() {
  local id='' reason='' epoch rec failures backoff
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source) [ "$#" -ge 2 ] || die '--source requires a value'; id=$2; shift 2 ;;
      --reason) [ "$#" -ge 2 ] || die '--reason requires a value'; reason=$2; shift 2 ;;
      *) die "unknown fail argument: $1" ;;
    esac
  done
  require_enabled
  [ -n "$id" ] || die '--source is required'
  require_id 'source id' "$id"
  [ -n "$reason" ] || die '--reason is required'
  source_known "$id" || die "source is not in the inventory: $id"
  epoch=$(now_epoch)
  require_state_lock
  rec=$(source_record "$id")
  failures=$(record_field "$rec" failures)
  case "$failures" in ''|*[!0-9]*) failures=0 ;; esac
  failures=$((failures + 1))
  # Geometric backoff to a bounded ceiling. A throttle is a reason to read less
  # often, never to retry harder, and the ceiling means a permanently broken
  # source settles into a cheap heartbeat instead of a loop.
  backoff=$CFG_BACKOFF
  local n=1
  while [ "$n" -lt "$failures" ] && [ "$backoff" -lt "$CFG_BACKOFF_MAX" ]; do
    backoff=$((backoff * 2))
    n=$((n + 1))
  done
  [ "$backoff" -le "$CFG_BACKOFF_MAX" ] || backoff=$CFG_BACKOFF_MAX
  # last_ok is deliberately NOT advanced: the checkpoint and the freshness
  # reading both stay where the last captured read left them.
  save_source "$id" "$(record_field "$rec" checkpoint)" \
    "$(record_field "$rec" last_ok)" "$epoch" "$failures" "$((epoch + backoff))" "$reason"
  clear_armed
  log_event "source $id failed ($failures): $reason"
  printf 'CHANNEL_INTAKE: %s read failed (%s consecutive), backing off %ss - %s\n' \
    "$id" "$failures" "$backoff" "$reason"
}

# A reported read settles the cycle, whether it succeeded or failed. Leaving
# the marker in place would suppress the next genuine wake.
clear_armed() {
  rm -f "$ARMED_FILE"
}

# --- observe ----------------------------------------------------------------

# The one entry point for "the orchestrator saw this". Idempotent by content:
# the same content reported twice is `unchanged` and produces no second item and
# no second notification, which is what makes an unchanged poll silent.
observe() {
  local id='' ref='' digest_in='' digest_file='' class=routine title='' link=''
  local dedup='' thread='' marker='' source_epoch='' epoch key path digest thread_marker
  local existing_digest existing_state created revisions provenance notified
  local notified_digest kind outcome prov_tag attention=''
  local partner_hint=false awaiting_since=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source) [ "$#" -ge 2 ] || die '--source requires a value'; id=$2; shift 2 ;;
      --ref) [ "$#" -ge 2 ] || die '--ref requires a value'; ref=$2; shift 2 ;;
      --digest) [ "$#" -ge 2 ] || die '--digest requires a value'; digest_in=$2; shift 2 ;;
      --digest-file) [ "$#" -ge 2 ] || die '--digest-file requires a value'; digest_file=$2; shift 2 ;;
      --class) [ "$#" -ge 2 ] || die '--class requires a value'; class=$2; shift 2 ;;
      --title) [ "$#" -ge 2 ] || die '--title requires a value'; title=$2; shift 2 ;;
      --link) [ "$#" -ge 2 ] || die '--link requires a value'; link=$2; shift 2 ;;
      --dedup-key) [ "$#" -ge 2 ] || die '--dedup-key requires a value'; dedup=$2; shift 2 ;;
      --thread) [ "$#" -ge 2 ] || die '--thread requires a value'; thread=$2; shift 2 ;;
      --reply-marker) [ "$#" -ge 2 ] || die '--reply-marker requires a value'; marker=$2; shift 2 ;;
      --source-epoch) [ "$#" -ge 2 ] || die '--source-epoch requires a value'; source_epoch=$2; shift 2 ;;
      --partner) partner_hint=true; shift ;;
      --partner-awaiting-since)
        [ "$#" -ge 2 ] || die '--partner-awaiting-since requires a value'
        # The same bound the morning sidecar's awaiting_since takes, so
        # milliseconds or a date never rank as a partner awaiting the captain.
        case "$2" in
          ''|0*|*[!0-9]*|????????????*) die "--partner-awaiting-since must be an epoch second: $2" ;;
        esac
        awaiting_since=$2; partner_hint=true; shift 2 ;;
      *) die "unknown observe argument: $1" ;;
    esac
  done
  require_enabled
  [ -n "$id" ] || die '--source is required'
  require_id 'source id' "$id"
  [ -n "$ref" ] || die '--ref is required'
  # A ref is hashed into the item key and never becomes a path, so it only has
  # to be a single-line token; a Gmail message id is not a filename slug.
  case "$ref" in
    *[[:space:]]*) die "--ref must be a single whitespace-free token: $ref" ;;
  esac
  source_known "$id" || die "source is not in the inventory: $id"
  require_class "$class"
  [ "$class" != update ] || [ "$(inventory_field "$id" 2)" = slack-announcements ] \
    || die '--class update requires a slack-announcements source'
  if [ -n "$digest_file" ]; then
    [ -z "$digest_in" ] || die 'pass --digest or --digest-file, not both'
    [ -f "$digest_file" ] && [ ! -L "$digest_file" ] \
      || die "--digest-file is not a regular file: $digest_file"
    # Content never lands in the ledger, only its hash: customer text and
    # private message bodies stay in the source system.
    digest_in=$(digest_hex "$(cat "$digest_file")")
  fi
  [ -n "$digest_in" ] || die '--digest or --digest-file is required'
  case "$source_epoch" in
    '') ;;
    *[!0-9]*) die "--source-epoch must be an epoch second: $source_epoch" ;;
  esac
  epoch=$(now_epoch)
  require_state_lock
  digest=$(digest_hex "$digest_in")
  key=$(item_key "$dedup" "$id" "$ref")
  kind=$(inventory_field "$id" 2)
  prov_tag="$id:$ref"
  # A line with no title renders as an untitled row nobody can act on. Refused
  # before any write, so a refused reply leaves no thread marker behind.
  if [ -z "$(printf '%s' "$title" | tr -d '[:space:]')" ] && [ ! -f "$(archive_path "$key")" ] \
    && [ ! -f "$(item_path "$key")" ] && [ ! -f "$INACTIVE_DIR/$key" ]; then
    die '--title is required for a new item'
  fi

  if [ -n "$thread" ]; then
    require_id 'thread parent' "$thread"
    mkdir -p "$THREAD_DIR/$id"
    # `updated` records when the marker last ADVANCED, which is what bounds the
    # tracked set. An unchanged re-read of the same reply rewrites nothing, so
    # a dormant parent cannot keep itself in the set by being re-polled.
    thread_marker=$(sanitize "${marker:-$ref}")
    if [ "$(record_field "$THREAD_DIR/$id/$thread" marker)" != "$thread_marker" ]; then
      write_atomic "$THREAD_DIR/$id/$thread" \
        "$(printf 'marker=%s\nupdated=%s' "$thread_marker" "$epoch")" \
        || die 'cannot record the thread reply marker'
    fi
  fi

  # A resolved ask is never reopened from here. A reaction or an unchanged
  # re-read is silent, and even a genuine later edit only annotates the archive
  # so the brief can mention it; reopening is a captain decision, not a poll's.
  # An edit is news exactly once. The archived record keeps its pre-resolution
  # digest verbatim as evidence, so "has this edit already been reported" is
  # answered by the annotation rather than by that digest - otherwise every
  # later poll of the same edited message would re-announce it forever.
  if [ -f "$(archive_path "$key")" ]; then
    path=$(archive_path "$key")
    existing_digest=$(record_field "$path" digest)
    if [ "$existing_digest" = "$digest" ]; then
      printf 'archived-unchanged %s\n' "$key"
    elif annotate_archived_edit "$path" "$digest" "$epoch"; then
      printf 'archived-changed %s\n' "$key"
      log_event "archived item $key changed after resolution"
    else
      printf 'archived-unchanged %s\n' "$key"
    fi
    return 0
  fi

  path=$(item_path "$key")
  restore_inactive_item "$key" "$path"
  if [ -f "$path" ]; then
    existing_digest=$(record_field "$path" digest)
    existing_state=$(record_field "$path" state)
    created=$(record_field "$path" created)
    revisions=$(record_field "$path" revisions)
    provenance=$(record_field "$path" provenance)
    notified=$(record_field "$path" notified)
    notified_digest=$(record_field "$path" notified_digest)
    case "$revisions" in ''|*[!0-9]*) revisions=0 ;; esac
    # Whole-token membership: provenance is space-separated `id:ref`, and an
    # unanchored match would drop a new tag whose ref is a prefix of a
    # recorded one on the same source.
    case " $provenance " in
      *" $prov_tag "*) ;;
      # A cross-source duplicate keeps every source's provenance and stays ONE
      # item: it never becomes a second task.
      *) provenance="$provenance $prov_tag"; outcome=merged ;;
    esac
    attention=$(with_partner_hint "$(attention_fields "$path")" "$partner_hint" "$path" "$awaiting_since")
    if [ "$existing_digest" = "$digest" ]; then
      # Unchanged content. Provenance may still have grown, so the record is
      # rewritten, but nothing about the item's attention state moves - except
      # that a --partner mark is kept.
      save_item "$path" "$(item_body "$key" "$id" "$kind" "$ref" \
        "$(record_field "$path" link)" "$(record_field "$path" class)" \
        "$(record_field "$path" title)" "$digest" "$existing_state" "$created" \
        "$(record_field "$path" updated)" "$(record_field "$path" source_epoch)" \
        "$notified" "$notified_digest" "$revisions" "$provenance" \
        "$(record_field "$path" resolution)" "$(record_field "$path" resolved_at)" "$attention")"
      printf '%s %s\n' "${outcome:-unchanged}" "$key"
      return 0
    fi
    # A correction updates the SAME item rather than creating a second one.
    revisions=$((revisions + 1))
    save_item "$path" "$(item_body "$key" "$id" "$kind" "$ref" \
      "${link:-$(record_field "$path" link)}" "$class" \
      "${title:-$(record_field "$path" title)}" "$digest" "$existing_state" \
      "$created" "$epoch" "${source_epoch:-$(record_field "$path" source_epoch)}" \
      "$notified" "$notified_digest" "$revisions" "$provenance" \
      "$(record_field "$path" resolution)" "$(record_field "$path" resolved_at)" "$attention")"
    log_event "item $key updated (revision $revisions)"
    printf 'updated %s\n' "$key"
    return 0
  fi

  attention=$(with_partner_hint "$attention" "$partner_hint" '' "$awaiting_since")
  save_item "$path" "$(item_body "$key" "$id" "$kind" "$ref" "$link" "$class" \
    "$title" "$digest" open "$epoch" "$epoch" "$source_epoch" '' '' 0 "$prov_tag" '' '' "$attention")"
  if [ -n "$source_epoch" ] && [ "$epoch" -ge "$source_epoch" ]; then
    # Measured detection latency, sampled from real runs rather than projected
    # from the poll interval, which is a target and not an upper bound.
    mkdir -p "$INTAKE_DIR"
    umask 077
    printf '%s\t%s\t%s\n' "$epoch" "$id" "$((epoch - source_epoch))" >>"$LATENCY_LOG"
  fi
  log_event "item $key opened from $prov_tag as $class"
  printf 'new %s\n' "$key"
}

# The partner marks kept: once an earlier observe marked an item
# partner-facing or awaiting the captain, a later read does not unmark it; one
# that passes a new awaiting time moves it.
with_partner_hint() {
  local attention=$1 hint=$2 path=$3 since=$4
  attention=$(printf '%s\n' "$attention" | grep -v -e '^partner_hint=' -e '^awaiting_since=' || true)
  if [ "$hint" = true ] || { [ -n "$path" ] && [ "$(record_field "$path" partner_hint)" = 1 ]; }; then
    attention=$(printf '%s\npartner_hint=1' "$attention")
  fi
  [ -n "$since" ] || [ -z "$path" ] || since=$(record_field "$path" awaiting_since)
  [ -z "$since" ] || attention=$(printf '%s\nawaiting_since=%s' "$attention" "$since")
  printf '%s' "$attention" | sed '/^$/d'
}

# --- resolution -------------------------------------------------------------

# Whether a reason hands the wait to a named owner who is neither the captain
# nor a pronoun or indefinite word.
hands_over_to_other() {
  local name not_owner
  not_owner=" i me my mine myself we us our ours ourselves you your yours yourself yourselves he him his himself she her hers herself they them their theirs themselves it its itself one this that these those there here someone somebody something anyone anybody anything everyone everybody everything noone nobody nothing some any every no all both each either neither none other others another such few many much most several who whom whose which what whoever whichever whatever where when captain $(printf '%s' "$CFG_CAPTAIN_NAMES" | tr '[:upper:]' '[:lower:]') "
  for name in $(printf ' %s ' "$1" | grep -oE \
    '([Ww]aiting (on|for)|[Rr]outed to|[Hh]anded( it)?( over)? to|[Aa]ssigned to) [A-Z][a-z]+|[A-Z][a-z]+ will [a-z]+' \
    | sed -E 's/ will [a-z]+$//; s/.* //'); do
    case "$not_owner" in
      *" $(printf '%s' "$name" | tr '[:upper:]' '[:lower:]') "*) ;;
      *) return 0 ;;
    esac
  done
  return 1
}

# Month and weekday names count only as whole words, a month only next to a day
# number; "sat", "sun" and "wed" are ordinary words, so those days need their
# full names.
names_a_date() {
  local month='(jan(uary)?|feb(ruary)?|mar(ch)?|apr(il)?|may|june?|july?|aug(ust)?|sep(t(ember)?)?|oct(ober)?|nov(ember)?|dec(ember)?)'
  local weekday='(monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tues?|thu(rs?)?|fri)'
  printf ' %s ' "$1" | tr '[:upper:]' '[:lower:]' | grep -Eq \
    "[0-9]{4}-[0-9]{2}-[0-9]{2}|[^a-z]${weekday}[^a-z]|[^a-z]tomorrow[^a-z]|[^a-z]next week[^a-z]|[^0-9][0-9]{1,2}(st|nd|rd|th)? ?${month}[^a-z]|[^a-z]${month}\.? [0-9]{1,2}[^0-9]"
}

# An obligation is discharged by content, not by the fact that somebody replied.
# `--waiting` is the honest middle state for "handed to someone else": it leaves
# the item on the ledger under waiting-on-others rather than clearing it.
resolve_item() {
  local key='' reason='' waiting=false epoch path dest
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --item) [ "$#" -ge 2 ] || die '--item requires a value'; key=$2; shift 2 ;;
      --reason) [ "$#" -ge 2 ] || die '--reason requires a value'; reason=$2; shift 2 ;;
      --waiting) waiting=true; shift ;;
      *) die "unknown resolve argument: $1" ;;
    esac
  done
  require_enabled
  [ -n "$key" ] || die '--item is required'
  require_id 'item key' "$key"
  [ -n "$reason" ] || die '--reason is required'
  if [ "$waiting" = true ] && ! names_a_date "$reason" && ! hands_over_to_other "$reason"; then
    die "a wait needs a date in --reason (YYYY-MM-DD, a full weekday name or mon/tue/thu/fri, tomorrow, next week, or a day number with a month) or a hand-over to someone named other than the captain (waiting on/for Name, routed to Name, handed (over) to Name, assigned to Name, Name will ...); without one it is a park with no end: $reason"
  fi
  epoch=$(now_epoch)
  require_state_lock
  path=$(item_path "$key")
  # A record that left the hot set is still reachable by key: leaving the
  # polling set is a location, never a loss of the item.
  restore_inactive_item "$key" "$path"
  [ -f "$path" ] || die "no open item with that key: $key"
  if [ "$waiting" = true ]; then
    save_item "$path" "$(item_body "$key" "$(record_field "$path" source)" \
      "$(record_field "$path" kind)" "$(record_field "$path" ref)" \
      "$(record_field "$path" link)" "$(record_field "$path" class)" \
      "$(record_field "$path" title)" "$(record_field "$path" digest)" waiting \
      "$(record_field "$path" created)" "$epoch" \
      "$(record_field "$path" source_epoch)" "$(record_field "$path" notified)" \
      "$(record_field "$path" notified_digest)" "$(record_field "$path" revisions)" \
      "$(record_field "$path" provenance)" "$reason" '' "$(attention_fields "$path")")"
    log_event "item $key moved to waiting-on-others: $reason"
    printf 'waiting %s\n' "$key"
    return 0
  fi
  # Archived, not deleted: the item leaves the active list and its evidence -
  # source, ref, link, provenance, revision count - is preserved verbatim.
  mkdir -p "$ARCHIVE_DIR"
  dest=$(archive_path "$key")
  save_item "$dest" "$(item_body "$key" "$(record_field "$path" source)" \
    "$(record_field "$path" kind)" "$(record_field "$path" ref)" \
    "$(record_field "$path" link)" "$(record_field "$path" class)" \
    "$(record_field "$path" title)" "$(record_field "$path" digest)" archived \
    "$(record_field "$path" created)" "$epoch" \
    "$(record_field "$path" source_epoch)" "$(record_field "$path" notified)" \
    "$(record_field "$path" notified_digest)" "$(record_field "$path" revisions)" \
    "$(record_field "$path" provenance)" "$reason" "$epoch" "$(attention_fields "$path")")"
  rm -f "$path"
  log_event "item $key archived: $reason"
  printf 'archived %s\n' "$key"
}

# --- listing ----------------------------------------------------------------

for_each_item() {
  local dir=$1 f
  [ -d "$dir" ] || return 0
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"
  done
}

count_items_in_state() {
  local dir=$1 want=$2 path state n=0
  while IFS="$FIELD_SEP" read -r path state; do
    [ -n "$path" ] || continue
    [ "$state" = "$want" ] || continue
    n=$((n + 1))
  done <<EOF
$(scan_records "$dir" state)
EOF
  printf '%s\n' "$n"
}

count_records() {
  for_each_item "$1" | grep -c '[^[:space:]]' || true
}

# `--state inactive` is a LOCATION, not a state field: those records still read
# `open`, they have simply left the polled set past their class horizon. A bare
# `items` lists every location, so nothing this gate keeps is invisible.
items_cmd() {
  local want='' dirs dir path key state class source title
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --state) [ "$#" -ge 2 ] || die '--state requires a value'; want=$2; shift 2 ;;
      *) die "unknown items argument: $1" ;;
    esac
  done
  case "$want" in
    open|waiting) dirs=$ITEM_DIR ;;
    archived) dirs=$ARCHIVE_DIR ;;
    inactive) dirs=$INACTIVE_DIR ;;
    '') dirs="$ITEM_DIR $INACTIVE_DIR $ARCHIVE_DIR" ;;
    *) die "unknown state: $want" ;;
  esac
  for dir in $dirs; do
    while IFS="$FIELD_SEP" read -r path key state class source title; do
      [ -n "$path" ] || continue
      case "$want" in
        ''|inactive) ;;
        *) [ "$want" = "$state" ] || continue ;;
      esac
      printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$state" "$class" "$source" "$title"
    done <<EOF
$(scan_records "$dir" key state class source title)
EOF
  done
}

sources_cmd() {
  local epoch id rec
  [ "$#" -eq 0 ] || die 'sources takes no arguments'
  epoch=$(now_epoch)
  load_inventory
  if [ -z "$INVENTORY_IDS" ]; then
    printf 'sources: <none enrolled>\tinventory: %s\n' "$CFG_SOURCES_FILE"
    return 0
  fi
  for id in $INVENTORY_IDS; do
    rec=$(source_record "$id")
    printf '%s\t%s\t%s\tcheckpoint=%s\tlast_ok=%s\tfailures=%s\t%s\n' \
      "$id" "$(inventory_field "$id" 2)" "$(source_status "$id" "$epoch")" \
      "$(record_field "$rec" checkpoint)" "$(record_field "$rec" last_ok)" \
      "$(record_field "$rec" failures)" "$(inventory_field "$id" 3)"
  done
}

# --- notification -------------------------------------------------------------

notify_field() {
  record_field "$NOTIFY_FILE" "$1"
}

# Payloads already sent today, reset by the local day rather than a rolling
# window so the daily cap means what the captain would read it to mean.
notify_today_count() {
  local epoch=$1 day sent
  day=$(local_date "$epoch")
  sent=$(notify_field count)
  case "$sent" in ''|*[!0-9]*) sent=0 ;; esac
  [ "$(notify_field day)" = "$day" ] || sent=0
  printf '%s\n' "$sent"
}

save_notify() {
  local last=$1 day=$2 count=$3
  write_atomic "$NOTIFY_FILE" "$(printf 'last=%s\nday=%s\ncount=%s' "$last" "$day" "$count")" \
    || die 'cannot write the notification record'
}

# An item is notifiable when it is open, in a notifiable class, and either has
# never been notified or its content changed since the notification that went
# out. That last clause is what makes an edit re-notify exactly once and an
# unchanged poll never re-notify at all.
#
# One pass over the item directory hands back every column the three callers
# need - the count, the quiet-hours bypass check, the wake signature and the
# rendered payload - so the live wake path costs a bounded couple of processes
# instead of five per item twice per sweep.
# Columns: key, digest, class, title, link.
notifiable_rows() {
  local quiet=$1 path key digest class title link state notified notified_digest
  while IFS="$FIELD_SEP" read -r path key digest class title link state notified notified_digest; do
    [ -n "$path" ] || continue
    [ "$state" = open ] || continue
    is_notify_class "$class" || continue
    if [ "$quiet" = true ]; then
      is_quiet_bypass_class "$class" || continue
    fi
    if [ -n "$notified" ] && [ "$notified_digest" = "$digest" ]; then
      continue
    fi
    printf '%s%s%s%s%s%s%s%s%s\n' \
      "$key" "$FIELD_SEP" "$digest" "$FIELD_SEP" "$class" "$FIELD_SEP" \
      "$title" "$FIELD_SEP" "$link"
  done <<EOF
$(scan_records "$ITEM_DIR" key digest class title link state notified notified_digest)
EOF
}

# The ONE decision for "can a payload go out right now, and if not, why not".
# It prints `<state> <count>` and nothing else: `notify-due` renders from it,
# and `pending`, `check` and `status` report it. Scraping the rendered payload
# instead collapsed every refusal and every suppression into the same silence
# as "nothing to send", which is precisely what a blocked alert must not do.
#   none          nothing is notifiable right now
#   unconfigured  no recipient is configured
#   unverified    the recipient was never checked against the captain account
#   capped        the bounded payloads for this local day are spent
#   spaced        the minimum gap since the last payload has not elapsed
#   ready         a payload can be rendered and sent
notify_state() {
  local epoch=$1 day quiet=false rows count last lastday sent class bypass=false
  enabled || { printf 'none 0\n'; return 0; }
  day=$(local_date "$epoch")
  ! in_quiet_hours "$epoch" || quiet=true
  rows=$(notifiable_rows "$quiet")
  count=$(printf '%s' "$rows" | grep -c '[^[:space:]]' || true)
  if [ "$count" -eq 0 ]; then
    printf 'none 0\n'
    return 0
  fi
  # The recipient is checked against the known captain account BEFORE any
  # payload can be rendered for it. Standing scope covers private alerts to the
  # captain and nobody else, so an unverified recipient is a refusal.
  if [ -z "$CFG_NOTIFY_RECIPIENT" ]; then
    printf 'unconfigured %s\n' "$count"
    return 0
  fi
  if [ "$CFG_NOTIFY_VERIFIED" != true ]; then
    printf 'unverified %s\n' "$count"
    return 0
  fi
  for class in $(printf '%s\n' "$rows" | cut -d"$FIELD_SEP" -f3); do
    ! is_quiet_bypass_class "$class" || bypass=true
  done
  last=$(notify_field last)
  lastday=$(notify_field day)
  sent=$(notify_field count)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  case "$sent" in ''|*[!0-9]*) sent=0 ;; esac
  [ "$lastday" = "$day" ] || sent=0
  if [ "$sent" -ge "$CFG_NOTIFY_MAX_PER_DAY" ]; then
    printf 'capped %s\n' "$count"
    return 0
  fi
  if [ "$bypass" != true ] && [ $((epoch - last)) -lt "$CFG_NOTIFY_MIN_INTERVAL" ]; then
    printf 'spaced %s\n' "$count"
    return 0
  fi
  printf 'ready %s\n' "$count"
}

notify_state_count() {
  local count=${1##* }
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  printf '%s\n' "$count"
}

# WHICH items are notifiable and what they currently say, not merely how many
# there are. A bare count collides on the most ordinary sequence this gate
# sees - one urgent ask surfaced, cleared by the captain, and replaced by a
# different one - and a colliding signature reads as already surfaced, so the
# new ask never reaches the live wake path. Folding each item's digest in
# means a correction to an alert already reported is a change too.
notify_identity() {
  local epoch=$1 quiet=false pairs
  ! in_quiet_hours "$epoch" || quiet=true
  pairs=$(notifiable_rows "$quiet" \
    | awk -F"$FIELD_SEP" 'NF { printf "%s:%s\n", $1, $2 }' \
    | LC_ALL=C sort | tr '\n' ' ')
  [ -n "$pairs" ] || { printf 'none\n'; return 0; }
  digest_hex "$pairs"
}

# How a state that is neither `ready` nor empty reads on a captain-facing
# surface, so a cap or a refusal is visible instead of looking like quiet.
notify_state_phrase() {
  case "$1" in
    unconfigured) printf 'blocked, notify_recipient is not configured\n' ;;
    unverified) printf 'blocked, notify_recipient_verified is not true\n' ;;
    capped) printf 'held, the daily notification cap is spent\n' ;;
    spaced) printf 'held, the minimum gap since the last payload has not elapsed\n' ;;
    *) printf 'ready to send\n' ;;
  esac
}

# Renders. Does NOT send: sending is the orchestrator's authenticated path, and
# the items are only stamped once it confirms with `notify-sent`, so an
# interrupted send re-renders instead of vanishing.
notify_due() {
  local epoch quiet=false rows count state key class title link
  [ "$#" -eq 0 ] || die 'notify-due takes no arguments'
  enabled || return 0
  epoch=$(now_epoch)
  state=$(notify_state "$epoch")
  case "${state%% *}" in
    none) return 0 ;;
    unconfigured) die "notify_recipient is not configured in $CONFIG_FILE" ;;
    unverified)
      die "notify_recipient_verified is not true in $CONFIG_FILE; verify the recipient against the known captain account before enabling notifications" ;;
    # Nothing is lost: the items stay notifiable and `pending`/`status` report
    # the suppression, so a cap is visible rather than silent.
    capped|spaced) return 0 ;;
  esac
  ! in_quiet_hours "$epoch" || quiet=true
  rows=$(notifiable_rows "$quiet")
  count=$(notify_state_count "$state")
  printf 'recipient: %s\n' "$CFG_NOTIFY_RECIPIENT"
  printf 'items: %s\n' "$count"
  printf 'keys: %s\n' "$(printf '%s\n' "$rows" | cut -d"$FIELD_SEP" -f1 | tr '\n' ' ')"
  printf -- '---\n'
  printf 'Intake needs you (%s):\n' "$count"
  while IFS="$FIELD_SEP" read -r key _ class title link; do
    [ -n "$key" ] || continue
    printf -- '- [%s] %s%s\n' "$class" "$title" "${link:+ $link}"
  done <<EOF
$rows
EOF
  printf 'Full brief: %s brief\n' "$0"
}

notify_sent() {
  local keys='' epoch day key path sent lastday skipped='' stamped_count=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --keys) [ "$#" -ge 2 ] || die '--keys requires a value'; keys=$2; shift 2 ;;
      *) die "unknown notify-sent argument: $1" ;;
    esac
  done
  require_enabled
  [ -n "$keys" ] || die '--keys is required'
  epoch=$(now_epoch)
  day=$(local_date "$epoch")
  require_state_lock
  for key in $keys; do
    require_id 'item key' "$key"
    path=$(item_path "$key")
    if ! [ -f "$path" ]; then
      skipped="$skipped $key"
      continue
    fi
    stamped_count=$((stamped_count + 1))
    save_item "$path" "$(item_body "$key" "$(record_field "$path" source)" \
      "$(record_field "$path" kind)" "$(record_field "$path" ref)" \
      "$(record_field "$path" link)" "$(record_field "$path" class)" \
      "$(record_field "$path" title)" "$(record_field "$path" digest)" \
      "$(record_field "$path" state)" "$(record_field "$path" created)" \
      "$(record_field "$path" updated)" "$(record_field "$path" source_epoch)" \
      "$epoch" "$(record_field "$path" digest)" "$(record_field "$path" revisions)" \
      "$(record_field "$path" provenance)" "$(record_field "$path" resolution)" \
      "$(record_field "$path" resolved_at)" "$(attention_fields "$path")")"
  done
  lastday=$(notify_field day)
  sent=$(notify_field count)
  case "$sent" in ''|*[!0-9]*) sent=0 ;; esac
  [ "$lastday" = "$day" ] || sent=0
  save_notify "$epoch" "$day" "$((sent + 1))"
  log_event "notification delivered for: $keys"
  printf 'CHANNEL_INTAKE: notification recorded for %s item(s)\n' "$stamped_count"
  [ -z "$skipped" ] || printf 'skipped (already resolved):%s\n' "$skipped"
}

# --- rendered surfaces --------------------------------------------------------

resolve_out() {
  local out=$1
  [ -n "$out" ] || return 0
  case "$out" in
    /*) ;;
    *) die "--out must be an absolute path: $out" ;;
  esac
  case "/$out/" in
    */../*) die "--out must not contain a .. path component: $out" ;;
  esac
  if [ -n "$CFG_REPORT_DIR" ]; then
    case "$out" in
      "$CFG_REPORT_DIR"/*) ;;
      *) die "--out is outside the configured report_dir: $out" ;;
    esac
  fi
}

# Only a captain-requested render reaches this, and only after the page is
# already on disk. It is deliberately fail-soft: the render is the deliverable
# and the open is a convenience, so a host with no opener, an opener that is
# not installed, or one that exits non-zero all report the miss and leave the
# command successful rather than turning a written page into a failed command.
default_open_command() {
  if [ -n "$CFG_OPEN_COMMAND" ]; then
    printf '%s\n' "$CFG_OPEN_COMMAND"
  elif [ "$(uname 2>/dev/null)" = Darwin ]; then
    printf 'open\n'
  else
    printf 'xdg-open\n'
  fi
}

open_report() {
  local path=$1 opener
  opener=$(default_open_command)
  if ! command -v "$opener" >/dev/null 2>&1; then
    printf 'CHANNEL_INTAKE: could not open %s - no opener named %s on this host; the page is written\n' \
      "$path" "$opener"
    return 0
  fi
  if ! "$opener" "$path" >/dev/null 2>&1; then
    printf 'CHANNEL_INTAKE: could not open %s - %s failed; the page is written\n' \
      "$path" "$opener"
    return 0
  fi
  printf 'CHANNEL_INTAKE: opened %s\n' "$path"
}

section_items() {
  local want_state=$1 epoch=$2 path state class title link source created found=false
  shift 2
  while IFS="$FIELD_SEP" read -r path state class title link source created; do
    [ -n "$path" ] || continue
    [ "$state" = "$want_state" ] || continue
    if [ "$#" -gt 0 ]; then
      case " $* " in
        *" $class "*) ;;
        *) continue ;;
      esac
    fi
    found=true
    printf -- '- [%s] %s%s (%s, first seen %s)\n' "$class" \
      "$title" "${link:+ $link}" "$source" "$(local_date "$created")"
  done <<EOF
$(scan_records "$ITEM_DIR" state class title link source created)
EOF
  [ "$found" = true ] || printf -- '- nothing\n'
}

render_brief() {
  local epoch=$1 id f
  printf '# Channel intake brief - %s\n\n' "$(local_fmt "$epoch" '%Y-%m-%d %H:%M %Z')"
  printf '## Coverage\n\n'
  printf 'Enrolled sources only. Enrolling these does not enrol every channel, mailbox or board in the workspace.\n'
  # shellcheck disable=SC2016
  printf 'A source reading `unknown` did not complete its last read; that is not the same as nothing new.\n\n'
  load_inventory
  if [ -z "$INVENTORY_IDS" ]; then
    printf -- '- no sources enrolled\n'
  else
    for id in $INVENTORY_IDS; do
      # shellcheck disable=SC2016
      printf -- '- `%s` (%s): %s - last read %s, %s\n' "$id" \
        "$(inventory_field "$id" 2)" "$(source_status "$id" "$epoch")" \
        "$(freshness_phrase "$id" "$epoch")" "$(inventory_field "$id" 3)"
    done
  fi
  printf '\n## What changed\n\n'
  changed_section "$epoch"
  printf '\n## What needs you\n\n'
  section_items open "$epoch" urgent outage deadline obligation
  printf '\n## Waiting on others\n\n'
  section_items waiting "$epoch"
  printf '\n## Next dated actions\n\n'
  section_items open "$epoch" deadline
  printf '\n## Automation candidates\n\n'
  printf 'Proposals only. Nothing here is prepared, staged or executable, and detecting one grants no permission to act.\n\n'
  section_items open "$epoch" automation-candidate
  printf '\n## Detection limits\n\n'
  printf -- '- An in-place edit older than the %ss revision window is not detected.\n' "$CFG_REVISION_WINDOW"
  printf -- '- A reply on a thread whose parent is not in the tracked set can appear in no cursor read.\n'
  printf -- '- The tracked set is bounded, not forever: a parent whose reply marker has not advanced within %ss leaves it, and replies on a parent that has left are not re-read.\n' \
    "$CFG_REVISION_WINDOW"
  # shellcheck disable=SC2016
  printf -- '- Routine traffic older than %ss leaves the polled set and is listed by `items --state inactive`. Nothing is deleted, and nothing owed, waiting or corrected ever leaves.\n' \
    "$BRIEF_WINDOW"
  printf -- '- The %ss poll interval is a target detection latency, not a guaranteed upper bound: sleep, offline stretches, backoff and queue delay all add to it.\n' "$CFG_INTERVAL"
  printf -- '- Measured detection latency so far: %s\n' "$(latency_summary)"
}

freshness_phrase() {
  local id=$1 epoch=$2 last_ok
  last_ok=$(record_field "$(source_record "$id")" last_ok)
  case "$last_ok" in
    ''|*[!0-9]*) printf 'never\n' ;;
    *) printf '%ss ago\n' "$((epoch - last_ok))" ;;
  esac
}

# What changed is the day's readable accumulation: routine traffic that needs
# no action, every correction to an item already on the ledger, and anything
# closed recently. It is bounded by BRIEF_WINDOW so it stays a brief rather
# than growing into the whole history.
BRIEF_WINDOW=86400

changed_section() {
  local epoch=$1 path found=false revisions resolved_at created updated edited
  local class title source resolution
  while IFS="$FIELD_SEP" read -r path revisions updated created class title source; do
    [ -n "$path" ] || continue
    case "$revisions" in ''|*[!0-9]*) revisions=0 ;; esac
    if [ "$revisions" -gt 0 ]; then
      # Bounded like every other row here: a correction is news on the day it
      # lands, not a permanent fixture of every later brief.
      case "$updated" in ''|*[!0-9]*) continue ;; esac
      [ $((epoch - updated)) -le "$BRIEF_WINDOW" ] || continue
      found=true
      printf -- '- %s was corrected %s time(s) (%s)\n' "$title" "$revisions" "$source"
      continue
    fi
    # Routine traffic and team updates are never a ping; this is where they accumulate.
    case "$class" in routine|update) ;; *) continue ;; esac
    case "$created" in ''|*[!0-9]*) continue ;; esac
    [ $((epoch - created)) -le "$BRIEF_WINDOW" ] || continue
    found=true
    printf -- '- %s (%s)\n' "$title" "$source"
  done <<EOF
$(scan_records "$ITEM_DIR" revisions updated created class title source)
EOF
  while IFS="$FIELD_SEP" read -r path resolved_at edited title resolution; do
    [ -n "$path" ] || continue
    case "$edited" in
      ''|*[!0-9]*) ;;
      *)
        # An edit that arrived after the item was closed is news, but the item
        # stays closed: the reader is told the source moved, not handed the
        # obligation back.
        if [ $((epoch - edited)) -le "$BRIEF_WINDOW" ]; then
          found=true
          printf -- '- %s was edited after it was closed; it stays closed\n' "$title"
        fi
        ;;
    esac
    case "$resolved_at" in ''|*[!0-9]*) continue ;; esac
    [ $((epoch - resolved_at)) -le "$BRIEF_WINDOW" ] || continue
    found=true
    printf -- '- %s was closed: %s\n' "$title" "$resolution"
  done <<EOF
$(scan_records "$ARCHIVE_DIR" resolved_at edited_after_resolution title resolution)
EOF
  [ "$found" = true ] || printf -- '- nothing\n'
}

latency_summary() {
  [ -f "$LATENCY_LOG" ] || { printf 'no samples yet\n'; return 0; }
  awk -F'\t' '
    { n++; s += $3; if ($3 > max) max = $3 }
    END {
      if (n == 0) { print "no samples yet"; exit }
      printf "%d sample(s), mean %ds, max %ds\n", n, s / n, max
    }
  ' "$LATENCY_LOG"
}

brief_cmd() {
  local out='' epoch body open=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --out) [ "$#" -ge 2 ] || die '--out requires a value'; out=$2; shift 2 ;;
      --open) open=true; shift ;;
      *) die "unknown brief argument: $1" ;;
    esac
  done
  require_enabled
  resolve_out "$out"
  [ "$open" != true ] || [ -n "$out" ] || die '--open requires --out; there is no page to open'
  epoch=$(now_epoch)
  body=$(render_brief "$epoch")
  if [ -n "$out" ]; then
    # Overwriting the same path is deliberate: a background run updates the
    # existing page instead of leaving a trail of dated files to reopen.
    write_atomic "$out" "$body" || die "cannot write the brief: $out"
    printf 'CHANNEL_INTAKE: brief written to %s\n' "$out"
    [ "$open" != true ] || open_report "$out"
  else
    printf '%s\n' "$body"
  fi
}

# The daily to-do list is rendered from the same ledger as the brief, so a
# correction, a resolution and a completed obligation reconcile across both by
# construction rather than needing a second pass over two stores.
render_todo() {
  local epoch=$1 path state class title link source found=false
  printf '# Daily to-do - %s\n\n' "$(local_date "$epoch")"
  printf 'Human obligations only. Executable automations live in the Action Deck behind their own approval.\n\n'
  while IFS="$FIELD_SEP" read -r path state class title link source; do
    [ -n "$path" ] || continue
    [ "$state" = open ] || continue
    case "$class" in
      automation-candidate|routine|update) continue ;;
    esac
    found=true
    printf -- '- [ ] %s%s (%s)\n' "$title" "${link:+ $link}" "$source"
  done <<EOF
$(scan_records "$ITEM_DIR" state class title link source)
EOF
  [ "$found" = true ] || printf -- '- [ ] nothing outstanding\n'
  printf '\n## Waiting on others\n\n'
  section_items waiting "$epoch"
}

todo_cmd() {
  local out='' epoch body open=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --out) [ "$#" -ge 2 ] || die '--out requires a value'; out=$2; shift 2 ;;
      --open) open=true; shift ;;
      *) die "unknown todo argument: $1" ;;
    esac
  done
  require_enabled
  resolve_out "$out"
  [ "$open" != true ] || [ -n "$out" ] || die '--open requires --out; there is no page to open'
  epoch=$(now_epoch)
  body=$(render_todo "$epoch")
  if [ -n "$out" ]; then
    write_atomic "$out" "$body" || die "cannot write the to-do list: $out"
    printf 'CHANNEL_INTAKE: to-do list written to %s\n' "$out"
    [ "$open" != true ] || open_report "$out"
  else
    printf '%s\n' "$body"
  fi
}

# --- watcher check and session-start surface ----------------------------------

# The watcher contract: one line when firstmate should wake, nothing otherwise,
# finishing well inside FM_CHECK_TIMEOUT. Suppression is by signature, so an
# unchanged state wakes the primary once rather than on every poll. Stdout is
# not a durable watcher acknowledgement, so an unchanged state wakes again at
# most every CHECK_BACKSTOP seconds to bound a wake lost before delivery.
#
# Due sources and notifiable items are two independent conditions and each
# carries its own signature and its own marker. One combined snapshot would
# couple them: a claim that empties the due set while an alert is still held
# reads as a brand-new combined state, so the primary would be woken again
# about the alert it has already been told about, twice per poll interval, for
# as long as the alert stays held - and `capped`, `spaced` and an unverified
# recipient are all standing conditions rather than edge cases.
#
# Each signature carries the term that actually moves under it - the
# last-attempt watermark for due sources, the identity of the notifiable set
# for notifications - and a condition that is currently absent clears its own
# marker. That is what the morning gate gets from folding its monotonic
# `updated` stamp in: without it a recurring identical state is suppressed
# forever and the live wake path fires once in the life of the home.
CHECK_DUE_FILE_NAME='check-surfaced-due'
CHECK_NOTIFY_FILE_NAME='check-surfaced-notify'
CHECK_BACKSTOP=43200

check_signal() {
  local epoch due count notify notify_token line='' progress wake=false
  local due_file notify_file due_signature='' notify_signature='' saved seen
  [ "$#" -eq 0 ] || die 'check takes no arguments'
  enabled || return 0
  epoch=$(now_epoch)
  lock_state "$CHECK_LOCK_WAIT" || return 0
  due_file="$INTAKE_DIR/$CHECK_DUE_FILE_NAME"
  notify_file="$INTAKE_DIR/$CHECK_NOTIFY_FILE_NAME"
  due=$(due_source_ids "$epoch")
  count=$(printf '%s' "$due" | grep -c '[^[:space:]]' || true)
  notify=$(notify_state "$epoch")
  notify_token=${notify%% *}
  notify=$(notify_state_count "$notify")

  if [ "$count" -gt 0 ]; then
    progress=$(last_attempt_watermark)
    due_signature="$count:$progress"
    saved=$(read_line_file "$due_file"); seen=${saved##*|}
    case "$seen" in ''|*[!0-9]*) seen=0 ;; esac
    if [ "$saved" != "$due_signature|$seen" ] || [ "$epoch" -lt "$seen" ] || [ $((epoch - seen)) -ge "$CHECK_BACKSTOP" ]; then
      wake=true
    fi
    line="$CFG_LABEL: $count source(s) due to read"
  fi
  if [ "$notify" -gt 0 ]; then
    notify_signature="$notify_token:$notify:$(notify_identity "$epoch")"
    saved=$(read_line_file "$notify_file"); seen=${saved##*|}
    case "$seen" in ''|*[!0-9]*) seen=0 ;; esac
    if [ "$saved" != "$notify_signature|$seen" ] || [ "$epoch" -lt "$seen" ] || [ $((epoch - seen)) -ge "$CHECK_BACKSTOP" ]; then
      wake=true
    fi
    line="${line:-$CFG_LABEL:}${line:+,} $notify item(s) $(notify_state_phrase "$notify_token")"
  fi

  # An absent condition clears its own marker whether or not this sweep wakes,
  # because that is what re-arms its next genuine wake.
  [ -n "$due_signature" ] || rm -f "$due_file"
  [ -n "$notify_signature" ] || rm -f "$notify_file"
  if [ "$wake" != true ]; then
    unlock_state
    return 0
  fi
  if [ -n "$due_signature" ]; then
    write_atomic "$due_file" "$due_signature|$epoch" || { unlock_state; return 0; }
  fi
  if [ -n "$notify_signature" ]; then
    write_atomic "$notify_file" "$notify_signature|$epoch" || { unlock_state; return 0; }
  fi
  unlock_state
  printf '%s\n' "$line"
}

# Read-only. Prints at most one diagnostic-convention line per condition, and
# nothing at all on a home that is not opted in or has nothing owed.
pending() {
  local epoch count notify notify_token armed unknown
  [ "$#" -eq 0 ] || die 'pending takes no arguments'
  enabled || return 0
  epoch=$(now_epoch)
  count=$(due_source_ids "$epoch" | grep -c '[^[:space:]]' || true)
  [ "$count" -eq 0 ] \
    || printf 'CHANNEL_INTAKE: %s source(s) due for %s - take them with %s claim\n' \
      "$count" "$CFG_LABEL" "$0"
  # A refused or suppressed alert reads as itself here. Reporting only the
  # sendable count would make "the recipient was never verified" and "the day's
  # cap is spent" indistinguishable from a quiet home.
  notify=$(notify_state "$epoch")
  notify_token=${notify%% *}
  notify=$(notify_state_count "$notify")
  [ "$notify" -eq 0 ] \
    || printf 'CHANNEL_INTAKE: %s item(s) %s for %s\n' \
      "$notify" "$(notify_state_phrase "$notify_token")" "$CFG_LABEL"
  unknown=$(unknown_sources "$epoch")
  [ -z "$unknown" ] \
    || printf 'CHANNEL_INTAKE: source(s) reading unknown for %s: %s\n' "$CFG_LABEL" "$unknown"
  # Nothing re-creates the live-session shim once it is gone, so report the
  # loss where an operator already looks and name the one command that repairs
  # it. Read-only on purpose: session start must not pay a mutation on every
  # home just to keep a per-device opt-in.
  [ "$count" -gt 0 ] || [ "$notify" -gt 0 ] || return 0
  armed=$(check_armed_state)
  [ "$armed" != armed ] || return 0
  printf 'CHANNEL_INTAKE: %s live check is %s - re-arm it with %s arm-check\n' \
    "$CFG_LABEL" "$armed" "$0"
}

unknown_sources() {
  local epoch=$1 id out=
  load_inventory
  for id in $INVENTORY_IDS; do
    [ "$(source_status "$id" "$epoch")" = unknown ] || continue
    out="$out${out:+ }$id"
  done
  printf '%s\n' "$out"
}

status_cmd() {
  local epoch
  [ "$#" -eq 0 ] || die 'status takes no arguments'
  epoch=$(now_epoch)
  printf 'config: %s\n' "$CONFIG_FILE"
  printf 'enabled: %s\n' "$CFG_ENABLED"
  printf 'timezone: %s\n' "${CFG_TIMEZONE:-<host local time>}"
  printf 'interval_seconds: %s\n' "$CFG_INTERVAL"
  printf 'interval_floor_seconds: %s\n' "$MIN_INTERVAL"
  printf 'revision_window_seconds: %s\n' "$CFG_REVISION_WINDOW"
  printf 'stale_after_seconds: %s\n' "$CFG_STALE_AFTER"
  printf 'backoff_seconds: %s\n' "$CFG_BACKOFF"
  printf 'backoff_max_seconds: %s\n' "$CFG_BACKOFF_MAX"
  printf 'quiet_hours: %s\n' \
    "$([ -z "$CFG_QUIET_START" ] && printf '<unset>' || printf '%s-%s' "$CFG_QUIET_START" "$CFG_QUIET_END")"
  printf 'in_quiet_hours: %s\n' "$(in_quiet_hours "$epoch" && printf true || printf false)"
  printf 'active_window: %s\n' \
    "$([ -z "$CFG_ACTIVE_START" ] && printf '<unset>' || printf '%s-%s' "$CFG_ACTIVE_START" "$CFG_ACTIVE_END")"
  printf 'in_active_window: %s\n' "$(in_active_window "$epoch" && printf true || printf false)"
  printf 'notify_min_interval_seconds: %s\n' "$CFG_NOTIFY_MIN_INTERVAL"
  printf 'notify_max_per_day: %s\n' "$CFG_NOTIFY_MAX_PER_DAY"
  printf 'notify_recipient_set: %s\n' \
    "$([ -n "$CFG_NOTIFY_RECIPIENT" ] && printf true || printf false)"
  printf 'notify_recipient_verified: %s\n' "$CFG_NOTIFY_VERIFIED"
  printf 'sources_file: %s\n' "$CFG_SOURCES_FILE"
  printf 'report_dir: %s\n' "${CFG_REPORT_DIR:-<unset>}"
  printf 'open_command: %s\n' "$(default_open_command)"
  printf 'label: %s\n' "$CFG_LABEL"
  printf 'local_date_now: %s\n' "$(local_date "$epoch")"
  printf 'sources_enrolled: %s\n' "$(load_inventory; printf '%s' "$INVENTORY_IDS" | grep -c '[^[:space:]]' || true)"
  printf 'sources_due: %s\n' "$(due_source_ids "$epoch" | grep -c '[^[:space:]]' || true)"
  printf 'sources_unknown: %s\n' "$(unknown_sources "$epoch")"
  # Open and waiting both live in the active directory, so counting the
  # directory would report work handed to someone else as still owed.
  printf 'items_open: %s\n' "$(count_items_in_state "$ITEM_DIR" open)"
  printf 'items_waiting: %s\n' "$(count_items_in_state "$ITEM_DIR" waiting)"
  # Retired routine and update records are reported, never silently gone: they
  # left the polled set past their horizon and `items --state inactive` lists them.
  printf 'items_inactive: %s\n' "$(count_records "$INACTIVE_DIR")"
  printf 'items_archived: %s\n' "$(count_records "$ARCHIVE_DIR")"
  printf 'tracked_threads: %s\n' \
    "$(find "$THREAD_DIR" -type f 2>/dev/null | grep -c '[^[:space:]]' || true)"
  printf 'notifications_today: %s\n' "$(notify_today_count "$epoch")"
  printf 'notifications_state: %s\n' "$(notify_state "$epoch")"
  printf 'measured_latency: %s\n' "$(latency_summary)"
  printf 'check_armed: %s\n' "$(check_armed_state)"
}

print_interval() {
  [ "$#" -eq 0 ] || die 'interval takes no arguments'
  printf '%s\n' "$CFG_INTERVAL"
}

load_config

case "${1:-}" in
  tick) shift; tick "$@" ;;
  claim) shift; claim "$@" ;;
  observe) shift; observe "$@" ;;
  complete) shift; complete_source "$@" ;;
  fail) shift; fail_source "$@" ;;
  resolve) shift; resolve_item "$@" ;;
  items) shift; items_cmd "$@" ;;
  sources) shift; sources_cmd "$@" ;;
  notify-due) shift; notify_due "$@" ;;
  notify-sent) shift; notify_sent "$@" ;;
  brief) shift; brief_cmd "$@" ;;
  todo) shift; todo_cmd "$@" ;;
  check) shift; check_signal "$@" ;;
  arm-check) shift; arm_check "$@" ;;
  disarm-check) shift; disarm_check "$@" ;;
  pending) shift; pending "$@" ;;
  status) shift; status_cmd "$@" ;;
  interval) shift; print_interval "$@" ;;
  -h|--help) usage ;;
  '') usage; exit 2 ;;
  *) die "unknown command: $1" ;;
esac
