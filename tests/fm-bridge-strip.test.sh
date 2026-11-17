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
# The owner's calls read the backlog through the tasks-axi adapter; this
# stand-in serves the home's markdown rows.
fm_install_markdown_tasks_axi "$TMP_ROOT/axibin"
export PATH="$TMP_ROOT/axibin:$PATH"
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
# Keyboard focus, kept as real Herdr does: --no-focus leaves it where it was,
# a swap hands it to the source pane, and a focus call moves it to the pane on
# that side (here the strip has only the target pane below it).
focus="${FM_BRIDGE_TEST_CALLS%/*}/focus"
arg() { local want=$1; shift; while [ "$#" -gt 1 ]; do [ "$1" = "$want" ] && { printf '%s' "$2"; return; }; shift; done; }
case "$1 $2 ${3:-}" in
  'plugin pane open')
    [ -z "${FM_BRIDGE_TEST_NO_PANE:-}" ] || { printf '{"result":{}}\n'; exit 0; }
    case " $* " in *' --no-focus '*) ;; *) printf 'w1:p9\n' > "$focus" ;; esac
    printf '{"id":"cli","result":{"type":"plugin_pane_opened","plugin_pane":{"plugin_id":"starship.bridge","entrypoint":"bridge","pane":{"pane_id":"w1:p9"}}}}\n'
    ;;
  'pane swap '*) arg --source-pane "$@" > "$focus" ;;
  'pane focus '*)
    [ "$(arg --pane "$@")" = w1:p9 ] && [ "$(arg --direction "$@")" = down ] && printf 'w1:p2' > "$focus"
    ;;
  'pane neighbor '*)
    printf '{"result":{"type":"pane_neighbor","neighbor":{"pane_id":"%s","direction":"down","neighbor_pane_id":"w1:p2"}}}\n' \
      "$(arg --pane "$@")"
    ;;
  'plugin config-dir starship.bridge') printf '%s\n' "$FM_BRIDGE_TEST_CONFIG" ;;
  'plugin config-dir starship.factory') printf '%s\n' "$FM_BRIDGE_TEST_CONFIG/factory" ;;
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
  mkdir -p "$HOME_FIX/state" "$HOME_FIX/data" "$HOME_FIX/config" "$FLEET_FIX"
  : > "$CALLS"
  export FM_FLEET_FIXTURE="$FLEET_FIX"
  battery_reading ''
}

task() {  # <id> <canonical line> [metadata...]
  local id=$1 line=$2
  shift 2
  if [ "$#" -gt 0 ]; then
    fm_write_meta "$HOME_FIX/state/$id.meta" "$@"
  else
    fm_write_meta "$HOME_FIX/state/$id.meta" kind=crew
  fi
  printf '%s\n' "$line" > "$FLEET_FIX/$id"
}

# work <id> <title> [state]: a work item in the home's backlog, as tasks-axi
# writes it, so a ready task has a title to be named by.
work() {
  local file="$HOME_FIX/data/backlog.md"
  [ -e "$file" ] || printf '## In flight\n\n## Queued\n' > "$file"
  printf -- '- [ ] %s - %s (repo: sample) (kind: ship)\n' "$1" "$2" >> "$file"
}

# held <id> <title> [extra metadata]: a decision held for the owner, in the
# home's backlog the way tasks-axi writes it. Only these light the red lamp.
held() {
  local file="$HOME_FIX/data/backlog.md"
  mkdir -p "$HOME_FIX/data"
  [ -e "$file" ] || printf '## In flight\n\n## Queued\n' > "$file"
  printf -- '- [ ] %s - %s (repo: sample) (kind: captain) (hold: choose one) (hold-kind: captain)%s\n' \
    "$1" "$2" "${3:+ $3}" >> "$file"
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
  TZ=UTC FM_HOME="$HOME_FIX" FM_FLEET_STATE_NO_CACHE="${FM_FLEET_STATE_NO_CACHE:-1}" \
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
  row=$(printf '%s' "$1" | sed $'s/\342\226\240/#/g; s/\342\224\202/|/g; s/\342\226\270/>/g')
  printf '%s' "${#row}"
}

a_busy_fleet() {
  task typing 'state: working · source: pane · harness busy'
  task checking 'state: working · source: run-step · run ci'
  task asking 'state: parked · source: status-log · which of two designs'
  task green 'state: done · source: run-step · checks passed'
  task landed 'state: done · source: run-step · checks green: PR merged (ci monitor ended)'
  held pick-design 'Which of two designs'
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
  held pick-design 'Which of two designs'
  held name-release 'What to call the release'
  assert_contains "$(frame 110 | plain)" '■ 2 decisions for you ' "two decisions in the long form"
  assert_contains "$(frame 60 | plain)" '■ 2 decisions ' "two decisions in the short form"
  assert_not_contains "$(frame 110 | plain)" 'waiting for you' "the strip reused the status bar's words for a different count"
  pass "bridge strip: the red lamp names decisions, never the status bar's waiting for you"
}

