#!/usr/bin/env bash
# Behavior tests for the launchd-backed supervision-outage sentinel.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SENTINEL="$ROOT/bin/fm-supervision-sentinel.sh"
TMP_ROOT=$(fm_test_tmproot fm-supervision-sentinel)

# Exact-service teardown for the opt-in real-launchd smoke below. Registered here
# rather than inside that test so a `fail` anywhere still retires the one service
# it may have bootstrapped, and never touches any other launchd label.
FM_SENTINEL_SMOKE_SERVICE=

fm_sentinel_bootout_smoke_service() {
  local service=$1 i=0
  /bin/launchctl bootout "$service" >/dev/null 2>&1 || true
  while [ "$i" -lt 100 ] && /bin/launchctl print "$service" >/dev/null 2>&1; do
    sleep 0.05
    i=$((i + 1))
  done
  ! /bin/launchctl print "$service" >/dev/null 2>&1
}

fm_sentinel_suite_teardown() {
  local rc=$?
  if [ -n "$FM_SENTINEL_SMOKE_SERVICE" ]; then
    if fm_sentinel_bootout_smoke_service "$FM_SENTINEL_SMOKE_SERVICE"; then
      FM_SENTINEL_SMOKE_SERVICE=
    else
      printf 'not ok - real-launchd smoke left %s loaded; remove it with: launchctl bootout %s\n' \
        "$FM_SENTINEL_SMOKE_SERVICE" "$FM_SENTINEL_SMOKE_SERVICE" >&2
      rc=1
    fi
  fi
  fm_test_cleanup
  exit "$rc"
}
trap fm_sentinel_suite_teardown EXIT

make_primary() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state" "$dir/config"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
}

# The service identity the sentinel derives for <home>, recomputed independently
# from the documented SHA-256 of the canonical home and state paths.
fm_sentinel_expected_service() { # <home> [domain]
  local home=$1 domain=${2:-} hash
  home=$(cd "$home" && pwd -P) || return 1
  [ -n "$domain" ] || domain="gui/$(id -u)"
  hash=$(printf '%s\t%s' "$home" "$home/state" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}') || return 1
  printf '%s/works.earendil.firstmate.supervision-sentinel-v1.%s\n' "$domain" "$hash"
}

make_recorder() {
  local path=$1 log=$2
  cat > "$path" <<SH
#!/usr/bin/env bash
printf '%s\\t%s\\n' "\$1" "\$2" >> "$log"
SH
  chmod +x "$path"
}

run_check() {
  local home=$1 recorder=$2
  FM_SUPERVISION_SENTINEL_MODE=auto \
    FM_ROOT_OVERRIDE="$home" \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_WEDGE_ALARM_CHANNEL=osascript \
    FM_WEDGE_ALARM_EXEC="$recorder" \
    "$SENTINEL" scheduled-check
}

run_mode() { # <home> <recorder> <mode>
  local home=$1 recorder=$2 mode=$3
  FM_SUPERVISION_SENTINEL_MODE=auto \
    FM_ROOT_OVERRIDE="$home" \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_WEDGE_ALARM_CHANNEL=osascript \
    FM_WEDGE_ALARM_EXEC="$recorder" \
    "$SENTINEL" "$mode"
}

install_stale_watcher_fixture() { # <home> <holder-pid> <watcher-path>
  local home=$1 holder=$2 watcher=$3 identity
  identity=$(FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$holder") || return 1
  mkdir -p "$home/state/.watch.lock"
  printf '%s\n' "$holder" > "$home/state/.watch.lock/pid"
  printf '%s\n' "$home" > "$home/state/.watch.lock/fm-home"
  printf '%s\n' "$watcher" > "$home/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$home/state/.watch.lock/pid-identity"
}

test_stale_beacon_alert_is_loud_deduplicated_backed_off_and_rearmed() {
  local home="$TMP_ROOT/check" recorder="$TMP_ROOT/record-alert" log="$TMP_ROOT/alerts.log" holder i text marker delivered next
  make_primary "$home"
  make_recorder "$recorder" "$log"
  for i in 1 2 3 4 5 6; do
    printf 'project=test\n' > "$home/state/task-$i.meta"
  done
  sleep 60 &
  holder=$!
  install_stale_watcher_fixture "$home" "$holder" "$ROOT/bin/fm-watch.sh" || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "could not identify the stale-beacon watcher fixture"
  }
  touch -t 202001010000 "$home/state/.last-watcher-beat"
  marker="$home/state/.supervision-outage-alarm"

  run_check "$home" "$recorder"
  [ -s "$marker" ] || fail "stale watcher check did not write its durable outage marker"
  [ "$(wc -l < "$log" | tr -d '[:space:]')" -eq 1 ] || fail "first outage check did not emit exactly one active alert"
  text=$(cat "$log")
  assert_contains "$text" $'osascript\tSUPERVISION DOWN: 6 task(s) in flight' "active alert did not lead with an unambiguous outage and task count"
  assert_contains "$text" "last watcher beat:" "active alert omitted the outage age evidence"
  assert_contains "$text" "grace 300s" "active alert omitted the configured grace"
  assert_contains "$text" "No automatic restart was attempted" "active alert did not state the conservative recovery result"
  assert_contains "$(cat "$marker")" 'delivery_count=1' "initial alert did not record the first successful delivery"
  delivered=$(awk -F= '$1 == "delivered_at" { print $2 }' "$marker")
  next=$(awk -F= '$1 == "next_alert_at" { print $2 }' "$marker")
  [ "$((next - delivered))" -eq 300 ] || fail "first repeat delay was not five minutes"

  run_check "$home" "$recorder"
  [ "$(wc -l < "$log" | tr -d '[:space:]')" -eq 1 ] || fail "one continuous outage emitted a duplicate alert inside its backoff window"

  awk -F= '$1 == "next_alert_at" { print "next_alert_at=0"; next } { print }' "$marker" > "$marker.next"
  mv "$marker.next" "$marker"
  run_check "$home" "$recorder"
  [ "$(wc -l < "$log" | tr -d '[:space:]')" -eq 2 ] || fail "due continuous-outage reminder was not delivered"
  assert_contains "$(cat "$marker")" 'delivery_count=2' "repeat alert did not advance its delivery count"
  delivered=$(awk -F= '$1 == "delivered_at" { print $2 }' "$marker")
  next=$(awk -F= '$1 == "next_alert_at" { print $2 }' "$marker")
  [ "$((next - delivered))" -eq 600 ] || fail "second repeat did not exponentially back off to ten minutes"

  # Flapping outage: the watcher was re-armed and reaped again between two host
  # checks, so the beacon evidence moved. That is a new episode and must alert
  # now instead of inheriting the backed-off schedule of the previous one.
  touch -t 202001020000 "$home/state/.last-watcher-beat"
  run_check "$home" "$recorder"
  [ "$(wc -l < "$log" | tr -d '[:space:]')" -eq 3 ] || fail "a re-reaped watcher stayed silent under the previous episode's backoff"
  assert_contains "$(cat "$marker")" 'delivery_count=1' "changed outage evidence did not restart the repeat schedule"
  delivered=$(awk -F= '$1 == "delivered_at" { print $2 }' "$marker")
  next=$(awk -F= '$1 == "next_alert_at" { print $2 }' "$marker")
  [ "$((next - delivered))" -eq 300 ] || fail "new outage episode did not reset the backoff to five minutes"

  rm -f "$home/state/task-"*.meta
  run_check "$home" "$recorder"
  [ ! -e "$marker" ] || fail "healthy/idle transition did not clear the outage episode marker"
  printf 'project=test\n' > "$home/state/task-new.meta"
  run_check "$home" "$recorder"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$(wc -l < "$log" | tr -d '[:space:]')" -eq 4 ] || fail "a later outage episode did not re-arm the active alert"
  pass "supervision sentinel: stale beacon alert deduplicates, backs off, resets on a new episode, and re-arms"
}

