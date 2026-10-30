#!/usr/bin/env bash
# Install and inspect the local morning-intake schedule on macOS launchd.
#
# Usage:
#   fm-morning-intake-schedule.sh render
#   fm-morning-intake-schedule.sh install
#   fm-morning-intake-schedule.sh status
#   fm-morning-intake-schedule.sh remove
#   fm-morning-intake-schedule.sh --help
#
# The schedule is intentionally visible, not an opaque cron entry.
# `render` prints the complete plist, `status` prints its path, the resolved
# knobs and the installed definition, and `install` writes
# ~/Library/LaunchAgents/<label>.plist, loads it, and arms the watcher check.
#
# `StartInterval` plus `RunAtLoad` is the whole trigger. launchd runs the job on
# login and then on the interval, and a job whose interval elapsed while the
# machine was asleep runs shortly after it wakes. That is the catch-up path, and
# it is why the intake is described as the FIRST AVAILABLE MORNING rather than a
# lid-open event: launchd exposes no such event here and none is claimed.
#
# The gate itself lives in bin/fm-morning-intake.sh, which owns the local day,
# the threshold, deduplication, retries and the completion watermark. This
# script only decides WHEN that gate is consulted, and reads the cadence back
# from the gate owner rather than parsing config a second time. The LaunchAgent
# itself is written by the shared owner in bin/fm-launchd-schedule-lib.sh.
#
# The label is derived from FM_HOME, so each operational home installs its own
# agent and installing here never disturbs another home's schedule.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
INTAKE="$SCRIPT_DIR/fm-morning-intake.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-morning-intake-schedule: %s\n' "$*" >&2
  exit 2
}

[ -x "$INTAKE" ] || die "intake gate is not executable: $INTAKE"

intake() {
  FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$ROOT" "$INTAKE" "$@"
}

# The team checkout's bin/fm-launchd-schedule-lib.sh, sourced below, reads
# these settings.
# shellcheck disable=SC2034
{
  FM_LAUNCHD_STEM=morning-intake
  FM_LAUNCHD_PROGRAM="$INTAKE"
  FM_LAUNCHD_PROGRAM_ARG=run
  FM_LAUNCHD_ROOT="$ROOT"
  FM_LAUNCHD_FM_HOME="$FM_HOME"
  FM_LAUNCHD_LOG_DIR="$DATA/morning-intake"
  FM_LAUNCHD_AGENTS_DIR=${FM_MORNING_INTAKE_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}
  # Overridable so the behavior suite can install and remove against a temporary
  # home without loading anything into the operator's real launchd session.
  FM_LAUNCHD_LAUNCHCTL=${FM_MORNING_INTAKE_LAUNCHCTL:-launchctl}
  FM_LAUNCHD_REMOVE_NEEDS_DARWIN=false
}

# shellcheck source=bin/fm-launchd-schedule-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-launchd-schedule-lib.sh"

fm_launchd_interval() {
  intake interval
}

# Refuse rather than enrolling a home that never opted in: this is what keeps a
# fresh clone or a seeded secondmate from acquiring a schedule by accident.
fm_launchd_preinstall() {
  [ "$(intake status | awk '$1 == "enabled:" { print $2 }')" = true ] \
    || die "this home is not opted in; add 'enabled = true' to config/morning-intake first"
}

# Arm the live-session delivery path too, so a running fleet is actually woken
# instead of only discovering the intake at the next session start.
fm_launchd_postinstall() {
  intake arm-check
}

fm_launchd_postremove() {
  # Durable records under data/morning-intake are deliberately left in place:
  # removing the schedule is not the same as discarding the intake history.
  intake disarm-check >/dev/null 2>&1 || true
}

fm_launchd_status_detail() {
  intake status
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
