#!/usr/bin/env bash
# fm-outward-style.sh - show or switch this home's worker outward style, on the
# captain's word: the /outward-fine-print, /outward-broad and /outward-no-block
# skills run it.
#
# Usage:
#   fm-outward-style.sh [show]
#       Print one line naming the style in force, such as "Outward: fine print",
#       "Outward: broad switches (send email, control browser)" or
#       "Outward: no block", for any surface that shows it.
#   fm-outward-style.sh fine-print
#   fm-outward-style.sh no-block
#   fm-outward-style.sh broad ['<switch>[, <switch>...]']
#       Switch the style and print one sentence saying which style is now on
#       and what it means. The broad switches are exactly send email, reply to
#       email, respond to invites, change calendar, control browser and use
#       zapier, comma-separated; name all six to turn every switch on.
#       Broad with switches turns on exactly those; without, it keeps the ones
#       chosen before, or when none were turns no switch on and its sentence
#       asks which to allow. A switch it does not understand changes nothing.
#
# The style lives in this home's config/outward-permissions
# (FM_CONFIG_OVERRIDE, else $FM_HOME/config), which the worker outward check
# reads on every action, so a switch holds from every worker's next action
# without a relaunch. Switching rewrites only the style line, and the broad
# lines when switches are named; narrow standing permissions and comments are
# kept, so every switch is undone by running another. docs/configuration.md
# "Worker outward actions" owns what each style allows, and
# bin/fm-outward-check.py's header owns the file mechanics.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

case "${1:-}" in
  -h | --help)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit 0
    ;;
esac
command -v python3 >/dev/null 2>&1 || {
  echo "error: python3 is required to read or change the outward style" >&2
  exit 1
}
exec python3 "$SCRIPT_DIR/fm-outward-check.py" style --config "$CONFIG" "$@"
