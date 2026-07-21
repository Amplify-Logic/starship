#!/usr/bin/env bash
# Focused behavior coverage for authoritative Herdr worker presentation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-visible-status)
HOME_FIX="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/herdr.log"
STATES="$TMP_ROOT/states"
mkdir -p "$HOME_FIX/state" "$HOME_FIX/data" "$TMP_ROOT/worktrees"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_VISIBLE_HERDR_LOG"
exit 0
SH
cat > "$FAKEBIN/pi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKEBIN/herdr" "$FAKEBIN/pi"

make_worktree() {  # <name> <branch-or-detached>
  local wt="$TMP_ROOT/worktrees/$1"
  fm_git_init_commit "$wt"
  if [ "$2" = detached ]; then
    git -C "$wt" checkout -q --detach
  else
    git -C "$wt" checkout -qb "$2"
  fi
  printf '%s' "$wt"
}

write_task() {  # <id> <project-key> <project-name> <ws> <tab> <pane> <wt> <kind> <harness> <model> [managed]
  fm_write_meta "$HOME_FIX/state/$1.meta" \
    "window=fm-lab-visible:$6" \
    "worktree=$7" \
    "project=$2" \
    "harness=$9" \
    "model=${10}" \
    "kind=$8" \
    "backend=herdr" \
    "herdr_session=fm-lab-visible" \
    "herdr_workspace_id=$4" \
    "herdr_tab_id=$5" \
    "herdr_pane_id=$6" \
    "herdr_workspace_managed=${11:-1}" \
    "herdr_project_name=$3" \
    "herdr_project_key=$2"
}

JOURNEY_SHIP=$(make_worktree journey-ship fm/journey-release-q7)
JOURNEY_SCOUT=$(make_worktree journey-scout detached)
ATELIER_BLOCK=$(make_worktree atelier-block fm/atelier-block-p2)
ATELIER_FAIL=$(make_worktree atelier-fail fm/atelier-fail-z9)
ATELIER_PAUSE=$(make_worktree atelier-pause fm/atelier-pause-r2)
ATELIER_READY=$(make_worktree atelier-ready fm/atelier-ready-r8)
LEGACY_WT=$(make_worktree legacy fm/legacy-k1)
write_task journey-ship /projects/city-guide 'City Guide' w1 t1 w1:p1 "$JOURNEY_SHIP" ship pi default
write_task journey-scout /projects/city-guide 'City Guide' w1 t2 w1:p2 "$JOURNEY_SCOUT" scout codex gpt-5.6
write_task atelier-block /projects/atelier Atelier w2 t3 w2:p1 "$ATELIER_BLOCK" ship pi default
write_task atelier-fail /projects/atelier Atelier w2 t4 w2:p2 "$ATELIER_FAIL" ship codex gpt-5.6
write_task atelier-pause /projects/atelier Atelier w2 t5 w2:p3 "$ATELIER_PAUSE" scout pi default
write_task atelier-ready /projects/atelier Atelier w2 t6 w2:p4 "$ATELIER_READY" ship codex gpt-5.6
write_task legacy-task /projects/legacy 'Legacy Project' oldw oldt oldw:p1 "$LEGACY_WT" ship pi default 0
fm_write_meta "$HOME_FIX/state/secondmate-task.meta" \
  "window=fm-lab-visible:sm:p1" \
  "worktree=$HOME_FIX" \
  "project=$HOME_FIX" \
  "harness=pi" \
  "kind=secondmate" \
  "backend=herdr" \
  "herdr_session=fm-lab-visible" \
  "herdr_workspace_id=smw" \
  "herdr_tab_id=smt" \
  "herdr_pane_id=sm:p1" \
  "home=$HOME_FIX"

cat > "$HOME_FIX/data/backlog.md" <<'EOF'
- [ ] journey-ship - Ship the Journey release (repo: city-guide)
- [ ] journey-scout - Validate the Journey route (repo: city-guide)
- [ ] atelier-block - Unblock Atelier deploy (repo: atelier)
- [ ] atelier-fail - Repair Atelier failure (repo: atelier)
- [ ] atelier-pause - Wait for Atelier upstream (repo: atelier)
- [ ] atelier-ready - Prepare Atelier release (repo: atelier)
- [ ] legacy-task - Refresh legacy task safely (repo: legacy)
EOF
cat > "$STATES" <<'EOF'
journey-ship=working
journey-scout=parked
atelier-block=blocked
atelier-fail=failed
atelier-pause=paused
atelier-ready=done
legacy-task=working
EOF

run_all() {
  : > "$LOG"
  PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_VISIBLE_STATE_FILE="$STATES" \
    FM_VISIBLE_HERDR_LOG="$LOG" \
    FM_BACKEND_HERDR_PRESENTATION_FORCE=1 \
    HERDR_ENV=1 \
    HERDR_SESSION=fm-lab-visible \
    HERDR_PANE_ID=ordinary-worker:p9 \
    "$ROOT/bin/fm-visible-status.sh" --all
}

