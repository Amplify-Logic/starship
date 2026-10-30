#!/usr/bin/env bash
# Opt-in real Herdr verification for the grouped Agents worker presentation.
# Every Herdr operation, including lifecycle cleanup, goes through the guarded
# helper and a generated non-default lab session.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ "${FM_HERDR_WORKER_PRESENTATION_E2E:-0}" = 1 ] || {
  echo 'skip: set FM_HERDR_WORKER_PRESENTATION_E2E=1 for real Herdr worker presentation verification'
  exit 0
}
command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr not found'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
command -v pi >/dev/null 2>&1 || { echo 'skip: pi not found'; exit 0; }

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name worker-presentation)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-worker-presentation-e2e.XXXXXX")

cleanup() {
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null 2>&1 || true
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail 'could not provision guarded non-default Herdr lab'

WS_OUT=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace create \
  --cwd "$ROOT" --label 'Alpha · 🔵 1 WORKING' --no-focus) \
  || fail 'could not create project workspace in lab'
WS=$(printf '%s' "$WS_OUT" | jq -r '.result.workspace.workspace_id // empty')
SEED=$(printf '%s' "$WS_OUT" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$WS" ] && [ -n "$SEED" ] || fail 'workspace creation did not return stable ids'

OWNER_TOKEN="path-v1:$(printf '%s' "$ROOT" | git -C "$ROOT" hash-object --stdin)"
PROJECT_TOKEN=$OWNER_TOKEN
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace report-metadata "$WS" \
  --source firstmate-project-identity-v1 \
  --token "fm_owner=$OWNER_TOKEN" \
  --token "fm_project=$PROJECT_TOKEN" >/dev/null \
  || fail 'could not bind project identity tokens'

# Herdr 0.9 replaced `agent start <name> --workspace ... -- <argv>`, which made
# its own tab, with `agent start <name> --kind <kind> --pane <id>` into an
# existing pane at a shell prompt, and agent names became lowercase slugs.
if "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" agent start --help 2>/dev/null | grep -q -- '--kind'; then
  TAB_OUT=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" tab create \
    --workspace "$WS" --cwd "$ROOT" --env 'FM_PRESENTATION_LAB=1' --no-focus) \
    || fail 'could not create the Pi presentation probe tab'
  PROBE_PANE=$(printf '%s' "$TAB_OUT" | jq -r '.result.root_pane.pane_id // empty')
  [ -n "$PROBE_PANE" ] || fail 'tab creation did not return the probe pane id'
  # The pane runs the operator's login shell, whose profile (conda, nvm,
  # prompt helpers) keeps spawning foreground processes for several seconds,
  # and Herdr 0.9 refuses or times out `agent start` until the pane is at an
  # idle prompt. A lone shell sample is not enough, since the profile spawns
  # more helpers after it, so wait for the shell to stay alone for 3 seconds.
  samples=0 i=0
  while [ "$samples" -lt 6 ]; do
    [ "$i" -lt 240 ] || fail 'the probe pane login shell never settled at an idle prompt'
    if "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane process-info --pane "$PROBE_PANE" 2>/dev/null \
      | jq -e '.result.process_info as $p | [$p.foreground_processes[]?.pid] == [$p.shell_pid]' >/dev/null 2>&1; then
      samples=$((samples + 1))
    else
      samples=0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  AGENT_OUT=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" agent start worker-presentation \
    --kind pi --pane "$PROBE_PANE") || fail 'could not start isolated Pi presentation probe'
else
  AGENT_OUT=$("$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" agent start \
    'WORKER · Fix the login timeout · 🔵 WORKING' \
    --workspace "$WS" --cwd "$ROOT" --no-focus \
    --env 'FM_PRESENTATION_LAB=1' \
    -- pi) || fail 'could not start isolated Pi presentation probe'
fi
TAB=$(printf '%s' "$AGENT_OUT" | jq -r '.result.agent.tab_id // empty')
PANE=$(printf '%s' "$AGENT_OUT" | jq -r '.result.agent.pane_id // empty')
[ -n "$TAB" ] && [ -n "$PANE" ] || fail 'agent start did not return stable tab/pane ids'

"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" tab rename "$TAB" \
  'WORKER · Fix the login timeout · 🔵 WORKING' >/dev/null \
  || fail 'could not set worker tab title'
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane report-metadata "$PANE" \
  --source firstmate-worker-visible-v1 \
  --title 'WORKER · Fix the login timeout · 🔵 WORKING' \
  --display-agent 'pi/gpt-5.6 · detached' \
  --state-label 'working=🔵 WORKING' \
  --state-label 'blocked=🔵 WORKING' \
  --state-label 'idle=🔵 WORKING' \
  --state-label 'done=🔵 WORKING' \
  --token 'fm_task_id=alpha-login-timeout-v8' \
  --token 'fm_runtime=pi/gpt-5.6' \
  --token 'fm_branch=detached' \
  --token 'fm_state=WORKING' >/dev/null \
  || fail 'could not project worker presentation metadata'
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane close "$SEED" >/dev/null \
  || fail 'could not close the unused seeded pane'
sleep 1

"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace list > "$TMP_ROOT/workspaces.json" \
  || fail 'could not inspect real workspace presentation'
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" tab list --workspace "$WS" > "$TMP_ROOT/tabs.json" \
  || fail 'could not inspect real tab presentation'
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane list --workspace "$WS" > "$TMP_ROOT/panes.json" \
  || fail 'could not inspect real pane presentation'
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" agent list > "$TMP_ROOT/agents.json" \
  || fail 'could not inspect real grouped Agents inventory'
"$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" api snapshot > "$TMP_ROOT/snapshot.json" \
  || fail 'could not inspect real session snapshot'

workspace_label=$(jq -r --arg id "$WS" '.result.workspaces[]|select(.workspace_id==$id)|.label' "$TMP_ROOT/workspaces.json")
tab_label=$(jq -r --arg id "$TAB" '.result.tabs[]|select(.tab_id==$id)|.label' "$TMP_ROOT/tabs.json")
display_agent=$(jq -r --arg id "$PANE" '.result.panes[]|select(.pane_id==$id)|.display_agent' "$TMP_ROOT/panes.json")
task_id=$(jq -r --arg id "$PANE" '.result.panes[]|select(.pane_id==$id)|.tokens.fm_task_id' "$TMP_ROOT/panes.json")
native_agent=$(jq -r --arg id "$PANE" '.result.agents[]|select(.pane_id==$id)|.agent' "$TMP_ROOT/agents.json")

[ "$workspace_label" = 'Alpha · 🔵 1 WORKING' ] \
  || fail "real grouped workspace row mismatch: $workspace_label"
[ "$tab_label" = 'WORKER · Fix the login timeout · 🔵 WORKING' ] \
  || fail "real grouped task row mismatch: $tab_label"
[ "$display_agent" = 'pi/gpt-5.6 · detached' ] \
  || fail "real grouped detail row mismatch: $display_agent"
[ "$task_id" = alpha-login-timeout-v8 ] \
  || fail "real hidden task identity mismatch: $task_id"
[ "$native_agent" = pi ] \
  || fail "real Agents inventory did not register Pi: $native_agent"

"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" \
  || fail 'guarded lab teardown or default-session tripwire failed'
trap - EXIT
pass 'real Herdr grouped Agents presentation shows human project, WORKER outcome/state, Pi detail, and hidden task identity'