test_guard_note_outage_records_evidence_without_notifying() {
  local home="$TMP_ROOT/note" recorder="$TMP_ROOT/record-note" log="$TMP_ROOT/note-alerts.log" marker
  make_primary "$home"
  make_recorder "$recorder" "$log"
  printf 'project=test\n' > "$home/state/task.meta"
  touch -t 202001010000 "$home/state/.last-watcher-beat"
  marker="$home/state/.supervision-outage-alarm"

  FM_SUPERVISION_SENTINEL_MODE=auto \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_WEDGE_ALARM_CHANNEL=osascript FM_WEDGE_ALARM_EXEC="$recorder" \
    "$SENTINEL" note-outage || fail "marker-only outage note failed"
  [ ! -e "$log" ] || fail "in-harness note-outage crossed the active-channel boundary: $(cat "$log")"
  [ -s "$marker" ] || fail "note-outage did not record the durable outage evidence"
  assert_contains "$(cat "$marker")" 'SUPERVISION DOWN: 1 task(s) in flight' "note-outage marker omitted the outage summary"
  assert_contains "$(cat "$marker")" 'delivery=pending' "note-outage claimed a delivery it never attempted"
  assert_contains "$(cat "$marker")" 'attempt_at=0' "note-outage left a delivery lease the host check must wait out"
  [ ! -e "$home/state/.supervision-sentinel-last-check" ] || fail "note-outage forged the launchd liveness proof"

  run_check "$home" "$recorder"
  [ "$(wc -l < "$log" | tr -d '[:space:]')" -eq 1 ] || fail "the scheduled check did not immediately deliver a noted outage"
  assert_contains "$(cat "$marker")" 'delivery=sent' "delivered alert did not commit its delivery state"

  # A noted outage must never clobber an already-delivered episode's backoff.
  FM_SUPERVISION_SENTINEL_MODE=auto \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_WEDGE_ALARM_CHANNEL=osascript FM_WEDGE_ALARM_EXEC="$recorder" \
    "$SENTINEL" note-outage || fail "repeat outage note failed"
  assert_contains "$(cat "$marker")" 'delivery=sent' "a later note-outage reset a committed delivery record"
  [ "$(wc -l < "$log" | tr -d '[:space:]')" -eq 1 ] || fail "note-outage notified after the episode was already delivered"

  assert_not_contains "$(cat "$ROOT/bin/fm-turnend-guard.sh" "$ROOT/bin/fm-continuity-pretool-check.sh")" \
    'SENTINEL" check' "an in-harness guard still waits on the active-alert boundary"
  pass "supervision sentinel: in-harness guards record outage evidence without any notifier work"
}

test_in_harness_modes_are_marker_only_and_honor_a_durable_disarm() {
  local home="$TMP_ROOT/marker-only" recorder="$TMP_ROOT/record-marker-only" log="$TMP_ROOT/marker-only.log" marker mode out status
  make_primary "$home"
  make_recorder "$recorder" "$log"
  printf 'project=test\n' > "$home/state/task.meta"
  touch -t 202001010000 "$home/state/.last-watcher-beat"
  marker="$home/state/.supervision-outage-alarm"

  # `scheduled-check` is the only mode that may cross the external boundary, so
  # neither in-harness mode alerts even though both see the same outage.
  for mode in check note-outage; do
    rm -f "$marker"
    out=$(run_mode "$home" "$recorder" "$mode"); status=$?
    if [ "$mode" = check ]; then
      expect_code 1 "$status" "the operator diagnostic must exit non-zero on a detected outage"
      assert_contains "$out" 'SUPERVISION DOWN: 1 task(s) in flight' "the operator diagnostic did not report the outage"
      assert_contains "$out" 'external alert delivery is PENDING' "the operator diagnostic did not say host delivery is still owed"
    else
      expect_code 0 "$status" "a hook-owned note must not fail the guard that called it"
      [ -z "$out" ] || fail "note-outage printed to stdout instead of staying silent for hooks: $out"
    fi
    [ ! -e "$log" ] || fail "$mode crossed the active-channel boundary: $(cat "$log")"
    [ -s "$marker" ] || fail "$mode did not record the durable outage evidence"
    assert_contains "$(cat "$marker")" 'delivery=pending' "$mode claimed a delivery it never attempted"
    assert_contains "$(cat "$marker")" 'attempt_at=0' "$mode left a delivery lease the host check must wait out"
    [ ! -e "$home/state/.supervision-sentinel-last-check" ] || fail "$mode forged the launchd liveness proof"
  done

  # The same diagnostic must be unambiguous about a healthy home, with exit 0.
  rm -f "$home/state/task.meta" "$marker"
  out=$(run_mode "$home" "$recorder" check); status=$?
  expect_code 0 "$status" "the operator diagnostic must exit 0 when there is nothing to supervise"
  assert_contains "$out" 'OK - no task metadata in flight' "the operator diagnostic did not report the idle verdict"
  printf 'project=test\n' > "$home/state/task.meta"

  # A deliberately disarmed home stays silent on every EXTERNAL channel and stops
  # accumulating outage evidence until an explicit verified enable. The scheduled
  # host check still records its LOCAL liveness proof first: that marker is what
  # enable's bounded registration wait observes, so a proof gated on the disarm
  # record would deadlock the one documented recovery command forever.
  rm -f "$marker"
  printf 'state=disarmed\n' > "$home/state/.supervision-sentinel.disarmed"
  for mode in check note-outage scheduled-check; do
    out=$(run_mode "$home" "$recorder" "$mode") || fail "$mode failed on a disarmed home"
    [ ! -e "$log" ] || fail "$mode alerted on a deliberately disarmed home: $(cat "$log")"
    [ ! -e "$marker" ] || fail "$mode wrote outage evidence on a deliberately disarmed home"
    if [ "$mode" = check ]; then
      assert_contains "$out" 'DISARMED' "the operator diagnostic hid the deliberate disarm"
    fi
    if [ "$mode" = scheduled-check ]; then
      [ -s "$home/state/.supervision-sentinel-last-check" ] \
        || fail "a disarmed home's scheduled check withheld the local liveness proof enable waits on"
    else
      [ ! -e "$home/state/.supervision-sentinel-last-check" ] \
        || fail "$mode forged the launchd liveness proof on a disarmed home"
    fi
  done
  rm -f "$home/state/.supervision-sentinel.disarmed" "$home/state/.supervision-sentinel-last-check"
  pass "supervision sentinel: check reports a marker-only verdict, note-outage stays silent, and every mode honors a durable disarm"
}

test_marker_only_evidence_refreshes_a_new_episode_but_never_a_claim() {
  local home="$TMP_ROOT/refresh" recorder="$TMP_ROOT/record-refresh" log="$TMP_ROOT/refresh.log" marker first second
  make_primary "$home"
  make_recorder "$recorder" "$log"
  printf 'project=test\n' > "$home/state/task.meta"
  touch -t 202001010000 "$home/state/.last-watcher-beat"
  marker="$home/state/.supervision-outage-alarm"

  run_mode "$home" "$recorder" note-outage || fail "first outage note failed"
  first=$(awk -F= '$1 == "episode" { print $2 }' "$marker")
  assert_contains "$(cat "$marker")" 'SUPERVISION DOWN: 1 task(s) in flight' "first note omitted its summary"

  # A changed task count with the same episode refreshes the human-facing text.
  printf 'project=test\n' > "$home/state/task-2.meta"
  run_mode "$home" "$recorder" note-outage || fail "second outage note failed"
  assert_contains "$(cat "$marker")" 'SUPERVISION DOWN: 2 task(s) in flight' "a changed in-flight count left stale evidence"

  # A changed beacon episode re-keys the frozen record instead of preserving the
  # first outage ever observed on a home with no working host check.
  touch -t 202001020000 "$home/state/.last-watcher-beat"
  run_mode "$home" "$recorder" note-outage || fail "third outage note failed"
  second=$(awk -F= '$1 == "episode" { print $2 }' "$marker")
  [ -n "$first" ] && [ "$first" != "$second" ] || fail "changed outage evidence did not re-key the durable record"
  assert_contains "$(cat "$marker")" 'delivery=pending' "a marker-only refresh must never claim delivery"

  # An in-flight scheduled claim owns the record: a concurrent guard note must
  # not steal its token, count, or lease even when the episode moved.
  NOW=$(date +%s) awk -F= '$1 == "claim" { print "claim=host-token"; next }
           $1 == "attempt_at" { printf "attempt_at=%s\n", ENVIRON["NOW"]; next }
           $1 == "delivery_count" { print "delivery_count=3"; next } { print }' "$marker" > "$marker.claimed"
  mv "$marker.claimed" "$marker"
  touch -t 202001030000 "$home/state/.last-watcher-beat"
  run_mode "$home" "$recorder" note-outage || fail "note-outage failed against an in-flight claim"
  assert_contains "$(cat "$marker")" 'claim=host-token' "a marker-only note stole an in-flight delivery claim"
  assert_contains "$(cat "$marker")" 'delivery_count=3' "a marker-only note rewound an in-flight claim's repeat schedule"
  [ ! -e "$log" ] || fail "marker-only refresh reached an external channel: $(cat "$log")"
  pass "supervision sentinel: marker-only evidence refreshes a moved episode without touching a live claim"
}

