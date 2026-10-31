#!/usr/bin/env bash
# The PR text check (bin/fm-pr-text-guard.py) for a first mate or second mate
# Claude session.
#
# bin/fm-spawn.sh installs that check for every spawned Claude worker with the
# worker's home. A first mate or second mate session is not spawned that way,
# so the tracked .claude/settings.json runs this wrapper as a PreToolUse hook
# on Bash instead. It only scopes the check and finds the home; the check owns
# what counts as publishing, which repositories are refused and the answer.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-pr-text-pretool-check.sh
#
# SCOPE. It runs only in a genuine first mate or second mate home: the plain
# checkout of a primary home, or a home carrying a valid .fm-secondmate-home
# marker (bin/fm-primary-scope-lib.sh owns that test). A ship or scout worker,
# which already has its own copy, and any other checkout pass untouched. A
# payload Cursor delivered passes too, because the check answers only in
# Claude's shape (bin/fm-hook-host-lib.sh).
#
# HOME. The session's FM_HOME when it is set, else this checkout, whose
# config/ holds the word list.
#
# HARMLESS WITHOUT A LIST. With no word list or approvals file the check
# refuses only a live key or token shape. Without python3 the wrapper allows
# every command rather than refusing them all, as bin/fm-spawn.sh does for a
# worker. It always exits 0; a refusal is the deny object the check prints on
# stdout.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || exit 0

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_is_task_worker && exit 0
command -v git >/dev/null 2>&1 || exit 0
fm_primary_root_matches "$FM_ROOT" || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0

home=${FM_HOME:-$FM_ROOT}
printf '%s' "$PAYLOAD" | python3 "$SCRIPT_DIR/fm-pr-text-guard.py" hook --home "$home"
exit 0
