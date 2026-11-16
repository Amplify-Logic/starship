#!/usr/bin/env bash
# Behavioral tests for bin/fm-procevent-mothership.sh, Mothership monitoring.
# A scripted stand-in for the Mothership link plays each reply, so no room is
# needed; the members and rooms are invented.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
ADAPTER="$ROOT/bin/fm-procevent-mothership.sh"
TMP_ROOT=$(fm_test_tmproot fm-procevent-mothership)
CLAIMS="$TMP_ROOT/claims"
STUB_BIN="$TMP_ROOT/bin"
mkdir -p "$CLAIMS" "$STUB_BIN"

# The stand-in link. $MS_STUB is its directory: `rooms` lists the joined rooms,
# `saved.<room>` is plain pull's place, `now` the room's end, `requests` the open
# requests, `old` makes it a link without `position`, and each file in
# `pull.d/` is one scripted pull reply (first line the exit code, then `out:`
# and `err:` lines). With no reply queued, a pull waits out its window and
# returns the place it was given. A `hang-now` file makes `position --now`
# never answer, and `hang-rooms` does the same to `rooms`. Every call is logged
# to `calls`, and each accept or decline, with all its arguments, to `acts`;
# a `refuse-acts` file makes those fail as an unreachable room. Like the real
# link, an accept or decline the room's allow-list in $MOTHERSHIP_CONFIG does
# not let through (its project, and one of the entry's tags when it names any)
# is refused before it is sent, and is not logged.
cat > "$STUB_BIN/mothership" <<'SH'
#!/usr/bin/env bash
set -u
d=${MS_STUB:?}
cmd=${1-}
[ "$#" -eq 0 ] || shift
case "$cmd" in
  accept|decline)
    args="$*" a_room='' a_project='' a_tags='[]'
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --room) a_room=$2; shift 2 ;;
        --project) a_project=$2; shift 2 ;;
        --tag) a_tags=$(printf '%s' "$a_tags" | jq -c --arg t "$2" '. + [$t]'); shift 2 ;;
        *) shift ;;
      esac
    done
    if ! jq -e --arg r "$a_room" --arg p "$a_project" --argjson t "$a_tags" \
      'any(.rooms[$r].allow[]?; .project == $p and ((.tags // []) | length == 0 or any(.[]; . as $x | $t | index($x))))' \
      "${MOTHERSHIP_CONFIG:?}" >/dev/null 2>&1; then
      echo "Not sent: room $a_room's allow-list does not let this project through." >&2
      exit 1
    fi
    printf '%s %s\n' "$cmd" "$args" >> "$d/acts"
    [ ! -e "$d/refuse-acts" ] || { echo "Could not reach the room at https://room.example.test" >&2; exit 3; }
    echo '{"ok":true}'
    exit 0
    ;;
esac
room='' now=0 set_pos='' from='' wait=0 max=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --room) room=$2; shift 2 ;;
    --now) now=1; shift ;;
    --set) set_pos=$2; shift 2 ;;
    --from) from=$2; shift 2 ;;
    --wait) wait=$2; shift 2 ;;
    --max) max=$2; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s room=%s from=%s now=%s set=%s max=%s config=%s\n' \
  "$cmd" "$room" "$from" "$now" "$set_pos" "$max" "${MOTHERSHIP_CONFIG-}" >> "$d/calls"
case "$cmd" in
  rooms) [ ! -e "$d/hang-rooms" ] || sleep 300; cat "$d/rooms" 2>/dev/null; exit 0 ;;
  position)
    if [ -e "$d/old" ]; then echo "Unknown command position. Run mothership help." >&2; exit 1; fi
    if [ -n "$set_pos" ]; then printf '{"position":%s}\n' "$set_pos" > "$d/saved.$room"; cat "$d/saved.$room"; exit 0; fi
    if [ "$now" = 1 ]; then [ ! -e "$d/hang-now" ] || sleep 300; cat "$d/now"; exit 0; fi
    cat "$d/saved.$room" 2>/dev/null || echo '{"position":{"recordId":null,"cursor":0,"at":0}}'
    exit 0
    ;;
  requests) cat "$d/requests" 2>/dev/null || echo '[]'; exit 0 ;;
  pull)
    next=$(ls "$d/pull.d" 2>/dev/null | sort | head -n 1)
    if [ -z "$next" ]; then
      sleep "$wait"
      printf '{"position":%s}\n' "$from"
      exit 0
    fi
    f="$d/pull.d/$next"
    rc=$(sed -n 1p "$f")
    sed 1d "$f" > "$d/.reply"
    rm -f "$f"
    sed -n 's/^out://p' "$d/.reply"
    sed -n 's/^err://p' "$d/.reply" >&2
    exit "$rc"
    ;;
esac
exit 1
SH
chmod +x "$STUB_BIN/mothership"

P0='{"recordId":"r1","cursor":3,"at":1000}'
P1='{"recordId":"r1","cursor":5,"at":1200}'
P2='{"recordId":"r1","cursor":7,"at":1400}'
NOW='{"recordId":"r1","cursor":40,"at":9000}'
ITEM_ASK='{"seq":4,"reason":"asked","what":"card.new","card":"c6","title":"Pick a colour","by":{"who":"alex","ship":true},"byName":"Alex'"'"'s ship","says":"asked Sam'"'"'s ship for this.","value":{"to":{"who":"sam","ship":true},"line":"Blue or green for the new page"}}'
ITEM_MSG='{"seq":5,"reason":"spoken to","what":"msg","card":"c6","title":"Pick a colour","by":{"who":"robin","ship":false},"byName":"Robin","says":"wrote: \"Blue\"","value":{"text":"Blue, please"}}'

# make_home <name>: a home, a stand-in directory and the environment both use.
make_home() {
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/home/config" "$h/home/state" "$h/home/data" "$h/stub/pull.d"
  fm_test_tasks_toml "$h/home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$h/home/data/backlog.md"
  printf 'alpha  https://room.example.test\nbeta  https://other.example.test\n' > "$h/stub/rooms"
  printf '{"position":%s}\n' "$NOW" > "$h/stub/now"
  fm_test_track_procevent_home "$h/home" "$CLAIMS"
  printf '%s\n' "$h"
}

# in_home <dir> <command...>: no Tailscale command unless a case names one.
in_home() {
  local h=$1
  shift
  FM_HOME="$h/home" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" MS_STUB="$h/stub" \
    FM_MOTHERSHIP_BIN="$STUB_BIN/mothership" MOTHERSHIP_CONFIG="$h/rooms.json" \
    FM_MOTHERSHIP_TAILSCALE="${FM_MOTHERSHIP_TAILSCALE-}" \
    FM_MOTHERSHIP_WAIT_SECONDS=1 FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=2 "$@"
}

# A stand-in Tailscale: `status --json` reports the backend state in
# $TS_STATE, or fails when it is `gone` (the app not running).
cat > "$STUB_BIN/tailscale" <<'SH'
#!/usr/bin/env bash
[ "$*" = 'status --json' ] || exit 2
[ "${TS_STATE:-Running}" != gone ] || { echo 'failed to connect to local Tailscale service' >&2; exit 1; }
printf '{"BackendState":"%s","Self":{}}\n' "${TS_STATE:-Running}"
SH
chmod +x "$STUB_BIN/tailscale"

# queue_reply <dir> <exit-code> <line>...
queue_reply() {
  local h=$1 rc=$2 n
  shift 2
  n=$(find "$h/stub/pull.d" -type f | wc -l | tr -d ' ')
  { printf '%s\n' "$rc"; [ "$#" -eq 0 ] || printf '%s\n' "$@"; } > "$h/stub/pull.d/$(printf '%03d' "$((n + 1))")"
}

position_of() { cat "$1/home/state/mothership/$2.position" 2>/dev/null; }
assert_place() { assert_equals "$3" "$(position_of "$1" "$2")" "$4"; }
set_position() { mkdir -p "$1/home/state/mothership"; printf '%s\n' "$3" > "$1/home/state/mothership/$2.position"; }
set_told() { mkdir -p "$1/home/state/mothership"; printf '%s\n' "$3" > "$1/home/state/mothership/$2.told"; }