test_symlinked_home_is_not_reported_as_an_outage() {
  local real="$TMP_ROOT/symlink-real" link="$TMP_ROOT/symlink-home" rootlink="$TMP_ROOT/symlink-root"
  local recorder="$TMP_ROOT/record-symlink" log="$TMP_ROOT/symlink.log" holder
  make_primary "$real"
  make_recorder "$recorder" "$log"
  ln -s "$real" "$link"
  ln -s "$ROOT" "$rootlink"
  printf 'project=test\n' > "$real/state/task.meta"
  sleep 60 &
  holder=$!
  # bin/fm-watch.sh resolves its home and its own path with `pwd`, so it records
  # whatever symlinked spelling it was started through, while the host sentinel
  # resolves both physically with `pwd -P`. The identity check compares the same
  # physical target, so a healthy watcher is never alarmed over the spelling.
  install_stale_watcher_fixture "$real" "$holder" "$rootlink/bin/fm-watch.sh" || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "could not identify the symlinked-home watcher fixture"
  }
  printf '%s\n' "$link" > "$real/state/.watch.lock/fm-home"
  touch "$real/state/.last-watcher-beat"

  FM_SUPERVISION_SENTINEL_MODE=auto \
    FM_ROOT_OVERRIDE="$real" FM_HOME="$real" FM_STATE_OVERRIDE="$real/state" \
    FM_WEDGE_ALARM_CHANNEL=osascript FM_WEDGE_ALARM_EXEC="$recorder" \
    "$SENTINEL" check >/dev/null || fail "a healthy watcher reached through a symlinked home was reported as an outage"
  [ ! -e "$log" ] || fail "a healthy watcher reached through a symlinked home was alarmed as down: $(cat "$log")"
  [ ! -e "$real/state/.supervision-outage-alarm" ] || fail "symlinked-home spelling produced a false outage marker"

  # A genuinely different home must still fail the identity check, with the same
  # live pid, watcher path, and fresh beacon.
  mkdir -p "$TMP_ROOT/symlink-other"
  printf '%s\n' "$TMP_ROOT/symlink-other" > "$real/state/.watch.lock/fm-home"
  FM_SUPERVISION_SENTINEL_MODE=auto \
    FM_ROOT_OVERRIDE="$real" FM_HOME="$real" FM_STATE_OVERRIDE="$real/state" \
    FM_WEDGE_ALARM_CHANNEL=osascript FM_WEDGE_ALARM_EXEC="$recorder" \
    "$SENTINEL" check >/dev/null && fail "a foreign home in the watcher lock was reported as healthy"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ -s "$real/state/.supervision-outage-alarm" ] || fail "a foreign home in the watcher lock was accepted as this home"
  pass "supervision sentinel: watcher identity matches through symlinks but not across homes"
}

test_failed_alert_stays_pending_and_retries() {
  local home="$TMP_ROOT/retry" failing="$TMP_ROOT/record-failure" recorder="$TMP_ROOT/record-retry" log="$TMP_ROOT/retry.log"
  make_primary "$home"
  printf 'project=test\n' > "$home/state/task.meta"
  touch -t 202001010000 "$home/state/.last-watcher-beat"
  cat > "$failing" <<SH
#!/usr/bin/env bash
printf 'failed\\n' >> "$log"
exit 1
SH
  chmod +x "$failing"
  make_recorder "$recorder" "$log"

  if FM_SENTINEL_CLAIM_LEASE_SECS=1 run_check "$home" "$failing"; then
    fail "failed active-alert channel was reported as delivered"
  fi
  assert_contains "$(cat "$home/state/.supervision-outage-alarm")" 'delivery=pending' "failed notification was incorrectly marked delivered"
  sleep 1
  FM_SENTINEL_CLAIM_LEASE_SECS=1 run_check "$home" "$recorder" || fail "pending notification was not retried successfully"
  assert_contains "$(cat "$home/state/.supervision-outage-alarm")" 'delivery=sent' "successful retry did not commit delivery state"
  assert_contains "$(cat "$log")" $'osascript\tSUPERVISION DOWN:' "successful retry did not reach the recorder"
  pass "supervision sentinel: failed alert remains pending and retries on the next check"
}

make_fake_launchctl() {
  local path=$1 log=$2 loaded=$3 checked=$4
  cat > "$path" <<SH
#!/usr/bin/env bash
printf '%s' "\$1" >> "$log"
shift
for arg in "\$@"; do printf ' <%s>' "\$arg" >> "$log"; done
printf '\\n' >> "$log"
case "\$(tail -n 1 "$log")" in
  print*) [ -e "$loaded" ] ;;
  bootstrap*) : > "$loaded"; date +%s > "$checked" ;;
  bootout*) rm -f "$loaded" ;;
  kickstart*) date +%s > "$checked" ;;
  enable*) exit 0 ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$path"
}

test_live_identity_matched_watcher_stays_silent() {
  local home="$TMP_ROOT/healthy" recorder="$TMP_ROOT/record-healthy" log="$TMP_ROOT/healthy-alerts.log" holder identity
  make_primary "$home"
  make_recorder "$recorder" "$log"
  printf 'project=test\n' > "$home/state/task.meta"
  sleep 60 &
  holder=$!
  identity=$(FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$holder") || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "could not identify the healthy watcher fixture"
  }
  mkdir -p "$home/state/.watch.lock"
  printf '%s\n' "$holder" > "$home/state/.watch.lock/pid"
  printf '%s\n' "$home" > "$home/state/.watch.lock/fm-home"
  printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$home/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$home/state/.watch.lock/pid-identity"
  touch "$home/state/.last-watcher-beat"

  run_check "$home" "$recorder"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ ! -e "$log" ] || fail "healthy watcher emitted an active alert: $(cat "$log")"
  [ ! -e "$home/state/.supervision-outage-alarm" ] || fail "healthy watcher wrote an outage marker"
  pass "supervision sentinel: live identity-matched watcher with a fresh beacon stays silent"
}

test_arm_registers_one_home_scoped_read_only_launchd_job() {
  local home="$TMP_ROOT/arm" fake="$TMP_ROOT/fake-launchctl" log="$TMP_ROOT/launchctl.log" loaded="$TMP_ROOT/loaded" checked plist calls
  make_primary "$home"
  checked="$home/state/.supervision-sentinel-last-check"
  make_fake_launchctl "$fake" "$log" "$loaded" "$checked"

  FM_SUPERVISION_SENTINEL_MODE=auto \
    FM_SENTINEL_PLATFORM=Darwin \
    FM_SENTINEL_LAUNCHCTL="$fake" \
    FM_ROOT_OVERRIDE="$home" \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" \
    "$SENTINEL" arm || fail "first sentinel arm did not register its fake launchd service"
  plist="$home/state/.supervision-sentinel.plist"
  [ -s "$plist" ] || fail "sentinel arm did not write its launchd plist"
  assert_contains "$(cat "$plist")" "$SENTINEL" "launchd plist did not pin the tracked sentinel path"
  assert_contains "$(cat "$plist")" '<string>scheduled-check</string>' "launchd plist does not run the host-liveness check mode"
  assert_not_contains "$(cat "$plist")" '<string>check</string>' "launchd plist used the in-harness check entry point"
  assert_contains "$(cat "$plist")" '<integer>60</integer>' "launchd plist lost the bounded one-minute check cadence"
  assert_contains "$(cat "$plist")" '/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin' "launchd plist did not pin its minimal host PATH"
  assert_not_contains "$(cat "$plist")" '.pi/agent/bin' "launchd plist persisted a harness-controlled PATH"
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$plist" >/dev/null || fail "generated launchd plist is invalid"
  fi
  assert_not_contains "$(cat "$plist")" 'fm-watch-arm.sh' "host fallback must not auto-start a watcher"
  assert_not_contains "$(cat "$plist")" 'fm-supervise-daemon.sh' "host fallback must not auto-start an away-mode daemon"
  assert_not_contains "$(cat "$plist")" '--restart' "host fallback must not restart any supervision process"
  # There is no notifier-override knob at all. A manifest that carried one would
  # redirect this home's whole external-alert path for as long as the service stays
  # loaded, and an override that failed would retry silently forever.
  assert_not_contains "$(cat "$plist")" 'FM_WEDGE_ALARM_EXEC' "the generated manifest pinned a notifier override"

  FM_SUPERVISION_SENTINEL_MODE=auto \
    FM_SENTINEL_PLATFORM=Darwin \
    FM_SENTINEL_LAUNCHCTL="$fake" \
    FM_ROOT_OVERRIDE="$home" \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" \
    "$SENTINEL" arm || fail "second sentinel arm was not idempotent"
  calls=$(grep -c '^bootstrap ' "$log" || true)
  [ "$calls" -eq 1 ] || fail "idempotent arm bootstrapped $calls services instead of one: $(cat "$log")"

  touch -t 202001010000 "$checked"
  FM_SUPERVISION_SENTINEL_MODE=auto \
    FM_SENTINEL_PLATFORM=Darwin \
    FM_SENTINEL_LAUNCHCTL="$fake" \
    FM_ROOT_OVERRIDE="$home" \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" \
    "$SENTINEL" arm || fail "loaded sentinel with a stale check heartbeat was not verified"
  [ "$(grep -c '^kickstart ' "$log" || true)" -eq 1 ] || fail "stale host checker was not kickstarted by exact service id: $(cat "$log")"

  FM_SUPERVISION_SENTINEL_MODE=auto \
    FM_SENTINEL_PLATFORM=Darwin \
    FM_SENTINEL_LAUNCHCTL="$fake" \
    FM_SENTINEL_INTERVAL_SECS=90 \
    FM_ROOT_OVERRIDE="$home" \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" \
    "$SENTINEL" arm || fail "changed sentinel manifest was not reloaded"
  [ "$(grep -c '^bootout ' "$log" || true)" -eq 1 ] || fail "manifest change did not retire the exact old service once: $(cat "$log")"
  [ "$(grep -c '^bootstrap ' "$log" || true)" -eq 2 ] || fail "manifest change did not bootstrap one replacement service: $(cat "$log")"
  assert_contains "$(cat "$plist")" '<integer>90</integer>' "reloaded manifest did not retain the changed interval"
  pass "supervision sentinel: launchd registration is one-per-home, reconciles its manifest, and never auto-recovers"
}

