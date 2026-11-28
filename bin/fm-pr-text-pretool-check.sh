#!/usr/bin/env bash
# The PR text check (bin/fm-pr-text-guard.py) for a first mate or second mate
# Claude or Antigravity (agy) session.
#
# bin/fm-spawn.sh installs that check for every spawned Claude worker with the
# worker's home. A first mate or second mate session is not spawned that way,
# so the tracked .claude/settings.json runs this wrapper as a PreToolUse hook
# on Bash, and the tracked .agents/hooks.json runs it with --agy on agy's
# shell tool, instead. It only scopes the check, finds the home and, for agy,
# translates the payload and the answer; the check owns what counts as
# publishing, which repositories are refused and the refusal text.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-pr-text-pretool-check.sh [--agy]
#
# --agy reads agy's PreToolUse payload (toolCall.name run_command, bash or
# Bash; the command in toolCall.args.CommandLine or .command; the working
# directory in toolCall.args.Cwd, else the payload's cwd) and answers a
# refusal as agy's {"decision":"deny","reason":...} object on stdout. An allow
# prints nothing, which agy reads as allow. It needs jq to translate; without
# jq it allows, as it does without python3.
#
# SCOPE. It runs only in a genuine first mate or second mate home: the plain
# checkout of a primary home, or a home carrying a valid .fm-secondmate-home
# marker (bin/fm-primary-scope-lib.sh owns that test). A ship or scout worker,
# which already has its own copy, and any other checkout pass untouched.
# Without --agy, a payload Cursor delivered passes too, because the check
# answers only in Claude's shape (bin/fm-hook-host-lib.sh).
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

AGY_MODE=0
case "${1-}" in
  '') ;;
  --agy) AGY_MODE=1 ;;
  -h|--help) sed -n '2,/^set -u$/{/^#/s/^# \{0,1\}//p;}' "${BASH_SOURCE[0]}"; exit 0 ;;
  *) echo "fm-pr-text-pretool-check.sh: unknown argument: $1 (usage: [--agy])" >&2; exit 0 ;;
esac

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

# Prefilter (transport only; the check still owns what counts as publishing).
# The check reads only a command whose text holds gh (gh, gh-axi) or
# no-mistakes, and a JSON string can spell those letters only literally or
# through a \u escape, so a raw payload with none of the three cannot publish
# and is allowed before the scope test starts git or the check starts Python.
case "$PAYLOAD" in
  *gh*|*no-mistakes*|*'\u'*) ;;
  *) exit 0 ;;
esac

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
FM_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || exit 0

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_is_task_worker && exit 0
command -v git >/dev/null 2>&1 || exit 0
fm_primary_root_matches "$FM_ROOT" || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

home=${FM_HOME:-$FM_ROOT}

if [ "$AGY_MODE" -eq 1 ]; then
  command -v jq >/dev/null 2>&1 || exit 0
  # agy's shell tool becomes the check's Bash; any other tool keeps its own
  # name, which the check passes untouched.
  CLAUDE_PAYLOAD=$(printf '%s' "$PAYLOAD" | jq -c '
    (.toolCall // {}) as $call | ($call.args // {}) as $args
    | {tool_name: (if ($call.name | IN("run_command", "bash", "Bash")) then "Bash" else ($call.name // "") end),
       tool_input: {command: ($args.CommandLine // $args.command)},
       cwd: ($args.Cwd // .cwd)}' 2>/dev/null) || exit 0
  ANSWER=$(printf '%s' "$CLAUDE_PAYLOAD" | python3 "$SCRIPT_DIR/fm-pr-text-guard.py" hook --home "$home")
  [ -n "$ANSWER" ] || exit 0
  printf '%s' "$ANSWER" | jq -c '{decision: "deny", reason: .hookSpecificOutput.permissionDecisionReason}' 2>/dev/null \
    || printf '{"decision":"deny","reason":"Starship refused this command because its PR text check answer could not be read. Append a blocked: status line naming this and stop."}\n'
  exit 0
fi

# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0

printf '%s' "$PAYLOAD" | python3 "$SCRIPT_DIR/fm-pr-text-guard.py" hook --home "$home"
exit 0
