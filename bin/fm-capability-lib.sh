#!/usr/bin/env bash
# Capability outcome log helpers: append finished-task evidence and read a
# recency-window summary so dispatch can consult harness/model/effort performance
# per task type without replacing config/crew-dispatch.json cost rules.
#
# This header owns the wire format and selection contracts:
#   - Log path: $FM_HOME/data/capability-outcomes.log (override: FM_CAPABILITY_LOG).
#   - One append-only line per finished ship/scout teardown:
#       <unix-epoch>|<task-type>|<harness>|<model>|<effort>|<outcome>
#     Fields never contain '|' or newlines; invalid fields refuse the append.
#   - Outcomes: green (normal landed teardown) or discarded (--force).
#   - Secondmate teardowns are not recorded (not a worker capability sample).
#   - task-type is a free-form slug from meta task_type= when present, else kind
#     (ship|scout). Firstmate should pass a stable slug at spawn for finer bins.
#   - Reader window: last FM_CAPABILITY_WINDOW_SECS seconds (default 604800 = 7d).
#   - Evidence layers ON cost-allowed profiles only: callers pass the already
#     cost-filtered profile set; this lib never invents a harness outside it and
#     never bypasses third-party-model / crew-dispatch guards.
#   - select=capability-recent ranks allowed profiles by green density
#     (green / (green+discarded)) in the window; a sampled profile outranks an
#     earlier unsampled one only when density > 0; all-zero or absent evidence
#     keeps input (configured) order; no samples for a task-type keep the first.
#   - Scout tax (~10%): advisory CAPABILITY_SCOUT_TAX stderr suggestion of a
#     different allowed profile; never changes the selected stdout profile.
#     FM_CAPABILITY_SCOUT_TAX=0 disables; =1 forces; otherwise a roll
#     FM_CAPABILITY_SCOUT_ROLL (0-99) or $RANDOM%100 fires when roll <
#     FM_CAPABILITY_SCOUT_TAX_RATE (default 10, clamped to 0-100).
#   - FM_CAPABILITY_NOW overrides "now" as a unix epoch for tests.
#   - Portable on bash 3.2 (no associative arrays); aggregation uses awk.
#
# Sourced by fm-teardown.sh and fm-dispatch-select.sh; not a CLI entrypoint.

_FM_CAPABILITY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_CAPABILITY_LIB_DIR="."

fm_capability_log_path() {
  if [ -n "${FM_CAPABILITY_LOG:-}" ]; then
    printf '%s\n' "$FM_CAPABILITY_LOG"
    return 0
  fi
  local home=${FM_HOME:-${FM_ROOT_OVERRIDE:-$_FM_CAPABILITY_LIB_DIR/..}}
  local data=${FM_DATA_OVERRIDE:-$home/data}
  printf '%s\n' "$data/capability-outcomes.log"
}

fm_capability_now() {
  if [ -n "${FM_CAPABILITY_NOW:-}" ]; then
    printf '%s\n' "$FM_CAPABILITY_NOW"
    return 0
  fi
  date +%s
}

fm_capability_window_secs() {
  printf '%s\n' "${FM_CAPABILITY_WINDOW_SECS:-604800}"
}

# Sanitize one log field: refuse empty, '|', or newline-bearing values.
fm_capability_field_ok() {
  local v=$1
  [ -n "$v" ] || return 1
  case "$v" in
    *'|'*) return 1 ;;
  esac
  case "$v" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  return 0
}

# Append one outcome line. Args: task-type harness model effort outcome
# Best-effort: creates data/ as needed; returns non-zero on invalid fields or
# write failure but never blocks teardown callers that ignore the status.
fm_capability_log_append() {
  local task_type=$1 harness=$2 model=$3 effort=$4 outcome=$5
  local log_path ts dir
  case "$outcome" in
    green|discarded) ;;
    *) return 1 ;;
  esac
  fm_capability_field_ok "$task_type" || return 1
  fm_capability_field_ok "$harness" || return 1
  fm_capability_field_ok "$model" || return 1
  fm_capability_field_ok "$effort" || return 1
  log_path=$(fm_capability_log_path)
  dir=$(dirname "$log_path")
  mkdir -p "$dir" || return 1
  ts=$(fm_capability_now)
  fm_capability_field_ok "$ts" || return 1
  printf '%s|%s|%s|%s|%s|%s\n' "$ts" "$task_type" "$harness" "$model" "$effort" "$outcome" >> "$log_path"
}

