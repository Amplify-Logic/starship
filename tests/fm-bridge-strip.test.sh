#!/usr/bin/env bash
# The Starship bridge strip: bin/fm-bridge-strip.sh.
#
# Fixture fleet states and fixture battery readings go in; the frame that comes
# out is compared word for word and colour by colour. A fixture reader stands in
# for bin/fm-crew-state.sh and a fake pmset for the battery, so no crew, pane or
# Herdr server is touched. The Herdr calls behind open, install and remove run
# against a fake herdr that records them.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-bridge-strip)
BINDIR="$TMP_ROOT/bin"
mkdir -p "$BINDIR"
STRIP="$ROOT/bin/fm-bridge-strip.sh"

E=$'\033'
AMBER="${E}[38;2;255;182;72m"
GREEN="${E}[38;2;98;221;154m"
RED="${E}[38;2;255;122;107m"
CYAN="${E}[38;2;116;215;234m"
MIST="${E}[38;2;163;180;203m"
LAMP_OFF="${E}[38;2;61;82;115m"
HULL_BG="${E}[48;2;13;21;36m"
LAMP=$'\342\226\240'

cat > "$BINDIR/fake-crew-state" <<'SH'
#!/usr/bin/env bash
[ -f "$FM_FLEET_FIXTURE/$1" ] || exit 1
cat "$FM_FLEET_FIXTURE/$1"
SH
chmod +x "$BINDIR/fake-crew-state"

# A fake pmset that prints whatever battery reading the case wrote.
cat > "$BINDIR/fake-pmset" <<'SH'
#!/usr/bin/env bash
[ "$*" = '-g batt' ] || exit 2
cat "$FM_BRIDGE_TEST_BATTERY"
SH
chmod +x "$BINDIR/fake-pmset"

# A fake herdr that records every call and answers the plugin pane open with the
# shape Herdr 0.9.5 returns.
cat > "$BINDIR/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_BRIDGE_TEST_CALLS"
case "$1 $2 ${3:-}" in
  'plugin pane open')
    [ -z "${FM_BRIDGE_TEST_NO_PANE:-}" ] || { printf '{"result":{}}\n'; exit 0; }
    printf '{"id":"cli","result":{"type":"plugin_pane_opened","plugin_pane":{"plugin_id":"starship.bridge","entrypoint":"bridge","pane":{"pane_id":"w1:p9"}}}}\n'
    ;;
  'plugin config-dir starship.bridge') printf '%s\n' "$FM_BRIDGE_TEST_CONFIG" ;;
esac
exit 0
SH
chmod +x "$BINDIR/herdr"

CASE=0
reset_case() {
  CASE=$((CASE + 1))
  HOME_FIX="$TMP_ROOT/case$CASE/home"
  FLEET_FIX="$TMP_ROOT/case$CASE/fleet"
  CONFIG_FIX="$TMP_ROOT/case$CASE/config"
  CALLS="$TMP_ROOT/case$CASE/calls"
  mkdir -p "$HOME_FIX/state" "$FLEET_FIX"
  : > "$CALLS"
  export FM_FLEET_FIXTURE="$FLEET_FIX"
  battery_reading ''
}

task() {  # <id> <canonical line>
  fm_write_meta "$HOME_FIX/state/$1.meta" kind=crew
  printf '%s\n' "$2" > "$FLEET_FIX/$1"
}

battery_reading() {  # <pmset -g batt output, or empty for a machine with none>
  BATTERY_FIX="$TMP_ROOT/case$CASE/battery"
  printf '%s' "$1" > "$BATTERY_FIX"
}

on_battery() {  # <percent> <state> <left>
  battery_reading "Now drawing from 'Battery Power'
 -InternalBattery-0 (id=1234567)	$1%; $2; $3 remaining present: true
"
}

on_mains() {  # <percent> <state>
  battery_reading "Now drawing from 'AC Power'
 -InternalBattery-0 (id=1234567)	$1%; $2; 1:10 remaining present: true
"
}

frame() {  # <width> [height]
  FM_HOME="$HOME_FIX" FM_FLEET_STATE_NO_CACHE="${FM_FLEET_STATE_NO_CACHE:-1}" \
    FM_FLEET_STATE_READER="${READER:-$BINDIR/fake-crew-state}" \
    FM_BRIDGE_STRIP_PMSET="$BINDIR/fake-pmset" FM_BRIDGE_TEST_BATTERY="$BATTERY_FIX" \
    bash "$STRIP" render --width "$1" --height "${2:-1}"
}

plain() { sed $'s/\033\\[[0-9;]*m//g'; }