# capture <dir> <seq> <file-with-source-output>: file it the way the runner does.
capture() {
  local inbox="$1/home/state/procevent-inbox"
  mkdir -p "$inbox"
  cp "$3" "$inbox/mothership-alpha.$2.result"
  printf 'mothership\n' > "$inbox/mothership-alpha.$2.adapter"
  printf '%s\n' "$inbox/mothership-alpha.$2.result"
}

wait_for_file() {  # <path> [tries of 0.1s]
  local _
  for _ in $(seq 1 "${2:-100}"); do
    [ -e "$1" ] && return 0
    sleep 0.1
  done
  return 1
}

test_help() {
  local help
  if help=$("$ADAPTER" --help 2>&1); then fail "help exited zero"; fi
  assert_contains "$help" "fm-procevent-mothership.sh on <room>" "help names on"
  assert_not_contains "$help" "--now" "help offers no --now mode"
  assert_contains "$help" "config/mothership-monitor" "help names the setting"
  assert_not_contains "$help" "set -u" "help leaked source"
  pass "help renders the header"
}

test_no_setting_runs_nothing() {
  local h out
  h=$(make_home none)
  out=$(in_home "$h" "$ADAPTER" ensure 2>&1) || fail "ensure without a setting failed: $out"
  [ -z "$out" ] || fail "ensure without a setting printed: $out"
  [ -z "$(ls -A "$h/home/state")" ] || fail "ensure without a setting left state: $(ls -A "$h/home/state")"
  [ ! -e "$h/stub/calls" ] || fail "ensure without a setting called the link: $(cat "$h/stub/calls")"
  pass "with no config/mothership-monitor nothing is registered and no state is created"
}

test_on_off_status() {
  local h out
  h=$(make_home switch)
  printf '{"position":%s}\n' "$P0" > "$h/stub/saved.alpha"
  printf '[{"id":"c9","title":"Tidy the shared photo folder"}]\n' > "$h/stub/requests"

  if out=$(in_home "$h" "$ADAPTER" on gamma 2>&1); then fail "on accepted a room this Starship has not joined"; fi
  assert_contains "$out" "gamma is not one of this Starship's rooms" "unknown room named"
  assert_contains "$out" "alpha beta" "joined rooms listed"
  [ ! -e "$h/home/config/mothership-monitor" ] || fail "a refused on wrote the setting"

  : > "$h/stub/old"
  if out=$(in_home "$h" "$ADAPTER" on alpha 2>&1); then fail "on accepted a link without position"; fi
  assert_contains "$out" "update the Mothership link first" "old link refused"
  [ ! -e "$h/home/config/mothership-monitor" ] || fail "an old link still wrote the setting"
  rm -f "$h/stub/old"

  out=$(in_home "$h" "$ADAPTER" on alpha 2>&1) || fail "on alpha failed: $out"
  assert_contains "$out" "on: alpha" "on reported"
  assert_contains "$out" "open requests for your ship: 1" "open requests counted"
  assert_contains "$out" "- Tidy the shared photo folder" "open request listed"
  grep -qx 'alpha = on' "$h/home/config/mothership-monitor" || fail "setting not written: $(cat "$h/home/config/mothership-monitor")"
  [ -f "$h/home/state/procevent/mothership-alpha.source" ] || fail "source not registered"
  assert_place "$h" alpha "$P0" "on carries on from plain pull's saved place"
  grep -q "config=$h/rooms.json" "$h/stub/calls" || fail "the link did not get the resolved config"

  if out=$(in_home "$h" "$ADAPTER" on beta --now 2>&1); then fail "on accepted a --now mode"; fi
  [ ! -e "$h/home/state/procevent/mothership-beta.source" ] || fail "a refused on beta --now registered the room"
  out=$(in_home "$h" "$ADAPTER" on beta 2>&1) || fail "on beta failed: $out"
  assert_place "$h" beta "$NOW" "a room never pulled starts at its current end"

  out=$(in_home "$h" "$ADAPTER" status 2>&1) || fail "status failed: $out"
  assert_contains "$out" "alpha: on" "status shows alpha on"
  assert_contains "$out" "beta: on" "status shows beta on"

  set_position "$h" alpha "$P2"
  out=$(in_home "$h" "$ADAPTER" off alpha 2>&1) || fail "off alpha failed: $out"
  assert_contains "$out" "off: alpha" "off reported"
  assert_equals "{\"position\":$P2}" "$(cat "$h/stub/saved.alpha")" "off hands the place back to plain pull"
  [ ! -e "$h/home/state/mothership/alpha.position" ] || fail "off kept the monitor's place"
  [ ! -e "$h/home/state/procevent/mothership-alpha.source" ] || fail "off left the source registered"
  grep -qx 'alpha = off' "$h/home/config/mothership-monitor" || fail "off not written"
  [ "$(grep -c '^alpha' "$h/home/config/mothership-monitor")" -eq 1 ] || fail "the setting kept two alpha lines"
  grep -q '^# A room switched on here' "$h/home/config/mothership-monitor" || fail "the setting lost its comment"

  out=$(in_home "$h" "$ADAPTER" off beta 2>&1) || fail "off beta failed: $out"
  pass "on checks the room and the link, seeds the place and registers; off retires and hands the place back"
}

test_config_pinned_only_when_named() {
  local h out
  h=$(make_home unnamed)
  printf '{"position":%s}\n' "$P0" > "$h/stub/saved.alpha"
  out=$(in_home "$h" env -u MOTHERSHIP_CONFIG "$ADAPTER" on alpha 2>&1) || fail "on without a named config failed: $out"
  if grep -qx -- '--config' "$h/home/state/procevent/mothership-alpha.source"; then
    fail "the registration pinned a config this shell never named"
  fi
  grep -q '^position room=alpha' "$h/stub/calls" || fail "on never asked the link for the place"
  if grep -v ' config=$' "$h/stub/calls" | grep -q .; then
    fail "the link was given a config this shell never named: $(cat "$h/stub/calls")"
  fi
  in_home "$h" env -u MOTHERSHIP_CONFIG "$ADAPTER" off alpha >/dev/null 2>&1 || fail "off failed"
  pass "the link's own default config is left to the link unless a config is named"
}

test_ensure_follows_the_setting() {
  local h out
  h=$(make_home ensure)
  printf '{"position":%s}\n' "$P0" > "$h/stub/saved.alpha"
  printf 'alpha = on\nbeta = maybe\ngamma = on\n' > "$h/home/config/mothership-monitor"
  out=$(in_home "$h" "$ADAPTER" ensure 2>&1) || fail "ensure failed: $out"
  assert_contains "$out" "MOTHERSHIP_MONITOR: config/mothership-monitor line 2 is not" "bad line reported"
  assert_contains "$out" "MOTHERSHIP_MONITOR: gamma: switched on but not one of this Starship's rooms" "unjoined room reported"
  [ -f "$h/home/state/procevent/mothership-alpha.source" ] || fail "ensure did not arm an on room"
  [ ! -e "$h/home/state/procevent/mothership-beta.source" ] || fail "a malformed line switched a room on"
  assert_place "$h" alpha "$P0" "ensure seeded the place"

  out=$(in_home "$h" "$ADAPTER" ensure 2>&1)
  [ "$out" = "$(printf '%s\n%s' "MOTHERSHIP_MONITOR: config/mothership-monitor line 2 is not \"<room> = on\" or \"<room> = off\"; treated as off" "MOTHERSHIP_MONITOR: gamma: switched on but not one of this Starship's rooms (mothership rooms); nothing is listening")" ] \
    || fail "a second ensure changed anything but the same diagnostics: $out"

  set_position "$h" alpha "$P1"
  printf 'alpha = off\n' > "$h/home/config/mothership-monitor"
  out=$(in_home "$h" "$ADAPTER" ensure 2>&1) || fail "ensure off failed: $out"
  [ -z "$out" ] || fail "ensure off printed: $out"
  [ ! -e "$h/home/state/procevent/mothership-alpha.source" ] || fail "ensure left an off room registered"
  assert_equals "{\"position\":$P1}" "$(cat "$h/stub/saved.alpha")" "ensure hands an off room's place back"

  in_home "$h" "$ADAPTER" ensure >/dev/null 2>&1
  printf 'alpha = on\n' > "$h/home/config/mothership-monitor"
  in_home "$h" "$ADAPTER" ensure >/dev/null 2>&1 || fail "re-arm failed"
  rm -f "$h/home/config/mothership-monitor"
  out=$(in_home "$h" "$ADAPTER" ensure 2>&1) || fail "ensure with the setting removed failed: $out"
  [ ! -e "$h/home/state/procevent/mothership-alpha.source" ] || fail "a removed setting left a room registered"
  pass "ensure arms on rooms, retires off and unlisted ones, and reports bad lines"
}

