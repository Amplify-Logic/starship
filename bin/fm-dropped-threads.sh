#!/usr/bin/env bash
# fm-dropped-threads.sh - opt-in twice-daily "dropped threads" digest.
#
# Usage:
#   fm-dropped-threads.sh run
#   fm-dropped-threads.sh preview [--slot morning|evening]
#   fm-dropped-threads.sh latest [--json]
#   fm-dropped-threads.sh status
#   fm-dropped-threads.sh interval
#   fm-dropped-threads.sh --help
#
# Twice a local day, at about the configured morning and evening times, this
# collects what has been left hanging in THIS home's own records and publishes
# one short digest: a spoken sentence ("Three things are waiting on you: ...")
# plus a short list. It reads local files only, through the canonical snapshot
# (bin/fm-fleet-snapshot.sh --backlog and --secondmate-home-summary, both
# local-only) and each in-flight task's own status log:
#
#   decision    a captain hold that is live or aged (the snapshot's hold_bucket),
#               with its hold-until date as the due date when it has one
#   question    an open needs-decision or blocked event from work under way,
#               the same keyed open-decision set the wake drain folds
#   time-gate   any other held backlog item whose hold-until date has arrived
#   quiet-task  an in-flight task with no captain hold whose newest status event
#               is stamped more than stale_hours ago; an unstamped event is
#               unknown time and is never guessed from a file time, so it is
#               not reported
#
# IT ONLY REPORTS. It never changes the backlog, a hold, a task or the wake
# queue, never wakes firstmate, never writes a captain inbox note, opens no
# network connection, and needs no new macOS permission. It never takes the
# per-home session lock; the only lock is a private mutex over its own record
# directory, so a scheduled run and a manual one cannot both publish a slot.
#
# Delivery is a durable record, which a later Starship Voice change will read
# for the phone card, plus one line spoken at the desk through bin/fm-speak.sh.
# That speaker is itself opt-in (config/speak), so with desk voice off nothing
# is heard. When nothing is waiting the slot's record is still written, with
# `spoken` null and no items, and nothing is spoken. No item text carries a
# link: any http(s) address in a title or note is removed before it is recorded.
#
# `run` is the scheduled entry point (bin/fm-dropped-threads-schedule.sh installs
# it on macOS launchd) and the manual command. It publishes the latest slot whose
# time has passed today, once: a morning missed because the machine slept is
# published on the first run after it wakes, unless the evening time has also
# passed, in which case only the evening digest is published. Nothing is
# published before the morning time. A failed collection writes nothing and
# exits 1, so the next scheduled run tries the same slot again.
# `preview` collects and prints the record `run` would write, writing and
# speaking nothing, and works whether or not the home has opted in.
# `latest` prints the newest published record; `--json` prints it verbatim, or
# `null` when none exists yet.
#
# RECORD FORMAT (schema fm-dropped-threads.v1). This header is its single owner.
# The newest record is data/dropped-threads/latest.json, and each slot's record
# is kept as data/dropped-threads/digests/<local-date>-<slot>.json (those of the
# newest 30 local dates are retained). Each file is one JSON object:
#   schema       "fm-dropped-threads.v1"
#   at           UTC publication time, YYYY-MM-DDTHH:MM:SSZ
#   local_date   the home's local date the slot belongs to, YYYY-MM-DD
#   slot         "morning" or "evening"
#   spoken       the one plain sentence to say, or null when nothing is waiting
#   counts       {decisions, questions, time_gates, quiet_tasks, total}
#   items[]      the short list, most pressing first, at most max_items:
#                {kind, id, text, due} where kind is decision, question,
#                time-gate or quiet-task; text is one short display line; due is
#                the item's YYYY-MM-DD hold-until date or null
#   more         how many items beyond items[] the counts include
# A reader shows `spoken` and items[] once per new `at`, and shows nothing when
# `spoken` is null. Records are replaced whole and atomically, never edited.
#
# Opt-in is per home and per device: with no `enabled = true` line in private
# gitignored config/dropped-threads, `run` does nothing at all, so cloning the
# repo or seeding a secondmate home never enrols it. Configuration is
# `key = value` lines; unknown keys are refused rather than ignored.
#   enabled           true to arm this home (default false)
#   morning           HH:MM local morning digest time (default 08:30)
#   evening           HH:MM local evening digest time, after morning (default 19:30)
#   stale_hours       hours without a status event before a task is quiet (default 24)
#   max_items         longest list a record carries (default 8)
#   interval_seconds  scheduled poll cadence (default 900)
#
# Environment:
#   FM_HOME                   operational home whose records are read
#   FM_DROPPED_THREADS_NOW    epoch second used as "now" (tests)
#   FM_DROPPED_THREADS_SPEAK  speaker command (default bin/fm-speak.sh)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$ROOT}}"
export FM_HOME
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG_FILE="$CONFIG/dropped-threads"
DIGEST_DIR="$DATA/dropped-threads"
RECORDS_DIR="$DIGEST_DIR/digests"
LATEST_FILE="$DIGEST_DIR/latest.json"
LOCK="$DIGEST_DIR/run.lock"
SPEAK=${FM_DROPPED_THREADS_SPEAK:-$SCRIPT_DIR/fm-speak.sh}
KEEP_DAYS=30

