#!/usr/bin/env bash
# Behavior tests for per-task FM_HERDR_PROJECT_KEY/FM_HERDR_PROJECT_LABEL hygiene.
#
# A worker pane spawned inside herdr otherwise inherits the launching
# environment, which can name a completely unrelated project. fm-spawn must
# set the task's own project when herdr presentation identity applies, and
# clear both variables otherwise, including when the launcher already exports
# leaked values.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-herdr-env)
LEAK_KEY='/unrelated/AtlasSupportHub'
LEAK_LABEL='AtlasSupportHub'

cleanup_task_tmp() { rm -rf "/tmp/fm-$1"; }

install_fake_herdr() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/herdr" <<'SH'
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
tokens=()
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --workspace) workspace=${args[$((i+1))]:-} ;;
    --label) label=${args[$((i+1))]:-} ;;
    --cwd) cwd=${args[$((i+1))]:-} ;;
    --token) tokens+=("${args[$((i+1))]:-}") ;;
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
    query --arg ws "$ws" --arg lbl "$label" --arg tab "$tab" --arg pane "$pane" --arg cwd "$cwd" '
      .next += 1 |
      .workspaces += [{workspace_id:$ws,"label":$lbl,tokens:{}}] |
      .tabs += [{workspace_id:$ws,tab_id:$tab,pane_id:$pane,"label":"1",cwd:$cwd,tokens:{}}]' | save
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
    query --arg ws "$workspace" --arg tab "$tab" --arg pane "$pane" --arg lbl "$label" --arg cwd "$cwd" '
      .next += 1 |
      .tabs += [{workspace_id:$ws,tab_id:$tab,pane_id:$pane,"label":$lbl,cwd:$cwd,tokens:{}}]' | save
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
  'agent get') printf '{"result":{"agent":{"agent":"pi","agent_status":"idle"}}}\n' ;;
  *) : ;;
esac
SH
  chmod +x "$fakebin/herdr" "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" pi
  printf '%s' "$fakebin"
}

make_herdr_home() {  # <name> <project-slug> <task-id>
  local name=$1 slug=$2 id=$3 home proj
  home="$TMP_ROOT/$name/home"
  proj="$TMP_ROOT/$name/$slug"
  mkdir -p "$home/state" "$home/data/$id" "$home/config" "$home/projects"
  fm_git_init_commit "$proj"
  cat > "$home/data/$id/brief.md" <<BRIEF
# Task

## Captain's intent

brief for $id

## Firstmate spec

Stay inside the task worktree.
BRIEF
  printf 'manual\n' > "$home/config/backlog-backend"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$home|$proj"
}

herdr_pane_runs() {  # <log>
  grep -F '<pane><run>' "$1" || true
}

run_herdr_spawn() {  # <home> <proj> <id> <fakebin> <state> <log> <wt-root> [extra env assignments...]
  local home=$1 proj=$2 id=$3 fakebin=$4 state=$5 log=$6 wt_root=$7
  shift 7
  # The ambient launcher identity of whatever runs this suite names a real
  # workspace on the developer's own herdr server; scrub it so the spawn takes
  # the label path this fixture models.
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH \
    PATH="$fakebin:$PATH" \
    FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_HERDR_STATE="$state" \
    FM_FAKE_HERDR_LOG="$log" \
    FM_FAKE_WT_ROOT="$wt_root" \
    HERDR_SESSION=fm-lab-fake-herdr-env \
    FM_HERDR_PROJECT_KEY="$LEAK_KEY" \
    FM_HERDR_PROJECT_LABEL="$LEAK_LABEL" \
    "$@" \
    "$SPAWN" "$id" "$proj" --harness pi --backend herdr --mode no-mistakes --yolo off
}

test_set_when_applicable_and_no_leak() {
  local rec home proj id fakebin state log wt_root out status pane_runs key label
  id=herdr-env-set-z1
  rec=$(make_herdr_home set-applicable alpha "$id")
  IFS='|' read -r home proj <<EOF
$rec
EOF
  wt_root="$TMP_ROOT/set-applicable/worktrees"
  mkdir -p "$wt_root"
  state="$TMP_ROOT/set-applicable/herdr-state.json"
  log="$TMP_ROOT/set-applicable/herdr.log"
  printf '{"next":1,"workspaces":[],"tabs":[]}\n' > "$state"
  : > "$log"
  fakebin=$(install_fake_herdr "$TMP_ROOT/set-applicable")

  out=$(run_herdr_spawn "$home" "$proj" "$id" "$fakebin" "$state" "$log" "$wt_root" 2>&1)
  status=$?
  expect_code 0 "$status" "presentation herdr spawn should succeed"$'\n'"$out"
  pane_runs=$(herdr_pane_runs "$log")
  key=$(cd "$proj" && pwd -P)
  label=$("$ROOT/bin/fm-project-display-name.sh" "$(basename "$key")")
  assert_contains "$pane_runs" "export FM_HERDR_PROJECT_KEY='$key'" \
    "worker pane did not export the task's own project key"
  assert_contains "$pane_runs" "FM_HERDR_PROJECT_LABEL='$label'" \
    "worker pane did not export the task's own project label"
  assert_not_contains "$pane_runs" "$LEAK_KEY" \
    "launcher project key leaked into the worker pane env commands"
  assert_not_contains "$pane_runs" "$LEAK_LABEL" \
    "launcher project label leaked into the worker pane env commands"
  assert_not_contains "$pane_runs" 'unset FM_HERDR_PROJECT_KEY' \
    "presentation spawn cleared FM_HERDR_PROJECT_* instead of setting the task project"
  cleanup_task_tmp "$id"
  pass "herdr presentation spawn sets the task project and does not inherit launcher values"
}