test_ensure_bounds_a_room_that_never_answers() {
  local h out started elapsed
  h=$(make_home hang)
  : > "$h/stub/hang-now"
  printf 'alpha = on\n' > "$h/home/config/mothership-monitor"
  started=$(date +%s)
  out=$(in_home "$h" env FM_MOTHERSHIP_LINK_TIMEOUT=2 "$ADAPTER" ensure 2>&1) || fail "ensure failed: $out"
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 10 ] || fail "ensure waited ${elapsed}s on a room that never answers"
  assert_equals "MOTHERSHIP_MONITOR: alpha: the Mothership link did not answer within 2s; nothing is listening" "$out" \
    "a room whose end never arrives is reported as a link that did not answer"
  [ ! -e "$h/home/state/procevent/mothership-alpha.source" ] || fail "a room that never answered was armed"
  [ ! -e "$h/home/state/mothership/alpha.position" ] || fail "a room that never answered got a place"

  rm -f "$h/stub/hang-now"
  : > "$h/stub/hang-rooms"
  out=$(in_home "$h" env FM_MOTHERSHIP_LINK_TIMEOUT=2 "$ADAPTER" ensure 2>&1) || fail "ensure failed: $out"
  assert_equals "MOTHERSHIP_MONITOR: alpha: the Mothership link did not answer within 2s; nothing is listening" "$out" \
    "a rooms list that never arrives is not reported as an unjoined room"
  out=$(in_home "$h" env FM_MOTHERSHIP_LINK_TIMEOUT=2 "$ADAPTER" on alpha 2>&1) && fail "on succeeded with a link that never answers"
  assert_equals "error: alpha: the Mothership link did not answer within 2s" "$out" "on reports a link that did not answer"
  pass "ensure gives up on a link call that never returns and reports the room"
}

test_source_windows() {
  local h out rc started elapsed
  h=$(make_home source)
  set_position "$h" alpha "$P0"
  set_told "$h" alpha "$P0"
  src() { in_home "$h" "$ADAPTER" source alpha --bin "$STUB_BIN/mothership" --config "$h/rooms.json"; }

  rc=0; out=$(src) || rc=$?
  [ "$rc" -eq 75 ] && [ -z "$out" ] || fail "empty window gave rc=$rc out=$out"
  assert_place "$h" alpha "$P0" "an empty window keeps the place"
  grep -q "pull room=alpha from=$P0 now=0 set= max=50" "$h/stub/calls" || fail "pull was not read from the place: $(cat "$h/stub/calls")"

  queue_reply "$h" 0 "out:{\"position\":$P1}"
  rc=0; out=$(src) || rc=$?
  [ "$rc" -eq 75 ] && [ -z "$out" ] || fail "an unrelated move gave rc=$rc out=$out"
  assert_place "$h" alpha "$P1" "an unrelated move saves the new place"

  queue_reply "$h" 0 "out:$ITEM_ASK" "out:$ITEM_MSG" "out:{\"position\":$P2}"
  rc=0; out=$(src) || rc=$?
  [ "$rc" -eq 0 ] || fail "items gave rc=$rc"
  assert_contains "$out" "schema=fm-mothership-pull.v1" "result schema"
  assert_contains "$out" "status=items" "result status"
  assert_contains "$out" "from=$P1" "result from"
  assert_contains "$out" "to=$P2" "result to"
  assert_contains "$out" "items=2" "result count"
  assert_contains "$out" "$ITEM_MSG" "item line kept"
  assert_place "$h" alpha "$P1" "a window with items does not move the place itself"

  queue_reply "$h" 3 "err:Could not reach the room at https://room.example.test: ECONNREFUSED"
  started=$(date +%s)
  rc=0; out=$(src) || rc=$?
  elapsed=$(( $(date +%s) - started ))
  [ "$rc" -eq 75 ] && [ -z "$out" ] || fail "unreachable gave rc=$rc out=$out"
  [ "$elapsed" -ge 1 ] || fail "unreachable did not wait out its window"

  local i
  for i in 1 2 3 4; do
    queue_reply "$h" 1 "err:Something odd $i"
    rc=0; out=$(src) || rc=$?
    [ "$rc" -eq 75 ] && [ -z "$out" ] || fail "failure $i gave rc=$rc out=$out"
  done
  queue_reply "$h" 1 "err:Something odd 5"
  rc=0; out=$(src) || rc=$?
  [ "$rc" -eq 0 ] || fail "the fifth failure gave rc=$rc"
  assert_contains "$out" "status=error" "five failures stop"
  assert_contains "$out" "the last said: Something odd 5" "error names the last failure"

  queue_reply "$h" 1 "err:once"
  rc=0; out=$(src) || rc=$?
  [ "$rc" -eq 75 ] || fail "the failure count did not start again"

  queue_reply "$h" 4 "err:The room refused this key. It may have been revoked."
  rc=0; out=$(src) || rc=$?
  [ "$rc" -eq 0 ] || fail "refused gave rc=$rc"
  assert_contains "$out" "status=refused" "refused result"
  assert_contains "$out" "reason=The room refused this key." "refused reason"
  printf '%s\n' "$out" > "$TMP_ROOT/refused.result"
  "$ADAPTER" terminal "$TMP_ROOT/refused.result" || fail "a refused result is not terminal"
  assert_equals refused "$("$ADAPTER" classify "$TMP_ROOT/refused.result")" "classify refused"

  queue_reply "$h" 0 "out:not json" "out:{\"position\":$P2}"
  rc=0; out=$(src) || rc=$?
  assert_contains "$out" "status=error" "malformed pull output stops"

  rm -f "$h/home/state/mothership/alpha.position"
  rc=0; out=$(src) || rc=$?
  assert_contains "$out" "status=error" "a missing place stops"
  pass "source: empty and unrelated windows exit 75, items are captured unmoved, failures back off or stop"
}

