#!/usr/bin/env bash
# Opt-in real Herdr staging for the unapproved layout convergence preview.
#
# Stages three fleets of the same eight synthetic workers across three projects
# and captures what Herdr actually reports for each:
#   BEFORE  - today's shape, one workspace per project, one tab per worker.
#   AFTER-A - upstream's one workspace per worker, under a project header row.
#   AFTER-B - upstream's one workspace per worker, project name on every row.
# Each model is staged in its own generated non-default lab session, and each
# model also stages a LATE worker after the first capture, so the captures show
# how each shape survives a worker that starts out of project order.
#
# Nothing here touches the live fleet, the default session, or any real task.
# Every Herdr operation, lifecycle included, goes through bin/fm-herdr-lab.sh.
#
# Run it, and refresh docs/herdr-layout-preview.md's captures, with:
#   FM_HERDR_LAYOUT_PREVIEW_E2E=1 \
#     FM_HERDR_LAYOUT_PREVIEW_OUT=docs/evidence/herdr-layout-preview \
#     HERDR_LAB_HELPER=$HOME/starship/bin/fm-herdr-lab.sh \
#     tests/fm-herdr-layout-preview-e2e.test.sh
# FM_HERDR_LAYOUT_PREVIEW_OUT is optional; without it the captures go to a
# temp dir and only the assertions run.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-herdr-preview-lib.sh
. "$ROOT/bin/fm-herdr-preview-lib.sh"

[ "${FM_HERDR_LAYOUT_PREVIEW_E2E:-0}" = 1 ] || {
  echo 'skip: set FM_HERDR_LAYOUT_PREVIEW_E2E=1 for real Herdr layout preview staging'
  exit 0
}
command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr not found'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
# Deliberately mktemp rather than fm_test_tmproot: this test reads its scratch
# files back after the call that creates them, and fm_test_tmproot installs its
# cleanup trap inside the command substitution that returns the path, so the
# subshell removes the directory on the way out.
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-layout-preview.XXXXXX")
OUT_DIR=${FM_HERDR_LAYOUT_PREVIEW_OUT:-$TMP_ROOT/captures}
mkdir -p "$OUT_DIR"

