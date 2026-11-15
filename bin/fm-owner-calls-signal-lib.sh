#!/usr/bin/env bash
# fm-owner-calls-signal-lib.sh - the one cheap signal that the owner's calls
# may have changed.
#
# Why this exists: the bridge strip and the Factory pane show the owner's calls
# (fm_owner_calls in bin/fm-fleet-status-lib.sh) from readings that refresh
# only every so often, because the worker part of each reading is slow. A
# decision answered, parked, released, closed or added changes none of the
# workers, so on 2026-11-15 the strip kept naming a decision the owner had just
# parked as the one to decide next. Both panes now check this signal once a
# second, and recompute the calls on their own the moment it moves.
#
# The signal is two things, printed as one opaque token:
#   - the home's state/.owner-calls-changed stamp, which every command that
#     changes a call rewrites with a fresh value (bin/fm-captain-hold.sh,
#     bin/fm-tasks-axi.sh writes and bin/fm-inbox.sh note), so a backlog kept
#     in any adapter is covered;
#   - the modification time and size of the home's markdown backlog,
#     data/backlog.md, so a write that went around those commands is seen too.
# Two tokens that differ mean the calls may differ; equal tokens mean nothing
# that feeds them was written through those paths. Callers compare tokens for
# equality only and never parse them.
#
# Reading the signal costs one stat and one small read, so a one-second frame
# can afford it. Writing the stamp is best effort: a state directory that cannot
# be written costs snappiness, never the command that changed the call.
set -u

# fm_owner_calls_signal: the token for the home that owns <state-dir>.
fm_owner_calls_signal() {  # <state-dir>
  local state=$1 stamp='' backlog
  if [ -f "$state/.owner-calls-changed" ]; then
    IFS= read -r stamp < "$state/.owner-calls-changed" 2>/dev/null || :
  fi
  case "${OSTYPE:-}" in
    darwin*) backlog=$(/usr/bin/stat -f '%m:%z' "$state/../data/backlog.md" 2>/dev/null) ;;
    *) backlog=$(stat -c '%Y:%s' "$state/../data/backlog.md" 2>/dev/null) ;;
  esac
  stamp=$(printf '%s' "$stamp" | LC_ALL=C tr -cd 'A-Za-z0-9._-')
  case "$backlog" in
    *[!0-9:]*) backlog= ;;
  esac
  printf '%s/%s' "${stamp:--}" "${backlog:--}"
}

# fm_owner_calls_touch: tell every reader of <state-dir>'s owner's calls that
# they may have changed. A missing state directory is left alone.
fm_owner_calls_touch() {  # <state-dir>
  local state=$1 tmp
  [ -d "$state" ] || return 0
  tmp="$state/.owner-calls-changed.$$"
  printf '%s.%s.%s\n' "$(date +%s 2>/dev/null)" "$$" "${RANDOM:-0}" > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$state/.owner-calls-changed" 2>/dev/null \
    || rm -f "$tmp" 2>/dev/null || :
  return 0
}
