#!/usr/bin/env bash
# Mothership monitoring: a built-in process-event adapter that wakes the first
# mate when something new for this Starship arrives in a Mothership room.
#
# Usage:
#   fm-procevent-mothership.sh on <room>
#   fm-procevent-mothership.sh off <room>
#   fm-procevent-mothership.sh status
#   fm-procevent-mothership.sh ensure
#   fm-procevent-mothership.sh read <result-file>
#   fm-procevent-mothership.sh told <result-file>
#   fm-procevent-mothership.sh answer <task-id> <option> [--source <text>]
#   fm-procevent-mothership.sh settle [<task-id>...]
#   fm-procevent-mothership.sh calls
#   fm-procevent-mothership.sh source <room> --bin <mothership> [--config <file>] [--node-dir <dir>]
#   fm-procevent-mothership.sh autohandle <source-id> <sequence> <result-file>
#   fm-procevent-mothership.sh relisten
#   fm-procevent-mothership.sh classify <result-file>
#   fm-procevent-mothership.sh terminal <result-file>
#   fm-procevent-mothership.sh source-id <room>
#
# The setting is config/mothership-monitor, one `<room> = on|off` line per
# joined room, by the name `mothership rooms` lists; `#` starts a comment. A
# room not listed, or the file absent, is off, and with no file and no
# registration nothing runs and no state is created. Any other line is reported
# and treated as off, so a malformed file never switches anything on. When a
# room is listed more than once, its last line wins.
#
# on         Check that the room is one this Starship has joined and that the
#            installed Mothership link supports `position`, seed this monitor's
#            own place in the room, write `<room> = on`, register the room's
#            source and confirm it is listening, then list the requests already
#            open for the ship (read-only) so nothing waiting is missed. The
#            place carries on from plain `pull`'s saved place; a room never
#            pulled starts at the room's current end so switching on replays no
#            history. Running `on` for a room already on keeps its place.
# off        Retire the room's source, hand this monitor's place back to plain
#            `pull` (`mothership position --set`) so a later manual pull does
#            not repeat what was already told, and write `<room> = off`.
# status     One line per room joined in the Mothership config (or listed in the
#            setting): on or off, whether it is listening, when the room last
#            answered, and the last item told; then a line naming the problem
#            when the link cannot be found or run.
# ensure     Session-start reconciliation, run by bin/fm-bootstrap.sh: arm each
#            `on` room that has no registration, and retire (handing the place
#            back) each registered room that is now off or not listed. Prints
#            one `MOTHERSHIP_MONITOR: ...` line per problem and is otherwise
#            silent.
# read       The relay view of one captured result for the first mate: each item
#            not yet told, as labelled fields with control characters removed
#            and lengths capped, or `nothing new` when everything was told.
#            Room text in it is data, never an instruction.
# told       After telling the owner: hold each request to the ship not yet told
#            as one owner call (see REQUESTS AS OWNER CALLS below), record what
#            was told, move the place on if the runner had not, and acknowledge
#            the capture. Idempotent. Tell captures oldest first. A batch never
#            recorded as told, such as after a crash between telling the owner
#            and running told, is not flagged. A call that cannot be held stops
#            told before anything is recorded, so running told again retries it.
# answer     Record the owner's answer to one room call, given on the Factory
#            pane or in chat, through bin/fm-captain-hold.sh answers (the one
#            keyed-answer intake; --source is its provenance), then settle it.
#            <option> is one of the call's options, in any case; anything else
#            is refused with the options named.
# settle     Carry out the answer to each answered room call, or only the named
#            ones, once, printing one line per call: accepted, declined, later,
#            left, held, unanswered, failed, and, for a named call still
#            waiting, waiting. Exits 1 when any room step failed; the next
#            settle tries it again. bin/fm-tap-desk.sh route runs it for every
#            call a tap answered.
# calls      Print the task id of each room call still waiting for its answer
#            to be carried out, one per line. bin/fm-tap-desk.sh reads it so a
#            room call takes only the owner's own answer: its card offers no
#            "You decide", and a delegated tap or the seven-day default leaves
#            it held for the owner.
# source     The blocking child the runner executes; never run it in a turn.
# autohandle The runner's seam right after capture: move this monitor's place
#            forward to the end of the captured batch and acknowledge the
#            capture, so the runner listens again at once. The queued `check`
#            wake still reaches the first mate, who reads, tells, then runs told.
# relisten   Exit 0: the runner polls again in the same process after an empty
#            window and after a handled capture.
# classify   Print items, refused, error, or unknown.
# terminal   Exit 0 for a refused or error result, which ends the source.
# source-id  Print the canonical source id, mothership-<room>.
#
# One window of `source` runs `mothership pull --room <room> --from <place>
# --wait 55 --max 50`, a read that neither reads nor moves plain `pull`'s saved
# place, and ends:
#   - nothing new, place unchanged: exit 75 (an empty window) with no output;
#   - nothing new for this ship but the place moved: save the new place, exit 75;
#   - items: print a `schema=fm-mothership-pull.v1` result naming the place it
#     read from and the place after the batch, then the item lines, exit 0,
#     without moving the place (autohandle or told moves it after capture);
#   - the room cannot be reached (pull exit 3, or no answer within the window):
#     note it in <room>.unreachable, wait out the rest of the window, exit 75,
#     so an offline or sleeping machine costs one attempt a minute and wakes no
#     one;
#   - the room refuses the key (pull exit 4): a `status=refused` result, which
#     is terminal;
#   - any other failure: wait out the window and exit 75, and after five in a
#     row a `status=error` result, which is terminal; malformed pull output is
#     an error result at once.
# A terminal result retires the source; the next session start re-arms an `on`
# room, so a room still refusing is reported again.
#
# The place moves only after a capture is durable, so a crash before that reads
# the same items again, and the told mark keeps `read` from showing them twice.
# A crash between telling the owner and running `told` can still repeat one
# batch once. Every `pull`, this one included, marks the ship's own cards "read
# by your ship" in rooms whose allow-list is not empty; that is the only thing
# monitoring sends to a room on its own.
#
# REQUESTS AS OWNER CALLS. A request to the ship is never a chat question:
# `told` holds it as one task for the owner (bin/fm-captain-hold.sh hold), id
# ms-<room>-<card>, titled `Take on "<title>" from the <room> room?`, whose
# reason ends `Choose: Take on under <project>; OR ...; OR Decline; OR Later`
# with one take-on option per project the room's allow-list names (the
# Mothership config `status` reads). A room that allows no project hears
# nothing from this Starship, so its call offers only Later and Leave it. The
# call is then one of the owner's calls, counted and answered on the bridge
# strip, the Factory pane and any tap page. A card that already has a call
# waiting gets no second one; a card asked again after its call was settled
# gets a new call. Holding a call sends nothing to the room. Only the owner's
# answer does, through `settle`: a take-on option runs `mothership accept
# <card> --project <project>`, Decline runs `mothership decline` under the
# first allowed project, each with a `--tag` for every tag the allow-list
# names that project with when it never names it without tags, and with a
# client id fixed per call so a retry after a crash counts once in the room;
# Later holds a new call for the same card until three days later
# (FM_MOTHERSHIP_NOW, an epoch, is the test seam for now); Leave it, a tap's
# drop, or a call closed as already settled sends nothing. A room request
# takes only the owner's own answer: one naming none of the options sends
# nothing and holds a new call for the same card for the owner at once. The
# chosen option is read from the call's newest recorded resolution (`Chosen
# option:` from a tap, `Answer:` from the keyed intake).
#
# Private state, under state/mothership/: <room>.position (this monitor's
# place), <room>.told (the end of the latest batch told, seeded with the
# place), calls/ms-<room>-<card>.json (one room call: its room, card,
# title, current task, options and whether its answer was carried out),
# <room>.contact (when the room last answered), <room>.failures (failures
# in a row), and <room>.unreachable while the room cannot be reached, for the
# bridge strip's red alert (bin/fm-bridge-strip.sh): `since=<epoch>` (the first
# failed read in this run of them; a gap of more than 180 seconds since the
# last one starts a new run), `last=<epoch>` (the latest failed read), and
# `cause=tailscale` (Tailscale is installed here and not running, or, with no
# Tailscale command to ask, the room's name does not resolve) or `cause=room`.
# The room answering, `off`, and retiring the room remove it.
#
# The link is the first of: FM_MOTHERSHIP_BIN; the mothership command on PATH;
# and projects/mothership/bin/mothership in the home. A path FM_MOTHERSHIP_BIN
# names that cannot be run is reported, never passed over. A link that is a
# Node script runs with a node that can run TypeScript (22.18+, 23.6+ or 24+):
# the first such node on PATH, else the newest under $NVM_DIR (default
# ~/.nvm), because the first node on PATH may be
# an older one that stops with ERR_UNKNOWN_FILE_EXTENSION ".ts". The Mothership
# config `status` reads rooms from is $MOTHERSHIP_CONFIG, else
# ~/.config/mothership/rooms.json.
#
# Environment: FM_MOTHERSHIP_WAIT_SECONDS (1..55, default 55) is the window;
# FM_MOTHERSHIP_LINK_TIMEOUT (seconds, default 20) bounds every other link
# call, and a call that runs past it counts as failed. FM_MOTHERSHIP_TAILSCALE
# is the Tailscale command asked `status --json` after a failed read (default:
# tailscale on PATH; empty for none); it is asked only then, within 5 seconds.
# docs/configuration.md "Mothership monitoring (config/mothership-monitor)"
# owns the setting and its operating contract.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