# The row a pane of <width> columns should get: one column of margin each side,
# the left side flush left and the battery flush right.
row_of() {  # <width> <left> [right]
  local left=$2 right=${3:-} fill
  fill=$(($1 - 2 - $(columns "$left") - $(columns "$right")))
  printf ' %s%*s%s ' "$left" "$fill" '' "$right"
}

# Columns a plain row takes. Each of the strip's glyphs is one column, so they
# are counted as one character whatever the ambient locale counts bytes as.
columns() {  # <plain row>
  local row
  row=$(printf '%s' "$1" | sed $'s/\342\226\240/#/g; s/\342\224\202/|/g')
  printf '%s' "${#row}"
}

a_busy_fleet() {
  task typing 'state: working · source: pane · harness busy'
  task checking 'state: working · source: run-step · run ci'
  task asking 'state: parked · source: status-log · which of two designs'
  task green 'state: done · source: run-step · checks passed'
  task landed 'state: done · source: run-step · checks green: PR merged (ci monitor ended)'
}

# --- the crew -----------------------------------------------------------------

test_a_fleet_lights_busy_decision_and_ready_lamps() {
  local out row
  reset_case
  a_busy_fleet
  on_battery 57 discharging 3:12
  out=$(frame 110)
  row=$(printf '%s' "$out" | plain)
  assert_equals "$row" "$(row_of 110 'S T A R S H I P  │  ■ 2 busy   ■ 1 decision for you   ■ 1 ready to merge' \
    'battery 57%, 3:12 left')" "the wide strip"
  assert_contains "$out" "${AMBER}${LAMP} " "busy work did not light the amber lamp"
  assert_contains "$out" "${RED}${LAMP} " "a decision for the owner did not light the red lamp"
  assert_contains "$out" "${GREEN}${LAMP} " "work ready to merge did not light the green lamp"
  assert_contains "$out" "${CYAN}S T A R S H I P" "the wordmark is not cyan"
  assert_contains "$out" "$HULL_BG" "the strip is not painted in the hull colour"
  assert_not_contains "$row" 'typing' "a task id reached the strip"
  pass "bridge strip: busy, decisions-for-you and ready-to-merge lamps light from the fleet reading"
}

test_the_decision_lamp_counts_in_its_own_words() {
  reset_case
  task asking 'state: parked · source: status-log · which of two designs'
  task naming 'state: parked · source: status-log · what to call the release'
  assert_contains "$(frame 110 | plain)" '■ 2 decisions for you ' "two decisions in the long form"
  assert_contains "$(frame 60 | plain)" '■ 2 decisions ' "two decisions in the short form"
  assert_not_contains "$(frame 110 | plain)" 'waiting for you' "the strip reused the status bar's words for a different count"
  pass "bridge strip: the red lamp names decisions, never the status bar's waiting for you"
}

test_an_idle_fleet_shows_unlit_lamps() {
  local out
  reset_case
  out=$(frame 110)
  assert_equals "$(printf '%s' "$out" | plain)" \
    "$(row_of 110 'S T A R S H I P  │  ■ 0 busy   ■ 0 decisions for you   ■ 0 ready to merge')" \
    "the idle strip"
  assert_contains "$out" "${LAMP_OFF}${LAMP} " "an empty lamp was lit"
  assert_not_contains "$out" "${AMBER}${LAMP}" "an idle fleet lit the busy lamp"
  pass "bridge strip: an idle fleet shows unlit lamps and no battery on a machine without one"
}

test_an_unread_fleet_says_so_instead_of_zero() {
  local out
  reset_case
  task typing 'state: working · source: pane · harness busy'
  out=$(FM_FLEET_STATE_NO_CACHE=0 READER="$BINDIR/absent-reader" frame 110 | plain)
  assert_contains "$out" 'reading the crew' "an unread fleet was not named as being read"
  assert_not_contains "$out" '0 busy' "an unread fleet was shown as an idle one"
  pass "bridge strip: a fleet with no reading yet says it is being read, never zero"
}

test_a_last_good_reading_is_marked_with_its_age() {
  local out
  reset_case
  task typing 'state: working · source: pane · harness busy'
  printf '400\t1\t0\t2\t0\t0\t3\tstale-signature\t1' > "$HOME_FIX/state/.status-fleet-state"
  out=$(FM_FLEET_STATE_NO_CACHE=0 FM_FLEET_STATE_NOW=1000 READER="$BINDIR/absent-reader" frame 110 | plain)
  assert_contains "$out" '■ 3 busy   ■ 1 decision for you   ■ 2 ready to merge (10m ago)' \
    "a reading that is no longer current was not marked with its age"
  pass "bridge strip: a last good reading stands in with its age"
}

