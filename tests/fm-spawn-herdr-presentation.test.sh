#!/usr/bin/env bash
# End-to-end fake-Herdr-CLI coverage for single and batch fm-spawn presentation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-spawn-herdr-presentation)
HOME_FIX="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
HERDR_STATE="$TMP_ROOT/herdr-state.json"
HERDR_LOG="$TMP_ROOT/herdr.log"
WT_ROOT="$TMP_ROOT/worktrees"
mkdir -p "$HOME_FIX/state" "$HOME_FIX/data" "$HOME_FIX/config" "$WT_ROOT"
printf '{"next":1,"workspaces":[],"tabs":[]}\n' > "$HERDR_STATE"
: > "$HERDR_LOG"

cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
state=${FM_FAKE_HERDR_STATE:?}
log=${FM_FAKE_HERDR_LOG:?}
{
  for arg in "$@"; do printf '<%s>' "$arg"; done
  printf '\n'
} >> "$log"

save() { local tmp="$state.tmp.$$"; cat > "$tmp" && mv "$tmp" "$state"; }
query() { jq "$@" "$state"; }
args=("$@")
cmd=${1:-}; sub=${2:-}; workspace= label= cwd=
tokens=(); clears=()
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --workspace) workspace=${args[$((i+1))]:-} ;;
    --label) label=${args[$((i+1))]:-} ;;
    --cwd) cwd=${args[$((i+1))]:-} ;;
    --token) tokens+=("${args[$((i+1))]:-}") ;;
    --clear-token) clears+=("${args[$((i+1))]:-}") ;;
  esac
done

protocol=${FM_FAKE_HERDR_PROTOCOL:-16}
require_presentation() {
  [ "$protocol" -ge 16 ] && return 0
  printf '{"error":{"code":"unknown_method"}}\n' >&2
  exit 1
}

case "$cmd $sub" in
  'status --json')
    printf '{"client":{"version":"0.7.4","protocol":%s},"server":{"running":true}}\n' "$protocol"
    ;;
  'workspace list') query '{result:{workspaces:.workspaces}}' ;;
  'workspace create')
    n=$(query -r .next); ws="w$n"; tab="$ws:t1"; pane="$ws:p1"
    query --arg ws "$ws" --arg label "$label" --arg tab "$tab" --arg pane "$pane" --arg cwd "$cwd" '
      .next += 1 |
      .workspaces += [{workspace_id:$ws,label:$label,tokens:{}}] |
      .tabs += [{workspace_id:$ws,tab_id:$tab,pane_id:$pane,label:"1",cwd:$cwd,tokens:{}}]' | save
    jq -n --arg ws "$ws" --arg tab "$tab" --arg pane "$pane" \
      '{result:{workspace:{workspace_id:$ws},tab:{tab_id:$tab},root_pane:{pane_id:$pane}}}'
    ;;
  'workspace report-metadata')
    require_presentation
    target=${3:-}
    for token in "${tokens[@]}"; do
      key=${token%%=*}; value=${token#*=}
      query --arg id "$target" --arg key "$key" --arg value "$value" \
        '.workspaces |= map(if .workspace_id == $id then (.tokens[$key]=$value) else . end)' | save
    done
    ;;
  'workspace rename')
    require_presentation
    target=${3:-}; value=${4:-}
    query --arg id "$target" --arg value "$value" \
      '.workspaces |= map(if .workspace_id == $id then .label=$value else . end)' | save
    ;;
  'tab list') query --arg ws "$workspace" '{result:{tabs:[.tabs[]|select(.workspace_id==$ws)]}}' ;;
  'tab create')
    n=$(query -r .next); tab="$workspace:t$n"; pane="$workspace:p$n"
    query --arg ws "$workspace" --arg tab "$tab" --arg pane "$pane" --arg label "$label" --arg cwd "$cwd" '
      .next += 1 |
      .tabs += [{workspace_id:$ws,tab_id:$tab,pane_id:$pane,label:$label,cwd:$cwd,tokens:{}}]' | save
    jq -n --arg tab "$tab" --arg pane "$pane" '{result:{tab:{tab_id:$tab},root_pane:{pane_id:$pane}}}'
    ;;
  'tab rename')
    require_presentation
    target=${3:-}; value=${4:-}
    query --arg id "$target" --arg value "$value" \
      '.tabs |= map(if .tab_id == $id then .label=$value else . end)' | save
    ;;
  'tab close')
    target=${3:-}
    query --arg id "$target" '.tabs |= map(select(.tab_id != $id))' | save
    ;;
  'pane list')
    query --arg ws "$workspace" '{result:{panes:[.tabs[]|select(.workspace_id==$ws)|{workspace_id,tab_id,pane_id,tokens}]}}'
    ;;
  'pane report-metadata')
    require_presentation
    target=${3:-}
    for token in "${tokens[@]}"; do
      key=${token%%=*}; value=${token#*=}
      query --arg id "$target" --arg key "$key" --arg value "$value" \
        '.tabs |= map(if .pane_id == $id then (.tokens[$key]=$value) else . end)' | save
    done
    for key in ${clears[@]+"${clears[@]}"}; do
      query --arg id "$target" --arg key "$key" \
        '.tabs |= map(if .pane_id == $id then .tokens |= del(.[$key]) else . end)' | save
    done
    ;;
  'pane get')
    target=${3:-}
    query --arg id "$target" '{result:{pane:(.tabs[]|select(.pane_id==$id)|{pane_id,workspace_id,tab_id,foreground_cwd:.cwd,cwd:.cwd})}}'
    ;;
  'pane run')
    target=${3:-}; command=${4:-}
    if [ "$command" = 'treehouse get' ]; then
      project=$(query -r --arg id "$target" '.tabs[]|select(.pane_id==$id)|.cwd')
      safe=${target//[:\/]/_}; wt="$FM_FAKE_WT_ROOT/$safe"
      git -C "$project" worktree add -q --detach "$wt" HEAD
      query --arg id "$target" --arg wt "$wt" \
        '.tabs |= map(if .pane_id == $id then .cwd=$wt else . end)' | save
    fi
    ;;
  'pane close')
    target=${3:-}
    query --arg id "$target" '.tabs |= map(select(.pane_id != $id))' | save
    ;;
  'pane read'|'pane send-text'|'pane send-keys') : ;;
  'agent get') printf '{"result":{"agent":{"agent":"pi","agent_status":"idle"}}\n' ;;
  *) : ;;