ADAPTER=mothership
SETTING="$CONFIG/mothership-monitor"
MS_STATE="$STATE/mothership"
RESULT_SCHEMA=fm-mothership-pull.v1
MAX_ITEMS=50
FAILURE_LIMIT=5
EMPTY_WINDOW=75
TEXT_CAP=600
LATER_DAYS=3
WAIT_SECONDS=${FM_MOTHERSHIP_WAIT_SECONDS:-55}
case "$WAIT_SECONDS" in ''|*[!0-9]*) WAIT_SECONDS=55 ;; esac
[ "$WAIT_SECONDS" -ge 1 ] && [ "$WAIT_SECONDS" -le 55 ] || WAIT_SECONDS=55
LINK_TIMEOUT=${FM_MOTHERSHIP_LINK_TIMEOUT:-20}
case "$LINK_TIMEOUT" in ''|*[!0-9]*|0) LINK_TIMEOUT=20 ;; esac

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

# A room name becomes part of a source id, a file name and a wake line, so it is
# held to a short path-safe shape.
room_valid() {
  local LC_ALL=C
  [[ "${1-}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,47}$ ]]
}
require_room() { room_valid "${1-}" || die "not a room name: ${1-}"; }
source_id() { printf 'mothership-%s\n' "$1"; }
registered() { [ -f "$STATE/procevent/$(source_id "$1").source" ]; }
position_file() { printf '%s/%s.position\n' "$MS_STATE" "$1"; }
told_file() { printf '%s/%s.told\n' "$MS_STATE" "$1"; }
contact_file() { printf '%s/%s.contact\n' "$MS_STATE" "$1"; }
failures_file() { printf '%s/%s.failures\n' "$MS_STATE" "$1"; }
unreachable_file() { printf '%s/%s.unreachable\n' "$MS_STATE" "$1"; }
lock_path() { printf '%s/.%s.lock\n' "$MS_STATE" "$1"; }

state_prepare() {
  (umask 077; mkdir -p "$MS_STATE") || die "cannot create $MS_STATE"
  [ -d "$MS_STATE" ] && [ ! -L "$MS_STATE" ] || die "unsafe state directory: $MS_STATE"
}

# write_file <path> <content>: atomic, private.
write_file() {
  local dest=$1 tmp
  tmp=$(umask 077; mktemp "$MS_STATE/.write.XXXXXX") || return 1
  if printf '%s\n' "$2" > "$tmp" && chmod 0600 "$tmp" && mv -f -- "$tmp" "$dest"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# A place in a room, in the one canonical spelling used for every comparison:
# {"recordId": string|null, "cursor": whole number, "at": number}. Prints
# nothing and fails for anything else.
canonical_position() {
  printf '%s' "${1-}" | jq -ce '
    select(type == "object"
      and ((.recordId | type) == "string" or .recordId == null)
      and (.cursor | type) == "number" and .cursor >= 0 and (.cursor | floor) == .cursor
      and (.at | type) == "number" and .at >= 0)
    | {recordId, cursor, at}' 2>/dev/null
}

read_position() {  # <room>: the stored place, canonical, or nothing
  local file
  file=$(position_file "$1")
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  canonical_position "$(cat "$file")"
}

# Take the place out of one `{"position": {...}}` line, the shape `mothership position` and the
# end of `pull --from` print.
unwrap_position_line() {
  local inner
  inner=$(printf '%s' "${1-}" | jq -ce 'select(type == "object" and (keys == ["position"])) | .position' 2>/dev/null) || return 1
  canonical_position "$inner"
}

# One line, printable, capped: what may be shown from another machine's text.
sanitize_line() {  # <text> [cap]
  printf '%s' "${1-}" | jq -Rrs --argjson cap "${2:-$TEXT_CAP}" '
    explode
    | map(if . < 32 or . == 127 or (. >= 128 and . < 160)
            or (. >= 8234 and . <= 8238) or (. >= 8294 and . <= 8297) then 32 else . end)
    | implode | gsub("  +"; " ") | sub("^ "; "") | sub(" $"; "")
    | if length > $cap then .[0:$cap] + "..." else . end' 2>/dev/null
}

# ----- the setting -----

# Print `<room> <on|off>` per valid line, last line winning; report bad lines on
# stderr as MOTHERSHIP_MONITOR diagnostics.
setting_entries() {
  [ -f "$SETTING" ] || return 0
  LC_ALL=C awk '
    {
      line = $0
      sub(/#.*/, "", line)
      gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (line == "") next
      if (match(line, /^[A-Za-z0-9][A-Za-z0-9_-]*[ \t]*=[ \t]*[A-Za-z]+$/)) {
        key = line; sub(/[ \t]*=.*/, "", key)
        val = line; sub(/^[^=]*=[ \t]*/, "", val)
        if (length(key) <= 48 && (val == "on" || val == "off")) {
          if (!(key in seen)) order[++n] = key
          seen[key] = val
          next
        }
      }
      printf "MOTHERSHIP_MONITOR: config/mothership-monitor line %d is not \"<room> = on\" or \"<room> = off\"; treated as off\n", NR > "/dev/stderr"
    }
    END { for (i = 1; i <= n; i++) print order[i], seen[order[i]] }
  ' "$SETTING"
}

setting_of() {  # <room>: on or off
  local value
  value=$(setting_entries 2>/dev/null | awk -v room="$1" '$1 == room { print $2 }')
  [ "$value" = on ] && printf 'on\n' || printf 'off\n'
}

# Rewrite the setting with exactly one line for <room>, keeping every other line.
setting_write() {  # <room> <on|off>
  local room=$1 value=$2 tmp dir
  dir=$(dirname "$SETTING")
  (umask 077; mkdir -p "$dir") || die "cannot create $dir"
  tmp=$(umask 077; mktemp "$dir/.mothership-monitor.XXXXXX") || die "cannot write $SETTING"
  {
    if [ -f "$SETTING" ]; then
      LC_ALL=C awk -v room="$room" '
        {
          line = $0
          sub(/#.*/, "", line)
          gsub(/^[ \t]+|[ \t]+$/, "", line)
          key = line; sub(/[ \t]*=.*/, "", key)
          if (line != "" && key == room) next
          print
        }' "$SETTING"
    else
      printf '# A room switched on here wakes the first mate on new requests, answers and messages.\n'
      printf '# One line per joined room, by the name that mothership rooms lists.\n'
      printf '# A room not listed, or this file absent, is off.\n'
    fi
    printf '%s = %s\n' "$room" "$value"
  } > "$tmp" || { rm -f -- "$tmp"; die "cannot write $SETTING"; }
  mv -f -- "$tmp" "$SETTING" || { rm -f -- "$tmp"; die "cannot write $SETTING"; }
}

# ----- the Mothership link -----

LINK_BIN=
LINK_CONFIG=
LINK_NODE_DIR=
LINK_NODE=
LINK_PROBLEM=

# Whether <file> is a Node script, by its first line.
link_is_node() { head -n 1 "$1" 2>/dev/null | LC_ALL=C grep -aq '^#!.*node'; }

# Whether <node> runs a .ts file without flags: 22.18+, 23.6+ or 24+.
node_runs_typescript() {
  local said major minor
  [ -f "$1" ] && [ -x "$1" ] || return 1
  said=$(fm_run_timed 5 "$1" --version 2>/dev/null < /dev/null) || return 1
  [[ "$said" =~ ^v([0-9]+)\.([0-9]+) ]] || return 1
  major=$((10#${BASH_REMATCH[1]})) minor=$((10#${BASH_REMATCH[2]}))
  [ "$major" -ge 24 ] || { [ "$major" -eq 23 ] && [ "$minor" -ge 6 ]; } || { [ "$major" -eq 22 ] && [ "$minor" -ge 18 ]; }
}

# Every node worth trying, best first: each node on PATH in PATH order, then
# each nvm node, newest first.
node_candidates() {
  local dir path
  printf '%s\n' "$PATH" | tr ':' '\n' | while IFS= read -r dir; do
    [ -n "$dir" ] && [ -x "$dir/node" ] && printf '%s\n' "$dir/node"
  done
  for path in "${NVM_DIR:-$HOME/.nvm}"/versions/node/v*/bin/node; do
    [ -x "$path" ] && printf '%s\n' "$path"
  done | awk '{
      v = $0; sub(/.*\/versions\/node\/v/, "", v); sub(/\/.*/, "", v)
      split(v, p, /[^0-9]+/)
      printf "%d %d %d %s\n", p[1], p[2], p[3], $0
    }' | sort -k1,1nr -k2,2nr -k3,3nr | cut -d' ' -f4-
}

# Set LINK_NODE to the node that runs the link's TypeScript, or set
# LINK_PROBLEM and fail.
pick_node() {
  local node
  LINK_NODE=
  while IFS= read -r node; do
    node_runs_typescript "$node" && { LINK_NODE=$node; return 0; }
  done < <(node_candidates | awk '!seen[$0]++')
  LINK_PROBLEM="no node on this machine can run the Mothership link's TypeScript (it needs node 22.18 or newer); install one"
  return 1
}

# Sets LINK_BIN, LINK_CONFIG and LINK_NODE_DIR, or LINK_PROBLEM and fails. The
# link is the first of FM_MOTHERSHIP_BIN, the mothership command on PATH, and
# projects/mothership/bin/mothership in the home; a path FM_MOTHERSHIP_BIN
# names that cannot be run is reported rather than passed over.
resolve_link() {
  local bin from node
  LINK_BIN='' LINK_NODE_DIR='' LINK_PROBLEM=''
  if [ -n "${FM_MOTHERSHIP_BIN:-}" ]; then
    bin=$FM_MOTHERSHIP_BIN from=FM_MOTHERSHIP_BIN
  elif bin=$(command -v mothership 2>/dev/null) && [ -n "$bin" ]; then
    from=PATH
  elif [ -f "$FM_HOME/projects/mothership/bin/mothership" ]; then
    bin="$FM_HOME/projects/mothership/bin/mothership" from=projects/mothership
  else
    LINK_PROBLEM="the Mothership link is not installed: there is no mothership command on PATH or at projects/mothership/bin/mothership in this home (name its path in FM_MOTHERSHIP_BIN)"
    return 1
  fi
  case "$bin" in /*) ;; *) bin="$(cd "$(dirname "$bin")" 2>/dev/null && pwd)/$(basename "$bin")" ;; esac
  [ -f "$bin" ] && [ -x "$bin" ] || { LINK_PROBLEM="the mothership command at $bin (from $from) cannot be run"; return 1; }
  LINK_BIN=$bin
  # The link's own default config location is its business; only a config
  # this shell names is pinned, so the runner uses the same one later.
  LINK_CONFIG=${MOTHERSHIP_CONFIG:-}
  case "$LINK_CONFIG" in ''|/*) ;; *) LINK_CONFIG="$(pwd)/$LINK_CONFIG" ;; esac
  # A link written in TypeScript needs a node that runs it; the first node on
  # PATH may be an older one that stops with ERR_UNKNOWN_FILE_EXTENSION.
  if link_is_node "$bin"; then
    pick_node || { LINK_BIN=; return 1; }
    node=$LINK_NODE
  else
    node=$(command -v node 2>/dev/null || true)
  fi
  [ -z "$node" ] || LINK_NODE_DIR=$(cd "$(dirname "$node")" 2>/dev/null && pwd)
  return 0
}

# The timeout runs a program, never a shell function, so the environment the
# link needs is spelled out through env.
link_run_for() {  # <seconds> <args...>: run the link with the resolved command, config and node
  local seconds=$1
  shift
  local -a link_env=(PATH="${LINK_NODE_DIR:+$LINK_NODE_DIR:}$PATH")
  [ -z "$LINK_CONFIG" ] || link_env+=(MOTHERSHIP_CONFIG="$LINK_CONFIG")
  fm_run_timed "$seconds" env "${link_env[@]}" "$LINK_BIN" "$@" < /dev/null
}

link_run() { link_run_for "$LINK_TIMEOUT" "$@"; }  # <args...>

link_timeout_note() { printf 'the Mothership link did not answer within %ss\n' "$LINK_TIMEOUT"; }

joined_rooms() {  # print the joined rooms, or fail with the link's status
  local out rc=0
  out=$(link_run rooms 2>/dev/null) || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s\n' "$out" | awk 'NF { print $1 }'
}

room_joined() {  # <room>: fails 1 when it is not joined, 2 when the link timed out
  local rooms rc=0
  rooms=$(joined_rooms) || rc=$?
  ! fm_timed_out "$rc" || return 2
  printf '%s\n' "$rooms" | awk -v room="$1" '$1 == room { found = 1 } END { exit !found }'
}

# ----- the monitor's place and told mark -----

# Seed this monitor's place and told mark for <room> if it has no place. Prints a
# problem and fails.
seed_position() {  # <room>
  local room=$1 line saved err rc=0
  read_position "$room" >/dev/null && return 0
  err=$(mktemp "${TMPDIR:-/tmp}/fm-mothership-err.XXXXXX") || { printf 'cannot stage output\n'; return 1; }
  line=$(link_run position --room "$room" 2>"$err") || rc=$?
  if [ "$rc" -ne 0 ]; then
    if fm_timed_out "$rc"; then
      link_timeout_note
    else
      printf 'your Mothership link cannot keep a separate place (%s); update the Mothership link first\n' \
        "$(sanitize_line "$(tail -n 1 "$err")" 200)"
    fi
    rm -f -- "$err"
    return 1
  fi
  saved=$(unwrap_position_line "$(printf '%s\n' "$line" | tail -n 1)") || {
    rm -f -- "$err"
    printf 'your Mothership link printed a place Starship cannot read; update the Mothership link first\n'
    return 1
  }
  if [ "$(printf '%s' "$saved" | jq -r '.recordId == null and .cursor == 0')" = true ]; then
    line=$(link_run position --room "$room" --now 2>"$err") || rc=$?
    if [ "$rc" -ne 0 ]; then
      if fm_timed_out "$rc"; then
        link_timeout_note
      else
        printf 'could not read where the room ends: %s\n' "$(sanitize_line "$(tail -n 1 "$err")" 200)"
      fi
      rm -f -- "$err"
      return 1
    fi
    saved=$(unwrap_position_line "$(printf '%s\n' "$line" | tail -n 1)") || {
      rm -f -- "$err"
      printf 'your Mothership link printed a place Starship cannot read; update the Mothership link first\n'
      return 1
    }
  fi
  rm -f -- "$err"
  write_file "$(position_file "$room")" "$saved" || { printf 'cannot save the place\n'; return 1; }
  write_file "$(told_file "$room")" "$saved" || { printf 'cannot save the told mark\n'; return 1; }
}

# Move the place from <from> to <to> only while it still stands at <from>, so a
# replayed or stale capture never moves it, least of all backwards.
commit_locked() {  # <room> <from> <to>
  local room=$1 from=$2 to=$3 current
  current=$(read_position "$room" || true)
  [ -n "$current" ] && [ "$current" = "$from" ] || return 0
  [ "$from" = "$to" ] && return 0
  write_file "$(position_file "$room")" "$to"
}

with_lock() {  # <room> <command...>
  local room=$1 lock rc
  shift
  lock=$(lock_path "$room")
  fm_lock_acquire_wait "$lock" || return 1
  rc=0
  "$@" || rc=$?
  fm_lock_release "$lock"
  return "$rc"
}

# Whether place <a> is at or past place <b>: within one record by cursor, and
# across records (a room restart) by time, the room's own ordering rule.
place_at_or_past() {  # <a> <b>
  jq -en --argjson a "$1" --argjson b "$2" '
    if $a.recordId == $b.recordId then $a.cursor >= $b.cursor else $a.at >= $b.at end' >/dev/null
}

told_mark() {  # <room>: print the told mark, or fail when there is none
  local file
  file=$(told_file "$1")
  [ -f "$file" ] && canonical_position "$(cat "$file")"
}

# Record a batch told, ending at <to>. The mark only moves forward.
told_update_locked() {  # <room> <to>
  local room=$1 to=$2 current
  if current=$(told_mark "$room") && place_at_or_past "$current" "$to"; then return 0; fi
  write_file "$(told_file "$room")" "$to"
}

# ----- results -----

result_field() {  # <result-file> <key>: a header field, before the `--` line
  awk -v key="$2" '
    $0 == "--" { exit }
    index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }
  ' "$1"
}
result_items() { awk 'seen { print } $0 == "--" { seen = 1 }' "$1"; }

valid_result() {  # <result-file>
  [ -f "$1" ] && [ ! -L "$1" ] && [ "$(sed -n '1p' "$1")" = "schema=$RESULT_SCHEMA" ]
}

# The capture this file is: prints "<source-id> <sequence> <room>", or fails.
capture_identity() {  # <result-file>
  local file=$1 base id seq room adapter
  valid_result "$file" || return 1
  base=${file##*/}
  case "$base" in *.result) ;; *) return 1 ;; esac
  base=${base%.result}
  seq=${base##*.}
  id=${base%.*}
  case "$seq" in ''|*[!0-9]*) return 1 ;; esac
  room=$(result_field "$file" room)
  room_valid "$room" || return 1
  [ "$id" = "$(source_id "$room")" ] || return 1
  adapter=$(cat "${file%.result}.adapter" 2>/dev/null || true)
  [ "$adapter" = "$ADAPTER" ] || return 1
  printf '%s %s %s\n' "$id" "$seq" "$room"
}

# The items of one captured batch not yet told, one compact JSON object per
# line: everything past the told mark, by the room's own ordering rule.
untold_items() {  # <result-file> <room>
  local file=$1 room=$2 told to
  to=$(canonical_position "$(result_field "$file" to)") || return 1
  told=$(told_mark "$room" || printf 'null')
  result_items "$file" | jq -cnR --argjson told "$told" --argjson to "$to" '
    inputs | (try fromjson catch null) | select(type == "object" and (.seq | type) == "number")
    | select(
        if $told == null then true
        elif $told.recordId == $to.recordId then .seq > $told.cursor
        else $to.at > $told.at end)'
}

cmd_classify() {
  local file=${1-} status
  [ -n "$file" ] || usage
  if valid_result "$file"; then
    status=$(result_field "$file" status)
    case "$status" in items|refused|error) printf '%s\n' "$status"; return 0 ;; esac
  fi
  printf 'unknown\n'
}

cmd_terminal() {
  local file=${1-}
  [ -n "$file" ] || usage
  case "$(cmd_classify "$file")" in refused|error) return 0 ;; esac
  return 1
}

# Move the place on for one captured batch. 0 when done or nothing to do.
apply_capture() {  # <result-file> <room>
  local file=$1 room=$2 from to
  [ "$(result_field "$file" status)" = items ] || return 0
  from=$(canonical_position "$(result_field "$file" from)") || return 1
  to=$(canonical_position "$(result_field "$file" to)") || return 1
  with_lock "$room" commit_locked "$room" "$from" "$to"
}

cmd_autohandle() {
  local id=${1-} seq=${2-} file=${3-} identity cap_id cap_seq room
  [ -n "$file" ] || usage
  identity=$(capture_identity "$file") || return 1
  read -r cap_id cap_seq room <<EOF
$identity
EOF
  [ "$cap_id" = "$id" ] && [ "$cap_seq" = "$seq" ] || return 1
  state_prepare
  apply_capture "$file" "$room" || return 1
  "$SCRIPT_DIR/fm-procevent.sh" handled "$id" "$seq" >/dev/null || return 1
}

cmd_told() {
  local file=${1-} identity id seq room to count asks item
  [ -n "$file" ] || usage
  identity=$(capture_identity "$file") || die "not a captured Mothership result: $file"
  read -r id seq room <<EOF
$identity
EOF
  state_prepare
  apply_capture "$file" "$room" || die "cannot move the place on for $room"
  count=0
  if [ "$(result_field "$file" status)" = items ]; then
    # Each request to the ship becomes one owner call before the batch counts
    # as told, so a call that could not be held is tried again by running told
    # again rather than lost.
    asks=$(untold_items "$file" "$room" | jq -c 'select(.reason == "asked")') \
      || die "cannot read the requests in $file"
    while IFS= read -r item; do
      [ -n "$item" ] || continue
      ensure_call "$room" "$item" \
        || die "a request from $room could not be held as an owner call; nothing was recorded as told, so run told again"
    done <<EOF
$asks
EOF
    to=$(canonical_position "$(result_field "$file" to)") || die "the result has no place to record"
    with_lock "$room" told_update_locked "$room" "$to" || die "cannot record what was told for $room"
    count=$(result_items "$file" | grep -c . || true)
  fi
  "$SCRIPT_DIR/fm-procevent.sh" handled "$id" "$seq" >/dev/null || die "cannot acknowledge $id $seq"
  printf 'told: %s (%s item(s) in this batch)\n' "$room" "$count"
}

cmd_read() {
  local file=${1-} identity id seq room status
  [ -n "$file" ] || usage
  identity=$(capture_identity "$file") || die "not a captured Mothership result: $file"
  read -r id seq room <<EOF
$identity
EOF
  status=$(result_field "$file" status)
  printf 'room: %s\n' "$room"
  case "$status" in
    refused)
      printf 'status: refused\n'
      printf 'reason: %s\n' "$(sanitize_line "$(result_field "$file" reason)" 300)"
      printf 'meaning: the room refused this Starship'"'"'s key or removed its ship, and monitoring for this room has stopped; the owner may need a new invite (mothership join), then switch monitoring on again\n'
      return 0
      ;;
    error)
      printf 'status: error\n'
      printf 'reason: %s\n' "$(sanitize_line "$(result_field "$file" reason)" 300)"
      printf 'meaning: monitoring for this room has stopped; once the cause is fixed, switch it on again\n'
      return 0
      ;;
    items) ;;
    *) die "unreadable Mothership result: $file" ;;
  esac
  canonical_position "$(result_field "$file" to)" >/dev/null || die "the result has no place: $file"
  untold_items "$file" "$room" | jq -nr --argjson cap "$TEXT_CAP" '
    def clean($n):
      if type == "string" then
        explode
        | map(if . < 32 or . == 127 or (. >= 128 and . < 160)
                or (. >= 8234 and . <= 8238) or (. >= 8294 and . <= 8297) then 32 else . end)
        | implode | gsub("  +"; " ") | sub("^ "; "") | sub(" $"; "")
        | if length > $n then .[0:$n] + "..." else . end
      else "" end;
    def kind:
      { "asked": "asked your ship to do something",
        "answered": "answered a question your ship asked",
        "spoken to": "spoke to your ship",
        "changed": "changed a card your ship is on",
        "taken off": "took your ship off a card",
        "tagged": "brought your ship in on a card" }[tostring] // "changed something for your ship";
    [inputs]
    | if length == 0 then "nothing new"
      else
        "new: \(length)",
        (to_entries[] | .key as $i | .value |
          "item \($i + 1)",
          "  what: \((.byName | clean(120)) | if . == "" then "someone" else . end) \(.reason | kind)",
          "  card: \(.title | clean(200))",
          "  card-id: \(.card | clean(80))",
          "  says: \(.says | clean($cap))",
          (if (.value | type) == "object" and ((.value.text // .value.line // .value.note // null) | type) == "string"
           then "  text: \((.value.text // .value.line // .value.note) | clean($cap))" else empty end))
      end'
}

# ----- requests as owner calls -----
#
# The header's REQUESTS AS OWNER CALLS owns what these do. A call's record is
# named by its first task id, its base id, and follows it through every Later.

calls_dir() { printf '%s/calls\n' "$MS_STATE"; }
call_record() { printf '%s/%s.json\n' "$(calls_dir)" "$1"; }  # <base-id>

mothership_config_file() { printf '%s\n' "${MOTHERSHIP_CONFIG:-$HOME/.config/mothership/rooms.json}"; }

# The task id of the first call for one card: ms-<room>-<card>, path-safe.
call_base_id() {  # <room> <card>
  printf 'ms-%s-%s\n' "$(printf '%s' "$1" | tr '_' '-')" \
    "$(printf '%s' "$2" | LC_ALL=C tr -c 'A-Za-z0-9.-' '-' | cut -c1-64)"
}

# What the room's allow-list lets through, as a JSON array of {project, tags},
# in order, once per project; only names that can be a registered project's
# name. A project the list names without tags needs none, so its tags are
# empty; a project named only with tags carries them all, since the link lets
# an item through when it names one of them.
room_allow() {  # <room>
  local file
  file=$(mothership_config_file)
  [ -f "$file" ] || { printf '[]\n'; return 0; }
  jq -c --arg room "$1" '
    [(.rooms[$room].allow // []) | if type == "array" then .[] else empty end
      | objects | select((.project | type) == "string")
      | select(.project | test("^[A-Za-z0-9][A-Za-z0-9._-]*$") and length <= 64)
      | {project, tags: ((.tags // []) | if type == "array" then map(strings | select(length > 0 and (test("[[:cntrl:]]") | not))) else [] end)}]
    | reduce .[] as $e ([];
        if any(.[]; .project == $e.project)
        then map(if .project == $e.project
                 then .tags = (if (.tags | length) == 0 or ($e.tags | length) == 0 then [] else (.tags + $e.tags | unique) end)
                 else . end)
        else . + [$e] end)' "$file" 2>/dev/null || printf '[]\n'
}

# The options one call offers, as a JSON array of {label, action, project,
# tags}: take it on under each project the room allows, decline, or later. A
# room that allows no project of this Starship hears nothing from it, so its
# call offers only later and leave it.
call_options() {  # <room>
  room_allow "$1" | jq -c '
    if length == 0
    then [{label: "Later", action: "later"}, {label: "Leave it", action: "leave"}]
    else [.[] | {label: "Take on under \(.project)", action: "accept", project, tags}]
      + [{label: "Decline", action: "decline", project: .[0].project, tags: .[0].tags}, {label: "Later", action: "later"}]
    end'
}

# Hold one call. The reason ends in the options, so every surface that reads a
# held decision's options (bin/fm-decision-surface.mjs) shows exactly these.
hold_call() {  # <task-id> <room> <title> <options-json> [until]
  local id=$1 room=$2 title=$3 options=$4 until=${5:-} reason repo
  if [ "$(printf '%s' "$options" | jq -r 'any(.[]; .action == "accept")')" = true ]; then
    reason="A request to your ship from the $room room."
  else
    reason="A request to your ship from the $room room, which allows no project of this Starship yet, so it can be taken on or declined only once a project is added to the room's allow-list."
  fi
  reason="$reason Choose: $(printf '%s' "$options" | jq -r 'map(.label) | join("; OR ")')"
  repo=$(printf '%s' "$options" | jq -r '[.[] | .project // empty] | first // empty')
  set -- "$SCRIPT_DIR/fm-captain-hold.sh" hold "$id" \
    --title "Take on \"$title\" from the $room room?" --reason "$reason"
  [ -z "$repo" ] || set -- "$@" --repo "$repo"
  [ -z "$until" ] || set -- "$@" --until "$until"
  "$@" >/dev/null
}

write_call_record() {  # <base-id> <json>
  (umask 077; mkdir -p "$(calls_dir)") || return 1
  write_file "$(call_record "$1")" "$2"
}

# Make one request to the ship one owner call. A card that already has a call
# waiting gets no second one; a card asked again after its call was settled
# gets a new call.
ensure_call_locked() {  # <room> <item-json> <card> <base-id>
  local room=$1 item=$2 card=$3 base=$4 rec title gen id options
  rec=$(call_record "$base")
  title=$(sanitize_line "$(printf '%s' "$item" | jq -r '.title // "" | strings')" 120)
  [ -n "$title" ] || title="a request"
  gen=1 id=$base
  if [ -f "$rec" ]; then
    [ "$(jq -r '.settled != null' "$rec" 2>/dev/null)" = true ] || return 0
    gen=$(( $(jq -r '.generation // 1' "$rec") + 1 ))
    id="$base-$gen"
  fi
  options=$(call_options "$room") || return 1
  hold_call "$id" "$room" "$title" "$options" || return 1
  write_call_record "$base" "$(jq -cn --arg room "$room" --arg card "$card" --arg title "$title" \
    --arg base "$base" --arg task "$id" --argjson gen "$gen" --argjson options "$options" \
    '{room: $room, card: $card, title: $title, base: $base, task: $task, generation: $gen, options: $options, settled: null}')" \
    || return 1
  printf 'held: %s: take on "%s" from the %s room?\n' "$id" "$title" "$room"
}

with_call_lock() {  # <base-id> <command...>
  local lock rc
  lock="$MS_STATE/.call-$1.lock"
  shift
  fm_lock_acquire_wait "$lock" || return 1
  rc=0
  "$@" || rc=$?
  fm_lock_release "$lock"
  return "$rc"
}

ensure_call() {  # <room> <item-json>
  local room=$1 item=$2 card base
  card=$(printf '%s' "$item" | jq -r '.card // "" | strings')
  if ! [[ "$card" =~ ^[A-Za-z0-9_.-]{1,80}$ ]]; then
    printf 'not held: a request from the %s room names no card it can be answered on\n' "$room"
    return 0
  fi
  base=$(call_base_id "$room" "$card")
  with_call_lock "$base" ensure_call_locked "$room" "$item" "$card" "$base"
}

# The newest recorded resolution in a task body: records are prepended, so it
# is the first, from its label line to the next record.
newest_decision() {  # <decoded-body>
  printf '%s\n' "$1" | awk '
    /^Resolution recorded by fm-(captain|decision)-hold\.$/ { if (seen++) exit; next }
    seen && /^(Captain decision|Reconciliation evidence):$/ { inside = 1 }
    inside { print }'
}

task_body() {  # <task-id>: the decoded body
  local shown
  shown=$("$SCRIPT_DIR/fm-tasks-axi.sh" show "$1" --full 2>/dev/null) || return 1
  printf '%s\n' "$shown" | sed -n 's/^  body: //p' | head -n 1 \
    | jq -r 'if type == "string" then . else "" end' 2>/dev/null
}

later_date() {  # the date a call answered later is asked again
  local at
  at=$(( ${FM_MOTHERSHIP_NOW:-$(date +%s)} + LATER_DAYS * 86400 ))
  date -u -r "$at" +%Y-%m-%d 2>/dev/null || date -u -d "@$at" +%Y-%m-%d
}

mark_settled() {  # <base-id> <outcome>
  local rec
  rec=$(call_record "$1")
  write_call_record "$1" "$(jq -c --arg outcome "$2" --argjson at "$(date +%s)" \
    '.settled = {task: .task, outcome: $outcome, at: $at}' "$rec")"
}

# Run accept or decline for one call in its room. Prints a failed line and
# fails when the room was not told. The client id makes a retry after a crash
# count once in the room.
room_act() {  # <task-id> <action> <room> <card> <project> [<tag>...]
  local task=$1 action=$2 room=$3 card=$4 project=$5 tag err rc=0
  local -a args=("$action" "$card" --room "$room" --project "$project")
  shift 5
  for tag in "$@"; do args+=(--tag "$tag"); done
  if [ -z "$LINK_BIN" ] && ! resolve_link; then
    printf 'failed: %s: the %s room was not told: %s\n' "$task" "$room" "$LINK_PROBLEM"
    return 1
  fi
  err=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-mothership-err.XXXXXX") || return 1
  link_run "${args[@]}" --cid "fm-$task-$action" >/dev/null 2>"$err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if fm_timed_out "$rc"; then
      printf 'failed: %s: the %s room was not told: %s\n' "$task" "$room" "$(link_timeout_note)"
    else
      printf 'failed: %s: the %s room was not told: %s\n' "$task" "$room" "$(sanitize_line "$(tail -n 1 "$err")" 300)"
    fi
    rm -f -- "$err"
    return 1
  fi
  rm -f -- "$err"
}

# Hold the call's next generation for the owner, until a date when given, and
# move its record to it.
hold_next() {  # <base-id> <room> <title> <generation> [until]
  local base=$1 room=$2 title=$3 gen=$4 until=${5:-} options
  options=$(call_options "$room") || return 1
  hold_call "$base-$((gen + 1))" "$room" "$title" "$options" "$until" || return 1
  write_call_record "$base" "$(jq -c --arg task "$base-$((gen + 1))" --argjson gen "$((gen + 1))" --argjson options "$options" \
    '.task = $task | .generation = $gen | .options = $options' "$(call_record "$base")")"
}

# Do what the owner's answer to one call asks, once. Prints one line.
SETTLE_NAMED=0
settle_locked() {  # <base-id>
  local base=$1 rec room card title task gen rc body decision chosen option action project until tag
  local -a tags=()
  rec=$(call_record "$base")
  [ -f "$rec" ] || return 0
  [ "$(jq -r '.settled == null' "$rec" 2>/dev/null)" = true ] || return 0
  room=$(jq -r .room "$rec") card=$(jq -r .card "$rec") title=$(jq -r .title "$rec")
  task=$(jq -r .task "$rec") gen=$(jq -r '.generation // 1' "$rec")
  rc=0
  "$SCRIPT_DIR/fm-captain-hold.sh" open "$task" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) [ "$SETTLE_NAMED" = 0 ] || printf 'waiting: %s: still waiting on the owner\n' "$task"; return 0 ;;
    1) ;;
    *) printf 'failed: %s: could not tell whether the call is still waiting\n' "$task"; return 1 ;;
  esac
  body=$(task_body "$task") || { printf 'failed: %s: could not read the call\n' "$task"; return 1; }
  decision=$(newest_decision "$body")
  if [ -z "$decision" ]; then
    printf 'unanswered: %s: no longer held for the owner but carries no answer; nothing was sent to the %s room\n' "$task" "$room"
    return 0
  fi
  chosen=$(printf '%s\n' "$decision" | sed -n -e 's/^Chosen option: //p' -e 's/^Answer: //p' | head -n 1)
  option=$(jq -c --arg chosen "$chosen" 'first(.options[] | select(.label == $chosen)) // empty' "$rec")
  if [ -z "$option" ]; then
    if printf '%s\n' "$decision" | grep -q '^Reconciliation evidence:$'; then
      mark_settled "$base" settled-elsewhere || return 1
      printf 'left: %s: closed as already settled; nothing was sent to the %s room\n' "$task" "$room"
    elif printf '%s\n' "$decision" | grep -q '^Dropped:'; then
      mark_settled "$base" dropped || return 1
      printf 'left: %s: the owner dropped it; nothing was sent to the %s room\n' "$task" "$room"
    else
      hold_next "$base" "$room" "$title" "$gen" \
        || { printf 'failed: %s: could not hold the call again for the owner\n' "$task"; return 1; }
      printf 'held: %s: room requests need the owner'"'"'s own answer and this one chose none of its options, so nothing was sent to the %s room and "%s" is held for the owner again as %s\n' "$task" "$room" "$title" "$base-$((gen + 1))"
    fi
    return 0
  fi
  action=$(printf '%s' "$option" | jq -r .action)
  project=$(printf '%s' "$option" | jq -r '.project // empty')
  while IFS= read -r tag; do [ -z "$tag" ] || tags+=("$tag"); done < <(printf '%s' "$option" | jq -r '.tags // [] | .[]')
  case "$action" in
    accept)
      room_act "$task" accept "$room" "$card" "$project" ${tags[@]+"${tags[@]}"} || return 1
      mark_settled "$base" accepted || return 1
      printf 'accepted: %s: your ship took on "%s" in the %s room under %s; file the work through ordinary intake\n' "$task" "$title" "$room" "$project"
      ;;
    decline)
      room_act "$task" decline "$room" "$card" "$project" ${tags[@]+"${tags[@]}"} || return 1
      mark_settled "$base" declined || return 1
      printf 'declined: %s: your ship declined "%s" in the %s room\n' "$task" "$title" "$room"
      ;;
    later)
      until=$(later_date) || return 1
      hold_next "$base" "$room" "$title" "$gen" "$until" \
        || { printf 'failed: %s: could not hold the call again for later\n' "$task"; return 1; }
      printf 'later: %s: "%s" from the %s room is asked again on %s as %s\n' "$task" "$title" "$room" "$until" "$base-$((gen + 1))"
      ;;
    leave)
      mark_settled "$base" left || return 1
      printf 'left: %s: the owner left it; nothing was sent to the %s room\n' "$task" "$room"
      ;;
    *) printf 'failed: %s: the call records an option it cannot act on\n' "$task"; return 1 ;;
  esac
}