# Record teardown evidence from already-loaded meta fields.
# Args: kind force_flag harness model effort [task_type]
# force_flag is "--force" or empty. No-ops for secondmate and missing harness.
fm_capability_record_teardown() {
  local kind=$1 force=$2 harness=$3 model=$4 effort=$5 task_type=${6:-}
  local outcome
  [ "$kind" = secondmate ] && return 0
  [ -n "$harness" ] || return 0
  [ -n "$model" ] || model=default
  [ -n "$effort" ] || effort=default
  [ -n "$task_type" ] || task_type=$kind
  [ -n "$task_type" ] || task_type=ship
  if [ "$force" = "--force" ]; then
    outcome=discarded
  else
    outcome=green
  fi
  fm_capability_log_append "$task_type" "$harness" "$model" "$effort" "$outcome" || true
}

# Print recent matching lines for a task-type (stdout), one wire line each.
# Args: task-type
fm_capability_recent_lines() {
  local task_type=$1
  local log_path now window cutoff
  log_path=$(fm_capability_log_path)
  [ -f "$log_path" ] || return 0
  now=$(fm_capability_now)
  window=$(fm_capability_window_secs)
  cutoff=$((now - window))
  awk -F'|' -v cutoff="$cutoff" -v want="$task_type" '
    NF >= 6 && $1 ~ /^[0-9]+$/ && ($1 + 0) >= cutoff && $2 == want { print }
  ' "$log_path"
}

# Summarize green density per harness|model|effort for a task-type.
# Prints lines: <harness>|<model>|<effort>|<green>|<total>|<density_percent>
# sorted by density desc, then total desc, then key asc. Density is integer
# percent (green*100/total). Args: task-type
fm_capability_summarize() {
  local task_type=$1
  fm_capability_recent_lines "$task_type" | awk -F'|' '
    NF >= 6 {
      key = $3 "|" $4 "|" $5
      total[key]++
      if ($6 == "green") green[key]++
    }
    END {
      for (key in total) {
        g = green[key] + 0
        t = total[key]
        d = int(g * 100 / t)
        n = split(key, parts, "|")
        if (n != 3) continue
        printf "%s|%s|%s|%d|%d|%d\n", parts[1], parts[2], parts[3], g, t, d
      }
    }
  ' | sort -t'|' -k6,6nr -k5,5nr -k1,1 -k2,2 -k3,3
}