test_source_notes_a_room_it_cannot_reach() {
  local h note rc before since
  h=$(make_home reach)
  set_position "$h" alpha "$P0"
  set_told "$h" alpha "$P0"
  printf 'alpha = on\n' > "$h/home/config/mothership-monitor"
  note="$h/home/state/mothership/alpha.unreachable"
  src() { TS_STATE=${1:-Running} FM_MOTHERSHIP_TAILSCALE="${2-$STUB_BIN/tailscale}" \
    in_home "$h" "$ADAPTER" source alpha --bin "$STUB_BIN/mothership" --config "$h/rooms.json" >/dev/null; }
  field() { sed -n "s/^$1=//p" "$note"; }

  # No Tailscale command to ask, and the room's name does not resolve:
  # Tailscale's private names are gone.
  queue_reply "$h" 3 "err:Could not reach the room at https://room.example.test: ENOTFOUND"
  before=$(date +%s)
  rc=0; src Running '' || rc=$?
  [ "$rc" -eq 75 ] || fail "an unreachable room gave rc=$rc"
  [ -f "$note" ] || fail "an unreachable room left no note"
  assert_equals tailscale "$(field cause)" "a name that does not resolve, with no Tailscale to ask, is Tailscale"
  assert_equals 'since last cause' "$(sed 's/=.*//' "$note" | tr '\n' ' ' | sed 's/ $//')" "the note has other fields than its times and cause"
  since=$(field since)

  # No Tailscale command and the name resolves: the room is down.
  queue_reply "$h" 3 "err:Could not reach the room at https://room.example.test: ECONNREFUSED"
  src Running ''
  assert_equals room "$(field cause)" "a refused connection with no Tailscale to ask is the room"

  # Tailscale running but the name does not resolve (no internet, say):
  # Tailscale's own answer decides, so it is the room not answering.
  queue_reply "$h" 3 "err:Could not reach the room at https://room.example.test: getaddrinfo EAI_AGAIN room.example.test"
  src
  assert_equals room "$(field cause)" "a name lookup failure with Tailscale running was blamed on Tailscale"
  [ "$since" -ge "$before" ] && [ "$(field last)" -ge "$since" ] || fail "the note's times are wrong: $(cat "$note")"

  # Tailscale running and the room refusing the connection: the room is down.
  queue_reply "$h" 3 "err:Could not reach the room at https://room.example.test: ECONNREFUSED"
  src
  assert_equals room "$(field cause)" "a refused connection with Tailscale on is the room"
  assert_equals "$since" "$(field since)" "a run of failures kept its first time"

  # Tailscale switched off, or its app not running at all.
  queue_reply "$h" 3 "err:Could not reach the room at https://room.example.test: ETIMEDOUT"
  src Stopped
  assert_equals tailscale "$(field cause)" "Tailscale stopped is the cause"
  queue_reply "$h" 3 "err:Could not reach the room at https://room.example.test: ETIMEDOUT"
  src gone
  assert_equals tailscale "$(field cause)" "a Tailscale that cannot be asked is off"

  # A long gap since the last failure (a sleeping machine) starts a new run.
  printf 'since=1000\nlast=1100\ncause=room\n' > "$note"
  queue_reply "$h" 3 "err:Could not reach the room at https://room.example.test: ECONNREFUSED"
  src
  [ "$(field since)" -ge "$before" ] || fail "an old run of failures was carried on: $(cat "$note")"

  # The room answering again clears the note.
  queue_reply "$h" 0 "out:{\"position\":$P0}"
  src
  [ ! -e "$note" ] || fail "the note stayed after the room answered"
  pass "source: a room it cannot reach is noted with its cause, and the note clears when the room answers"
}

test_off_clears_the_unreachable_note() {
  local h out
  h=$(make_home offnote)
  printf 'alpha = on\n' > "$h/home/config/mothership-monitor"
  out=$(in_home "$h" "$ADAPTER" ensure 2>&1) || fail "ensure failed: $out"
  [ -f "$h/home/state/procevent/mothership-alpha.source" ] || fail "the room was not armed"
  printf 'since=1\nlast=2\ncause=room\n' > "$h/home/state/mothership/alpha.unreachable"
  out=$(in_home "$h" "$ADAPTER" off alpha 2>&1) || fail "off failed: $out"
  [ ! -e "$h/home/state/mothership/alpha.unreachable" ] || fail "off left the unreachable note"
  pass "off removes the room's unreachable note"
}

test_autohandle_and_told() {
  local h out f1 f2 doc
  h=$(make_home handle)
  set_position "$h" alpha "$P0"
  doc="$TMP_ROOT/handle.out"
  queue_reply "$h" 0 "out:$ITEM_ASK" "out:{\"position\":$P1}"
  in_home "$h" "$ADAPTER" source alpha --bin "$STUB_BIN/mothership" --config "$h/rooms.json" > "$doc"
  f1=$(capture "$h" 1 "$doc")
  # A crash before autohandle: the next window reads the same items again.
  queue_reply "$h" 0 "out:$ITEM_ASK" "out:{\"position\":$P1}"
  in_home "$h" "$ADAPTER" source alpha --bin "$STUB_BIN/mothership" --config "$h/rooms.json" > "$doc"
  f2=$(capture "$h" 2 "$doc")

  in_home "$h" "$ADAPTER" autohandle mothership-alpha 2 "$f2" || fail "autohandle failed"
  assert_place "$h" alpha "$P1" "autohandle moves the place on"
  [ -e "${f2%.result}.handled" ] || fail "autohandle did not acknowledge the capture"
  in_home "$h" "$ADAPTER" autohandle mothership-alpha 2 "$f2" || fail "a replayed autohandle failed"
  assert_place "$h" alpha "$P1" "a replay keeps the place"
  if in_home "$h" "$ADAPTER" autohandle mothership-alpha 9 "$f2"; then fail "autohandle accepted a mismatched sequence"; fi

  out=$(in_home "$h" "$ADAPTER" read "$f1") || fail "read failed"
  assert_contains "$out" "new: 1" "the first capture shows its item"
  assert_contains "$out" "what: Alex's ship asked your ship to do something" "item described"
  assert_contains "$out" "card: Pick a colour" "card title"
  assert_contains "$out" "card-id: c6" "card id"
  assert_contains "$out" "text: Blue or green for the new page" "card line"
  out=$(in_home "$h" "$ADAPTER" told "$f1") || fail "told failed: $out"
  assert_contains "$out" "told: alpha (1 item(s) in this batch)" "told reported"
  [ -e "${f1%.result}.handled" ] || fail "told did not acknowledge the capture"
  assert_place "$h" alpha "$P1" "a stale capture never moves the place back"
  out=$(in_home "$h" "$ADAPTER" read "$f2")
  assert_equals "$(printf 'room: alpha\nnothing new')" "$out" "a duplicate capture is shown once"

  # A result without its closing place is never committed.
  printf 'schema=fm-mothership-pull.v1\nroom=alpha\nstatus=items\nfrom=%s\nitems=1\n--\n%s\n' "$P1" "$ITEM_MSG" > "$doc"
  f1=$(capture "$h" 3 "$doc")
  if in_home "$h" "$ADAPTER" autohandle mothership-alpha 3 "$f1"; then fail "autohandle accepted a result with no closing place"; fi
  assert_place "$h" alpha "$P1" "a result with no closing place keeps the place"
  [ ! -e "${f1%.result}.handled" ] || fail "a result with no closing place was acknowledged"

  # A result from a place behind the stored one never moves it.
  printf 'schema=fm-mothership-pull.v1\nroom=alpha\nstatus=items\nfrom=%s\nto=%s\nitems=1\n--\n%s\n' "$P0" "$P2" "$ITEM_MSG" > "$doc"
  f1=$(capture "$h" 4 "$doc")
  in_home "$h" "$ADAPTER" autohandle mothership-alpha 4 "$f1" || fail "a stale autohandle failed"
  assert_place "$h" alpha "$P1" "a capture from behind the place keeps it"
  pass "autohandle and told move the place only forward, and told keeps a repeated batch from being shown twice"
}

test_told_after_a_missed_told() {
  local h out doc f1 f2 late
  h=$(make_home missed)
  set_position "$h" alpha "$P0"
  set_told "$h" alpha "$P0"
  late=$(printf '%s' "$ITEM_MSG" | jq -c '.seq = 6')
  doc="$TMP_ROOT/missed.out"
  queue_reply "$h" 0 "out:$ITEM_ASK" "out:{\"position\":$P1}"
  in_home "$h" "$ADAPTER" source alpha --bin "$STUB_BIN/mothership" --config "$h/rooms.json" > "$doc"
  f1=$(capture "$h" 1 "$doc")
  in_home "$h" "$ADAPTER" autohandle mothership-alpha 1 "$f1" || fail "autohandle 1 failed"
  # The turn ends before told runs for the first capture.
  queue_reply "$h" 0 "out:$late" "out:{\"position\":$P2}"
  in_home "$h" "$ADAPTER" source alpha --bin "$STUB_BIN/mothership" --config "$h/rooms.json" > "$doc"
  f2=$(capture "$h" 2 "$doc")
  in_home "$h" "$ADAPTER" autohandle mothership-alpha 2 "$f2" || fail "autohandle 2 failed"

  out=$(in_home "$h" "$ADAPTER" told "$f2" 2>&1) || fail "told refused a batch after a missed told: $out"
  assert_contains "$out" "told: alpha (1 item(s) in this batch)" "the later batch is recorded"
  assert_equals "$P2" "$(cat "$h/home/state/mothership/alpha.told")" "the told mark moves to the later batch's end"
  [ -e "${f2%.result}.handled" ] || fail "told did not acknowledge the later capture"

  queue_reply "$h" 0 "out:{\"position\":$NOW}"
  in_home "$h" "$ADAPTER" source alpha --bin "$STUB_BIN/mothership" --config "$h/rooms.json" >/dev/null || true
  assert_place "$h" alpha "$NOW" "an empty window still moves the place on"
  pass "a capture never told does not wedge told or the place"
}