# On 2026-11-14 the strip lit the red lamp for workers' own questions, which
# firstmate answers, while the owner's held decisions went uncounted. Only a
# live held decision is his: a worker's question, an ask-user review finding, a
# worker's pause and a hold deferred to a date light nothing red.
test_only_the_owners_live_held_decisions_light_the_red_lamp() {
  local out
  reset_case
  task asking 'state: parked · source: status-log · needs-decision: which of two designs'
  task owed 'state: parked · source: run-step · parked at review: 1 finding(s) · ask-user: authority decision · run: r1'
  task waiting 'state: paused · source: status-log · waiting on the carrier'
  held later 'Revisit the release name' '(hold-until: 2099-01-01)'
  out=$(frame 110 | plain)
  assert_contains "$out" '■ 0 busy   ■ 0 decisions for you   ■ 0 ready to merge' \
    "a question that is not the owner's lit the red lamp"
  held pick-design 'Which of two designs'
  assert_contains "$(frame 110 | plain)" '■ 1 decision for you ' "the owner's live held decision was not counted"
  pass "bridge strip: only the owner's live held decisions light the red lamp"
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
  printf '400\t1\t0\t2\t0\t0\t3\tstale-signature\t1\tcalls' > "$HOME_FIX/state/.status-fleet-state"
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

# --- the most urgent call ----------------------------------------------------

test_the_most_urgent_call_is_named_after_the_lamps() {
  local out row
  reset_case
  task green 'state: done · source: run-step · checks passed'
  work green 'Feedback button'
  out=$(frame 130)
  row=$(printf '%s' "$out" | plain)
  assert_equals "$row" "$(row_of 130 'S T A R S H I P  │  ■ 0 busy   ■ 0 decisions for you   ■ 1 ready to merge  │  ▸ Merge: Feedback button')" \
    "a merge is named after the lamps"
  assert_contains "$out" "${CYAN}▸ " "the call is not marked as the way in"
  # A held decision waits on the owner before work ready to land does.
  held pick-design 'Which of two designs'
  assert_contains "$(frame 130 | plain)" '│  ▸ Decide: Which of two designs ' "the decision does not come first"
  pass "bridge strip: the owner's most urgent call is named, decisions before merges"
}

test_the_call_only_takes_the_columns_left_over() {
  reset_case
  a_busy_fleet
  on_battery 57 discharging 3:12
  # 110 columns hold the lamps and the battery with too little left for a name.
  assert_equals "$(frame 110 | plain)" "$(row_of 110 'S T A R S H I P  │  ■ 2 busy   ■ 1 decision for you   ■ 1 ready to merge' \
    'battery 57%, 3:12 left')" "the call pushed the strip into a narrower tier"
  assert_equals "$(frame 125 | plain)" "$(row_of 125 'S T A R S H I P  │  ■ 2 busy   ■ 1 decision for you   ■ 1 ready to merge  │  ▸ Decide: Which of...' \
    'battery 57%, 3:12 left')" "a name with little room is cut, not dropped"
  assert_contains "$(frame 160 | plain)" '▸ Decide: Which of two designs   ' "a wide pane shows the whole name"
  pass "bridge strip: the call takes only the columns the lamps and the battery leave, cut short before it is dropped"
}

test_a_title_is_shown_as_plain_text() {
  reset_case
  task green 'state: done · source: run-step · checks passed'
  work green $'Fix the \xe2\x80\x9cshare\xe2\x80\x9d sheet \xe2\x80\x94 caf\xc3\xa9 \xf0\x9f\x8e\x89 first'
  assert_contains "$(frame 140 | plain)" "▸ Merge: Fix the \"share\" sheet - caf? ? first " \
    "a title with non-ASCII text was not made plain"
  pass "bridge strip: a call's title is made plain text so its columns can be counted"
}

# click_strip <label|column> <width>: run the live strip under a pty of 3 rows,
# click a column of its middle row the way Herdr reports a click to a pane that
# asked for mouse reports, and save what it drew. `label` clicks the call.
click_strip() {
  python3 - "$STRIP" "$1" "$2" "$TMP_ROOT/case$CASE/screen" <<'PY'
import fcntl, os, pty, re, select, signal, struct, sys, termios, time
strip, where, width, screen = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 3, width, 0, 0))
    os.execvp("bash", ["bash", strip, "run"])
seen = b""
def drain(seconds, until=None):
    global seen
    end = time.time() + seconds
    while time.time() < end and not (until and until in seen):
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                seen += os.read(fd, 65536)
            except OSError:
                break
drain(30, until="▸".encode())
drain(0.5)
text = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", seen.decode("utf-8", "replace"))
middle = [line for line in text.split("\n") if "▸" in line][-1]
column = middle.index("▸") + 1 if where == "label" else int(where)
os.write(fd, ("\x1b[<0;%d;2M\x1b[<0;%d;2m" % (column, column)).encode())
drain(4)
open(screen, "wb").write(seen)
os.kill(pid, signal.SIGTERM)
end = time.time() + 30
while True:   # keep reading so its last writes drain and it can exit
    done, _ = os.waitpid(pid, os.WNOHANG)
    if done:
        break
    if time.time() >= end:
        os.kill(pid, 9)
        os.waitpid(pid, 0)
        sys.exit("click_strip: the strip did not exit")
    drain(0.3)
PY
}

# live_click <label|column> <width>: click_strip on this case's home, below
# pane w1:p9 of a stand-in Herdr, which hands the strip its own plugin config
# directory as Herdr does. The fleet is read once into the cache the live strip
# reads, as it does in a real home, so each frame is quick.
live_click() {
  herdr_env
  FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" bash -c '
    . "$1/bin/fm-fleet-status-lib.sh"
    _fm_fleet_collect "$2" "$(date +%s)" "$3"
  ' _ "$ROOT" "$HOME_FIX/state" "$BINDIR/fake-crew-state" > "$HOME_FIX/state/.status-fleet-state" \
    || fail "the fleet could not be read for the live strip"
  FM_HOME="$HOME_FIX" FM_FLEET_STATE_TTL=3600 FM_FLEET_STATE_MAX_AGE=3600 \
    FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" FM_BRIDGE_STRIP_PMSET='' \
    HERDR_PLUGIN_CONFIG_DIR="$CONFIG_FIX" HERDR_PANE_ID=w1:p9 HERDR_TAB_ID=w1:t1 TZ=UTC \
    click_strip "$@"
}

