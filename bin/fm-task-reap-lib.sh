#!/usr/bin/env bash
# fm-task-reap-lib.sh - stop the processes a task left behind in its own
# copies. Sourced by bin/fm-teardown.sh (cleanup) and bin/fm-control.sh
# (relaunch); each caller owns which copies it passes.
#
# A backgrounded or disowned process started by a worker or by its validation
# run does not receive the hangup that closing the worker's terminal sends, so
# it survives reparented to init or launchd and keeps running from a copy that
# cleanup is about to remove, or that no-mistakes already removed.
# fm_reap_task_processes stops every process that sits inside one of the
# given copies:
#   - its current working directory is the copy or under it, read from one
#     bounded system-wide `lsof -a -d cwd` scan for all copies (never the
#     recursive +D walk). A copy that no longer exists still matches: lsof keeps naming
#     the directory a process was started in after it is deleted (Linux adds a
#     " (deleted)" suffix, which is stripped);
#   - or one of its whitespace-separated arguments starts with the copy
#     followed by `/`, read from one `ps` listing per scan. The copy's own
#     path alone never matches, so a terminal multiplexer or editor that was
#     merely started with the copy as its directory is not mistaken for a
#     program running from it.
# Each copy is matched under both its given spelling and its resolved one
# (macOS /tmp is /private/tmp). The calling script and its ancestors are never
# matched, so whatever supervises the cleanup is never stopped. A copy belongs
# to exactly one task, so this can never reach another task's processes or a
# process outside those copies.
# Stopping is polite then forceful: TERM, a one-second grace, then KILL for a
# survivor whose identity (start time) still matches, up to three passes.
# Every stopped process is logged on stderr with its pid and command line.
# Without lsof only the argument match runs; the caller decides on any extra
# fallback. Returns 0 when nothing is left, 1 (with a REFUSED line ending in
# the caller's consequence text) when a scan fails or a process survives every
# pass.
# FM_PROC_ROOT_OVERRIDE points the Linux identity read at a fake /proc (tests).