test_read_cleans_room_text() {
  local h out doc f long item
  h=$(make_home clean)
  long=$(printf 'x%.0s' $(seq 1 2000))
  item=$(jq -cn --arg long "$long" '{seq: 9, reason: "spoken to", card: "c1", title: "Bad\u001b[31m title‮ here", byName: "Alex\u0007s ship", says: "wrote: ok", value: {text: ("line one\nline two " + $long)}}')
  doc="$TMP_ROOT/clean.out"
  printf 'schema=fm-mothership-pull.v1\nroom=alpha\nstatus=items\nfrom=%s\nto=%s\nitems=1\n--\n%s\n' "$P0" "$P1" "$item" > "$doc"
  f=$(capture "$h" 1 "$doc")
  out=$(in_home "$h" "$ADAPTER" read "$f") || fail "read failed"
  if printf '%s' "$out" | LC_ALL=C grep -q "$(printf '\033')"; then fail "read kept an escape character"; fi
  if printf '%s' "$out" | grep -q "$(printf '\342\200\256')"; then fail "read kept a direction override"; fi
  assert_contains "$out" "card: Bad [31m title here" "title cleaned"
  assert_contains "$out" "text: line one line two xxx" "newline flattened"
  [ "$(printf '%s\n' "$out" | grep -c '^item ')" -eq 1 ] || fail "room text added lines: $out"
  [ "$(printf '%s\n' "$out" | awk '/^  text: / { print length($0) }')" -le 612 ] || fail "text not capped"
  pass "read strips control characters and caps lengths"
}

# ----- requests as owner calls -----

# ask_item <seq> <card> <title>: a request to the ship on one card.
ask_item() {
  printf '%s' "$ITEM_ASK" | jq -c --argjson seq "$1" --arg card "$2" --arg title "$3" '.seq = $seq | .card = $card | .title = $title'
}

# capture_items <dir> <seq> <from> <to> <item>...: one captured batch.
capture_items() {
  local h=$1 seq=$2 from=$3 to=$4 doc
  shift 4
  doc="$TMP_ROOT/$(basename "$h").$seq.out"
  { printf 'schema=fm-mothership-pull.v1\nroom=alpha\nstatus=items\nfrom=%s\nto=%s\nitems=%s\n--\n' "$from" "$to" "$#"
    printf '%s\n' "$@"; } > "$doc"
  capture "$h" "$seq" "$doc"
}

# allow_rooms <dir>: the alpha room allows two projects, one only with a tag,
# the beta room none, and the gamma room one project only under two tags.
allow_rooms() {
  printf '%s\n' '{"default":"alpha","rooms":{"alpha":{"url":"https://room.example.test","allow":[{"project":"alpha-app"},{"project":"studio","tags":["alpha"]},{"project":"alpha-app"}]},"beta":{"url":"https://other.example.test","allow":[]},"gamma":{"url":"https://third.example.test","allow":[{"project":"studio","tags":["g2"]},{"project":"studio","tags":["g1"]}]}}}' > "$1/rooms.json"
}

# Every surface reads the home through these.
hold_in() { in_home "$1" "$ROOT/bin/fm-captain-hold.sh" "${@:2}"; }
desk_in() { in_home "$1" "$ROOT/bin/fm-tap-desk.sh" "${@:2}"; }
show_in() { in_home "$1" "$ROOT/bin/fm-tasks-axi.sh" show "$2" --full; }
calls_in() {  # <dir>: the task ids held for the owner
  in_home "$1" "$ROOT/bin/fm-tasks-axi.sh" list --state held --kind captain 2>/dev/null | grep -oE 'ms-[A-Za-z0-9.-]+' | sort -u
}
acts_of() { cat "$1/stub/acts" 2>/dev/null; }

# tap_on <dir> <task-id> <option>: the owner taps one option on the phone page.
# tap_choice <dir> <task-id> <choice> [<option>]: the owner taps any choice.
tap_on() { tap_choice "$1" "$2" option "$3"; }
tap_choice() {
  local h=$1 id=$2 choice=$3 option=${4-} identity
  identity=$(hold_in "$h" open "$id" --identity) || fail "$id is not waiting on the owner"
  mkdir -p "$h/taps"
  jq -n --arg id "$id" --arg identity "$identity" --arg choice "$choice" --arg option "$option" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{id: ("d." + $id), version: 1, data: {card: ("d." + $id), kind: "decision", id: $id, identity: $identity, choice: $choice, option: $option, pr: "", reason: "", tapped_at: $at}}' \
    > "$h/taps/$id.json"
}

# tell_room <dir> <room> <seq> <item>...: capture one batch from <room> and tell it.
tell_room() {
  local h=$1 room=$2 seq=$3 doc inbox
  shift 3
  doc="$TMP_ROOT/$(basename "$h").$room.$seq.out"
  { printf 'schema=fm-mothership-pull.v1\nroom=%s\nstatus=items\nfrom=%s\nto=%s\nitems=%s\n--\n' "$room" "$P0" "$P1" "$#"
    printf '%s\n' "$@"; } > "$doc"
  inbox="$h/home/state/procevent-inbox"
  mkdir -p "$inbox"
  cp "$doc" "$inbox/mothership-$room.$seq.result"
  printf 'mothership\n' > "$inbox/mothership-$room.$seq.adapter"
  in_home "$h" "$ADAPTER" told "$inbox/mothership-$room.$seq.result"
}

test_a_request_becomes_one_owner_call() {
  local h out f
  command -v tasks-axi >/dev/null 2>&1 || { pass "skip: tasks-axi not found"; return 0; }
  command -v node >/dev/null 2>&1 || { pass "skip: node not found"; return 0; }
  h=$(make_home calls)
  allow_rooms "$h"
  set_position "$h" alpha "$P0"
  set_told "$h" alpha "$P0"
  f=$(capture_items "$h" 1 "$P0" "$P1" "$ITEM_ASK" "$ITEM_MSG")
  out=$(in_home "$h" "$ADAPTER" told "$f" 2>&1) || fail "told failed: $out"
  assert_contains "$out" 'held: ms-alpha-c6: take on "Pick a colour" from the alpha room?' "the request was held as a call"
  assert_contains "$out" "told: alpha (2 item(s) in this batch)" "the batch was told"
  assert_equals "ms-alpha-c6" "$(calls_in "$h")" "exactly one call for one request, none for the message"
  show_in "$h" ms-alpha-c6 | grep -q 'title: "Take on \\"Pick a colour\\" from the alpha room?"' \
    || fail "the call does not ask the question: $(show_in "$h" ms-alpha-c6)"

  # A repeat wake for the same request makes no second call: the same batch
  # told again, the same request in a later capture, and the crash window
  # where the call was held but the batch never recorded as told.
  in_home "$h" "$ADAPTER" told "$f" >/dev/null 2>&1 || fail "told again failed"
  f=$(capture_items "$h" 2 "$P0" "$P1" "$ITEM_ASK")
  in_home "$h" "$ADAPTER" told "$f" >/dev/null 2>&1 || fail "told on a repeated capture failed"
  set_told "$h" alpha "$P0"
  out=$(in_home "$h" "$ADAPTER" told "$f" 2>&1) || fail "told after the crash window failed: $out"
  case "$out" in *held:*) fail "the crash window held a second call: $out" ;; esac
  assert_equals "ms-alpha-c6" "$(calls_in "$h")" "a repeat wake makes no second call"

  # It is one of the owner's calls, the count the bridge strip, the Factory
  # pane and the tap page all show, with the room's projects as its options.
  out=$(desk_in "$h" export 2>&1) || fail "export failed: $out"
  assert_contains "$out" "owner's calls: 1" "the call is in the shared count"
  assert_equals '["Take on under alpha-app","Take on under studio","Decline","Later"]' \
    "$(jq -c '[.cards[] | select(.id == "ms-alpha-c6") | .options[]]' "$h/home/data/tap-desk/cards.json")" \
    "the card offers each allowed project, decline and later"
  out=$(desk_in "$h" shapes ms-alpha-c6) || fail "shapes failed"
  assert_equals '["Take on under alpha-app","Take on under studio","Decline","Later"]' \
    "$(printf '%s' "$out" | jq -c '.decisions[0].options')" "the Factory pane reads the same options"

  # A room that allows no project of this Starship can only be put off or left.
  out=$(in_home "$h" "$ADAPTER" told "$(
    doc="$TMP_ROOT/calls.beta.out"
    printf 'schema=fm-mothership-pull.v1\nroom=beta\nstatus=items\nfrom=%s\nto=%s\nitems=1\n--\n%s\n' "$P0" "$P1" "$(ask_item 4 c9 'Fix the form')" > "$doc"
    inbox="$h/home/state/procevent-inbox"
    cp "$doc" "$inbox/mothership-beta.1.result"
    printf 'mothership\n' > "$inbox/mothership-beta.1.adapter"
    printf '%s' "$inbox/mothership-beta.1.result")" 2>&1) || fail "told for beta failed: $out"
  out=$(desk_in "$h" shapes ms-beta-c9) || fail "shapes for beta failed"
  assert_equals '["Later","Leave it"]' "$(printf '%s' "$out" | jq -c '.decisions[0].options')" \
    "a room that allows nothing offers only later and leave it"
  [ -z "$(acts_of "$h")" ] || fail "holding a call sent something to the room: $(acts_of "$h")"
  pass "a request to the ship becomes exactly one owner call in the shared count, whatever repeats"
}

