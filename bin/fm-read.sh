#!/usr/bin/env bash
# fm-read.sh - render Markdown reports as a private Lavish reading page.
#
# Each source is a Markdown path or a bare task id, which resolves to
# $FM_HOME/data/<id>/report.md. Every source renders, in order, into one
# self-contained HTML page with a stable source-derived name under
# $FM_HOME/.lavish/, named and titled for the first source (for the task id when
# it is a task report), and refreshed on every invocation.
# A task id whose $FM_HOME/data/<id>/page.html exists stands for that page, the
# worker's own view of the work: the first such page opens as it is and nothing
# is rendered.
# Lavish is bound to IPv4 loopback and no feedback poll is started; without
# lavish-axi the page opens in the browser instead.
#
# Usage:
#   fm-read.sh [--no-open] <markdown-path-or-task-id>...
#
# --no-open prints the page's path instead of opening it.
#
# Environment:
#   FM_HOME          private Firstmate home; defaults to this repository root
#   FM_LAVISH_BIN    Lavish executable override for tests; defaults to lavish-axi
#   FM_READ_PORT     dedicated IPv4 loopback port; defaults to 4389
#   FM_READ_BROWSER  the browser opener used without lavish-axi; defaults to
#                    open on macOS and xdg-open elsewhere
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
LAVISH_BIN="${FM_LAVISH_BIN:-lavish-axi}"
LAVISH_PORT="${FM_READ_PORT:-4389}"
NO_OPEN=0

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-read: %s\n' "$*" >&2
  exit 1
}

case "$LAVISH_PORT" in ''|*[!0-9]*|0) fail "FM_READ_PORT must be a positive integer" ;; esac

if [ "${1:-}" = "--no-open" ]; then
  NO_OPEN=1
  shift
fi
[ "$#" -ge 1 ] || { usage >&2; exit 2; }

OUTPUT=
SOURCES=()
for INPUT in "$@"; do
  if [ -f "$INPUT" ]; then
    SOURCE=$INPUT
  elif printf '%s\n' "$INPUT" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
    if [ -f "$FM_HOME/data/$INPUT/page.html" ]; then
      OUTPUT="$FM_HOME/data/$INPUT/page.html"
      break
    fi
    SOURCE="$FM_HOME/data/$INPUT/report.md"
    [ -f "$SOURCE" ] || fail "no Markdown source found; looked for '$INPUT' and '$SOURCE'"
  else
    fail "Markdown file does not exist: $INPUT"
  fi
  case "${SOURCE##*.}" in
    md|MD|markdown|MARKDOWN) ;;
    *) fail "refusing non-Markdown file: $SOURCE (expected .md or .markdown)" ;;
  esac
  SOURCES+=("$SOURCE")
done

if [ -z "$OUTPUT" ]; then
  command -v node >/dev/null 2>&1 || fail "node is required to render Markdown; install Node.js and try again"
  if ! OUTPUT=$(node "$SCRIPT_DIR/fm-read.mjs" "${SOURCES[@]}" "$FM_HOME/.lavish"); then
    fail "could not render ${SOURCES[*]} into $FM_HOME/.lavish"
  fi
  [ -n "$OUTPUT" ] || fail "renderer did not report an output page for ${SOURCES[*]}"
fi

if [ "$NO_OPEN" -eq 1 ]; then
  printf '%s\n' "$OUTPUT"
  exit 0
fi

if command -v "$LAVISH_BIN" >/dev/null 2>&1; then
  LAVISH_AXI_HOST=127.0.0.1 \
  LAVISH_AXI_LINK_HOST=127.0.0.1 \
  LAVISH_AXI_PORT="$LAVISH_PORT" \
    exec "$LAVISH_BIN" "$OUTPUT"
fi
BROWSER_BIN=${FM_READ_BROWSER:-}
if [ -z "$BROWSER_BIN" ]; then
  if [ "$(uname)" = Darwin ]; then BROWSER_BIN=open; else BROWSER_BIN=xdg-open; fi
fi
command -v "$BROWSER_BIN" >/dev/null 2>&1 || fail "neither lavish-axi nor a browser opener ($BROWSER_BIN) was found to open $OUTPUT; install lavish-axi with: npm install -g lavish-axi && lavish-axi setup hooks"
exec "$BROWSER_BIN" "$OUTPUT"
