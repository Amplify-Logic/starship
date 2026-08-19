#!/usr/bin/env bash
# fm-bridge-view.sh - captain's phone-first read-only fleet page.
#
# Serves one small Python 3 standard-library HTTP server on IPv4 loopback and
# exposes it on the tailnet with Tailscale Serve HTTPS. It never binds
# 0.0.0.0, never enables Funnel, and never writes backlog or fleet state.
# The observation is `fm-bearings-snapshot.sh --json --passive-view`.
#
# The bind address is the literal 127.0.0.1 constant in bin/fm-bridge-view.py
# and there is no flag or environment variable that widens it.
#
# Usage:
#   fm-bridge-view.sh serve [--port <n>] [--host <magicdns>]
#   fm-bridge-view.sh init-passcode
#   fm-bridge-view.sh revoke-sessions
#   fm-bridge-view.sh render-plist
#   fm-bridge-view.sh mailbox-listener
#   fm-bridge-view.sh check-funnel
#
# Environment:
#   FM_HOME                 private Firstmate home; defaults to this repository root
#   FM_BRIDGE_VIEW_PORT     dedicated IPv4 loopback port; defaults to 8766
#   FM_BRIDGE_VIEW_HOST     expected Serve MagicDNS hostname (Host/Origin checks)
#   FM_BRIDGE_VIEW_TEST     set to 1 only in the behavior suite
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
ENGINE="$SCRIPT_DIR/fm-bridge-view.py"
PORT="${FM_BRIDGE_VIEW_PORT:-8766}"
HOST_NAME="${FM_BRIDGE_VIEW_HOST:-}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-bridge-view: %s\n' "$*" >&2
  exit 1
}

require_runtime() {
  command -v python3 >/dev/null 2>&1 || fail "python3 is required"
  [ -f "$ENGINE" ] || fail "server is missing: $ENGINE"
}

check_port() {
  case "$1" in
    ''|*[!0-9]*) fail "port must be a non-negative integer: $1" ;;
  esac
  [ "$1" -le 65535 ] || fail "port must be below 65536: $1"
}

engine() {
  require_runtime
  FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" python3 "$ENGINE" "$@"
}

command_serve() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --port) shift; PORT=${1:-} ;;
      --host) shift; HOST_NAME=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  check_port "$PORT"
  set -- serve --home "$FM_HOME" --root "$FM_ROOT" --port "$PORT"
  [ -n "$HOST_NAME" ] && set -- "$@" --host "$HOST_NAME"
  engine "$@"
}

command_init_passcode() {
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  engine init-passcode --home "$FM_HOME"
}

command_revoke() {
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  engine revoke-sessions --home "$FM_HOME"
}

command_render_plist() {
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  engine render-plist --home "$FM_HOME" --root "$FM_ROOT"
}

command_mailbox() {
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  engine mailbox-listener
}

command_funnel() {
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  engine check-funnel
}

case "${1:-}" in
  serve) shift; command_serve "$@" ;;
  init-passcode) shift; command_init_passcode "$@" ;;
  revoke-sessions) shift; command_revoke "$@" ;;
  render-plist) shift; command_render_plist "$@" ;;
  mailbox-listener) shift; command_mailbox "$@" ;;
  check-funnel) shift; command_funnel "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
