#!/usr/bin/env bash
# fm-tap-desk.sh - phone tap cards over captain decisions and ready merges.
#
# One private card file and one phone page let the captain answer every task
# held for the captain, and every ready task PR, with a single tap. There is no
# second decision lifecycle: a decision answer goes through
# bin/fm-captain-hold.sh answer as a compare-and-answer (--expect-identity), and
# a merge tap only ever through bin/fm-pr-merge.sh with every one of its checks.
# The .agents/opt-in-skills/tap-desk skill owns when firstmate runs each command
# and how it publishes the page and reads the taps back.
#
# Usage:
#   fm-tap-desk.sh export [--output <cards.json>] [--page <page.html>]
#   fm-tap-desk.sh route --taps <file-or-directory> [--apply]
#   fm-tap-desk.sh defaults [--days <n>] [--apply]
#   fm-tap-desk.sh mark <task-id> [--option <text>]... [--recommend <option>] [--easy-undo]
#   fm-tap-desk.sh mark <task-id> --clear
#   fm-tap-desk.sh body <task-id> (--marks-file <f> | --note-file <f>) [--expect-identity <identity>]
#
# CARDS. `export` reads every open captain call (a held task whose hold kind is
# captain and that `fm-captain-hold.sh open --identity` calls open, whatever
# the task's own kind) and every task whose metadata records pr= for an open,
# non-draft GitHub pull request, read live with gh. It writes the card file
# (schema fm-tap-cards.v1, default data/tap-desk/cards.json) and the phone page
# (default data/tap-desk/page.html: bin/fm-tap-desk.html with the cards
# inlined). Both are private, mode 0600, and stay under the home's data/; a row
# that cannot be read is named under not_shown rather than stopping the export.
# A decision card carries its options, firstmate's recommendation, its
# lifecycle identity, how long it has waited, whether it is marked easy to undo,
# and a keep the captain already tapped on this same question. Its choices are
# each option, keep, drop, and you decide. A merge card carries the PR URL and
# the live head commit as its identity; its choices are merge and not yet.
# Every card takes an optional short reason.
#
# Options and the recommendation are read the way bin/fm-decision-surface.mjs
# reads them, unless `mark` recorded explicit ones for the current question.
#
# TAPS. The page writes one document per card to its artifact database
# collection `taps`: {card, kind, id, identity, choice, option, reason,
# tapped_at}. `route` reads those documents from a JSON file (one document, an
# array, or an object with a documents array) or a directory of *.json files,
# such as the out_dir an artifact database list writes. It is a dry run unless
# --apply is given. For each tap it re-reads the current state rather than
# trusting the card:
#   - a decision tap whose identity no longer matches the open call, or whose
#     option is no longer offered, is stale and records nothing;
#   - an option answers the call; drop answers it with a drop record and closes
#     it; you decide applies the recorded recommendation, or records that
#     firstmate decides when none is recorded; the answer closes a task of kind
#     captain and releases (`answer --release`) a held work item so it resumes,
#     which fm-captain-hold refuses while the away record exists;
#   - keep leaves the hold in place and notes the keep and its reason in the
#     task body, and that question is then never given the seven-day default;
#   - merge runs `fm-pr-merge.sh <task> <pr> --expected-head <card head>`, so
#     a push after the card was made refuses instead of merging unseen commits;
#     not yet notes the reason in the task body.
# The decision text handed to fm-captain-hold names the chosen option, the
# reason, and that it came from the captain's tap. Every finished tap is
# appended to data/tap-desk/ledger.jsonl, so reading the same taps again is a
# no-op; a refused tap (for example checks still running) is not recorded and
# is tried again on the next route. A finished tap with a reason also appends a
# one-line rule candidate under "## Tap rule candidates" in data/learnings.md.
# `route` exits 1 when any tap was refused or unreadable.
#
# DEFAULTS. `defaults` lists open captain calls that waited at least --days
# (default and minimum 7) since their hold was set, carry the explicit
# easy-to-undo mark for the current question, and have a recorded recommended
# option; with --apply it answers each with that option through the same
# compare-and-answer path and records the answer as a default, not the
# captain's tap. It never defaults a call the captain deferred with --until or
# kept, and never one whose words read as destructive, irreversible,
# security-sensitive, money, outward to people, or a merge; that word check
# only ever refuses. Firstmate tells the captain each `defaulted:` line.
#
# MARKS. `mark` records explicit options, the recommended option, and the
# easy-to-undo field as body lines bound to the current lifecycle identity, so a
# re-held question never inherits them. --easy-undo needs --recommend and is
# refused for a decision of a class the default never decides. Easy to undo is
# never guessed: without this mark no decision is defaulted.
#
# BODY. `body` is the one writer of tap lines into a task body. It holds the
# same per-task control lock `fm-captain-hold.sh answer` takes, re-checks the
# expected identity under it (exit 3 when it changed), and appends a note or
# replaces the mark block. `mark` and `route` call it; it is not meant to be
# run by hand.
#
# Environment:
#   FM_HOME                    the home whose backlog, state, and data are read
#   FM_DATA_OVERRIDE, FM_STATE_OVERRIDE   test and layout overrides
#   FM_TAP_DESK_MERGE_BIN      merge command override for tests; defaults to
#                              bin/fm-pr-merge.sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
ENGINE="$SCRIPT_DIR/fm-tap-desk.mjs"
TEMPLATE="$SCRIPT_DIR/fm-tap-desk.html"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-tap-desk: %s\n' "$*" >&2
  exit 1
}