test_a_click_on_the_call_opens_the_factory_pane_on_it() {
  local pid
  reset_case
  held pick-design 'Which of two designs'
  (live_click 3 130) || fail "the live strip could not be driven"
  assert_no_grep 'plugin pane open' "$CALLS" "a click away from the call opened something"
  assert_not_contains "$(cat "$TMP_ROOT/case$CASE/screen")" '[<0;' "the strip echoed a mouse report"
  : > "$CALLS"
  (live_click label 130) || fail "the live strip could not be driven"
  assert_grep 'pane neighbor --pane w1:p9 --direction down' "$CALLS" "the strip did not look for the pane below it"
  assert_grep "plugin pane open --plugin starship.factory --entrypoint factory --placement split --direction right --target-pane w1:p2 --focus --env FM_HOME=$HOME_FIX --env FM_FACTORY_ITEM=pick-design" \
    "$CALLS" "a click on the call did not open the Factory pane on it beside the pane below"
  # A Factory overview already in this tab, recorded in the Factory pane's own
  # config directory, moves its highlight to the call instead.
  : > "$CALLS"
  mkdir -p "$CONFIG_FIX/factory/panes"
  bash -c "exec -a 'fm-factory-pane.sh run' sleep 60" &
  pid=$!
  printf 'pane=w1:p4\ntab=w1:t1\nsession=%s\nview=overview\n' "${HERDR_SOCKET_PATH:-}" \
    > "$CONFIG_FIX/factory/panes/$pid"
  (live_click label 130) || { kill "$pid" 2>/dev/null; fail "the live strip could not be driven"; }
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  assert_no_grep 'plugin pane open' "$CALLS" "a click opened a second Factory pane in a tab that shows one"
  assert_equals "$(cat "$CONFIG_FIX/factory/focus/$pid" 2>/dev/null)" pick-design \
    "the Factory pane already in the tab was not moved to the call"
  pass "bridge strip: a click on the most urgent call opens the Factory pane on that item, or moves the one in the tab to it; a click elsewhere nothing"
}

# --- the next call, as soon as one is settled -------------------------------

# cache_fleet: read the fleet once into the cache the strip reads, as the
# out-of-band refresh does in a real home.
cache_fleet() {
  FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" bash -c '
    . "$1/bin/fm-fleet-status-lib.sh"
    _fm_fleet_collect "$2" "$(date +%s)" "$3"
  ' _ "$ROOT" "$HOME_FIX/state" "$BINDIR/fake-crew-state" > "$HOME_FIX/state/.status-fleet-state" \
    || fail "the fleet could not be read into the cache"
}

# cached_frame <width>: a frame from the cache, with the worker reading's own
# refresh an hour away, so only the owner's calls can move it.
cached_frame() {
  FM_FLEET_STATE_NO_CACHE=0 FM_FLEET_STATE_TTL=3600 FM_FLEET_STATE_MAX_AGE=3600 frame "$@"
}

# park <id>: defer a held decision to a date, the way tasks-axi rewrites its
# row when firstmate parks it with fm-captain-hold.sh hold --until.
park() {
  local file="$HOME_FIX/data/backlog.md"
  sed "s/^\(- \[ \] $1 - .*\)\$/\1 (hold-until: 2099-01-01)/" "$file" > "$file.new" && mv "$file.new" "$file"
}

# On 2026-11-15 the owner parked a held decision and the strip went on naming
# it as the one to decide, because the calls rode the worker reading's two
# minute refresh and parking changes no worker.
test_a_parked_decision_gives_way_to_the_next_call() {
  local out deadline
  reset_case
  held pick-colour 'Pick the cup colour'
  held name-shop 'Name the shop'
  cache_fleet
  out=$(cached_frame 130 | plain)
  assert_contains "$out" '■ 2 decisions for you ' "the two decisions were not counted"
  assert_contains "$out" '▸ Decide: Pick the cup colour ' "the first decision was not the call"
  park pick-colour
  deadline=$(($(date +%s) + 10))
  while :; do
    out=$(cached_frame 130 | plain)
    case "$out" in *'▸ Decide: Name the shop '*) break ;; esac
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep 0.2
  done
  assert_contains "$out" '■ 1 decision for you ' "the parked decision was still counted"
  assert_contains "$out" '▸ Decide: Name the shop ' "the parked decision was still the call"
  pass "bridge strip: a parked decision gives way to the next call without waiting for the workers' reading"
}

# strip_reading: the reading the strip takes for a frame from the cache, one
# field per line.
strip_reading() {
  FM_FLEET_STATE_TTL=3600 FM_FLEET_STATE_MAX_AGE=3600 \
    FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" bash -c '
      . "$1/bin/fm-fleet-status-lib.sh"
      fm_fleet_status_counts "$2" strip
    ' _ "$ROOT" "$HOME_FIX/state" | tr '\t' '\n'
}

# On 2026-11-15 a strip still running code from before the calls carried their
# signal read a reading saved by the newer code, and the title, the last field
# the older code knew, took in the fields saved after it, tab and all: the strip
# read 'Decide: <title>insights<signal>...'. Each saved reading is read here as
# a reader meets one saved by newer code, with a field after the ones it knows.
test_a_title_never_runs_into_fields_a_newer_reading_adds() {
  local title='What is still open from the life-insights report' signal list
  reset_case
  held life-insights "$title"
  cache_fleet
  printf '\tnewer-field' >> "$HOME_FIX/state/.status-fleet-state"
  assert_contains "$(cached_frame 200 | plain)" "▸ Decide: $title   " \
    "the reading's title ran into a field after it"
  # The owner's calls refreshed on their own between full readings.
  cache_fleet
  list=$(awk -F'\t' '{ print $18 }' "$HOME_FIX/state/.status-fleet-state")
  printf '\tnewer-field' >> "$HOME_FIX/state/.status-fleet-state"
  printf 'moved\n' > "$HOME_FIX/state/.owner-calls-changed"
  signal=$(. "$ROOT/bin/fm-owner-calls-signal-lib.sh"; fm_owner_calls_signal "$HOME_FIX/state")
  printf '%s\t%s\t%s\t1\t1\tdecision\tlife-insights\t%s\tnewer-field\n' \
    "$signal" "$list" "$(date +%s)" "$title" > "$HOME_FIX/state/.status-fleet-calls"
  assert_equals "decision
life-insights
$title
$signal" "$(strip_reading | sed -n '14,17p')" "the refreshed calls' title ran into a field after it"
  assert_contains "$(cached_frame 200 | plain)" "▸ Decide: $title   " \
    "the refreshed calls' title was not shown on its own"
  pass "bridge strip: a call's title never runs into a field a newer reading adds after it"
}

