#!/usr/bin/env bash
# Deliver the standing upstream watch and its catch-up preparation locally and
# privately.
#
# Usage:
#   fm-upstream-watch.sh run
#   fm-upstream-watch.sh catchup
#   fm-upstream-watch.sh pending
#   fm-upstream-watch.sh notify
#   fm-upstream-watch.sh acknowledge [REPORT]
#   fm-upstream-watch.sh arm
#   fm-upstream-watch.sh disarm
#   fm-upstream-watch.sh --help
#
# `run` refreshes a STANDALONE bare cache at data/upstream-watch/cache.git,
# generates a dated report under data/upstream-watch/reports/, advances the
# durable upstream-tip watermark only after the report is safely written, and
# records it as pending for session-start surfacing.
# The cache is initialized without alternates and every fetch runs with
# `git -C "$CACHE"`: no fetch runs in the live checkout, no shared ref moves,
# and no port, merge, rebase, cherry-pick, or publication is attempted.
# Every report ends with the tool-version section from
# bin/fm-stack-versions.sh, which only reports and installs nothing.
# When private config/upstream-watch says `catchup = on` (the format is owned
# by fm_upstream_watch_config in bin/fm-upstream-lib.sh) and the run finds new
# upstream work, the report also carries the generator's catch-up plan and is
# recorded as a pending catch-up.
#
# `catchup` is the on-demand form of the same run, for when the captain asks.
# It needs no opt-in and ignores the "new since the last report" cut, so its
# plan covers every outstanding upstream commit. It prints one line:
#   UPSTREAM_CATCHUP: catch-up ready to prepare through <sha> from <url>; private report at <path>
#   UPSTREAM_CATCHUP: nothing to catch up from <url>; private report at <path>
# Neither form merges anything: firstmate prepares the catch-up itself as a
# real merge on a branch through the `catchup` skill.
#
# `pending` is read-only and prints at most one diagnostic-convention line:
#   UPSTREAM_CATCHUP: catch-up ready to prepare, private report at <path>
#   UPSTREAM_REPORT: new private report at <path>
# bin/fm-bootstrap.sh calls it so the session-start digest surfaces the report.
# `notify` is the live form for a running firstmate's watcher: while catch-up
# is on, it prints
#   upstream-catchup: catch-up ready to prepare, private report at <path>
# once per pending catch-up and is silent otherwise. It opens no network
# connection. `arm` writes state/upstream-catchup.check.sh, which runs
# `notify`, and binds it with bin/fm-check-register.sh; it refuses unless
# catch-up is on. `disarm` retires that check with bin/fm-check-unregister.sh.
# `acknowledge` clears each pending pointer that names REPORT (every pointer
# when REPORT is omitted); reports and watermarks remain.
#
# FM_UPSTREAM_WATCH_LOCK_TIMEOUT bounds acquisition (default 5 seconds).
# FM_UPSTREAM_WATCH_FETCH_TIMEOUT bounds each cache fetch (default 120 seconds).
# The owner-aware mutex recovers dead owners, including legacy ownerless locks.
#
# Generation is separately owned by fm-upstream-watch-generate.sh so a private
# repository workflow can retarget delivery without changing report semantics.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
WATCH_DIR="$DATA/upstream-watch"
CACHE="${FM_UPSTREAM_WATCH_CACHE:-$WATCH_DIR/cache.git}"
REPORTS="$WATCH_DIR/reports"
WATERMARK_FILE="$WATCH_DIR/watermark"
PENDING_FILE="$WATCH_DIR/pending-report"
CATCHUP_FILE="$WATCH_DIR/pending-catchup"
NOTIFIED_FILE="$WATCH_DIR/notified-catchup"
CHECK_ID=upstream-catchup
REMOTE=${FM_UPSTREAM_REMOTE:-upstream}
# shellcheck source=bin/fm-upstream-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-upstream-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-upstream-watch: %s\n' "$*" >&2
  exit 2
}