run_arm() { # <home> <launchctl> [extra env assignments...]
  local home=$1 fake=$2
  shift 2
  env "$@" \
    FM_SUPERVISION_SENTINEL_MODE=auto \
    FM_SENTINEL_PLATFORM=Darwin \
    FM_SENTINEL_LAUNCHCTL="$fake" \
    FM_ROOT_OVERRIDE="$home" \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" \
    "$SENTINEL" arm
}

test_unconverged_arm_backs_off_instead_of_churning_launchd() {
  local home="$TMP_ROOT/churn" fake="$TMP_ROOT/churn-launchctl" log="$TMP_ROOT/churn-launchctl.log"
  local loaded="$TMP_ROOT/churn-loaded" healthy="$TMP_ROOT/churn-healthy" checked failure err boots
  make_primary "$home"
  checked="$home/state/.supervision-sentinel-last-check"
  failure="$home/state/.supervision-sentinel.arm-failure"
  err="$TMP_ROOT/churn.err"
  # launchd retains the service, but until the healthy flag exists no scheduled
  # check ever lands. That is exactly what a job which cannot resolve its own home
  # under the pinned minimal PATH looks like from the arm side.
  cat > "$fake" <<SH
#!/usr/bin/env bash
printf '%s' "\$1" >> "$log"
shift
for arg in "\$@"; do printf ' <%s>' "\$arg" >> "$log"; done
printf '\\n' >> "$log"
case "\$(tail -n 1 "$log")" in
  print*) [ -e "$loaded" ] || exit 1 ;;
  bootstrap*) : > "$loaded"; [ -e "$healthy" ] && date +%s > "$checked" ;;
  bootout*) rm -f "$loaded" ;;
  kickstart*) [ -e "$healthy" ] && date +%s > "$checked" ;;
esac
exit 0
SH
  chmod +x "$fake"

  # The registration retry schedule has its own bounds: a short repeat-ALERT
  # delay must not shorten how long a broken launchd registration goes unretried.
  if run_arm "$home" "$fake" FM_SENTINEL_CHECK_WAIT_SECS=1 \
    FM_SENTINEL_REALARM_SECS=60 FM_SENTINEL_ARM_RETRY_SECS=900 2>"$err"; then
    fail "arm reported success without a single completed scheduled check"
  fi
  assert_contains "$(cat "$err")" 'no check completed' "failed registration did not say why it failed"
  [ -s "$failure" ] || fail "a failed registration left no durable per-home failure record"
  assert_contains "$(cat "$failure")" 'failures=1' "first registration failure was not counted"
  assert_contains "$(cat "$failure")" 'retry_after_secs=900' "registration retry inherited the repeat-alert delay instead of its own"
  assert_grep 'retry_at=' "$failure" "failure record carries no retry deadline for session start to surface"
  assert_grep "service=$(fm_sentinel_expected_service "$home")" "$failure" "failure record lost the exact service identity"
  boots=$(grep -c '^bootstrap ' "$log" || true)
  [ "$boots" -eq 1 ] || fail "first arm bootstrapped $boots services instead of one: $(cat "$log")"

  if run_arm "$home" "$fake" FM_SENTINEL_CHECK_WAIT_SECS=1 FM_SENTINEL_ARM_RETRY_SECS=900 2>"$err"; then
    fail "arm inside its failure cooldown must not claim host monitoring is healthy"
  fi
  assert_contains "$(cat "$err")" 'host outage monitoring is NOT active' "cooldown warning implied monitoring was live"
  assert_contains "$(cat "$err")" 'fm-supervision-sentinel.sh enable' "cooldown warning omitted the deliberate recovery action"
  [ "$(grep -c '^bootstrap ' "$log" || true)" -eq 1 ] || fail "cooldown still re-bootstrapped the service: $(cat "$log")"
  [ "$(grep -c '^bootout ' "$log" || true)" -eq 0 ] || fail "cooldown still booted out the service: $(cat "$log")"
  [ "$(grep -c '^kickstart ' "$log" || true)" -eq 0 ] || fail "cooldown still kickstarted the service: $(cat "$log")"
  assert_contains "$(cat "$failure")" 'failures=1' "a cooldown skip must not count as another failure"

  # An explicit enable bypasses the cooldown, but a FAILED enable must not erase
  # the evidence: the suppressed state has to survive to the next session start,
  # and its count must keep escalating rather than resetting to a first failure.
  FM_SUPERVISION_SENTINEL_MODE=auto FM_SENTINEL_PLATFORM=Darwin FM_SENTINEL_LAUNCHCTL="$fake" \
    FM_SENTINEL_CHECK_WAIT_SECS=1 FM_SENTINEL_ARM_RETRY_SECS=900 \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$SENTINEL" enable >/dev/null 2>"$err" && fail "enable reported success while no scheduled check completed"
  [ -s "$failure" ] || fail "a failed enable cleared the durable failure record before verified recovery"
  assert_contains "$(cat "$failure")" 'failures=2' "a failed enable reset the escalating failure count"
  [ "$(grep -c '^bootstrap ' "$log" || true)" -eq 2 ] || fail "enable did not bypass the cooldown for one real attempt: $(cat "$log")"

  # Only a verified registration clears it.
  : > "$healthy"
  FM_SUPERVISION_SENTINEL_MODE=auto FM_SENTINEL_PLATFORM=Darwin FM_SENTINEL_LAUNCHCTL="$fake" \
    FM_SENTINEL_CHECK_WAIT_SECS=1 FM_SENTINEL_ARM_RETRY_SECS=900 \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$SENTINEL" enable >/dev/null 2>"$err" || fail "explicit enable did not override the failure cooldown: $(cat "$err")"
  [ ! -e "$failure" ] || fail "a verified registration left its failure record behind"
  [ -s "$checked" ] || fail "verified registration did not record a completed scheduled check"

  boots=$(grep -c '^bootstrap ' "$log" || true)
  run_arm "$home" "$fake" FM_SENTINEL_CHECK_WAIT_SECS=1 2>"$err" \
    || fail "converged arm did not report success: $(cat "$err")"
  [ "$(grep -c '^bootstrap ' "$log" || true)" -eq "$boots" ] \
    || fail "a converged arm re-registered the service: $(cat "$log")"
  [ ! -e "$failure" ] || fail "a converged arm recorded a failure"
  pass "supervision sentinel: an unconverged launchd registration backs off per home instead of churning"
}

test_rolled_back_clock_does_not_suppress_registration_forever() {
  local home="$TMP_ROOT/stale-cooldown" fake="$TMP_ROOT/stale-launchctl" log="$TMP_ROOT/stale-launchctl.log"
  local loaded="$TMP_ROOT/stale-loaded" checked failure err out
  make_primary "$home"
  home=$(cd "$home" && pwd -P)
  checked="$home/state/.supervision-sentinel-last-check"
  failure="$home/state/.supervision-sentinel.arm-failure"
  err="$TMP_ROOT/stale.err"
  make_fake_launchctl "$fake" "$log" "$loaded" "$checked"

  # A state volume restored from a machine whose clock ran ahead, or a local clock
  # rollback: retry_at is far beyond the window retry_after_secs recorded with it.
  # That evidence cannot be trusted to suppress anything.
  cat > "$failure" <<EOF
state=arm-failed
failures=1
failed_at=1
retry_after_secs=60
retry_at=$(( $(date +%s) + 86400 ))
home=$home
EOF

  run_arm "$home" "$fake" 2>"$err" || fail "a stale retry deadline blocked registration: $(cat "$err")"
  [ ! -e "$failure" ] || fail "a verified registration left the stale failure record behind"
  [ "$(grep -c '^bootstrap ' "$log" || true)" -eq 1 ] \
    || fail "a stale retry deadline suppressed the launchd retry: $(cat "$log")"

  # The operator diagnostic must call that stale evidence out rather than print an
  # enormous active suppression window the arm path would ignore.
  cat > "$failure" <<EOF
state=arm-failed
failures=2
failed_at=1
retry_after_secs=60
retry_at=$(( $(date +%s) + 86400 ))
home=$home
EOF
  printf 'project=test\n' > "$home/state/task.meta"
  touch -t 202001010000 "$home/state/.last-watcher-beat"
  out=$(run_mode "$home" "$TMP_ROOT/record-stale" check) && fail "check reported healthy during an outage"
  assert_contains "$out" 'retry deadline is stale' "the diagnostic presented a stale deadline as an active suppression window"
  assert_not_contains "$out" 'suppressed for another 86400s' "the diagnostic printed an enormous unenforced suppression window"
  pass "supervision sentinel: a retry deadline beyond its own recorded window is stale evidence, not a suppression"
}