esac
SH
chmod +x "$FAKEBIN/herdr" "$FAKEBIN/treehouse"
fm_fake_exit0 "$FAKEBIN" pi codex

make_project() {  # <slug>
  local dir="$TMP_ROOT/$1"
  fm_git_init_commit "$dir"
  printf '%s' "$dir"
}

JOURNEY=$(make_project city-guide)
ATELIER=$(make_project atelier)
for id in journey-single journey-batch-one journey-batch-two atelier-single; do
  mkdir -p "$HOME_FIX/data/$id"
  printf 'fake spawn instructions for %s\n' "$id" > "$HOME_FIX/data/$id/brief.md"
done
cat > "$HOME_FIX/data/projects.md" <<'EOF'
- city-guide [local-only] - Journey
- atelier [local-only] - Atelier
EOF
cat > "$HOME_FIX/data/backlog.md" <<'EOF'
- [ ] journey-single - Validate GPS triggers across all seven city stops (repo: city-guide)
- [ ] journey-batch-one - Rebaseline the City Guide launch plan with a date (repo: city-guide)
- [ ] journey-batch-two - Audit the Journey release checklist (repo: city-guide)
- [ ] atelier-single - Align Atelier launch surfaces (repo: atelier)
EOF
cat > "$TMP_ROOT/states" <<'EOF'
journey-single=working
journey-batch-one=parked
journey-batch-two=working
atelier-single=blocked
EOF

run_spawn() {
  PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_HERDR_STATE="$HERDR_STATE" \
    FM_FAKE_HERDR_LOG="$HERDR_LOG" \
    FM_FAKE_WT_ROOT="$WT_ROOT" \
    FM_VISIBLE_STATE_FILE="$TMP_ROOT/states" \
    HERDR_SESSION=fm-lab-fake-presentation \
    "$ROOT/bin/fm-spawn.sh" "$@"
}

run_spawn journey-single "$JOURNEY" --harness pi --backend herdr >/dev/null \
  || fail 'single Journey Herdr spawn failed'
run_spawn \
  "journey-batch-one=$JOURNEY" \
  "journey-batch-two=$JOURNEY" \
  --scout --harness codex --backend herdr >/dev/null \
  || fail 'batch Journey Herdr spawn failed'
run_spawn atelier-single "$ATELIER" --harness codex --backend herdr --outcome 'Align Atelier launch surfaces' >/dev/null \
  || fail 'concurrent Atelier Herdr spawn failed'

journey_path=$(cd "$JOURNEY" && pwd -P)
atelier_path=$(cd "$ATELIER" && pwd -P)
home_path=$(cd "$HOME_FIX" && pwd -P)
journey_key="path-v1:$(printf '%s' "$journey_path" | git -C "$ROOT" hash-object --stdin)"
atelier_key="path-v1:$(printf '%s' "$atelier_path" | git -C "$ROOT" hash-object --stdin)"
home_key="path-v1:$(printf '%s' "$home_path" | git -C "$ROOT" hash-object --stdin)"
workspace_count=$(jq '.workspaces|length' "$HERDR_STATE")
[ "$workspace_count" -eq 2 ] || fail "expected one workspace per project, got $workspace_count"
journey_ws=$(jq -r --arg owner "$home_key" --arg project "$journey_key" \
  '.workspaces[]|select(.tokens.fm_owner==$owner and .tokens.fm_project==$project)|.workspace_id' "$HERDR_STATE")
