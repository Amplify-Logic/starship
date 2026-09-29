#!/usr/bin/env bash
# Resolve one already-matched crew-dispatch rule to a concrete profile.
# Usage:
#   fm-dispatch-select.sh [--select <strategy>] [--task-type <slug>]
#                         [<rule-or-use-json>]
#
# Input may be a full rule object with `use` and optional `select`, a single
# profile object, or an ordered array of profile objects.
# Output is one compact JSON profile object on stdout.
#
# Capability evidence (optional --task-type) layers ON the cost-allowed profile
# set from the input rule: it never invents a harness outside that set and never
# bypasses crew-dispatch / third-party-model guards. bin/fm-capability-lib.sh
# owns the outcome-log wire format, 7-day window, capability-recent ranking, and
# advisory scout-tax suggestion. When --task-type is set, CAPABILITY_EVIDENCE
# lines are printed on stderr for firstmate; ~10% of those dispatches may also
# print one CAPABILITY_SCOUT_TAX suggestion without changing stdout selection.
#
# capability-recent ranks the cost-allowed profile array by recent green density
# for --task-type (see fm-capability-lib.sh). Absent --task-type it degrades to
# the first profile. Absent select still means first array element.
#
# This script never ranks by quota. Firstmate chooses among a quota-sensitive
# profile array by quota-axi's spendPriority through the quota-array-dispatch
# skill, the single ranker. The retired `select: quota-balanced` token still
# loads, so existing config files stay valid; it prints the first profile and a
# stderr note pointing at that skill, and never runs quota-axi.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-capability-lib.sh
. "$SCRIPT_DIR/fm-capability-lib.sh"

SELECT_OVERRIDE=
TASK_TYPE=
ARGS=()

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

log() {
  printf 'fm-dispatch-select: %s\n' "$*" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --select)
      [ "$#" -gt 1 ] || { echo "error: --select requires a value" >&2; exit 2; }
      SELECT_OVERRIDE=$2
      shift 2
      ;;
    --select=*)
      SELECT_OVERRIDE=${1#--select=}
      shift
      ;;
    --task-type)
      [ "$#" -gt 1 ] || { echo "error: --task-type requires a value" >&2; exit 2; }
      TASK_TYPE=$2
      shift 2
      ;;
    --task-type=*)
      TASK_TYPE=${1#--task-type=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        ARGS+=("$1")
        shift
      done
      ;;
    -*)
      echo "error: unknown option $1" >&2
      exit 2
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

[ "${#ARGS[@]}" -le 1 ] || { echo "error: expected at most one JSON argument" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }

if [ "${#ARGS[@]}" -eq 1 ]; then
  SPEC_JSON=${ARGS[0]}
else
  SPEC_JSON=$(cat)
fi

profiles_json=$(printf '%s\n' "$SPEC_JSON" | jq -ec '
  (if type == "object" and has("use") then .use else . end)
  | if type == "array" then .
    elif type == "object" then [.]
    else empty
    end
' 2>/dev/null) || { echo "error: dispatch input must be a rule, profile, or profile array" >&2; exit 2; }

profile_count=$(printf '%s\n' "$profiles_json" | jq 'length')
[ "$profile_count" -gt 0 ] || { echo "error: dispatch profile array must not be empty" >&2; exit 2; }

first_profile() {
  printf '%s\n' "$profiles_json" | jq -c '
    def clean($p):
      {harness: $p.harness}
      + (if ($p.model? | type) == "string" then {model: $p.model} else {} end)
      + (if ($p.effort? | type) == "string" then {effort: $p.effort} else {} end);
    clean(.[0])
  '
}

select_strategy=$SELECT_OVERRIDE
if [ -z "$select_strategy" ]; then
  select_strategy=$(printf '%s\n' "$SPEC_JSON" | jq -r '
    if type == "object" and has("use") and (.select? | type) == "string" then .select else "" end
  ' 2>/dev/null || true)
fi

emit_capability_advisories() {
  local selected=$1
  [ -n "$TASK_TYPE" ] || return 0
  fm_capability_surface_evidence "$TASK_TYPE"
  fm_capability_maybe_scout_tax "$TASK_TYPE" "$selected" "$profiles_json"
}

if [ "$select_strategy" = capability-recent ]; then
  if [ -z "$TASK_TYPE" ]; then
    log "capability-recent without --task-type; using first profile"
    selected=$(first_profile)
  else
    selected=$(fm_capability_pick_profile "$TASK_TYPE" "$profiles_json") \
      || selected=$(first_profile)
  fi
  emit_capability_advisories "$selected"
  printf '%s\n' "$selected"
  exit 0
fi

if [ "$select_strategy" = quota-balanced ]; then
  log "quota-balanced ranking is retired; rank a quota-sensitive profile array by spendPriority through the quota-array-dispatch skill; using first profile"
elif [ -n "$select_strategy" ]; then
  log "unknown select strategy '$select_strategy'; using first profile"
fi
selected=$(first_profile)
emit_capability_advisories "$selected"
printf '%s\n' "$selected"
