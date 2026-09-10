#!/usr/bin/env bash
# Install and inspect the local weekly upstream-watch schedule on macOS launchd.
#
# Usage:
#   fm-upstream-watch-schedule.sh render
#   fm-upstream-watch-schedule.sh install
#   fm-upstream-watch-schedule.sh status
#   fm-upstream-watch-schedule.sh remove
#   fm-upstream-watch-schedule.sh --help
#
# The schedule is intentionally visible, not an opaque cron entry.
# `render` prints the complete plist, `status` prints its path and contents, and
# `install` writes ~/Library/LaunchAgents/<label>.plist before loading it.
# The LaunchAgent itself is written by the shared owner in
# bin/fm-launchd-schedule-lib.sh; this script owns only the cadence.
# The default interval is 604800 seconds (weekly).
# Override it with FM_UPSTREAM_WATCH_INTERVAL_SECONDS or a private
# config/upstream-watch line: `interval_seconds = N`.
# launchd calls bin/fm-upstream-watch.sh run; generation remains separately
# callable by a future private-repository workflow.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
DEFAULT_INTERVAL=604800

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-upstream-watch-schedule: %s\n' "$*" >&2
  exit 2
}

interval_seconds() {
  local value=${FM_UPSTREAM_WATCH_INTERVAL_SECONDS:-} line key parsed
  if [ -z "$value" ] && [ -f "$CONFIG/upstream-watch" ]; then
    while IFS= read -r line; do
      line=$(printf '%s\n' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
      case "$line" in ''|'#'*) continue ;; esac
      key=${line%%=*}
      parsed=${line#*=}
      key=$(printf '%s\n' "$key" | tr -d '[:space:]')
      parsed=$(printf '%s\n' "$parsed" | tr -d '[:space:]')
      [ "$key" = interval_seconds ] || die "unknown config key: $key"
      [ -z "$value" ] || die 'duplicate interval_seconds setting'
      value=$parsed
    done <"$CONFIG/upstream-watch"
  fi
  [ -n "$value" ] || value=$DEFAULT_INTERVAL
  case "$value" in ''|*[!0-9]*|0) die "interval_seconds must be a positive integer: $value" ;; esac
  printf '%s\n' "$value"
}

FM_LAUNCHD_STEM=upstream-watch
FM_LAUNCHD_PROGRAM="$SCRIPT_DIR/fm-upstream-watch.sh"
FM_LAUNCHD_PROGRAM_ARG=run
FM_LAUNCHD_ROOT="$ROOT"
FM_LAUNCHD_FM_HOME="$FM_HOME"
FM_LAUNCHD_LOG_DIR="$DATA/upstream-watch"
FM_LAUNCHD_AGENTS_DIR=${FM_UPSTREAM_WATCH_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}
FM_LAUNCHD_LAUNCHCTL=${FM_UPSTREAM_WATCH_LAUNCHCTL:-launchctl}
FM_LAUNCHD_REMOVE_NEEDS_DARWIN=true

# shellcheck source=bin/fm-launchd-schedule-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-launchd-schedule-lib.sh"

fm_launchd_interval() {
  interval_seconds
}

fm_launchd_status_detail() {
  printf 'interval_seconds: %s\n' "$(interval_seconds)"
}

case "${1:-}" in
  render) [ "$#" -eq 1 ] || die 'render takes no arguments'; fm_launchd_render ;;
  install) [ "$#" -eq 1 ] || die 'install takes no arguments'; fm_launchd_install ;;
  status) [ "$#" -eq 1 ] || die 'status takes no arguments'; fm_launchd_status ;;
  remove) [ "$#" -eq 1 ] || die 'remove takes no arguments'; fm_launchd_remove ;;
  -h|--help) usage ;;
  '') usage; exit 2 ;;
  *) die "unknown command: $1" ;;
esac