# The lab session currently provisioned, so one EXIT trap covers whichever of
# the three staging runs is in flight.
LAB_SESSION=""
cleanup() {
  local status=$? report
  # The default-session fleet tripwire only reports a violation on the
  # teardown's stderr, so the failure path must never discard it.
  if [ -n "$LAB_SESSION" ] \
    && ! report=$("$HERDR_LAB_HELPER" teardown "$LAB_SESSION" 2>&1); then
    printf 'guarded lab teardown or default-session tripwire failed for %s, which may still exist:\n%s\n' \
      "$LAB_SESSION" "$report" >&2
  fi
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT

# </dev/null so a herdr subcommand can never consume the stdin of a caller's
# read loop and silently truncate a capture.
lab() {  # <herdr arguments...>
  "$HERDR_LAB_HELPER" run "$LAB_SESSION" "$@" </dev/null
}

lab_open() {  # <label>
  LAB_SESSION=$("$HERDR_LAB_HELPER" name "$1")
  "$HERDR_LAB_HELPER" provision "$LAB_SESSION" \
    || fail "could not provision guarded non-default Herdr lab for $1"
}

lab_close() {
  "$HERDR_LAB_HELPER" teardown "$LAB_SESSION" \
    || fail "guarded lab teardown or default-session tripwire failed for $LAB_SESSION"
  LAB_SESSION=""
}

# --- the synthetic fleet ----------------------------------------------------
#
# Eight workers across three projects, covering five of the six visible states
# - NEEDS YOU, FAILED, BLOCKED, WORKING and READY - at the scale the trial
# verdict said upstream's flat list starts to degrade at. No record is `paused`,
# so WAITING and its yellow aggregate slot are not exercised by these captures.
# Fields: task-id | project | canonical-state | runtime | branch | outcome
# LATE is deliberately an Alpha worker started last, after both
# other projects already have workers.
WORKERS=(
  'alpha-login-timeout-v8|Alpha|working|pi/gpt-5.6|detached|Fix the login timeout'
  'alpha-pricing-layout-q2|Alpha|parked|claude/opus-5|fm/alpha-pricing-layout-q2|Decide the pricing page layout'
  'alpha-search-speed-r3|Alpha|working|codex/gpt-5.6|fm/alpha-search-speed-r3|Speed up the search results'
  'beta-onboarding-copy-k4|Beta|parked|claude/opus-5|fm/beta-onboarding-copy-k4|Decide the onboarding welcome copy'
  'beta-export-retry-m1|Beta|failed|pi/gpt-5.6|fm/beta-export-retry-m1|Retry the nightly CSV export'
  'api-platform-rate-limit-c7|API Platform|blocked|claude/opus-5|fm/api-platform-rate-limit-c7|Stop rate limits dropping webhook deliveries'
  'api-platform-schema-audit-s2|API Platform|done|codex/gpt-5.6|detached|Audit the public schema for breaking changes'
)
LATE='alpha-settings-crash-t9|Alpha|failed|claude/opus-5|fm/alpha-settings-crash-t9|Fix the crash on the settings page'
PROJECTS=('Alpha' 'Beta' 'API Platform')

field() {  # <worker-record> <1-based-field>
  printf '%s' "$1" | cut -d'|' -f"$2"
}

# project_stats: the six-count string fm_visible_aggregate consumes, counted
# over the supplied worker records for one project. Mirrors what
# bin/fm-visible-status.sh counts from real task metadata.
project_stats() {  # <project> <worker-record>...
  local project=$1 record state
  local needs=0 failed=0 blocked=0 working=0 waiting=0 ready=0
  shift
  for record in "$@"; do
    [ "$(field "$record" 2)" = "$project" ] || continue
    state=$(fm_visible_state "$(field "$record" 3)")
    case "$state" in
      'NEEDS YOU') needs=$((needs + 1)) ;;
      FAILED) failed=$((failed + 1)) ;;
      BLOCKED) blocked=$((blocked + 1)) ;;
      WORKING) working=$((working + 1)) ;;
      WAITING) waiting=$((waiting + 1)) ;;
      READY) ready=$((ready + 1)) ;;
    esac
  done
  printf '%s %s %s %s %s %s' "$needs" "$failed" "$blocked" "$working" "$waiting" "$ready"
}

# project_of: the workspace id staged for <project>, read from the PROJECT_WS
# lookup the BEFORE and AFTER-A stagers fill in.
PROJECT_WS=()
project_ws() {  # <project>
  local entry
  for entry in "${PROJECT_WS[@]:-}"; do
    [ "${entry%%|*}" = "$1" ] && { printf '%s' "${entry#*|}"; return 0; }
  done
  return 1
}

workspace_create() {  # <label>
  local out
  out=$(lab workspace create --cwd "$ROOT" --label "$1" --no-focus) \
    || fail "could not create workspace '$1' in the lab"
  printf '%s' "$out"
}

# project_metadata: the hidden owner/project identity binding today's adapter
# writes. Both candidates keep it, so both captures are staged with it.
bind_identity() {  # <workspace-id> <project>
  local owner project
  owner="path-v1:$(printf '%s' "$ROOT" | git -C "$ROOT" hash-object --stdin)"
  project="path-v1:$(printf '%s' "$2" | git -C "$ROOT" hash-object --stdin)"
  lab workspace report-metadata "$1" \
    --source firstmate-project-identity-v1 \
    --token "fm_owner=$owner" \
    --token "fm_project=$project" >/dev/null \
    || fail "could not bind identity tokens on workspace $1"
}