# shellcheck source=bin/fm-classify-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"

# launchd starts the job with a bare system PATH; the snapshot's per-task reads
# need the same tools an interactive shell finds.
for _extra in "$HOME/.local/bin" /opt/homebrew/bin /usr/local/bin; do
  case ":$PATH:" in
    *":$_extra:"*) ;;
    *) [ -d "$_extra" ] && PATH="$PATH:$_extra" ;;
  esac
done
unset _extra
export PATH

CFG_ENABLED=false
CFG_MORNING=08:30
CFG_EVENING=19:30
CFG_STALE_HOURS=24
CFG_MAX_ITEMS=8
CFG_INTERVAL=900

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-dropped-threads: %s\n' "$*" >&2
  exit 2
}

require_positive_int() {
  case "$2" in
    ''|*[!0-9]*|0) die "$1 must be a positive integer: $2" ;;
  esac
}

require_hhmm() {
  printf '%s\n' "$2" | grep -Eq '^([01][0-9]|2[0-3]):[0-5][0-9]$' \
    || die "$1 must be HH:MM in 24-hour form: $2"
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
      morning) require_hhmm morning "$value"; CFG_MORNING=$value ;;
      evening) require_hhmm evening "$value"; CFG_EVENING=$value ;;
      stale_hours) require_positive_int stale_hours "$value"; CFG_STALE_HOURS=$value ;;
      max_items) require_positive_int max_items "$value"; CFG_MAX_ITEMS=$value ;;
      interval_seconds) require_positive_int interval_seconds "$value"; CFG_INTERVAL=$value ;;
      *) die "unknown config key: $key" ;;
    esac
  done <"$CONFIG_FILE"
  [ "$CFG_MORNING" \< "$CFG_EVENING" ] \
    || die "evening ($CFG_EVENING) must be later than morning ($CFG_MORNING)"
}

# --- clock ------------------------------------------------------------------

now_epoch() {
  local value=${FM_DROPPED_THREADS_NOW:-}
  if [ -n "$value" ]; then
    case "$value" in
      *[!0-9]*) die "FM_DROPPED_THREADS_NOW must be an epoch second: $value" ;;
    esac
    printf '%s\n' "$value"
    return 0
  fi
  date +%s
}

# Render one strftime format for an epoch in host local time, or in UTC when
# the third argument is "utc".
fmt_epoch() {
  local epoch=$1 fmt=$2 utc=${3:-}
  if [ "$utc" = utc ]; then
    date -u -r "$epoch" "+$fmt" 2>/dev/null \
      || date -u -d "@$epoch" "+$fmt" 2>/dev/null \
      || die "cannot render time; date(1) supports neither -r nor -d"
  else
    date -r "$epoch" "+$fmt" 2>/dev/null \
      || date -d "@$epoch" "+$fmt" 2>/dev/null \
      || die "cannot render time; date(1) supports neither -r nor -d"
  fi
}

# The latest slot whose local time has passed today, or nothing before morning.
due_slot() {
  local hhmm
  hhmm=$(fmt_epoch "$1" '%H:%M')
  if [ "$hhmm" = "$CFG_EVENING" ] || [ "$hhmm" \> "$CFG_EVENING" ]; then
    printf 'evening\n'
  elif [ "$hhmm" = "$CFG_MORNING" ] || [ "$hhmm" \> "$CFG_MORNING" ]; then
    printf 'morning\n'
  fi
}

# --- collection -------------------------------------------------------------

