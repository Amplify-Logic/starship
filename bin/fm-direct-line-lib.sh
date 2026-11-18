#!/usr/bin/env bash
# fm-direct-line-lib.sh - the one owner of a direct-line second mate's opt-in
# and of its "talking with owner" state.
#
# A direct-line second mate is a local second mate the owner may talk to
# directly, through bin/fm-direct-line.sh, instead of only through the first
# mate. docs/direct-line.md owns the design; this library owns the facts every
# other script reads about it.
#
# OPT-IN takes two records, so a mate can never opt itself in:
#   - its own data/charter.md holds the exact line FM_DIRECT_LINE_CHARTER_LINE
#     (bin/fm-brief.sh --direct-line writes it, with the rules the mate keeps);
#   - the PARENT home records it: <parent-state>/direct-line/<id>/enabled,
#     written only by `bin/fm-direct-line.sh enable <id>` from the parent.
# Every other mate is off, which is the default.
#
# TALKING WITH OWNER. An opted-in mate is talking with its owner while its
# primary is alive (the pid in its state/.lock answers kill -0) and either
#   - the owner's last direct-line message, stamped in the PARENT's
#     <parent-state>/direct-line/<id>/last-owner-message, is less than
#     FM_DIRECT_LINE_TALK_SECS old (default 1800), or
#   - the mate itself declared it is waiting on the owner (bin/fm-direct-line.sh
#     waiting writes <mate-home>/state/direct-line/waiting-on-owner) for at most
#     FM_DIRECT_LINE_WAIT_MAX_SECS (14400).
# A stamp from the future (an owner stamp more than a minute ahead, or a wait
# beyond that maximum) is ignored, so neither record can extend the state past
# its bound. While a mate is talking the first mate never nudges or relaunches
# it: a steering-inbox doorbell younger than FM_DIRECT_LINE_DEFER_MAX_SECS
# (default 3600) is deferred, after which the ordinary ladder and its escalation
# resume; the watcher's drain nudge and stall alert are held; and
# bin/fm-control.sh refuses interrupt, exit, and relaunch without the owner's
# word.
#
# No side effects on source.

FM_DIRECT_LINE_CHARTER_LINE='Direct line: on'
FM_DIRECT_LINE_TALK_SECS_DEFAULT=1800
FM_DIRECT_LINE_WAIT_MAX_SECS=14400
FM_DIRECT_LINE_DEFER_MAX_SECS_DEFAULT=3600

# shellcheck disable=SC2034 # Output globals read by sourcing callers.
FM_DIRECT_LINE_TALKING_REASON=
# shellcheck disable=SC2034 # Output globals read by sourcing callers.
FM_DIRECT_LINE_TALKING_UNTIL=

_fm_direct_line_number() {  # <value> <default>
  case "$1" in ''|*[!0-9]*) printf '%s\n' "$2" ;; *) printf '%s\n' "$((10#$1))" ;; esac
}

fm_direct_line_talk_secs() {
  _fm_direct_line_number "${FM_DIRECT_LINE_TALK_SECS:-}" "$FM_DIRECT_LINE_TALK_SECS_DEFAULT"
}

fm_direct_line_defer_max_secs() {
  _fm_direct_line_number "${FM_DIRECT_LINE_DEFER_MAX_SECS:-}" "$FM_DIRECT_LINE_DEFER_MAX_SECS_DEFAULT"
}

# 0 when <home>'s own charter carries the opt-in line.
fm_direct_line_charter_opted_in() {  # <mate-home>
  local charter="$1/data/charter.md"
  [ -f "$charter" ] && [ ! -L "$charter" ] || return 1
  grep -qxF "$FM_DIRECT_LINE_CHARTER_LINE" "$charter" 2>/dev/null
}

# The parent-side record directory for mate <id>.
fm_direct_line_parent_dir() {  # <parent-state> <mate-id>
  printf '%s/direct-line/%s\n' "$1" "$2"
}