# Absolute resolved spelling of <dir>, which need not exist: the deepest
# existing ancestor is resolved and the rest appended unchanged.
fm_reap_resolve_dir() {  # <dir>
  local dir=$1 rest='' base
  case "$dir" in /*) ;; *) return 1 ;; esac
  while [ ! -d "$dir" ]; do
    base=${dir##*/}
    rest="/$base$rest"
    dir=${dir%/*}
    [ -n "$dir" ] || { printf '%s\n' "$rest"; return 0; }
  done
  dir=$(cd "$dir" && pwd -P) || return 1
  [ "$dir" != / ] || dir=
  printf '%s%s\n' "$dir" "$rest"
}

# Pids whose current working directory is one of <dir>... or under it, from
# one lsof scan. Failure means the scan could not establish a safe result.
fm_reap_pids_with_cwd_under() {  # <dir>...
  local out pid path line dir
  out=$(lsof -a -d cwd -Fpn 2>/dev/null) || return 1
  [ -n "$out" ] || return 0
  pid=
  while IFS= read -r line; do
    case "$line" in
      p*)
        pid=${line#p}
        case "$pid" in ''|*[!0-9]*) return 1 ;; esac
        ;;
      fcwd) [ -n "$pid" ] || return 1 ;;
      n*)
        [ -n "$pid" ] || return 1
        path=${line#n}
        path=${path% (deleted)}
        for dir in "$@"; do
          case "$path" in
            "$dir"|"$dir"/*)
              printf '%s\n' "$pid"
              break
              ;;
          esac
        done
        ;;
      '') ;;
      *) return 1 ;;
    esac
  done <<EOF
$out
EOF
}

# The calling script's own pid and every ancestor's, one per line.
fm_reap_own_ancestry() {
  local pid=$$ parent depth=0
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null && [ "$depth" -lt 64 ]; do
    printf '%s\n' "$pid"
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]') || break
    [ "$parent" != "$pid" ] || break
    pid=$parent
    depth=$((depth + 1))
  done
}

# Pids with a whitespace-separated argument that starts with one of <dir>...
# followed by `/`, from one ps listing. Failure means the listing could not be
# read.
fm_reap_pids_with_args_under() {  # <dir>...
  local out
  out=$(ps -A -ww -o pid= -o args= 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | awk '
    BEGIN {
      for (i = 1; i < ARGC; i++) { dirs[i] = ARGV[i] "/"; delete ARGV[i] }
      ndirs = ARGC - 1
    }
    {
      pid = $1
      if (pid !~ /^[0-9]+$/) next
      for (f = 2; f <= NF; f++)
        for (i = 1; i <= ndirs; i++)
          if (index($f, dirs[i]) == 1) { print pid; next }
    }' "$@"
}

fm_reap_process_identity() {  # <pid>
  local pid=$1 proc_root stat_line starttime value
  local -a stat_fields
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  if [ -r "$proc_root/$pid/stat" ]; then
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 1
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${#stat_fields[@]}" -ge 20 ] || return 1
    starttime=${stat_fields[19]}
    case "$starttime" in ''|*[!0-9]*) return 1 ;; esac
    printf 'starttime=%s\n' "$starttime"
    return 0
  fi
  value=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || return 1
  value=$(printf '%s' "$value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [ -n "$value" ] || return 1
  case "$value" in *$'\n'*|*$'\r'*) return 1 ;; esac
  printf 'lstart=%s\n' "$value"
}

fm_reap_process_identity_matches() {  # <pid> <identity>
  local current
  current=$(fm_reap_process_identity "$1") || return 1
  [ "$current" = "$2" ]
}

fm_reap_pid_list_contains() {  # <pid-list> <pid>
  printf '%s\n' "$1" | grep -Fxq "$2"
}

# Sets FM_REAP_PIDS (sorted, unique) for every process inside <dir>..., or
# FM_REAP_FAILED_DIR and returns 1 when a scan failed.
fm_reap_pids_under_roots() {  # <dir>...
  FM_REAP_PIDS=
  FM_REAP_FAILED_DIR=
  local dir real cwd_pids="" arg_pids
  local -a dirs=()
  for dir in "$@"; do
    [ -n "$dir" ] || continue
    if ! real=$(fm_reap_resolve_dir "$dir"); then
      FM_REAP_FAILED_DIR=$dir
      return 1
    fi
    dirs+=("$dir")
    [ "$real" = "$dir" ] || dirs+=("$real")
  done
  [ "${#dirs[@]}" -gt 0 ] || return 0
  if command -v lsof >/dev/null 2>&1 \
     && ! cwd_pids=$(fm_reap_pids_with_cwd_under "${dirs[@]}"); then
    FM_REAP_FAILED_DIR=${dirs[0]}
    return 1
  fi
  if ! arg_pids=$(fm_reap_pids_with_args_under "${dirs[@]}"); then
    FM_REAP_FAILED_DIR=${dirs[0]}
    return 1
  fi
  local pids="$cwd_pids
$arg_pids"
  FM_REAP_PIDS=$(printf '%s\n' "$pids" | grep -E '^[0-9]+$' | sort -un \
    | grep -F -x -v -f <(fm_reap_own_ancestry; printf '%s\n' "$$") || true)
}

fm_reap_log_processes() {  # <prefix> <pid>...
  local prefix=$1 pid cmd
  shift
  for pid in "$@"; do
    cmd=$(ps -p "$pid" -o args= 2>/dev/null | head -1) || cmd=
    printf '%s %s %s\n' "$prefix" "$pid" "${cmd:-<exited>}" >&2
  done
}

fm_reap_scan_refusal() {  # <id> <consequence>
  echo "REFUSED: cannot determine leaked processes under ${FM_REAP_FAILED_DIR:-<missing>} for $1 (lsof failed); $2." >&2
}

# Stop every process inside <dir>... for task <id>; <label> names the copies
# in log lines, <who> prefixes them (teardown, relaunch), and <consequence>
# ends every REFUSED line with what the caller does about a refusal.
fm_reap_task_processes() {  # <who> <label> <id> <consequence> <dir>...
  local who=$1 label=$2 id=$3 consequence=$4 pids pid identity current_pids i pass=1 max_passes=3
  local -a tracked_pids tracked_identities remaining_pids remaining_identities
  shift 4
  while [ "$pass" -le "$max_passes" ]; do
    fm_reap_pids_under_roots "$@" || { fm_reap_scan_refusal "$id" "$consequence"; return 1; }
    pids=$FM_REAP_PIDS
    [ -n "$pids" ] || return 0
    tracked_pids=()
    tracked_identities=()
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      if ! identity=$(fm_reap_process_identity "$pid"); then
        fm_reap_pids_under_roots "$@" || { fm_reap_scan_refusal "$id" "$consequence"; return 1; }
        if fm_reap_pid_list_contains "$FM_REAP_PIDS" "$pid"; then
          echo "REFUSED: cannot verify leaked process $pid identity for $id; $consequence." >&2
          return 1
        fi
        continue
      fi
      tracked_pids+=("$pid")
      tracked_identities+=("$identity")
    done <<EOF
$pids
EOF
    if [ "${#tracked_pids[@]}" -eq 0 ]; then
      pass=$((pass + 1))
      continue
    fi
    fm_reap_pids_under_roots "$@" || { fm_reap_scan_refusal "$id" "$consequence"; return 1; }
    current_pids=$FM_REAP_PIDS
    echo "$who: reaping leaked $label process(es) for $id: $(printf '%s' "$pids" | tr '\n' ' ')" >&2
    fm_reap_log_processes "$who: stopping" "${tracked_pids[@]}"
    for i in "${!tracked_pids[@]}"; do
      pid=${tracked_pids[$i]}
      identity=${tracked_identities[$i]}
      if fm_reap_pid_list_contains "$current_pids" "$pid" \
         && fm_reap_process_identity_matches "$pid" "$identity"; then
        kill -TERM "$pid" 2>/dev/null || true
      fi
    done
    sleep 1
    fm_reap_pids_under_roots "$@" || { fm_reap_scan_refusal "$id" "$consequence"; return 1; }
    current_pids=$FM_REAP_PIDS
    remaining_pids=()
    remaining_identities=()
    for i in "${!tracked_pids[@]}"; do
      pid=${tracked_pids[$i]}
      identity=${tracked_identities[$i]}
      if fm_reap_pid_list_contains "$current_pids" "$pid" \
         && fm_reap_process_identity_matches "$pid" "$identity"; then
        remaining_pids+=("$pid")
        remaining_identities+=("$identity")
      fi
    done
    if [ "${#remaining_pids[@]}" -gt 0 ]; then
      echo "$who: force-killing leaked $label process(es) for $id: ${remaining_pids[*]}" >&2
      fm_reap_pids_under_roots "$@" || { fm_reap_scan_refusal "$id" "$consequence"; return 1; }
      current_pids=$FM_REAP_PIDS
      for i in "${!remaining_pids[@]}"; do
        pid=${remaining_pids[$i]}
        identity=${remaining_identities[$i]}
        if fm_reap_pid_list_contains "$current_pids" "$pid" \
           && fm_reap_process_identity_matches "$pid" "$identity"; then
          kill -KILL "$pid" 2>/dev/null || true
        fi
      done
    fi
    pass=$((pass + 1))
  done
  fm_reap_pids_under_roots "$@" || { fm_reap_scan_refusal "$id" "$consequence"; return 1; }
  [ -z "$FM_REAP_PIDS" ] && return 0
  echo "REFUSED: leaked $label processes for $id remain after $max_passes reap attempts; $consequence." >&2
  return 1
}
