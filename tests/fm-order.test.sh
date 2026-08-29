#!/usr/bin/env bash
# Behavior tests for bin/fm-order.sh: parse, arm-refusal, graduate-refusal.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ORDER_SH="$ROOT/bin/fm-order.sh"
REGISTER="$ROOT/bin/fm-check-register.sh"
TMP=$(fm_test_tmproot fm-order)
HOME_DIR="$TMP/home"
DATA_DIR="$HOME_DIR/data"
STATE_DIR="$HOME_DIR/state"
ORDERS="$DATA_DIR/orders"
mkdir -p "$ORDERS" "$STATE_DIR" "$HOME_DIR/config" "$DATA_DIR/action-gateway"

NOW=1700000000

run_order() {
  FM_HOME="$HOME_DIR" \
  FM_DATA_OVERRIDE="$DATA_DIR" \
  FM_STATE_OVERRIDE="$STATE_DIR" \
  FM_ACTION_GATEWAY_TEST=1 \
  FM_ACTION_GATEWAY_NOW="$NOW" \
    "$ORDER_SH" "$@"
}

write_order() {
  local slug=$1 status=${2:-DRAFT}
  cat > "$ORDERS/${slug}.md" <<EOF
# ${slug}
Slug: ${slug}
Status: ${status}

## Watch
A fixture watch.

## Stage
crm.update drafts.

## Last click
The message.

## Reaches me
Tier 2.

## Route
Cleared: fixture.
EOF
}

