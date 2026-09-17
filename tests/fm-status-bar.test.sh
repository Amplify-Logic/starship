#!/usr/bin/env bash
# Canonical Firstmate status-bar contract and adapter integration regressions.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-status-bar)
HOME_FIX="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
mkdir -p "$HOME_FIX/state"

cat > "$FAKEBIN/stat" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_STATUS_BAR_TEST_BEAT_EPOCH:-900}"
SH
chmod +x "$FAKEBIN/stat"

# The fleet fields fold bin/fm-crew-state.sh, which consults the validation
# pipeline and costs about a second per task. These cases stand a fixture in for
# it: one file per task id holding the exact canonical line that reader would
# print. Nothing here reaches a real crew, a real pane, or the pipeline.
FLEET_FIX="$TMP_ROOT/fleet"
mkdir -p "$FLEET_FIX"
# Suite-wide, so a case that launches the companion loop cannot reach the real
# reader - or the validation pipeline behind it - through the cached path.
export FM_FLEET_FIXTURE="$FLEET_FIX"
export FM_FLEET_STATE_READER="$FAKEBIN/fake-crew-state"
export FM_FLEET_STATE_NO_CACHE=1
cat > "$FAKEBIN/fake-crew-state" <<'SH'
#!/usr/bin/env bash
[ -f "$FM_FLEET_FIXTURE/$1" ] || exit 1
cat "$FM_FLEET_FIXTURE/$1"
SH
chmod +x "$FAKEBIN/fake-crew-state"

# fleet_task <id> <kind> <canonical state line>: one task record plus the state
# the canonical reader reports for it.
fleet_task() {
  fm_write_meta "$HOME_FIX/state/$1.meta" "kind=$2"
  printf '%s\n' "$3" > "$FLEET_FIX/$1"
}