test_an_answer_runs_the_room_step_once() {
  local h out f until
  command -v tasks-axi >/dev/null 2>&1 || { pass "skip: tasks-axi not found"; return 0; }
  command -v node >/dev/null 2>&1 || { pass "skip: node not found"; return 0; }
  h=$(make_home answers)
  allow_rooms "$h"
  set_position "$h" alpha "$P0"
  set_told "$h" alpha "$P0"
  f=$(capture_items "$h" 1 "$P0" "$P1" "$ITEM_ASK" "$(ask_item 5 c7 'Write the notes')" \
    "$(ask_item 6 c8 "Tidy the board")")
  in_home "$h" "$ADAPTER" told "$f" >/dev/null 2>&1 || fail "told failed"
  assert_equals "$(printf 'ms-alpha-c6\nms-alpha-c7\nms-alpha-c8')" "$(calls_in "$h")" "three requests, three calls"

  # A tap on the phone page takes the request on under the chosen project.
  tap_on "$h" ms-alpha-c6 "Take on under studio"
  out=$(desk_in "$h" route --taps "$h/taps" --apply 2>&1) || fail "route failed: $out"
  assert_contains "$out" 'room: accepted: ms-alpha-c6: your ship took on "Pick a colour" in the alpha room under studio' "the tap took it on"
  assert_contains "$out" 'file the work through ordinary intake under studio with "mothership: alpha/c6" in its body' "the accepted line names the card ref the work's task carries"
  assert_equals "accept c6 --room alpha --project studio --tag alpha --cid fm-ms-alpha-c6-accept" "$(acts_of "$h")" "the room's accept ran under that project, with the tag its allow-list names it under"
  desk_in "$h" route --taps "$h/taps" --apply >/dev/null 2>&1 || fail "routing the taps again failed"
  in_home "$h" "$ADAPTER" settle >/dev/null 2>&1 || fail "settle failed"
  assert_equals 1 "$(acts_of "$h" | grep -c .)" "the accept ran once"

  # An answer from the Factory pane or chat goes through the same keyed intake.
  out=$(in_home "$h" "$ADAPTER" answer ms-alpha-c7 decline --source "the Factory pane" 2>&1) || fail "answer failed: $out"
  assert_contains "$out" 'declined: ms-alpha-c7: your ship declined "Write the notes" in the alpha room' "the answer declined it"
  show_in "$h" ms-alpha-c7 | grep -q 'state: done' || fail "the answered call is still open"
  show_in "$h" ms-alpha-c7 | grep -q 'Captain answered this call through the Factory pane' || fail "the answer's source was not recorded"
  in_home "$h" "$ADAPTER" settle ms-alpha-c7 >/dev/null 2>&1 || fail "settle again failed"
  assert_equals "decline c7 --room alpha --project alpha-app --cid fm-ms-alpha-c7-decline" "$(acts_of "$h" | sed -n 2p)" "the room's decline ran"
  assert_equals 2 "$(acts_of "$h" | grep -c .)" "the decline ran once"
  if in_home "$h" "$ADAPTER" answer ms-alpha-c6 decline >/dev/null 2>&1; then fail "an answered call took a second answer"; fi
  if out=$(in_home "$h" "$ADAPTER" answer ms-alpha-c8 maybe 2>&1); then fail "an option the call does not offer was accepted"; fi
  assert_contains "$out" "offers: Take on under alpha-app | Take on under studio | Decline | Later" "the options are named"

  # Later puts the request off to a date as a new call, which leaves the count
  # until then and is answered like the first.
  until=$(date -u -r 1800000000 +%Y-%m-%d 2>/dev/null || date -u -d @1800000000 +%Y-%m-%d)
  out=$(in_home "$h" env FM_MOTHERSHIP_NOW=$((1800000000 - 3 * 86400)) "$ADAPTER" answer ms-alpha-c8 later 2>&1) || fail "later failed: $out"
  assert_contains "$out" "later: ms-alpha-c8: \"Tidy the board\" from the alpha room is asked again on $until as ms-alpha-c8-2" "later re-held it"
  show_in "$h" ms-alpha-c8-2 | grep -q "hold_until: $until" || fail "the new call is not held to the date: $(show_in "$h" ms-alpha-c8-2)"
  out=$(desk_in "$h" export 2>&1) || fail "export failed"
  assert_contains "$out" "owner's calls: 0" "a call put off to a date is not in the count until then"
  assert_equals 2 "$(acts_of "$h" | grep -c .)" "later sent nothing to the room"

  # A room that cannot be reached leaves the answer to be carried out later, once.
  touch "$h/stub/refuse-acts"
  if out=$(in_home "$h" "$ADAPTER" answer ms-alpha-c8-2 "take on under alpha-app" 2>&1); then fail "an unreachable room counted as told"; fi
  assert_contains "$out" "failed: ms-alpha-c8-2: the alpha room was not told: Could not reach the room" "the failure is named"
  rm -f "$h/stub/refuse-acts"
  out=$(in_home "$h" "$ADAPTER" settle 2>&1) || fail "settle after the room came back failed: $out"
  assert_contains "$out" "accepted: ms-alpha-c8-2" "the answer was carried out once the room answered"
  in_home "$h" "$ADAPTER" settle >/dev/null 2>&1 || fail "a last settle failed"
  assert_equals 2 "$(acts_of "$h" | grep -c 'accept c8')" "the retry used the same client id, and nothing ran after it landed"
  assert_equals "fm-ms-alpha-c8-2-accept" "$(acts_of "$h" | grep 'accept c8' | sort -u | sed 's/.*--cid //')" "both tries share one client id"
  pass "an answer from the tap page, the Factory pane or chat runs the room's accept or decline once, and later re-holds with a date"
}