test_tasks_projects_axes_and_states() {
  local out
  run_all
  out=$(cat "$LOG")
  assert_contains "$out" 'tab rename t1 WORKER · Ship the Journey release · 🔵 WORKING' \
    'Pi ship did not receive the worker contract'
  assert_contains "$out" 'tab rename t2 WORKER · Validate the Journey route · 🟣 NEEDS YOU' \
    'Codex scout did not receive the same worker contract'
  assert_contains "$out" '--display-agent pi · fm/journey-release-q7' \
    'Pi runtime or named branch was not projected'
  assert_contains "$out" '--display-agent codex/gpt-5.6 · detached' \
    'Codex model or detached scout state was not projected'
  assert_contains "$out" 'workspace rename w1 City Guide · 🟣 1 NEEDS YOU · 🔵 1 WORKING' \
    'Journey tasks did not aggregate in one human project workspace'
  assert_contains "$out" 'workspace rename w2 Atelier · 🔴 1 FAILED · 🟠 1 BLOCKED · 🟡 1 WAITING · 🟢 1 READY' \
    'authoritative states were not prioritized for the concurrent Atelier project'
  assert_contains "$out" '--token fm_task_id=journey-ship' \
    'hidden durable task identity was not preserved'
  assert_not_contains "$out" 'tab rename t1 fm-journey-ship' \
    'durable task id leaked into a new human-facing tab'
  pass 'visible status: concurrent projects, ship/scout, Pi/Codex, outcomes, runtime/model, branches, and authoritative states'
}

test_legacy_refresh_and_primary_boundary() {
  local out
  run_all
  out=$(cat "$LOG")
  assert_contains "$out" 'tab rename oldt WORKER · Refresh legacy task safely · 🔵 WORKING' \
    'legacy task was not safely refreshed by recorded tab id'
  assert_not_contains "$out" 'workspace rename oldw' \
    'legacy mixed workspace was renamed to one task project'
  assert_not_contains "$out" 'FIRSTMATE' \
    'ordinary worker environment acquired the primary role'
  assert_not_contains "$out" 'ordinary-worker:p9' \
    'worker environment pane was mistaken for the primary pane'
  pass 'visible status: legacy mixed workspace stays in place and worker environments never project FIRSTMATE'
}

test_secondmate_keeps_legacy_presentation() {
  local out
  run_all
  out=$(cat "$LOG")
  assert_not_contains "$out" 'tab rename smt' \
    'a secondmate tab was renamed to the WORKER convention'
  assert_not_contains "$out" 'sm:p1' \
    'a secondmate pane received worker presentation metadata'
  pass 'visible status: kind=secondmate keeps its legacy fm-<id> tab untouched'
}

test_incapable_build_projects_nothing() {
  : > "$LOG"
  PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_VISIBLE_STATE_FILE="$STATES" \
    FM_VISIBLE_HERDR_LOG="$LOG" \
    FM_BACKEND_HERDR_PRESENTATION_FORCE=0 \
    HERDR_SESSION=fm-lab-visible \
    "$ROOT/bin/fm-visible-status.sh" --all
  [ -s "$LOG" ] && fail 'a below-capability Herdr build still received presentation calls'
  pass 'visible status: below the presentation capability no tab or workspace is touched'
}

test_cleanup_keeps_stable_target_fallback() {
  : > "$LOG"
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FIX" FM_VISIBLE_HERDR_LOG="$LOG" \
    FM_BACKEND_HERDR_PRESENTATION_FORCE=1 \
    "$ROOT/bin/fm-visible-status.sh" --clear journey-ship
  assert_contains "$(cat "$LOG")" '--clear-title --clear-display-agent --clear-state-labels' \
    'cleanup did not clear presentation metadata'
  assert_contains "$(cat "$LOG")" 'tab rename t1 fm-journey-ship' \
    'cleanup did not restore the legacy readable fallback before endpoint close'
  [ -f "$HOME_FIX/state/journey-ship.meta" ] || fail 'presentation cleanup changed durable task metadata'
  pass 'visible status: cleanup clears cosmetics while preserving stable metadata and a legacy title fallback'
}