reset_fleet() {
  rm -f "$HOME_FIX"/state/*.meta "$HOME_FIX"/state/*.status 2>/dev/null || true
  rm -f "$HOME_FIX"/state/.status-fleet-state* 2>/dev/null || true
  rm -f "$FLEET_FIX"/* 2>/dev/null || true
}

strip_ansi() {
  sed $'s/\033\\[[0-9;]*m//g'
}

# Herdr's border-title store counts CODEPOINTS, and `${#var}` counts bytes
# wherever LC_CTYPE is C/POSIX - including this suite's own shell. Counting
# non-continuation UTF-8 bytes is the same answer on every host, which is the
# unit the assertions below have to be in.
count_codepoints() {  # <text>
  printf '%s' "$1" | LC_ALL=C tr -d '\200-\277' | LC_ALL=C wc -c | tr -d ' '
}

render() {
  PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS=pi \
    FM_STATUS_BAR_NOW=1000 \
    FM_FLEET_FIXTURE="$FLEET_FIX" \
    FM_FLEET_STATE_READER="${FM_FLEET_STATE_READER:-$FAKEBIN/fake-crew-state}" \
    FM_FLEET_STATE_NO_CACHE="${FM_FLEET_STATE_NO_CACHE:-1}" \
    "$ROOT/bin/fm-status-bar.sh" \
      --adapter pi \
      --model "${1:-Opus}" \
      --effort "${2:-high}" \
      --context-used "${3:---}" \
      --quota-used "${4:---}" \
      --cost "${5:---}"
}

# The companion must never publish a frame the collector has not filled in yet.
# The probe is a fake `stat`, which the renderer calls while it is collecting:
# it snapshots the bytes already written to the pane at that exact moment, so a
# snapshot that ends with a bare row erase proves the row was blank on screen
# for the whole length of the collection.
test_companion_never_leaves_the_row_blank_while_collecting() {
  local out_file="$TMP_ROOT/blank-out.raw" snap_dir="$TMP_ROOT/blank-snaps"
  local count_file="$TMP_ROOT/blank-count" snap_count_file="$TMP_ROOT/blank-snap-count"
  local refreshes=3 snap snaps blanked=

  rm -rf "$snap_dir"
  mkdir -p "$snap_dir"
  : > "$out_file"
  rm -f "$count_file" "$snap_count_file"
  fm_install_fake_tmux_pane "$FAKEBIN" "$refreshes"
  # Snapshots are numbered from a counter file rather than a timestamp: BSD
  # `date` has no %N, so every probe call inside one second would otherwise
  # write the same name and leave a single collection to stand for all of them.
    # The probe fires on the supervision-beacon stat only. Every frame reads that
  # beacon exactly once, mid-collection, which is the moment this case needs to
  # observe; snapshotting on EVERY stat would instead count whatever else the
  # frame happens to stat and make the one-snapshot-per-refresh guard below a
  # statement about the renderer's internals rather than about its refreshes.
cat > "$FAKEBIN/stat" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_STATUS_BAR_TEST_SNAPDIR:-}" ] && case "$*" in *.last-watcher-beat) true ;; *) false ;; esac; then
  seq=0
  [ ! -f "$FM_STATUS_BAR_TEST_SNAPCOUNT" ] || seq=$(<"$FM_STATUS_BAR_TEST_SNAPCOUNT")
  seq=$((seq + 1))
  printf '%s\n' "$seq" > "$FM_STATUS_BAR_TEST_SNAPCOUNT"
  cp "$FM_STATUS_BAR_TEST_OUT" "$FM_STATUS_BAR_TEST_SNAPDIR/$seq.snap" 2>/dev/null
fi
printf '%s\n' "${FM_STATUS_BAR_TEST_BEAT_EPOCH:-900}"
SH
  chmod +x "$FAKEBIN/stat"
  : > "$HOME_FIX/state/.last-watcher-beat"

  # shellcheck disable=SC2094 # The probe reads the pane bytes written so far
  # from the very file this run is writing; that is the measurement, not a bug.
  PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS=kimi \
    FM_STATUS_BAR_INTERVAL=0 \
    FM_STATUS_BAR_TMUX_COUNT="$count_file" \
    FM_STATUS_BAR_TEST_SNAPDIR="$snap_dir" \
    FM_STATUS_BAR_TEST_SNAPCOUNT="$snap_count_file" \
    FM_STATUS_BAR_TEST_OUT="$out_file" \
    "$ROOT/bin/fm-status-bar.sh" \
      --adapter kimi --model kimi-code/k3 --effort -- --follow-pane %42 \
    > "$out_file"

  # One snapshot per collection, or the check is narrower than it advertises.
  snaps=$(find "$snap_dir" -name '*.snap' | wc -l | tr -d ' ')
  [ "$snaps" -eq "$refreshes" ] \
    || fail "the collection probe left $snaps snapshots for $refreshes refreshes, so the blank-frame check proved less than it claims"
  for snap in "$snap_dir"/*.snap; do
    case "$(cat "$snap")" in
      *$'\033[2K') blanked=1 ;;
    esac
  done
  [ -z "$blanked" ] \
    || fail "the companion erased the row and left it blank while it collected the next frame"
  assert_contains "$(cat "$out_file")" '⚓' "the companion stopped rendering the status row"
  # The erase is what clips a shorter frame's stale tail, so it must survive -
  # it just has to reach the pane in the same write as the frame it precedes.
  assert_contains "$(cat "$out_file")" $'\033[H\033[2K\033[1m⚓' \
    "the row erase no longer arrives together with the frame it introduces"
  rm -f "$FAKEBIN/tmux"
  pass "status bar: the companion never blanks its row while collecting a frame"
}

test_companion_publishes_every_refresh_to_the_pane() {
  local out count_file="$TMP_ROOT/repeat-count" rows

  : > "$HOME_FIX/state/.last-watcher-beat"

  # A frozen clock and a frozen fleet make all three rows byte-identical, and
  # every one of them must still be published. A settled fleet with no watcher
  # beat holds every field constant, so a row published only when it changes is
  # written once and stays clipped to the width it was written at - a companion
  # widened after that would never recover the rest of the row.
  rm -f "$count_file"
  fm_install_fake_tmux_pane "$FAKEBIN" 3
  cat > "$FAKEBIN/stat" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_STATUS_BAR_TEST_BEAT_EPOCH:-900}"
SH
  chmod +x "$FAKEBIN/stat"
  out=$(PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS=kimi \
    FM_STATUS_BAR_NOW=1000 \
    FM_STATUS_BAR_INTERVAL=0 \
    FM_STATUS_BAR_TMUX_COUNT="$count_file" \
    "$ROOT/bin/fm-status-bar.sh" \
      --adapter kimi --model kimi-code/k3 --effort -- --follow-pane %42)
  rows=$(printf '%s' "$out" | grep -o '⚓' | wc -l | tr -d ' ')
  [ "$rows" -eq 3 ] \
    || fail "three refreshes published $rows unchanged rows instead of one row each"

  # A clock that moves one second per refresh changes the supervision age, and
  # every one of those changes must reach the pane.
  rm -f "$count_file"
  fm_install_fake_tmux_pane "$FAKEBIN" 3
  cat > "$FAKEBIN/stat" <<'SH'
#!/usr/bin/env bash
epoch=900
[ ! -f "$FM_STATUS_BAR_TEST_BEAT_FILE" ] || epoch=$(<"$FM_STATUS_BAR_TEST_BEAT_FILE")
printf '%s\n' "$((epoch - 1))" > "$FM_STATUS_BAR_TEST_BEAT_FILE"
printf '%s\n' "$epoch"
SH
  chmod +x "$FAKEBIN/stat"
  rm -f "$TMP_ROOT/beat-epoch"
  out=$(PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS=kimi \
    FM_STATUS_BAR_NOW=1000 \
    FM_STATUS_BAR_INTERVAL=0 \
    FM_STATUS_BAR_TMUX_COUNT="$count_file" \
    FM_STATUS_BAR_TEST_BEAT_FILE="$TMP_ROOT/beat-epoch" \
    "$ROOT/bin/fm-status-bar.sh" \
      --adapter kimi --model kimi-code/k3 --effort -- --follow-pane %42 | strip_ansi)
  rows=$(printf '%s' "$out" | grep -o '⚓' | wc -l | tr -d ' ')
  [ "$rows" -eq 3 ] \
    || fail "three refreshes published $rows rows instead of one row each"
  assert_contains "$out" '👁 100s' "the first supervision age never reached the pane"
  assert_contains "$out" '👁 101s' "a changed supervision age never reached the pane"
  assert_contains "$out" '👁 102s' "a changed supervision age never reached the pane"
  rm -f "$FAKEBIN/tmux"
  cat > "$FAKEBIN/stat" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_STATUS_BAR_TEST_BEAT_EPOCH:-900}"
SH
  chmod +x "$FAKEBIN/stat"
  pass "status bar: the companion publishes a row on every refresh"
}

test_contract_order_and_fleet_projection() {
  local out
  reset_fleet
  fleet_task working crew 'state: working · source: pane · harness busy'
  fleet_task validating crew 'state: working · source: run-step · run running'
  fleet_task paused crew 'state: paused · source: status-log · upstream release'
  fleet_task attention scout 'state: blocked · source: status-log · missing fixture'
  fleet_task finished crew 'state: done · source: run-step · checks passed'
  fleet_task torndown crew 'state: unknown · source: none · backend target gone'
  fm_write_meta "$HOME_FIX/state/domain.meta" "kind=secondmate"
  printf 'blocked: must not count\n' > "$FLEET_FIX/domain"
  : > "$HOME_FIX/state/.last-watcher-beat"
  : > "$HOME_FIX/state/.afk"

  out=$(render Opus high 42 73 1.235 | strip_ansi)
  [ "$out" = "⚓ Opus·high │ 🧠42% ⚡73% │ 🚢1 🧪1 ⏸1 ⚠1 📋6 │ 👁 100s │ \$1.24 │ 💤AFK" ] \
    || fail "canonical fields, order, fleet counts, or formatting drifted: $out"
  pass "status bar: canonical field order and fleet projection are stable"
}

# The defect the captain photographed: twelve task records rendered as twelve
# running ships. A record whose worker is gone is still a record, and the row
# has to say so with a number that is not the ship count.
test_task_records_are_never_counted_as_running_workers() {
  local out
  reset_fleet
  fleet_task live crew 'state: working · source: pane · harness busy'
  fleet_task gone1 crew 'state: unknown · source: none · backend target gone: w8:pV'
  fleet_task gone2 crew 'state: unknown · source: none · no current-state source available'
  fleet_task gone3 scout 'state: done · source: run-step · checks passed'
  : > "$HOME_FIX/state/.last-watcher-beat"

  out=$(render Opus high -- -- -- | strip_ansi)
  assert_contains "$out" '🚢1 ' "a fleet of one live worker and three records did not report one ship"
  assert_contains "$out" '📋4' "the record count does not cover every ordinary task"
  assert_not_contains "$out" '🚢4' "task records were counted as running workers"
  pass "status bar: a task record is never counted as a running worker"
}

# A pipeline run carrying a task and a worker typing at one are both "working"
# to the canonical reader; only its SOURCE separates them, and the captain asked
# to see that difference.
test_validating_work_is_distinguished_from_a_busy_worker() {
  local out
  reset_fleet
  fleet_task typing crew 'state: working · source: pane · harness busy'
  fleet_task inpipeline crew 'state: working · source: run-step · run ci'
  fleet_task fixing crew 'state: working · source: run-step · run fixing'
  fleet_task gate crew 'state: parked · source: run-step · awaiting approval'
  : > "$HOME_FIX/state/.last-watcher-beat"

  out=$(render Opus high -- -- -- | strip_ansi)
  assert_contains "$out" '🚢1 🧪2' "validating work was folded into the busy-worker count"
  assert_contains "$out" '⚠1' "a parked validation gate is not reported as needing attention"
  pass "status bar: validating work is a separate field from a busy worker"
}

# Zero live workers is a real fleet state. It must never be what the row shows
# because the reading has not been taken yet.
test_unknown_fleet_state_shows_placeholders_and_never_zero() {
  local out
  reset_fleet
  fleet_task one crew 'state: working · source: pane · harness busy'
  fleet_task two crew 'state: working · source: pane · harness busy'
  : > "$HOME_FIX/state/.last-watcher-beat"

  # No cached reading and no reader that can answer: every live field is unknown.
  out=$(FM_FLEET_STATE_NO_CACHE=0 FM_FLEET_STATE_READER="$FAKEBIN/absent-reader" \
    render Opus high -- -- -- | strip_ansi)
  assert_contains "$out" '🚢-- 🧪-- ⏸-- ⚠--' \
    "an unread fleet does not show placeholders for every live field"
  assert_contains "$out" '📋2' "the record count is not shown while the live fields are unknown"
  assert_not_contains "$out" '🚢0' "an unread fleet was reported as zero live workers"

  # A genuine zero still renders as zero.
  reset_fleet
  fleet_task done1 crew 'state: done · source: run-step · checks passed'
  out=$(render Opus high -- -- -- | strip_ansi)
  assert_contains "$out" '🚢0 🧪0 ⏸0 ⚠0 📋1' "a genuinely idle fleet is not reported as zero"
  pass "status bar: an unread fleet shows placeholders and a genuine zero still shows zero"
}

test_threshold_colors_and_placeholders() {
  local out
  # Context-used thresholds invert the prior remaining bands: green at/under 70%,
  # yellow at 71-85% (was under 30% remaining), red at 86%+ (was under 15%).
  out=$(render Opus high 70 69 0)
  assert_contains "$out" $'\033[92m🧠70%' "70% context used is not bright green"
  assert_contains "$out" $'\033[92m⚡69%' "69% quota used is not bright green"

  out=$(render Opus high 71 70 0)
  assert_contains "$out" $'\033[93m🧠71%' "71% context used is not bright yellow"
  assert_contains "$out" $'\033[93m⚡70%' "70% quota used is not bright yellow"

  out=$(render Opus high 85 70 0)
  assert_contains "$out" $'\033[93m🧠85%' "85% context used is not bright yellow"

  out=$(render Opus high 86 90 0)
  assert_contains "$out" $'\033[91m🧠86%' "86% context used is not bright red"
  assert_contains "$out" $'\033[91m⚡90%' "90% quota used is not bright red"

  out=$(render Opus high -- -- -- | strip_ansi)
  assert_contains "$out" '🧠-- ⚡--' "unavailable provider metrics do not use canonical placeholders"
  assert_contains "$out" '$--' "unavailable session cost does not use the canonical placeholder"
  pass "status bar: threshold colors and unavailable-metric placeholders are canonical"
}

test_no_watch_is_bright_red_when_missing_or_stale() {
  local out
  rm -f "$HOME_FIX/state/.last-watcher-beat"
  out=$(render Opus high 50 10 0)
  assert_contains "$out" $'\033[91;1m👁 NO-WATCH --' "missing supervision beacon is not a bright-red NO-WATCH alert"

  : > "$HOME_FIX/state/.last-watcher-beat"
  out=$(FM_STATUS_BAR_TEST_BEAT_EPOCH=800 render Opus high 50 10 0)
  assert_contains "$out" $'\033[91;1m👁 NO-WATCH 200s' "stale supervision beacon is not a bright-red NO-WATCH alert"

  out=$(PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS=pi \
    FM_STATUS_BAR_NOW=invalid \
    "$ROOT/bin/fm-status-bar.sh" \
      --adapter pi \
      --model Opus \
      --effort high)
  assert_contains "$out" $'\033[91;1m👁 NO-WATCH --' "unreadable supervision time is not a bright-red NO-WATCH alert"
  pass "status bar: missing and stale supervision are loud NO-WATCH alerts"
}

test_claude_payload_adapter_and_primary_guard() {
  local input out
  input='{"model":{"display_name":"Claude Fable"},"effort":{"level":"high"},"context_window":{"used_percentage":35.2,"remaining_percentage":64.8},"rate_limits":{"five_hour":{"used_percentage":12.9}},"cost":{"total_cost_usd":2.345}}'
  out=$(printf '%s' "$input" | \
    PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS=claude \
    FM_STATUS_BAR_NOW=1000 \
    "$ROOT/bin/fm-status-bar.sh" --adapter claude | strip_ansi)
  assert_contains "$out" '⚓ Claude Fable·high' "Claude adapter did not normalize model and effort"
  assert_contains "$out" '🧠35% ⚡12%' "Claude adapter did not prefer context used over remaining"
  assert_contains "$out" "\$2.35" "Claude adapter did not normalize session cost"

  input='{"model":{"display_name":"Claude Fable"},"effort":{"level":"high"},"context_window":{"remaining_percentage":64.8}}'
  out=$(printf '%s' "$input" | \
    PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS=claude \
    FM_STATUS_BAR_NOW=1000 \
    "$ROOT/bin/fm-status-bar.sh" --adapter claude | strip_ansi)
  assert_contains "$out" '🧠36%' "Claude adapter did not derive context used from remaining when used is absent"

  input='{"model":{"display_name":"Bad\u0007Model"},"effort":{"level":"high"}}'
  out=$(printf '%s' "$input" | \
    PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS=claude \
    FM_STATUS_BAR_NOW=1000 \
    "$ROOT/bin/fm-status-bar.sh" --adapter claude)
  assert_not_contains "$out" $'\a' "Claude model label can inject terminal control bytes"
  assert_contains "$(printf '%s' "$out" | strip_ansi)" '⚓ BadModel·high' \
    "Claude model label was not sanitized without changing its printable text"

  out=$(printf '%s' "$input" | \
    PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS='' \
    FM_STATUS_BAR_NOW=1000 \
    "$ROOT/bin/fm-status-bar.sh" --adapter claude)
  [ -z "$out" ] || fail "Claude status bar rendered outside the guarded primary launcher"
  pass "status bar: Claude payload normalization is guarded to a primary launch"
}

test_follow_mode_exits_when_primary_pane_is_gone() {
  local out count_file="$TMP_ROOT/tmux-count"
  cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$FM_STATUS_BAR_TMUX_COUNT" ] || count=$(<"$FM_STATUS_BAR_TMUX_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$FM_STATUS_BAR_TMUX_COUNT"
if [ "$count" -eq 1 ]; then
  printf '\n'
  exit 0
fi
exit 1
SH
  chmod +x "$FAKEBIN/tmux"
  out=$(PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS=kimi \
    FM_STATUS_BAR_INTERVAL=0 \
    FM_STATUS_BAR_TMUX_COUNT="$count_file" \
    "$ROOT/bin/fm-status-bar.sh" \
      --adapter kimi \
      --model kimi-code/k3 \
      --effort -- \
      --follow-pane %42)
  assert_not_contains "$out" '⚓' "tmux companion rendered after its primary pane disappeared"
  pass "status bar: tmux companion exits when its exact primary pane is gone"
}

test_cursor_payload_adapter_and_primary_guard() {
  local input out
  input='{"model":{"id":"cursor-grok-4.6","display_name":"Cursor Grok 4.6","param_summary":"high"},"context_window":{"used_percentage":42.7,"remaining_percentage":57.3}}'
  out=$(printf '%s' "$input" | \
    PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS=cursor \
    FM_STATUS_BAR_NOW=1000 \
    "$ROOT/bin/fm-status-bar.sh" --adapter cursor | strip_ansi)
  assert_contains "$out" '⚓ Cursor Grok 4.6·high' "Cursor adapter did not read model and reasoning summary"
  assert_contains "$out" '🧠42%' "Cursor adapter did not read context used"
  # Cursor's statusLine payload carries no quota and no cost, so both must stay
  # visibly unknown rather than being invented or silently zeroed.
  assert_contains "$out" '⚡--' "Cursor adapter fabricated a provider quota it cannot observe"
  assert_contains "$out" '$--' "Cursor adapter fabricated a session cost it cannot observe"

  out=$(printf '%s' "$input" | \
    PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS='' \
    FM_STATUS_BAR_NOW=1000 \
    "$ROOT/bin/fm-status-bar.sh" --adapter cursor)
  [ -z "$out" ] || fail "Cursor status bar rendered outside the guarded primary launcher"
  pass "status bar: Cursor payload normalization is guarded and keeps unknown metrics unknown"
}

test_account_role_label_is_verified_and_compact() {
  local out
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FIX" FM_PRIMARY_HARNESS=codex \
    FM_STATUS_BAR_NOW=1000 \
    "$ROOT/bin/fm-status-bar.sh" --adapter codex --model gpt-6-astra --effort high \
      --role Plus | strip_ansi)
  assert_contains "$out" '⚓ gpt-6-astra·high [Plus]' "role label is not attached to the model identity"

  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FIX" FM_PRIMARY_HARNESS=codex \
    FM_STATUS_BAR_NOW=1000 FM_PRIMARY_ACCOUNT_ROLE=Team \
    "$ROOT/bin/fm-status-bar.sh" --adapter codex --model m --effort e | strip_ansi)
  assert_contains "$out" '[Team]' "role label is not taken from the launcher-resolved account name"

  # The native Claude, Pi and Cursor surfaces get no companion command, so the
  # label has to reach them from the account owner's own resolved global.
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FIX" FM_PRIMARY_HARNESS=codex \
    FM_STATUS_BAR_NOW=1000 FM_ACCOUNT_NAME=Max \
    "$ROOT/bin/fm-status-bar.sh" --adapter codex --model m --effort e | strip_ansi)
  assert_contains "$out" '[Max]' "role label is not taken from the account owner's FM_ACCOUNT_NAME"

  # An unknown ambient account must stay unknown, and an account IDENTIFIER
  # must never reach the row even when the environment supplies one.
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FIX" FM_PRIMARY_HARNESS=codex \
    FM_STATUS_BAR_NOW=1000 \
    "$ROOT/bin/fm-status-bar.sh" --adapter codex --model m --effort e | strip_ansi)
  assert_not_contains "$out" '[' "unknown account rendered a role label anyway"

  # Acceptance is positive - alphabetic and compact - so identifier shapes that
  # carry no punctuation at all are rejected too, and an over-long value is
  # dropped whole rather than truncated into an identifier prefix.
  for identifier in 'a@b.com' 'acct:12345' 'team/one' 'Two Words' '1048576123' \
    '550e8400-e29b-41d4-a716-446655440000' 'ABCDEFGHIJKLMNOPQRST' 'Team2'; do
    out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FIX" FM_PRIMARY_HARNESS=codex \
      FM_STATUS_BAR_NOW=1000 FM_PRIMARY_ACCOUNT_ROLE="$identifier" \
      "$ROOT/bin/fm-status-bar.sh" --adapter codex --model m --effort e | strip_ansi)
    assert_not_contains "$out" '[' "account identifier '$identifier' leaked into the status row"

    out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FIX" FM_PRIMARY_HARNESS=codex \
      FM_STATUS_BAR_NOW=1000 FM_ACCOUNT_NAME="$identifier" \
      "$ROOT/bin/fm-status-bar.sh" --adapter codex --model m --effort e | strip_ansi)
    assert_not_contains "$out" '[' "account identifier '$identifier' leaked in through FM_ACCOUNT_NAME"
  done

  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FIX" FM_PRIMARY_HARNESS=codex \
    FM_STATUS_BAR_NOW=1000 FM_PRIMARY_ACCOUNT_ROLE=ABCDEFGHIJKL \
    "$ROOT/bin/fm-status-bar.sh" --adapter codex --model m --effort e | strip_ansi)
  assert_contains "$out" '[ABCDEFGHIJKL]' "a role word at the compact width was rejected"
  pass "status bar: account role is compact, verified, and never an identifier"
}

test_herdr_companion_exits_when_primary_pane_is_gone() {
  local out count_file="$TMP_ROOT/herdr-count"
  cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$FM_STATUS_BAR_HERDR_COUNT" ] || count=$(<"$FM_STATUS_BAR_HERDR_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$FM_STATUS_BAR_HERDR_COUNT"
# The session selector must always be present, so an unscoped call can never
# resolve against another Herdr session's pane.
case " $* " in
  *" --session "*) ;;
  *) exit 1 ;;
esac
if [ "$count" -eq 1 ]; then
  printf '{"result":{"pane":{"pane_id":"w9:p9"}}}\n'
  exit 0
fi
printf '{"result":{"pane":{}}}\n'
exit 0
SH
  chmod +x "$FAKEBIN/herdr"
  out=$(PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS=codex \
    FM_STATUS_BAR_INTERVAL=0 \
    FM_STATUS_BAR_HERDR_COUNT="$count_file" \
    FM_STATUS_HERDR_SESSION=default \
    "$ROOT/bin/fm-status-bar.sh" \
      --adapter codex \
      --model gpt-6-astra \
      --effort high \
      --follow-pane w9:p9 --follow-backend herdr | strip_ansi)
  assert_contains "$out" '⚓ gpt-6-astra·high' "Herdr companion never rendered while its pane was live"
  # One render for the live read, then the pane resolves to nothing and the
  # companion must stop rather than outliving the primary it follows.
  [ "$(printf '%s' "$out" | grep -c '⚓')" -eq 1 ] \
    || fail "Herdr companion kept rendering after its exact primary pane was gone"
  rm -f "$FAKEBIN/herdr"
  pass "status bar: herdr companion is session-scoped and exits when its pane is gone"
}

test_companion_clears_the_whole_pane_once_at_startup() {
  local out count_file="$TMP_ROOT/clear-count"
  fm_install_fake_tmux_pane "$FAKEBIN" 2
  out=$(PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS=kimi \
    FM_STATUS_BAR_INTERVAL=0 \
    FM_STATUS_BAR_TMUX_COUNT="$count_file" \
    "$ROOT/bin/fm-status-bar.sh" \
      --adapter kimi --model kimi-code/k3 --effort -- --follow-pane %42)
  # Herdr clamps the split share to 0.9, so a companion is a proportional tenth
  # of the tab - two rows on a 23-row terminal, six on a 63-row one - and `pane
  # run` echoes the launch command into the pane's shell, so everything the
  # provider left below the status row is cleared whole exactly once.
  assert_contains "$out" $'\033[2J' "the companion never cleared the pane it took over"
  [ "$(printf '%s' "$out" | grep -c $'\033\\[2J')" -eq 1 ] \
    || fail "the companion repeated the full-pane clear on every refresh"
  assert_contains "$out" $'\033[H\033[2K' "the per-refresh single-row erase was dropped"
  assert_contains "$out" $'\033[?25h\033[?7h' "the companion stopped restoring terminal state on exit"
  rm -f "$FAKEBIN/tmux"
  pass "status bar: the companion clears its pane once and keeps the per-refresh erase"
}

test_companion_backend_is_restricted_to_verified_providers() {
  local out
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FIX" FM_PRIMARY_HARNESS=codex \
    FM_STATUS_BAR_NOW=1000 \
    "$ROOT/bin/fm-status-bar.sh" --adapter codex --model m --effort e \
      --follow-pane p1 --follow-backend zellij)
  [ -z "$out" ] || fail "companion ran on an unverified session provider"
  pass "status bar: companion refuses an unverified session provider"
}

test_tracked_adapter_wiring_and_cursor_boundary() {
  local status_command pi_extension
  status_command=$(jq -r '.statusLine.command // ""' "$ROOT/.claude/settings.json")
  assert_contains "$status_command" "\$CLAUDE_PROJECT_DIR" "Claude status command is not anchored to the tracked project"
  assert_contains "$status_command" 'bin/fm-status-bar.sh --adapter claude' "Claude status command does not use the canonical renderer"
  assert_not_contains "$status_command" "$HOME" "Claude status command writes or depends on the operator-global home"

  pi_extension=$(cat "$ROOT/.pi/extensions/fm-primary-status-bar.ts")
  assert_contains "$pi_extension" 'ctx.ui.setFooter' "Pi adapter does not use the installed custom-footer API"
  assert_contains "$pi_extension" 'truncateToWidth' "Pi adapter is not terminal-width safe"
  assert_contains "$pi_extension" 'bin/fm-status-bar.sh' "Pi adapter does not derive output from the canonical renderer"
  assert_not_contains "$pi_extension" 'setEditorComponent' "Pi adapter replaces native interaction controls"

  assert_grep 'fm-primary-status-bar.ts' "$ROOT/bin/fm-primary.sh" \
    "the guarded primary launcher does not verify the Pi status-bar integration"
  assert_grep 'split-window' "$ROOT/bin/fm-primary.sh" \
    "the guarded primary launcher does not provide the non-native tmux companion"
  assert_grep 'pane split' "$ROOT/bin/fm-primary.sh" \
    "the guarded primary launcher does not provide the non-native herdr companion"

  # Cursor's status line is a real native command API, so the installer writes
  # exactly one key and never touches credentials.
  assert_grep 'statusLine' "$ROOT/bin/fm-cursor-statusline.sh" \
    "the Cursor installer does not install the native statusLine key"
  assert_not_contains "$(cat "$ROOT/bin/fm-cursor-statusline.sh")" 'auth.json' \
    "the Cursor installer touches credential storage"
  assert_grep 'fm-cursor-statusline.sh' "$ROOT/docs/status-bar.md" \
    "the status-bar owner does not document the Cursor activation route"
  pass "status bar: tracked adapters preserve guarded installation across native and companion surfaces"
}

# --- Codex/Astra session metric supply -------------------------------------
#
# These cases drive bin/fm-codex-session-metrics-lib.sh directly with fixture
# rollouts and fixture provider reports. Nothing here spawns a renderer against
# a live pane, points at a live Herdr session, relies on an installed herdr, or
# signals a process: the library's pane resolution is either replaced by its
# documented rollout seam or answered by PATH stubs, so the suite can never
# reach the captain's own primary or its companion.

CODEX_FIX="$TMP_ROOT/codex"
mkdir -p "$CODEX_FIX"

# codex_token_event <input-tokens> <context-window> <limit-id> <limit-name>
#   <primary-used> <primary-minutes> <primary-resets>
# One rollout token-count line. "-" omits the rate-limit window entirely. The
# rate-limit fields are still written because a real rollout carries them: the
# point of most cases below is that they never reach the row.
codex_token_event() {
  local tok=$1 win=$2 lid=$3 lname=$4 pu=$5 pm=$6 pr=$7 primary
  primary=null
  [ "$pu" = - ] || primary="{\"used_percent\":$pu,\"window_minutes\":$pm,\"resets_at\":$pr}"
  printf '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":%s},"model_context_window":%s},"rate_limits":{"limit_id":"%s","limit_name":"%s","primary":%s,"secondary":null}}}\n' \
    "$tok" "$win" "$lid" "$lname" "$primary"
}

# codex_metrics <rollout-file> [quota-json]
# The reading as "context|quota|window", with caching off so each case is read
# fresh and no case can observe another's cached answer.
codex_metrics() {
  local quota=${2:-} state="$CODEX_FIX/state" disable=
  mkdir -p "$state"
  [ -n "$quota" ] || disable=1
  (
    # shellcheck source=bin/fm-codex-session-metrics-lib.sh
    . "$ROOT/bin/fm-codex-session-metrics-lib.sh"
    FM_CODEX_METRICS_NO_CACHE=1 \
      FM_CODEX_METRICS_NOW=1000 \
      FM_CODEX_METRICS_ROLLOUT="$1" \
      FM_CODEX_QUOTA_JSON="$quota" \
      FM_CODEX_QUOTA_DISABLE="$disable" \
      fm_codex_session_metrics fixture-pane herdr default "$state"
  ) | tr '\t' '|'
}

# codex_quota_report <scope-status> <remaining> <limiting-window-ids-json>
#   [stale] [semantics-status]
codex_quota_report() {
  local sstatus=$1 remaining=$2 windows=$3 stale=${4:-false} qs=${5:-known}
  printf '{"providers":[{"provider":"codex","state":{"stale":%s},"quotaSemantics":{"status":"%s","effectiveAvailability":[{"scope":"all_models","status":"%s","effectivePercentRemaining":%s,"limitingWindowIds":%s}]}}]}' \
    "$stale" "$qs" "$sstatus" "$remaining" "$windows"
}

# The rollout's rate_limits block is not a quota source, under any identity
# rule. The measured case is a gpt-6-astra primary whose rollout carried
# limit_id=codex_bengalfox (GPT-5.3-Codex-Spark) at 0% used while the account's
# real binding weekly window sat at 54% used: reporting that 0% would tell the
# captain there is full headroom when there is not. A name-shaped filter does
# not rescue the block either - the plain `codex` profile's own model string is
# a substring of `codex_bengalfox`, so it would match that very block - and the
# block never states which account or model allowance it describes. So quota
# comes from the account owner or it is unavailable.
test_codex_never_reads_quota_from_the_rollout() {
  local rollout="$CODEX_FIX/misattributed.jsonl" quota="$CODEX_FIX/weekly.json" out
  codex_token_event 129200 258400 codex_bengalfox GPT-5.3-Codex-Spark 0 300 99999 > "$rollout"
  codex_quota_report known 46 '["weekly"]' > "$quota"

  out=$(codex_metrics "$rollout" "$quota")
  assert_contains "$out" '|54|wk' \
    "the account's binding window did not supply the quota figure"
  assert_not_contains "$out" '|0|' \
    "another model's 0% allowance was reported as this primary's quota"

  # With no account owner to ask, the rollout's own block is still not a
  # fallback: the reading is unavailable rather than borrowed.
  out=$(codex_metrics "$rollout")
  assert_contains "$out" '|--|' \
    "the rollout's rate-limit block was used as a quota fallback"

  # An identity that looks like it belongs to the running model changes
  # nothing: the block is not read for quota at all.
  codex_token_event 129200 258400 'model:gpt_6_astra:5h' GPT-6-Astra 37 300 99999 > "$rollout"
  out=$(codex_metrics "$rollout")
  assert_contains "$out" '|--|' \
    "a model-shaped limit identity reopened the rollout as a quota source"
  assert_not_contains "$out" '|37|' \
    "a rollout rate-limit percentage reached the row"

  # And the profile whose model string is a substring of the foreign limit id
  # is the case a match rule got wrong, so it is pinned here too.
  codex_token_event 129200 258400 codex_bengalfox GPT-5.3-Codex-Spark 0 300 99999 > "$rollout"
  out=$(codex_metrics "$rollout")
  assert_contains "$out" '|--|' \
    "the codex profile trusted a foreign limit block whose id contains its model string"
  pass "status bar: the rollout's rate-limit block is never reported as this primary's quota"
}

# Context is read from the newest token event, so a compacted thread reports its
# smaller post-compaction prompt rather than its pre-compaction peak. The
# context window comes from the session's own report, so no capacity is assumed.
test_codex_context_follows_the_current_session_and_compaction() {
  local rollout="$CODEX_FIX/compaction.jsonl" out
  codex_token_event 232560 258400 codex_bengalfox Spark - - - > "$rollout"
  out=$(codex_metrics "$rollout")
  assert_contains "$out" '90|' "context did not track the session's own prompt size"

  # A later, smaller event is the current truth after compaction.
  codex_token_event 51680 258400 codex_bengalfox Spark - - - >> "$rollout"
  out=$(codex_metrics "$rollout")
  assert_contains "$out" '20|' "context kept a pre-compaction figure after compaction"
  pass "status bar: Codex context tracks the current session across compaction"
}

# The newest token event is usually a few kilobytes from the end, but mid-turn
# tool output pushes it far further back - measured on a live rollout, most
# appended bytes sit beyond a 256 KB tail. A single fixed tail therefore reads
# unavailable on exactly the long sessions this exists for, so the window
# escalates while nothing is found. Selection is on payload.type, because a
# conversation that merely mentions the event name is not an event.
test_codex_context_survives_a_buried_token_event() {
  local rollout_file="$CODEX_FIX/buried.jsonl" state="$CODEX_FIX/buried-state" out

  codex_token_event 51680 258400 codex_bengalfox Spark - - - > "$rollout_file"
  # Roughly 40 KB of later output, so the event is outside a deliberately tiny
  # first step and inside the escalated one.
  awk 'BEGIN { for (i = 0; i < 200; i++)
    printf "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"text\":\"%0200d\"}}\n", i }' \
    >> "$rollout_file"
  mkdir -p "$state"
  out=$(
    # shellcheck source=bin/fm-codex-session-metrics-lib.sh
    . "$ROOT/bin/fm-codex-session-metrics-lib.sh"
    FM_CODEX_METRICS_NO_CACHE=1 FM_CODEX_METRICS_NOW=1000 \
      FM_CODEX_QUOTA_DISABLE=1 FM_CODEX_METRICS_TAIL_BYTES=1024 \
      FM_CODEX_METRICS_ROLLOUT="$rollout_file" \
      fm_codex_session_metrics fixture-pane herdr default "$state"
  )
  assert_contains "$(printf '%s' "$out" | tr '\t' '|')" '20|' \
    "a token event beyond the first tail step was never found"

  # Conversation content that names the event is not one, and must not stand in
  # for the reading.
  printf '%s\n' '{"type":"response_item","payload":{"type":"message","text":"we changed the \"token_count\" selector"}}' \
    >> "$rollout_file"
  out=$(codex_metrics "$rollout_file")
  assert_contains "$out" '20|' \
    "a line that merely mentions the event name displaced the real reading"
  pass "status bar: Codex context escalates a bounded tail and selects real token events only"
}

# A reading that cannot be refreshed within the bounded tail keeps its last
# known value until that value ages out, because a live session's occupancy
# does not become unknown the moment its newest event scrolls past the window.
# Past the bound it goes back to unavailable - never to zero.
test_codex_context_keeps_its_last_reading_until_it_ages_out() {
  local state="$CODEX_FIX/age-state" cache_file rollout_file="$CODEX_FIX/age.jsonl" out
  mkdir -p "$state"
  cache_file="$state/.status-codex-metrics.fixture-pane"
  printf '%s\n' '{"type":"response_item","payload":{"type":"message"}}' > "$rollout_file"

  # A last known 42% taken at epoch 1000, attempted then too.
  printf '42\t1000\t1000' > "$cache_file"
  out=$(
    # shellcheck source=bin/fm-codex-session-metrics-lib.sh
    . "$ROOT/bin/fm-codex-session-metrics-lib.sh"
    FM_CODEX_METRICS_NOW=1100 FM_CODEX_QUOTA_DISABLE=1 \
      FM_CODEX_CONTEXT_MAX_AGE=900 FM_CODEX_METRICS_ROLLOUT="$rollout_file" \
      fm_codex_session_metrics fixture-pane herdr default "$state"
  )
  assert_contains "$(printf '%s' "$out" | tr '\t' '|')" '42|' \
    "a reading that could not be refreshed was dropped instead of kept"

  printf '42\t1000\t1000' > "$cache_file"
  out=$(
    # shellcheck source=bin/fm-codex-session-metrics-lib.sh
    . "$ROOT/bin/fm-codex-session-metrics-lib.sh"
    FM_CODEX_METRICS_NOW=9000 FM_CODEX_QUOTA_DISABLE=1 \
      FM_CODEX_CONTEXT_MAX_AGE=900 FM_CODEX_METRICS_ROLLOUT="$rollout_file" \
      fm_codex_session_metrics fixture-pane herdr default "$state"
  )
  assert_contains "$(printf '%s' "$out" | tr '\t' '|')" -- '--|' \
    "a reading past its age bound was still presented as current"
  assert_not_contains "$(printf '%s' "$out" | tr '\t' '|')" '0|' \
    "an aged-out reading became zero"
  rm -f "$cache_file"
  pass "status bar: an unrefreshable Codex context keeps its last reading only while it is young enough"
}

# Unavailable must never be rendered as zero, on any of the ways a reading can
# fail. Each case here would be a silently wrong "0%" if the guards were missing.
test_codex_unavailable_readings_never_become_zero() {
  local rollout="$CODEX_FIX/broken.jsonl" quota="$CODEX_FIX/broken.json" out

  # Malformed: not JSON at all, but carrying the token_count marker.
  printf '%s\n' '{"type":"event_msg","payload":{"type":"token_count"' > "$rollout"
  out=$(codex_metrics "$rollout")
  [ "$out" = '--|--|' ] || fail "a malformed token event produced '$out' instead of unavailable"

  # Absent: no token event in the rollout at all.
  printf '%s\n' '{"type":"response_item","payload":{"type":"message"}}' > "$rollout"
  out=$(codex_metrics "$rollout")
  [ "$out" = '--|--|' ] || fail "a rollout with no token event produced '$out'"

  # Absent context window: a percentage of an unknown window is meaningless.
  printf '%s\n' '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000}}}}' > "$rollout"
  out=$(codex_metrics "$rollout")
  [ "$out" = '--|--|' ] || fail "an unknown context window produced '$out'"

  codex_token_event 51680 258400 codex_bengalfox Spark - - - > "$rollout"

  # A stale provider report is refused rather than shown.
  codex_quota_report known 46 '["weekly"]' true > "$quota"
  out=$(codex_metrics "$rollout" "$quota")
  assert_contains "$out" '|--|' "a stale provider report was reported as current quota"

  # So is an unknown one, at either level.
  codex_quota_report unknown null '["weekly"]' false known > "$quota"
  out=$(codex_metrics "$rollout" "$quota")
  assert_contains "$out" '|--|' "an unknown scope status was reported as quota"
  codex_quota_report known 46 '["weekly"]' false unknown > "$quota"
  out=$(codex_metrics "$rollout" "$quota")
  assert_contains "$out" '|--|' "an unknown semantics status was reported as quota"

  # A provider that reports no binding window at all cannot be labelled.
  codex_quota_report known 46 '[]' > "$quota"
  out=$(codex_metrics "$rollout" "$quota")
  assert_contains "$out" '|--|' "a figure with no binding window was reported anyway"

  # A real zero is still a real reading and must survive all of the above.
  codex_quota_report known 100 '["weekly"]' > "$quota"
  out=$(codex_metrics "$rollout" "$quota")
  assert_contains "$out" '|0|wk' "a genuine 0% quota was suppressed as unavailable"
  pass "status bar: missing, malformed, and stale Codex readings stay unavailable rather than zero"
}

# A percentage means something different against five hours than against a week,
# so the window is part of the metric. A plan exposing only a weekly limit still
# reports a labelled figure. quota-axi names every window tied at the minimum
# remaining, so a tie is an ordinary state - an untouched account ties at 100%
# remaining, an exhausted one at 0% - and the tied figure is known either way:
# it is reported with the tied windows named, shortest first.
test_codex_quota_window_is_always_named() {
  local rollout="$CODEX_FIX/window.jsonl" quota="$CODEX_FIX/window.json" out
  codex_token_event 51680 258400 codex_bengalfox Spark - - - > "$rollout"

  codex_quota_report known 46 '["weekly"]' > "$quota"
  out=$(codex_metrics "$rollout" "$quota")
  assert_contains "$out" '|54|wk' "a weekly-only provider limit was not reported"

  codex_quota_report known 70 '["model:codex_bengalfox:5h"]' > "$quota"
  out=$(codex_metrics "$rollout" "$quota")
  assert_contains "$out" '|30|5h' "a five-hour window was not labelled as one"

  codex_quota_report known 46 '["weekly","daily"]' > "$quota"
  out=$(codex_metrics "$rollout" "$quota")
  assert_contains "$out" '|54|24h/wk' \
    "a tied figure was withheld instead of reported against every window that binds it"

  # A fully unused account ties at 100% remaining, which is a genuine 0% used.
  codex_quota_report known 100 '["five_hour","weekly"]' > "$quota"
  out=$(codex_metrics "$rollout" "$quota")
  assert_contains "$out" '|0|5h/wk' "a genuine tied 0% used was suppressed as unavailable"

  # An exhausted account ties at 0% remaining, which must not read as headroom.
  codex_quota_report known 0 '["five_hour","weekly"]' > "$quota"
  out=$(codex_metrics "$rollout" "$quota")
  assert_contains "$out" '|100|5h/wk' "a tied exhausted account was hidden behind unavailable"

  # Two ids naming the same window are one window, named once.
  codex_quota_report known 46 '["weekly","model:codex_bengalfox:7d"]' > "$quota"
  out=$(codex_metrics "$rollout" "$quota")
  assert_contains "$out" '|54|wk' "one window reached the row twice"

  # A tie too wide for the row collapses to its shortest window rather than
  # overflowing. The wider windows stay just as binding, which is why the
  # figure itself is the tied one and not the short window's own share.
  codex_quota_report known 46 '["five_hour","daily","weekly","monthly"]' > "$quota"
  out=$(codex_metrics "$rollout" "$quota")
  assert_contains "$out" '|54|5h' "a wide tie was not collapsed to its shortest binding window"

  codex_quota_report known 46 '["something-new"]' > "$quota"
  out=$(codex_metrics "$rollout" "$quota")
  assert_contains "$out" '|--|' "an unrecognized window was reported without a usable label"

  codex_quota_report known 46 '["weekly","something-new"]' > "$quota"
  out=$(codex_metrics "$rollout" "$quota")
  assert_contains "$out" '|--|' "a tie with an unnameable window was labelled with the half it could name"
  pass "status bar: a Codex quota figure is reported only with its actual windows named"
}

# The session binding is an open file descriptor, not a newest-file guess. When
# the followed pane resolves to no Codex process, or to processes holding more
# than one rollout, there is no safe choice and the row must say so rather than
# borrow a sibling session's context.
test_codex_never_borrows_a_sibling_session() {
  local state="$CODEX_FIX/sibling-state" out lsof_bin="$CODEX_FIX/lsofbin"
  mkdir -p "$state" "$lsof_bin"

  # A stub herdr, so the case answers from the fixture and never reaches an
  # installed CLI or a live session.
  cat > "$lsof_bin/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"other-pane","foreground_processes":[{"name":"codex","pid":4242}]}}}'
SH
  chmod +x "$lsof_bin/herdr"

  # An answer about a different pane is not an answer about this one.
  out=$(
    # shellcheck source=bin/fm-codex-session-metrics-lib.sh
    . "$ROOT/bin/fm-codex-session-metrics-lib.sh"
    PATH="$lsof_bin:$PATH" _fm_codex_pane_pids fixture-pane herdr default
  )
  [ -z "$out" ] \
    || fail "a process-info answer about another pane resolved to pid '$out'"

  # No Codex process behind the pane: nothing to bind to.
  out=$(
    # shellcheck source=bin/fm-codex-session-metrics-lib.sh
    . "$ROOT/bin/fm-codex-session-metrics-lib.sh"
    FM_CODEX_METRICS_NO_CACHE=1 FM_CODEX_METRICS_NOW=1000 \
      FM_CODEX_QUOTA_DISABLE=1 PATH="$lsof_bin:$PATH" \
      fm_codex_session_metrics fixture-pane herdr default "$state"
  )
  [ "$out" = "$(printf '%s\t%s\t' -- --)" ] \
    || fail "an unresolvable pane produced a reading anyway: '$out'"

  # Two rollouts held open at once is ambiguous, so it is refused outright
  # rather than resolved by picking one.
  cat > "$lsof_bin/lsof" <<'SH'
#!/usr/bin/env bash
printf 'n/tmp/sessions/2026/09/09/rollout-a.jsonl\n'
printf 'n/tmp/sessions/2026/09/10/rollout-b.jsonl\n'
SH
  chmod +x "$lsof_bin/lsof"
  out=$(
    # shellcheck source=bin/fm-codex-session-metrics-lib.sh
    . "$ROOT/bin/fm-codex-session-metrics-lib.sh"
    PATH="$lsof_bin:$PATH" _fm_codex_rollout_for_pids 4242 && printf 'RESOLVED'
  )
  [ -z "$out" ] || fail "two open rollouts resolved to '$out' instead of refusing"

  # Exactly one is the only resolvable case.
  cat > "$lsof_bin/lsof" <<'SH'
#!/usr/bin/env bash
printf 'n/tmp/sessions/2026/09/09/rollout-a.jsonl\n'
SH
  chmod +x "$lsof_bin/lsof"
  out=$(
    # shellcheck source=bin/fm-codex-session-metrics-lib.sh
    . "$ROOT/bin/fm-codex-session-metrics-lib.sh"
    PATH="$lsof_bin:$PATH" _fm_codex_rollout_for_pids 4242
  )
  [ "$out" = /tmp/sessions/2026/09/09/rollout-a.jsonl ] \
    || fail "a single open rollout did not resolve, got '$out'"
  pass "status bar: Codex context binds to one open session and never borrows a sibling"
}

# A tmux pane reports its own process, which is the login shell: the runtime is
# a descendant, and a launcher shim, a treehouse subshell and the runtime itself
# can each add a level. The descent has to reach it, and it has to hand lsof
# only processes positively identified as Codex - an unrelated descendant
# holding a rollout open would otherwise turn a resolvable pane into the
# two-rollout refusal.
test_codex_tmux_pane_resolves_a_shimmed_primary() {
  local bin="$CODEX_FIX/tmuxbin" out
  mkdir -p "$bin"
  cat > "$bin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 1000
SH
  cat > "$bin/pgrep" <<'SH'
#!/usr/bin/env bash
case "${2:-}" in
  1000) printf '%s\n' 1001 ;;
  1001) printf '%s\n' 1002 ;;
  1002) printf '%s\n' 1003 ;;
  1003) printf '%s\n%s\n' 1004 1005 ;;
esac
SH
  cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
case "${*}" in
  *1004*) printf '%s\n' /opt/codex/bin/codex ;;
  *1005*) printf '%s\n' /opt/codex/bin/codex-code-mode-host ;;
  *) printf '%s\n' /bin/bash ;;
esac
SH
  chmod +x "$bin/tmux" "$bin/pgrep" "$bin/ps"

  out=$(
    # shellcheck source=bin/fm-codex-session-metrics-lib.sh
    . "$ROOT/bin/fm-codex-session-metrics-lib.sh"
    PATH="$bin:$PATH" _fm_codex_pane_pids %42 tmux ''
  )
  [ "$out" = 1004 ] \
    || fail "the tmux descent resolved '$out' instead of the shimmed Codex process alone"
  pass "status bar: a tmux pane resolves its Codex primary through a launcher shim and nothing else"
}

# PR117's property is that the companion computes a whole frame before it
# erases its row, so nothing the frame needs may be allowed to stall the
# collection. The provider read is a subprocess and is the one thing that
# could, so a cache miss starts it detached and renders the placeholder: the
# first frame carries the session's own context and a dim quota rather than an
# empty pane. The stub here would take four seconds if a refresh waited on it,
# and it exits on its own - nothing is signalled, so no pattern can reach a
# live companion.
test_codex_provider_miss_renders_a_row_instead_of_waiting() {
  local bin="$CODEX_FIX/slowbin" state="$CODEX_FIX/slow-state" out elapsed
  local rollout_file="$CODEX_FIX/slow.jsonl" count_file="$TMP_ROOT/codex-slow-count"
  mkdir -p "$bin" "$state"
  rm -f "$state"/.status-codex-quota.* "$state"/.status-codex-metrics.*
  cat > "$bin/quota-axi" <<'SH'
#!/usr/bin/env bash
sleep 4
printf '%s' '{"providers":[]}'
SH
  chmod +x "$bin/quota-axi"
  codex_token_event 51680 258400 codex_bengalfox Spark 0 300 99999 > "$rollout_file"

  rm -f "$count_file"
  fm_install_fake_tmux_pane "$FAKEBIN" 1
  elapsed=$SECONDS
  out=$(PATH="$bin:$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS=codex \
    FM_STATUS_BAR_NOW=1000 \
    FM_STATUS_BAR_INTERVAL=0 \
    FM_STATUS_BAR_TMUX_COUNT="$count_file" \
    FM_CODEX_METRICS_ROLLOUT="$rollout_file" \
    "$ROOT/bin/fm-status-bar.sh" \
      --adapter codex --model gpt-6-astra --effort high --follow-pane %42 \
    | strip_ansi)
  elapsed=$((SECONDS - elapsed))
  [ "$elapsed" -lt 3 ] \
    || fail "a provider cache miss stalled the refresh for ${elapsed}s instead of deferring the read"
  assert_contains "$out" '🧠20%' "a provider cache miss cost the row its context figure"
  assert_contains "$out" '⚡--' "a provider cache miss did not render the unavailable placeholder"
  rm -f "$FAKEBIN/tmux"
  pass "status bar: a Codex provider cache miss renders a complete row instead of waiting on the read"
}

# The window token has to reach the rendered row, and it must not leak into the
# adapters whose payloads carry no window - Claude, Pi and Cursor keep the bare
# percentage their contracts already specify.
test_quota_window_renders_only_where_a_window_is_known() {
  local out rollout="$CODEX_FIX/row.jsonl" quota="$CODEX_FIX/row.json"
  local count_file="$TMP_ROOT/codex-row-count"

  out=$(render Opus high 40 55 | strip_ansi)
  assert_contains "$out" '⚡55%' "the Pi row lost its quota percentage"
  assert_not_contains "$out" '⚡55%wk' "a window label was invented for an adapter with no window"

  out=$(printf '%s' '{"model":{"display_name":"Claude"},"context_window":{"used_percentage":10},"rate_limits":{"five_hour":{"used_percentage":22}}}' |
    PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FIX" FM_PRIMARY_HARNESS=claude \
      FM_STATUS_BAR_NOW=1000 "$ROOT/bin/fm-status-bar.sh" --adapter claude | strip_ansi)
  assert_contains "$out" '⚡22%' "the Claude quota field changed shape"
  assert_not_contains "$out" '⚡22%5h' "a window label was appended to the Claude contract"

  # The Codex companion's own row, end to end through the renderer, from a
  # fixture rollout and a fixture provider report. The tied label has to
  # survive the row's own sanitizer, which is the boundary this pins.
  codex_token_event 51680 258400 codex_bengalfox Spark 0 300 99999 > "$rollout"
  codex_quota_report known 46 '["weekly","daily"]' > "$quota"
  rm -f "$count_file"
  fm_install_fake_tmux_pane "$FAKEBIN" 1
  out=$(PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS=codex \
    FM_STATUS_BAR_NOW=1000 \
    FM_STATUS_BAR_INTERVAL=0 \
    FM_STATUS_BAR_TMUX_COUNT="$count_file" \
    FM_CODEX_METRICS_NO_CACHE=1 \
    FM_CODEX_METRICS_NOW=1000 \
    FM_CODEX_METRICS_ROLLOUT="$rollout" \
    FM_CODEX_QUOTA_JSON="$quota" \
    "$ROOT/bin/fm-status-bar.sh" \
      --adapter codex --model gpt-6-astra --effort high --follow-pane %42 | strip_ansi)
  assert_contains "$out" '🧠20%' "the Codex companion did not render its session's context"
  assert_contains "$out" '⚡54%24h/wk' "the tied window label did not reach the Codex row"
  assert_not_contains "$out" '⚡0%' "the rollout's foreign rate-limit block reached the row"
  rm -f "$FAKEBIN/tmux"
  pass "status bar: the quota window is rendered only by adapters that actually know one"
}

test_chrome_mode_publishes_the_border_row_and_keeps_the_pane_fallback() {
  local out log="$TMP_ROOT/chrome-log" count_file="$TMP_ROOT/chrome-count"
  : > "$log"
  cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_CHROME_LOG"
case " $* " in
  *" --session "*) ;;
  *) exit 1 ;;
esac
for arg in "$@"; do
  case "$arg" in
    pane) ;;
  esac
done
case "$*" in
  *"pane get"*)
    count=0
    [ ! -f "$FM_CHROME_COUNT" ] || count=$(<"$FM_CHROME_COUNT")
    count=$((count + 1))
    printf '%s\n' "$count" > "$FM_CHROME_COUNT"
    # Live for two refreshes, then the primary is gone and the loop must end.
    if [ "$count" -le 2 ]; then
      printf '{"result":{"pane":{"pane_id":"w9:p9"}}}\n'
    else
      printf '{"result":{"pane":{}}}\n'
    fi
    ;;
  *"pane layout"*) printf '{"result":{"layout":{"panes":[{},{}]}}}\n' ;;
  *) printf '{}\n' ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN/herdr"
  out=$(PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS=codex \
    FM_STATUS_BAR_INTERVAL=0 \
    FM_CHROME_LOG="$log" \
    FM_CHROME_COUNT="$count_file" \
    FM_STATUS_HERDR_SESSION=default \
    "$ROOT/bin/fm-status-bar.sh" \
      --adapter codex --model gpt-6-astra --effort high \
      --follow-pane w9:p9 --follow-backend herdr \
      --chrome-pane w9:p1 --chrome-role FM | strip_ansi)

  # The in-pane row is the fallback and must keep being drawn, unchanged.
  assert_contains "$out" '⚓ gpt-6-astra·high' "chrome mode stopped drawing the in-pane fallback row"

  # The border row is published to the PRIMARY pane, under its own source, with
  # a ttl so a dead renderer stops asserting a stale row.
  assert_contains "$(cat "$log")" 'pane report-metadata w9:p1' \
    "chrome mode never published the row to the primary pane's border"
  assert_contains "$(cat "$log")" '--source firstmate-primary-status-v1' \
    "chrome mode must not publish under the launcher's own metadata source, which would wipe its supervision labels"
  assert_contains "$(cat "$log")" '--ttl-ms' \
    "chrome mode published a border row with no expiry"
  # The role marker leads the row, so the guarded primary identity survives.
  assert_contains "$(cat "$log")" 'FM │ ⚓ gpt-6-astra·high' \
    "chrome mode dropped the visible role marker from the border row"
  # A border title cannot carry styling, so the published row is plain.
  grep -q -- $'--title FM \033' "$log" \
    && fail "chrome mode published ANSI escapes into the border title"

  rm -f "$FAKEBIN/herdr"
  pass "status bar: chrome mode publishes the border row and keeps the in-pane fallback"
}

test_chrome_mode_only_releases_zoom_and_never_reapplies_it() {
  local out log="$TMP_ROOT/zoom-log" count_file="$TMP_ROOT/zoom-count"
  : > "$log"
  cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_CHROME_LOG"
case "$*" in
  *"pane get"*)
    count=0
    [ ! -f "$FM_CHROME_COUNT" ] || count=$(<"$FM_CHROME_COUNT")
    count=$((count + 1))
    printf '%s\n' "$count" > "$FM_CHROME_COUNT"
    if [ "$count" -le 12 ]; then
      printf '{"result":{"pane":{"pane_id":"w9:p9"}}}\n'
    else
      printf '{"result":{"pane":{}}}\n'
    fi
    ;;
  # A third pane has appeared in the tab, so the reclaimed rows must be given
  # back rather than hide a co-tenant pane's live work.
  *"pane layout"*) printf '{"result":{"layout":{"panes":[{},{},{}]}}}\n' ;;
  *) printf '{}\n' ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN/herdr"
  out=$(PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS=codex \
    FM_STATUS_BAR_INTERVAL=0 \
    FM_STATUS_CHROME_ZOOM_EVERY=1 \
    FM_CHROME_LOG="$log" \
    FM_CHROME_COUNT="$count_file" \
    FM_STATUS_HERDR_SESSION=default \
    "$ROOT/bin/fm-status-bar.sh" \
      --adapter codex --model gpt-6-astra --effort high \
      --follow-pane w9:p9 --follow-backend herdr \
      --chrome-pane w9:p1 --chrome-role FM --chrome-zoomed | strip_ansi)

  assert_contains "$(cat "$log")" 'pane zoom w9:p1 --off' \
    "chrome mode never released the zoom after a third pane appeared"
  # Releasing is one-way: the renderer must never zoom, or a deliberate unzoom
  # by the captain would be fought on every refresh.
  grep -q -- '--on' "$log" && fail "chrome mode re-applied the zoom; only bin/fm-primary.sh may zoom, and only once"
  # And once released it stops asking, rather than reading the layout forever.
  [ "$(grep -c 'pane zoom' "$log")" -eq 1 ] \
    || fail "chrome mode released the zoom more than once instead of standing down"

  rm -f "$FAKEBIN/herdr"
  pass "status bar: chrome mode only ever releases the zoom, once, and never re-applies it"
}

test_chrome_mode_never_releases_a_zoom_the_launcher_did_not_apply() {
  local log="$TMP_ROOT/unowned-zoom-log" count_file="$TMP_ROOT/unowned-zoom-count"
  : > "$log"
  cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_CHROME_LOG"
case "$*" in
  *"pane get"*)
    count=0
    [ ! -f "$FM_CHROME_COUNT" ] || count=$(<"$FM_CHROME_COUNT")
    count=$((count + 1))
    printf '%s\n' "$count" > "$FM_CHROME_COUNT"
    if [ "$count" -le 6 ]; then
      printf '{"result":{"pane":{"pane_id":"w9:p9"}}}\n'
    else
      printf '{"result":{"pane":{}}}\n'
    fi
    ;;
  # A crowded tab, which is exactly when the launcher WITHHOLDS the zoom: it
  # still hands over --chrome-pane, but never --chrome-zoomed.
  *"pane layout"*) printf '{"result":{"layout":{"panes":[{},{},{}]}}}\n' ;;
  *) printf '{}\n' ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN/herdr"
  PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS=codex \
    FM_STATUS_BAR_INTERVAL=0 \
    FM_STATUS_CHROME_ZOOM_EVERY=1 \
    FM_CHROME_LOG="$log" \
    FM_CHROME_COUNT="$count_file" \
    FM_STATUS_HERDR_SESSION=default \
    "$ROOT/bin/fm-status-bar.sh" \
      --adapter codex --model gpt-6-astra --effort high \
      --follow-pane w9:p9 --follow-backend herdr \
      --chrome-pane w9:p1 --chrome-role FM >/dev/null

  # Releasing is OWNED, not assumed: without the launcher's signal this zoom
  # belongs to someone else, so it must never be turned off here.
  assert_not_contains "$(cat "$log")" 'pane zoom' \
    "the renderer released a zoom the launcher never applied"
  # And the watch is not even armed, so it costs no layout read per refresh.
  assert_not_contains "$(cat "$log")" 'pane layout' \
    "the renderer polled the layout for a zoom it does not own"
  # The border row is still published; only the release watch is withheld.
  assert_contains "$(cat "$log")" 'pane report-metadata w9:p1' \
    "the border row must still be published when the launcher withheld the zoom"

  rm -f "$FAKEBIN/herdr"
  pass "status bar: the renderer only releases a zoom the launcher reported applying"
}

test_chrome_clip_measures_codepoints_not_bytes() {
  local log="$TMP_ROOT/locale-clip-log" count_file="$TMP_ROOT/locale-clip-count" title
  : > "$log"
  cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_CHROME_LOG"
case "$*" in
  *"pane get"*)
    count=0
    [ ! -f "$FM_CHROME_COUNT" ] || count=$(<"$FM_CHROME_COUNT")
    count=$((count + 1))
    printf '%s\n' "$count" > "$FM_CHROME_COUNT"
    if [ "$count" -le 1 ]; then
      printf '{"result":{"pane":{"pane_id":"w9:p9"}}}\n'
    else
      printf '{"result":{"pane":{}}}\n'
    fi
    ;;
  *"pane layout"*) printf '{"result":{"layout":{"panes":[{},{}]}}}\n' ;;
  *) printf '{}\n' ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN/herdr"
  # The store counts CODEPOINTS. This row is emoji-heavy, so its byte length
  # runs well past 80 while its codepoint length fits comfortably - and neither
  # the herdr server nor the shell it spawns the companion in is guaranteed to
  # carry a UTF-8 locale. Measuring bytes here would throw away whole fields
  # from a row that fits, so the run is deliberately made under LC_ALL=C.
  LC_ALL=C PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS=codex \
    FM_STATUS_BAR_INTERVAL=0 \
    FM_STATUS_BAR_NOW=1000 \
    FM_CHROME_LOG="$log" \
    FM_CHROME_COUNT="$count_file" \
    FM_STATUS_HERDR_SESSION=default \
    "$ROOT/bin/fm-status-bar.sh" \
      --adapter codex --model gpt-6-astra --effort high \
      --follow-pane w9:p9 --follow-backend herdr \
      --chrome-pane w9:p1 --chrome-role FM >/dev/null

  title=$(sed -n 's/.*--title \(.*\) --ttl-ms.*/\1/p' "$log" | tail -1)
  [ -n "$title" ] || fail "chrome mode published no border title to inspect"
  case "$title" in
    *'…') fail "a row that fits the 80-codepoint store was clipped by byte count: $title" ;;
  esac
  # The row this run produces is well inside the store in codepoints and well
  # past it in bytes, which is exactly the case a byte count gets wrong.
  [ "$(count_codepoints "$title")" -le 80 ] \
    || fail "the locale probe row is not actually within the 80-codepoint store"
  [ "${#title}" -gt 80 ] || [ "$(printf '%s' "$title" | LC_ALL=C wc -c | tr -d ' ')" -gt 80 ] \
    || fail "the locale probe row is not long enough in BYTES to distinguish the two measurements"
  # Every canonical field survives, the rightmost one included.
  assert_contains "$title" '💤' \
    "byte-length measurement dropped the trailing fields from a row that fits"

  rm -f "$FAKEBIN/herdr"
  pass "status bar: the border row is measured in codepoints regardless of the ambient locale"
}

