#!/usr/bin/env bash
# The one call a lifecycle step makes to tell the Mothership room how a task
# goes, and the one test that decides whether this home has a room link at all.
# bin/fm-procevent-mothership.sh "OUTCOMES IN THE ROOM" owns what each event
# sends and to which room.
#
#   fm_mothership_config_file
#       The Mothership link's config: $MOTHERSHIP_CONFIG, else
#       ~/.config/mothership/rooms.json.
#   fm_mothership_linked <state-dir>
#       Succeeds when this home keeps Mothership state or has a link config.
#   fm_mothership_report <home> <state-dir> <config-dir> <task-id> <event> [--pr <url>]
#       Runs `fm-procevent-mothership.sh report --detach` for a linked home and
#       returns at once; it never fails and prints nothing, so the step that
#       calls it is never held up or changed by the room. A home with no room
#       link costs one directory and one file test.

_FM_MOTHERSHIP_REPORT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fm_mothership_config_file() { printf '%s\n' "${MOTHERSHIP_CONFIG:-${HOME:-}/.config/mothership/rooms.json}"; }

fm_mothership_linked() {  # <state-dir>
  [ -d "$1/mothership" ] || [ -f "$(fm_mothership_config_file)" ]
}

fm_mothership_report() {  # <home> <state-dir> <config-dir> <task-id> <event> [--pr <url>]
  local home=$1 state=$2 config=$3
  shift 3
  fm_mothership_linked "$state" || return 0
  FM_HOME=$home FM_STATE_OVERRIDE=$state FM_CONFIG_OVERRIDE=$config \
    "$_FM_MOTHERSHIP_REPORT_LIB_DIR/fm-procevent-mothership.sh" report --detach "$@" >/dev/null 2>&1 || true
  return 0
}