test_genuine_primary_and_lab_are_structural() {
  local out
  : > "$LOG"
  if ! out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FIX" FM_PRIMARY_DRY_RUN=1 \
    FM_VISIBLE_HERDR_LOG="$LOG" HERDR_ENV=1 HERDR_SESSION=fm-lab-visible \
    HERDR_PANE_ID=primary:p1 "$ROOT/bin/fm-primary.sh" pi 2>&1); then
    fail "genuine primary dry-run failed: $out"
  fi
  assert_contains "$out" 'role=FIRSTMATE' \
    'genuine primary launcher did not establish FIRSTMATE identity'

  : > "$LOG"
  if ! out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FIX" FM_PRIMARY_DRY_RUN=1 \
    FM_PRIMARY_VISIBLE_PREFIX=LAB FM_VISIBLE_HERDR_LOG="$LOG" HERDR_ENV=1 \
    HERDR_SESSION=fm-lab-visible HERDR_PANE_ID=lab:p1 "$ROOT/bin/fm-primary.sh" pi 2>&1); then
    fail "lab primary dry-run failed: $out"
  fi
  assert_contains "$out" 'role=LAB · PRIMARY' \
    'guarded lab did not remain visibly LAB'
  assert_not_contains "$out" 'role=FIRSTMATE' \
    'guarded lab acquired captain-facing primary identity'
  pass 'primary boundary: only the primary launcher emits FIRSTMATE and guarded experiments remain LAB'
}

test_cursor_live_footer_relabels_runtime_over_meta() {
  local wt catalog out meta
  wt=$(make_worktree cursor-live fm/cursor-live-m1)
  catalog="$TMP_ROOT/cursor-models.txt"
  cat > "$catalog" <<'EOF'
Available models
cursor-grok-4.5-medium-fast - Cursor Grok 4.5 Medium Fast
gpt-5.6-sol-xhigh - GPT-5.6 Sol 1M Extra High
EOF
  # Meta claims sol-xhigh (the atelier-local-services-run-d1 shape); the pane
  # footer shows the account-default Grok the worker actually ran.
  write_task cursor-live /projects/atelier Atelier w3 t7 w3:p7 "$wt" scout cursor gpt-5.6-sol-xhigh
  meta="$HOME_FIX/state/cursor-live.meta"
  printf 'cursor-live=working\n' >> "$STATES"
  : > "$LOG"
  PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_VISIBLE_STATE_FILE="$STATES" \
    FM_VISIBLE_HERDR_LOG="$LOG" \
    FM_BACKEND_HERDR_PRESENTATION_FORCE=1 \
    FM_CURSOR_MODEL_CATALOG="$catalog" \
    FM_VISIBLE_PANE_CAPTURE=$'READY1\n\n  → Add a follow-up\n\n  Cursor Grok 4.5 Medium Fast · 7%                                   Run Everything\n' \
    HERDR_ENV=1 \
    HERDR_SESSION=fm-lab-visible \
    "$ROOT/bin/fm-visible-status.sh" cursor-live
  out=$(cat "$LOG")
  assert_contains "$out" '--display-agent cursor/cursor-grok-4.5-medium-fast · fm/cursor-live-m1' \
    'cursor live footer did not replace the recorded spawn model in the label'
  assert_not_contains "$out" 'gpt-5.6-sol-xhigh' \
    'recorded spawn model leaked into the cursor live label'
  assert_grep 'model_live=cursor-grok-4.5-medium-fast' "$meta" \
    'model_live was not recorded when the pane disagreed with meta'
  assert_grep 'model=gpt-5.6-sol-xhigh' "$meta" \
    'live relabel must preserve the original model= audit value'
  pass 'visible status: cursor live footer relabels runtime over meta model='
}

test_cursor_busy_pane_keeps_meta_model() {
  local wt catalog out
  wt=$(make_worktree cursor-busy fm/cursor-busy-m2)
  catalog="$TMP_ROOT/cursor-models-busy.txt"
  cat > "$catalog" <<'EOF'
Available models
gpt-5.6-sol-xhigh - GPT-5.6 Sol 1M Extra High
EOF
  write_task cursor-busy /projects/atelier Atelier w3 t8 w3:p8 "$wt" ship cursor gpt-5.6-sol-xhigh
  printf 'cursor-busy=working\n' >> "$STATES"
  : > "$LOG"
  PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_VISIBLE_STATE_FILE="$STATES" \
    FM_VISIBLE_HERDR_LOG="$LOG" \
    FM_BACKEND_HERDR_PRESENTATION_FORCE=1 \
    FM_CURSOR_MODEL_CATALOG="$catalog" \
    FM_VISIBLE_PANE_CAPTURE=$'  → Add a follow-up                                          ctrl+c to stop\n  1 task\n' \
    HERDR_ENV=1 \
    HERDR_SESSION=fm-lab-visible \
    "$ROOT/bin/fm-visible-status.sh" cursor-busy
  out=$(cat "$LOG")
  assert_contains "$out" '--display-agent cursor/gpt-5.6-sol-xhigh · fm/cursor-busy-m2' \
    'busy cursor pane without a model footer must keep the meta model label'
  pass 'visible status: busy cursor pane without footer model keeps meta'
}

test_tasks_projects_axes_and_states
test_legacy_refresh_and_primary_boundary
test_secondmate_keeps_legacy_presentation
test_incapable_build_projects_nothing
test_cleanup_keeps_stable_target_fallback
test_genuine_primary_and_lab_are_structural
test_cursor_live_footer_relabels_runtime_over_meta
test_cursor_busy_pane_keeps_meta_model