test_chrome_row_is_clipped_visibly_for_the_border_title_store() {
  local log="$TMP_ROOT/clip-log" count_file="$TMP_ROOT/clip-count" title codepoints
  : > "$log"
  cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_CHROME_LOG"
case "$*" in
  *"pane get"*)
    count=0
    [ ! -f "$FM_CHROME_COUNT" ] || count=$(<"$FM_CHROME_COUNT")
    count=$((count + 1))
    printf '%s\n' "$count" > "$FM_CHROME_COUNT"
    if [ "$count" -le 1 ]; then
      printf '{"result":{"pane":{"pane_id":"w9:p9"}}}\n'
    else
      printf '{"result":{"pane":{}}}\n'
    fi
    ;;
  *"pane layout"*) printf '{"result":{"layout":{"panes":[{},{}]}}}\n' ;;
  *) printf '{}\n' ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN/herdr"
  # Herdr stores a border title clipped to 80 codepoints with no marker of its
  # own, so a row that would overflow has to lose whole fields visibly first.
  PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS=codex \
    FM_STATUS_BAR_INTERVAL=0 \
    FM_CHROME_LOG="$log" \
    FM_CHROME_COUNT="$count_file" \
    FM_STATUS_HERDR_SESSION=default \
    "$ROOT/bin/fm-status-bar.sh" \
      --adapter codex \
      --model a-deliberately-very-long-model-identifier-for-clipping \
      --effort xhigh \
      --follow-pane w9:p9 --follow-backend herdr \
      --chrome-pane w9:p1 --chrome-role FM >/dev/null

  title=$(sed -n 's/.*--title \(.*\) --ttl-ms.*/\1/p' "$log" | tail -1)
  [ -n "$title" ] || fail "chrome mode published no border title to inspect"
  codepoints=$(count_codepoints "$title")
  [ "$codepoints" -le 80 ] \
    || fail "the published border row exceeds Herdr's 80-codepoint store, which would clip it silently: $codepoints"
  case "$title" in
    *'…') ;;
    *) fail "an over-long border row was clipped without a visible marker: $title" ;;
  esac
  # The role marker leads the row precisely so a clip can never reach it.
  case "$title" in
    'FM │ ⚓ '*) ;;
    *) fail "clipping reached the role marker or the anchor, which must always survive: $title" ;;
  esac

  rm -f "$FAKEBIN/herdr"
  pass "status bar: an over-long border row loses whole fields visibly and keeps its role marker"
}

