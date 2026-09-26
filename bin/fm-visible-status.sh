#!/usr/bin/env bash
# Project authoritative Firstmate task details onto Herdr presentation metadata.
#
# Usage:
#   fm-visible-status.sh --all [--republish]
#   fm-visible-status.sh <task-id>
#   fm-visible-status.sh --clear <task-id>
#
# --all is a bounded, single-flight pass and never a nested one:
#   - Every backend round trip (tab rename, pane metadata, workspace rename,
#     cursor pane capture) and the authoritative-state read run under
#     fm-timeout-lib.sh, bounded by FM_VISIBLE_CALL_TIMEOUT seconds (default 5).
#   - Each task is additionally bounded by FM_VISIBLE_TASK_TIMEOUT seconds
#     (default 15) and the whole pass by FM_VISIBLE_PASS_TIMEOUT seconds
#     (default 120). A task the pass did not reach keeps its previous published
#     label and is published by the next pass.
#   - A task whose computed label equals the one last published for it skips
#     the tab and label calls, keeping only the primary-role clear and its
#     fm_state restore (see update_task). The last published label lives in
#     state/<id>.visible-label, a workspace's in state/.visible-workspace-<id>;
#     both are pure presentation caches, safe to delete (that forces one full
#     republish). --republish ignores them, which is what a recovery pass after
#     a backend restart wants. A single-task refresh always publishes and only
#     updates those records, so --republish means nothing there.
#   - One pass at a time per home: a second --all exits immediately while
#     state/.visible-status-all.lock is held by a live pass, and the exported
#     FM_VISIBLE_STATUS_ALL_ACTIVE guard makes a nested --all a no-op.
#   - The authoritative state of each task is read at most once per pass, and
#     each managed workspace is renamed at most once per pass, so a pass costs
#     O(tasks) reads rather than O(tasks x tasks).
#
# New managed tabs read:
#   WORKER · <human outcome> · <authoritative state>
# Pane detail reads:
#   <runtime/model> · <actual branch or detached>
# Project workspaces retain their human project name and add prioritized task
# counts. A workspace shared by tasks of several projects reads
# "Firstmate · <counts>" over all of them instead of any one project's name.
#
# For cursor workers, runtime/model prefers the live idle-footer model parsed
# from the pane (bin/fm-cursor-model-lib.sh) over meta model= when readable, and
# records model_live= on the task meta when the live label differs from the
# recorded spawn model. Busy panes without a model footer keep the meta value.
#
# This is presentation only.
# Every operational action continues to use recorded Herdr ids.
# Herdr API failures are therefore best-effort and never make task control fail.
# State comes only from fm-crew-state.sh.
# A kind=secondmate task keeps its legacy fm-<id> tab and is never restyled.
# On a Herdr build below the verified presentation protocol this script exits
# without touching any tab or workspace, so legacy fm-<id> labels survive.
# This script never projects FIRSTMATE or LAB roles: bin/fm-primary.sh owns the
# structurally guarded primary surface, and lab identity remains lab-owned.
# Publishing a worker pane also clears any role bin/fm-primary.sh left on it.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)}
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
SOURCE=firstmate-worker-visible-v1
# The source bin/fm-primary.sh marks its own pane with.
PRIMARY_SOURCE=firstmate-primary-visible-v1

# fm_backend_herdr_presentation_capable owns the capability verdict shared
# with fm-spawn.sh's herdr arm.
# shellcheck source=bin/backends/herdr.sh
. "$SCRIPT_DIR/backends/herdr.sh"
# shellcheck source=bin/fm-cursor-model-lib.sh
. "$SCRIPT_DIR/fm-cursor-model-lib.sh"
# fm_visible_state, fm_visible_icon and fm_visible_aggregate own the
# captain-facing state vocabulary shared with the layout preview.
# shellcheck source=bin/fm-visible-format-lib.sh
. "$SCRIPT_DIR/fm-visible-format-lib.sh"
# fm_run_timed owns bounded execution, so no backend round trip here can
# outlive its deadline and starve a caller that is holding a liveness budget.
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

