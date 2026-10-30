#!/usr/bin/env bash
# The daily to-do's durable item store: one record per thing asked of the captain.
#
# Usage:
#   fm-todo.sh sync [--morning-json FILE]
#   fm-todo.sh sweep-start [--at EPOCH] [--pass]
#   fm-todo.sh recheck [--since EPOCH ID ...]
#   fm-todo.sh verify --item ID --how TEXT [--rev REV] [--at EPOCH]
#   fm-todo.sh close --item ID --evidence TEXT [--reason fulfilled|dismissed|superseded] [--actor NAME]
#                    [--source-change DIGEST]
#   fm-todo.sh hand-over --item ID --to NAME --note TEXT [--rev REV] [--at EPOCH] [--source-change DIGEST]
#   fm-todo.sh reopen --item ID [--reason TEXT]
#   fm-todo.sh ack --item ID
#   fm-todo.sh command [--item ID [--rev REV] [--at EPOCH]] [LINE ...]   (lines on stdin when none given)
#   fm-todo.sh mark --item ID --name NAME (--text TEXT | --clear)
#   fm-todo.sh list [--state open|waiting|closed]
#   fm-todo.sh --help
#
# WHAT THIS IS. A LOCAL STORE ONLY. It never reads a source system, opens a
# network connection or sends anything. It folds durable records this home
# already holds into one item per ask, and bin/fm-todo-render.sh renders the
# day page from those items and nothing else:
#   - the channel-intake ledger (data/channel-intake items/ and archive/);
#   - the morning action sidecar .lavish/today-<date>.morning.json, whose
#     schema bin/fm-todo-render.sh owns;
#   - captain-held tasks in the markdown backlog, `(hold-kind: captain)`.
# Every render runs `sync` first, so the morning sweep and the intake passes
# during the day update the same items instead of the page being re-scraped.
#
# ITEM RECORD. data/todo/items/<id>.json keeps: aliases, one slot per source
# (its last observation and its own revision), `state` open|waiting|closed,
# `closure` {reason fulfilled|dismissed|superseded|resolved|released, actor,
# evidence, at}, `owner`, `snoozed_until`, `pending` handoff, `marks` (the
# lines an add-on put on the row, below), `source_change` (the change an
# add-on made at the source, below), `verification` {at, how, rev} and `rev`,
# the item's meaningful revision over its slots.
# data/todo/journal is an append-only line per transition or command effect.
# One lock serializes sync and every write. Sync deletes one kind of record
# and no other: a routine item or team update the intake retired, thirty days
# after that closure. A routine line marked with mine, park, you or dig is
# never retired that way, so it is never pruned either. Every closed
# obligation and every command tombstone is kept, so done and drop keep
# suppressing a reopen, and the journal is never trimmed.
#
# IDENTITY. An item is one ask. It is matched by an explicitly shared alias
# only: a ledger record's `source:ref`, key and provenance tokens; a morning
# action's `source:ref`, key and optional `aliases`; `firstmate-backlog:<task>`.
# Two asks on one thread are two items unless a source says they are the same.
#
# VERIFICATION IS ITS OWN FACT. Sync never renews it. It changes only on a
# newer source read: an open ledger record's change time (an unchanged re-read
# keeps its old time; a hand-over is not a read), a morning action's same-day
# `updated`, or an explicit `verify` by the orchestrator running the
# daily-todo-freshness procedure, which owns how an item is re-read. A backlog
# hold time and a report's written time are never verification. The page calls
# a line current only when its check is at or after this build's sweep
# (`sweep-start`, or `sweep_started` in the sidecar; else the start of the
# day) and checked the revision now shown. `sweep-start --pass` records an
# intake pass instead of a morning sweep: it raises the freshness floor only
# for items a pass can re-read (those `recheck` lists by their source refs); a
# held decision or a Firstmate-internal line still answers to the morning
# sweep. A pass never moves the page's "Closed since" boundary, which stays at
# the previous morning sweep.
#
# RE-CHECK ON EVERY PASS. `recheck` prints one `recheck:` line per open or
# waiting item that names an external source to re-read: id, revision, state,
# source label, its source refs (the item's `source:ref` aliases, never a
# ledger key, a held decision or a Firstmate-internal line), link and title,
# tab-separated. A parked item, routine activity and a team update are not
# listed; like a held decision, they answer to the morning sweep's freshness
# floor, never a pass's. bin/fm-channel-intake.sh `claim` prints these and the
# pass answers each with `verify` or `close`. `recheck --since EPOCH ID ...`
# prints one `TODO_RECHECK:` line counting the listed ids still open or
# waiting with no verification at or after EPOCH, and names them.
#
# TITLES CARRY NO RELATIVE TIME. "today", "yesterday" and the days of a
# waiting or age phrasing ("WAITING N DAYS", "N days ago", "(N days)") rot the
# day after they are written, so they are stripped from every stored title and
# why; a deadline such as "tomorrow" or a duration the ask is about stays. The
# page computes ages itself from the item's ask time (`asked_at`: the earliest
# source's ask epoch, a ledger record's source epoch or creation, a morning
# action's `asked_at`, a held task's `since` day).
#
# CHANGES, NOT SNAPSHOTS. Sync applies only what changed since the last sync,
# so repeated syncs, an old sidecar and a re-asserted morning action are
# no-ops; closures and commands are tombstones that survive them. A closed
# item, or one an add-on handed over, reopens, with the reason shown, only
# when one of its sources' own meaningful revision changes to anything but the
# add-on's recorded source change, and that source did not resolve or park it
# in the same tick: the ledger's `edited_digest` over `digest`, a
# morning action's explicit `digest` (never its reworded title or daily key),
# a backlog hold's reason and date. Missing, unreadable or refused input
# closes nothing; a task that leaves the readable backlog's held set releases
# only that item, and a routine item the readable ledger no longer carries -
# the intake retires one past its brief horizon - closes as superseded unless
# it was marked. An unreadable ledger or backlog is not an absence and closes
# nothing.
#
# TIME-BOUND ASKS EXPIRE. An item a morning action gave an `ends_at` closes on
# the first sync after that time, as superseded by actor `auto-expiry` with
# the end time as evidence, so it moves to the page's closed fold. An item
# with no end time never expires, nor does one the captain marked (mine, a
# park not yet lapsed, or a pending you/dig). Each end time expires an item
# once: a `reopen` after expiry stays open, and only a source moving the end
# time can close it again; an expired item whose end time moves into the
# future, or that a morning action re-asserts with no end time, reopens.
#
# PAGE COMMANDS. `command` applies the captain's one-line verbs:
#   drop <words>            closed as dismissed
#   done <words>            closed as fulfilled
#   park <words> til <when> snoozed until YYYY-MM-DD, today, tomorrow, a
#                           weekday or next week; back on that day
#   mine <words>            owner=captain; tracked, not surfaced
#   you <words>: <what>     pending handoff to firstmate
#   dig <words>             pending investigation by firstmate
# Prefer --item with the row's id and --rev with the revision the page showed
# (both are in the page's queued note); a stale --rev is refused so an old page
# cannot act on a changed ask. Pass --at with the epoch the queued note gives
# as the time the captain typed it. Without --item, <words> must match exactly
# one open item's title or ask. Repeating a command is harmless (`already`).
# `you`/`dig` stay "handoff requested" on the page until firstmate accepts
# them with `ack`, which moves the item to waiting with owner firstmate;
# `reopen` brings a closed or waiting item back to the captain's lane, ending
# the hand-over, and refuses an item that is already open.
# Each line prints one `TODO_CMD:` result naming the item's source refs. A
# held backlog decision is never answered here: done/drop on one says to
# record the answer through bin/fm-captain-hold.sh, and the item releases when
# the backlog does. A line with no leading verb prints `TODO_CMD:
# not-a-command` and changes nothing. Exit 1 when any line was refused.
#
# ADD-ON VERBS. A home's add-on (bin/fm-addon.sh) can take more one-line verbs
# on a row through its `todo-verbs` hooks, for example changes to a ticket the
# row names. A line typed with --item that no verb above takes, against the
# revision the item still has (or with no --rev), is offered to each
# `todo-verbs` hook in name order, with the line as its one argument and
# FM_TODO_ITEM (the id), FM_TODO_ITEM_FILE (its record, read-only),
# FM_TODO_REV (the current revision), FM_TODO_AT (the epoch it was typed) and
# FM_TODO_STORE exported. A hook that takes the line prints one result line
# and exits 0, or exits non-zero to refuse it; the first line it printed is
# reported as `TODO_CMD: <line>`, and no later hook is offered the line. A hook
# that prints nothing does not take it. A line no hook takes stays
# `not-a-command`, as does an untargeted line or one typed against an older
# revision, so an add-on verb never acts on a changed ask. The store keeps
# nothing for such a verb: the hook records its own work, moves the item with
# `close`, `hand-over`, `reopen` or `mark`, and appends any wake it needs.
#
# HAND-OVER. `hand-over --item ID --to NAME --note TEXT` moves an open or
# waiting item to waiting on NAME, shown under "Waiting on others" as "NAME has
# it: TEXT", for example a ticket set to waiting on its owner or reassigned. It
# refuses a closed item, an empty name, the captain's own name (captain_names,
# singly or as one name) and a stale --rev; --at is when it was handed over.
# A source change brings a handed-over item back to the captain, like a closed
# one, unless the source itself resolved it or set it waiting in the same tick;
# `reopen` does too.
#
# THE ADD-ON'S OWN SOURCE CHANGE. An add-on that changes the source itself,
# such as closing or reassigning the ticket a row names, passes
# `--source-change DIGEST` to `close` or `hand-over`, where DIGEST is what its
# next pass observes that change with: the `observe --digest` value for the
# channel-intake ledger, or a morning action's `digest`. A sync that sees that
# revision does not reopen the item; any later, different revision, such as a
# new message after the add-on's change, still does. Any other transition of
# the item forgets the recorded change.
#
# MARKS. `mark --item ID --name NAME --text TEXT` puts one short line on the
# item's row, under that slug name, until `mark --item ID --name NAME --clear`
# removes it; a later --text under the same name replaces it. This is how an
# add-on shows its own state on a row, such as a change it has queued or one
# that failed. A mark never changes the item's state, revision or freshness.
#
# Paths: data/todo (FM_TODO_STORE_OVERRIDE), data/channel-intake, and the
# backlog path from .tasks.toml's markdown backend (FM_TODO_BACKLOG_OVERRIDE).
# The zone, source inventory and captain_names are the ones
# bin/fm-todo-render.sh resolves. FM_TODO_NOW pins the clock for tests.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STORE="${FM_TODO_STORE_OVERRIDE:-$DATA/todo}"
INTAKE_DIR="$DATA/channel-intake"
HOOK_TIMEOUT="${FM_ADDON_HOOK_TIMEOUT:-20}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-todo: %s\n' "$*" >&2
  exit 2
}

