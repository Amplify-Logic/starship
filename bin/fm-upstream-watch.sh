#!/usr/bin/env bash
# Deliver the standing upstream watch locally and privately.
#
# Usage:
#   fm-upstream-watch.sh run
#   fm-upstream-watch.sh pending
#   fm-upstream-watch.sh acknowledge [REPORT]
#   fm-upstream-watch.sh --help
#
# `run` refreshes a STANDALONE bare cache at data/upstream-watch/cache.git,
# generates a dated report under data/upstream-watch/reports/, advances the
# durable upstream-tip watermark only after the report is safely written, and
# records it as pending for session-start surfacing.
# The cache is initialized without alternates and every fetch runs with
# `git -C "$CACHE"`: no fetch runs in the live checkout, no shared ref moves,
# and no port, merge, rebase, cherry-pick, or publication is attempted.
#
# `pending` is read-only and prints at most one diagnostic-convention line:
#   UPSTREAM_REPORT: new private report at <path>
# bin/fm-bootstrap.sh calls it so the session-start digest surfaces the report.
# `acknowledge` removes only the pending pointer; reports and watermarks remain.
#
# Generation is separately owned by fm-upstream-watch-generate.sh so a private
# repository workflow can retarget delivery without changing report semantics.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
WATCH_DIR="$DATA/upstream-watch"
CACHE="${FM_UPSTREAM_WATCH_CACHE:-$WATCH_DIR/cache.git}"
REPORTS="$WATCH_DIR/reports"
WATERMARK_FILE="$WATCH_DIR/watermark"
PENDING_FILE="$WATCH_DIR/pending-report"
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

safe_pending_report() {
  local report
  [ -f "$PENDING_FILE" ] || return 1
  IFS= read -r report <"$PENDING_FILE" || return 1
  case "$report" in
    "$REPORTS"/*.md) ;;
    *) return 1 ;;
  esac
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

pending() {
  local report
  report=$(safe_pending_report 2>/dev/null || true)
  [ -n "$report" ] || return 0
  printf 'UPSTREAM_REPORT: new private report at %s\n' "$report"
}

acknowledge() {
  local expected=${1:-} current
  current=$(safe_pending_report 2>/dev/null || true)
  [ -n "$current" ] || return 0
  if [ -n "$expected" ] && [ "$expected" != "$current" ]; then
    die "pending report changed (current: $current)"
  fi
  rm -f "$PENDING_FILE"
}

run_watch() {
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

  umask 077
  mkdir -p "$WATCH_DIR" "$REPORTS"
  lock="$WATCH_DIR/.run-lock"
  if ! mkdir "$lock" 2>/dev/null; then
    die "another upstream watch run is active ($lock)"
  fi
  RUN_LOCK=$lock
  trap 'rm -rf "${RUN_LOCK:-}"' EXIT HUP INT TERM

  if [ ! -d "$CACHE" ]; then
    git init --bare -q "$CACHE"
  fi
  [ "$(git -C "$CACHE" rev-parse --is-bare-repository 2>/dev/null || true)" = true ] \
    || die "cache is not a bare repository: $CACHE"
  # These are the only fetches in normal operation, and both write only refs in
  # the standalone cache. The live checkout is a read-only source URL here.
  GIT_TERMINAL_PROMPT=0 git -C "$CACHE" fetch --no-tags --quiet "$ROOT" \
    "+$head:refs/fm-watch/fork-head"
  GIT_TERMINAL_PROMPT=0 git -C "$CACHE" fetch --no-tags --quiet "$upstream_url" \
    "+refs/heads/$branch:refs/fm-watch/upstream"
  tip=$(git -C "$CACHE" rev-parse refs/fm-watch/upstream)
  watermark=
  [ -f "$WATERMARK_FILE" ] && IFS= read -r watermark <"$WATERMARK_FILE" || true

  stamp=${FM_UPSTREAM_WATCH_STAMP:-$(date -u +%Y-%m-%d-%H%M%SZ)}
  case "$stamp" in ''|*[!A-Za-z0-9._-]*) die "unsafe report stamp: $stamp" ;; esac
  report="$REPORTS/$stamp.md"
  [ ! -e "$report" ] || report="$REPORTS/$stamp-$$.md"
  tmp_report=$(mktemp "$REPORTS/.report.XXXXXX")
  if ! "$SCRIPT_DIR/fm-upstream-watch-generate.sh" \
    --git-dir "$CACHE" \
    --base refs/fm-watch/fork-head \
    --tip refs/fm-watch/upstream \
    --ledger "$ledger" \
    --watermark "$watermark" \
    --fork-root "$ROOT" \
    --upstream-url "$upstream_url" >"$tmp_report"; then
    rm -f "$tmp_report"
    die 'report generation failed'
  fi
  chmod 600 "$tmp_report"
  mv "$tmp_report" "$report"
  write_atomic "$WATERMARK_FILE" "$tip"
  write_atomic "$PENDING_FILE" "$report"
  printf 'UPSTREAM_REPORT: wrote private report %s (watermark %s)\n' "$report" "${tip:0:12}"
}

case "${1:-}" in
  run)
    [ "$#" -eq 1 ] || die 'run takes no arguments'
    run_watch
    ;;
  pending)
    [ "$#" -eq 1 ] || die 'pending takes no arguments'
    pending
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