require_runtime() {
  command -v node >/dev/null 2>&1 || fail "node is required"
  command -v tasks-axi >/dev/null 2>&1 || fail "tasks-axi is required"
}

engine() {  # <command> [args...]
  local command=$1
  shift
  node "$ENGINE" "$command" --home "$FM_HOME" --root "$FM_ROOT" --data "$DATA" --state "$STATE" "$@"
}

validate_slug() {  # <label> <value>
  case "$2" in
    ''|*[!A-Za-z0-9._-]*) fail "$1 must be a non-empty privacy-safe slug: $2" ;;
  esac
}

LOCK_HELD=''
release_lock() {
  [ -n "$LOCK_HELD" ] || return 0
  fm_lock_release "$LOCK_HELD" || true
  LOCK_HELD=''
}

command_body() {
  local id=${1:-} marks='' note='' expect='' expect_given=0 current rc
  [ -n "$id" ] || { usage >&2; exit 2; }
  validate_slug task-id "$id"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --marks-file) shift; marks=${1:-} ;;
      --note-file) shift; note=${1:-} ;;
      --expect-identity) shift; expect=${1:-}; expect_given=1 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  if [ -n "$marks" ] && [ -n "$note" ]; then fail "pass only one of --marks-file and --note-file"; fi
  if [ -z "$marks" ] && [ -z "$note" ]; then fail "body needs --marks-file or --note-file"; fi
  require_runtime
  # shellcheck source=bin/fm-wake-lib.sh
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  trap release_lock EXIT
  # The same lock bin/fm-captain-hold.sh answer and hold take, so a body write
  # never interleaves with an answer that rewrites the same body.
  fm_lock_acquire_wait "$STATE/.control-$id.lock" || fail "could not lock $id"
  LOCK_HELD="$STATE/.control-$id.lock"
  if [ "$expect_given" = 1 ]; then
    rc=0
    current=$("$SCRIPT_DIR/fm-captain-hold.sh" open "$id" --identity) || rc=$?
    if [ "$rc" -ne 0 ] || [ "$current" != "$expect" ]; then
      printf 'fm-tap-desk: %s is no longer the question the card showed\n' "$id" >&2
      release_lock
      exit 3
    fi
  fi
  if [ -n "$marks" ]; then
    engine body-write --id "$id" --marks-file "$marks"
  else
    engine body-write --id "$id" --note-file "$note"
  fi
  release_lock
}

case "${1:-}" in
  export) shift; require_runtime; engine export --template "$TEMPLATE" "$@" ;;
  route) shift; require_runtime; engine route "$@" ;;
  defaults) shift; require_runtime; engine defaults "$@" ;;
  mark)
    shift
    [ "$#" -ge 1 ] || { usage >&2; exit 2; }
    validate_slug task-id "$1"
    id=$1
    shift
    require_runtime
    engine mark --id "$id" "$@"
    ;;
  body) shift; command_body "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