test_explicit_disarm_is_durable_home_scoped_and_reversible() {
  local home="$TMP_ROOT/disarm" fake="$TMP_ROOT/disarm-launchctl" log="$TMP_ROOT/disarm-launchctl.log" loaded="$TMP_ROOT/disarm-loaded" checked before after out
  make_primary "$home"
  home=$(cd "$home" && pwd -P)
  checked="$home/state/.supervision-sentinel-last-check"
  make_fake_launchctl "$fake" "$log" "$loaded" "$checked"

  FM_SUPERVISION_SENTINEL_MODE=auto FM_SENTINEL_PLATFORM=Darwin FM_SENTINEL_LAUNCHCTL="$fake" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$SENTINEL" arm || fail "disarm fixture could not register its home service"
  out=$(FM_SENTINEL_PLATFORM=Darwin FM_SENTINEL_LAUNCHCTL="$fake" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$SENTINEL" disarm) || fail "explicit disarm failed"
  assert_contains "$out" 'disarmed for this home' "disarm did not report its durable result"
  [ ! -e "$loaded" ] || fail "disarm left the exact home service loaded"
  [ -s "$home/state/.supervision-sentinel.disarmed" ] || fail "disarm did not leave a durable visible record"
  assert_contains "$(cat "$home/state/.supervision-sentinel.disarmed")" "home=$home" "disarm record lost its canonical home identity"
  [ ! -e "$home/state/.supervision-sentinel.plist" ] || fail "disarm left its generated manifest installed"

  # An ordinary arm on a disarmed home is a deliberate no-op: it must not
  # register, must not exit 0 (that is reserved for a verified registration),
  # and must not record a failure, because it neither protected the home nor
  # tried and lost.
  before=$(grep -c '^bootstrap ' "$log" || true)
  FM_SUPERVISION_SENTINEL_MODE=auto FM_SENTINEL_PLATFORM=Darwin FM_SENTINEL_LAUNCHCTL="$fake" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$SENTINEL" arm >/dev/null 2>&1
  expect_code 4 $? "automatic arm on a disarmed home did not report the deliberate no-op status"
  after=$(grep -c '^bootstrap ' "$log" || true)
  [ "$after" -eq "$before" ] || fail "ordinary arm silently overrode the durable disarm"
  [ -s "$home/state/.supervision-sentinel.disarmed" ] || fail "ordinary arm cleared the durable disarm record"
  [ ! -e "$home/state/.supervision-sentinel.arm-failure" ] \
    || fail "a deliberate no-op arm recorded a registration failure it never attempted"

  FM_SUPERVISION_SENTINEL_MODE=off FM_SENTINEL_PLATFORM=Darwin FM_SENTINEL_LAUNCHCTL="$fake" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$SENTINEL" enable >/dev/null || fail "explicit enable did not restore the home service"
  [ -e "$loaded" ] || fail "explicit enable did not load the exact home service"
  [ ! -e "$home/state/.supervision-sentinel.disarmed" ] || fail "explicit enable left the disarm record after verified registration"

  assert_not_contains "$(cat "$ROOT/bin/fm-teardown.sh" "$ROOT/bin/fm-session-start.sh" "$ROOT/bin/fm-watch-arm.sh")" \
    'fm-supervision-sentinel.sh disarm' "ordinary lifecycle code invokes the explicit-only disarm path"
  pass "supervision sentinel: explicit disarm is durable, home-scoped, visible, and explicitly reversible"
}

# Regression: disarm -> enable must converge against a transport that does NOT
# forge the liveness proof. make_fake_launchctl stamps the last-check file from
# bootstrap/kickstart directly, which masked a deadlock: while the durable disarm
# record exists, a launchd-spawned scheduled-check that returns before recording
# the proof leaves enable's bounded registration wait nothing to observe, so the
# one documented recovery command timed out and preserved the disarm record
# forever. This fake launchd runs the REAL scheduled-check on bootstrap and
# kickstart, exactly as RunAtLoad does, so the proof exists only if that check
# records it on the still-disarmed home.
test_disarm_then_enable_restores_host_monitoring() {
  local home="$TMP_ROOT/reenable" fake="$TMP_ROOT/reenable-launchctl" log="$TMP_ROOT/reenable-launchctl.log"
  local loaded="$TMP_ROOT/reenable-loaded" recorder="$TMP_ROOT/record-reenable" alerts="$TMP_ROOT/reenable-alerts.log" checked out
  make_primary "$home"
  home=$(cd "$home" && pwd -P)
  checked="$home/state/.supervision-sentinel-last-check"
  make_recorder "$recorder" "$alerts"
  cat > "$fake" <<SH
#!/usr/bin/env bash
printf '%s' "\$1" >> "$log"
shift
for arg in "\$@"; do printf ' <%s>' "\$arg" >> "$log"; done
printf '\\n' >> "$log"
run_scheduled_check() {
  FM_SUPERVISION_SENTINEL_MODE=auto FM_SENTINEL_PLATFORM=Darwin FM_SENTINEL_LAUNCHCTL="$fake" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_WEDGE_ALARM_CHANNEL=osascript FM_WEDGE_ALARM_EXEC="$recorder" "$SENTINEL" scheduled-check
}
case "\$(tail -n 1 "$log")" in
  print*) [ -e "$loaded" ] ;;
  bootstrap*) : > "$loaded"; run_scheduled_check ;;
  bootout*) rm -f "$loaded" ;;
  kickstart*) run_scheduled_check ;;
  enable*) exit 0 ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fake"

  FM_SUPERVISION_SENTINEL_MODE=auto FM_SENTINEL_PLATFORM=Darwin FM_SENTINEL_LAUNCHCTL="$fake" \
    FM_SENTINEL_CHECK_WAIT_SECS=5 \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$SENTINEL" arm || fail "re-enable fixture could not register against the real-check transport"
  FM_SENTINEL_PLATFORM=Darwin FM_SENTINEL_LAUNCHCTL="$fake" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$SENTINEL" disarm >/dev/null || fail "re-enable fixture could not disarm"
  [ -s "$home/state/.supervision-sentinel.disarmed" ] || fail "re-enable fixture left no durable disarm record"

  # An outage begins while the home is disarmed: the enable-time launchd check
  # must record the local proof yet still cross no external channel and write no
  # outage marker for the deliberately disarmed home.
  printf 'project=test\n' > "$home/state/task.meta"
  touch -t 202001010000 "$home/state/.last-watcher-beat"

  out=$(FM_SUPERVISION_SENTINEL_MODE=auto FM_SENTINEL_PLATFORM=Darwin FM_SENTINEL_LAUNCHCTL="$fake" \
    FM_SENTINEL_CHECK_WAIT_SECS=5 \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$SENTINEL" enable) || fail "enable after disarm deadlocked instead of restoring host monitoring: $out"
  assert_contains "$out" 'enabled for this home' "enable did not report the restored service"
  [ ! -e "$home/state/.supervision-sentinel.disarmed" ] || fail "a verified enable left the durable disarm record behind"
  [ -e "$loaded" ] || fail "enable did not load the exact home service"
  [ -s "$checked" ] || fail "the launchd-spawned check on the disarmed home never recorded the local liveness proof"
  [ ! -e "$alerts" ] || fail "the enable-time check on a disarmed home crossed the external channel: $(cat "$alerts")"
  [ ! -e "$home/state/.supervision-outage-alarm" ] || fail "the enable-time check wrote outage evidence on a disarmed home"
  [ ! -e "$home/state/.supervision-sentinel.arm-failure" ] || fail "a verified enable left an arm-failure record"
  pass "supervision sentinel: disarm then enable restores host monitoring without forged liveness or external noise"
}

test_watch_arm_validates_arguments_before_sentinel_registration() {
  local case_line arm_line
  case_line=$(grep -nF "case \"\${1:-}\" in" "$ROOT/bin/fm-watch-arm.sh" | tail -1 | cut -d: -f1)
  arm_line=$(grep -nF "\"\$SENTINEL\" arm" "$ROOT/bin/fm-watch-arm.sh" | head -1 | cut -d: -f1)
  [ -n "$case_line" ] && [ -n "$arm_line" ] && [ "$case_line" -lt "$arm_line" ] \
    || fail "watcher arm still registers the host service before rejecting bad argv"
  pass "supervision sentinel: watcher arm validates argv before host registration"
}