# watch_park <width> <id> <first> <next>: run the live strip under a pty, and
# once it names <first>, park decision <id> and print how many seconds pass
# until it names <next> instead (or `never`).
watch_park() {
  python3 - "$STRIP" "$@" "$HOME_FIX/data/backlog.md" <<'PY'
import fcntl, os, pty, re, select, signal, struct, sys, termios, time
strip, width, ident, first, nxt, backlog = sys.argv[1], int(sys.argv[2]), *sys.argv[3:7]
pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 3, width, 0, 0))
    os.execvp("bash", ["bash", strip, "run"])
seen = b""
def drain(seconds, until=None, start=0):
    global seen
    end = time.time() + seconds
    while time.time() < end:
        if until and until.encode() in re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", seen[start:]):
            return True
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                seen += os.read(fd, 65536)
            except OSError:
                break
    return False
result = "no first call"
if drain(30, until=first):
    mark = len(seen)
    lines = open(backlog).read().splitlines()
    lines = [l + " (hold-until: 2099-01-01)" if l.startswith("- [ ] %s - " % ident) else l for l in lines]
    began = time.time()
    with open(backlog + ".new", "w") as handle:
        handle.write("\n".join(lines) + "\n")
    os.rename(backlog + ".new", backlog)
    result = "%.1f" % (time.time() - began) if drain(15, until=nxt, start=mark) else "never"
print(result)
os.kill(pid, signal.SIGTERM)
end = time.time() + 30
while True:   # keep reading so its last writes drain and it can exit
    done, _ = os.waitpid(pid, os.WNOHANG)
    if done:
        break
    if time.time() >= end:
        os.kill(pid, 9)
        os.waitpid(pid, 0)
        break
    drain(0.3)
PY
}

test_the_live_strip_draws_the_next_call_within_seconds() {
  local took
  reset_case
  held pick-colour 'Pick the cup colour'
  held name-shop 'Name the shop'
  cache_fleet
  took=$(FM_HOME="$HOME_FIX" FM_FLEET_STATE_TTL=3600 FM_FLEET_STATE_MAX_AGE=3600 \
    FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" FM_BRIDGE_STRIP_PMSET='' TZ=UTC \
    watch_park 130 pick-colour 'Decide: Pick the cup colour' 'Decide: Name the shop') \
    || fail "the live strip could not be driven"
  case "$took" in
    never|'no first call'|'') fail "the live strip did not move on from the parked decision: $took" ;;
  esac
  # The strip's ordinary frame is five seconds; the next call must not wait
  # for it.
  awk -v t="$took" 'BEGIN { exit !(t < 4.5) }' \
    || fail "the live strip took ${took}s to name the next call"
  pass "bridge strip: the live strip names the next call within seconds of a decision being parked (${took}s)"
}

# --- the red alert ------------------------------------------------------------

test_the_red_alert_shows_failed_work_and_stopped_workers_until_they_clear() {
  local out
  reset_case
  on_battery 57 discharging 3:12
  task broke 'state: failed · source: status-log · the tests would not build'
  out=$(frame 130)
  assert_equals "$(printf '%s' "$out" | plain)" \
    "$(row_of 130 'S T A R S H I P  │  ■ 0 busy   ■ 0 decisions for you   ■ 0 ready to merge' '■ 1 failed   battery 57%, 3:12 left')" \
    "failed work did not raise the alert"
  assert_contains "$out" "${RED}${LAMP} 1 failed" "the alert is not red"
  # A failed task whose worker is gone is one broken task: the alert counts it
  # as failed only, while the status bar's stopped figure still counts it.
  task broke 'state: failed · source: status-log · the tests would not build' kind=ship \
    "worktree=$TMP_ROOT/case$CASE/gone"
  assert_contains "$(frame 130 | plain)" '■ 1 failed   battery' "a failed task whose worker is gone was counted twice"
  assert_equals "$(frame 6 | plain)" '1 brok' "the narrowest pane counted a failed task twice"
  assert_equals "$(FM_FLEET_STATE_NO_CACHE=1 FM_FLEET_STATE_READER="$BINDIR/fake-crew-state" bash -c '
    . "$1/bin/fm-fleet-status-lib.sh"
    fm_fleet_status_counts "$2"' _ "$ROOT" "$HOME_FIX/state" | cut -f3)" 1 \
    "the status bar stopped counting a failed task whose worker is gone"
  task lost 'state: parked · source: status-log · needs-decision: which way' kind=ship \
    "worktree=$TMP_ROOT/case$CASE/gone"
  assert_contains "$(frame 130 | plain)" '■ 1 failed, 1 stopped   battery' "a stopped worker did not join the alert"
  # A narrow pane keeps the alert, as it keeps a low battery.
  assert_equals "$(frame 40 | plain)" "$(row_of 40 '■ 0 ■ 0 ■ 0' '■ 2 broken   57%')" "a narrow pane dropped the alert"
  assert_equals "$(frame 6 | plain)" '2 brok' "the narrowest pane dropped the alert"
  task broke 'state: working · source: pane · harness busy'
  rm -f "$HOME_FIX/state/lost.meta" "$FLEET_FIX/lost"
  assert_not_contains "$(frame 130 | plain)" 'failed' "the alert stayed after its cause cleared"
  assert_not_contains "$(frame 130 | plain)" 'stopped' "the alert stayed after its cause cleared"
  pass "bridge strip: failed work and stopped workers raise a red alert that narrow panes keep and that clears with its cause"
}

