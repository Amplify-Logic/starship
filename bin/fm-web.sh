#!/usr/bin/env bash
# fm-web.sh - the primary first mate's conversation in a calm localhost page.
#
# Runs bin/fm-web.py, a Python 3 standard-library server bound to the literal
# 127.0.0.1 constant; there is no flag or environment variable that widens
# it, and nothing here publishes it on a tailnet. The page shows the primary
# Claude session's conversation, a message box that sends only through
# bin/fm-desk-voice.sh send, and the bridge view's fleet glance
# (docs/web.md).
#
# Usage:
#   fm-web.sh start [--port <n>]   start in the background, print the URL
#   fm-web.sh stop                 stop the background server
#   fm-web.sh status               print running/stopped with the port
#   fm-web.sh url                  print the sign-in URL (carries the token)
#   fm-web.sh serve [--port <n>]   run in the foreground
#   fm-web.sh --help
#
# The URL carries this home's token from state/web/token (owner-only). The
# first visit swaps it for a cookie. Runtime files (pid, port, log) live in
# state/web/.
#
# Environment:
#   FM_HOME       private Firstmate home; defaults to this repository root
#   FM_WEB_PORT   loopback port; defaults to 8767
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
ENGINE="$SCRIPT_DIR/fm-web.py"
PORT="${FM_WEB_PORT:-8767}"
WEB_DIR="$FM_HOME/state/web"
PID_FILE="$WEB_DIR/web.pid"
PORT_FILE="$WEB_DIR/web.port"
LOG_FILE="$WEB_DIR/web.log"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-web: %s\n' "$*" >&2
  exit 1
}

require_runtime() {
  command -v python3 >/dev/null 2>&1 || fail "python3 is required"
  [ -f "$ENGINE" ] || fail "server is missing: $ENGINE"
}

parse_port() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --port)
        [ "$#" -ge 2 ] || fail "--port needs a number"
        PORT=$2
        shift 2
        ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  case "$PORT" in
    ''|*[!0-9]*) fail "port must be a non-negative integer: $PORT" ;;
  esac
  [ "$PORT" -le 65535 ] || fail "port must be below 65536: $PORT"
}

ensure_web_dir() {
  mkdir -p "$WEB_DIR" || fail "cannot create $WEB_DIR"
  chmod 700 "$WEB_DIR" 2>/dev/null || true
}

# The recorded pid, only while it is still this home's fm-web.py server.
running_pid() {
  local pid args
  [ -f "$PID_FILE" ] || return 1
  pid=$(head -n 1 "$PID_FILE" 2>/dev/null) || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null) || return 1
  case "$args" in
    *fm-web.py\ serve*"--home $FM_HOME "*) printf '%s\n' "$pid" ;;
    *) return 1 ;;
  esac
}

engine() {
  require_runtime
  FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" python3 "$ENGINE" "$@"
}

print_url() {
  local port token
  port=$(cat "$PORT_FILE" 2>/dev/null || true)
  case "$port" in ''|*[!0-9]*) fail "not running; start it with fm-web.sh start" ;; esac
  token=$(engine token --home "$FM_HOME")
  printf 'http://127.0.0.1:%s/?token=%s\n' "$port" "$token"
}

command_start() {
  local pid n=0 line
  parse_port "$@"
  require_runtime
  if pid=$(running_pid); then
    print_url
    return 0
  fi
  ensure_web_dir
  : > "$LOG_FILE.start"
  FM_ROOT_OVERRIDE="$FM_ROOT" nohup python3 "$ENGINE" serve \
    --home "$FM_HOME" --root "$FM_ROOT" --port "$PORT" \
    >"$LOG_FILE.start" 2>&1 </dev/null &
  pid=$!
  printf '%s\n' "$pid" > "$PID_FILE"
  while [ "$n" -lt 50 ]; do
    line=$(grep -E '^listening on 127\.0\.0\.1:[0-9]+$' "$LOG_FILE.start" 2>/dev/null || true)
    if [ -n "$line" ]; then
      printf '%s\n' "${line##*:}" > "$PORT_FILE"
      print_url
      return 0
    fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    n=$((n + 1))
  done
  rm -f "$PID_FILE"
  fail "server did not start: $(tail -n 3 "$LOG_FILE.start" 2>/dev/null)"
}

command_stop() {
  local pid
  if pid=$(running_pid); then
    kill "$pid" 2>/dev/null || true
    printf 'stopped\n'
  else
    printf 'not running\n'
  fi
  rm -f "$PID_FILE" "$PORT_FILE"
}

command_status() {
  local pid
  if pid=$(running_pid); then
    printf 'running on 127.0.0.1:%s (pid %s)\n' "$(cat "$PORT_FILE" 2>/dev/null)" "$pid"
  else
    printf 'stopped\n'
    return 3
  fi
}

command_serve() {
  parse_port "$@"
  ensure_web_dir
  engine serve --home "$FM_HOME" --root "$FM_ROOT" --port "$PORT"
}

case "${1:-}" in
  start) shift; command_start "$@" ;;
  stop) shift; command_stop ;;
  status) shift; command_status ;;
  url) shift; running_pid >/dev/null || fail "not running; start it with fm-web.sh start"; print_url ;;
  serve) shift; command_serve "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
