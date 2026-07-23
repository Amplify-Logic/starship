#!/usr/bin/env bash
# fm-browse-session.sh - isolated per-task chrome-devtools-axi browsing sessions.
#
# HARD SAFETY RULE: this helper must NEVER attach to, auto-connect to, or reuse
# the captain's own Chrome instance or default profile.
# Isolation is separate profile directories under state/browse/<task-id>/profile,
# not shared identity or cache-coherency schemes (see docs/worker-browsing.md).
#
# chrome-devtools-axi owns browsing mechanics; this script owns naming,
# isolation, and cleanup only.
# Named sessions use CHROME_DEVTOOLS_AXI_SESSION=<task-id>.
# Profiles use CHROME_DEVTOOLS_AXI_USER_DATA_DIR=$STATE/browse/<task-id>/profile.
# Ambient CHROME_DEVTOOLS_AXI_AUTO_CONNECT and CHROME_DEVTOOLS_AXI_BROWSER_URL are
# always stripped before every axi invocation so an existing browser cannot be reached.
#
# Usage:
#   fm-browse-session.sh start <task-id>
#   fm-browse-session.sh stop <task-id> [--purge]
#   fm-browse-session.sh list
#   fm-browse-session.sh -h|--help
#
# Environment:
#   FM_HOME / FM_STATE_OVERRIDE - home and state roots (same as other bin scripts)
#   FM_BROWSE_AXI - override path to the chrome-devtools-axi binary (tests)
#
# Exit:
#   0 on success
#   1 on usage or run failure
#   2 on invalid task id
#   127 when chrome-devtools-axi is absent
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  cat <<'EOF' >&2
usage: fm-browse-session.sh start <task-id>
       fm-browse-session.sh stop <task-id> [--purge]
       fm-browse-session.sh list
       fm-browse-session.sh -h|--help

Isolated per-task chrome-devtools-axi sessions with per-task profile dirs under
state/browse/<task-id>/profile. Never attaches to the captain's Chrome.
See docs/worker-browsing.md.
EOF
}

fail() {
  printf 'fm-browse-session: %s\n' "$*" >&2
  exit 1
}

refuse_missing_axi() {
  cat <<'EOF' >&2
fm-browse-session: chrome-devtools-axi not found on PATH.
Install chrome-devtools-axi, then retry.
See docs/worker-browsing.md.
EOF
  exit 127
}

browse_root_for() {
  printf '%s\n' "$STATE/browse/$1"
}

profile_dir_for() {
  printf '%s\n' "$(browse_root_for "$1")/profile"
}

live_marker_for() {
  printf '%s\n' "$(browse_root_for "$1")/session.live"
}

axi_bin() {
  if [ -n "${FM_BROWSE_AXI:-}" ]; then
    printf '%s\n' "$FM_BROWSE_AXI"
    return 0
  fi
  command -v chrome-devtools-axi
}

require_task_id() {
  local id=${1-}
  if ! fm_task_id_path_safe "$id"; then
    printf 'fm-browse-session: invalid task id: %s\n' "${id:-<empty>}" >&2
    exit 2
  fi
  # chrome-devtools-axi rejects names made only of dots (would collapse onto default).
  if [[ "$id" =~ ^\.+$ ]]; then
    printf 'fm-browse-session: invalid task id (dots-only): %s\n' "$id" >&2
    exit 2
  fi
  if [ "${#id}" -gt 64 ]; then
    printf 'fm-browse-session: task id exceeds 64-char session name limit: %s\n' "$id" >&2
    exit 2
  fi
}

# Run chrome-devtools-axi with isolation env and captain-Chrome attach knobs stripped.
# HARD SAFETY: never pass AUTO_CONNECT or BROWSER_URL through.
run_axi_isolated() {
  local id=$1
  shift
  local axi profile
  axi=$(axi_bin) || refuse_missing_axi
  profile=$(profile_dir_for "$id")
  mkdir -p "$profile" || fail "could not create profile dir $profile"
  # Explicitly defeat ambient attach-to-existing-browser knobs.
  env -u CHROME_DEVTOOLS_AXI_AUTO_CONNECT \
      -u CHROME_DEVTOOLS_AXI_BROWSER_URL \
      CHROME_DEVTOOLS_AXI_SESSION="$id" \
      CHROME_DEVTOOLS_AXI_USER_DATA_DIR="$profile" \
      "$axi" "$@"
}

cmd_start() {
  local id=$1
  local marker root
  require_task_id "$id"
  root=$(browse_root_for "$id")
  marker=$(live_marker_for "$id")
  mkdir -p "$root" || fail "could not create browse root $root"
  if ! run_axi_isolated "$id" start; then
    fail "chrome-devtools-axi start failed for session $id"
  fi
  {
    printf 'task_id=%s\n' "$id"
    printf 'session=%s\n' "$id"
    printf 'profile=%s\n' "$(profile_dir_for "$id")"
    printf 'started_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$marker"
  printf 'fm-browse-session: started session=%s profile=%s\n' \
    "$id" "$(profile_dir_for "$id")"
}

cmd_stop() {
  local id=$1
  local purge=${2:-}
  local marker root
  require_task_id "$id"
  if [ -n "$purge" ] && [ "$purge" != "--purge" ]; then
    fail "unknown stop flag: $purge (expected --purge)"
  fi
  root=$(browse_root_for "$id")
  marker=$(live_marker_for "$id")
  # Best-effort session close: axi may already be down.
  if axi_bin >/dev/null 2>&1; then
    run_axi_isolated "$id" stop >/dev/null 2>&1 || true
  fi
  rm -f "$marker"
  if [ "$purge" = "--purge" ]; then
    rm -rf "$root"
    printf 'fm-browse-session: stopped and purged session=%s\n' "$id"
  else
    printf 'fm-browse-session: stopped session=%s (profile retained)\n' "$id"
  fi
}

cmd_list() {
  local root marker id profile
  root="$STATE/browse"
  if [ ! -d "$root" ]; then
    return 0
  fi
  # One line per live marker: task_id=<id> session=<id> profile=<path>
  shopt -s nullglob
  for marker in "$root"/*/session.live; do
    id=$(basename "$(dirname "$marker")")
    profile=$(profile_dir_for "$id")
    printf 'task_id=%s session=%s profile=%s\n' "$id" "$id" "$profile"
  done
  shopt -u nullglob
}

main() {
  local cmd=${1:-}
  case "$cmd" in
    ''|-h|--help)
      usage
      exit 0
      ;;
    start)
      [ "$#" -eq 2 ] || fail "start requires <task-id>"
      cmd_start "$2"
      ;;
    stop)
      [ "$#" -ge 2 ] || fail "stop requires <task-id>"
      cmd_stop "$2" "${3:-}"
      ;;
    list)
      [ "$#" -eq 1 ] || fail "list takes no arguments"
      cmd_list
      ;;
    *)
      fail "unknown command: $cmd"
      ;;
  esac
}

main "$@"