# Newest status event age, in seconds, for every in-flight task with metadata
# and no captain hold whose newest event is stamped at least stale_hours ago,
# as a JSON array of {id, age_seconds}. The stamp grammar is owned by bin/fm-classify-lib.sh.
quiet_tasks_json() {  # <backlog-json-file> <now-epoch>
  local backlog=$1 now=$2 limit id status line epoch age rows=''
  limit=$((CFG_STALE_HOURS * 3600))
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    case "$id" in */*|.*) continue ;; esac
    [ -f "$STATE/$id.meta" ] || continue
    status="$STATE/$id.status"
    [ -f "$status" ] || continue
    line=$(grep -v '^[[:space:]]*$' "$status" 2>/dev/null | tail -1) || continue
    epoch=$(status_line_at_epoch "$line") || continue
    [ "$epoch" -le "$now" ] || continue
    age=$((now - epoch))
    [ "$age" -ge "$limit" ] || continue
    rows="$rows$(jq -cn --arg id "$id" --argjson age "$age" '{id:$id,age_seconds:$age}')"$'\n'
  done < <(jq -r '.records[]? | select(.structured == true and .state == "in_flight" and .hold_bucket == null) | .id' "$backlog")
  printf '%s' "$rows" | jq -cs '.'
}

# Collect and compose one record on stdout. Writes nothing durable.
compose_record() {  # <slot> <now-epoch>
  local slot=$1 now=$2 work snapshot_now today at rc=0
  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-dropped-threads.XXXXXX") || die 'cannot create a scratch directory'
  snapshot_now=$(fmt_epoch "$now" '%Y-%m-%dT%H:%M:%SZ' utc)
  today=$(fmt_epoch "$now" '%Y-%m-%d')
  at=$snapshot_now
  {
    FM_SNAPSHOT_NOW=$snapshot_now FM_SNAPSHOT_NOW_EPOCH=$now \
      "$SCRIPT_DIR/fm-fleet-snapshot.sh" --backlog >"$work/backlog.json" \
      && FM_SNAPSHOT_NOW=$snapshot_now FM_SNAPSHOT_NOW_EPOCH=$now \
        FM_SNAPSHOT_SECONDMATE_DECISIONS=100000 \
        "$SCRIPT_DIR/fm-fleet-snapshot.sh" --secondmate-home-summary >"$work/summary.json" \
      && quiet_tasks_json "$work/backlog.json" "$now" >"$work/quiet.json" \
      && jq -n \
        --slurpfile backlog "$work/backlog.json" \
        --slurpfile summary "$work/summary.json" \
        --slurpfile quiet "$work/quiet.json" \
        --arg at "$at" --arg today "$today" --arg slot "$slot" \
        --argjson stale_hours "$CFG_STALE_HOURS" --argjson max_items "$CFG_MAX_ITEMS" '
        def clean: tostring | gsub("https?://[^\\s]+"; "") | gsub("\\s+"; " ")
          | sub("^ "; "") | sub(" $"; "");
        def short($n): clean | if length > $n then .[:($n - 1)] + "…" else . end;
        def month: ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"][. - 1];
        def day_label: (split("-") | map(tonumber)) as $p
          | "\($p[2]) \($p[1] | month)";
        def words: if . >= 0 and . <= 20 then
            ["no","one","two","three","four","five","six","seven","eight","nine","ten",
             "eleven","twelve","thirteen","fourteen","fifteen","sixteen","seventeen",
             "eighteen","nineteen","twenty"][.]
          else tostring end;
        def plural($one; $many): if . == 1 then $one else $many end;
        def join_and: if length <= 1 then (.[0] // "")
          elif length == 2 then "\(.[0]) and \(.[1])"
          else (.[:-1] | join(", ")) + ", and " + .[-1] end;
        def capital: (.[:1] | ascii_upcase) + .[1:];
        def quiet_span: if . < 172800 then "\((. / 3600) | floor) hours"
          else "\((. / 86400) | floor) days" end;
        ($backlog[0].records // []) as $records
        | ([ $records[] | select(.structured == true) | {key:.id, value:.title} ] | from_entries) as $titles
        | [ $records[]
            | select(.structured == true and .state != "done"
                     and (.hold_bucket == "live" or .hold_bucket == "aged"))
            | {kind:"decision", id, due:(.hold_until // null),
               text:((.title | short(100)) + (if .hold_until then " (due \(.hold_until | day_label))" else "" end)),
               rank:(if .hold_until then 1 elif .hold_bucket == "live" then 4 else 5 end),
               age:(.hold_age_days // 0)} ] as $decisions
        | [ $summary[0].decisions_open[]? | select(.source == "status")
            | {kind:"question", id, due:null,
               text:((($titles[.id] // .id) | short(60)) + " - " + (.summary | short(80))),
               rank:0, age:0} ] as $questions
        | ([ $questions[].id ] + [ $decisions[].id ]) as $listed
        | [ $records[]
            | select(.structured == true and .state != "done" and .hold_bucket == null
                     and .hold_until != null and .hold_until <= $today)
            | select(.id as $id | $listed | index($id) | not)
            | {kind:"time-gate", id, due:.hold_until,
               text:((.title | short(100)) + " (set aside until \(.hold_until | day_label))"),
               rank:2, age:(.hold_age_days // 0)} ] as $gates
        | [ $quiet[0][]
            | select(.id as $id | ($listed + [ $gates[].id ]) | index($id) | not)
            | {kind:"quiet-task", id, due:null,
               text:((($titles[.id] // .id) | short(100)) + " - no news for \(.age_seconds | quiet_span)"),
               rank:3, age:(.age_seconds / 86400)} ] as $quiet_tasks
        | ($decisions + $questions + $gates + $quiet_tasks
           | sort_by([.rank, -.age, .id])) as $all
        | {decisions:($decisions | length), questions:($questions | length),
           time_gates:($gates | length), quiet_tasks:($quiet_tasks | length),
           total:($all | length)} as $counts
        | ([ if $counts.decisions > 0 then
               "\($counts.decisions | words) " + ($counts.decisions | plural("decision"; "decisions")) + " held for you"
             else empty end,
             if $counts.questions > 0 then
               "\($counts.questions | words) " + ($counts.questions | plural("question"; "questions")) + " from work under way"
             else empty end,
             if $counts.time_gates > 0 then
               "\($counts.time_gates | words) set-aside " + ($counts.time_gates | plural("item"; "items")) + " whose date has come"
             else empty end,
             if $counts.quiet_tasks > 0 then
               "\($counts.quiet_tasks | words) " + ($counts.quiet_tasks | plural("task"; "tasks"))
               + " with no news for " + (if $stale_hours == 24 then "a day" else "\($stale_hours) hours" end)
             else empty end ]) as $parts
        | {schema:"fm-dropped-threads.v1", at:$at, local_date:$today, slot:$slot,
           spoken:(if $counts.total == 0 then null
                   else ((if $counts.total == 1 then "one thing is"
                          else "\($counts.total | words) things are" end)
                         + " waiting on you: " + ($parts | join_and) + ".") | capital end),
           counts:$counts,
           items:($all[:$max_items] | map({kind, id, text, due})),
           more:([($all | length) - $max_items, 0] | max)}'
  } || rc=$?
  rm -rf "$work"
  return "$rc"
}

# --- durable records --------------------------------------------------------

write_atomic() {  # <dest> <content-file>
  local dest=$1 src=$2 tmp
  mkdir -p "${dest%/*}"
  tmp=$(umask 077; mktemp "${dest%/*}/.dropped-threads.XXXXXX") || return 1
  cat "$src" >"$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp"
  mv -f "$tmp" "$dest"
}

# Keep the records of the newest KEEP_DAYS local dates; names lead with the date.
prune_records() {
  local dates=() name day i cutoff
  for i in "$RECORDS_DIR"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-*.json; do
    [ -f "$i" ] || continue
    name=${i##*/}
    day=${name:0:10}
    [ "${#dates[@]}" -gt 0 ] && [ "${dates[${#dates[@]}-1]}" = "$day" ] || dates+=("$day")
  done
  [ "${#dates[@]}" -gt "$KEEP_DAYS" ] || return 0
  cutoff=${dates[${#dates[@]}-KEEP_DAYS]}
  for i in "$RECORDS_DIR"/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-*.json; do
    name=${i##*/}
    [ "${name:0:10}" \< "$cutoff" ] && rm -f "$i"
  done
  return 0
}

LOCK_HELD=false

acquire_lock() {
  mkdir -p "$DIGEST_DIR"
  mkdir "$LOCK" 2>/dev/null || return 1
  LOCK_HELD=true
  trap 'release_lock' EXIT
}

release_lock() {
  [ "$LOCK_HELD" = true ] || return 0
  LOCK_HELD=false
  rmdir "$LOCK" 2>/dev/null || true
}

speak_line() {  # <sentence>
  [ -x "$SPEAK" ] || return 0
  "$SPEAK" "$1" >/dev/null 2>&1 \
    || printf 'fm-dropped-threads: the desk speaker did not take the line\n' >&2
}

cmd_run() {
  local now slot day record tmp spoken
  [ "$#" -eq 0 ] || die 'run takes no arguments'
  [ "$CFG_ENABLED" = true ] || return 0
  command -v jq >/dev/null 2>&1 || die 'jq not found'
  now=$(now_epoch)
  slot=$(due_slot "$now")
  [ -n "$slot" ] || return 0
  day=$(fmt_epoch "$now" '%Y-%m-%d')
  record="$RECORDS_DIR/$day-$slot.json"
  [ ! -e "$record" ] || return 0
  # A second run already publishing this slot owns it; this one simply leaves.
  # A crash leaves the directory behind, so one older than an hour is cleared.
  if ! acquire_lock; then
    if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
      rmdir "$LOCK" 2>/dev/null || true
      acquire_lock || return 0
    else
      return 0
    fi
  fi
  [ ! -e "$record" ] || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-dropped-threads-record.XXXXXX") || die 'cannot stage the record'
  if ! compose_record "$slot" "$now" >"$tmp"; then
    rm -f "$tmp"
    printf 'fm-dropped-threads: could not collect the %s digest for %s; the next run tries again\n' "$slot" "$day" >&2
    exit 1
  fi
  if ! write_atomic "$record" "$tmp" || ! write_atomic "$LATEST_FILE" "$tmp"; then
    rm -f "$tmp"
    die 'cannot write the digest record'
  fi
  spoken=$(jq -r '.spoken // empty' "$tmp")
  rm -f "$tmp"
  prune_records
  if [ -n "$spoken" ]; then
    printf 'published %s %s: %s\n' "$day" "$slot" "$spoken"
    speak_line "$spoken"
  else
    printf 'published %s %s: nothing waiting\n' "$day" "$slot"
  fi
}

cmd_preview() {
  local slot='' now
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --slot)
        [ "$#" -ge 2 ] || die '--slot needs morning or evening'
        case "$2" in morning|evening) slot=$2 ;; *) die "unknown slot: $2" ;; esac
        shift 2
        ;;
      *) die "unknown preview argument: $1" ;;
    esac
  done
  command -v jq >/dev/null 2>&1 || die 'jq not found'
  now=$(now_epoch)
  [ -n "$slot" ] || slot=$(due_slot "$now")
  [ -n "$slot" ] || slot=morning
  compose_record "$slot" "$now" || die 'could not collect the digest'
}