test_a_reading_from_before_the_split_is_not_guessed() {
  local out
  reset_case
  task green 'state: done · source: run-step · checks passed'
  # A reading written before decisions were counted apart cannot say which of
  # its ready work is a decision, so the strip shows no lamps rather than guess.
  printf '1000\t0\t0\t0\t0\t0\t1\tsig' > "$HOME_FIX/state/.status-fleet-state"
  out=$(FM_FLEET_STATE_NO_CACHE=0 FM_FLEET_STATE_NOW=1000 READER="$BINDIR/absent-reader" frame 110 | plain)
  assert_contains "$out" 'reading the crew' "an older reading was split by guesswork"
  pass "bridge strip: a reading that cannot split decisions from merges is not guessed"
}

test_rendering_changes_nothing_in_the_home() {
  local before after
  reset_case
  a_busy_fleet
  : > "$HOME_FIX/state/typing.status"
  before=$(cd "$HOME_FIX" && find . -exec ls -ld {} + | LC_ALL=C sort)
  frame 110 >/dev/null
  after=$(cd "$HOME_FIX" && find . -exec ls -ld {} + | LC_ALL=C sort)
  assert_equals "$after" "$before" "rendering a frame changed the home"
  pass "bridge strip: a frame reads the home and writes nothing to it"
}

# --- the battery --------------------------------------------------------------

test_the_battery_warns_before_it_runs_flat() {
  local out
  reset_case
  on_battery 57 discharging 3:12
  out=$(frame 110)
  assert_contains "$(printf '%s' "$out" | plain)" 'battery 57%, 3:12 left ' "a healthy battery reading"
  assert_contains "$out" "${MIST}battery 57%" "a healthy battery is not quiet"

  on_battery 22 discharging 0:48
  out=$(frame 110)
  assert_contains "$out" "${AMBER}${LAMP} battery 22%, 0:48 left" "a battery under 25% did not turn amber"

  on_battery 8 discharging 0:12
  out=$(frame 110)
  assert_contains "$out" "${RED}${LAMP} battery 8%, plug in now" "a battery under 10% did not turn red"

  on_mains 8 charging
  out=$(frame 110)
  assert_contains "$out" "${MIST}battery 8%, charging" "a charging battery was raised as a warning"

  on_mains 100 charged
  assert_contains "$(frame 110 | plain)" 'battery 100%, full ' "a full battery reading"

  on_mains 80 'AC attached'
  assert_contains "$(frame 110 | plain)" 'battery 80%, plugged in ' "a battery held on mains"

  on_battery 40 discharging '(no estimate)'
  battery_reading "Now drawing from 'Battery Power'
 -InternalBattery-0 (id=1234567)	40%; discharging; (no estimate) present: true
"
  assert_contains "$(frame 110 | plain)" 'battery 40% ' "a battery with no estimate"

  battery_reading "Now drawing from 'AC Power'
"
  assert_not_contains "$(frame 110 | plain)" 'battery' "a machine with no battery showed one"
  pass "bridge strip: the battery is quiet when healthy, amber under 25% and red under 10% on battery"
}

# --- narrow panes -------------------------------------------------------------

test_every_width_fills_the_row_exactly() {
  local width row
  reset_case
  a_busy_fleet
  on_battery 57 discharging 3:12
  for width in 1 4 8 12 16 20 24 30 36 44 52 60 70 80 90 100 110 140; do
    row=$(frame "$width" | plain)
    [ "$(columns "$row")" -eq "$width" ] \
      || fail "a $width-column pane got a $(columns "$row")-column row: [$row]"
  done
  pass "bridge strip: every pane width gets a row of exactly that width, never wrapped"
}

test_a_narrow_pane_keeps_the_crew_and_a_low_battery() {
  local row
  reset_case
  a_busy_fleet
  on_battery 57 discharging 3:12
  assert_equals "$(frame 80 | plain)" \
    "$(row_of 80 'STARSHIP  │  ■ 2 busy  ■ 1 decision  ■ 1 to merge' 'battery 57%')" \
    "an 80-column strip"
  assert_equals "$(frame 60 | plain)" \
    "$(row_of 60 'STARSHIP  │  ■ 2 busy  ■ 1 decision  ■ 1 to merge' '57%')" "a 60-column strip"
  assert_equals "$(frame 34 | plain)" "$(row_of 34 'STARSHIP  │  ■ 2 ■ 1 ■ 1' '57%')" "a 34-column strip"
  assert_equals "$(frame 18 | plain)" "$(row_of 18 '■ 2 ■ 1 ■ 1')" "an 18-column strip"
  on_battery 8 discharging 0:12
  # A low battery outranks the wordmark and then the lamps as the pane narrows.
  assert_equals "$(frame 24 | plain)" "$(row_of 24 '■ 2 ■ 1 ■ 1' '■ 8%')" "a 24-column strip with a low battery"
  assert_equals "$(frame 16 | plain)" "$(row_of 16 '' '■ 8%')" "a 16-column strip with a low battery"
  row=$(frame 4 | plain)
  assert_equals "$row" '8%  ' "the narrowest strip dropped a low battery"
  pass "bridge strip: a narrow pane drops words before lamps and never drops a low battery"
}