ALL_LOCK="$STATE/.visible-status-all.lock"
REPUBLISH=0
BATCH=0
TASK_START=
# A non-positive value is not a bound (fm-timeout-lib.sh), so an unusable
# setting falls back to the default rather than silently removing the deadline.
positive_seconds() {  # <value> <default>
  case "$1" in
    ''|*[!0-9]*|0) printf '%s' "$2" ;;
    *) printf '%s' "$1" ;;
  esac
}
CALL_TIMEOUT=$(positive_seconds "${FM_VISIBLE_CALL_TIMEOUT:-}" 5)
TASK_TIMEOUT=$(positive_seconds "${FM_VISIBLE_TASK_TIMEOUT:-}" 15)
PASS_TIMEOUT=$(positive_seconds "${FM_VISIBLE_PASS_TIMEOUT:-}" 120)

# next_bound: seconds the next backend call may take, the smallest of the
# per-call bound and whatever is left of the task and pass deadlines. Returns
# non-zero when a deadline is already spent, which is the caller's signal to
# stop rather than to run an unbounded call.
next_bound() {
  local budget=$CALL_TIMEOUT left
  if [ -n "$TASK_START" ]; then
    left=$((TASK_TIMEOUT - (SECONDS - TASK_START)))
    [ "$left" -lt "$budget" ] && budget=$left
  fi
  if [ "$BATCH" -eq 1 ]; then
    left=$((PASS_TIMEOUT - SECONDS))
    [ "$left" -lt "$budget" ] && budget=$left
  fi
  [ "$budget" -gt 0 ] || return 1
  printf '%s' "$budget"
}

# The cache bounds the cost of the fleet-wide pass. A single-task refresh is
# already a bounded, deliberate point in a task's lifecycle - a spawn, a
# relaunch, a push transition - and its caller expects the projection to happen,
# so it always publishes and then records what it published.
skip_unchanged() {
  [ "$BATCH" -eq 1 ] && [ "$REPUBLISH" -eq 0 ]
}

pass_exhausted() {
  [ "$BATCH" -eq 1 ] || return 1
  [ "$SECONDS" -ge "$PASS_TIMEOUT" ]
}

# bounded: run one backend round trip under the current deadline. Exit status
# is the command's own, 124 when the bound was hit, and 124 when no budget was
# left to spend.
bounded() {  # <command...>
  local budget
  budget=$(next_bound) || return 124
  fm_run_timed "$budget" "$@"
}

# bounded_shell: the same bound for a shell FUNCTION. fm_run_timed's external
# mechanisms exec the command in a fresh process where this shell's functions
# do not exist, so a function goes through fm-timeout-lib.sh's subshell runner,
# which keeps them visible and still bounds the whole process group.
bounded_shell() {  # <shell-function> [args...]
  local budget
  budget=$(next_bound) || return 124
  fm_run_bash_timeout "$budget" "$@"
}

usage() {
  sed -n '2,/^set -u$/s/^# \{0,1\}//p' "$0"
}

meta_value() {  # <meta> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1
}

one_line() {  # <text>
  printf '%s' "$1" | tr '\r\n\t' '   ' | tr -s ' ' | sed 's/^ *//; s/ *$//'
}

project_slug() {  # <meta>
  local project
  project=$(meta_value "$1" project)
  basename "$project"
}

project_name() {  # <meta>
  local explicit slug
  explicit=$(meta_value "$1" herdr_project_name)
  if [ -n "$explicit" ]; then
    one_line "$explicit"
    return 0
  fi
  slug=$(project_slug "$1")
  "$SCRIPT_DIR/fm-project-display-name.sh" "$slug"
}

project_key() {  # <meta>
  local explicit project
  explicit=$(meta_value "$1" herdr_project_key)
  [ -n "$explicit" ] && { printf '%s' "$explicit"; return 0; }
  project=$(meta_value "$1" project)
  if [ -d "$project" ]; then
    (CDPATH='' cd -- "$project" && pwd -P)
  else
    printf '%s' "$project"
  fi
}

human_outcome() {  # <id> <meta>
  "$SCRIPT_DIR/fm-task-outcome.sh" "$1" "$(meta_value "$2" outcome)"
}

