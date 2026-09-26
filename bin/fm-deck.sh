#!/usr/bin/env bash
# fm-deck.sh - the captain's private ACTION DECK pane.
#
# One refreshing, read-only terminal view that answers "what is waiting for me"
# above the fold and then shows what is moving. It is captain-private: it renders
# only from records this home already keeps and holds no queue, no cache, and no
# state of its own beyond the frame it is currently drawing.
#
# Sections, most-actionable first:
#   STAGED FOR YOUR CLICK  bin/fm-tray.sh json, grouped by standing order using
#                          bin/fm-order.sh list --no-tray-depth (age headline,
#                          expiry countdown)
#   NEEDS YOU              parked and blocked work, pull requests that are ready
#                          to review with their full URL, and durable captain
#                          decisions; one row per worker, one row per pull
#                          request however many records carry it, and a failed
#                          worker's pull request is not ready to review. When
#                          the backlog cannot be read at all, the section says
#                          so and falls back to this home's own record of a
#                          finished worker's pull request rather than dropping it
#   LOOSE ENDS             data/loose-ends/latest.md, the manual inbox sweep
#   UNDER WAY              one outcome line per recorded worker
#   JUST IN                recent completions and findings
#
# Herdr workspace registration: firstmate opens this pane as its own tab in the
# captain's "Company Starship" workspace with
#   herdr tab create --workspace <id> --label 'Action Deck' --command 'bin/fm-deck.sh'
# where <id> is that workspace's recorded id. This script never drives Herdr
# itself; the screen doctrine owns tab layout.
#
# Every section degrades to an honest empty line rather than an error when its
# source is missing or empty, because a pane that errors out is a pane the
# captain stops trusting.
#
# State vocabulary and colours come from bin/fm-visible-format-lib.sh, the one
# owner of that captain-facing wording. The UNDER WAY state is a projection of
# the durable status stream folded by bin/fm-classify-lib.sh, labelled REPORTED
# because that is what it is: bin/fm-crew-state.sh remains the owner of live
# current state, and the deck deliberately does not call it so a refresh stays
# well under a second.
#
# Usage:
#   fm-deck.sh [--interval <secs>]   refresh until interrupted (default 15)
#   fm-deck.sh --once                print one snapshot and exit
#   fm-deck.sh --json                print one snapshot as the fm-deck.v1 JSON
#                                    model and exit: the same collection and
#                                    the same reading rules as the pane, for a
#                                    second renderer such as the bridge's
#                                    /deck page (docs/bridge-view.md). Model
#                                    fields are owned by bin/fm-deck-render.py
#   fm-deck.sh -h|--help
#
# Environment:
#   FM_HOME / FM_DATA_OVERRIDE / FM_STATE_OVERRIDE / FM_CONFIG_OVERRIDE
#                          home and root directories
#   FM_DECK_COLUMNS        render width; else COLUMNS, else the terminal's own
#                          window size, else tput cols, else 100
#   FM_DECK_NOW            override unix epoch for ages and the clock (tests)
#   FM_DECK_JUST_IN        completions to show in JUST IN (default 5)
#   FM_DECK_LOOSE_ENDS     urgent/waiting loose ends to show (default 5)
#   FM_DECK_NEEDS_YOU      rows to show in NEEDS YOU before "+n more" (default 8)
#   FM_DECK_MAX_FRAMES     stop after this many refreshes; test seam so the
#                          suite can assert the loop's redraw without killing a
#                          process. Unset means refresh until interrupted.
#
# Exit:
#   0 on success, or on any single source being absent or unreadable
#   1 on usage error or a missing python3
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

DEFAULT_INTERVAL=15

# The payload's section boundary carries a per-run nonce, because the payload
# also carries text this home did not author: an inbox sweep assembled from mail
# and chat, a worker's own outcome line, a backlog title. With a fixed sentinel
# any one of those lines could open a section of its own and overwrite a real
# one - a crafted sweep line could rewrite NEEDS YOU, inventing an ask or hiding
# one. Every byte a collector prints is DATA; only this process knows what
# STRUCTURE looks like, so no source can be quoted into a boundary.
new_section_mark() {
  local nonce=''
  nonce=$( (head -c 16 /dev/urandom 2>/dev/null || true) \
    | od -An -tx1 2>/dev/null | tr -dc 'a-f0-9' || true)
  [ -n "$nonce" ] || nonce="$$-$(date +%s 2>/dev/null || printf '0')-${RANDOM:-0}"
  printf '__FM_DECK_SECTION_%s__\n' "$nonce"
}
SECTION_MARK=$(new_section_mark)