test_cleared_when_not_applicable_protocol14() {
  local rec home proj id fakebin state log wt_root out status pane_runs labels
  id=herdr-env-clear-p14-z1
  rec=$(make_herdr_home clear-p14 alpha "$id")
  IFS='|' read -r home proj <<EOF
$rec
EOF
  wt_root="$TMP_ROOT/clear-p14/worktrees"
  mkdir -p "$wt_root"
  state="$TMP_ROOT/clear-p14/herdr-state.json"
  log="$TMP_ROOT/clear-p14/herdr.log"
  printf '{"next":1,"workspaces":[],"tabs":[]}\n' > "$state"
  : > "$log"
  fakebin=$(install_fake_herdr "$TMP_ROOT/clear-p14")

  out=$(FM_FAKE_HERDR_PROTOCOL=14 run_herdr_spawn "$home" "$proj" "$id" "$fakebin" "$state" "$log" "$wt_root" 2>&1)
  status=$?
  expect_code 0 "$status" "protocol-14 herdr spawn should succeed"$'\n'"$out"
  pane_runs=$(herdr_pane_runs "$log")
  assert_contains "$pane_runs" 'unset FM_HERDR_PROJECT_KEY FM_HERDR_PROJECT_LABEL' \
    "protocol-14 spawn did not clear FM_HERDR_PROJECT_* for the worker"
  assert_not_contains "$pane_runs" "export FM_HERDR_PROJECT_KEY=" \
    "protocol-14 spawn exported a project key when presentation identity does not apply"
  assert_not_contains "$pane_runs" "$LEAK_KEY" \
    "launcher project key leaked into the protocol-14 worker pane env commands"
  assert_not_contains "$pane_runs" "$LEAK_LABEL" \
    "launcher project label leaked into the protocol-14 worker pane env commands"
  labels=$(jq -r '.workspaces[].label' "$state")
  assert_contains "$labels" 'firstmate' \
    "protocol-14 spawn with leaked launcher env did not keep the legacy per-home workspace"
  assert_not_contains "$labels" "$LEAK_LABEL" \
    "protocol-14 spawn adopted the launcher's leaked project as a workspace label"
  cleanup_task_tmp "$id"
  pass "protocol-14 herdr spawn clears FM_HERDR_PROJECT_* and does not inherit launcher values"
}

test_cleared_when_not_applicable_tmux() {
  local home proj wt fakebin sendlog id out status sends
  id=herdr-env-clear-tmux-z1
  home="$TMP_ROOT/clear-tmux/home"
  proj="$TMP_ROOT/clear-tmux/alpha"
  wt="$TMP_ROOT/clear-tmux/wt"
  sendlog="$TMP_ROOT/clear-tmux/send.log"
  fakebin=$(fm_fakebin "$TMP_ROOT/clear-tmux")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' pi > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$id"
  cat > "$home/data/$id/brief.md" <<BRIEF
# Task

## Captain's intent

brief for $id

## Firstmate spec

Stay inside the task worktree.
BRIEF
  printf 'manual\n' > "$home/config/backlog-backend"
  touch "$home/state/.last-watcher-beat"
  : > "$sendlog"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  # The agent-up read checks the session inventory before it trusts a pane, so
  # a created window has to show up in list-windows or every spawn reads as a
  # gone endpoint.
  list-windows)
    [ -z "${FM_FAKE_WINDOW_LOG:-}" ] || [ ! -f "$FM_FAKE_WINDOW_LOG" ] || cat "$FM_FAKE_WINDOW_LOG"
    exit 0 ;;
  new-window)
    if [ -n "${FM_FAKE_WINDOW_LOG:-}" ]; then
      prev=""
      for a in "$@"; do
        [ "$prev" != "-n" ] || printf '%s\n' "$a" >> "$FM_FAKE_WINDOW_LOG"
        prev=$a
      done
    fi
    exit 0 ;;
  has-session|new-session|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_SEND_LOG:-}" ]; then
      printf '%s\n' "$*" >> "$FM_FAKE_SEND_LOG"
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse pi

  out=$(
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
      FM_FAKE_SEND_LOG="$sendlog" PATH="$fakebin:$PATH" \
      FM_FAKE_WINDOW_LOG="$home/state/.fake-windows" FM_SPAWN_AGENT_UP_SLEEP=0 \
      FM_HERDR_PROJECT_KEY="$LEAK_KEY" FM_HERDR_PROJECT_LABEL="$LEAK_LABEL" \
      "$SPAWN" "$id" "$proj" --harness pi --backend tmux --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "tmux spawn should succeed"$'\n'"$out"
  sends=$(cat "$sendlog")
  assert_contains "$sends" 'unset FM_HERDR_PROJECT_KEY FM_HERDR_PROJECT_LABEL' \
    "tmux spawn did not clear FM_HERDR_PROJECT_* for the worker"
  assert_not_contains "$sends" "export FM_HERDR_PROJECT_KEY=" \
    "tmux spawn exported a project key when herdr presentation identity does not apply"
  assert_not_contains "$sends" "$LEAK_KEY" \
    "launcher project key leaked into the tmux worker pane env commands"
  assert_not_contains "$sends" "$LEAK_LABEL" \
    "launcher project label leaked into the tmux worker pane env commands"
  cleanup_task_tmp "$id"
  pass "tmux spawn clears FM_HERDR_PROJECT_* and does not inherit launcher values"
}

test_set_when_applicable_and_no_leak
test_cleared_when_not_applicable_protocol14
test_cleared_when_not_applicable_tmux
