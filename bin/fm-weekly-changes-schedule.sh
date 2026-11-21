#!/usr/bin/env bash
# Install and inspect the local weekly "what changed" page schedule on macOS launchd.
#
# Usage:
#   fm-weekly-changes-schedule.sh render
#   fm-weekly-changes-schedule.sh install
#   fm-weekly-changes-schedule.sh status
#   fm-weekly-changes-schedule.sh remove
#   fm-weekly-changes-schedule.sh --help
#
# The schedule is intentionally visible, not an opaque cron entry.
# `render` prints the complete plist, `status` prints its path, the resolved
# settings and the installed definition, `install` writes
# ~/Library/LaunchAgents/<label>.plist and loads it, and `remove` unloads it.
#
# launchd runs bin/fm-weekly-changes.py run at login and then every
# interval_seconds; a run whose interval elapsed while the machine slept runs
# shortly after it wakes. The page owner decides whether this week's page is
# due, so this script only decides WHEN that owner is consulted and reads the
# cadence back from it rather than parsing config a second time. The
# LaunchAgent itself is written by the shared owner in
# bin/fm-launchd-schedule-lib.sh. The job runs with the installer's PATH so it
# finds the same gh the home uses; reinstall after moving gh.
#
# The label is derived from FM_HOME, so each operational home installs its own
# agent and installing here never disturbs another home's schedule.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PAGE="$SCRIPT_DIR/fm-weekly-changes.py"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-weekly-changes-schedule: %s\n' "$*" >&2
  exit 2
}

[ -x "$PAGE" ] || die "page owner is not executable: $PAGE"

page() {
  FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$ROOT" "$PAGE" "$@"
}

FM_LAUNCHD_STEM=weekly-changes
FM_LAUNCHD_PROGRAM="$PAGE"
FM_LAUNCHD_PROGRAM_ARG=run
FM_LAUNCHD_ROOT="$ROOT"
FM_LAUNCHD_FM_HOME="$FM_HOME"
FM_LAUNCHD_LOG_DIR="$DATA/weekly-changes"
FM_LAUNCHD_AGENTS_DIR=${FM_WEEKLY_CHANGES_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}
# Overridable so the behavior suite can install and remove against a temporary
# home without loading anything into the operator's real launchd session.
FM_LAUNCHD_LAUNCHCTL=${FM_WEEKLY_CHANGES_LAUNCHCTL:-launchctl}
FM_LAUNCHD_REMOVE_NEEDS_DARWIN=false
FM_LAUNCHD_PATH=$PATH

# shellcheck source=bin/fm-launchd-schedule-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-launchd-schedule-lib.sh"

fm_launchd_interval() {
  page interval
}

# Refuse rather than enrolling a home that never opted in: this is what keeps a
# fresh clone or a seeded secondmate from acquiring a schedule by accident.
fm_launchd_preinstall() {
  [ "$(page status | awk '$1 == "enabled:" { print $2 }')" = true ] \
    || die "this home is not opted in; add 'enabled = true' to config/weekly-changes first"
}

fm_launchd_status_detail() {
  page status
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
