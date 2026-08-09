#!/usr/bin/env bash
# fm-read.sh - render a Markdown report as a private Lavish reading page.
#
# Accepts either a Markdown path or a bare task id, which resolves to
# $FM_HOME/data/<id>/report.md. The self-contained HTML page has a stable source-
# derived name under $FM_HOME/.lavish/, named and titled for the task id when the
# source is a task report, and is refreshed on every invocation.
# Lavish is bound to IPv4 loopback and no feedback poll is started.
#
# Usage:
#   fm-read.sh [--no-open] <markdown-path-or-task-id>
#
# Environment:
#   FM_HOME          private Firstmate home; defaults to this repository root
#   FM_LAVISH_BIN    Lavish executable override for tests; defaults to lavish-axi
#   FM_READ_PORT     dedicated IPv4 loopback port; defaults to 4389
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
[ "$#" -eq 1 ] || { usage >&2; exit 2; }
INPUT=$1

command -v node >/dev/null 2>&1 || fail "node is required to render Markdown; install Node.js and try again"

SOURCE=
if [ -f "$INPUT" ]; then
  SOURCE=$INPUT
elif printf '%s\n' "$INPUT" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
  REPORT="$FM_HOME/data/$INPUT/report.md"
  [ -f "$REPORT" ] || fail "no Markdown source found; looked for '$INPUT' and '$REPORT'"
  SOURCE=$REPORT
else
  fail "Markdown file does not exist: $INPUT"
fi

case "${SOURCE##*.}" in
  md|MD|markdown|MARKDOWN) ;;
  *) fail "refusing non-Markdown file: $SOURCE (expected .md or .markdown)" ;;
esac

if ! OUTPUT=$(node "$SCRIPT_DIR/fm-read.mjs" "$SOURCE" "$FM_HOME/.lavish"); then
  fail "could not render $SOURCE into $FM_HOME/.lavish"
fi
[ -n "$OUTPUT" ] || fail "renderer did not report an output page for $SOURCE"

if [ "$NO_OPEN" -eq 1 ]; then
  printf '%s\n' "$OUTPUT"
  exit 0
fi

command -v "$LAVISH_BIN" >/dev/null 2>&1 || fail "lavish-axi is required to open the page; install it with: npm install -g lavish-axi && lavish-axi setup hooks"
LAVISH_AXI_HOST=127.0.0.1 \
LAVISH_AXI_LINK_HOST=127.0.0.1 \
LAVISH_AXI_PORT="$LAVISH_PORT" \
  "$LAVISH_BIN" "$OUTPUT"
