#!/usr/bin/env bash
# fm-status-cache-lib.sh - cache and freshness primitives for status renderers.
#
# The status companion refreshes once a second, so every reading it shows has to
# come from a cache that some slower reader fills out of band. Two renderers now
# need that shape - the Codex session/quota supply and the fleet-state supply -
# and they need it to MEAN the same thing, because both decide from it whether a
# figure is still true enough to show.
#
# These helpers are the mechanism only, and they are pure: nothing here reads
# configuration or decides policy. Each caller keeps its own TTLs and its own
# "is my cache disabled" rule, so a test seam belongs to the library that owns
# the reading rather than to this one.
#
# Every freshness answer fails toward "not fresh": an unreadable, absent, or
# future stamp is never within a window. A renderer that cannot tell how old a
# reading is must show it as unavailable, never as current.
set -u

# fm_status_ttl: a non-negative integer TTL, or the supplied default.
fm_status_ttl() {  # <value> <default>
  case "$1" in
    ''|*[!0-9]*) printf '%s' "$2" ;;
    *) printf '%s' "$1" ;;
  esac
}

# fm_status_age_within: 0 iff <stamp> is a readable epoch no more than <window>
# seconds before <now>.
fm_status_age_within() {  # <now> <stamp> <window>
  local now=$1 stamp=$2 window=$3 age
  case "$stamp" in
    ''|*[!0-9]*) return 1 ;;
  esac
  case "$now" in
    ''|*[!0-9]*) return 1 ;;
  esac
  age=$((now - stamp))
  [ "$age" -ge 0 ] && [ "$age" -lt "$window" ]
}

# fm_status_file_mtime: a file's modification epoch, BSD or GNU stat.
fm_status_file_mtime() {  # <path>
  local modified
  modified=$(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null)
  case "$modified" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$modified"
}

# fm_status_file_size: a file's size in bytes, BSD or GNU stat.
fm_status_file_size() {  # <path>
  local size
  size=$(stat -f %z "$1" 2>/dev/null || stat -c %s "$1" 2>/dev/null)
  case "$size" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$size"
}

# fm_status_cache_key: a filesystem-safe token for a cache file name.
fm_status_cache_key() {  # <value>
  printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_'
}

# fm_status_cache_load: a cached payload whatever its age, so a reading can
# carry its own recorded timestamps rather than inferring them from the file.
fm_status_cache_load() {  # <cache-file>
  [ -f "$1" ] || return 1
  cat "$1" 2>/dev/null
}

# fm_status_cache_read: a cached payload that is still inside its TTL.
fm_status_cache_read() {  # <cache-file> <now> <ttl>
  local modified raw
  [ -f "$1" ] || return 1
  modified=$(fm_status_file_mtime "$1") || return 1
  fm_status_age_within "$2" "$modified" "$3" || return 1
  raw=$(cat "$1" 2>/dev/null) || return 1
  printf '%s' "$raw"
}

# fm_status_cache_write: best effort, and atomic within a directory. A state
# directory that cannot be written costs freshness, never a render.
fm_status_cache_write() {  # <cache-file> <payload>
  printf '%s' "$2" > "$1.$$" 2>/dev/null \
    && mv -f "$1.$$" "$1" 2>/dev/null \
    || rm -f "$1.$$" 2>/dev/null || true
  return 0
}

# fm_status_claim_refresh: 0 iff this caller may start ONE out-of-band refresh
# for <lock>, which it claims for <warm-ttl> seconds. Concurrent renderers, and
# the ticks that follow a refresh that died without writing, are refused, so a
# one-second loop can never pile up detached readers.
#
# The claim records the epoch its holder claimed AT, rather than reading the
# lock's mtime: the caller's clock is its own (a renderer may be rendering a
# stamped frame), so a claim taken a moment ago can carry an mtime slightly
# ahead of the next caller's <now>. Under the reading rule - which fails toward
# "not fresh", and so calls a future stamp stale - that freshly taken claim
# looked expired and a second refresher started over the same fleet. A claim is
# the opposite case from a reading: only a stamp that is readably OLDER than the
# window releases it, and a stamp ahead of <now> is a claim someone just took.
fm_status_claim_refresh() {  # <lock-file> <now> <warm-ttl>
  local lock=$1 now=$2 warm=$3 stamp
  case "$now" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if [ -f "$lock" ]; then
    stamp=$(head -n 1 "$lock" 2>/dev/null | tr -d '[:space:]')
    case "$stamp" in
      ''|*[!0-9]*) stamp=$(fm_status_file_mtime "$lock") || stamp= ;;
    esac
    # No readable age at all leaves the claim reclaimable, so an unreadable lock
    # can never wedge the field it paces at unknown.
    if [ -n "$stamp" ] && [ "$((now - stamp))" -lt "$warm" ]; then
      return 1
    fi
  fi
  printf '%s\n' "$now" > "$lock" 2>/dev/null || return 1
  return 0
}
