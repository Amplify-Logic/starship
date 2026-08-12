#!/usr/bin/env bash
# fm-lint.sh - the single owner of firstmate's shell-lint definition.
#
# Runs every canonical shell root with ShellCheck's default severity, extended
# analysis, ambient configuration disabled, and one exact ShellCheck version.
# CI and no-mistakes both invoke this script with no arguments, so the file set,
# rule set, version, bounded execution, and diagnostics ordering cannot drift.
# Tests stop source analysis at imported production modules because every
# production shell is already a canonical, source-aware root of this same run.
#
# Canonical lint defaults to two bounded workers over two stable logical shards.
# Each shard writes separate diagnostics, and the parent replays those outputs in
# deterministic shard and root order after every worker finishes. FM_LINT_JOBS=1
# runs the same shards serially with byte-identical diagnostics and exit selection.
#
# Usage:
#   fm-lint.sh                    lint the canonical file set (what both gates run)
#   fm-lint.sh <path>...          lint only the given paths with the same config
#                                  (developer convenience; the gates never pass args)
#   FM_LINT_JOBS=1 fm-lint.sh ... run the same two shards serially (default: 2)
#   fm-lint.sh --required-version print the pinned ShellCheck version and exit
#                                  (CI reads this to install the exact same one)
#   fm-lint.sh --list-files       print the canonical shell file set and exit
#
# Exit status is ShellCheck's own on a clean lint run, so a caller (CI or the
# gate) fails exactly when ShellCheck reports a finding; a version mismatch, a
# missing ShellCheck, or a non-executable tracked test fails before ShellCheck
# with a distinct message.
set -eu

REQUIRED_SHELLCHECK=0.11.0
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/fm-lint.sh"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
cd "$ROOT" || exit 1

FM_LINT_WORKER_SHELLCHECK_PID=
# shellcheck disable=SC2329 # Registered by the private worker's signal traps.
fm_lint_worker_stop() {
  [ -n "$FM_LINT_WORKER_SHELLCHECK_PID" ] || return 0
  kill "$FM_LINT_WORKER_SHELLCHECK_PID" 2>/dev/null || true
  wait "$FM_LINT_WORKER_SHELLCHECK_PID" 2>/dev/null || true
  FM_LINT_WORKER_SHELLCHECK_PID=
}

fm_lint_worker() {  # <manifest> <output-dir> <shard-index>
  local manifest=$1 output_dir=$2 shard_index=$3 tab index path output expected rc=0
  local -a roots
  roots=()
  output="$output_dir/shard.$shard_index"
  expected=-1
  if [ -f "$manifest" ] && [ -r "$manifest" ]; then
    expected=$(awk 'END {print NR + 0}' "$manifest" 2>/dev/null | tr -d '[:space:]')
    case "$expected" in ''|*[!0-9]*) expected=-1 ;; esac
  fi
  if [ "$expected" -lt 0 ]; then
    printf 'fm-lint.sh: shard %s manifest is missing or unreadable: %s\n' \
      "$shard_index" "$manifest" > "$output.out"
    printf '%s\n' 2 > "$output.rc"
    return 2
  fi
  tab=$(printf '\t')
  while IFS="$tab" read -r index path || [ -n "${index:-}${path:-}" ]; do
    [ -n "${index:-}" ] || continue
    roots+=("$path")
  done < "$manifest"
  if [ "${#roots[@]}" -ne "$expected" ]; then
    printf 'fm-lint.sh: shard %s read %s of %s manifest roots: %s\n' \
      "$shard_index" "${#roots[@]}" "$expected" "$manifest" > "$output.out"
    printf '%s\n' 2 > "$output.rc"
    return 2
  fi
  if [ "${#roots[@]}" -gt 0 ]; then
    trap 'fm_lint_worker_stop; exit 129' HUP
    trap 'fm_lint_worker_stop; exit 130' INT
    trap 'fm_lint_worker_stop; exit 143' TERM
    "$FM_LINT_SHELLCHECK" --norc --external-sources -- "${roots[@]}" > "$output.out" 2>&1 &
    FM_LINT_WORKER_SHELLCHECK_PID=$!
    wait "$FM_LINT_WORKER_SHELLCHECK_PID" || rc=$?
    FM_LINT_WORKER_SHELLCHECK_PID=
    trap - HUP INT TERM
  else
    : > "$output.out"
  fi
  printf '%s\n' "$rc" > "$output.rc"
  return "$rc"
}

# Private subprocess mode used only by the bounded parent above.
if [ "${1:-}" = "--internal-worker" ]; then
  [ "${FM_LINT_INTERNAL:-}" = 1 ] || {
    printf 'fm-lint.sh: --internal-worker is private to the lint owner.\n' >&2
    exit 2
  }
  [ "$#" -eq 4 ] && [ -n "${FM_LINT_SHELLCHECK:-}" ] || exit 2
  fm_lint_worker "$2" "$3" "$4"
  exit $?