# Print the report a pointer file names, only when it is a regular report file.
safe_pointer() {
  local pointer=$1 report dir reports
  [ -f "$pointer" ] || return 1
  IFS= read -r report <"$pointer" || return 1
  case "$report" in
    /*/*.md) ;;
    *) return 1 ;;
  esac
  # Pointers keep FM_HOME as the writer spelled it, while the armed check pins
  # the physical path, so the reports directory is compared physically.
  dir=$(cd "${report%/*}" 2>/dev/null && pwd -P) || return 1
  reports=$(cd "$REPORTS" 2>/dev/null && pwd -P) || return 1
  [ "$dir" = "$reports" ] || return 1
  [ -f "$report" ] && [ ! -L "$report" ] || return 1
  printf '%s\n' "$report"
}

write_atomic() {
  local dest=$1 value=$2 parent tmp
  parent=${dest%/*}
  mkdir -p "$parent"
  tmp=$(umask 077; mktemp "$parent/.upstream-watch.XXXXXX") || return 1
  printf '%s\n' "$value" >"$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp"
  mv -f "$tmp" "$dest"
}

safe_pending_report() {
  safe_pointer "$PENDING_FILE"
}

catchup_setting() {
  fm_upstream_watch_config "$CONFIG/upstream-watch" catchup || die 'config/upstream-watch is invalid'
}

pending() {
  local report
  report=$(safe_pointer "$CATCHUP_FILE" 2>/dev/null || true)
  if [ -n "$report" ]; then
    printf 'UPSTREAM_CATCHUP: catch-up ready to prepare, private report at %s\n' "$report"
    return 0
  fi
  report=$(safe_pending_report 2>/dev/null || true)
  [ -n "$report" ] || return 0
  printf 'UPSTREAM_REPORT: new private report at %s\n' "$report"
}

notify() {
  local report notified=
  # A malformed config stays silent here rather than waking firstmate on every
  # sweep; the next run or arm reports it.
  [ "$(catchup_setting 2>/dev/null)" = on ] || return 0
  report=$(safe_pointer "$CATCHUP_FILE" 2>/dev/null || true)
  [ -n "$report" ] || return 0
  [ ! -f "$NOTIFIED_FILE" ] || IFS= read -r notified <"$NOTIFIED_FILE" || true
  [ "$notified" != "$report" ] || return 0
  write_atomic "$NOTIFIED_FILE" "$report"
  printf 'upstream-catchup: catch-up ready to prepare, private report at %s\n' "$report"
}

acknowledge() {
  local expected=${1:-} current catchup
  current=$(safe_pending_report 2>/dev/null || true)
  catchup=$(safe_pointer "$CATCHUP_FILE" 2>/dev/null || true)
  if [ -z "$expected" ]; then
    rm -f "$PENDING_FILE" "$CATCHUP_FILE"
    return 0
  fi
  # Each pointer that names this report is cleared; a pointer naming a newer
  # report stays, so acknowledging an old report never hides a new one.
  [ -n "$current$catchup" ] || return 0
  if [ "$expected" != "$current" ] && [ "$expected" != "$catchup" ]; then
    die "pending report changed (current: ${catchup:-$current})"
  fi
  [ "$expected" != "$current" ] || rm -f "$PENDING_FILE"
  [ "$expected" != "$catchup" ] || rm -f "$CATCHUP_FILE"
}

arm() {
  local home shim tmp setting
  setting=$(catchup_setting) || exit 2
  [ "$setting" = on ] \
    || die 'catch-up is off for this home; add "catchup = on" to config/upstream-watch first'
  mkdir -p "$STATE"
  home=$(cd "$FM_HOME" && pwd -P)
  shim="$STATE/$CHECK_ID.check.sh"
  [ ! -L "$shim" ] || die "refusing a symlinked check: $shim"
  tmp=$(umask 077; mktemp "$STATE/.upstream-catchup-check.XXXXXX")
  {
    printf '#!/usr/bin/env bash\n'
    printf 'exec env FM_HOME=%q %q notify\n' "$home" "$SCRIPT_DIR/fm-upstream-watch.sh"
  } >"$tmp" || { rm -f "$tmp"; die "could not write $shim"; }
  if ! chmod 700 "$tmp" || ! mv -f "$tmp" "$shim"; then
    rm -f "$tmp"
    die "could not write $shim"
  fi
  # An unregistered shim is not inert: the watcher wakes firstmate about it on
  # every sweep, so a failed registration removes the shim again.
  if ! FM_HOME="$home" "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" >/dev/null; then
    rm -f "$shim"
    die "could not register $shim"
  fi
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

disarm() {
  [ -d "$STATE" ] || { printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"; return 0; }
  "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID" >/dev/null || die "could not retire state/$CHECK_ID.check.sh"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

run_watch() {
  local mode=$1 plan=0 has_work=0 catchup
  local upstream_url origin_url branch head tip watermark ledger stamp report tmp_report lock
  git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "not a git checkout: $ROOT"
  upstream_url=$(git -C "$ROOT" remote get-url "$REMOTE" 2>/dev/null || true)
  [ -n "$upstream_url" ] || die "remote is not configured: $REMOTE"
  origin_url=$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)
  if [ -n "$origin_url" ] \
    && [ "$(printf '%s' "$origin_url" | sed -E 's#^file://##; s#(\.git)?/*$##')" = "$(printf '%s' "$upstream_url" | sed -E 's#^file://##; s#(\.git)?/*$##')" ]; then
    die 'origin and upstream are the same repository; this is not a fork watch'
  fi
  branch=${FM_UPSTREAM_WATCH_BRANCH:-}
  if [ -z "$branch" ]; then
    branch=$(fm_upstream_branch "$ROOT" "$REMOTE" 2>/dev/null || true)
  fi
  [ -n "$branch" ] || branch=main
  head=$(git -C "$ROOT" rev-parse HEAD)
  ledger=${FM_UPSTREAM_LEDGER:-$ROOT/$FM_UPSTREAM_LEDGER_DEFAULT}
  [ -f "$ledger" ] || die "ported ledger is missing: $ledger"
  catchup=$(catchup_setting)
  if [ "$mode" = catchup ] || [ "$catchup" = on ]; then
    plan=1
  fi

  umask 077
  mkdir -p "$WATCH_DIR" "$REPORTS"
  # shellcheck source=bin/fm-wake-lib.sh disable=SC1091
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
  . "$SCRIPT_DIR/fm-timeout-lib.sh"
  local lock_timeout=${FM_UPSTREAM_WATCH_LOCK_TIMEOUT:-5} fetch_timeout=${FM_UPSTREAM_WATCH_FETCH_TIMEOUT:-120}
  case "$lock_timeout" in ''|*[!0-9]*|0) die 'lock timeout must be positive seconds' ;; esac
  case "$fetch_timeout" in ''|*[!0-9]*|0) die 'fetch timeout must be positive seconds' ;; esac
  lock="$WATCH_DIR/.run-lock"
  RUN_LOCK=$lock
  trap 'fm_lock_release "$RUN_LOCK"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if ! fm_lock_acquire_wait_bounded "$lock" "$lock_timeout"; then
    die "another upstream watch run is active ($lock)"
  fi

  if [ ! -d "$CACHE" ]; then
    git init --bare -q "$CACHE"
  fi
  [ "$(git -C "$CACHE" rev-parse --is-bare-repository 2>/dev/null || true)" = true ] \
    || die "cache is not a bare repository: $CACHE"
  # These are the only fetches in normal operation, and both write only refs in
  # the standalone cache. The live checkout is a read-only source URL here.
  fm_run_timed "$fetch_timeout" env GIT_TERMINAL_PROMPT=0 git -C "$CACHE" fetch --no-tags --quiet "$ROOT" \
    "+$head:refs/fm-watch/fork-head"
  fm_run_timed "$fetch_timeout" env GIT_TERMINAL_PROMPT=0 git -C "$CACHE" fetch --no-tags --quiet "$upstream_url" \
    "+refs/heads/$branch:refs/fm-watch/upstream"
  tip=$(git -C "$CACHE" rev-parse refs/fm-watch/upstream)
  watermark=
  [ -f "$WATERMARK_FILE" ] && IFS= read -r watermark <"$WATERMARK_FILE" || true
  # On demand, the plan must cover all outstanding work, not only what is new
  # since the last report, so the watermark cut is skipped.
  [ "$mode" != catchup ] || watermark=

  stamp=${FM_UPSTREAM_WATCH_STAMP:-$(date -u +%Y-%m-%d-%H%M%SZ)}
  case "$stamp" in ''|*[!A-Za-z0-9._-]*) die "unsafe report stamp: $stamp" ;; esac
  report="$REPORTS/$stamp.md"
  [ ! -e "$report" ] || report="$REPORTS/$stamp-$$.md"
  tmp_report=$(mktemp "$REPORTS/.report.XXXXXX")
  local -a plan_arg=()
  [ "$plan" -eq 0 ] || plan_arg=(--catchup-plan)
  if ! "$SCRIPT_DIR/fm-upstream-watch-generate.sh" \
    --git-dir "$CACHE" \
    --base refs/fm-watch/fork-head \
    --tip refs/fm-watch/upstream \
    --ledger "$ledger" \
    --watermark "$watermark" \
    --fork-root "$ROOT" \
    --upstream-url "$upstream_url" ${plan_arg[@]+"${plan_arg[@]}"} >"$tmp_report"; then
    rm -f "$tmp_report"
    die 'report generation failed'
  fi
  # The generator's quiet interval is exactly one line; anything longer is work.
  [ "$(wc -l <"$tmp_report" | tr -d ' ')" -le 1 ] || has_work=1
  printf '\n' >>"$tmp_report"
  if ! FM_ROOT_OVERRIDE="$ROOT" "$SCRIPT_DIR/fm-stack-versions.sh" report >>"$tmp_report" 2>/dev/null; then
    printf '## Tool versions\n\nThe tool versions could not be checked on this run.\n' >>"$tmp_report"
  fi
  chmod 600 "$tmp_report"
  mv "$tmp_report" "$report"
  write_atomic "$WATERMARK_FILE" "$tip"
  write_atomic "$PENDING_FILE" "$report"
  if [ "$plan" -eq 1 ] && [ "$has_work" -eq 1 ]; then
    write_atomic "$CATCHUP_FILE" "$report"
  elif [ "$mode" = catchup ]; then
    rm -f "$CATCHUP_FILE"
  fi
  if [ "$mode" = catchup ]; then
    if [ "$has_work" -eq 1 ]; then
      printf 'UPSTREAM_CATCHUP: catch-up ready to prepare through %s from %s; private report at %s\n' \
        "${tip:0:12}" "$(fm_upstream_normalize_url "$upstream_url")" "$report"
    else
      printf 'UPSTREAM_CATCHUP: nothing to catch up from %s; private report at %s\n' \
        "$(fm_upstream_normalize_url "$upstream_url")" "$report"
    fi
    return 0
  fi
  printf 'UPSTREAM_REPORT: wrote private report %s (watermark %s)\n' "$report" "${tip:0:12}"
  if [ "$plan" -eq 1 ] && [ "$has_work" -eq 1 ]; then
    printf 'UPSTREAM_CATCHUP: catch-up ready to prepare through %s from %s; private report at %s\n' \
      "${tip:0:12}" "$(fm_upstream_normalize_url "$upstream_url")" "$report"
  fi
}

case "${1:-}" in
  run)
    [ "$#" -eq 1 ] || die 'run takes no arguments'
    run_watch run
    ;;
  catchup)
    [ "$#" -eq 1 ] || die 'catchup takes no arguments'
    run_watch catchup
    ;;
  pending)
    [ "$#" -eq 1 ] || die 'pending takes no arguments'
    pending
    ;;
  notify)
    [ "$#" -eq 1 ] || die 'notify takes no arguments'
    notify
    ;;
  arm)
    [ "$#" -eq 1 ] || die 'arm takes no arguments'
    arm
    ;;
  disarm)
    [ "$#" -eq 1 ] || die 'disarm takes no arguments'
    disarm
    ;;
  acknowledge)
    [ "$#" -le 2 ] || die 'acknowledge accepts at most one report path'
    acknowledge "${2:-}"
    ;;
  -h|--help)
    usage
    ;;
  '')
    usage
    exit 2
    ;;
  *)
    die "unknown command: $1"
    ;;
esac