read_canonical_state() {  # <id>
  local id=$1 line
  if [ -n "${FM_VISIBLE_STATE_FILE:-}" ] && [ -f "$FM_VISIBLE_STATE_FILE" ]; then
    line=$(sed -n "s/^$id=//p" "$FM_VISIBLE_STATE_FILE" | tail -1)
    [ -z "$line" ] || { printf '%s' "${line#state: }" | cut -d' ' -f1; return 0; }
  fi
  line=$(bounded env "FM_CREW_STATE_NM_TIMEOUT=${FM_VISIBLE_NM_TIMEOUT:-2}" \
    "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null || true)
  line=${line#state: }
  printf '%s' "${line%% · *}"
}

# One authoritative read per task per process. A project's aggregate counts
# every managed task in that project, so without this memo a pass over N tasks
# would read state N + N x N times, which is what made a large fleet's refresh
# run for minutes. Bash 3.2 has no associative arrays, so the memo is a
# newline-delimited "<id>=<state>" string; an empty state is stored as "-" so a
# recorded miss is not re-read on every project aggregate.
# It publishes into CANONICAL_STATE rather than standard output, because a
# command substitution would run - and discard - the memo in a subshell.
STATE_MEMO=$'\n'
CANONICAL_STATE=
canonical_state() {  # <id>
  local id=$1 rest state
  case "$STATE_MEMO" in
    *$'\n'"$id="*)
      rest=${STATE_MEMO#*$'\n'"$id="}
      state=${rest%%$'\n'*}
      [ "$state" != - ] || state=
      CANONICAL_STATE=$state
      return 0
      ;;
  esac
  state=$(read_canonical_state "$id")
  STATE_MEMO="$STATE_MEMO$id=${state:--}"$'\n'
  CANONICAL_STATE=$state
}

# cursor_pane_capture: plain-text pane tail for live model parsing.
# FM_VISIBLE_PANE_CAPTURE overrides the capture (tests); otherwise reads the
# herdr pane via the shared backend helper.
cursor_pane_capture() {  # <session> <pane>
  local session=$1 pane=$2
  if [ -n "${FM_VISIBLE_PANE_CAPTURE:-}" ]; then
    printf '%s' "$FM_VISIBLE_PANE_CAPTURE"
    return 0
  fi
  if [ -n "${FM_VISIBLE_PANE_CAPTURE_FILE:-}" ] && [ -f "$FM_VISIBLE_PANE_CAPTURE_FILE" ]; then
    cat "$FM_VISIBLE_PANE_CAPTURE_FILE"
    return 0
  fi
  [ -n "$session" ] && [ -n "$pane" ] || return 1
  # The only per-pane read in this script, and only for cursor workers; it is
  # bounded like every other backend round trip.
  bounded_shell fm_backend_herdr_capture "${session}:${pane}" 40 2>/dev/null
}

# record_model_live: upsert model_live=<token> on <meta> when the live label
# differs from the recorded spawn model. No-op when they already match or the
# live token is empty. Best-effort: never fails the presentation refresh.
record_model_live() {  # <meta> <live-token> <recorded-model>
  local meta=$1 live=$2 recorded=$3 tmp
  [ -n "$live" ] || return 0
  [ -f "$meta" ] || return 0
  if [ -n "$recorded" ] && [ "$recorded" != default ] \
    && fm_cursor_models_equivalent "$recorded" "$live"; then
    # Clear a stale model_live= from an earlier mismatch once they agree again.
    if grep -q '^model_live=' "$meta" 2>/dev/null; then
      tmp=$(mktemp "$meta.XXXXXX") || return 0
      grep -v '^model_live=' "$meta" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
      mv "$tmp" "$meta"
    fi
    return 0
  fi
  if [ "$(meta_value "$meta" model_live)" = "$live" ]; then
    return 0
  fi
  tmp=$(mktemp "$meta.XXXXXX") || return 0
  grep -v '^model_live=' "$meta" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  printf 'model_live=%s\n' "$live" >> "$tmp"
  mv "$tmp" "$meta"
}

runtime_text() {  # <meta>
  local harness model live session pane cap display label
  harness=$(meta_value "$1" harness)
  model=$(meta_value "$1" model)
  [ -n "$harness" ] || harness=unknown
  if [ "$harness" = cursor ]; then
    session=$(meta_value "$1" herdr_session)
    pane=$(meta_value "$1" herdr_pane_id)
    cap=$(cursor_pane_capture "$session" "$pane" 2>/dev/null || true)
    display=$(fm_cursor_parse_footer_model "$cap")
    if [ -n "$display" ]; then
      label=$(fm_cursor_runtime_label "$display")
      record_model_live "$1" "$label" "$model"
      printf '%s/%s' "$harness" "$label"
      return 0
    fi
    live=$(meta_value "$1" model_live)
    if [ -n "$live" ]; then
      printf '%s/%s' "$harness" "$live"
      return 0
    fi
  fi
  if [ -n "$model" ] && [ "$model" != default ]; then
    printf '%s/%s' "$harness" "$model"
  else
    printf '%s' "$harness"
  fi
}

actual_branch() {  # <worktree>
  local branch
  branch=$(git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$branch" ] && printf '%s' "$branch" || printf 'detached'
}

herdr_call() {  # <session> <args...>
  local session=$1
  shift
  bounded env "HERDR_SESSION=$session" herdr "$@" --session "$session"
}

# Last-published label records. Presentation caches only: deleting one costs a
# redundant republish and nothing else, so every write here is best-effort.
task_label_record() {  # <task-id>
  printf '%s/%s.visible-label' "$STATE" "$1"
}

workspace_label_record() {  # <workspace-id>
  printf '%s/.visible-workspace-%s' "$STATE" \
    "$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"
}

# Drop the records of tasks and workspaces this home no longer has, so a long
# lived home does not accumulate them. Teardown clears a retired task through
# --clear; this is the sweep for anything that vanished another way.
prune_label_records() {
  local record id meta workspaces="" ws
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    ws=$(meta_value "$meta" herdr_workspace_id)
    [ -z "$ws" ] || workspaces="$workspaces$(workspace_label_record "$ws")"$'\n'
  done
  for record in "$STATE"/*.visible-label; do
    [ -f "$record" ] || continue
    id=$(basename "$record" .visible-label)
    [ -f "$STATE/$id.meta" ] || rm -f "$record"
  done
  for record in "$STATE"/.visible-workspace-*; do
    [ -f "$record" ] || continue
    case "$workspaces" in
      *"$record"$'\n'*) ;;
      *) rm -f "$record" ;;
    esac
  done
}

# The label a shared workspace carries when the managed tasks in it belong to
# more than one project. Herdr can place several projects' workers in one
# workspace, and naming it after any one of them mislabels every other row.
MIXED_WORKSPACE_NAME=Firstmate

# workspace_label: the label for one managed workspace, from every managed
# non-secondmate task recorded in it. A single-project workspace reads
# "<project name> · <counts>"; a workspace shared by several projects reads
# "$MIXED_WORKSPACE_NAME · <counts>" with the counts over all of its tasks, so
# the label never depends on which project's meta a pass reached first.
# Publishes into WORKSPACE_LABEL, empty when there is nothing to name.
WORKSPACE_LABEL=
workspace_label() {  # <session> <workspace-id>
  local session=$1 workspace=$2 meta id state key name="" first_key="" mixed=0
  local needs=0 failed=0 blocked=0 working=0 waiting=0 ready=0
  WORKSPACE_LABEL=
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    [ "$(meta_value "$meta" backend)" = herdr ] || continue
    [ "$(meta_value "$meta" kind)" != secondmate ] || continue
    [ "$(meta_value "$meta" herdr_workspace_managed)" = 1 ] || continue
    [ "$(meta_value "$meta" herdr_session)" = "$session" ] || continue
    [ "$(meta_value "$meta" herdr_workspace_id)" = "$workspace" ] || continue
    key=$(project_key "$meta")
    [ -n "$key" ] || continue
    if [ -z "$first_key" ]; then
      first_key=$key
      name=$(project_name "$meta")
    elif [ "$key" != "$first_key" ]; then
      mixed=1
    fi
    id=$(basename "$meta" .meta)
    canonical_state "$id"
    state=$(fm_visible_state "$CANONICAL_STATE")
    case "$state" in
      'NEEDS YOU') needs=$((needs + 1)) ;;
      FAILED) failed=$((failed + 1)) ;;
      BLOCKED) blocked=$((blocked + 1)) ;;
      WORKING) working=$((working + 1)) ;;
      WAITING) waiting=$((waiting + 1)) ;;
      READY) ready=$((ready + 1)) ;;
    esac
  done
  [ -n "$first_key" ] || return 0
  [ "$mixed" -eq 0 ] || name=$MIXED_WORKSPACE_NAME
  [ -n "$name" ] || return 0
  WORKSPACE_LABEL="$name · $(fm_visible_aggregate \
    "$needs $failed $blocked $working $waiting $ready")"
}

update_workspace() {  # <session> <workspace-id>
  local session=$1 workspace=$2 label record
  [ -n "$session" ] && [ -n "$workspace" ] || return 0
  workspace_label "$session" "$workspace"
  label=$WORKSPACE_LABEL
  [ -n "$label" ] || return 0
  record=$(workspace_label_record "$workspace")
  if skip_unchanged && [ "$(cat "$record" 2>/dev/null || true)" = "$label" ]; then
    return 0
  fi
  if herdr_call "$session" workspace rename "$workspace" "$label" >/dev/null 2>&1; then
    printf '%s\n' "$label" > "$record" 2>/dev/null || true
  fi
}

# One rename per managed workspace per pass, however many tasks or projects it
# holds. Renaming once per project let projects sharing a workspace overwrite
# each other's label, so the last one relabelled named every worker in it.
update_workspaces() {
  local meta session workspace seen=$'\n'
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    pass_exhausted && break
    [ "$(meta_value "$meta" backend)" = herdr ] || continue
    [ "$(meta_value "$meta" kind)" != secondmate ] || continue
    [ "$(meta_value "$meta" herdr_workspace_managed)" = 1 ] || continue
    session=$(meta_value "$meta" herdr_session)
    workspace=$(meta_value "$meta" herdr_workspace_id)
    case "$seen" in *$'\n'"$session"$'\t'"$workspace"$'\n'*) continue ;; esac
    seen="$seen$session"$'\t'"$workspace"$'\n'
    update_workspace "$session" "$workspace"
  done
}

update_task() {  # <task-id>
  local id=$1 meta session tab pane state icon title detail outcome runtime branch
  local record published=1
  meta="$STATE/$id.meta"
  [ -f "$meta" ] || return 0
  [ "$(meta_value "$meta" backend)" = herdr ] || return 0
  [ "$(meta_value "$meta" kind)" != secondmate ] || return 0
  session=$(meta_value "$meta" herdr_session)
  tab=$(meta_value "$meta" herdr_tab_id)
  pane=$(meta_value "$meta" herdr_pane_id)
  [ -n "$session" ] && [ -n "$tab" ] && [ -n "$pane" ] || return 0
  TASK_START=$SECONDS
  canonical_state "$id"
  state=$(fm_visible_state "$CANONICAL_STATE")
  icon=$(fm_visible_icon "$state")
  outcome=$(human_outcome "$id" "$meta")
  runtime=$(runtime_text "$meta")
  branch=$(actual_branch "$(meta_value "$meta" worktree)")
  # bin/fm-visible-title.sh is the single owner of this format, so the tab a
  # worker is spawned with and the tab this refresh renames it to cannot drift.
  title=$("$SCRIPT_DIR/fm-visible-title.sh" "$outcome" "$icon $state")
  detail="$runtime · $branch"
  # A worker pane is never the primary, so drop any role the primary launcher
  # marked onto it. Herdr keeps each source's fields until that source clears
  # them, so without this a worker that once ran bin/fm-primary.sh in its own
  # pane would keep the FIRSTMATE role token beside its worker label. The
  # label record below cannot see that marker, so this clear runs even on a
  # pass that skips an unchanged label: a marker landing after the label was
  # cached is gone by the next ordinary pass, not only after a --republish.
  herdr_call "$session" pane report-metadata "$pane" \
    --source "$PRIMARY_SOURCE" \
    --clear-title \
    --clear-display-agent \
    --clear-state-labels \
    --clear-token fm_role \
    --clear-token fm_state >/dev/null 2>&1 || published=0
  # Everything the tab and the pane display is derived from these three
  # values, so an identical triple means the backend already shows this label
  # and the two round trips below would change nothing.
  record=$(task_label_record "$id")
  if skip_unchanged \
    && [ "$(cat "$record" 2>/dev/null || true)" = "$title"$'\t'"$detail"$'\t'"$icon $state" ]; then
    # Herdr tokens are keyed by name, not source, so the clear above also
    # dropped this worker's own fm_state; put it back.
    herdr_call "$session" pane report-metadata "$pane" \
      --source "$SOURCE" \
      --token "fm_state=$state" >/dev/null 2>&1 || true
    TASK_START=
    return 0
  fi
  herdr_call "$session" tab rename "$tab" "$title" >/dev/null 2>&1 || published=0
  herdr_call "$session" pane report-metadata "$pane" \
    --source "$SOURCE" \
    --title "$title" \
    --display-agent "$detail" \
    --state-label "working=$icon $state" \
    --state-label "blocked=$icon $state" \
    --state-label "idle=$icon $state" \
    --state-label "done=$icon $state" \
    --token "fm_task_id=$id" \
    --token "fm_runtime=$runtime" \
    --token "fm_branch=$branch" \
    --token "fm_state=$state" >/dev/null 2>&1 || published=0
  # Only a fully published label is remembered: a timed-out or failed round
  # trip leaves the record alone so the next pass publishes this task again.
  if [ "$published" -eq 1 ]; then
    printf '%s\n' "$title"$'\t'"$detail"$'\t'"$icon $state" > "$record" 2>/dev/null || true
  fi
  TASK_START=
  [ "$BATCH" -eq 1 ] || [ "$(meta_value "$meta" herdr_workspace_managed)" != 1 ] \
    || update_workspace "$session" "$(meta_value "$meta" herdr_workspace_id)"
}

clear_task() {  # <task-id>
  local id=$1 meta session tab pane
  rm -f "$(task_label_record "$id")"
  meta="$STATE/$id.meta"
  [ -f "$meta" ] || return 0
  [ "$(meta_value "$meta" backend)" = herdr ] || return 0
  session=$(meta_value "$meta" herdr_session)
  tab=$(meta_value "$meta" herdr_tab_id)
  pane=$(meta_value "$meta" herdr_pane_id)
  if [ -n "$session" ] && [ -n "$pane" ]; then
    herdr_call "$session" pane report-metadata "$pane" \
      --source "$SOURCE" \
      --clear-title \
      --clear-display-agent \
      --clear-state-labels \
      --clear-token fm_task_id \
      --clear-token fm_runtime \
      --clear-token fm_branch \
      --clear-token fm_state >/dev/null 2>&1 || true
  fi
  [ -z "$session" ] || [ -z "$tab" ] \
    || herdr_call "$session" tab rename "$tab" "fm-$id" >/dev/null 2>&1 \
    || true
}

# refresh_all: one bounded pass over every recorded task, then one rename per
# managed workspace, then the record sweep. A spent pass deadline stops the
# pass where it is: the unreached tasks keep their previous published label and
# the next pass, which starts from a fresh deadline, publishes them.
refresh_all() {
  local meta
  BATCH=1
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    pass_exhausted && break
    update_task "$(basename "$meta" .meta)"
  done
  update_workspaces
  prune_label_records
}

MODE=
ARG=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --republish) REPUBLISH=1 ;;
    --all) [ -z "$MODE" ] || { usage >&2; exit 2; }; MODE=all ;;
    --clear)
      [ -z "$MODE" ] || { usage >&2; exit 2; }
      MODE=clear
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      shift
      ARG=$1
      ;;
    --*) usage >&2; exit 2 ;;
    *)
      [ -z "$MODE" ] || { usage >&2; exit 2; }
      MODE=task
      ARG=$1
      ;;
  esac
  shift
done

case "$MODE" in
  '') usage ;;
  all)
    # Never recurse. The guard is exported, so a child process that reaches
    # this script again during a pass exits instead of starting a second one.
    [ "${FM_VISIBLE_STATUS_ALL_ACTIVE:-0}" = 1 ] && exit 0
    export FM_VISIBLE_STATUS_ALL_ACTIVE=1
    fm_backend_herdr_presentation_capable || exit 0
    if ! declare -F fm_lock_try_acquire >/dev/null 2>&1; then
      # shellcheck source=bin/fm-wake-lib.sh
      . "$SCRIPT_DIR/fm-wake-lib.sh"
    fi
    # Single flight per home: a pass already under way is doing this work, and
    # a second one would only queue more backend round trips behind it. The
    # lock's own dead-owner reclaim keeps a killed pass from wedging the next.
    fm_lock_try_acquire "$ALL_LOCK" || exit 0
    trap 'fm_lock_release "$ALL_LOCK"' EXIT
    trap 'fm_lock_release "$ALL_LOCK"; exit 143' INT TERM
    refresh_all
    ;;
  clear)
    fm_backend_herdr_presentation_capable || exit 0
    clear_task "$ARG"
    ;;
  task)
    fm_backend_herdr_presentation_capable || exit 0
    update_task "$ARG"
    ;;
esac