test_a_room_call_takes_only_the_owners_answer() {
  local h out f
  command -v tasks-axi >/dev/null 2>&1 || { pass "skip: tasks-axi not found"; return 0; }
  command -v node >/dev/null 2>&1 || { pass "skip: node not found"; return 0; }
  h=$(make_home owneronly)
  allow_rooms "$h"
  set_position "$h" alpha "$P0"
  set_told "$h" alpha "$P0"
  f=$(capture_items "$h" 1 "$P0" "$P1" "$ITEM_ASK" "$(ask_item 5 c7 'Write the notes')")
  in_home "$h" "$ADAPTER" told "$f" >/dev/null 2>&1 || fail "told failed"

  # Even with a recommendation marked easy to undo, the card offers no "You
  # decide" and the seven-day default never answers it.
  out=$(desk_in "$h" mark ms-alpha-c7 --recommend "Decline" --easy-undo 2>&1) || fail "mark failed: $out"
  out=$(desk_in "$h" export 2>&1) || fail "export failed: $out"
  assert_equals '{"owner_only":true,"easy_undo":true,"default_in_days":null}' \
    "$(jq -c '.cards[] | select(.id == "ms-alpha-c7") | {owner_only, easy_undo, default_in_days}' "$h/home/data/tap-desk/cards.json")" \
    "a room call's card takes only the owner's answer and is never defaulted"

  # A "you decide" tap that still arrives answers nothing: the call stays held.
  tap_choice "$h" ms-alpha-c7 you-decide
  out=$(desk_in "$h" route --taps "$h/taps" --apply 2>&1) || fail "route failed: $out"
  assert_contains "$out" "held: ms-alpha-c7: a request from a Mothership room needs the owner's own answer, so it stays held for the owner" "the delegated tap was refused"
  hold_in "$h" open ms-alpha-c7 >/dev/null 2>&1 || fail "the delegated tap closed the call"
  [ -z "$(acts_of "$h")" ] || fail "a delegated tap sent something to the room: $(acts_of "$h")"
  out=$(desk_in "$h" route --taps "$h/taps" --apply 2>&1) || fail "routing again failed: $out"
  assert_contains "$out" "already handled: 1" "the refused tap is not routed twice"

  # The owner's own tap then answers it.
  tap_on "$h" ms-alpha-c7 "Decline"
  out=$(desk_in "$h" route --taps "$h/taps" --apply 2>&1) || fail "route of the owner's tap failed: $out"
  assert_contains "$out" "room: declined: ms-alpha-c7" "the owner's own tap declined it"
  assert_equals "decline c7 --room alpha --project alpha-app --cid fm-ms-alpha-c7-decline" "$(acts_of "$h")" "the decline ran once"

  # An answer that names none of the options, by any path, is held again.
  printf 'ms-alpha-c6\tyou decide\tyou decide\n' | hold_in "$h" answers --source "a test" >/dev/null 2>&1 || fail "the answer was not recorded"
  out=$(in_home "$h" "$ADAPTER" settle 2>&1) || fail "settle failed: $out"
  assert_contains "$out" "held: ms-alpha-c6: room requests need the owner's own answer" "an off-option answer is refused"
  assert_contains "$out" "is held for the owner again as ms-alpha-c6-2" "and the call is held again"
  hold_in "$h" open ms-alpha-c6-2 >/dev/null 2>&1 || fail "the call was not held again"
  assert_equals 1 "$(acts_of "$h" | grep -c .)" "an off-option answer sent nothing to the room"

  # A project the allow-list names only with tags is taken on or declined with them.
  out=$(tell_room "$h" gamma 2 "$(ask_item 7 c9 'Fix the form')" 2>&1) || fail "told for gamma failed: $out"
  out=$(in_home "$h" "$ADAPTER" answer ms-gamma-c9 decline 2>&1) || fail "decline in gamma failed: $out"
  assert_contains "$out" "declined: ms-gamma-c9" "the decline in a tagged-only room went through"
  assert_equals "decline c9 --room gamma --project studio --tag g1 --tag g2 --cid fm-ms-gamma-c9-decline" "$(acts_of "$h" | sed -n 2p)" "the decline carried the project's tags"
  pass "a room call takes only the owner's own answer, and tagged allow-list entries go through"
}

test_runner_wakes_once_and_keeps_listening() {
  local h out sid polls_before polls
  h=$(make_home runner)
  sid=mothership-alpha
  printf '{"position":%s}\n' "$P0" > "$h/stub/saved.alpha"
  printf 'alpha = on\n' > "$h/home/config/mothership-monitor"
  in_home "$h" "$ADAPTER" ensure >/dev/null 2>&1 || fail "ensure failed"
  queue_reply "$h" 0 "out:$ITEM_ASK" "out:{\"position\":$P1}"
  in_home "$h" "$ROOT/bin/fm-procevent.sh" start "$sid" >/dev/null 2>&1 &
  wait_for_file "$h/home/state/procevent-inbox/$sid.1.handled" 100 || fail "the runner did not capture and apply the item"
  assert_place "$h" alpha "$P1" "the runner moved the place on after capture"
  [ "$(grep -c "procevent mothership $sid 1" "$h/home/state/.wake-queue" 2>/dev/null)" -eq 1 ] \
    || fail "expected exactly one wake: $(cat "$h/home/state/.wake-queue" 2>/dev/null)"
  polls_before=$(grep -c '^pull ' "$h/stub/calls")
  for _ in $(seq 1 60); do
    polls=$(grep -c '^pull ' "$h/stub/calls")
    [ "$polls" -gt "$polls_before" ] && break
    sleep 0.1
  done
  [ "$polls" -gt "$polls_before" ] || fail "the runner stopped listening after the item"
  grep -q "pull room=alpha from=$P1 " "$h/stub/calls" || fail "the next window did not read from the new place"
  out=$(in_home "$h" "$ROOT/bin/fm-procevent.sh" list 2>/dev/null | awk -v id="$sid" '$1 == id { print $3 }')
  assert_equals live "$out" "the source is still owned"
  [ ! -e "$h/home/state/procevent-inbox/$sid.2.result" ] || fail "an empty window was captured"

  # A refused key ends the source; the next session start arms the room again.
  queue_reply "$h" 4 "err:The room refused this key."
  wait_for_file "$h/home/state/procevent-inbox/$sid.2.result" 100 || fail "the refusal was not captured"
  for _ in $(seq 1 50); do
    [ -e "$h/home/state/procevent/$sid.source" ] || break
    sleep 0.1
  done
  [ ! -e "$h/home/state/procevent/$sid.source" ] || fail "a refused key did not retire the source"
  out=$(in_home "$h" "$ADAPTER" read "$h/home/state/procevent-inbox/$sid.2.result")
  assert_contains "$out" "status: refused" "the refusal reads as refused"
  in_home "$h" "$ADAPTER" ensure >/dev/null 2>&1 || fail "ensure after the refusal failed"
  [ -e "$h/home/state/procevent/$sid.source" ] || fail "ensure did not arm the on room again"
  in_home "$h" "$ADAPTER" off alpha >/dev/null 2>&1 || fail "off failed"
  pass "through the real runner one item gives one wake, the runner keeps listening, and a refusal ends the source"
}

# A PATH with no mothership command and no node on it, so the adapter's own
# fallbacks are what find the link and the node. Any other tool that shares a
# directory with a node or a mothership command stays reachable through a
# directory of links.
BARE_TOOLS="$TMP_ROOT/bare-tools"
mkdir -p "$BARE_TOOLS"
PATH_BARE=$(printf '%s' "$PATH" | tr ':' '\n' | while IFS= read -r dir; do
  [ -n "$dir" ] && [ -d "$dir" ] || continue
  if [ -e "$dir/node" ] || [ -e "$dir/mothership" ]; then
    for tool in "$dir"/*; do
      case "${tool##*/}" in (node|mothership) continue ;; esac
      [ -x "$tool" ] && [ ! -e "$BARE_TOOLS/${tool##*/}" ] && ln -s "$tool" "$BARE_TOOLS/${tool##*/}"
    done
    continue
  fi
  printf '%s:' "$dir"
done)
PATH_BARE="${PATH_BARE}$BARE_TOOLS"

# bare_home <dir> <command...>: a home with no link or node named anywhere and
# none on PATH; PATH_FRONT, when set, goes before that PATH.
bare_home() {
  local h=$1
  shift
  env -u FM_MOTHERSHIP_BIN PATH="${PATH_FRONT:+$PATH_FRONT:}$PATH_BARE" \
    NVM_DIR="$h/nvm" FM_HOME="$h/home" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" MS_STUB="$h/stub" \
    MOTHERSHIP_CONFIG="$h/rooms.json" FM_MOTHERSHIP_WAIT_SECONDS=1 \
    FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=2 "$@"
}