fi

if [ "${1:-}" = "--required-version" ]; then
  printf '%s\n' "$REQUIRED_SHELLCHECK"
  exit 0
fi

LIST_FILES=0
if [ "${1:-}" = "--list-files" ]; then
  LIST_FILES=1
  shift
  [ "$#" -eq 0 ] || {
    printf 'fm-lint.sh: --list-files does not accept explicit paths.\n' >&2
    exit 2
  }
fi

CANONICAL=1
if [ "$#" -gt 0 ]; then
  ROOTS=("$@")
  CANONICAL=0
else
  ROOTS=(bin/*.sh bin/backends/*.sh tests/*.sh)
fi

if [ "$LIST_FILES" -eq 1 ]; then
  printf '%s\n' "${ROOTS[@]}"
  exit 0
fi

JOBS=${FM_LINT_JOBS:-2}
case "$JOBS" in
  1|2) ;;
  *) printf 'fm-lint.sh: jobs must be 1 or 2, got %s.\n' "$JOBS" >&2; exit 2 ;;
esac

# Enforce the pin so local and CI resolve the identical rule set.
if ! command -v shellcheck >/dev/null 2>&1; then
  printf 'fm-lint.sh: ShellCheck not found; install ShellCheck %s for CI parity.\n' \
    "$REQUIRED_SHELLCHECK" >&2
  exit 127
fi
unset SHELLCHECK_OPTS
SHELLCHECK_BIN=$(command -v shellcheck)
resolved=$("$SHELLCHECK_BIN" --version | awk '/^version:/ {print $2; exit}')
printf 'fm-lint.sh: ShellCheck %s (pinned %s)\n' "$resolved" "$REQUIRED_SHELLCHECK" >&2
if [ "$resolved" != "$REQUIRED_SHELLCHECK" ]; then
  printf 'fm-lint.sh: ShellCheck %s required for CI parity, found %s. Install %s.\n' \
    "$REQUIRED_SHELLCHECK" "$resolved" "$REQUIRED_SHELLCHECK" >&2
  exit 1
fi

# Fail closed on tracked tests that lack the git executable bit. Do not repair
# here: auto-chmod would hide the bad commit that CI exit 126 already punished.
# A 100644 entry still passes `bash tests/<name>.test.sh`, as fm-test-run.sh uses,
# but direct CI execution fails with exit 126.
# The quoted pathspec below is load-bearing: git, not the shell, expands it.
check_test_exec_bits() {
  local mode path bad=0
  while read -r mode _ _ path; do
    [ -n "${path:-}" ] || continue
    if [ "$mode" != "100755" ]; then
      printf 'fm-lint.sh: %s is mode %s in the git index; expected 100755.\n' "$path" "$mode" >&2
      printf 'fm-lint.sh: repair with: chmod +x %s\n' "$path" >&2
      bad=1
    fi
  done < <(git ls-files -s -- 'tests/*.test.sh')
  [ "$bad" -eq 0 ]
}

if [ "$CANONICAL" -eq 1 ]; then
  check_test_exec_bits || exit 1
fi

# Canonical file set: the ONE authoritative definition. Callers consume it
# through this script or --list-files; they never re-spell the inventory.
ROOT_COUNT=${#ROOTS[@]}
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-lint.XXXXXX") || exit 1
ACTIVE_PIDS=()
# shellcheck disable=SC2329 # Registered by the EXIT and signal traps below.
fm_lint_cleanup() {
  local pid
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -TERM -- "-$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP_ROOT"
}
trap fm_lint_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

TAB=$(printf '\t')
WEIGHTS="$TMP_ROOT/weights"
OUTPUT_DIR="$TMP_ROOT/output"
mkdir -p "$OUTPUT_DIR"
SHARD_COUNT=2
worker=0
while [ "$worker" -lt "$SHARD_COUNT" ]; do
  : > "$TMP_ROOT/manifest.$worker"
  worker=$((worker + 1))
done

index=1
: > "$WEIGHTS"
for path in "${ROOTS[@]}"; do
  case "$path" in
    *"$TAB"*|*$'\n'*)
      printf 'fm-lint.sh: paths containing tabs or newlines are not supported: %s\n' "$path" >&2
      exit 2
      ;;
  esac
  if [ -f "$path" ]; then
    weight=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]')
  else
    weight=1
  fi
  case "$weight" in ''|*[!0-9]*) weight=1 ;; esac
  printf '%s\t%s\t%s\n' "$weight" "$index" "$path" >> "$WEIGHTS"
  index=$((index + 1))
done

# Largest-first deterministic greedy assignment keeps the two bounded workers
# balanced without affecting replay order. Direct bytes are a stable portable
# proxy after the expensive dynamic adapter source fan-out is cut.
WORKER_LOADS=(0 0)
LC_ALL=C sort -t "$TAB" -k1,1nr -k2,2n "$WEIGHTS" > "$WEIGHTS.sorted"
while IFS="$TAB" read -r weight index path; do
  worker=0
  if [ "${WORKER_LOADS[1]}" -lt "${WORKER_LOADS[0]}" ]; then
    worker=1
  fi
  printf '%s\t%s\n' "$index" "$path" >> "$TMP_ROOT/manifest.$worker"
  WORKER_LOADS[worker]=$((WORKER_LOADS[worker] + weight))
done < "$WEIGHTS.sorted"
worker=0
while [ "$worker" -lt "$SHARD_COUNT" ]; do
  LC_ALL=C sort -t "$TAB" -k1,1n "$TMP_ROOT/manifest.$worker" > "$TMP_ROOT/manifest.$worker.sorted"
  mv "$TMP_ROOT/manifest.$worker.sorted" "$TMP_ROOT/manifest.$worker"
  worker=$((worker + 1))
done

# Fail closed: a truncated weight file, a failed shard write, or an unreadable
# manifest must never be reported as a clean shard.
ASSIGNED_COUNT=0
worker=0
while [ "$worker" -lt "$SHARD_COUNT" ]; do
  shard_count=$(awk 'END {print NR + 0}' "$TMP_ROOT/manifest.$worker" 2>/dev/null | tr -d '[:space:]')
  case "$shard_count" in
    ''|*[!0-9]*)
      printf 'fm-lint.sh: shard %s manifest is unreadable; refusing to report a partial lint.\n' "$worker" >&2
      exit 2
      ;;
  esac
  ASSIGNED_COUNT=$((ASSIGNED_COUNT + shard_count))
  worker=$((worker + 1))
done
if [ "$ASSIGNED_COUNT" -ne "$ROOT_COUNT" ]; then
  printf 'fm-lint.sh: shard manifests cover %s of %s roots; refusing to report a partial lint.\n' \
    "$ASSIGNED_COUNT" "$ROOT_COUNT" >&2
  exit 2
fi
fm_lint_run_worker() {  # <worker-index>
  local worker_index=$1 manifest
  manifest="$TMP_ROOT/manifest.$worker_index"
  exec env FM_LINT_INTERNAL=1 FM_LINT_SHELLCHECK="$SHELLCHECK_BIN" \
    "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
}

# Bash job control makes each background worker its own process-group leader, so
# fm_lint_cleanup can stop a complete worker tree with no external dependency.
fm_lint_start_worker() {
  local monitor_was_on=0
  case "$-" in
    *m*) monitor_was_on=1 ;;
  esac
  set -m
  fm_lint_run_worker "$1" &
  ACTIVE_PIDS+=("$!")
  [ "$monitor_was_on" -eq 1 ] || set +m
}

fm_lint_wait_workers() {
  local pid
  while [ "${#ACTIVE_PIDS[@]}" -gt 0 ]; do
    pid=${ACTIVE_PIDS[0]}
    wait "$pid" 2>/dev/null || true
    ACTIVE_PIDS=("${ACTIVE_PIDS[@]:1}")
  done
}

if [ "$JOBS" -eq 1 ]; then
  worker=0
  while [ "$worker" -lt "$SHARD_COUNT" ]; do
    fm_lint_start_worker "$worker"
    fm_lint_wait_workers
    worker=$((worker + 1))
  done
else
  worker=0
  while [ "$worker" -lt "$SHARD_COUNT" ]; do
    fm_lint_start_worker "$worker"
    worker=$((worker + 1))
  done
  fm_lint_wait_workers
fi

# Replay both stable shards in deterministic order and select the first nonzero
# shard status. ShellCheck processes every root in a shard after earlier findings.
overall_rc=0
worker=0
while [ "$worker" -lt "$SHARD_COUNT" ]; do
  output="$OUTPUT_DIR/shard.$worker"
  [ ! -f "$output.out" ] || cat "$output.out"
  if [ -f "$output.rc" ]; then
    rc=$(cat "$output.rc" 2>/dev/null || printf '2')
    case "$rc" in ''|*[!0-9]*) rc=2 ;; esac
  else
    printf 'fm-lint.sh: worker produced no result for shard %s.\n' "$worker" >&2
    rc=2
  fi
  if [ "$overall_rc" -eq 0 ] && [ "$rc" -ne 0 ]; then
    overall_rc=$rc
  fi
  worker=$((worker + 1))
done

exit "$overall_rc"