project_worker_metadata() {  # <pane-id> <worker-record> <icon> <state>
  local record=$2 icon=$3 state=$4
  lab pane report-metadata "$1" \
    --source firstmate-worker-visible-v1 \
    --title "$(fm_preview_worker_tab "$(field "$record" 6)" "$icon" "$state")" \
    --display-agent "$(fm_preview_worker_detail "$(field "$record" 4)" "$(field "$record" 5)")" \
    --state-label "working=$icon $state" \
    --state-label "blocked=$icon $state" \
    --state-label "idle=$icon $state" \
    --state-label "done=$icon $state" \
    --token "fm_task_id=$(field "$record" 1)" \
    --token "fm_runtime=$(field "$record" 4)" \
    --token "fm_branch=$(field "$record" 5)" \
    --token "fm_state=$state" >/dev/null \
    || fail "could not project worker presentation metadata on pane $1"
}

# --- capture ----------------------------------------------------------------
#
# The sidebar is rendered from Herdr's own authoritative reports rather than
# photographed: the lab session is never attached to, because attaching is a
# session lifecycle operation the guarded helper refuses. Workspace order is
# Herdr's own reported order, which is creation order (verified below by the
# LATE worker in every model).
capture() {  # <file> <heading>
  local file=$1 heading=$2 ws label tabs tab_id tab_label pane detail
  {
    printf '%s\n' "$heading"
    printf '%s\n' "$(printf '%*s' "${#heading}" '' | tr ' ' '-')"
  } > "$file"
  lab workspace list > "$TMP_ROOT/ws.json" || fail 'could not read workspace list'
  while IFS=$'\t' read -r ws label; do
    printf 'WORKSPACE  %s\n' "$label" >> "$file"
    tabs=$(lab tab list --workspace "$ws") || fail "could not read tabs of $ws"
    lab pane list --workspace "$ws" > "$TMP_ROOT/panes.json" \
      || fail "could not read panes of $ws"
    while IFS=$'\t' read -r tab_id tab_label; do
      [ -n "$tab_id" ] || continue
      printf '  TAB      %s\n' "$tab_label" >> "$file"
      pane=$(jq -r --arg t "$tab_id" \
        'first(.result.panes[]|select(.tab_id==$t)|.pane_id) // empty' "$TMP_ROOT/panes.json")
      [ -n "$pane" ] || continue
      detail=$(jq -r --arg p "$pane" \
        '.result.panes[]|select(.pane_id==$p)|.display_agent // empty' "$TMP_ROOT/panes.json")
      [ -n "$detail" ] || continue
      printf '  DETAIL   %s\n' "$detail" >> "$file"
    done <<EOF
$(printf '%s' "$tabs" | jq -r '.result.tabs[]|"\(.tab_id)\t\(.label)"')
EOF
  done <<EOF
$(jq -r '.result.workspaces[]|"\(.workspace_id)\t\(.label)"' "$TMP_ROOT/ws.json")
EOF
}

sidebar_rows() {  # <capture-file> -> workspace rows only
  sed -n 's/^WORKSPACE  //p' "$1"
}

# --- BEFORE: one workspace per project, one tab per worker ------------------

stage_before() {
  local project record out ws tab pane state icon seed
  lab_open fm-layout-before
  PROJECT_WS=()
  for project in "${PROJECTS[@]}"; do
    out=$(workspace_create "$(fm_preview_project_row "$project" "$(project_stats "$project" "${WORKERS[@]}")")")
    ws=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty')
    seed=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty')
    [ -n "$ws" ] && [ -n "$seed" ] || fail 'workspace creation did not return stable ids'
    PROJECT_WS+=("$project|$ws")
    bind_identity "$ws" "$project"
    printf '%s\n' "$seed" >> "$TMP_ROOT/before-seeds"
  done
  for record in "${WORKERS[@]}"; do
    state=$(fm_visible_state "$(field "$record" 3)")
    icon=$(fm_visible_icon "$state")
    ws=$(project_ws "$(field "$record" 2)") || fail 'no workspace for project'
    out=$(lab tab create --workspace "$ws" \
      --label "$(fm_preview_worker_tab "$(field "$record" 6)" "$icon" "$state")" --no-focus) \
      || fail "could not create worker tab for $(field "$record" 1)"
    tab=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty')
    pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty')
    [ -n "$tab" ] && [ -n "$pane" ] || fail 'tab creation did not return stable ids'
    project_worker_metadata "$pane" "$record" "$icon" "$state"
  done
  # Close each project workspace's unused seeded tab, exactly as the live
  # adapter does once the first real worker tab exists beside it.
  while read -r seed; do
    [ -n "$seed" ] || continue
    lab pane close "$seed" >/dev/null || fail "could not close seeded pane $seed"
  done < "$TMP_ROOT/before-seeds"
  sleep 1
  capture "$OUT_DIR/01-before.txt" \
    'BEFORE - today: one workspace per project, one tab per worker (7 workers, 3 projects)'

  # LATE arrival: an eighth worker for a project that already has workers, and
  # whose project was staged first.
  state=$(fm_visible_state "$(field "$LATE" 3)")
  icon=$(fm_visible_icon "$state")
  ws=$(project_ws "$(field "$LATE" 2)") || fail 'no workspace for the late project'
  out=$(lab tab create --workspace "$ws" \
    --label "$(fm_preview_worker_tab "$(field "$LATE" 6)" "$icon" "$state")" --no-focus) \
    || fail 'could not create the late worker tab'
  pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty')
  project_worker_metadata "$pane" "$LATE" "$icon" "$state"
  # The project row aggregates its own workers, so it must be re-rendered.
  lab workspace rename "$ws" \
    "$(fm_preview_project_row "$(field "$LATE" 2)" "$(project_stats "$(field "$LATE" 2)" "${WORKERS[@]}" "$LATE")")" \
    >/dev/null || fail 'could not re-render the project row after the late worker'
  sleep 1
  capture "$OUT_DIR/02-before-late-worker.txt" \
    'BEFORE - after an eighth worker starts for a project that already has workers'
  lab_close
}

# --- AFTER-A: one workspace per worker, under a project header row ----------

stage_after_a() {
  local project record out ws tab pane state icon
  lab_open fm-after-a
  PROJECT_WS=()
  for project in "${PROJECTS[@]}"; do
    out=$(workspace_create "$(fm_preview_project_row "$project" "$(project_stats "$project" "${WORKERS[@]}")")")
    ws=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty')
    [ -n "$ws" ] || fail 'header workspace creation did not return a stable id'
    PROJECT_WS+=("$project|$ws")
    bind_identity "$ws" "$project"
    lab tab rename "$(printf '%s' "$out" | jq -r '.result.tab.tab_id')" \
      "$project" >/dev/null || fail 'could not label the header holder tab'
    # Each worker of this project immediately follows its header, so the
    # grouped reading only works while Herdr keeps them adjacent.
    for record in "${WORKERS[@]}"; do
      [ "$(field "$record" 2)" = "$project" ] || continue
      state=$(fm_visible_state "$(field "$record" 3)")
      icon=$(fm_visible_icon "$state")
      out=$(workspace_create "$(fm_preview_grouped_child "$(field "$record" 6)" "$icon" "$state")")
      ws=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty')
      tab=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty')
      pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty')
      [ -n "$ws" ] && [ -n "$tab" ] && [ -n "$pane" ] || fail 'worker workspace lacked stable ids'
      bind_identity "$ws" "$project"
      lab tab rename "$tab" \
        "$(fm_preview_worker_tab "$(field "$record" 6)" "$icon" "$state")" >/dev/null \
        || fail 'could not set the worker tab title'
      project_worker_metadata "$pane" "$record" "$icon" "$state"
    done
  done
  sleep 1
  capture "$OUT_DIR/03-after-a-grouped.txt" \
    'AFTER-A - one workspace per worker under a project header row (7 workers, 3 projects)'

  state=$(fm_visible_state "$(field "$LATE" 3)")
  icon=$(fm_visible_icon "$state")
  out=$(workspace_create "$(fm_preview_grouped_child "$(field "$LATE" 6)" "$icon" "$state")")
  ws=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty')
  tab=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty')
  pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty')
  bind_identity "$ws" "$(field "$LATE" 2)"
  lab tab rename "$tab" \
    "$(fm_preview_worker_tab "$(field "$LATE" 6)" "$icon" "$state")" >/dev/null \
    || fail 'could not set the late worker tab title'
  project_worker_metadata "$pane" "$LATE" "$icon" "$state"
  ws=$(project_ws "$(field "$LATE" 2)") || fail 'no header workspace for the late project'
  lab workspace rename "$ws" \
    "$(fm_preview_project_row "$(field "$LATE" 2)" "$(project_stats "$(field "$LATE" 2)" "${WORKERS[@]}" "$LATE")")" \
    >/dev/null || fail 'could not re-render the header row after the late worker'
  sleep 1
  capture "$OUT_DIR/04-after-a-late-worker.txt" \
    'AFTER-A - after an eighth worker starts for a project whose header row is at the top'
  lab_close
}

# --- AFTER-B: one workspace per worker, project name on every row -----------

stage_after_b() {
  local project record out ws tab pane state icon
  lab_open fm-after-b
  for project in "${PROJECTS[@]}"; do
    for record in "${WORKERS[@]}"; do
      [ "$(field "$record" 2)" = "$project" ] || continue
      state=$(fm_visible_state "$(field "$record" 3)")
      icon=$(fm_visible_icon "$state")
      out=$(workspace_create "$(fm_preview_prefixed_row "$project" "$(field "$record" 6)" "$icon" "$state")")
      ws=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty')
      tab=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty')
      pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty')
      [ -n "$ws" ] && [ -n "$tab" ] && [ -n "$pane" ] || fail 'worker workspace lacked stable ids'
      bind_identity "$ws" "$project"
      lab tab rename "$tab" \
        "$(fm_preview_worker_tab "$(field "$record" 6)" "$icon" "$state")" >/dev/null \
        || fail 'could not set the worker tab title'
      project_worker_metadata "$pane" "$record" "$icon" "$state"
    done
  done
  sleep 1
  capture "$OUT_DIR/05-after-b-prefixed.txt" \
    'AFTER-B - one workspace per worker, project name on every row (7 workers, 3 projects)'

  state=$(fm_visible_state "$(field "$LATE" 3)")
  icon=$(fm_visible_icon "$state")
  out=$(workspace_create "$(fm_preview_prefixed_row "$(field "$LATE" 2)" "$(field "$LATE" 6)" "$icon" "$state")")
  ws=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty')
  tab=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty')
  pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty')
  bind_identity "$ws" "$(field "$LATE" 2)"
  lab tab rename "$tab" \
    "$(fm_preview_worker_tab "$(field "$LATE" 6)" "$icon" "$state")" >/dev/null \
    || fail 'could not set the late worker tab title'
  project_worker_metadata "$pane" "$LATE" "$icon" "$state"
  sleep 1
  capture "$OUT_DIR/06-after-b-late-worker.txt" \
    'AFTER-B - after an eighth worker starts out of project order'
  lab_close
}

stage_before
stage_after_a
stage_after_b

# --- assertions on the real captures ----------------------------------------

before=$(cat "$OUT_DIR/01-before.txt")
assert_contains "$before" 'WORKSPACE  Alpha · 🟣 1 NEEDS YOU · 🔵 2 WORKING' \
  'BEFORE project row must carry the human project name and its prioritized counts'
assert_contains "$before" '  TAB      WORKER · Decide the onboarding welcome copy · 🟣 NEEDS YOU' \
  'BEFORE worker tab must carry the human outcome and prominent state'
assert_contains "$before" '  DETAIL   claude/opus-5 · fm/beta-onboarding-copy-k4' \
  'BEFORE detail row must carry runtime and branch'
[ "$(sidebar_rows "$OUT_DIR/01-before.txt" | wc -l | tr -d ' ')" = 3 ] \
  || fail 'BEFORE must show exactly one sidebar row per project'

before_late=$(cat "$OUT_DIR/02-before-late-worker.txt")
assert_contains "$before_late" 'WORKSPACE  Alpha · 🟣 1 NEEDS YOU · 🔴 1 FAILED · 🔵 2 WORKING' \
  'BEFORE must fold a late worker into its own project row and recount it'
[ "$(sidebar_rows "$OUT_DIR/02-before-late-worker.txt" | wc -l | tr -d ' ')" = 3 ] \
  || fail 'BEFORE must not grow a sidebar row when a late worker starts'

after_a=$(cat "$OUT_DIR/03-after-a-grouped.txt")
assert_contains "$after_a" 'WORKSPACE  └ Decide the pricing page layout · 🟣 NEEDS YOU' \
  'AFTER-A worker row must carry the human outcome and prominent state'
[ "$(sidebar_rows "$OUT_DIR/03-after-a-grouped.txt" | wc -l | tr -d ' ')" = 10 ] \
  || fail 'AFTER-A must show one row per worker plus one header row per project'
# The grouped reading depends entirely on adjacency: every child row must still
# sit under its own header when nothing has arrived late.
[ "$(sidebar_rows "$OUT_DIR/03-after-a-grouped.txt" | sed -n '1p')" = "$(fm_preview_project_row 'Alpha' "$(project_stats 'Alpha' "${WORKERS[@]}")")" ] \
  || fail 'AFTER-A must open with the first project header row'

after_a_late=$(cat "$OUT_DIR/04-after-a-late-worker.txt")
assert_contains "$after_a_late" 'WORKSPACE  Alpha · 🟣 1 NEEDS YOU · 🔴 1 FAILED · 🔵 2 WORKING' \
  'AFTER-A header row must still recount its project after the late worker'
[ "$(sidebar_rows "$OUT_DIR/04-after-a-late-worker.txt" | tail -1)" = "$(fm_preview_grouped_child 'Fix the crash on the settings page' 🔴 FAILED)" ] \
  || fail 'AFTER-A late worker must be observed at the position Herdr actually gives it'
# The recorded divergence: Herdr appends, so the late Alpha worker lands at
# the bottom of the list, four rows below the last Beta/API Platform row and
# nowhere near its own header.
assert_not_contains "$(sidebar_rows "$OUT_DIR/04-after-a-late-worker.txt" | sed -n '2,5p')" \
  'Fix the crash on the settings page' \
  'AFTER-A late worker must not silently appear inside its own project group'

after_b=$(cat "$OUT_DIR/05-after-b-prefixed.txt")
assert_contains "$after_b" 'WORKSPACE  Beta · Retry the nightly CSV export · 🔴 FAILED' \
  'AFTER-B worker row must carry project, outcome and prominent state together'
[ "$(sidebar_rows "$OUT_DIR/05-after-b-prefixed.txt" | wc -l | tr -d ' ')" = 7 ] \
  || fail 'AFTER-B must show exactly one row per worker and no holder rows'

after_b_late=$(cat "$OUT_DIR/06-after-b-late-worker.txt")
assert_contains "$after_b_late" 'WORKSPACE  Alpha · Fix the crash on the settings page · 🔴 FAILED' \
  'AFTER-B late worker must still name its own project wherever Herdr places it'

# Both candidates keep the view inside a worker identical to today's.
for capture_file in "$OUT_DIR/03-after-a-grouped.txt" "$OUT_DIR/05-after-b-prefixed.txt"; do
  assert_grep '  TAB      WORKER · Decide the onboarding welcome copy · 🟣 NEEDS YOU' \
    "$capture_file" "worker tab title must be unchanged from today in $capture_file"
  assert_grep '  DETAIL   claude/opus-5 · fm/beta-onboarding-copy-k4' \
    "$capture_file" "worker detail row must be unchanged from today in $capture_file"
done

pass 'real Herdr staging captured the current project-grouped layout and both one-worker-per-workspace candidates at eight workers across three projects'