# fm_visible_state / fm_visible_icon own the captain-facing state wording.
# shellcheck source=bin/fm-visible-format-lib.sh
. "$SCRIPT_DIR/fm-visible-format-lib.sh"
# status_open_decisions / status_declared_wait_line / last_status_line own the durable
# status fold, so the deck never re-derives "is this decision still open".
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# fm_tasks_axi_backend_available owns whether the backlog is readable this way.
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

usage() {
  cat <<'EOF' >&2
usage: fm-deck.sh [--interval <secs>]
       fm-deck.sh --once
       fm-deck.sh --json
       fm-deck.sh -h|--help

The captain's private Action Deck pane: staged actions awaiting his click, what
needs him, his loose ends, live work, and recent outcomes. Read-only over
records this home already keeps; it approves, merges, and mutates nothing.
EOF
}

fail() {
  printf 'fm-deck: %s\n' "$*" >&2
  exit 1
}

now_ts() {
  if [ -n "${FM_DECK_NOW:-}" ]; then
    printf '%s\n' "$FM_DECK_NOW"
    return 0
  fi
  date +%s
}

positive_int() {  # <value>
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -gt 0 ]
}

# COLUMNS first, then the terminal's own window size read off stdin, and only
# then tput. tput answers from terminfo unless it can see a terminal on its
# stdout, and this runs as the left side of a pipeline, so on a wide tab it
# would report a static 80 and the width-aware columns would never engage.
# stdin is still the tab's terminal, which is what `stty size` asks.
render_width() {
  local cols size
  if [ -n "${FM_DECK_COLUMNS:-}" ]; then
    printf '%s\n' "$FM_DECK_COLUMNS"
    return 0
  fi
  cols=${COLUMNS:-}
  if ! positive_int "$cols"; then
    size=$(stty size 2>/dev/null || true)
    cols=${size##* }
  fi
  if ! positive_int "$cols"; then
    cols=$(tput cols 2>/dev/null || true)
  fi
  positive_int "$cols" || cols=100
  printf '%s\n' "$cols"
}

meta_value() {  # <meta-file> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1
}

# The home's own display name, so the pane says "Starship" not a path.
home_label() {
  "$SCRIPT_DIR/fm-project-display-name.sh" "$(basename "$FM_HOME")" 2>/dev/null || basename "$FM_HOME"
}

# --- source collection ------------------------------------------------------
# Each collector prints its blob and always succeeds: an absent or broken source
# yields an empty blob, and the renderer turns that into an honest empty section.

collect_tray() {
  "$SCRIPT_DIR/fm-tray.sh" json 2>/dev/null || printf '%s\n' '[]'
}

collect_staging() {
  # Device staging runs, rendered into the sections that already own each state:
  # a run awaiting the captain is staged, a run still working is under way, and
  # a run that needs a person is a need. The deck adds no section of its own.
  "$SCRIPT_DIR/fm-fota-stage-run.sh" list --json 2>/dev/null || printf '%s\n' '[]'
}

collect_orders() {
  # --no-tray-depth: the pane groups staged cards by the tray rows it already
  # read itself, so the depth fm-order.sh would otherwise compute costs two more
  # python3 folds of the whole audit log per standing order per frame and is
  # then thrown away. fm-order.sh stays the only reader of Status and last fire.
  "$SCRIPT_DIR/fm-order.sh" list --no-tray-depth 2>/dev/null || true
}

# Why the backlog read reports WHY it came back empty, and not just that it did:
# an empty backlog and an unreadable one look identical downstream, and the pane
# reads the two the same way - as "there is nothing here". That is a lie the
# captain cannot see through, and it costs him a finished worker's pull request,
# which the renderer deliberately lets the backlog row carry. The renderer turns
# this token into the section's source-availability wording; the tokens are ok,
# manual, no-tool, no-file and unreadable.
BACKLOG_STATUS=ok

collect_backlog() {
  # Every frame answers for itself: a read that failed last time says nothing
  # about this one, and a stale "unreadable" would keep the fallback rows and
  # the source-availability wording on the pane long after the reader came back.
  BACKLOG_STATUS=ok
  # Deliberately NOT fm_tasks_axi_backend_available: that probe shells out three
  # more times to confirm the MUTATION features (update --archive-body, atomic
  # multi-id mv) this pane will never use, and it is the single slowest thing in
  # a refresh. A view needs only "is this home's backlog readable this way", and
  # a `list` that fails anyway falls through to an honest empty section.
  if fm_backlog_backend_manual "$CONFIG"; then
    BACKLOG_STATUS=manual
    return 0
  fi
  if ! command -v tasks-axi >/dev/null 2>&1; then
    BACKLOG_STATUS=no-tool
    return 0
  fi
  if [ ! -f "$DATA/backlog.md" ]; then
    BACKLOG_STATUS=no-file
    return 0
  fi
  # --file pins the read to THIS home's backlog: without it tasks-axi resolves
  # its markdown path relative to the caller's directory, so the pane would show
  # whatever queue happened to sit under the shell's cwd. Same reason
  # bin/fm-backlog-handoff.sh passes it.
  tasks-axi list --file "$DATA/backlog.md" \
    --fields hold_kind,hold_reason,links,closed,blocked_by,held,priority \
    2>/dev/null || BACKLOG_STATUS=unreadable
  return 0
}

collect_loose_ends() {
  local f="$DATA/loose-ends/latest.md"
  [ -f "$f" ] || return 0
  # Home-relative, because the pane points him at a file to open, not at a path
  # to parse; the absolute prefix is the same on every line and just costs width.
  printf 'path\t%s\n' "${f#"$FM_HOME"/}"
  printf 'age_secs\t%s\n' "$(file_age_secs "$f")"
  printf 'body\n'
  cat "$f" 2>/dev/null || true
}

# Portable mtime in epoch seconds, branching on the platform the way every other
# lib here does. It cannot be a `stat -f %m || stat -c %Y` chain: on GNU stat
# `-f` selects FILESYSTEM mode, where %m is not mtime, so that call succeeds and
# prints a non-mtime token instead of failing over. The chain therefore reads -1
# on Linux and every age on the pane silently degrades to "not reported yet".
file_mtime_secs() {  # <file> -> epoch seconds, or empty
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

file_age_secs() {  # <file> -> seconds since mtime, or -1
  local f=$1 mtime now
  mtime=$(file_mtime_secs "$f" || true)
  case "$mtime" in
    ''|*[!0-9]*) printf '%s\n' -1; return 0 ;;
  esac
  now=$(now_ts)
  printf '%s\n' "$((now - mtime))"
}

# Project the durable status stream onto one canonical state name. Open
# decisions win over the last line, because a keyed needs-decision or blocked
# must never be masked by a later unrelated event - that is exactly what
# status_open_decisions folds for.
reported_state() {  # <status-file> -> <state>
  local f=$1 decisions row last verb effective resolve paused held
  if [ ! -f "$f" ]; then
    printf 'none'
    return 0
  fi
  decisions=$(status_open_decisions "$f")
  if [ -n "$decisions" ]; then
    row=$(printf '%s\n' "$decisions" | awk -F'\t' '$2 == "needs-decision" { print; exit }')
    if [ -n "$row" ]; then
      printf 'parked'
      return 0
    fi
    row=$(printf '%s\n' "$decisions" | awk -F'\t' '$2 == "blocked" { print; exit }')
    if [ -n "$row" ]; then
      printf 'blocked'
      return 0
    fi
  fi
  last=$(last_status_line "$f")
  if [ -z "$last" ]; then
    printf 'none'
    return 0
  fi
  # A trailing `resolved:` line is an event about a DECISION, not the crew's own
  # last word about the work, so read the state from the line before it. Without
  # this, a worker that finished or failed and then had an unrelated decision
  # resolved afterwards renders as still working - a failed worker showing up
  # blue on his pane is the wrong way round to be wrong. The look-back uses the
  # fold's own helper, and the declared wait below is status_declared_wait_line,
  # the rule the watcher and supervisor use, so a resolved line carrying the
  # pause's own phase key ends the declared wait here too; the task then falls
  # to the verb map below, where nobody having spoken since still reads as
  # waiting.
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  if [ "$(status_line_verb "$last")" = "$resolve" ]; then
    effective=$(_fm_last_non_resolve_line "$f")
    [ -z "$effective" ] || last=$effective
  fi
  if [ -n "$(status_declared_wait_line "$f")" ]; then
    printf 'paused'
    return 0
  fi
  # Map every verb the status vocabulary defines, so `unknown` means a verb this
  # projection genuinely does not know rather than a common one that happens to
  # land on the same label by luck. needs-decision, blocked and resolved reach
  # here only once the fold has closed the decision they carried, so all the
  # deck knows is that nobody has spoken since: that is the waiting state, not
  # observed activity. A declared wait reaches here whenever the fold did not
  # already claim it above - for example a pause behind a trailing resolve line
  # that closed an ordinary decision rather than a captain hold.
  verb=$(status_line_verb "$last")
  paused=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  case "$verb" in
    done) printf 'done' ;;
    failed) printf 'failed' ;;
    working) printf 'working' ;;
    needs-decision|blocked|"$resolve"|"$paused"|"$held") printf 'paused' ;;
    *) printf 'unknown' ;;
  esac
}

