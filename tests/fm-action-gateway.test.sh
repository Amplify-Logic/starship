#!/usr/bin/env bash
# Behavior tests for bin/fm-action-gateway.sh: schema validation,
# audit-append-before-decision ordering, and always-confirm-first stub.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GW_SH="$ROOT/bin/fm-action-gateway.sh"
TMP=$(fm_test_tmproot fm-action-gateway)
HOME_DIR="$TMP/home"
DATA_DIR="$HOME_DIR/data"
AUDIT="$DATA_DIR/action-audit.log"
mkdir -p "$DATA_DIR"

valid_request() {
  cat <<'JSON'
{
  "task_id": "task-gw-1",
  "domain": "travel",
  "action_kind": "purchase",
  "target": "https://airline.example/checkout",
  "parameters": { "amount_cents": 100 },
  "requested_consent_tier": "autonomous"
}
JSON
}

run_gw() {
  FM_HOME="$HOME_DIR" \
  FM_DATA_OVERRIDE="$DATA_DIR" \
  FM_ACTION_AUDIT_LOG="$AUDIT" \
    "$GW_SH" "$@"
}

test_help_exits_zero() {
  local out rc
  set +e
  out=$("$GW_SH" --help 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "--help exit"
  assert_contains "$out" 'fm-action-gateway.sh' "--help usage"
  assert_contains "$out" 'docs/action-gateway.md' "--help docs pointer"
  pass "fm-action-gateway --help exits 0"
}

test_schema_rejects_missing_and_bad_fields() {
  local out rc
  set +e
  out=$(printf '%s' '{"task_id":"x"}' | run_gw 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "missing fields exit"
  assert_contains "$out" 'schema validation failed' "missing fields message"
  [ ! -f "$AUDIT" ] || [ ! -s "$AUDIT" ] || fail "invalid request must not append audit"

  set +e
  out=$(printf '%s' '{"task_id":"../x","domain":"d","action_kind":"k","target":"t","parameters":{},"requested_consent_tier":"confirm-first"}' | run_gw 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "bad task_id exit"

  set +e
  out=$(printf '%s' '{"task_id":"ok","domain":"d","action_kind":"k","target":"t","parameters":[],"requested_consent_tier":"confirm-first"}' | run_gw 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "parameters must be object"

  set +e
  out=$(printf '%s' '{"task_id":"ok","domain":"d","action_kind":"k","target":"t","parameters":{},"requested_consent_tier":"yolo","extra":1}' | run_gw 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "bad tier / unknown field"
  pass "schema validation rejects incomplete and malformed ActionRequests"
}

test_audit_before_decision_always_confirm_first() {
  local out rc line
  rm -f "$AUDIT"
  set +e
  out=$(valid_request | run_gw 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "valid request exit"
  assert_contains "$out" 'decision=confirm-first' "stub always confirm-first"
  assert_not_contains "$out" 'decision=autonomous' \
    "requested autonomous must not change stub decision"
  [ -f "$AUDIT" ] || fail "audit log must exist after decision"
  line=$(tail -n1 "$AUDIT")
  assert_contains "$line" '"decision":"confirm-first"' "audit records confirm-first"
  assert_contains "$line" '"task_id":"task-gw-1"' "audit embeds request"
  # Ordering: decision line is the only stdout content, and audit must already
  # contain the record when the process exits (append happens before print).
  [ "$out" = "decision=confirm-first" ] || fail "stdout must be exactly the decision line"
  pass "audit append precedes decision and stub always returns confirm-first"
}

test_file_input_and_second_append() {
  local req out rc count
  req="$TMP/req.json"
  valid_request > "$req"
  set +e
  out=$(run_gw --file "$req" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "--file exit"
  assert_contains "$out" 'decision=confirm-first' "--file decision"
  count=$(wc -l < "$AUDIT" | tr -d ' ')
  [ "$count" -ge 2 ] || fail "expected at least two audit lines after second call"
  pass "--file input appends another durable audit line"
}

test_audit_failure_yields_no_decision() {
  local out rc blocked
  blocked="$TMP/blocked-audit"
  mkdir -p "$blocked"
  # Make audit path a directory so open(O_APPEND) fails.
  set +e
  out=$(
    valid_request | FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$DATA_DIR" \
      FM_ACTION_AUDIT_LOG="$blocked" "$GW_SH" 2>&1
  )
  rc=$?
  set -e
  expect_code 1 "$rc" "audit failure exit"
  assert_contains "$out" 'durable audit append failed' "audit failure message"
  assert_not_contains "$out" 'decision=' "no decision when audit fails"
  pass "failed audit write emits no decision"
}

test_help_exits_zero
test_schema_rejects_missing_and_bad_fields
test_audit_before_decision_always_confirm_first
test_file_input_and_second_append
test_audit_failure_yields_no_decision