# The generated job sets RunAtLoad, so registration itself triggers a scheduled
# check. Registering before the watcher is confirmed would therefore alert on the
# very outage the arm is ending, which is what every reboot looks like: the
# gui/<uid> agent is gone while task metadata survives. This drives the real
# bin/fm-watch-arm.sh against a scratch tree whose sentinel records the supervision
# state it was invoked in, so the ordering is observed rather than asserted.
test_watch_arm_registers_the_host_sentinel_only_after_a_healthy_watcher() {
  local home="$TMP_ROOT/arm-order" order out armpid i
  make_primary "$home"
  home=$(cd "$home" && pwd -P)
  order="$home/arm-order.log"
  out="$home/arm.out"
  cp "$ROOT/bin/fm-watch-arm.sh" "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-supervision-lib.sh" "$home/bin/" \
    || fail "could not stage the scratch watcher-arm tree"
  cat > "$home/bin/fm-watch.sh" <<SH
#!/usr/bin/env bash
set -u
FM_HOME=$home
. "$home/bin/fm-wake-lib.sh"
mkdir -p "$home/state/.watch.lock"
printf '%s\n' "\$\$" > "$home/state/.watch.lock/pid"
printf '%s\n' "$home" > "$home/state/.watch.lock/fm-home"
printf '%s\n' "$home/bin/fm-watch.sh" > "$home/state/.watch.lock/watcher-path"
fm_pid_identity "\$\$" > "$home/state/.watch.lock/pid-identity"
: > "$home/state/.last-watcher-beat"
printf 'watcher-healthy\n' >> "$order"
i=0
while [ "\$i" -lt 300 ]; do
  sleep 0.1
  i=\$((i + 1))
done
SH
  cat > "$home/bin/fm-supervision-sentinel.sh" <<SH
#!/usr/bin/env bash
set -u
FM_HOME=$home
. "$home/bin/fm-wake-lib.sh"
if fm_watcher_healthy "$home/state" "$home/bin/fm-watch.sh" 300 "$home"; then
  printf 'sentinel-arm healthy\n' >> "$order"
else
  printf 'sentinel-arm outage\n' >> "$order"
fi
SH
  chmod +x "$home/bin/fm-watch.sh" "$home/bin/fm-supervision-sentinel.sh"
  printf 'project=test\n' > "$home/state/task.meta"

  FM_HOME="$home" "$home/bin/fm-watch-arm.sh" > "$out" 2>&1 &
  armpid=$!
  i=0
  while [ "$i" -lt 200 ] && ! grep -q '^sentinel-arm ' "$order" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  kill -TERM "$armpid" 2>/dev/null || true
  wait "$armpid" 2>/dev/null || true

  assert_contains "$(cat "$out")" 'watcher: started pid=' "the scratch arm never confirmed its own watcher: $(cat "$out")"
  assert_grep 'sentinel-arm healthy' "$order" "the host service was not registered once the watcher was observed healthy"
  assert_no_grep 'sentinel-arm outage' "$order" "the host service was registered while the home was still in the outage this arm was resolving"
  [ "$(head -n 1 "$order")" = watcher-healthy ] \
    || fail "host registration preceded the watcher it is meant to backstop: $(cat "$order")"
  [ "$(grep -c '^sentinel-arm ' "$order" || true)" -eq 1 ] \
    || fail "one arm registered the host service more than once: $(cat "$order")"
  pass "supervision sentinel: the watcher arm registers the host service only after observing a healthy watcher"
}

# Away mode is not exempt from the observed-health premise. The away entry execs
# the daemon, so the registration belongs to the daemon: the one process that can
# observe the watcher it starts. This asserts the ownership boundary, the ordering,
# the cadence gate, and that ONLY a verified registration latches - a days-long away
# session must never treat one transient launchd failure as done-trying. The
# daemon's supervision loop is not reachable as a unit; the record format the
# catch-up depends on is unit-tested in tests/fm-daemon.test.sh.
test_away_mode_defers_host_registration_until_the_daemon_sees_a_healthy_watcher() {
  local afk="$ROOT/bin/fm-afk-start.sh" daemon="$ROOT/bin/fm-supervise-daemon.sh"
  local body probe arm latch cadence
  assert_not_contains "$(cat "$afk")" 'SENTINEL" arm' \
    "the away entry still registers the host service before any watcher can be observed healthy"
  body=$(/usr/bin/awk '/^  arm_host_sentinel\(\) \{$/ { p = 1 } p { print } p && /^  \}$/ { exit }' "$daemon")
  [ -n "$body" ] || fail "the away daemon has no host-sentinel registration helper"
  assert_contains "$body" 'SENTINEL" arm' "the away daemon's helper never registers the host service"
  probe=$(printf '%s\n' "$body" | grep -n 'fm_watcher_healthy' | head -1 | cut -d: -f1)
  arm=$(printf '%s\n' "$body" | grep -n 'SENTINEL" arm' | head -1 | cut -d: -f1)
  [ -n "$probe" ] || fail "the away daemon registers without observing a healthy watcher: $body"
  [ "$probe" -lt "$arm" ] || fail "the away daemon registers before it observes a healthy watcher: $body"
  [ "$(grep -c 'SENTINEL" arm' "$daemon" || true)" -eq 1 ] \
    || fail "the away daemon registers the host service outside its gated helper"

  # Only success latches, so a transient failure cannot disable host outage
  # detection for the rest of an unattended away session.
  [ "$(printf '%s\n' "$body" | grep -c 'SENTINEL_ARMED=1' || true)" -eq 1 ] \
    || fail "the away daemon latches its host registration in more than one place: $body"
  latch=$(printf '%s\n' "$body" | grep -n 'SENTINEL_ARMED=1' | head -1 | cut -d: -f1)
  [ "$arm" -lt "$latch" ] || fail "the away daemon latches host registration before it is verified: $body"

  # The multi-fork health probe and the retry both run on the housekeeping cadence,
  # never the loop's one-second tick, and the retry delay is capped.
  cadence=$(printf '%s\n' "$body" | grep -n 'SENTINEL_NEXT_ATTEMPT' | head -1 | cut -d: -f1)
  [ -n "$cadence" ] || fail "the away daemon has no cadence gate on its health probe: $body"
  [ "$cadence" -lt "$probe" ] \
    || fail "the away daemon runs its multi-fork health probe before the cadence gate: $body"
  assert_contains "$body" 'SENTINEL_RETRY_DELAY' "a failed away registration is never retried: $body"
  assert_contains "$body" 'SENTINEL_RETRY_MAX' "the away registration retry delay has no cap: $body"
  assert_contains "$body" 'sentinel_gap_append' \
    "the away daemon records no durable evidence that host alarms were unavailable: $body"

  # A permanently unsupported host stops the retries, but never by latching ARMED:
  # unsupported is unprotected, and no surface may read it as protected.
  assert_contains "$body" 'FM_SUP_SENTINEL_UNSUPPORTED_EXIT' \
    "the away daemon retries a permanently unsupported host as though it were transient: $body"
  assert_contains "$body" 'SENTINEL_UNSUPPORTED=1' \
    "the away daemon has no distinct latch for a permanently unsupported host: $body"
  assert_contains "$(printf '%s\n' "$body" | grep -A 6 'FM_SUP_SENTINEL_UNSUPPORTED_EXIT')" 'unsupported' \
    "the away daemon does not record an unsupported host as its own evidence class: $body"
  assert_not_contains "$(printf '%s\n' "$body" | grep -A 6 'FM_SUP_SENTINEL_UNSUPPORTED_EXIT')" 'SENTINEL_ARMED=1' \
    "the away daemon marks an unsupported host as armed, rendering unprotected as protected: $body"
  pass "supervision sentinel: away mode defers host registration to an observed healthy watcher, retries on cadence, and latches only success"
}

run_arm_on_platform() { # <home> <platform> <launchctl>
  local home=$1 platform=$2 launchctl=$3
  FM_SUPERVISION_SENTINEL_MODE=auto \
    FM_SENTINEL_PLATFORM="$platform" \
    FM_SENTINEL_LAUNCHCTL="$launchctl" \
    FM_ROOT_OVERRIDE="$home" \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" \
    "$SENTINEL" arm
}

# A capability this host does not have is permanent, so `arm` reports it with its
# own exit status and every surface still says the home is unprotected. Ambiguity is
# NOT permanent: a caller that stopped retrying on a generic registration failure
# would abandon a backstop that would have recovered on its own.
test_missing_host_capability_is_a_distinct_permanent_result() {
  local home="$TMP_ROOT/unsupported" fake="$TMP_ROOT/unsupported-launchctl" log="$TMP_ROOT/unsupported-launchctl.log"
  local loaded="$TMP_ROOT/unsupported-loaded" retained="$TMP_ROOT/unsupported-retained-launchctl"
  local retained_loaded="$TMP_ROOT/unsupported-retained-loaded" checked err out status
  make_primary "$home"
  home=$(cd "$home" && pwd -P)
  checked="$home/state/.supervision-sentinel-last-check"
  err="$TMP_ROOT/unsupported.err"
  make_fake_launchctl "$fake" "$log" "$loaded" "$checked"

  # No verified host scheduler for this platform: positive, specific evidence.
  run_arm_on_platform "$home" Linux "$fake" 2>"$err"
  status=$?
  expect_code 3 "$status" "a non-Darwin host did not report a distinct permanently-unsupported result"
  assert_contains "$(cat "$err")" 'no verified host scheduler' "the unsupported result did not name the missing platform capability"
  assert_contains "$(cat "$err")" 'UNAVAILABLE' "the unsupported result did not state that host alarms are unavailable"
  assert_contains "$(cat "$err")" 'only the in-session turn-end and continuity guards apply' \
    "the unsupported result did not state which protection actually applied instead"
  [ ! -e "$log" ] || fail "an unsupported host still reached launchd: $(cat "$log")"
  [ ! -e "$home/state/.supervision-sentinel.arm-failure" ] \
    || fail "an unsupported host recorded a retry cooldown for something no retry can fix"

  # A missing launchctl is the same class of positive evidence.
  run_arm_on_platform "$home" Darwin "$TMP_ROOT/unsupported-absent-launchctl" 2>"$err"
  status=$?
  expect_code 3 "$status" "a missing launchctl did not report a distinct permanently-unsupported result"
  assert_contains "$(cat "$err")" 'launchctl is missing at' "the unsupported result did not name the missing launchctl path"

  # A genuine registration failure is ambiguous and must stay retryable: exit 1,
  # never the permanent status, so the away daemon keeps its capped retry loop.
  cat > "$retained" <<SH
#!/usr/bin/env bash
case "\$1" in
  print) [ -e "$retained_loaded" ] || exit 1 ;;
  bootstrap) : > "$retained_loaded" ;;
  bootout) rm -f "$retained_loaded" ;;