registered_arg() {  # <dir> <flag>: the value the alpha registration gives <flag>
  awk -v flag="$2" 'take { print; exit } $0 == flag { take = 1 }' "$1/home/state/procevent/mothership-alpha.source"
}

joined_config() {  # <dir> <room>...: a Mothership config that has joined these rooms
  local h=$1
  shift
  printf '%s\n' "$@" | jq -R . | jq -s '{default: .[0], rooms: (map({key: ., value: {url: "https://room.example.test"}}) | from_entries)}' > "$h/rooms.json"
}

test_status_without_the_link() {
  local h out
  h=$(make_home nolink)
  joined_config "$h" alpha
  out=$(bare_home "$h" "$ADAPTER" status 2>&1) || fail "status failed: $out"
  assert_not_contains "$out" "no Mothership rooms" "a joined room is not reported as no rooms"
  assert_contains "$out" "alpha: off, not listening" "the joined room is listed with its monitoring state"
  assert_contains "$out" "the Mothership link is not installed" "status says plainly that the link is missing"

  rm -f "$h/rooms.json"
  out=$(bare_home "$h" "$ADAPTER" status 2>&1) || fail "status with no config failed: $out"
  assert_contains "$out" "no Mothership rooms joined" "no config means no rooms"
  assert_contains "$out" "the Mothership link is not installed" "and still names the missing link"

  if out=$(bare_home "$h" "$ADAPTER" on alpha 2>&1); then fail "on succeeded with no link"; fi
  assert_contains "$out" "FM_MOTHERSHIP_BIN" "the refusal names where a link can be set"
  pass "status lists rooms joined in the Mothership config and says plainly when the link is missing"
}

test_link_fallbacks() {
  local h out
  h=$(make_home fallback)
  printf '{"position":%s}\n' "$P0" > "$h/stub/saved.alpha"
  mkdir -p "$h/home/projects/mothership/bin"
  cp "$STUB_BIN/mothership" "$h/home/projects/mothership/bin/mothership"
  out=$(bare_home "$h" "$ADAPTER" on alpha 2>&1) || fail "on with the link only in the home failed: $out"
  assert_equals "$h/home/projects/mothership/bin/mothership" "$(registered_arg "$h" --bin)" "the home's projects/mothership link is used"
  bare_home "$h" "$ADAPTER" off alpha >/dev/null 2>&1 || fail "off failed"

  mkdir -p "$h/onpath"
  cp "$STUB_BIN/mothership" "$h/onpath/mothership"
  out=$(PATH_FRONT="$h/onpath" bare_home "$h" "$ADAPTER" on alpha 2>&1) || fail "on with the link on PATH failed: $out"
  assert_equals "$h/onpath/mothership" "$(registered_arg "$h" --bin)" "the link on PATH wins over the home's"
  PATH_FRONT="$h/onpath" bare_home "$h" "$ADAPTER" off alpha >/dev/null 2>&1 || fail "off failed"

  if out=$(PATH_FRONT="$h/onpath" bare_home "$h" env FM_MOTHERSHIP_BIN="$h/nowhere/mothership" "$ADAPTER" on alpha 2>&1); then fail "on passed over a named link that is missing"; fi
  assert_contains "$out" "$h/nowhere/mothership (from FM_MOTHERSHIP_BIN) cannot be run" "a named link that is missing is reported"
  out=$(bare_home "$h" env FM_MOTHERSHIP_BIN="$h/nowhere/mothership" "$ADAPTER" status 2>&1) || fail "status failed: $out"
  assert_contains "$out" "alpha: off, not listening" "status still lists the room"
  assert_contains "$out" "(from FM_MOTHERSHIP_BIN) cannot be run" "status names the broken link"
  pass "the link is found through FM_MOTHERSHIP_BIN, then PATH, then the home's projects/mothership"
}

test_node_for_a_typescript_link() {
  local h out
  h=$(make_home tsnode)
  printf '{"position":%s}\n' "$P0" > "$h/stub/saved.alpha"
  mkdir -p "$h/oldnode" "$h/home/projects/mothership/bin"
  { printf '#!/usr/bin/env node\n'; sed 1d "$STUB_BIN/mothership"; } > "$h/home/projects/mothership/bin/mothership"
  chmod +x "$h/home/projects/mothership/bin/mothership"
  # shellcheck disable=SC2016  # the fake node's own script
  printf '#!/usr/bin/env bash\n[ "${1-}" = --version ] && { echo v22.13.1; exit 0; }\necho "TypeError [ERR_UNKNOWN_FILE_EXTENSION]: Unknown file extension \".ts\"" >&2\nexit 1\n' > "$h/oldnode/node"
  chmod +x "$h/oldnode/node"
  # fake_node <version> <runs|fails>: an nvm node of that version.
  # shellcheck disable=SC2016  # the fake node's own script
  fake_node() {
    local dir="$h/nvm/versions/node/v$1/bin"
    mkdir -p "$dir"
    if [ "$2" = runs ]; then
      printf '#!/usr/bin/env bash\n[ "${1-}" = --version ] && { echo v%s; exit 0; }\nexec bash "$@"\n' "$1" > "$dir/node"
    else
      printf '#!/usr/bin/env bash\n[ "${1-}" = --version ] && { echo v%s; exit 0; }\nexit 1\n' "$1" > "$dir/node"
    fi
    chmod +x "$dir/node"
  }
  fake_node 22.17.0 fails
  fake_node 24.9.0 runs
  fake_node 24.10.0 runs
  out=$(PATH_FRONT="$h/oldnode" bare_home "$h" "$ADAPTER" on alpha 2>&1) || fail "on with an old node first on PATH failed: $out"
  assert_contains "$out" "on: alpha" "the TypeScript link ran"
  assert_equals "$h/nvm/versions/node/v24.10.0/bin" "$(registered_arg "$h" --node-dir)" "the newest nvm node that runs TypeScript is chosen over PATH's old one"
  PATH_FRONT="$h/oldnode" bare_home "$h" "$ADAPTER" off alpha >/dev/null 2>&1 || fail "off failed"

  rm -rf "$h/nvm"
  fake_node 22.17.0 fails
  fake_node 22.18.0 runs
  out=$(PATH_FRONT="$h/oldnode" bare_home "$h" "$ADAPTER" on alpha 2>&1) || fail "on with node 22.18 failed: $out"
  assert_equals "$h/nvm/versions/node/v22.18.0/bin" "$(registered_arg "$h" --node-dir)" "22.18 is new enough and 22.17 is not"
  PATH_FRONT="$h/oldnode" bare_home "$h" "$ADAPTER" off alpha >/dev/null 2>&1 || fail "off failed"

  rm -rf "$h/nvm"
  fake_node 23.5.0 runs
  if out=$(PATH_FRONT="$h/oldnode" bare_home "$h" "$ADAPTER" on alpha 2>&1); then fail "on accepted a machine with no node that runs TypeScript"; fi
  assert_contains "$out" "no node on this machine can run the Mothership link's TypeScript" "no usable node is reported"
  [ ! -e "$h/home/state/procevent/mothership-alpha.source" ] || fail "a link with no usable node was registered"
  pass "a TypeScript link runs with a node that can run it, never just the first node on PATH"
}

fm_test_run \
  test_status_without_the_link \
  test_link_fallbacks \
  test_node_for_a_typescript_link \
  test_help \
  test_no_setting_runs_nothing \
  test_on_off_status \
  test_config_pinned_only_when_named \
  test_ensure_follows_the_setting \
  test_ensure_bounds_a_room_that_never_answers \
  test_source_windows \
  test_source_notes_a_room_it_cannot_reach \
  test_off_clears_the_unreachable_note \
  test_autohandle_and_told \
  test_told_after_a_missed_told \
  test_read_cleans_room_text \
  test_a_request_becomes_one_owner_call \
  test_an_answer_runs_the_room_step_once \
  test_a_room_call_takes_only_the_owners_answer \
  test_runner_wakes_once_and_keeps_listening