# 0 when mate <id> at <mate-home> is opted in on both sides (see OPT-IN).
fm_direct_line_enabled() {  # <parent-state> <mate-id> <mate-home>
  local flag
  case "$2" in ''|.*|*/*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  flag="$(fm_direct_line_parent_dir "$1" "$2")/enabled"
  [ -f "$flag" ] && [ ! -L "$flag" ] || return 1
  fm_direct_line_charter_opted_in "$3"
}

# Create a private directory (no symlink, owner-only).
_fm_direct_line_private_dir() {  # <dir>
  if [ -L "$1" ] || { [ -e "$1" ] && [ ! -d "$1" ]; }; then
    return 1
  fi
  mkdir -p "$1" 2>/dev/null || return 1
  chmod 700 "$1" 2>/dev/null || true
}

fm_direct_line_enable() {  # <parent-state> <mate-id>
  local dir
  dir=$(fm_direct_line_parent_dir "$1" "$2")
  _fm_direct_line_private_dir "$dir" || return 1
  date -u +%Y-%m-%dT%H:%M:%SZ > "$dir/enabled"
}

fm_direct_line_disable() {  # <parent-state> <mate-id>
  rm -f "$(fm_direct_line_parent_dir "$1" "$2")/enabled"
}

# The epoch stored in <file>, or nothing when it is absent, a symlink, or not
# a plain number. Leading zeros are read as decimal.
_fm_direct_line_read_epoch() {  # <file>
  local value
  [ -f "$1" ] && [ ! -L "$1" ] || return 0
  value=$(head -n 1 "$1" 2>/dev/null) || return 0
  case "$value" in ''|*[!0-9]*) return 0 ;; esac
  [ "${#value}" -le 12 ] || return 0
  printf '%s\n' "$((10#$value))"
}

_fm_direct_line_write_epoch() {  # <file> <epoch>
  local tmp
  _fm_direct_line_private_dir "${1%/*}" || return 1
  tmp=$(mktemp "${1%/*}/.epoch.XXXXXX") || return 1
  if ! printf '%s\n' "$2" > "$tmp" || ! mv -f "$tmp" "$1"; then
    rm -f "$tmp"
    return 1
  fi
}

# Stamp the owner's message to mate <id> at <epoch> (default now), in the parent.
fm_direct_line_mark_owner_message() {  # <parent-state> <mate-id> [epoch]
  _fm_direct_line_write_epoch "$(fm_direct_line_parent_dir "$1" "$2")/last-owner-message" "${3:-$(date +%s)}"
}

# Put back a stamp a failed send set: <epoch> as it was, or none when empty.
fm_direct_line_restore_owner_message() {  # <parent-state> <mate-id> <epoch-or-empty>
  if [ -n "$3" ]; then
    fm_direct_line_mark_owner_message "$1" "$2" "$3"
  else
    rm -f "$(fm_direct_line_parent_dir "$1" "$2")/last-owner-message"
  fi
}

fm_direct_line_last_owner_message() {  # <parent-state> <mate-id>
  _fm_direct_line_read_epoch "$(fm_direct_line_parent_dir "$1" "$2")/last-owner-message"
}

fm_direct_line_waiting_file() {  # <mate-home>
  printf '%s/state/direct-line/waiting-on-owner\n' "$1"
}

fm_direct_line_set_waiting() {  # <mate-home> <until-epoch>
  _fm_direct_line_write_epoch "$(fm_direct_line_waiting_file "$1")" "$2"
}

fm_direct_line_clear_waiting() {  # <mate-home>
  rm -f "$(fm_direct_line_waiting_file "$1")"
}

fm_direct_line_waiting_until() {  # <mate-home>
  _fm_direct_line_read_epoch "$(fm_direct_line_waiting_file "$1")"
}

# 0 when the primary holding <mate-home>'s session lock is a live process.
fm_direct_line_primary_alive() {  # <mate-home>
  local pid
  [ -f "$1/state/.lock" ] && [ ! -L "$1/state/.lock" ] || return 1
  pid=$(head -n 1 "$1/state/.lock" 2>/dev/null) || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null
}

# 0 when opted-in mate <id> at <mate-home> is talking with its owner now (see
# the header). Sets FM_DIRECT_LINE_TALKING_REASON to owner-message or
# waiting-on-owner and FM_DIRECT_LINE_TALKING_UNTIL to the epoch the state
# lapses; both are empty when it returns 1.
fm_direct_line_talking() {  # <parent-state> <mate-id> <mate-home> [now]
  local state=$1 id=$2 home=$3 now=${4:-$(date +%s)} last waiting until=0 reason='' talk
  FM_DIRECT_LINE_TALKING_REASON=
  FM_DIRECT_LINE_TALKING_UNTIL=
  fm_direct_line_enabled "$state" "$id" "$home" || return 1
  fm_direct_line_primary_alive "$home" || return 1
  talk=$(fm_direct_line_talk_secs)
  last=$(fm_direct_line_last_owner_message "$state" "$id")
  if [ -n "$last" ] && [ "$last" -le "$((now + 60))" ] && [ "$((last + talk))" -gt "$now" ]; then
    until=$((last + talk))
    reason='owner-message'
  fi
  waiting=$(fm_direct_line_waiting_until "$home")
  if [ -n "$waiting" ] && [ "$waiting" -gt "$now" ] \
    && [ "$waiting" -le "$((now + FM_DIRECT_LINE_WAIT_MAX_SECS))" ] && [ "$waiting" -gt "$until" ]; then
    until=$waiting
    reason='waiting-on-owner'
  fi
  [ -n "$reason" ] || return 1
  # shellcheck disable=SC2034 # Output globals read by sourcing callers.
  FM_DIRECT_LINE_TALKING_REASON=$reason
  # shellcheck disable=SC2034 # Output globals read by sourcing callers.
  FM_DIRECT_LINE_TALKING_UNTIL=$until
  return 0
}

# The local second mate home a parent steering-inbox record is addressed to,
# printed: <rec> is <state>/<task>.inbox/<seq>.msg (or under handled/), and
# <state>/<task>.meta must record kind=secondmate, a home, and no remote host.
# Returns 1 for any other target, which has no home of its own here.
fm_direct_line_inbox_record_home() {  # <record-path>
  local dir=${1%/*} base task state meta line kind='' home='' remote=''
  dir=${dir%/handled}
  base=${dir##*/}
  task=${base%.inbox}
  [ -n "$task" ] && [ "$task" != "$base" ] || return 1
  state=${dir%/*}
  meta="$state/$task.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      kind=*) kind=${line#kind=} ;;
      home=*) home=${line#home=} ;;
      remote_host=*) remote=${line#remote_host=} ;;
    esac
  done < "$meta"
  [ "$kind" = secondmate ] && [ -z "$remote" ] || return 1
  case "$home" in /*) ;; *) return 1 ;; esac
  [ -d "$home/state" ] || return 1
  printf '%s\n' "$home"
}

# 0 when the doorbell for steering-inbox record <rec> waits: its mate is
# talking with its owner and the record is younger than
# FM_DIRECT_LINE_DEFER_MAX_SECS. An older record is never deferred, so the
# ordinary ladder rings and escalates it.
fm_direct_line_record_defers() {  # <record-path> [now]
  local rec=$1 now=${2:-$(date +%s)} home dir state task mtime
  home=$(fm_direct_line_inbox_record_home "$rec") || return 1
  dir=${rec%/*}
  dir=${dir%/handled}
  task=${dir##*/}
  task=${task%.inbox}
  state=${dir%/*}
  fm_direct_line_talking "$state" "$task" "$home" "$now" || return 1
  mtime=$(stat -c %Y "$rec" 2>/dev/null || stat -f %m "$rec" 2>/dev/null) || return 0
  case "$mtime" in ''|*[!0-9]*) return 0 ;; esac
  [ "$((now - mtime))" -lt "$(fm_direct_line_defer_max_secs)" ]
}