# One TSV row per recorded worker:
#   id, kind, project label, outcome, state, seconds since last heard, PR
collect_tasks() {
  local meta id kind project outcome status_log state heard pr
  [ -d "$STATE" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    kind=$(meta_value "$meta" kind)
    [ -n "$kind" ] || kind=ship
    project=$(project_label "$meta")
    outcome=$("$SCRIPT_DIR/fm-task-outcome.sh" "$id" "$(meta_value "$meta" outcome)" 2>/dev/null || printf '%s' "$id")
    status_log="$STATE/$id.status"
    state=$(reported_state "$status_log")
    if [ -f "$status_log" ]; then
      heard=$(file_age_secs "$status_log")
    else
      heard=-1
    fi
    pr=$(meta_value "$meta" pr)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$id" "$kind" "$project" "$(one_line "$outcome")" \
      "$state" "$heard" "$pr"
  done
}

one_line() {  # <text>
  printf '%s' "$1" | tr '\r\n\t' '   ' | tr -s ' ' | sed 's/^ *//; s/ *$//'
}

# The project a worker is changing, as the captain names it.
project_label() {  # <meta-file>
  local explicit project slug
  explicit=$(meta_value "$1" herdr_project_name)
  if [ -n "$explicit" ]; then
    one_line "$explicit"
    return 0
  fi
  project=$(meta_value "$1" project)
  [ -n "$project" ] || { printf '%s' '-'; return 0; }
  slug=$(basename "$project")
  "$SCRIPT_DIR/fm-project-display-name.sh" "$slug" 2>/dev/null || printf '%s' "$slug"
}

# The captain-facing state label and dot for every state the projection emits,
# resolved here so the renderer never re-implements the vocabulary.
collect_vocabulary() {
  local canonical visible
  for canonical in parked failed blocked working paused 'done' unknown none; do
    visible=$(fm_visible_state "$canonical")
    printf '%s\t%s\t%s\n' "$canonical" "$visible" "$(fm_visible_icon "$visible")"
  done
}

emit_payload() {
  printf '%s now\n%s\n' "$SECTION_MARK" "$(now_ts)"
  printf '%s width\n%s\n' "$SECTION_MARK" "$(render_width)"
  printf '%s home\n%s\n' "$SECTION_MARK" "$(home_label)"
  printf '%s interval\n%s\n' "$SECTION_MARK" "$1"
  printf '%s limits\n%s\t%s\t%s\n' "$SECTION_MARK" \
    "${FM_DECK_JUST_IN:-5}" "${FM_DECK_LOOSE_ENDS:-5}" "${FM_DECK_NEEDS_YOU:-8}"
  printf '%s vocabulary\n' "$SECTION_MARK"
  collect_vocabulary
  printf '%s tray\n' "$SECTION_MARK"
  collect_tray
  printf '%s staging\n' "$SECTION_MARK"
  collect_staging
  printf '%s orders\n' "$SECTION_MARK"
  collect_orders
  printf '%s backlog\n' "$SECTION_MARK"
  collect_backlog
  # After the collector, because that is what resolves BACKLOG_STATUS.
  printf '%s backlog_status\n%s\n' "$SECTION_MARK" "$BACKLOG_STATUS"
  printf '%s tasks\n' "$SECTION_MARK"
  collect_tasks
  printf '%s loose_ends\n' "$SECTION_MARK"
  collect_loose_ends
}

render() {  # <interval-or-empty>
  emit_payload "$1" | python3 "$SCRIPT_DIR/fm-deck-render.py" "$SECTION_MARK"
}

# The same payload, presented as the structured model instead of a frame.
render_json() {
  emit_payload '' | python3 "$SCRIPT_DIR/fm-deck-render.py" --json "$SECTION_MARK"
}

main() {
  local interval=$DEFAULT_INTERVAL once=0 as_json=0 frame

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --once) once=1; shift ;;
      --json) as_json=1; shift ;;
      --interval)
        [ "$#" -ge 2 ] || fail "--interval requires seconds"
        case "$2" in
          ''|*[!0-9]*) fail "--interval must be a positive whole number of seconds" ;;
        esac
        [ "$2" -gt 0 ] || fail "--interval must be a positive whole number of seconds"
        interval=$2
        shift 2
        ;;
      approve|execute|merge|arm|disarm|graduate)
        fail "read-only view: $1 stays on its own command; the deck never acts"
        ;;
      *) usage; exit 1 ;;
    esac
  done

  command -v python3 >/dev/null 2>&1 || fail "python3 not found"

  if [ "$as_json" -eq 1 ]; then
    render_json
    return 0
  fi
  if [ "$once" -eq 1 ]; then
    render ''
    return 0
  fi

  # Draw into a variable first, then clear and print in one write, so a refresh
  # does not flash a half-built pane at him.
  local drawn=0 max=${FM_DECK_MAX_FRAMES:-0}
  while :; do
    frame=$(render "$interval")
    printf '\033[H\033[2J\033[3J%s\n' "$frame"
    drawn=$((drawn + 1))
    if [ "$max" -gt 0 ] && [ "$drawn" -ge "$max" ]; then
      return 0
    fi
    sleep "$interval"
  done
}

main "$@"