# The base id of the call whose current task is <task-id>, or nothing.
call_of_task() {  # <task-id>
  local rec
  for rec in "$(calls_dir)"/*.json; do
    [ -f "$rec" ] || continue
    if [ "$(jq -r --arg t "$1" '.task == $t' "$rec" 2>/dev/null)" = true ]; then
      jq -r .base "$rec"
      return 0
    fi
  done
  return 1
}

cmd_settle() {
  local rec base id failed=0
  local -a bases=()
  if [ "$#" -gt 0 ]; then
    SETTLE_NAMED=1
    for id in "$@"; do
      if base=$(call_of_task "$id"); then bases+=("$base"); fi
    done
  else
    for rec in "$(calls_dir)"/*.json; do
      [ -f "$rec" ] || continue
      base=${rec##*/}
      bases+=("${base%.json}")
    done
  fi
  [ "${#bases[@]}" -gt 0 ] || return 0
  state_prepare
  for base in "${bases[@]}"; do
    with_call_lock "$base" settle_locked "$base" || failed=1
  done
  return "$failed"
}

cmd_calls() {
  local rec
  [ "$#" -eq 0 ] || usage
  for rec in "$(calls_dir)"/*.json; do
    [ -f "$rec" ] || continue
    jq -r 'select(.settled == null) | .task | strings' "$rec" 2>/dev/null || true
  done
}

cmd_answer() {
  local id=${1-} wanted=${2-} source="the owner's answer, relayed by the first mate" base rec label out rc=0
  [ -n "$id" ] && [ -n "$wanted" ] || usage
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source) [ "$#" -ge 2 ] || usage; source=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  base=$(call_of_task "$id") || die "$id is not a request from a Mothership room waiting as an owner call"
  rec=$(call_record "$base")
  label=$(jq -r --arg w "$wanted" '
    first(.options[] | select((.label | ascii_downcase) == ($w | ascii_downcase)) | .label) // empty' "$rec")
  [ -n "$label" ] || die "$id offers: $(jq -r '.options | map(.label) | join(" | ")' "$rec")"
  out=$(printf '%s\t%s\t%s\n' "$id" "$label" "$label" \
    | "$SCRIPT_DIR/fm-captain-hold.sh" answers --source "$source" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || die "the answer was not recorded: $(printf '%s\n' "$out" | tail -n 1)"
  cmd_settle "$id"
}

# ----- the source -----

sleep_out() {  # <started-epoch>
  local left
  left=$(( WAIT_SECONDS - ($(date +%s) - $1) ))
  [ "$left" -le 0 ] || sleep "$left"
}

failures_note() {  # <room>: count one failure, print the count
  local file n
  file=$(failures_file "$1")
  n=$(cat "$file" 2>/dev/null || true)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  n=$((n + 1))
  write_file "$file" "$n" || true
  printf '%s\n' "$n"
}

# tailscale_cut_off <stderr-file>: the room is cut off by Tailscale. When
# Tailscale is installed here its own answer decides: not running is cut off,
# running is not. Without the command, a room name that does not resolve is
# taken as Tailscale's private names being gone.
tailscale_cut_off() {
  local cmd said
  if [ "${FM_MOTHERSHIP_TAILSCALE+set}" = set ]; then
    cmd=$FM_MOTHERSHIP_TAILSCALE
  else
    cmd=$(command -v tailscale 2>/dev/null || true)
  fi
  if [ -z "$cmd" ]; then
    LC_ALL=C grep -Eq 'ENOTFOUND|EAI_AGAIN|EAI_NONAME' "$1" 2>/dev/null
    return
  fi
  said=$(fm_run_timed 5 "$cmd" status --json 2>/dev/null < /dev/null) || return 0
  [ "$(printf '%s' "$said" | jq -r '.BackendState // empty' 2>/dev/null)" != Running ]
}

# note_unreachable: record a read that could not reach the room, and why, for
# the bridge strip's red alert. A run of failures keeps its first time unless
# the last one is more than 180 seconds old (a sleeping machine, a listener that
# stopped), when a new run starts.
note_unreachable() {  # <room> <stderr-file>
  local room=$1 file now since last cause
  file=$(unreachable_file "$room")
  now=$(date +%s)
  since=$(sed -n 's/^since=//p' "$file" 2>/dev/null | head -n 1)
  last=$(sed -n 's/^last=//p' "$file" 2>/dev/null | head -n 1)
  case "$since" in ''|*[!0-9]*) since=$now ;; esac
  case "$last" in ''|*[!0-9]*) since=$now ;; *) [ $((now - last)) -le 180 ] || since=$now ;; esac
  cause=room
  ! tailscale_cut_off "$2" || cause=tailscale
  write_file "$file" "since=$since
last=$now
cause=$cause" || true
}

print_stop() {  # <room> <refused|error> <reason>
  printf 'schema=%s\n' "$RESULT_SCHEMA"
  printf 'room=%s\n' "$1"
  printf 'status=%s\n' "$2"
  printf 'reason=%s\n' "$(sanitize_line "$3" 300)"
}

cmd_source() {
  local room=${1-} started rc pos out err last to items count n
  [ -n "$room" ] || usage
  shift
  require_room "$room"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --bin) [ "$#" -ge 2 ] || usage; LINK_BIN=$2; shift 2 ;;
      --config) [ "$#" -ge 2 ] || usage; LINK_CONFIG=$2; shift 2 ;;
      --node-dir) [ "$#" -ge 2 ] || usage; LINK_NODE_DIR=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$LINK_BIN" ] || usage
  state_prepare
  pos=$(read_position "$room") || {
    print_stop "$room" error "this monitor has no place in the room; switch monitoring off and on again"
    return 0
  }
  out=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-mothership-pull.XXXXXX") || return 1
  err=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-mothership-err.XXXXXX") || { rm -f -- "$out"; return 1; }
  started=$(date +%s)
  rc=0
  link_run_for $((WAIT_SECONDS + 30)) pull --room "$room" --from "$pos" \
    --wait "$WAIT_SECONDS" --max "$MAX_ITEMS" > "$out" 2> "$err" || rc=$?
  if fm_timed_out "$rc"; then rc=3; fi
  case "$rc" in
    0) ;;
    3)
      note_unreachable "$room" "$err"
      rm -f -- "$out" "$err"
      sleep_out "$started"
      return "$EMPTY_WINDOW"
      ;;
    4)
      print_stop "$room" refused "$(tail -n 1 "$err")"
      rm -f -- "$out" "$err" "$(unreachable_file "$room")"
      return 0
      ;;
    *)
      n=$(failures_note "$room")
      if [ "$n" -ge "$FAILURE_LIMIT" ]; then
        print_stop "$room" error "$n failed reads in a row; the last said: $(tail -n 1 "$err")"
        rm -f -- "$out" "$err" "$(failures_file "$room")"
        return 0
      fi
      rm -f -- "$out" "$err"
      sleep_out "$started"
      return "$EMPTY_WINDOW"
      ;;
  esac
  rm -f -- "$err" "$(failures_file "$room")" "$(unreachable_file "$room")"
  write_file "$(contact_file "$room")" "$(date +%s)" || true
  last=$(tail -n 1 "$out")
  if ! to=$(unwrap_position_line "$last") \
    || ! items=$(sed '$d' "$out") \
    || [ "$(printf '%s' "$items" | jq -sr 'all(type == "object" and (.seq | type) == "number")' 2>/dev/null)" != true ]; then
    rm -f -- "$out"
    print_stop "$room" error "the Mothership link printed something Starship cannot read; update the Mothership link"
    return 0
  fi
  rm -f -- "$out"
  count=$(printf '%s' "$items" | jq -s length)
  if [ "$count" -eq 0 ]; then
    [ "$to" = "$pos" ] || with_lock "$room" commit_locked "$room" "$pos" "$to" || return 1
    return "$EMPTY_WINDOW"
  fi
  printf 'schema=%s\n' "$RESULT_SCHEMA"
  printf 'room=%s\n' "$room"
  printf 'status=items\n'
  printf 'from=%s\n' "$pos"
  printf 'to=%s\n' "$to"
  printf 'items=%s\n' "$count"
  printf -- '--\n'
  printf '%s\n' "$items"
}

# ----- switching -----

# Arm <room>: seed its place, register its source. Prints a problem and fails.
arm_room() {  # <room>
  local room=$1 problem id
  id=$(source_id "$room")
  state_prepare
  problem=$(with_lock "$room" seed_position "$room") || { printf '%s\n' "${problem:-cannot seed the place}"; return 1; }
  registered "$room" && return 0
  set -- "$SCRIPT_DIR/fm-procevent-mothership.sh" source "$room" --bin "$LINK_BIN"
  [ -z "$LINK_CONFIG" ] || set -- "$@" --config "$LINK_CONFIG"
  [ -z "$LINK_NODE_DIR" ] || set -- "$@" --node-dir "$LINK_NODE_DIR"
  "$SCRIPT_DIR/fm-procevent.sh" register "$ADAPTER" "$id" -- "$@" >/dev/null 2>&1 \
    || { printf 'the room'"'"'s source could not be registered\n'; return 1; }
}

hand_back_locked() {  # <room>: give this monitor's place to plain pull
  local room=$1 pos
  pos=$(read_position "$room") || return 0
  link_run position --room "$room" --set "$pos" >/dev/null 2>&1 || return 1
  rm -f -- "$(position_file "$room")"
}

# Retire <room>'s source and hand its place back. Prints a problem and fails.
disarm_room() {  # <room>
  local room=$1
  "$SCRIPT_DIR/fm-procevent.sh" retire "$(source_id "$room")" >/dev/null 2>&1 \
    || { printf 'its source could not be retired\n'; return 1; }
  rm -f -- "$(unreachable_file "$room")"
  [ -f "$(position_file "$room")" ] || return 0
  if [ -z "$LINK_BIN" ] || ! with_lock "$room" hand_back_locked "$room"; then
    printf 'monitoring stopped, but its place could not be handed back to mothership pull, so a manual pull may repeat items already told\n'
    return 1
  fi
}

cmd_on() {
  local room=${1-} problem id requests rc=0
  [ -n "$room" ] || usage
  [ "$#" -eq 1 ] || usage
  require_room "$room"
  resolve_link || die "$LINK_PROBLEM"
  room_joined "$room" || rc=$?
  [ "$rc" -ne 2 ] || die "$room: $(link_timeout_note)"
  [ "$rc" -eq 0 ] || die "$room is not one of this Starship's rooms (mothership rooms lists: $(joined_rooms | tr '\n' ' ' | sed 's/ $//'))"
  problem=$(arm_room "$room") || die "$room: $problem"
  setting_write "$room" on
  id=$(source_id "$room")
  if "$SCRIPT_DIR/fm-procevent.sh" ensure-listening "$id" >/dev/null 2>&1; then
    printf 'on: %s (listening)\n' "$room"
  else
    printf 'on: %s (registered; the watcher starts listening on its next cycle)\n' "$room"
  fi
  if requests=$(link_run requests --room "$room" 2>/dev/null) \
    && printf '%s' "$requests" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf 'open requests for your ship: %s\n' "$(printf '%s' "$requests" | jq length)"
    printf '%s' "$requests" | jq -r '.[] | .title // empty | tostring' 2>/dev/null \
      | head -n 20 | while IFS= read -r title; do printf -- '- %s\n' "$(sanitize_line "$title" 200)"; done
  fi
}

cmd_off() {
  local room=${1-} problem
  [ -n "$room" ] || usage
  [ "$#" -eq 1 ] || usage
  require_room "$room"
  resolve_link >/dev/null || true
  problem=$(disarm_room "$room") || { setting_write "$room" off; die "$room: $problem"; }
  setting_write "$room" off
  printf 'off: %s\n' "$room"
}

cmd_ensure() {
  local entries room value id rec problem rc have_link=1
  entries=$(setting_entries)
  if [ -n "$entries" ] && printf '%s\n' "$entries" | awk '$2 == "on" { f = 1 } END { exit !f }'; then
    resolve_link || { have_link=0; printf 'MOTHERSHIP_MONITOR: %s\n' "$LINK_PROBLEM"; }
  else
    resolve_link >/dev/null 2>&1 || have_link=0
  fi
  # Retire every registered room that is no longer on.
  for rec in "$STATE"/procevent/mothership-*.source; do
    [ -f "$rec" ] || continue
    id=${rec##*/}; id=${id%.source}
    room=${id#mothership-}
    room_valid "$room" || continue
    [ "$(printf '%s\n' "$entries" | awk -v r="$room" '$1 == r { print $2 }')" = on ] && continue
    problem=$(disarm_room "$room") || printf 'MOTHERSHIP_MONITOR: %s: %s\n' "$room" "$problem"
  done
  [ "$have_link" -eq 1 ] || return 0
  printf '%s\n' "$entries" | while read -r room value; do
    [ "$value" = on ] || continue
    registered "$room" && continue
    rc=0
    room_joined "$room" || rc=$?
    if [ "$rc" -eq 2 ]; then
      printf 'MOTHERSHIP_MONITOR: %s: %s; nothing is listening\n' "$room" "$(link_timeout_note)"
      continue
    fi
    if [ "$rc" -ne 0 ]; then
      printf 'MOTHERSHIP_MONITOR: %s: switched on but not one of this Starship'"'"'s rooms (mothership rooms); nothing is listening\n' "$room"
      continue
    fi
    problem=$(arm_room "$room") || printf 'MOTHERSHIP_MONITOR: %s: %s; nothing is listening\n' "$room" "$problem"
  done
}