test_help_exits_zero() {
  local out rc
  set +e
  out=$("$ORDER_SH" --help 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "--help exit"
  assert_contains "$out" 'fm-order.sh' "--help usage"
  assert_contains "$out" 'docs/ops-command-center.md' "--help docs pointer"
  pass "fm-order --help exits 0"
}

test_missing_status_fails_loudly() {
  local out rc
  printf '%s\n' '# no status here' > "$ORDERS/broken.md"
  set +e
  out=$(run_order list 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "missing Status exit"
  assert_contains "$out" 'missing Status' "loud missing Status"
  rm -f "$ORDERS/broken.md"
  pass "missing Status fails loudly"
}

test_arm_refuses_without_by_captain() {
  local out rc
  write_order fixture-arm DRAFT
  set +e
  out=$(run_order arm fixture-arm 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "arm without flag exit"
  assert_contains "$out" '--by-captain' "arm names the required flag"
  assert_contains "$out" 'must not self-arm' "arm names the authority rule"
  grep -F 'Status: DRAFT' "$ORDERS/fixture-arm.md" >/dev/null \
    || fail "DRAFT Status must be unchanged without --by-captain"
  pass "arm without --by-captain refuses and does not mutate"
}

test_arm_with_flag_flips_draft_to_armed() {
  local out rc
  write_order fixture-arm2 DRAFT
  set +e
  out=$(run_order arm fixture-arm2 --by-captain 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "arm with flag exit"
  assert_contains "$out" 'armed: fixture-arm2' "arm success"
  grep -E '^Status: ARMED \(captain ' "$ORDERS/fixture-arm2.md" >/dev/null \
    || fail "Status must become ARMED"
  pass "arm --by-captain flips DRAFT to ARMED"
}

test_disarm_refuses_without_flag() {
  local out rc
  write_order fixture-disarm 'ARMED (captain 2026-08-28)'
  set +e
  out=$(run_order disarm fixture-disarm 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "disarm without flag exit"
  assert_contains "$out" '--by-captain' "disarm names the required flag"
  pass "disarm without --by-captain refuses"
}

test_graduate_refuses_irreversible() {
  local out rc
  write_order fixture-grad 'ARMED (captain 2026-08-28)'
  set +e
  out=$(run_order graduate fixture-grad device.config.push --by-captain 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "graduate irreversible exit"
  assert_contains "$out" 'not graduatable' "graduate names the refusal"
  assert_contains "$out" 'device.config.push' "graduate names the kind"
  grep -F 'GRADUATED:' "$ORDERS/fixture-grad.md" >/dev/null \
    && fail "GRADUATED line must not be appended for irreversible kinds" || true
  pass "graduate refuses irreversible kinds via the gateway classifier"
}

test_graduate_refuses_messaging() {
  local out rc
  write_order fixture-grad-mail 'ARMED (captain 2026-08-28)'
  set +e
  out=$(run_order graduate fixture-grad-mail email.send --by-captain 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "graduate messaging exit"
  assert_contains "$out" 'not graduatable' "messaging not graduatable"
  pass "graduate refuses messaging kinds via the gateway classifier"
}

test_graduate_external_kind_appends() {
  local out rc
  write_order fixture-grad-ok 'ARMED (captain 2026-08-28)'
  set +e
  out=$(run_order graduate fixture-grad-ok crm.update --by-captain 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "graduate external exit"
  assert_contains "$out" 'graduated: fixture-grad-ok crm.update' "graduate success"
  grep -E '^GRADUATED: crm.update \(captain ' "$ORDERS/fixture-grad-ok.md" >/dev/null \
    || fail "GRADUATED line must be appended"
  pass "graduate of an external kind appends GRADUATED"
}

test_run_refuses_unregistered_check() {
  local out rc
  write_order fixture-run DRAFT
  set +e
  out=$(run_order run fixture-run 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "run unregistered exit"
  assert_contains "$out" 'no registered check' "run names the missing check"
  pass "run refuses when no registered check exists"
}

test_run_executes_registered_check() {
  local out rc check
  write_order fixture-run2 DRAFT
  check="$STATE_DIR/order-fixture-run2.check.sh"
  cat > "$check" <<'SH'
#!/usr/bin/env bash
printf 'proactive-outbound: 2 clients need contact\n'
SH
  chmod 0700 "$check"
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" "$REGISTER" order-fixture-run2 >/dev/null \
    || fail "could not register order check"
  set +e
  out=$(run_order run fixture-run2 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "run registered exit"
  assert_contains "$out" '2 clients need contact' "run prints check output"
  grep -E '^ts=[0-9]+ fired$' "$STATE_DIR/order-fixture-run2.check.log" >/dev/null \
    || fail "a run that prints a wake line must record a fire"
  pass "run executes a registered check and prints its output"
}

test_list_shows_status_tray_and_last_fire() {
  local out rc
  write_order fixture-list 'ARMED (captain 2026-08-28)'
  set +e
  out=$(run_order list 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "list exit"
  assert_contains "$out" 'fixture-list' "list names the slug"
  assert_contains "$out" 'Status: ARMED' "list includes Status"
  assert_contains "$out" 'tray=' "list includes tray depth"
  assert_contains "$out" 'last_fire=' "list includes last fire"
  pass "list prints slug, Status, tray depth, and last fire"
}

test_status_token_any_case() {
  local out rc
  printf '%s\n%s\n' '# fixture-case' 'STATUS: DRAFT' > "$ORDERS/fixture-case.md"
  set +e
  out=$(run_order arm fixture-case --by-captain 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "arm uppercase STATUS exit"
  assert_contains "$out" 'armed: fixture-case' "uppercase STATUS arms"
  pass "status token parses any case of Status:"
}

file_mode_of() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

test_arm_preserves_order_file_mode() {
  local rc mode
  write_order fixture-mode DRAFT
  chmod 0644 "$ORDERS/fixture-mode.md"
  set +e
  run_order arm fixture-mode --by-captain >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "arm mode exit"
  mode=$(file_mode_of "$ORDERS/fixture-mode.md")
  [ "$mode" = "644" ] || fail "arm must preserve the order file mode (got $mode)"
  pass "arm preserves the order file's mode across the rewrite"
}

test_graduate_unknown_kind_names_deny_by_default() {
  local out rc
  write_order fixture-grad-unknown 'ARMED (captain 2026-08-28)'
  set +e
  out=$(run_order graduate fixture-grad-unknown no.such.kind --by-captain 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "graduate unknown exit"
  assert_contains "$out" 'unknown or unregistered action kind' "unknown kind refusal"
  assert_contains "$out" 'deny-by-default' "gateway refusal reason is surfaced"
  pass "graduate names deny-by-default for unknown kinds"
}

test_graduate_infra_failure_not_misreported() {
  local out rc
  write_order fixture-grad-infra 'ARMED (captain 2026-08-28)'
  set +e
  out=$(FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$DATA_DIR" FM_STATE_OVERRIDE="$STATE_DIR" \
    "$ORDER_SH" graduate fixture-grad-infra crm.update --by-captain 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "graduate infra exit"
  assert_contains "$out" 'FM_ACTION_GATEWAY_TEST' "gateway stderr is surfaced"
  assert_not_contains "$out" 'unknown or unregistered' "infra failure is not misreported as an unregistered kind"
  pass "graduate surfaces gateway infrastructure failures"
}

test_list_marks_tray_unavailable() {
  local out rc audit
  audit="$DATA_DIR/action-gateway/action-audit.log"
  printf 'not json\n' > "$audit"
  set +e
  out=$(run_order list 2>&1)
  rc=$?
  set -e
  rm -f "$audit"
  expect_code 0 "$rc" "list with corrupt audit exit"
  assert_contains "$out" 'tray=?' "corrupt tray shows tray=?"
  assert_contains "$out" 'not JSON' "tray failure reason is surfaced"
  assert_not_contains "$out" 'tray=0' "corrupt tray must not read as zero"
  pass "list marks the tray unavailable instead of zero"
}

test_last_fire_dash_when_no_log() {
  local out rc check
  write_order fixture-nolog DRAFT
  check="$STATE_DIR/order-fixture-nolog.check.sh"
  cat > "$check" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod 0700 "$check"
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" "$REGISTER" order-fixture-nolog >/dev/null \
    || fail "could not register nolog check"
  set +e
  out=$(run_order list 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "list nolog exit"
  printf '%s\n' "$out" | grep -E $'^fixture-nolog\t.*last_fire=-$' >/dev/null \
    || fail "absent log must show last_fire=- (never the check script mtime)"
  pass "last fire is - when no check log exists"
}

test_log_fire_records_watch_fire() {
  local out rc check log
  write_order fixture-fire 'ARMED (captain 2026-08-28)'
  log="$STATE_DIR/order-fixture-fire.check.log"
  printf '' | run_order log-fire fixture-fire >/dev/null 2>&1 \
    || fail "log-fire must pass silent output through"
  [ ! -f "$log" ] || fail "silent check output must not stamp the fire log"
  check="$STATE_DIR/order-fixture-fire.check.sh"
  cat > "$check" <<SH
#!/usr/bin/env bash
printf 'fixture-fire: 1 client needs contact\n' | "$ORDER_SH" log-fire fixture-fire
SH
  chmod 0700 "$check"
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" "$REGISTER" order-fixture-fire >/dev/null \
    || fail "could not register fire check"
  set +e
  out=$(FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$DATA_DIR" FM_STATE_OVERRIDE="$STATE_DIR" \
    FM_ACTION_GATEWAY_TEST=1 FM_ACTION_GATEWAY_NOW="$NOW" bash "$check" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "fire check exit"
  assert_contains "$out" '1 client needs contact' "log-fire passes the wake line through"
  [ -f "$log" ] || fail "a printed wake line must stamp the check log"
  set +e
  out=$(run_order list 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "list after fire exit"
  printf '%s\n' "$out" | grep -E $'^fixture-fire\t.*last_fire=-$' >/dev/null \
    && fail "last fire must update after the check fires" || true
  printf '%s\n' "$out" | grep -E $'^fixture-fire\t.*last_fire=' >/dev/null \
    || fail "list must show a last fire for the fired order"
  pass "a check that prints a wake line updates last fire"
}

test_quiet_run_records_no_fire() {
  local out rc check log before after
  write_order fixture-quiet DRAFT
  check="$STATE_DIR/order-fixture-quiet.check.sh"
  cat > "$check" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod 0700 "$check"
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" "$REGISTER" order-fixture-quiet >/dev/null \
    || fail "could not register quiet check"
  log="$STATE_DIR/order-fixture-quiet.check.log"
  printf 'ts=%s fired\n' "$((NOW - 7200))" > "$log"
  before=$(cat "$log")
  set +e
  run_order run fixture-quiet >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 0 "$rc" "quiet run exit"
  after=$(cat "$log")
  [ "$before" = "$after" ] || fail "a quiet run must not touch the fire log (got: $after)"
  set +e
  out=$(run_order list 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "list after quiet run exit"
  printf '%s\n' "$out" | grep -E $'^fixture-quiet\t.*last_fire=2h$' >/dev/null \
    || fail "a quiet run must not move last_fire off the recorded fire"
  pass "a quiet run records no fire and leaves history intact"
}

test_run_appends_fire_without_erasing_history() {
  local out rc check log fires
  write_order fixture-append DRAFT
  check="$STATE_DIR/order-fixture-append.check.sh"
  cat > "$check" <<'SH'
#!/usr/bin/env bash
printf 'fixture-append: 1 client needs contact\n'
SH
  chmod 0700 "$check"
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" "$REGISTER" order-fixture-append >/dev/null \
    || fail "could not register append check"
  log="$STATE_DIR/order-fixture-append.check.log"
  printf 'ts=%s fired\n' "$((NOW - 7200))" > "$log"
  set +e
  out=$(run_order run fixture-append 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "firing run exit"
  assert_contains "$out" '1 client needs contact' "firing run prints the wake line"
  grep -F "ts=$((NOW - 7200)) fired" "$log" >/dev/null \
    || fail "run must not truncate earlier fire history"
  fires=$(grep -c 'fired' "$log" || true)
  [ "$fires" -eq 2 ] || fail "a firing run must append exactly one fire line (got $fires)"
  set +e
  out=$(run_order list 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "list after firing run exit"
  printf '%s\n' "$out" | grep -E $'^fixture-append\t.*last_fire=0s$' >/dev/null \
    || fail "last_fire must come from the newest recorded fire"
  pass "a firing run appends a fire and keeps prior history"
}

test_timed_out_run_records_no_fire() {
  local out rc check log
  write_order fixture-timeout DRAFT
  check="$STATE_DIR/order-fixture-timeout.check.sh"
  cat > "$check" <<'SH'
#!/usr/bin/env bash
printf 'fixture-timeout: still working\n'
sleep 5
SH
  chmod 0700 "$check"
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" "$REGISTER" order-fixture-timeout >/dev/null \
    || fail "could not register timeout check"
  log="$STATE_DIR/order-fixture-timeout.check.log"
  set +e
  out=$(FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$DATA_DIR" FM_STATE_OVERRIDE="$STATE_DIR" \
    FM_ACTION_GATEWAY_TEST=1 FM_ACTION_GATEWAY_NOW="$NOW" FM_CHECK_TIMEOUT=1 \
    "$ORDER_SH" run fixture-timeout 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "timed out run exit"
  assert_contains "$out" 'timed out' "run names the timeout"
  [ ! -f "$log" ] || fail "a timed-out run must not record a fire"
  pass "a timed-out run records no fire"
}

test_last_fire_ignores_lines_that_are_not_fires() {
  local out rc log
  write_order fixture-stale DRAFT
  log="$STATE_DIR/order-fixture-stale.check.log"
  printf 'ts=%s rc=0\nsome check output\n' "$NOW" > "$log"
  set +e
  out=$(run_order list 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "list with non-fire log exit"
  printf '%s\n' "$out" | grep -E $'^fixture-stale\t.*last_fire=-$' >/dev/null \
    || fail "last_fire must read recorded fire lines, never the log's mtime"
  pass "last fire ignores log lines that record no fire"
}

test_help_exits_zero
test_missing_status_fails_loudly
test_arm_refuses_without_by_captain
test_arm_with_flag_flips_draft_to_armed
test_disarm_refuses_without_flag
test_graduate_refuses_irreversible
test_graduate_refuses_messaging
test_graduate_external_kind_appends
test_run_refuses_unregistered_check
test_run_executes_registered_check
test_list_shows_status_tray_and_last_fire
test_status_token_any_case
test_arm_preserves_order_file_mode
test_graduate_unknown_kind_names_deny_by_default
test_graduate_infra_failure_not_misreported
test_list_marks_tray_unavailable
test_last_fire_dash_when_no_log
test_log_fire_records_watch_fire
test_quiet_run_records_no_fire
test_run_appends_fire_without_erasing_history
test_timed_out_run_records_no_fire
test_last_fire_ignores_lines_that_are_not_fires
