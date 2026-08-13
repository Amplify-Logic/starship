#!/usr/bin/env bash
# fm-overlay.sh - put a Markdown view in front of the captain: as an overlay pane
# inside his terminal when that is possible, and as a plain link when it is not.
#
# Nothing calls this by default. It is the wiring firstmate reaches for when it
# wants a report on his screen at the moment it matters, instead of telling him
# where the file lives.
#
# In-terminal delivery uses Herdr's own plugin pane, which is a first-class
# programmatic overlay:
#   herdr plugin pane open --plugin ID --entrypoint ID --placement overlay
# The viewer itself is third-party code and is never installed by this script.
# When no viewer is installed, when Herdr is not the runtime, or when the pane
# refuses to open, this prints where to read the same content instead and exits
# 0: a missing overlay must never fail the caller that only wanted to show
# something.
#
# The plugin and entrypoint are discovered from `herdr plugin list --json` so no
# unverified plugin identity is hardcoded here; pass --plugin/--entrypoint to
# override once the installed viewer's own identities are known.
#
# Usage:
#   fm-overlay.sh <markdown-path-or-task-id> [--plugin <id>] [--entrypoint <id>]
#                                            [--placement <overlay|popup|split|tab|zoomed>]
#                                            [--no-focus] [--link-only]
#
# Environment:
#   FM_HOME              private Firstmate home; defaults to this repository root
#   FM_HERDR_BIN         Herdr executable override for tests; defaults to herdr
#   FM_CHART_ROOM_PORT   loopback port used to build the fallback link; defaults to 4390
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
HERDR_BIN="${FM_HERDR_BIN:-herdr}"
PLACEMENT=overlay
PLUGIN=
ENTRYPOINT=
FOCUS=--focus
LINK_ONLY=0
TASK_ID=

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-overlay: %s\n' "$*" >&2
  exit 1
}

# Where the captain can read the same thing without the overlay. A task report
# has a live chart-room view; anything else is named by its path.
fallback_line() {
  if [ -n "$TASK_ID" ]; then
    printf '%s\n' "$("$SCRIPT_DIR/fm-chart-room.sh" url "/report/$TASK_ID")"
  else
    printf '%s\n' "$SOURCE"
  fi
}

degrade() {  # <reason>
  printf 'fm-overlay: no in-terminal overlay (%s); read it here instead:\n' "$1" >&2
  fallback_line
  exit 0
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
case "$1" in
  -h|--help) usage; exit 0 ;;
  --*) usage >&2; exit 2 ;;
esac
INPUT=$1
shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --plugin) shift; PLUGIN=${1:-} ;;
    --entrypoint) shift; ENTRYPOINT=${1:-} ;;
    --placement) shift; PLACEMENT=${1:-} ;;
    --no-focus) FOCUS=--no-focus ;;
    --link-only) LINK_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

case "$PLACEMENT" in
  overlay|popup|split|tab|zoomed) ;;
  *) fail "placement must be one of overlay, popup, split, tab, zoomed: $PLACEMENT" ;;
esac

FM_HOME_DIR=$(cd "$FM_HOME" 2>/dev/null && pwd) || FM_HOME_DIR=$FM_HOME