# The rooms the Mothership config has joined, read from the file itself so they
# show even when the link cannot run: $MOTHERSHIP_CONFIG, else the link's
# default ~/.config/mothership/rooms.json.
config_rooms() {
  local file
  file=$(mothership_config_file)
  [ -f "$file" ] || return 0
  jq -r '.rooms | if type == "object" then keys[] else empty end' "$file" 2>/dev/null || true
}

cmd_status() {
  local rooms room listening contact told list have_link=1
  resolve_link >/dev/null 2>&1 || have_link=0
  rooms=$( { config_rooms; [ "$have_link" -eq 0 ] || joined_rooms; setting_entries 2>/dev/null | awk '{ print $1 }'; } | awk 'NF && !seen[$1]++')
  if [ -z "$rooms" ]; then
    printf 'no Mothership rooms joined\n'
    [ "$have_link" -eq 1 ] || printf '%s\n' "$LINK_PROBLEM"
    return 0
  fi
  list=$("$SCRIPT_DIR/fm-procevent.sh" list 2>/dev/null || true)
  printf '%s\n' "$rooms" | while read -r room; do
    room_valid "$room" || continue
    if registered "$room"; then
      listening=$(printf '%s\n' "$list" | awk -v id="$(source_id "$room")" '$1 == id { print $3; exit }')
      [ "$listening" = live ] && listening=listening || listening="not listening yet"
    else
      listening="not listening"
    fi
    contact=$(cat "$(contact_file "$room")" 2>/dev/null || true)
    case "$contact" in ''|*[!0-9]*) contact=never ;; *) contact="$(( $(date +%s) - contact ))s ago" ;; esac
    told=$(told_mark "$room" 2>/dev/null | jq -r '.cursor' 2>/dev/null || true)
    printf '%s: %s, %s, last contact %s, last told %s\n' "$room" "$(setting_of "$room")" "$listening" "$contact" "${told:-nothing yet}"
  done
  [ "$have_link" -eq 1 ] || printf '%s\n' "$LINK_PROBLEM"
}

case "${1-}" in
  on)         shift; cmd_on "$@" ;;
  off)        shift; cmd_off "$@" ;;
  status)     shift; cmd_status ;;
  ensure)     shift; cmd_ensure ;;
  read)       shift; cmd_read "$@" ;;
  told)       shift; cmd_told "$@" ;;
  settle)     shift; cmd_settle "$@" ;;
  answer)     shift; cmd_answer "$@" ;;
  calls)      shift; cmd_calls "$@" ;;
  source)     shift; cmd_source "$@" ;;
  autohandle) shift; cmd_autohandle "$@" ;;
  relisten)   exit 0 ;;
  classify)   shift; cmd_classify "$@" ;;
  terminal)   shift; cmd_terminal "$@" ;;
  source-id)  shift; require_room "${1-}"; source_id "$1" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