test_a_taller_pane_centres_the_strip() {
  local out
  reset_case
  out=$(frame 40 3 | plain)
  assert_equals "$(printf '%s\n' "$out" | sed -n 1p)" "$(printf '%40s' '')" "the top row is not an empty deck"
  assert_contains "$(printf '%s\n' "$out" | sed -n 2p)" 'STARSHIP' "the strip is not on the middle row"
  assert_equals "$(printf '%s\n' "$out" | sed -n 3p)" "$(printf '%40s' '')" "the bottom row is not an empty deck"
  pass "bridge strip: a pane taller than one row keeps the strip on its middle row"
}

# --- Herdr: open, install and remove ------------------------------------------

herdr_env() {
  export HERDR_BIN_PATH="$BINDIR/herdr" FM_BRIDGE_TEST_CALLS="$CALLS"
  export FM_BRIDGE_TEST_CONFIG="$CONFIG_FIX" FM_BRIDGE_STRIP_CONFIG_DIR="$CONFIG_FIX"
}

test_open_puts_the_strip_above_the_pane() {
  local out
  reset_case
  out=$(herdr_env; FM_HOME="$HOME_FIX" HERDR_PANE_ID=w1:p2 HERDR_TAB_ID=w1:t1 bash "$STRIP" open 2>&1) \
    || fail "open failed: $out"
  assert_equals "$(cat "$CALLS")" "plugin pane open --plugin starship.bridge --entrypoint bridge --placement split --direction down --target-pane w1:p2 --no-focus --env FM_HOME=$HOME_FIX
pane swap --source-pane w1:p9 --target-pane w1:p2
pane resize --pane w1:p2 --direction up --amount 0.5" "the Herdr calls behind open"
  pass "bridge strip: open splits the pane, swaps the strip on top and makes it slim"
}

test_open_stops_when_herdr_does_not_name_the_strip() {
  local out
  reset_case
  if out=$(herdr_env; FM_BRIDGE_TEST_NO_PANE=1 FM_HOME="$HOME_FIX" HERDR_PANE_ID=w1:p2 bash "$STRIP" open 2>&1); then
    fail "open reported success with no strip pane named"
  fi
  assert_contains "$out" 'did not name it' "the refusal does not say why"
  assert_no_grep 'pane swap' "$CALLS" "a pane Herdr did not name was moved"
  assert_no_grep 'pane resize' "$CALLS" "a pane Herdr did not name was resized"
  pass "bridge strip: open moves nothing when Herdr does not name the pane it opened"
}

test_open_does_not_stack_a_second_strip_in_a_tab() {
  local out strip_pid
  reset_case
  mkdir -p "$CONFIG_FIX/panes"
  bash -c "exec -a 'fm-bridge-strip.sh run' sleep 30" &
  strip_pid=$!
  printf 'pane=w1:p9\ntab=w1:t1\n' > "$CONFIG_FIX/panes/$strip_pid"
  out=$(herdr_env; FM_HOME="$HOME_FIX" HERDR_PANE_ID=w1:p2 HERDR_TAB_ID=w1:t1 bash "$STRIP" open 2>&1)
  kill "$strip_pid" 2>/dev/null
  wait "$strip_pid" 2>/dev/null
  assert_contains "$out" 'already showing' "a second strip was opened in the same tab"
  assert_no_grep 'plugin pane open' "$CALLS" "a second strip was opened in the same tab"
  pass "bridge strip: open leaves a tab that already shows the strip alone"
}