test_contract_order_and_fleet_projection
test_task_records_are_never_counted_as_running_workers
test_validating_work_is_distinguished_from_a_busy_worker
test_unknown_fleet_state_shows_placeholders_and_never_zero
test_threshold_colors_and_placeholders
test_no_watch_is_bright_red_when_missing_or_stale
test_claude_payload_adapter_and_primary_guard
test_follow_mode_exits_when_primary_pane_is_gone
test_cursor_payload_adapter_and_primary_guard
test_account_role_label_is_verified_and_compact
test_herdr_companion_exits_when_primary_pane_is_gone
test_companion_clears_the_whole_pane_once_at_startup
test_companion_never_leaves_the_row_blank_while_collecting
test_companion_publishes_every_refresh_to_the_pane
test_companion_backend_is_restricted_to_verified_providers
test_tracked_adapter_wiring_and_cursor_boundary
test_codex_never_reads_quota_from_the_rollout
test_codex_context_follows_the_current_session_and_compaction
test_codex_context_survives_a_buried_token_event
test_codex_context_keeps_its_last_reading_until_it_ages_out
test_codex_unavailable_readings_never_become_zero
test_codex_quota_window_is_always_named
test_codex_never_borrows_a_sibling_session
test_codex_tmux_pane_resolves_a_shimmed_primary
test_codex_provider_miss_renders_a_row_instead_of_waiting
test_quota_window_renders_only_where_a_window_is_known
test_chrome_mode_publishes_the_border_row_and_keeps_the_pane_fallback
test_chrome_mode_only_releases_zoom_and_never_reapplies_it
test_chrome_mode_never_releases_a_zoom_the_launcher_did_not_apply
test_chrome_row_is_clipped_visibly_for_the_border_title_store
test_chrome_clip_measures_codepoints_not_bytes