esac
exit 0
SH
  chmod +x "$retained"
  FM_SENTINEL_CHECK_WAIT_SECS=1 run_arm_on_platform "$home" Darwin "$retained" 2>"$err"
  status=$?
  expect_code 1 "$status" "a retained-but-unconverged launchd registration was reported as permanently unsupported"
  assert_contains "$(cat "$err")" 'no check completed' "the transient registration failure lost its reason"
  rm -f "$home/state/.supervision-sentinel.arm-failure"

  # The operator diagnostic must never present an unsupported host as protected: an
  # OK supervision verdict says the watcher is alive, not that a host backstop exists.
  out=$(FM_SUPERVISION_SENTINEL_MODE=auto FM_SENTINEL_PLATFORM=Linux \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$SENTINEL" check)
  status=$?
  expect_code 0 "$status" "the diagnostic must still report its idle verdict on an unsupported host"
  assert_contains "$out" 'OK - no task metadata in flight' "the diagnostic lost its supervision verdict"
  assert_contains "$out" 'host-level outage alarms are UNAVAILABLE here' \
    "the diagnostic rendered an unsupported host as protected: $out"
  assert_contains "$out" 'only the in-session turn-end and continuity guards apply' \
    "the diagnostic did not say which protection actually applied on an unsupported host: $out"
  pass "supervision sentinel: a positively missing host capability is a distinct permanent result and never renders as protected"
}

install_held_arm_lock() { # <home> <holder-pid>
  local home=$1 holder=$2 lock owner
  lock="$home/state/.supervision-sentinel-arm.lock"
  owner="$lock.owner.held"
  rm -rf "$owner" "$lock" 2>/dev/null || true
  mkdir -p "$owner" || return 1
  printf '%s\n' "$holder" > "$owner/pid" || return 1
  ln -s "$owner" "$lock"
}

# A contended arm that never observes a verified service must not report the alarm
# as healthy. The holder is itself a harness-tracked process, so a reap between
# taking the lock and recording a failure leaves no durable evidence at all -
# exactly when an unearned success would hide an unmonitored home.
test_contended_arm_never_reports_success_without_verified_service_evidence() {
  local home="$TMP_ROOT/contended" fake="$TMP_ROOT/contended-launchctl" log="$TMP_ROOT/contended-launchctl.log"
  local loaded="$TMP_ROOT/contended-loaded" failure checked holder err service
  make_primary "$home"
  home=$(cd "$home" && pwd -P)
  checked="$home/state/.supervision-sentinel-last-check"
  failure="$home/state/.supervision-sentinel.arm-failure"
  err="$TMP_ROOT/contended.err"
  make_fake_launchctl "$fake" "$log" "$loaded" "$checked"
  service=$(fm_sentinel_expected_service "$home") || fail "could not derive the contended service identity"
  sleep 300 &
  holder=$!
  install_held_arm_lock "$home" "$holder" || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "could not install a live-held arm lock"
  }
  fail_with_holder() { # <message>
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "$1"
  }

  # No service at all: the missing evidence is launchd not holding this label.
  if run_arm "$home" "$fake" FM_SENTINEL_CHECK_WAIT_SECS=1 2>"$err"; then
    fail_with_holder "a contended arm reported success while nothing proved the service works"
  fi
  assert_contains "$(cat "$err")" "launchd is not holding $service" \
    "the contended arm did not name the missing launchd service"
  assert_contains "$(cat "$err")" 'NOT active' "the contended arm implied host monitoring was live"
  [ "$(grep -c '^bootstrap ' "$log" || true)" -eq 0 ] \
    || fail_with_holder "a contended arm mutated launchd behind a live lock holder: $(cat "$log")"
  [ ! -e "$failure" ] || fail_with_holder "a contended arm recorded a failure cooldown it never earned"

  # Service loaded but no scheduled check has landed: the missing evidence is the
  # completed check, and naming it is what an operator has to repair.
  : > "$loaded"
  touch -t 202001010000 "$checked"
  if run_arm "$home" "$fake" FM_SENTINEL_CHECK_WAIT_SECS=1 2>"$err"; then
    fail_with_holder "a contended arm reported success off a loaded service with no completed check"
  fi
  assert_contains "$(cat "$err")" 'no scheduled check has completed' \
    "the contended arm did not name the missing completed host check"
  assert_contains "$(cat "$err")" 'UNVERIFIED' "the contended arm presented unverified monitoring as healthy"
  [ ! -e "$failure" ] || fail_with_holder "a contended arm recorded a failure cooldown it never earned"

  # The verified pair - launchd holding the exact service plus a recent completed
  # check - is the only state a caller that never held the lock may call success.
  date +%s > "$checked"
  run_arm "$home" "$fake" FM_SENTINEL_CHECK_WAIT_SECS=1 2>"$err" \
    || fail_with_holder "a contended arm rejected a verified live service: $(cat "$err")"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  # A holder reaped mid-registration leaves the lock behind and never records a
  # failure, so one short lock retry after the wait takes it over and registers
  # rather than trusting that silence. The holder here dies well inside the wait.
  rm -f "$loaded" "$checked"
  sleep 2 &
  holder=$!
  install_held_arm_lock "$home" "$holder" || fail "could not install the reaped-holder arm lock"
  run_arm "$home" "$fake" FM_SENTINEL_CHECK_WAIT_SECS=1 2>"$err" \
    || fail "an arm did not take over a reaped holder's lock: $(cat "$err")"
  wait "$holder" 2>/dev/null || true
  [ "$(grep -c '^bootstrap ' "$log" || true)" -eq 1 ] \
    || fail "taking over a reaped holder's lock did not register the service exactly once: $(cat "$log")"
  [ ! -e "$failure" ] || fail "a verified takeover registration left a failure record"
  pass "supervision sentinel: a contended arm retries the lock once, then reports the missing evidence instead of success"
}

# A deliberate no-op must be distinguishable from both a verified registration
# and a genuine failure, so exit 0 can never latch a deliberately unprotected
# home as protected. The disarmed cause is asserted beside the disarm lifecycle
# above; these are the process-local mode and scope causes.
test_deliberate_noop_arm_is_a_distinct_non_failure_result() {
  local home="$TMP_ROOT/noop" fake="$TMP_ROOT/noop-launchctl" log="$TMP_ROOT/noop-launchctl.log"
  local loaded="$TMP_ROOT/noop-loaded" checked err status
  make_primary "$home"
  home=$(cd "$home" && pwd -P)
  checked="$home/state/.supervision-sentinel-last-check"
  err="$TMP_ROOT/noop.err"
  make_fake_launchctl "$fake" "$log" "$loaded" "$checked"

  FM_SUPERVISION_SENTINEL_MODE=off FM_SENTINEL_PLATFORM=Darwin FM_SENTINEL_LAUNCHCTL="$fake" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$SENTINEL" arm 2>"$err"
  status=$?
  expect_code 4 "$status" "sentinel mode off did not report the deliberate no-op status"
  [ ! -e "$log" ] || fail "a mode-off no-op still reached launchd: $(cat "$log")"
  [ ! -e "$home/state/.supervision-sentinel.arm-failure" ] \
    || fail "a mode-off no-op recorded a registration failure it never attempted"

  rm -f "$home/AGENTS.md"
  FM_SUPERVISION_SENTINEL_MODE=auto FM_SENTINEL_PLATFORM=Darwin FM_SENTINEL_LAUNCHCTL="$fake" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$SENTINEL" arm 2>"$err"
  status=$?
  expect_code 4 "$status" "a non-primary scope did not report the deliberate no-op status"
  [ ! -s "$err" ] || fail "a non-primary no-op printed a diagnostic instead of staying silent: $(cat "$err")"
  [ ! -e "$log" ] || fail "a non-primary no-op still reached launchd: $(cat "$log")"
  [ ! -e "$home/state/.supervision-sentinel.arm-failure" ] \
    || fail "a non-primary no-op recorded a registration failure it never attempted"
  pass "supervision sentinel: a deliberate no-op arm reports its own status with no launchd mutation and no failure record"
}