test_open_is_not_stopped_by_a_recycled_pid() {
  local out editor_pid
  reset_case
  mkdir -p "$CONFIG_FIX/panes"
  # A strip that died without clearing its record, its pid now an editor open
  # on the script: that is no strip, so the tab is free.
  bash -c "exec -a 'vim bin/fm-bridge-strip.sh' sleep 30" &
  editor_pid=$!
  printf 'pane=w1:p9\ntab=w1:t1\n' > "$CONFIG_FIX/panes/$editor_pid"
  out=$(herdr_env; FM_HOME="$HOME_FIX" HERDR_PANE_ID=w1:p2 HERDR_TAB_ID=w1:t1 bash "$STRIP" open 2>&1)
  kill "$editor_pid" 2>/dev/null
  wait "$editor_pid" 2>/dev/null
  assert_not_contains "$out" 'already showing' "a recycled pid was taken for a running strip"
  assert_grep 'plugin pane open' "$CALLS" "a recycled pid kept the strip from opening"
  pass "bridge strip: open is not stopped by a record whose pid now runs something else"
}

test_install_links_the_plugin_and_records_the_home() {
  local out
  reset_case
  out=$(herdr_env; unset HERDR_PANE_ID; FM_HOME="$HOME_FIX" bash "$STRIP" install 2>&1) \
    || fail "install failed: $out"
  assert_grep "plugin link $ROOT/herdr-plugins/starship-bridge" "$CALLS" "install did not link the plugin"
  assert_equals "$(cat "$CONFIG_FIX/home")" "$HOME_FIX" "install did not record the home"
  assert_no_grep 'plugin pane open' "$CALLS" "install outside a pane opened a strip"
  assert_contains "$out" 'open' "install outside a pane does not say how to show the strip"
  pass "bridge strip: install links the plugin, records the home, and opens only inside a pane"
}

test_remove_stops_only_its_own_strips_and_unlinks() {
  local out strip_pid other_pid editor_pid
  reset_case
  mkdir -p "$CONFIG_FIX/panes"
  printf '%s\n' "$HOME_FIX" > "$CONFIG_FIX/home"
  bash -c "exec -a 'fm-bridge-strip.sh run' sleep 30" &
  strip_pid=$!
  sleep 30 &
  other_pid=$!
  bash -c "exec -a 'vim bin/fm-bridge-strip.sh' sleep 30" &
  editor_pid=$!
  printf 'pane=w1:p9\ntab=w1:t1\n' > "$CONFIG_FIX/panes/$strip_pid"
  # Records whose pid now belongs to another process, even one that names the
  # script without running the strip: each must survive.
  printf 'pane=w1:p3\ntab=w1:t1\n' > "$CONFIG_FIX/panes/$other_pid"
  printf 'pane=w1:p4\ntab=w1:t1\n' > "$CONFIG_FIX/panes/$editor_pid"
  out=$(herdr_env; bash "$STRIP" remove 2>&1) || fail "remove failed: $out"
  wait "$strip_pid" 2>/dev/null
  kill -0 "$other_pid" 2>/dev/null || fail "remove stopped a process that was not a strip"
  kill -0 "$editor_pid" 2>/dev/null || fail "remove stopped a process that names the script but is not a strip"
  kill "$other_pid" "$editor_pid" 2>/dev/null
  wait "$other_pid" "$editor_pid" 2>/dev/null
  kill -0 "$strip_pid" 2>/dev/null && fail "remove left a running strip"
  assert_grep 'plugin unlink starship.bridge' "$CALLS" "remove did not unlink the plugin"
  assert_no_grep 'pane close' "$CALLS" "remove closed a pane by id"
  assert_absent "$CONFIG_FIX/home" "remove left the recorded home"
  assert_contains "$out" '1 strip' "remove did not count the strip it closed"
  pass "bridge strip: remove stops only the strips it recorded, then unlinks the plugin"
}

fm_test_run \
  test_a_fleet_lights_busy_decision_and_ready_lamps \
  test_the_decision_lamp_counts_in_its_own_words \
  test_an_idle_fleet_shows_unlit_lamps \
  test_an_unread_fleet_says_so_instead_of_zero \
  test_a_last_good_reading_is_marked_with_its_age \
  test_a_reading_from_before_the_split_is_not_guessed \
  test_rendering_changes_nothing_in_the_home \
  test_the_battery_warns_before_it_runs_flat \
  test_every_width_fills_the_row_exactly \
  test_a_narrow_pane_keeps_the_crew_and_a_low_battery \
  test_a_taller_pane_centres_the_strip \
  test_open_puts_the_strip_above_the_pane \
  test_open_stops_when_herdr_does_not_name_the_strip \
  test_open_does_not_stack_a_second_strip_in_a_tab \
  test_open_is_not_stopped_by_a_recycled_pid \
  test_install_links_the_plugin_and_records_the_home \
  test_remove_stops_only_its_own_strips_and_unlinks