# unreachable <room> <since> <last> <cause>: the note a room's Mothership
# listener keeps while it cannot reach the room.
unreachable() {
  mkdir -p "$HOME_FIX/state/mothership"
  printf 'since=%s\nlast=%s\ncause=%s\n' "$2" "$3" "$4" > "$HOME_FIX/state/mothership/$1.unreachable"
}

reach_frame() {  # <width>
  FM_FLEET_STATE_NOW=$NOON frame "$1"
}

NOON=1794744000      # 2026-11-15T12:00:00Z

test_the_red_alert_says_when_a_mothership_room_cannot_be_reached() {
  local out
  reset_case
  on_battery 57 discharging 3:12
  # Under two minutes is a blip, not an alert.
  unreachable alpha $((NOON - 90)) $((NOON - 30)) room
  assert_not_contains "$(reach_frame 130 | plain)" 'answering' "a short blip raised the alert"
  unreachable alpha $((NOON - 150)) $((NOON - 30)) room
  out=$(reach_frame 130)
  assert_equals "$(printf '%s' "$out" | plain)" \
    "$(row_of 130 'S T A R S H I P  │  ■ 0 busy   ■ 0 decisions for you   ■ 0 ready to merge' '■ The alpha room is not answering   battery 57%')" \
    "a room not answering did not raise the alert by its name"
  assert_contains "$out" "${RED}${LAMP} The alpha room is not answering" "the room alert is not red"
  # Tailscale switched off cuts every room off, so it is the cause shown.
  unreachable beta $((NOON - 300)) $((NOON - 20)) tailscale
  assert_contains "$(reach_frame 130 | plain)" '■ Tailscale is off on this Mac   battery' "Tailscale being off was not the alert"
  assert_not_contains "$(reach_frame 130 | plain)" 'answering' "the room alert showed beside Tailscale"
  # It joins broken work, and narrow panes keep it in short words.
  task broke 'state: failed · source: status-log · the tests would not build'
  assert_contains "$(reach_frame 130 | plain)" '■ 1 failed, Tailscale is off on this Mac   battery' "the alerts did not join"
  assert_equals "$(reach_frame 60 | plain)" "$(row_of 60 'STARSHIP  │  ■ 0 ■ 0 ■ 0' '■ 1 broken, Tailscale off   57%')" "a narrow pane dropped the reach alert"
  rm -f "$HOME_FIX/state/broke.meta" "$FLEET_FIX/broke"
  assert_equals "$(reach_frame 13 | plain)" 'Tailscale off' "the narrowest pane dropped the reach alert"
  # A listener that stopped trying leaves no alert behind.
  unreachable beta $((NOON - 900)) $((NOON - 400)) tailscale
  rm -f "$HOME_FIX/state/mothership/alpha.unreachable"
  assert_not_contains "$(reach_frame 130 | plain)" 'Tailscale' "a stale note kept the alert"
  # The room answering again removes the note, and the alert clears.
  unreachable beta $((NOON - 300)) $((NOON - 20)) tailscale
  assert_contains "$(reach_frame 130 | plain)" 'Tailscale is off' "the alert did not come back"
  rm -f "$HOME_FIX/state/mothership/beta.unreachable"
  assert_equals "$(reach_frame 130 | plain)" \
    "$(row_of 130 'S T A R S H I P  │  ■ 0 busy   ■ 0 decisions for you   ■ 0 ready to merge' 'battery 57%, 3:12 left')" \
    "the alert stayed after the room answered"
  pass "bridge strip: a Mothership room this Mac cannot reach for two minutes raises the red alert with its cause, and it clears when the room answers"
}

# --- the night shift ----------------------------------------------------------

EVENING=1794686400   # 2026-11-14T20:00:00Z
NIGHT=1794708000     # 2026-11-15T02:00:00Z
MORNING=1794729600   # 2026-11-15T08:00:00Z
AFTERNOON=1794751200 # 2026-11-15T14:00:00Z

night_frame() {  # <now> <width>
  FM_FLEET_STATE_NOW=$1 frame "$2" | plain
}

test_the_night_shift_says_when_it_starts_that_it_is_on_and_what_it_did() {
  reset_case
  on_mains 90 charged
  assert_not_contains "$(night_frame "$EVENING" 130)" 'night shift' "a home with no night shift showed one"
  printf '23:30-07:00\n' > "$HOME_FIX/config/night-shift-window"
  assert_contains "$(night_frame "$EVENING" 130)" '   night shift from 23:30   battery 90%, full ' "the evening line"
  assert_contains "$(night_frame "$NIGHT" 130)" '   night shift on   battery 90%, full ' "the line during the window"
  assert_not_contains "$(night_frame "$MORNING" 130)" 'overnight' "a morning with nothing counted claimed a figure"
  assert_not_contains "$(night_frame "$AFTERNOON" 130)" 'night shift' "the afternoon showed the night shift"

  # Finished in the window: a scout's report and a ship's ready report, and a
  # PR seen merged whose task was already cleaned up. Not counted: a ship's
  # handoff into the checks, and a ready report from before the window.
  task scout-a 'state: done · source: status-log · report ready' kind=scout
  printf 'done [at=1794711600]: report ready\n' > "$HOME_FIX/state/scout-a.status"
  task ship-b 'state: done · source: status-log · PR' kind=ship mode=no-mistakes
  printf 'done [at=1794704400]: handoff, ready for no-mistakes - x\ndone [at=1794715200]: PR https://github.com/o/r/pull/5 checks green\n' \
    > "$HOME_FIX/state/ship-b.status"
  task ship-c 'state: done · source: status-log · PR' kind=ship mode=no-mistakes
  printf 'done [at=1794704400]: handoff, ready for no-mistakes - x\n' > "$HOME_FIX/state/ship-c.status"
  task ship-d 'state: done · source: status-log · PR' kind=ship mode=direct-PR
  printf 'done [at=1794693600]: PR https://github.com/o/r/pull/7\n' > "$HOME_FIX/state/ship-d.status"
  mkdir -p "$HOME_FIX/data/landed-e" "$HOME_FIX/data/landed-f"
  printf '{"schema":"fm-contributions.v1","task":"landed-e","records":[{"url":"https://github.com/o/r/pull/8","kind":"pr","checked_at":"2026-11-15T05:00:00Z","observation":{"state":"merged"}}]}\n' \
    > "$HOME_FIX/data/landed-e/contributions.json"
  printf '{"schema":"fm-contributions.v1","task":"landed-f","records":[{"url":"https://github.com/o/r/pull/9","kind":"pr","checked_at":"2026-11-14T12:00:00Z","observation":{"state":"merged"}}]}\n' \
    > "$HOME_FIX/data/landed-f/contributions.json"
  assert_contains "$(night_frame "$MORNING" 160)" '   3 done overnight   battery 90%, full ' "the morning count"
  assert_contains "$(FM_FLEET_STATE_NOW=$MORNING frame 160)" "${GREEN}3 done overnight" "the morning count is not green"
  printf 'nonsense\n' > "$HOME_FIX/config/night-shift-window"
  assert_not_contains "$(night_frame "$MORNING" 160)" 'overnight' "a window that cannot be read showed a night shift"
  pass "bridge strip: the night shift says when it starts, that it is on, and in the morning what finished or landed in it"
}