test_real_channel_uses_unambiguous_notification_title_without_posting() {
  local home="$TMP_ROOT/title" fakebin log i
  make_primary "$home"
  printf 'project=test\n' > "$home/state/task.meta"
  touch -t 202001010000 "$home/state/.last-watcher-beat"
  fakebin=$(fm_fakebin "$TMP_ROOT/title-tools")
  log="$TMP_ROOT/osascript-argv.log"
  cat > "$fakebin/osascript" <<SH
#!/usr/bin/env bash
printf '<%s>\\n' "\$@" >> "$log"
SH
  chmod +x "$fakebin/osascript"

  PATH="$fakebin:$PATH" \
    FM_SUPERVISION_SENTINEL_MODE=auto \
    FM_ROOT_OVERRIDE="$home" \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_WEDGE_ALARM_CHANNEL=osascript \
    FM_WEDGE_ALARM_TIMEOUT_SECS=2 \
    env -u FM_WEDGE_ALARM_EXEC "$SENTINEL" scheduled-check
  [ -s "$log" ] || fail "fake osascript did not receive the active alert"
  assert_contains "$(cat "$log")" 'firstmate: SUPERVISION DOWN' "Notification Center title did not identify the supervision outage"
  assert_contains "$(cat "$log")" 'SUPERVISION DOWN: 1 task(s) in flight' "Notification Center body omitted the outage summary"
  pass "supervision sentinel: OS alert title and body are unambiguous (fake notifier only)"
}

# Opt-in end-to-end proof over the REAL launchd transport, which every other case
# in this file fakes. It is deliberately not part of the default suite: it mutates
# the caller's own `gui/<uid>` launchd domain, so it must be an explicit, attended
# choice on a macOS login session rather than something CI or a parallel shard
# does implicitly.
#
# It cannot post a real desktop notification, and that is structural rather than
# configured. launchd runs a COPY of the sentinel inside the scratch home, and the
# sentinel resolves its alert owner as fm-supervise-daemon.sh NEXT TO ITSELF - so
# the copy's alert owner is a stub that only appends to a file. The real daemon,
# and therefore every real notifier, is not reachable from the launched process at
# all, whatever any config lookup does. Production plist generation deliberately
# has no notifier-override knob to abuse instead.
test_real_launchd_scheduled_check_delivers_end_to_end() {
  local home alert_log scratch_sentinel label service plist marker i
  if [ "${FM_SENTINEL_REAL_LAUNCHD_SMOKE:-0}" != 1 ]; then
    pass "supervision sentinel: real-launchd smoke skipped (FM_SENTINEL_REAL_LAUNCHD_SMOKE=1 on an attended macOS login session runs it)"
    return 0
  fi
  [ "$(uname)" = Darwin ] || fail "the real-launchd smoke was requested on $(uname); it is macOS-only"
  [ -x /bin/launchctl ] || fail "the real-launchd smoke was requested without /bin/launchctl"

  home="$TMP_ROOT/real-launchd"
  make_primary "$home"
  home=$(cd "$home" && pwd -P)
  alert_log="$home/real-launchd-alert.log"
  scratch_sentinel="$home/bin/fm-supervision-sentinel.sh"

  cp "$SENTINEL" "$scratch_sentinel"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$ROOT/bin/fm-primary-scope-lib.sh" \
    "$ROOT/bin/fm-wake-lib.sh" "$home/bin/" \
    || fail "could not stage the scratch sentinel's libraries"
  cat > "$home/bin/fm-supervise-daemon.sh" <<SH
#!/usr/bin/env bash
printf '%s\t%s\n' "\$1" "\$2" >> "$alert_log"
SH
  chmod +x "$scratch_sentinel" "$home/bin/fm-supervise-daemon.sh"
  printf 'project=test\n' > "$home/state/task.meta"
  touch -t 202001010000 "$home/state/.last-watcher-beat"

  # Derive the exact service identity before registering anything, so teardown can
  # target this one label even if arm fails partway through.
  service=$(fm_sentinel_expected_service "$home") || fail "could not derive the smoke service identity"
  label=${service##*/}
  FM_SENTINEL_SMOKE_SERVICE="$service"

  FM_SUPERVISION_SENTINEL_MODE=auto FM_HOME="$home" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_SENTINEL_CHECK_WAIT_SECS=30 \
    "$scratch_sentinel" arm || fail "real launchd did not retain and verify this home service"
  plist="$home/state/.supervision-sentinel.plist"
  assert_grep "<string>$label</string>" "$plist" "generated manifest label does not match the derived service identity"
  assert_grep "<string>$scratch_sentinel</string>" "$plist" "the smoke manifest did not pin its scratch sentinel copy"
  assert_grep "<string>$home/config</string>" "$plist" "the smoke manifest did not pin its scratch alert configuration"
  assert_no_grep 'FM_WEDGE_ALARM_EXEC' "$plist" "the manifest carried a notifier override; delivery interception must come from the stub alert owner only"
  /bin/launchctl print "$service" >/dev/null 2>&1 || fail "real launchd is not holding the exact home service"
  [ -s "$home/state/.supervision-sentinel-last-check" ] \
    || fail "a launchd-spawned scheduled-check never recorded host liveness"

  # Wait on the COMMITTED delivery record, not on the alert-owner log. The
  # launchd-spawned check appends to that log and only afterwards takes the claim
  # lock to write delivery=sent, so a wait that stops at the log can sample the
  # marker while it still reads `pending` and fail an outcome that is merely a few
  # milliseconds away. delivery=sent is strictly the later of the two writes, so
  # waiting for it makes every assertion below race-free.
  marker="$home/state/.supervision-outage-alarm"
  i=0
  while [ "$i" -lt 300 ] && ! grep -qF 'delivery=sent' "$marker" 2>/dev/null; do
    sleep 0.2
    i=$((i + 1))
  done
  [ -s "$alert_log" ] || fail "the launchd-spawned check never reached its alert owner"
  assert_grep '--active-alert' "$alert_log" "the launchd job did not invoke its alert owner through the one-shot alert entry point"
  assert_grep 'SUPERVISION DOWN: 1 task(s) in flight' "$alert_log" "launchd-delivered alert omitted the outage summary"
  assert_grep 'delivery=sent' "$marker" "launchd-delivered alert did not commit its delivery state"

  fm_sentinel_bootout_smoke_service "$service" || fail "exact home service could not be retired after the smoke"
  FM_SENTINEL_SMOKE_SERVICE=
  pass "supervision sentinel: real launchd bootstrap -> scheduled-check -> alert owner delivers end to end"
}

test_stale_beacon_alert_is_loud_deduplicated_backed_off_and_rearmed
test_guard_note_outage_records_evidence_without_notifying
test_in_harness_modes_are_marker_only_and_honor_a_durable_disarm
test_marker_only_evidence_refreshes_a_new_episode_but_never_a_claim
test_symlinked_home_is_not_reported_as_an_outage
test_live_identity_matched_watcher_stays_silent
test_failed_alert_stays_pending_and_retries
test_arm_registers_one_home_scoped_read_only_launchd_job
test_unconverged_arm_backs_off_instead_of_churning_launchd
test_rolled_back_clock_does_not_suppress_registration_forever
test_explicit_disarm_is_durable_home_scoped_and_reversible
test_disarm_then_enable_restores_host_monitoring
test_watch_arm_validates_arguments_before_sentinel_registration
test_watch_arm_registers_the_host_sentinel_only_after_a_healthy_watcher
test_away_mode_defers_host_registration_until_the_daemon_sees_a_healthy_watcher
test_contended_arm_never_reports_success_without_verified_service_evidence
test_missing_host_capability_is_a_distinct_permanent_result
test_deliberate_noop_arm_is_a_distinct_non_failure_result
test_real_channel_uses_unambiguous_notification_title_without_posting
test_real_launchd_scheduled_check_delivers_end_to_end
