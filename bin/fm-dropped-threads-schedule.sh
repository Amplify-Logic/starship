#!/usr/bin/env bash
# Install and inspect the local dropped-threads digest schedule on macOS launchd.
#
# Usage:
#   fm-dropped-threads-schedule.sh render
#   fm-dropped-threads-schedule.sh install
#   fm-dropped-threads-schedule.sh status
#   fm-dropped-threads-schedule.sh remove
#   fm-dropped-threads-schedule.sh --help
#
# The schedule is intentionally visible, not an opaque cron entry.
# `render` prints the complete plist, `status` prints its path, the resolved
# knobs and the installed definition, `install` writes
# ~/Library/LaunchAgents/<label>.plist and loads it, and `remove` unloads it.
#
# launchd runs bin/fm-dropped-threads.sh run at login and then every
# interval_seconds; a run whose interval elapsed while the machine slept runs
# shortly after it wakes. The digest owner decides which slot, if any, is due,
# so this script only decides WHEN that owner is consulted and reads the
# cadence back from it rather than parsing config a second time. The
# LaunchAgent itself is written by the shared owner in
# bin/fm-launchd-schedule-lib.sh, and nothing besides the agent is armed: the
# digest never wakes firstmate.
#
# The label is derived from FM_HOME, so each operational home installs its own
# agent and installing here never disturbs another home's schedule.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
DIGEST="$SCRIPT_DIR/fm-dropped-threads.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-dropped-threads-schedule: %s\n' "$*" >&2
  exit 2
}

[ -x "$DIGEST" ] || die "digest owner is not executable: $DIGEST"

digest() {
  FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$ROOT" "$DIGEST" "$@"
}

FM_LAUNCHD_STEM=dropped-threads
FM_LAUNCHD_PROGRAM="$DIGEST"
FM_LAUNCHD_PROGRAM_ARG=run
FM_LAUNCHD_ROOT="$ROOT"
FM_LAUNCHD_FM_HOME="$FM_HOME"
FM_LAUNCHD_LOG_DIR="$DATA/dropped-threads"
FM_LAUNCHD_AGENTS_DIR=${FM_DROPPED_THREADS_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}
# Overridable so the behavior suite can install and remove against a temporary
# home without loading anything into the operator's real launchd session.
FM_LAUNCHD_LAUNCHCTL=${FM_DROPPED_THREADS_LAUNCHCTL:-launchctl}
FM_LAUNCHD_REMOVE_NEEDS_DARWIN=false

# shellcheck source=bin/fm-launchd-schedule-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-launchd-schedule-lib.sh"

fm_launchd_interval() {
  digest interval
}

# Refuse rather than enrolling a home that never opted in: this is what keeps a
# fresh clone or a seeded secondmate from acquiring a schedule by accident.
fm_launchd_preinstall() {
  [ "$(digest status | awk '$1 == "enabled:" { print $2 }')" = true ] \
    || die "this home is not opted in; add 'enabled = true' to config/dropped-threads first"
}

fm_launchd_status_detail() {
  digest status
}

case "${1:-}" in
  render) shift; [ "$#" -eq 0 ] || die 'render takes no arguments'; fm_launchd_render ;;
  install) shift; [ "$#" -eq 0 ] || die 'install takes no arguments'; fm_launchd_install ;;
  status) shift; [ "$#" -eq 0 ] || die 'status takes no arguments'; fm_launchd_status ;;
  remove) shift; [ "$#" -eq 0 ] || die 'remove takes no arguments'; fm_launchd_remove ;;
  -h|--help) usage ;;
  '') usage; exit 2 ;;
  *) die "unknown command: $1" ;;
esac
