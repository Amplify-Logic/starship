#!/usr/bin/env bash
# Claude primary watcher-continuity PreToolUse gate.
#
# This hook is deliberately narrow. It denies only an executed bin/fm-*.sh fleet
# command other than bin/fm-session-start.sh, bin/fm-wake-drain.sh,
# bin/fm-watch-arm.sh, the independently fail-closed bin/fm-teardown.sh, or the
# exact literal "bin/fm-supervision-sentinel.sh enable" that the session-start
# disarm banner names, and only when the active primary home has task metadata
# in flight but no identity-matched live watcher with a fresh beacon holds the
# home lock. Ordinary shell commands, recovery commands, healthy supervision,
# fleet-idle homes, and child worktrees are always allowed.
#
# The recovery set is keyed on the command word actually executed, so a direct
# bin/fm-bootstrap.sh stays denied while the bin/fm-bootstrap.sh that
# bin/fm-session-start.sh runs inside its own process is allowed. That is not a
# hole: session start takes the per-home session lock first, and holding that
# lock is exactly what gates bootstrap's five mutating sweeps (see the ORDERING
# header in fm-session-start.sh). The first-run scoping of that boundary is
# owned by the "Session-start first-run scoping" section of
# docs/watcher-continuity.md.
#
# The deny guidance keeps the two entry points distinct. bin/fm-wake-drain.sh is
# the action that is always safe mid-session; the once-per-session
# bin/fm-session-start.sh (AGENTS.md section 3) is both named and allowed only
# while no live session holds the home session lock. The session-lock relation
# (fm_session_lock_relation, shared with bin/fm-sessionstart-nudge.sh through
# fm_session_lock_in_ancestry) is passed to the classifier: a live holder in
# this hook's own ancestry means session start already ran in this session, a
# live foreign holder means another session owns the home, and either relation
# turns a session-start attempt into an ordinary gated fleet command denied
# with the midsession-session-start guidance below. Only the lock-free relation
# keeps session start a recovery command, exactly the genuine first run.
#
# The turn-end guard remains the final blocking backstop. This gate
# closes the long-turn gap before another fleet mutation, but does not replace or
# weaken the Stop hook.
#
# Input is Claude PreToolUse JSON on stdin. Tests may pass --command directly.
# Malformed transport, missing jq/Node, a missing classifier, or classifier
# failure all fail open. A deny writes Claude's hook decision to stderr only and
# exits 2.
set -u

COMMAND=
COMMAND_SET=0

usage() {
  cat <<'EOF'
Usage: fm-continuity-pretool-check.sh [--command <shell-command>]

Reads Claude PreToolUse JSON from stdin unless --command is supplied.
Exits 0 to allow. Exits 2 with a Claude deny object on stderr only when an
unhealthy primary tries to execute a non-recovery firstmate fleet script.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      COMMAND=$2
      COMMAND_SET=1
      shift 2
      ;;
    --command=*)
      COMMAND=${1#--command=}
      COMMAND_SET=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$COMMAND_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  COMMAND=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
fi
[ -n "$COMMAND" ] || exit 0

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)}
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
WATCH="$SCRIPT_DIR/fm-watch.sh"
POLICY="$SCRIPT_DIR/fm-continuity-command-policy.mjs"

# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
fm_supervision_status "$STATE" "${FM_GUARD_GRACE:-300}"
[ "$FM_SUP_IN_FLIGHT" -gt 0 ] || exit 0
if fm_watcher_healthy "$STATE" "$WATCH" "${FM_GUARD_GRACE:-300}" "$FM_HOME"; then
  exit 0
fi

# This hook can be the first surviving process to observe the outage, so it
# records the durable evidence the host sentinel later alerts on. Marker-only:
# a PreToolUse gate must decide immediately and never wait on external-channel
# delivery, which the scheduled launchd check owns.
SENTINEL="$SCRIPT_DIR/fm-supervision-sentinel.sh"
if [ -x "$SENTINEL" ]; then
  "$SENTINEL" note-outage >/dev/null 2>&1 || true
fi

command -v node >/dev/null 2>&1 || exit 0
[ -f "$POLICY" ] || exit 0
LOCK_RELATION=$(fm_session_lock_relation "$STATE") || LOCK_RELATION=free
CLASSIFICATION=$(node "$POLICY" --command "$COMMAND" --root "$FM_ROOT" --session-lock "$LOCK_RELATION" 2>/dev/null) || exit 0
case "$CLASSIFICATION" in
  deny*) ;;
  *) exit 0 ;;
esac

TAB=$(printf '\t')
REST=${CLASSIFICATION#*"$TAB"}
[ -n "$REST" ] && [ "$REST" != "$CLASSIFICATION" ] || exit 0
BLOCKED_SCRIPT=${REST%%"$TAB"*}
REASON_CODE=${REST#*"$TAB"}
[ "$REASON_CODE" != "$REST" ] || REASON_CODE=""
case "$REASON_CODE" in
  unsafe-teardown)
    REASON="[watcher-continuity] $FM_SUP_OUTAGE_SUMMARY No live watcher holds this home lock. During recovery only the ordinary literal bin/fm-teardown.sh is allowed, so drop --force and any shell-expanded arguments and retry the literal invocation (blocked: $BLOCKED_SCRIPT)"
    ;;
  unsafe-sentinel)
    REASON="[watcher-continuity] $FM_SUP_OUTAGE_SUMMARY During recovery only the literal bin/fm-supervision-sentinel.sh enable is allowed; arm, disarm, check, and every other host-sentinel invocation stays blocked until supervision is healthy (blocked: $BLOCKED_SCRIPT)"
    ;;
  midsession-session-start)
    if [ "$LOCK_RELATION" = ancestry ]; then
      HOLDER_CLAUSE="This session's own ancestry already holds the home session lock, so the once-per-session bin/fm-session-start.sh has already run here and a mid-session re-run is not a recovery action."
    else
      HOLDER_CLAUSE="Another live session holds the home session lock, so the once-per-session bin/fm-session-start.sh belongs to that session and is not a recovery action here."
    fi
    REASON="[watcher-continuity] $FM_SUP_OUTAGE_SUMMARY No live watcher holds this home lock. $HOLDER_CLAUSE Drain wakes with bin/fm-wake-drain.sh, the safe mid-session action; use fail-closed bin/fm-teardown.sh for completed tasks when needed, then re-arm with bin/fm-watch-arm.sh as a tracked Claude background task before running other fleet commands (blocked: $BLOCKED_SCRIPT)"
    ;;
  *)
    SESSION_START_CLAUSE=" run the once-per-session bin/fm-session-start.sh instead only if you have not already run it earlier this session;"
    [ "$LOCK_RELATION" = free ] || SESSION_START_CLAUSE=""
    REASON="[watcher-continuity] $FM_SUP_OUTAGE_SUMMARY No live watcher holds this home lock. Drain wakes with bin/fm-wake-drain.sh, the safe mid-session action;$SESSION_START_CLAUSE use fail-closed bin/fm-teardown.sh for completed tasks when needed, then re-arm with bin/fm-watch-arm.sh as a tracked Claude background task before running other fleet commands (blocked: $BLOCKED_SCRIPT)"
    ;;
esac
ESCAPED=$(printf '%s' "$REASON" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
exit 2
