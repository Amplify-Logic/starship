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
# returns the place it was given. Every call is logged to `calls`.
cat > "$STUB_BIN/mothership" <<'SH'
#!/usr/bin/env bash
set -u
d=${MS_STUB:?}
cmd=${1-}
[ "$#" -eq 0 ] || shift
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
  rooms) cat "$d/rooms" 2>/dev/null; exit 0 ;;
  position)
    if [ -e "$d/old" ]; then echo "Unknown command position. Run mothership help." >&2; exit 1; fi
    if [ -n "$set_pos" ]; then printf '{"position":%s}\n' "$set_pos" > "$d/saved.$room"; cat "$d/saved.$room"; exit 0; fi
    if [ "$now" = 1 ]; then cat "$d/now"; exit 0; fi
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
  printf 'alpha  https://room.example.test\nbeta  https://other.example.test\n' > "$h/stub/rooms"
  printf '{"position":%s}\n' "$NOW" > "$h/stub/now"
  fm_test_track_procevent_home "$h/home" "$CLAIMS"
  printf '%s\n' "$h"
}

# in_home <dir> <command...>
in_home() {
  local h=$1
  shift
  FM_HOME="$h/home" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" MS_STUB="$h/stub" \
    FM_MOTHERSHIP_BIN="$STUB_BIN/mothership" MOTHERSHIP_CONFIG="$h/rooms.json" \
    FM_MOTHERSHIP_WAIT_SECONDS=1 FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=2 "$@"
}

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

fm_test_run \
  test_help \
  test_no_setting_runs_nothing \
  test_on_off_status \
  test_config_pinned_only_when_named \
  test_ensure_follows_the_setting \
  test_source_windows \
  test_autohandle_and_told \
  test_told_after_a_missed_told \
  test_read_cleans_room_text \
  test_runner_wakes_once_and_keeps_listening
