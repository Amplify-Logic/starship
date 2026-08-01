#!/usr/bin/env bash
# fm-decision-surface.sh - private Lavish surface for durable captain decisions.
#
# Reads every active kind-captain hold through tasks-axi, renders one self-contained
# HTML page under .lavish/, and launches Lavish only on IPv4 loopback. Each answer
# carries the exact chosen option in a versioned marker. `poll` validates those
# markers against the generated page and refuses ambiguous, stale, forged, or
# lifecycle-unroutable marks instead of guessing.
#
# `route` is dry-run by default. `route --apply` creates one deterministic dependent
# work item blocked by the hold, writes the exact chosen option to a private decision
# file, and delegates ordering and closure to fm-decision-hold.sh resolve. It never
# calls tasks-axi unhold/done for a decision itself and never invents a second
# completion policy.
#
# Parentheses in existing hold reasons are read and rendered verbatim. This command
# never replays a hold reason through `fm-decision-hold.sh hold`, whose help forbids
# parentheses, so such source text cannot fail during answer routing.
#
# Usage:
#   fm-decision-surface.sh generate [--output <.lavish/page.html>]
#   fm-decision-surface.sh open [--page <.lavish/page.html>]
#   fm-decision-surface.sh poll [--page <.lavish/page.html>] [--answers <.lavish/answers.json>]
#   fm-decision-surface.sh show <hold-id> [--page <.lavish/page.html>]
#   fm-decision-surface.sh route [--page <.lavish/page.html>] [--answers <.lavish/answers.json>] [--apply]
#
# Environment:
#   FM_HOME          authoritative backlog home; defaults to this repository root
#   FM_LAVISH_BIN    Lavish executable override for tests; defaults to lavish-axi
#   FM_DECISION_SURFACE_PORT dedicated loopback port; defaults to 4388
#
# `open` always overrides LAVISH_AXI_HOST and LAVISH_AXI_LINK_HOST to 127.0.0.1.
# There is deliberately no share/export command because decision text is private.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
ENGINE="$SCRIPT_DIR/fm-decision-surface.mjs"
LAVISH_BIN="${FM_LAVISH_BIN:-lavish-axi}"
LAVISH_PORT="${FM_DECISION_SURFACE_PORT:-4388}"
DEFAULT_PAGE="$FM_HOME/.lavish/captain-decisions.html"
DEFAULT_ANSWERS="$FM_HOME/.lavish/captain-decisions.answers.json"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-decision-surface: %s\n' "$*" >&2
  exit 1
}

case "$LAVISH_PORT" in ''|*[!0-9]*|0) fail "FM_DECISION_SURFACE_PORT must be a positive integer" ;; esac

absolute_path() {  # <path>
  node -e 'const path=require("node:path"); process.stdout.write(path.resolve(process.argv[1]))' "$1"
}

private_path() {  # <label> <path>
  local label=$1 resolved
  resolved=$(absolute_path "$2")
  case "$resolved" in
    */.lavish/*) printf '%s\n' "$resolved" ;;
    *) fail "$label must be inside a .lavish directory: $resolved" ;;
  esac
}

require_runtime() {
  command -v node >/dev/null 2>&1 || fail "node is required"
  command -v tasks-axi >/dev/null 2>&1 || fail "tasks-axi is required"
}

command_generate() {
  local output=$DEFAULT_PAGE
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --output) shift; output=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  require_runtime
  output=$(private_path output "$output")
  node "$ENGINE" generate --home "$FM_HOME" --output "$output"
}

command_open() {
  local page=$DEFAULT_PAGE
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --page) shift; page=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  page=$(private_path page "$page")
  [ -f "$page" ] || fail "page does not exist; run generate first: $page"
  command -v "$LAVISH_BIN" >/dev/null 2>&1 || fail "lavish-axi is required"
  LAVISH_AXI_HOST=127.0.0.1 LAVISH_AXI_LINK_HOST=127.0.0.1 LAVISH_AXI_PORT="$LAVISH_PORT" "$LAVISH_BIN" "$page"
}

command_poll() {
  local page=$DEFAULT_PAGE answers=$DEFAULT_ANSWERS raw
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --page) shift; page=${1:-} ;;
      --answers) shift; answers=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  page=$(private_path page "$page")
  answers=$(private_path answers "$answers")
  [ -f "$page" ] || fail "page does not exist; run generate first: $page"
  command -v "$LAVISH_BIN" >/dev/null 2>&1 || fail "lavish-axi is required"
  mkdir -p "$(dirname "$answers")"
  raw=$(mktemp "$(dirname "$answers")/.captain-decisions.poll.XXXXXX")
  trap 'rm -f "$raw"' EXIT HUP INT TERM
  LAVISH_AXI_HOST=127.0.0.1 LAVISH_AXI_LINK_HOST=127.0.0.1 LAVISH_AXI_PORT="$LAVISH_PORT" "$LAVISH_BIN" poll "$page" > "$raw"
  node "$ENGINE" read-poll --page "$page" --poll-file "$raw" --output "$answers"
  rm -f "$raw"
  trap - EXIT HUP INT TERM
}

command_show() {
  local id=${1:-} page=$DEFAULT_PAGE
  [ -n "$id" ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --page) shift; page=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  page=$(private_path page "$page")
  [ -f "$page" ] || fail "page does not exist; run generate first: $page"
  node "$ENGINE" show --page "$page" --id "$id"
}

command_route() {
  local page=$DEFAULT_PAGE answers=$DEFAULT_ANSWERS apply=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --page) shift; page=${1:-} ;;
      --answers) shift; answers=${1:-} ;;
      --apply) apply=1 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  require_runtime
  page=$(private_path page "$page")
  answers=$(private_path answers "$answers")
  [ -f "$page" ] || fail "page does not exist: $page"
  [ -f "$answers" ] || fail "answers file does not exist; run poll first: $answers"
  if [ "$apply" = 1 ]; then
    node "$ENGINE" route --home "$FM_HOME" --root "$FM_ROOT" --page "$page" --answers "$answers" --apply
  else
    node "$ENGINE" route --home "$FM_HOME" --root "$FM_ROOT" --page "$page" --answers "$answers"
  fi
}

case "${1:-}" in
  generate) shift; command_generate "$@" ;;
  open) shift; command_open "$@" ;;
  poll) shift; command_poll "$@" ;;
  show) shift; command_show "$@" ;;
  route) shift; command_route "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
