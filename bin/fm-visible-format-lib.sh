#!/usr/bin/env bash
# Captain-facing state vocabulary for Herdr presentation surfaces.
#
# Source this library; it defines functions and runs nothing.
#
#   fm_visible_state <canonical-state>   -> NEEDS YOU|FAILED|BLOCKED|WORKING|WAITING|READY
#   fm_visible_icon <visible-state>      -> the state's colour dot
#   fm_visible_aggregate <stats>         -> "🟣 1 NEEDS YOU · 🔵 2 WORKING"
#
# <stats> is the six space-separated counts
# "<needs> <failed> <blocked> <working> <waiting> <ready>", already in urgency
# order, and fm_visible_aggregate's own loop is the single owner of that order:
# it emits only non-zero groups, most urgent first, or "no tasks" when every
# count is zero.
#
# This is the single owner of that vocabulary.
# bin/fm-visible-status.sh renders the live fleet with it, and
# bin/fm-herdr-preview-lib.sh renders the unapproved layout preview with it, so
# the two surfaces can never drift apart on what a state is called or coloured.
# Canonical state itself comes only from bin/fm-crew-state.sh; nothing here
# reads or infers it.

fm_visible_state() {  # <canonical-state>
  case "$1" in
    parked) printf 'NEEDS YOU' ;;
    failed) printf 'FAILED' ;;
    blocked) printf 'BLOCKED' ;;
    working) printf 'WORKING' ;;
    paused) printf 'WAITING' ;;
    done) printf 'READY' ;;
    *) printf 'WAITING' ;;
  esac
}

fm_visible_icon() {  # <visible-state>
  case "$1" in
    'NEEDS YOU') printf '🟣' ;;
    FAILED) printf '🔴' ;;
    BLOCKED) printf '🟠' ;;
    WORKING) printf '🔵' ;;
    WAITING) printf '🟡' ;;
    READY) printf '🟢' ;;
  esac
}

fm_visible_aggregate() {  # <stats>
  local needs failed blocked working waiting ready part icon count label text=
  read -r needs failed blocked working waiting ready <<EOF
$1
EOF
  for part in \
    "🟣:$needs:NEEDS YOU" \
    "🔴:$failed:FAILED" \
    "🟠:$blocked:BLOCKED" \
    "🔵:$working:WORKING" \
    "🟡:$waiting:WAITING" \
    "🟢:$ready:READY"; do
    IFS=: read -r icon count label <<EOF
$part
EOF
    [ "$count" -gt 0 ] || continue
    text="${text}${text:+ · }$icon $count $label"
  done
  printf '%s' "${text:-no tasks}"
}