now_epoch() {
  local value=${FM_TODO_NOW:-${FM_TODO_RENDER_NOW:-}}
  if [ -n "$value" ]; then
    case "$value" in
      *[!0-9]*) die "FM_TODO_NOW must be an epoch second: $value" ;;
    esac
    printf '%s\n' "$value"
    return 0
  fi
  date +%s
}

# The markdown backend's path from .tasks.toml, relative to this home; any
# other backend has no file to fold, so held tasks are simply not read.
backlog_path() {
  local toml="$FM_HOME/.tasks.toml" rel
  if [ -n "${FM_TODO_BACKLOG_OVERRIDE:-}" ]; then
    printf '%s\n' "$FM_TODO_BACKLOG_OVERRIDE"
    return 0
  fi
  [ -f "$toml" ] || toml="$ROOT/.tasks.toml"
  [ -f "$toml" ] || return 0
  grep -Eq '^backend[[:space:]]*=[[:space:]]*"markdown"' "$toml" || return 0
  rel=$(sed -nE '/^\[markdown\]/,/^\[/ s/^path[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$toml" | head -n 1)
  [ -n "$rel" ] || return 0
  case "$rel" in
    /*) printf '%s\n' "$rel" ;;
    *) printf '%s/%s\n' "$FM_HOME" "$rel" ;;
  esac
}

# The zone, source inventory and captain_names are the ones bin/fm-todo-render.sh
# resolves from config/channel-intake; this script reads them rather than a second copy.
settings=$("$SCRIPT_DIR/fm-todo-render.sh" settings) || exit 2
zone=$(printf '%s\n' "$settings" | sed -n 's/^timezone=//p')
sources=$(printf '%s\n' "$settings" | sed -n 's/^sources_file=//p')
captain_names=$(printf '%s\n' "$settings" | sed -n 's/^captain_names=//p')
[ -z "$zone" ] || export TZ="$zone"

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') usage; exit 2 ;;
esac
cmd=$1
shift
case "$cmd" in
  sync|sweep-start|recheck|verify|close|hand-over|reopen|ack|command|mark|list) ;;
  *) die "unknown command: $cmd" ;;
esac

args=()
morning=''
item=''
shown_rev=''
typed_at=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --morning-json) [ "$#" -ge 2 ] || die '--morning-json requires a value'; morning=$2; shift 2 ;;
    --pass|--clear) args+=("$1"); shift ;;
    --item|--how|--evidence|--at|--since|--state|--rev|--actor|--reason|--name|--text|--to|--note|--source-change)
      [ "$#" -ge 2 ] || die "$1 requires a value"
      case "$1" in
        --item) item=$2 ;;
        --rev) shown_rev=$2 ;;
        --at) typed_at=$2 ;;
      esac
      args+=("$1" "$2"); shift 2 ;;
    --*) die "unknown argument: $1" ;;
    *) args+=("$1"); shift ;;
  esac
done

run_items() {
  python3 "$SCRIPT_DIR/fm-todo-items.py" "$cmd" --store "$STORE" --now "$(now_epoch)" \
    --intake "$INTAKE_DIR" --sources "$sources" --backlog "$(backlog_path)" \
    --morning-json "$morning" --captain-names "$captain_names" ${args[@]+"${args[@]}"}
}

[ "$cmd" = command ] || { run_items; exit; }

# A line no built-in verb took, typed against one row, is offered to the
# add-on's todo-verbs hooks; untargeted lines never are.
out=$(run_items) && code=0 || code=$?
hooks=''
if [ -n "$item" ] && printf '%s\n' "$out" | grep -q '^TODO_CMD: not-a-command '; then
  hooks=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-addon.sh" hooks todo-verbs 2>/dev/null || true)
fi
if [ -z "$hooks" ]; then
  [ -z "$out" ] || printf '%s\n' "$out"
  exit "$code"
fi

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
item_file="$STORE/items/$item.json"
current_rev=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("rev", ""))' \
  "$item_file" 2>/dev/null) || current_rev=''
now=$(now_epoch)
case "$typed_at" in ''|*[!0-9]*) typed_at=$now ;; esac
[ "$typed_at" -le "$now" ] || typed_at=$now

offer_line() {  # <line>: print the result line of the hook that took it, if any
  local line=$1 root hook result rc
  [ -n "$current_rev" ] || return 1
  [ -z "$shown_rev" ] || [ "$shown_rev" = "$current_rev" ] || return 1
  while IFS="$(printf '\t')" read -r root hook; do
    [ -n "$hook" ] || continue
    rc=0
    result=$(fm_run_timed "$HOOK_TIMEOUT" env FM_HOME="$FM_HOME" FM_ROOT="$ROOT" FM_HOOK_ROOT="$root" \
      FM_TODO_ITEM="$item" FM_TODO_ITEM_FILE="$item_file" FM_TODO_REV="$current_rev" \
      FM_TODO_AT="$typed_at" FM_TODO_STORE="$STORE" "$hook" "$line" </dev/null) || rc=$?
    result=$(printf '%s\n' "$result" | sed -n '/[^[:space:]]/{p;q;}')
    if fm_timed_out "$rc"; then
      printf 'fm-todo: todo-verbs hook %s ran out of time after %ss\n' "$hook" "$HOOK_TIMEOUT" >&2
      continue
    fi
    if [ "$rc" -ne 0 ]; then
      printf 'refused %s :: %s\n' "$line" "${result:-the add-on refused it (hook ${hook##*/}, exit $rc)}"
      return 0
    fi
    [ -z "$result" ] || { printf '%s\n' "$result"; return 0; }
  done <<EOF
$hooks
EOF
  return 1
}

while IFS= read -r result_line; do
  case "$result_line" in
    'TODO_CMD: not-a-command '*)
      if taken=$(offer_line "${result_line#TODO_CMD: not-a-command }"); then
        printf 'TODO_CMD: %s\n' "$taken"
        case "$taken" in refused\ *) code=1 ;; esac
        continue
      fi
      ;;
  esac
  printf '%s\n' "$result_line"
done <<EOF
$out
EOF
exit "$code"