test_every_width_fills_the_row_with_everything_on_it() {
  local width row
  reset_case
  a_busy_fleet
  task broke 'state: failed · source: status-log · the tests would not build'
  printf '23:30-07:00\n' > "$HOME_FIX/config/night-shift-window"
  on_battery 57 discharging 3:12
  for width in 1 4 8 12 16 20 24 30 36 44 52 60 70 80 90 100 110 120 130 140 160 200; do
    row=$(FM_FLEET_STATE_NOW=$EVENING frame "$width" | plain)
    [ "$(columns "$row")" -eq "$width" ] \
      || fail "a $width-column pane got a $(columns "$row")-column row: [$row]"
  done
  assert_contains "$(FM_FLEET_STATE_NOW=$EVENING frame 200 | plain)" \
    '▸ Decide: Which of two designs   ' "the widest pane lost the call"
  assert_contains "$(FM_FLEET_STATE_NOW=$EVENING frame 200 | plain)" \
    '■ 1 failed   night shift from 23:30   battery 57%, 3:12 left ' "the widest pane lost the alert or the night shift"
  pass "bridge strip: with the call, the alert and the night shift, every width still gets a row of exactly that width"
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
  printf 'w1:p2' > "${CALLS%/*}/focus"
  out=$(herdr_env; FM_HOME="$HOME_FIX" HERDR_PANE_ID=w1:p2 HERDR_TAB_ID=w1:t1 bash "$STRIP" open 2>&1) \
    || fail "open failed: $out"
  assert_equals "$(cat "$CALLS")" "plugin pane open --plugin starship.bridge --entrypoint bridge --placement split --direction down --target-pane w1:p2 --no-focus --env FM_HOME=$HOME_FIX
pane swap --source-pane w1:p9 --target-pane w1:p2
pane resize --pane w1:p2 --direction up --amount 0.5
pane focus --pane w1:p9 --direction down" "the Herdr calls behind open"
  assert_equals w1:p2 "$(cat "${CALLS%/*}/focus")" "keyboard focus was left on the strip instead of the owner's pane"
  pass "bridge strip: open splits the pane, swaps the strip on top, makes it slim and leaves focus on the pane"
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
  printf 'pane=w1:p9\ntab=w1:t1\nsession=/run/herdr-a.sock\n' > "$CONFIG_FIX/panes/$strip_pid"
  out=$(herdr_env; FM_HOME="$HOME_FIX" HERDR_PANE_ID=w1:p2 HERDR_TAB_ID=w1:t1 \
    HERDR_SOCKET_PATH=/run/herdr-a.sock bash "$STRIP" open 2>&1)
  kill "$strip_pid" 2>/dev/null
  wait "$strip_pid" 2>/dev/null
  assert_contains "$out" 'already showing' "a second strip was opened in the same tab"
  assert_no_grep 'plugin pane open' "$CALLS" "a second strip was opened in the same tab"
  pass "bridge strip: open leaves a tab that already shows the strip alone"
}

test_open_is_not_stopped_by_the_same_tab_in_another_session() {
  local out strip_pid
  reset_case
  mkdir -p "$CONFIG_FIX/panes"
  # Herdr shares the plugin's config dir across sessions, and tab ids repeat
  # between them: a strip in session A's w1:t1 says nothing of session B's.
  bash -c "exec -a 'fm-bridge-strip.sh run' sleep 30" &
  strip_pid=$!
  printf 'pane=w1:p9\ntab=w1:t1\nsession=/run/herdr-a.sock\n' > "$CONFIG_FIX/panes/$strip_pid"
  out=$(herdr_env; FM_HOME="$HOME_FIX" HERDR_PANE_ID=w1:p2 HERDR_TAB_ID=w1:t1 \
    HERDR_SOCKET_PATH=/run/herdr-b.sock bash "$STRIP" open 2>&1)
  kill "$strip_pid" 2>/dev/null
  wait "$strip_pid" 2>/dev/null
  assert_not_contains "$out" 'already showing' "a strip in another session's tab was taken for this tab's"
  assert_grep 'plugin pane open' "$CALLS" "a strip in another session kept this tab from showing one"
  pass "bridge strip: open is not stopped by a strip in the same tab id of another Herdr session"
}

test_a_running_strip_records_its_session() {
  local out pid rec
  reset_case
  # The renderer records itself before its first frame; read that record back.
  (herdr_env; FM_HOME="$HOME_FIX" HERDR_PANE_ID=w1:p9 HERDR_TAB_ID=w1:t1 \
    HERDR_SOCKET_PATH=/run/herdr-a.sock exec bash "$STRIP" run >/dev/null 2>&1) &
  pid=$!
  rec="$CONFIG_FIX/panes/$pid"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -s "$rec" ] && break
    sleep 0.1
  done
  out=$(cat "$rec" 2>/dev/null)
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  assert_contains "$out" 'tab=w1:t1' "the strip did not record its tab"
  assert_contains "$out" 'session=/run/herdr-a.sock' "the strip did not record its Herdr session"
  assert_absent "$rec" "the strip left its record behind when stopped"
  pass "bridge strip: a running strip records its tab and Herdr session, and clears them on exit"
}

# code_copy <dir>: a code root whose bin/ links to this one's, except the strip
# and the fleet library, which are real copies a case can change under a
# running strip the way an update rewrites them.
code_copy() {
  local f
  mkdir -p "$1/bin"
  for f in "$ROOT"/bin/*; do
    ln -s "$f" "$1/bin/${f##*/}"
  done
  rm "$1/bin/fm-bridge-strip.sh" "$1/bin/fm-fleet-status-lib.sh"
  cp "$ROOT/bin/fm-bridge-strip.sh" "$ROOT/bin/fm-fleet-status-lib.sh" "$1/bin/"
}

