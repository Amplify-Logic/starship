#!/usr/bin/env bash
# fm-chart-room.sh - the captain's chart room: a private read-only fleet view.
#
# Serves one small page server on IPv4 loopback that renders every view fresh on
# request from the records that already exist - the backlog through tasks-axi,
# data/projects.md, task metadata, finished reports - plus the optional per-project
# goal charter in data/goals/<project>.md (format: docs/chart-room.md).
#
# Nothing is cached, pre-generated, or refreshed in the background, so a link
# followed hours after it was printed still shows the records as they are now.
# The server is strictly read-only: it never writes to the backlog, task metadata,
# decisions, reports, or any project, and it makes no outbound network calls.
#
# The bind address is the literal 127.0.0.1 constant in bin/fm-chart-room.mjs and
# there is no flag or environment variable that widens it, so the chart room
# cannot be published to a network by configuration.
#
# Views:
#   /                          fleet home, Captain's Call first
#   /p/<project>               that project's goal map
#   /p/<project>/node/<id>     the story behind one card
#   /report/<task-id>          a finished report, rendered
#
# Usage:
#   fm-chart-room.sh serve [--port <n>]
#   fm-chart-room.sh render <path>          render one view to stdout and exit
#   fm-chart-room.sh data                   print the derived model as JSON
#   fm-chart-room.sh url [<path>]           print the loopback URL for a view
#
# Environment:
#   FM_HOME              private Firstmate home; defaults to this repository root
#   FM_CHART_ROOM_PORT   dedicated IPv4 loopback port; defaults to 4390
#                        (4387 general Lavish, 4388 decisions, 4389 reports are taken)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
ENGINE="$SCRIPT_DIR/fm-chart-room.mjs"
PORT="${FM_CHART_ROOM_PORT:-4390}"
HOST=127.0.0.1

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-chart-room: %s\n' "$*" >&2
  exit 1
}

require_runtime() {
  command -v node >/dev/null 2>&1 || fail "node is required"
  command -v tasks-axi >/dev/null 2>&1 || fail "tasks-axi is required"
  [ -f "$ENGINE" ] || fail "render engine is missing: $ENGINE"
}

check_port() {
  case "$1" in
    ''|*[!0-9]*|0) fail "port must be a positive integer: $1" ;;
  esac
  [ "$1" -le 65535 ] || fail "port must be below 65536: $1"
}

command_serve() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --port) shift; PORT=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  require_runtime
  check_port "$PORT"
  exec node "$ENGINE" serve --home "$FM_HOME" --port "$PORT"
}

command_render() {
  local view=${1:-/}
  [ "$#" -le 1 ] || { usage >&2; exit 2; }
  case "$view" in
    /*) ;;
    *) fail "view must start with /: $view" ;;
  esac
  require_runtime
  node "$ENGINE" render --home "$FM_HOME" --path "$view"
}

command_data() {
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  require_runtime
  node "$ENGINE" data --home "$FM_HOME"
}

command_url() {
  local view=${1:-/}
  [ "$#" -le 1 ] || { usage >&2; exit 2; }
  case "$view" in
    /*) ;;
    *) fail "view must start with /: $view" ;;
  esac
  check_port "$PORT"
  printf 'http://%s:%s%s\n' "$HOST" "$PORT" "$view"
}

case "${1:-}" in
  serve) shift; command_serve "$@" ;;
  render) shift; command_render "$@" ;;
  data) shift; command_data "$@" ;;
  url) shift; command_url "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
