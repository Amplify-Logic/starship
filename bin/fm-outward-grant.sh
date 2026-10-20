#!/usr/bin/env bash
# fm-outward-grant.sh - give one running ship or scout task permission to act
# outward, on the captain's word, without relaunching it.
#
# Usage: fm-outward-grant.sh <task-id> '<permission>[; <permission>...]'
#
# The permission uses the words of docs/configuration.md "Worker outward
# actions", such as 'send email to a@example.com' or 'accept invites from
# @example.org'; bin/fm-outward-check.py parse checks and normalizes it, and a
# phrase it does not understand changes nothing. The task's existing
# permissions are kept and the new ones added, then the combined list is
# appended to state/<task-id>.meta as a new `outward=` line under the task's
# record lock. The worker's check reads the last such line on every call, so
# the permission holds from the next action, for this task only, and a
# relaunch keeps it. A secondmate record is refused: secondmates are not
# guarded. This never edits the task's brief; tell the worker with fm-send.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

case "${1:-}" in
  -h | --help)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit 0
    ;;
esac
[ "$#" -eq 2 ] || {
  echo "usage: fm-outward-grant.sh <task-id> '<permission>[; <permission>...]'" >&2
  exit 2
}

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

ID=$1
META="$STATE/$ID.meta"
META_LOCK=$(fm_meta_lock_path "$META") || {
  echo "error: invalid task id: $ID" >&2
  exit 2
}
command -v python3 >/dev/null 2>&1 || {
  echo "error: python3 is required to check the permission" >&2
  exit 1
}
ADDED=$(python3 "$SCRIPT_DIR/fm-outward-check.py" parse "$2") || exit 1
[ "$ADDED" != none ] || {
  echo "error: no permission given" >&2
  exit 1
}

META_LOCK_HELD=0
release() {
  [ "$META_LOCK_HELD" != 1 ] || fm_lock_release "$META_LOCK" || true
}
trap release EXIT
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
[ -f "$META" ] || {
  echo "error: no task record for $ID at $META" >&2
  exit 1
}
case "$(fm_meta_get "$META" kind)" in
  ship | scout) ;;
  *)
    echo "error: $ID is not a ship or scout task; only workers are guarded" >&2
    exit 1
    ;;
esac
CURRENT=$(fm_meta_get "$META" outward)
COMBINED=$(python3 "$SCRIPT_DIR/fm-outward-check.py" parse "${CURRENT:+$CURRENT; }$ADDED") || exit 1
printf 'outward=%s\n' "$COMBINED" >>"$META"
echo "granted: $ID may now $COMBINED"