cmd_latest() {
  local json=false
  case "${1:-}" in
    '') ;;
    --json) json=true; [ "$#" -eq 1 ] || die 'latest takes at most --json' ;;
    *) die "unknown latest argument: $1" ;;
  esac
  if [ ! -f "$LATEST_FILE" ]; then
    if [ "$json" = true ]; then printf 'null\n'; else printf 'no digest published yet\n'; fi
    return 0
  fi
  if [ "$json" = true ]; then
    cat "$LATEST_FILE"
    return 0
  fi
  jq -r '"\(.local_date) \(.slot): \(.spoken // "nothing waiting")",
         (.items[] | "- \(.text)"),
         (if .more > 0 then "- and \(.more) more" else empty end)' "$LATEST_FILE"
}

cmd_status() {
  [ "$#" -eq 0 ] || die 'status takes no arguments'
  printf 'enabled: %s\n' "$CFG_ENABLED"
  printf 'morning: %s\n' "$CFG_MORNING"
  printf 'evening: %s\n' "$CFG_EVENING"
  printf 'stale_hours: %s\n' "$CFG_STALE_HOURS"
  printf 'max_items: %s\n' "$CFG_MAX_ITEMS"
  printf 'interval_seconds: %s\n' "$CFG_INTERVAL"
  if [ -f "$LATEST_FILE" ] && command -v jq >/dev/null 2>&1; then
    printf 'latest: %s\n' "$(jq -r '"\(.local_date) \(.slot) total=\(.counts.total)"' "$LATEST_FILE")"
  else
    printf 'latest: none\n'
  fi
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') usage; exit 2 ;;
esac

load_config
command=$1
shift
case "$command" in
  run) cmd_run "$@" ;;
  preview) cmd_preview "$@" ;;
  latest) cmd_latest "$@" ;;
  status) cmd_status "$@" ;;
  interval) [ "$#" -eq 0 ] || die 'interval takes no arguments'; printf '%s\n' "$CFG_INTERVAL" ;;
  *) die "unknown command: $command" ;;
esac