# Look up density and total for harness|model|effort in summarize output.
# Prints: <density> <total>  (density -1 when absent). Args: summary harness model effort
fm_capability_lookup_density() {
  local summary=$1 harness=$2 model=$3 effort=$4
  local line h m e rest t d
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    h=${line%%|*}
    rest=${line#*|}
    m=${rest%%|*}
    rest=${rest#*|}
    e=${rest%%|*}
    rest=${rest#*|}
    # skip green count
    rest=${rest#*|}
    t=${rest%%|*}
    d=${rest#*|}
    if [ "$h" = "$harness" ] && [ "$m" = "$model" ] && [ "$e" = "$effort" ]; then
      printf '%s %s\n' "$d" "$t"
      return 0
    fi
  done <<EOF
$summary
EOF
  printf '%s %s\n' -1 0
}

# Emit advisory stderr lines for firstmate. Args: task-type
# Prints CAPABILITY_EVIDENCE: lines and, when empty, a single no-samples note.
fm_capability_surface_evidence() {
  local task_type=$1
  local summary_line count=0
  while IFS= read -r summary_line || [ -n "$summary_line" ]; do
    [ -n "$summary_line" ] || continue
    count=$((count + 1))
    printf 'CAPABILITY_EVIDENCE: task-type=%s %s\n' "$task_type" "$summary_line" >&2
  done <<EOF
$(fm_capability_summarize "$task_type")
EOF
  if [ "$count" -eq 0 ]; then
    printf 'CAPABILITY_EVIDENCE: task-type=%s no samples in %ss window\n' \
      "$task_type" "$(fm_capability_window_secs)" >&2
  fi
}

# Clean one profile object from a jq array index to compact JSON.
# Args: profiles_json index
fm_capability_clean_profile_at() {
  local profiles_json=$1 idx=$2
  printf '%s\n' "$profiles_json" | jq -c --argjson i "$idx" '
    def clean($p):
      {harness: $p.harness}
      + (if ($p.model? | type) == "string" then {model: $p.model} else {} end)
      + (if ($p.effort? | type) == "string" then {effort: $p.effort} else {} end);
    clean(.[$i])
  '
}

# Given a jq profile array JSON and task-type, print the best profile JSON by
# recent green density among the cost-allowed profiles. A sampled profile may
# outrank an earlier unsampled profile only when its density is greater than 0;
# all-zero evidence keeps input (configured) order. Ties among positive-density
# profiles prefer higher total, then earlier index. No samples at all keeps the
# first profile. Args: task-type profiles_json
fm_capability_pick_profile() {
  local task_type=$1 profiles_json=$2
  local summary count idx harness model effort density total
  local best_json best_density best_index best_total lookup pick

  summary=$(fm_capability_summarize "$task_type")
  count=$(printf '%s\n' "$profiles_json" | jq 'length')
  if [ "$count" -lt 1 ]; then
    return 1
  fi
  if [ -z "$summary" ]; then
    fm_capability_clean_profile_at "$profiles_json" 0
    return 0
  fi

  best_json=
  best_density=-1
  best_total=-1
  best_index=999999
  idx=0
  while [ "$idx" -lt "$count" ]; do
    harness=$(printf '%s\n' "$profiles_json" | jq -r --argjson i "$idx" '.[$i].harness // empty')
    model=$(printf '%s\n' "$profiles_json" | jq -r --argjson i "$idx" '.[$i].model // "default"')
    effort=$(printf '%s\n' "$profiles_json" | jq -r --argjson i "$idx" '.[$i].effort // "default"')
    lookup=$(fm_capability_lookup_density "$summary" "$harness" "$model" "$effort")
    density=${lookup%% *}
    total=${lookup#* }
    pick=0
    if [ "$density" -gt 0 ]; then
      if [ "$best_density" -le 0 ] || [ "$density" -gt "$best_density" ]; then
        pick=1
      elif [ "$density" -eq "$best_density" ] && [ "$total" -gt "$best_total" ]; then
        pick=1
      elif [ "$density" -eq "$best_density" ] && [ "$total" -eq "$best_total" ] \
        && [ "$idx" -lt "$best_index" ]; then
        pick=1
      fi
    elif [ -z "$best_json" ] || { [ "$best_density" -le 0 ] && [ "$idx" -lt "$best_index" ]; }; then
      # No positive evidence: keep configured input order (do not let 0%-green
      # beat an earlier untried profile).
      pick=1
    fi
    if [ "$pick" -eq 1 ]; then
      best_density=$density
      best_total=$total
      best_index=$idx
      best_json=$(fm_capability_clean_profile_at "$profiles_json" "$idx")
    fi
    idx=$((idx + 1))
  done
  if [ -z "$best_json" ]; then
    fm_capability_clean_profile_at "$profiles_json" 0
    return 0
  fi
  printf '%s\n' "$best_json"
}

# Maybe emit a scout-tax advisory. Args: task-type selected_profile_json profiles_json
# Never modifies selection; prints at most one CAPABILITY_SCOUT_TAX line.
fm_capability_maybe_scout_tax() {
  local task_type=$1 selected_json=$2 profiles_json=$3
  local rate roll force count idx harness model effort sel_h sel_m sel_e
  local cand_json

  force=${FM_CAPABILITY_SCOUT_TAX:-}
  case "$force" in
    0|false|no|off) return 0 ;;
  esac
  rate=${FM_CAPABILITY_SCOUT_TAX_RATE:-10}
  case "$rate" in
    ''|*[!0-9]*) rate=10 ;;
  esac
  if [ "$rate" -gt 100 ]; then
    rate=100
  fi
  if [ "$force" != 1 ] && [ "$force" != true ] && [ "$force" != yes ] && [ "$force" != on ]; then
    if [ -n "${FM_CAPABILITY_SCOUT_ROLL:-}" ]; then
      roll=$FM_CAPABILITY_SCOUT_ROLL
    else
      # RANDOM is bash-specific but present on 3.2; fall back to 100 (never fire).
      roll=${RANDOM:-100}
      roll=$((roll % 100))
    fi
    case "$roll" in
      ''|*[!0-9]*) return 0 ;;
    esac
    [ "$roll" -lt "$rate" ] || return 0
  fi

  count=$(printf '%s\n' "$profiles_json" | jq 'length')
  [ "$count" -ge 2 ] || return 0
  sel_h=$(printf '%s\n' "$selected_json" | jq -r '.harness // empty')
  sel_m=$(printf '%s\n' "$selected_json" | jq -r '.model // "default"')
  sel_e=$(printf '%s\n' "$selected_json" | jq -r '.effort // "default"')

  idx=0
  while [ "$idx" -lt "$count" ]; do
    harness=$(printf '%s\n' "$profiles_json" | jq -r --argjson i "$idx" '.[$i].harness // empty')
    model=$(printf '%s\n' "$profiles_json" | jq -r --argjson i "$idx" '.[$i].model // "default"')
    effort=$(printf '%s\n' "$profiles_json" | jq -r --argjson i "$idx" '.[$i].effort // "default"')
    if [ "$harness" != "$sel_h" ] || [ "$model" != "$sel_m" ] || [ "$effort" != "$sel_e" ]; then
      cand_json=$(fm_capability_clean_profile_at "$profiles_json" "$idx")
      printf 'CAPABILITY_SCOUT_TAX: task-type=%s consider %s (advisory; cost rules still govern)\n' \
        "$task_type" "$cand_json" >&2
      return 0
    fi
    idx=$((idx + 1))
  done
}
