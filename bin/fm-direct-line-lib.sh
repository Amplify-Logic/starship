#!/usr/bin/env bash
# fm-direct-line-lib.sh - the one owner of a direct-line second mate's opt-in
# and of its "talking with owner" state.
#
# A direct-line second mate is a local second mate whose charter lets the owner
# talk to it directly, through bin/fm-direct-line.sh, instead of only through
# the first mate. docs/direct-line.md owns the design; this library owns the
# two facts every other script reads about it.
#
# OPT-IN. A second mate is direct-line only when its own data/charter.md holds
# the exact line in FM_DIRECT_LINE_CHARTER_LINE (bin/fm-brief.sh --direct-line
# writes it). Every other charter is off, which is the default.
#
# TALKING WITH OWNER. A direct-line second mate is talking with its owner while
# either
#   - the owner's last direct-line message reached it less than
#     FM_DIRECT_LINE_TALK_SECS seconds ago (default 1800), or
#   - the mate declared it is waiting on the owner (bin/fm-direct-line.sh
#     waiting) and that declaration has not expired.
# While it is talking, the first mate never nudges or relaunches it: the
# steering-inbox doorbell is deferred, the watcher's drain nudge and stall
# alert are held, and bin/fm-control.sh refuses interrupt, exit, and relaunch
# without the owner's word. The durable records live in the mate's own
# state/direct-line/ directory.
#
# No side effects on source.

FM_DIRECT_LINE_CHARTER_LINE='Direct line: on'
FM_DIRECT_LINE_TALK_SECS_DEFAULT=1800
# shellcheck disable=SC2034 # Read by bin/fm-direct-line.sh waiting.
FM_DIRECT_LINE_WAIT_SECS_DEFAULT=43200

# shellcheck disable=SC2034 # Output globals read by sourcing callers.
FM_DIRECT_LINE_TALKING_REASON=
# shellcheck disable=SC2034 # Output globals read by sourcing callers.
FM_DIRECT_LINE_TALKING_UNTIL=

# 0 when <home>'s own charter opts into the direct line.
fm_direct_line_enabled() {  # <home>
  local charter="$1/data/charter.md"
  [ -f "$charter" ] && [ ! -L "$charter" ] || return 1
  grep -qxF "$FM_DIRECT_LINE_CHARTER_LINE" "$charter" 2>/dev/null
}

fm_direct_line_dir() {  # <home>
  printf '%s/state/direct-line\n' "$1"
}

fm_direct_line_talk_secs() {
  local secs=${FM_DIRECT_LINE_TALK_SECS:-$FM_DIRECT_LINE_TALK_SECS_DEFAULT}
  case "$secs" in ''|*[!0-9]*) secs=$FM_DIRECT_LINE_TALK_SECS_DEFAULT ;; esac
  printf '%s\n' "$secs"
}

# Create <home>'s state/direct-line directory, owner-only.
fm_direct_line_ensure_dir() {  # <home>
  local dir
  dir=$(fm_direct_line_dir "$1")
  if [ -L "$dir" ] || { [ -e "$dir" ] && [ ! -d "$dir" ]; }; then
    return 1
  fi
  mkdir -p "$dir" 2>/dev/null || return 1
  chmod 700 "$dir" 2>/dev/null || true
}

# The epoch stored in <file>, or nothing when it is absent, a symlink, or not
# a plain number.
_fm_direct_line_read_epoch() {  # <file>
  local value
  [ -f "$1" ] && [ ! -L "$1" ] || return 0
  value=$(head -n 1 "$1" 2>/dev/null) || return 0
  case "$value" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s\n' "$value"
}

_fm_direct_line_write_epoch() {  # <file> <epoch>
  local tmp
  tmp=$(mktemp "${1%/*}/.epoch.XXXXXX") || return 1
  if ! printf '%s\n' "$2" > "$tmp" || ! mv -f "$tmp" "$1"; then
    rm -f "$tmp"
    return 1
  fi
}

# Record that the owner's message reached <home> at <epoch> (default now).
fm_direct_line_mark_owner_message() {  # <home> [epoch]
  local at=${2:-$(date +%s)}
  fm_direct_line_ensure_dir "$1" || return 1
  _fm_direct_line_write_epoch "$(fm_direct_line_dir "$1")/last-owner-message" "$at"
}

fm_direct_line_last_owner_message() {  # <home>
  _fm_direct_line_read_epoch "$(fm_direct_line_dir "$1")/last-owner-message"
}

# Record that <home> is waiting on the owner until <epoch>.
fm_direct_line_set_waiting() {  # <home> <until-epoch>
  fm_direct_line_ensure_dir "$1" || return 1
  _fm_direct_line_write_epoch "$(fm_direct_line_dir "$1")/waiting-on-owner" "$2"
}

fm_direct_line_clear_waiting() {  # <home>
  rm -f "$(fm_direct_line_dir "$1")/waiting-on-owner"
}

fm_direct_line_waiting_until() {  # <home>
  _fm_direct_line_read_epoch "$(fm_direct_line_dir "$1")/waiting-on-owner"
}

# 0 when the direct-line second mate at <home> is talking with its owner now
# (see the header). Sets FM_DIRECT_LINE_TALKING_REASON to owner-message or
# waiting-on-owner and FM_DIRECT_LINE_TALKING_UNTIL to the epoch the state
# lapses; both are empty when it returns 1.
fm_direct_line_talking() {  # <home> [now]
  local home=$1 now=${2:-$(date +%s)} last waiting until=0 reason=''
  FM_DIRECT_LINE_TALKING_REASON=
  FM_DIRECT_LINE_TALKING_UNTIL=
  fm_direct_line_enabled "$home" || return 1
  last=$(fm_direct_line_last_owner_message "$home")
  if [ -n "$last" ] && [ "$((last + $(fm_direct_line_talk_secs)))" -gt "$now" ]; then
    until=$((last + $(fm_direct_line_talk_secs)))
    reason='owner-message'
  fi
  waiting=$(fm_direct_line_waiting_until "$home")
  if [ -n "$waiting" ] && [ "$waiting" -gt "$now" ] && [ "$waiting" -gt "$until" ]; then
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