# replace_file <file> <sed expression>: rewrite a file the way git does, as a
# new file moved into place, never by writing into the one a shell is reading.
replace_file() {
  sed "$2" "$1" > "$1.new" && mv "$1.new" "$1"
}

# start_loop <code root> <output>: the strip's own loop, redrawing every second.
start_loop() {
  (herdr_env; FM_HOME="$HOME_FIX" FM_FLEET_STATE_NO_CACHE="${FM_FLEET_STATE_NO_CACHE:-1}" \
    FM_FLEET_STATE_READER="${READER:-$BINDIR/fake-crew-state}" FM_FLEET_STATE_WAIT=1 \
    FM_BRIDGE_STRIP_PMSET="$BINDIR/fake-pmset" FM_BRIDGE_TEST_BATTERY="$BATTERY_FIX" \
    FM_BRIDGE_STRIP_INTERVAL=1 exec bash "$1/bin/fm-bridge-strip.sh" run >"$2" 2>"$2.err") &
  LOOP_PID=$!
}

# shows <output> <text> [seconds]: wait until the loop's frames show <text>.
shows() {
  local tries=$((${3:-5} * 10))
  while [ "$tries" -gt 0 ]; do
    [ -f "$1" ] && plain < "$1" | grep -qF -- "$2" && return 0
    sleep 0.1
    tries=$((tries - 1))
  done
  return 1
}

stop_loop() {
  kill "$LOOP_PID" 2>/dev/null
  wait "$LOOP_PID" 2>/dev/null
}

# starts <output> <count> [seconds]: wait until the loop has started <count>
# times; each start, the first and every reload, hides the cursor once.
starts() {
  local tries=$((${3:-3} * 10))
  while [ "$tries" -gt 0 ]; do
    [ "$(grep -o $'\033\\[?25l' "$1" 2>/dev/null | grep -c '')" -ge "$2" ] && return 0
    sleep 0.1
    tries=$((tries - 1))
  done
  return 1
}

test_a_running_strip_picks_up_changed_code() {
  local code out
  reset_case
  a_busy_fleet
  code="$TMP_ROOT/case$CASE/code"
  out="$TMP_ROOT/case$CASE/frames"
  code_copy "$code"
  # The strip starts with a fleet library that cannot read the crew, as a strip
  # started before an update that changed the reading's format would.
  # shellcheck disable=SC2016 # the stand-in function is written literally
  printf '\nfm_fleet_status_counts() { _fm_fleet_unknown 0 "${2:-}"; }\n' >> "$code/bin/fm-fleet-status-lib.sh"
  start_loop "$code" "$out"
  shows "$out" 'reading the crew' 15 || { stop_loop; fail "the strip did not start: $(plain < "$out")"; }
  # The update lands: the library that can read the crew replaces it. The loop
  # redraws every second, so the next frame is the new code's.
  cp "$ROOT/bin/fm-fleet-status-lib.sh" "$code/bin/fm-fleet-status-lib.sh.new"
  mv "$code/bin/fm-fleet-status-lib.sh.new" "$code/bin/fm-fleet-status-lib.sh"
  starts "$out" 2 || { stop_loop; fail "a running strip did not reload within a redraw of its library changing"; }
  shows "$out" '■ 1 decision for you' 15 \
    || { stop_loop; fail "a reloaded strip still cannot read the crew: $(plain < "$out" | tail -c 300)"; }
  # Its own script changes too.
  replace_file "$code/bin/fm-bridge-strip.sh" 's/S T A R S H I P/S T A R B O A T/'
  starts "$out" 3 || { stop_loop; fail "a running strip did not reload within a redraw of its script changing"; }
  shows "$out" 'S T A R B O A T' 15 || { stop_loop; fail "the reloaded strip does not draw its new code"; }
  kill -0 "$LOOP_PID" 2>/dev/null || fail "the strip's process ended rather than reloading in place"
  assert_present "$CONFIG_FIX/panes/$LOOP_PID" "the reloaded strip lost its pane record"
  stop_loop
  assert_absent "$CONFIG_FIX/panes/$LOOP_PID" "the reloaded strip left its record behind when stopped"
  pass "bridge strip: a running strip reloads in place within a redraw when its script or library changes"
}