atelier_ws=$(jq -r --arg owner "$home_key" --arg project "$atelier_key" \
  '.workspaces[]|select(.tokens.fm_owner==$owner and .tokens.fm_project==$project)|.workspace_id' "$HERDR_STATE")
[ -n "$journey_ws" ] && [ -n "$atelier_ws" ] && [ "$journey_ws" != "$atelier_ws" ] \
  || fail 'concurrent project workspaces did not get distinct hidden identities'
[ "$(jq --arg ws "$journey_ws" '[.tabs[]|select(.workspace_id==$ws)]|length' "$HERDR_STATE")" -eq 3 ] \
  || fail 'single and batch Journey spawns did not converge on one project workspace'
assert_contains "$(jq -r --arg ws "$journey_ws" '.workspaces[]|select(.workspace_id==$ws)|.label' "$HERDR_STATE")" \
  'City Guide' 'Journey workspace lost its human project name'
assert_contains "$(jq -r --arg ws "$atelier_ws" '.workspaces[]|select(.workspace_id==$ws)|.label' "$HERDR_STATE")" \
  'Atelier' 'Atelier workspace lost its human project name'

labels=$(jq -r '.tabs[].label' "$HERDR_STATE")
assert_contains "$labels" 'WORKER · Validate GPS triggers across all seven city stops · 🔵 WORKING' \
  'single spawn did not render backlog outcome and authoritative state'
assert_contains "$labels" 'WORKER · Rebaseline the City Guide launch plan with a date · 🟣 NEEDS YOU' \
  'first batch scout did not render its distinct outcome'
assert_contains "$labels" 'WORKER · Audit the Journey release checklist · 🔵 WORKING' \
  'second batch scout did not render its distinct outcome'
assert_contains "$labels" 'WORKER · Align Atelier launch surfaces · 🟠 BLOCKED' \
  'concurrent project explicit outcome did not render'
for id in journey-single journey-batch-one journey-batch-two atelier-single; do
  [ "$(jq -r --arg id "$id" '.tabs[]|select(.tokens.fm_task_id==$id)|.tokens.fm_task_id' "$HERDR_STATE")" = "$id" ] \
    || fail "spawned pane missing hidden fm_task_id=$id"
done
assert_contains "$(cat "$HOME_FIX/state/journey-single.meta")" 'harness=pi' 'Pi runtime was not preserved'
assert_contains "$(cat "$HOME_FIX/state/journey-batch-one.meta")" 'harness=codex' 'Codex runtime was not preserved'
assert_contains "$(cat "$HOME_FIX/state/journey-single.meta")" 'kind=ship' 'ship kind was not preserved'
assert_contains "$(cat "$HOME_FIX/state/journey-batch-one.meta")" 'kind=scout' 'scout kind was not preserved'
pass 'fm-spawn fake Herdr E2E: single, batch, projects, axes, human labels, outcomes, states, and hidden ids converge'

mkdir -p "$HOME_FIX/data/journey-protocol14"
printf 'fake spawn instructions for journey-protocol14\n' > "$HOME_FIX/data/journey-protocol14/brief.md"
cat >> "$HOME_FIX/data/backlog.md" <<'EOF'
- [ ] journey-protocol14 - Keep spawning on an old Herdr build (repo: city-guide)
EOF
: > "$HERDR_LOG"
FM_FAKE_HERDR_PROTOCOL=14 run_spawn journey-protocol14 "$JOURNEY" --harness pi --backend herdr >/dev/null \
  || fail 'a protocol-14 Herdr build no longer spawns through the label fallback'
legacy_ws=$(jq -r '.workspaces[]|select(.label=="firstmate")|.workspace_id' "$HERDR_STATE")
[ -n "$legacy_ws" ] || fail 'protocol-14 fallback did not use the legacy per-home workspace label'
[ "$(jq -r --arg ws "$legacy_ws" '.tabs[]|select(.workspace_id==$ws)|.label' "$HERDR_STATE")" = 'fm-journey-protocol14' ] \
  || fail 'protocol-14 fallback tab did not keep the legacy fm-<id> label'
[ "$(jq -r --arg ws "$legacy_ws" '.workspaces[]|select(.workspace_id==$ws)|.tokens|length' "$HERDR_STATE")" -eq 0 ] \
  || fail 'protocol-14 fallback attempted hidden workspace identity tokens'
legacy_log=$(cat "$HERDR_LOG")
assert_not_contains "$legacy_log" 'report-metadata' 'protocol-14 fallback still called report-metadata'
assert_not_contains "$legacy_log" 'rename' 'protocol-14 fallback still renamed a tab or workspace'
legacy_meta=$(cat "$HOME_FIX/state/journey-protocol14.meta")
assert_contains "$legacy_meta" 'backend=herdr' 'protocol-14 fallback did not record its backend'
assert_not_contains "$legacy_meta" 'herdr_workspace_managed' 'protocol-14 fallback claimed a managed workspace'
pass 'fm-spawn fake Herdr E2E: a protocol-14 build spawns through the prior label-based flow untouched by presentation'