SOURCE=
if [ -f "$INPUT" ]; then
  SOURCE=$INPUT
  # Only data/<task-id>/report.md has a chart-room /report/ view. Any other
  # Markdown under the records - a goal charter, a note beside a report - is
  # named by its own path, because a derived link there would 404.
  if [ "$(basename "$INPUT")" = report.md ]; then
    PARENT=$(cd "$(dirname "$INPUT")" && pwd)
    case "$PARENT" in
      "$FM_HOME_DIR"/data/*/*) ;;
      "$FM_HOME_DIR"/data/*)
        CANDIDATE=$(basename "$PARENT")
        if printf '%s\n' "$CANDIDATE" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
          TASK_ID=$CANDIDATE
        fi
        ;;
    esac
  fi
elif printf '%s\n' "$INPUT" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
  REPORT="$FM_HOME/data/$INPUT/report.md"
  [ -f "$REPORT" ] || fail "no Markdown source found; looked for '$INPUT' and '$REPORT'"
  SOURCE=$REPORT
  TASK_ID=$INPUT
else
  fail "Markdown file does not exist: $INPUT"
fi

case "${SOURCE##*.}" in
  md|MD|markdown|MARKDOWN) ;;
  *) fail "refusing non-Markdown file: $SOURCE (expected .md or .markdown)" ;;
esac

SOURCE=$(cd "$(dirname "$SOURCE")" && pwd)/$(basename "$SOURCE")
[ "$LINK_ONLY" -eq 0 ] || { fallback_line; exit 0; }

# shellcheck source=bin/fm-backend.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"
BACKEND=$(fm_backend_name 2>/dev/null || printf 'tmux')
[ "$BACKEND" = herdr ] || degrade "the terminal here is $BACKEND, not herdr"
command -v "$HERDR_BIN" >/dev/null 2>&1 || degrade "herdr is not installed"

# Ask the running Herdr which viewer is actually installed rather than assuming
# an identity that cannot be verified until the captain installs one.
if [ -z "$PLUGIN" ] || [ -z "$ENTRYPOINT" ]; then
  command -v node >/dev/null 2>&1 || degrade "node is needed to read the installed plugin list"
  LISTING=$("$HERDR_BIN" plugin list --json 2>/dev/null) || degrade "herdr could not list its plugins"
  # The single quotes are load-bearing: the ${...} inside are JavaScript template
  # placeholders that the shell must not touch.
  # shellcheck disable=SC2016
  DISCOVERED=$(printf '%s' "$LISTING" | node -e '
    let raw = "";
    process.stdin.on("data", (chunk) => { raw += chunk; });
    process.stdin.on("end", () => {
      let plugins = [];
      try {
        const parsed = JSON.parse(raw);
        plugins = parsed?.result?.plugins || parsed?.plugins || [];
      } catch { process.exit(0); }
      const wanted = plugins.filter((plugin) => plugin?.enabled !== false)
        .filter((plugin) => /view|read|file|markdown/i.test(`${plugin?.id || ""} ${plugin?.name || ""}`));
      const chosen = wanted[0];
      if (!chosen?.id) process.exit(0);
      const panes = chosen.panes || chosen.entrypoints || chosen.manifest?.panes || [];
      const entry = Array.isArray(panes)
        ? (typeof panes[0] === "string" ? panes[0] : panes[0]?.id || panes[0]?.entrypoint || "")
        : "";
      process.stdout.write(`${chosen.id}\t${entry}\n`);
    });
  ') || DISCOVERED=
  [ -n "$DISCOVERED" ] || degrade "no file-viewer plugin is installed in this terminal"
  [ -n "$PLUGIN" ] || PLUGIN=${DISCOVERED%%	*}
  [ -n "$ENTRYPOINT" ] || ENTRYPOINT=${DISCOVERED##*	}
fi
[ -n "$PLUGIN" ] || degrade "no file-viewer plugin is installed in this terminal"
[ -n "$ENTRYPOINT" ] || degrade "the installed viewer declares no pane to open; pass --entrypoint"

# The verified flags carry the location; how a given viewer selects the file
# within it is that plugin's own contract, so the exact path is also exported.
if "$HERDR_BIN" plugin pane open \
  --plugin "$PLUGIN" \
  --entrypoint "$ENTRYPOINT" \
  --placement "$PLACEMENT" \
  --cwd "$(dirname "$SOURCE")" \
  --env "FM_OVERLAY_FILE=$SOURCE" \
  "$FOCUS" >/dev/null 2>&1; then
  printf 'fm-overlay: opened %s in the %s pane\n' "$(basename "$SOURCE")" "$PLACEMENT"
  exit 0
fi
degrade "the viewer pane did not open"
