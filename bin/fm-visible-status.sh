#!/usr/bin/env bash
# Project authoritative Firstmate task details onto Herdr presentation metadata.
#
# Usage:
#   fm-visible-status.sh --all
#   fm-visible-status.sh <task-id>
#   fm-visible-status.sh --clear <task-id>
#
# New managed tabs read:
#   WORKER · <human outcome> · <authoritative state>
# Pane detail reads:
#   <runtime/model> · <actual branch or detached>
# Project workspaces retain their human project name and add prioritized task
# counts.
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
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)}
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
SOURCE=firstmate-worker-visible-v1

# fm_backend_herdr_presentation_capable owns the capability verdict shared
# with fm-spawn.sh's herdr arm.
# shellcheck source=bin/backends/herdr.sh
. "$SCRIPT_DIR/backends/herdr.sh"
# shellcheck source=bin/fm-cursor-model-lib.sh
. "$SCRIPT_DIR/fm-cursor-model-lib.sh"

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

canonical_state() {  # <id>
  local id=$1 line
  if [ -n "${FM_VISIBLE_STATE_FILE:-}" ] && [ -f "$FM_VISIBLE_STATE_FILE" ]; then
    line=$(sed -n "s/^$id=//p" "$FM_VISIBLE_STATE_FILE" | tail -1)
    [ -z "$line" ] || { printf '%s' "${line#state: }" | cut -d' ' -f1; return 0; }
  fi
  line=$(FM_CREW_STATE_NM_TIMEOUT=${FM_VISIBLE_NM_TIMEOUT:-2} \
    "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null || true)
  line=${line#state: }
  printf '%s' "${line%% · *}"
}

visible_state() {  # <canonical-state>
  case "$1" in
    parked) printf 'NEEDS YOU' ;;
    failed) printf 'FAILED' ;;
    blocked) printf 'BLOCKED' ;;
    working) printf 'WORKING' ;;
    paused) printf 'WAITING' ;;
    done) printf 'READY' ;;
    *) printf 'WAITING' ;;
  esac
}

state_icon() {  # <visible-state>
  case "$1" in
    'NEEDS YOU') printf '🟣' ;;
    FAILED) printf '🔴' ;;
    BLOCKED) printf '🟠' ;;
    WORKING) printf '🔵' ;;
    WAITING) printf '🟡' ;;
    READY) printf '🟢' ;;
  esac
}

state_rank() {  # <visible-state>
  case "$1" in
    'NEEDS YOU') printf 1 ;;
    FAILED) printf 2 ;;
    BLOCKED) printf 3 ;;
    WORKING) printf 4 ;;
    WAITING) printf 5 ;;
    READY) printf 6 ;;
    *) printf 7 ;;
  esac
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
  fm_backend_herdr_capture "${session}:${pane}" 40 2>/dev/null
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
  HERDR_SESSION="$session" herdr "$@" --session "$session"
}

project_stats() {  # <project-key>
  local key=$1 meta id state rank
  local needs=0 failed=0 blocked=0 working=0 waiting=0 ready=0 best=99
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    [ "$(meta_value "$meta" backend)" = herdr ] || continue
    [ "$(meta_value "$meta" herdr_workspace_managed)" = 1 ] || continue
    [ "$(project_key "$meta")" = "$key" ] || continue
    id=$(basename "$meta" .meta)
    state=$(visible_state "$(canonical_state "$id")")
    rank=$(state_rank "$state")
    [ "$rank" -ge "$best" ] || best=$rank
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

aggregate_text() {  # <stats>
  local needs failed blocked working waiting ready part icon count label text=
  read -r needs failed blocked working waiting ready <<EOF
$1
EOF
  for part in \
    "🟣:$needs:NEEDS YOU" \
    "🔴:$failed:FAILED" \
    "🟠:$blocked:BLOCKED" \
    "🔵:$working:WORKING" \
    "🟡:$waiting:WAITING" \
    "🟢:$ready:READY"; do
    IFS=: read -r icon count label <<EOF
$part
EOF
    [ "$count" -gt 0 ] || continue
    text="${text}${text:+ · }$icon $count $label"
  done
  printf '%s' "${text:-no tasks}"
}

update_project() {  # <meta>
  local meta=$1 session workspace key name stats aggregate
  [ "$(meta_value "$meta" herdr_workspace_managed)" = 1 ] || return 0
  session=$(meta_value "$meta" herdr_session)
  workspace=$(meta_value "$meta" herdr_workspace_id)
  key=$(project_key "$meta")
  name=$(project_name "$meta")
  [ -n "$session" ] && [ -n "$workspace" ] && [ -n "$key" ] && [ -n "$name" ] || return 0
  stats=$(project_stats "$key")
  aggregate=$(aggregate_text "$stats")
  herdr_call "$session" workspace rename "$workspace" "$name · $aggregate" >/dev/null 2>&1 || true
}

update_task() {  # <task-id>
  local id=$1 meta session tab pane state icon title detail outcome runtime branch
  meta="$STATE/$id.meta"
  [ -f "$meta" ] || return 0
  [ "$(meta_value "$meta" backend)" = herdr ] || return 0
  [ "$(meta_value "$meta" kind)" != secondmate ] || return 0
  session=$(meta_value "$meta" herdr_session)
  tab=$(meta_value "$meta" herdr_tab_id)
  pane=$(meta_value "$meta" herdr_pane_id)
  [ -n "$session" ] && [ -n "$tab" ] && [ -n "$pane" ] || return 0
  state=$(visible_state "$(canonical_state "$id")")
  icon=$(state_icon "$state")
  outcome=$(human_outcome "$id" "$meta")
  runtime=$(runtime_text "$meta")
  branch=$(actual_branch "$(meta_value "$meta" worktree)")
  title="WORKER · $outcome · $icon $state"
  detail="$runtime · $branch"
  herdr_call "$session" tab rename "$tab" "$title" >/dev/null 2>&1 || true
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
    --token "fm_state=$state" >/dev/null 2>&1 || true
  update_project "$meta"
}

clear_task() {  # <task-id>
  local id=$1 meta session tab pane
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

case "${1:-}" in
  -h|--help|'') usage ;;
  --all)
    fm_backend_herdr_presentation_capable || exit 0
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      update_task "$(basename "$meta" .meta)"
    done
    ;;
  --clear)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    fm_backend_herdr_presentation_capable || exit 0
    clear_task "$2"
    ;;
  --*) usage >&2; exit 2 ;;
  *)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    fm_backend_herdr_presentation_capable || exit 0
    update_task "$1"
    ;;
esac