test_a_running_strip_reloads_when_an_update_drops_a_library() {
  local code out
  reset_case
  a_busy_fleet
  code="$TMP_ROOT/case$CASE/code"
  out="$TMP_ROOT/case$CASE/frames"
  code_copy "$code"
  start_loop "$code" "$out"
  shows "$out" '■ 1 decision for you' 15 || { stop_loop; fail "the strip did not start: $(plain < "$out")"; }
  # The update folds the timeout library into the fleet library and deletes it.
  awk -v lib="$ROOT/bin/fm-timeout-lib.sh" '
    /^\. "\$_FM_FLEET_LIB_DIR\/fm-timeout-lib.sh"$/ { while ((getline l < lib) > 0) print l; next }
    { print }
  ' "$ROOT/bin/fm-fleet-status-lib.sh" > "$code/bin/fm-fleet-status-lib.sh.new"
  mv "$code/bin/fm-fleet-status-lib.sh.new" "$code/bin/fm-fleet-status-lib.sh"
  rm "$code/bin/fm-timeout-lib.sh"
  starts "$out" 2 || { stop_loop; fail "a running strip did not reload after an update dropped a library"; }
  local from tries=50
  from=$(($(wc -c < "$out") + 1))
  until tail -c "+$from" "$out" | plain | grep -qF '■ 1 decision for you'; do
    tries=$((tries - 1))
    [ "$tries" -gt 0 ] || { stop_loop; fail "the reloaded strip does not read the crew: $(cat "$out.err")"; }
    sleep 0.1
  done
  kill -0 "$LOOP_PID" 2>/dev/null || fail "the strip's process ended rather than reloading in place"
  stop_loop
  pass "bridge strip: a running strip reloads when an update removes a library it used to load"
}

test_a_running_strip_waits_while_its_script_is_empty() {
  local code out
  reset_case
  a_busy_fleet
  code="$TMP_ROOT/case$CASE/code"
  out="$TMP_ROOT/case$CASE/frames"
  code_copy "$code"
  start_loop "$code" "$out"
  shows "$out" '■ 1 decision for you' 15 || { stop_loop; fail "the strip did not start: $(plain < "$out")"; }
  # The update has created the new script but not yet written it.
  : > "$code/bin/fm-bridge-strip.sh.new"
  mv "$code/bin/fm-bridge-strip.sh.new" "$code/bin/fm-bridge-strip.sh"
  sleep 3
  kill -0 "$LOOP_PID" 2>/dev/null || fail "the strip reloaded onto an empty script and ended"
  [ "$(grep -o $'\033\\[?25l' "$out" | grep -c '')" -eq 1 ] \
    || { stop_loop; fail "the strip reloaded onto an empty script"; }
  assert_present "$CONFIG_FIX/panes/$LOOP_PID" "the strip lost its pane record while its script was empty"
  # The content lands, and the next frame is the new code's.
  sed 's/S T A R S H I P/S T A R B O A T/' "$ROOT/bin/fm-bridge-strip.sh" > "$code/bin/fm-bridge-strip.sh.new"
  mv "$code/bin/fm-bridge-strip.sh.new" "$code/bin/fm-bridge-strip.sh"
  starts "$out" 2 15 || { stop_loop; fail "the strip did not reload once its script was written"; }
  shows "$out" 'S T A R B O A T' 15 || { stop_loop; fail "the reloaded strip does not draw its new code"; }
  stop_loop
  pass "bridge strip: a running strip keeps its code while an update's script is still empty, then reloads"
}

test_a_strip_that_never_reads_the_crew_says_it_cannot() {
  local out
  reset_case
  task typing 'state: working · source: pane · harness busy'
  out="$TMP_ROOT/case$CASE/frames"
  READER="$BINDIR/absent-reader" start_loop "$ROOT" "$out"
  shows "$out" 'reading the crew' || { stop_loop; fail "the first frame did not say the crew is being read"; }
  if ! shows "$out" 'cannot read the crew (since ' 8; then
    stop_loop
    fail "a strip whose readings keep failing kept saying it is reading: $(plain < "$out" | tail -c 300)"
  fi
  stop_loop
  plain < "$out" | grep -qE 'cannot read the crew \(since [0-9]{2}:[0-9]{2}\)' \
    || fail "the strip did not say since when it cannot read the crew"
  pass "bridge strip: readings that keep failing say so, with since when, rather than reading forever"
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
  test_only_the_owners_live_held_decisions_light_the_red_lamp \
  test_an_idle_fleet_shows_unlit_lamps \
  test_an_unread_fleet_says_so_instead_of_zero \
  test_a_last_good_reading_is_marked_with_its_age \
  test_a_reading_from_before_the_split_is_not_guessed \
  test_rendering_changes_nothing_in_the_home \
  test_the_most_urgent_call_is_named_after_the_lamps \
  test_the_call_only_takes_the_columns_left_over \
  test_a_title_is_shown_as_plain_text \
  test_a_click_on_the_call_opens_the_factory_pane_on_it \
  test_a_parked_decision_gives_way_to_the_next_call \
  test_a_title_never_runs_into_fields_a_newer_reading_adds \
  test_the_live_strip_draws_the_next_call_within_seconds \
  test_the_red_alert_shows_failed_work_and_stopped_workers_until_they_clear \
  test_the_red_alert_says_when_a_mothership_room_cannot_be_reached \
  test_the_night_shift_says_when_it_starts_that_it_is_on_and_what_it_did \
  test_every_width_fills_the_row_with_everything_on_it \
  test_the_battery_warns_before_it_runs_flat \
  test_every_width_fills_the_row_exactly \
  test_a_narrow_pane_keeps_the_crew_and_a_low_battery \
  test_a_taller_pane_centres_the_strip \
  test_open_puts_the_strip_above_the_pane \
  test_open_stops_when_herdr_does_not_name_the_strip \
  test_open_does_not_stack_a_second_strip_in_a_tab \
  test_open_is_not_stopped_by_the_same_tab_in_another_session \
  test_a_running_strip_records_its_session \
  test_a_running_strip_picks_up_changed_code \
  test_a_running_strip_reloads_when_an_update_drops_a_library \
  test_a_running_strip_waits_while_its_script_is_empty \
  test_a_strip_that_never_reads_the_crew_says_it_cannot \
  test_open_is_not_stopped_by_a_recycled_pid \
  test_install_links_the_plugin_and_records_the_home \
  test_remove_stops_only_its_own_strips_and_unlinks
