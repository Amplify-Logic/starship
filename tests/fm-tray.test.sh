#!/usr/bin/env bash
# Behavior tests for bin/fm-tray.sh: fixture log render, expiry, age sort, read-only.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TRAY_SH="$ROOT/bin/fm-tray.sh"
GW_SH="$ROOT/bin/fm-action-gateway.sh"
TMP=$(fm_test_tmproot fm-tray)
HOME_DIR="$TMP/home"
DATA_DIR="$HOME_DIR/data"
GW_ROOT="$DATA_DIR/action-gateway"
AUDIT="$GW_ROOT/action-audit.log"
mkdir -p "$GW_ROOT" "$HOME_DIR/config"
printf '%s\n' "test-captain-secret-n1" > "$HOME_DIR/config/action-captain-secret"
chmod 600 "$HOME_DIR/config/action-captain-secret"

# Frozen "now" so age and expiry are deterministic.
NOW=1700003600

run_tray() {
  FM_ACTION_GATEWAY_TEST=1 \
  FM_HOME="$HOME_DIR" \
  FM_DATA_OVERRIDE="$DATA_DIR" \
  FM_ACTION_GATEWAY_ROOT="$GW_ROOT" \
  FM_ACTION_AUDIT_LOG="$AUDIT" \
  FM_ACTION_GATEWAY_NOW="$NOW" \
    "$TRAY_SH" "$@"
}

run_worker() {
  FM_ACTION_GATEWAY_TEST=1 \
  FM_HOME="$HOME_DIR" \
  FM_DATA_OVERRIDE="$DATA_DIR" \
  FM_ACTION_GATEWAY_ROOT="$GW_ROOT" \
  FM_ACTION_AUDIT_LOG="$AUDIT" \
  FM_ACTION_GATEWAY_ROLE=worker \
    "$GW_SH" "$@"
}

# Three prepared cards: oldest (2h), middle (1h, expired), newest (5m).
write_fixture_log() {
  cat > "$AUDIT" <<'JSONL'
{"ts":1700000000,"event":"prepared","state":"prepared","request_id":"r-old","digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","decision":"confirm-first","ceiling":null,"severity":"external","idempotency_key":"i-old","expires_at":1800000000,"requester_id":"worker-old","request":{"task_id":"t-old","domain":"fota","action_kind":"device.config.push","target":"unit-1","parameters":{},"requested_consent_tier":"confirm-first","environment":"prod","policy_version":"1","idempotency_key":"i-old","expires_at":1800000000,"nonce":"n-old","requester_id":"worker-old"}}
{"ts":1700000000,"event":"approved","state":"approved","digest":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","request_id":"r-done"}
{"ts":1700000000,"event":"prepared","state":"prepared","request_id":"r-mid","digest":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","decision":"confirm-first","ceiling":null,"severity":"external","idempotency_key":"i-mid","expires_at":1700000100,"requester_id":"worker-mid","request":{"task_id":"t-mid","domain":"fota","action_kind":"crm.update","target":"hubspot://note","parameters":{},"requested_consent_tier":"confirm-first","environment":"prod","policy_version":"1","idempotency_key":"i-mid","expires_at":1700000100,"nonce":"n-mid","requester_id":"worker-mid"}}
{"ts":1700003300,"event":"prepared","state":"prepared","request_id":"r-new","digest":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","decision":"confirm-first","ceiling":null,"severity":"external","idempotency_key":"i-new","expires_at":1800000000,"requester_id":"worker-new","request":{"task_id":"t-new","domain":"proactive-outbound","action_kind":"crm.update","target":"hubspot://note-2","parameters":{},"requested_consent_tier":"confirm-first","environment":"prod","policy_version":"1","idempotency_key":"i-new","expires_at":1800000000,"nonce":"n-new","requester_id":"worker-new"}}
JSONL
}

test_help_exits_zero() {
  local out rc
  set +e
  out=$("$TRAY_SH" --help 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "--help exit"
  assert_contains "$out" 'fm-tray.sh' "--help usage"
  assert_contains "$out" 'Never approves' "--help read-only"
  pass "fm-tray --help exits 0"
}

test_empty_tray_counts() {
  local out rc
  rm -f "$AUDIT"
  set +e
  out=$(run_tray counts 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "empty counts exit"
  [ "$out" = "TRAY 0 · OLDEST -" ] || fail "empty counts line, got: $out"
  pass "empty tray counts line"
}

test_age_sort_and_expiry() {
  local out rc
  write_fixture_log
  set +e
  out=$(run_tray 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "table exit"
  assert_contains "$out" 'TRAY 3 · OLDEST 1h' "counts: 3 pending, oldest is 1h (3600s)"
  # Order: aaaa (oldest, 1h) then cccc (expired, same prepared_ts but later digest? wait)
  # aaaa ts=1700000000 age=3600s = 1h
  # cccc ts=1700000000 age=3600s = 1h, EXPIRED
  # dddd ts=1700003300 age=300s = 5m
  # Sort by prepared_ts then digest: aaaa, cccc, dddd
  local first second third
  first=$(printf '%s\n' "$out" | awk '/^aaaaaaaaaaaa / {print NR; exit}')
  second=$(printf '%s\n' "$out" | awk '/^cccccccccccc / {print NR; exit}')
  third=$(printf '%s\n' "$out" | awk '/^dddddddddddd / {print NR; exit}')
  [ -n "$first" ] && [ -n "$second" ] && [ -n "$third" ] || fail "expected three digest rows in table: $out"
  [ "$first" -lt "$second" ] && [ "$second" -lt "$third" ] || fail "expected oldest-first digest order, lines $first $second $third"
  assert_contains "$out" 'EXPIRED' "expired card is marked"
  pass "pending table is oldest-first and marks expired"
}

test_approved_omitted() {
  local out
  write_fixture_log
  out=$(run_tray 2>&1)
  assert_not_contains "$out" 'bbbbbbbbbbbb' "approved digest is not pending"
  pass "approved actions are omitted from the pending tray"
}

test_order_filter_and_counts() {
  local out rc
  write_fixture_log
  set +e
  out=$(run_tray counts --order fota 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "filtered counts exit"
  [ "$out" = "TRAY 2 · OLDEST 1h" ] || fail "fota counts, got: $out"
  out=$(run_tray --order proactive-outbound 2>&1)
  assert_contains "$out" 'TRAY 1 · OLDEST 5m' "single-order table"
  assert_contains "$out" 'dddddddddddd' "new card listed"
  assert_not_contains "$out" 'aaaaaaaaaaaa' "other order omitted"
  pass "order filter scopes table and counts"
}

test_read_only_refuses_approve() {
  local out rc before after
  write_fixture_log
  before=$(wc -c < "$AUDIT")
  set +e
  out=$(run_tray approve abc 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "approve via tray exit"
  assert_contains "$out" 'read-only' "tray names read-only"
  after=$(wc -c < "$AUDIT")
  [ "$before" = "$after" ] || fail "tray must not mutate the audit log"
  pass "tray refuses approve and does not mutate the log"
}

test_show_delegates_to_gateway() {
  local out rc digest req
  rm -f "$AUDIT"
  req=$(cat <<JSON
{
  "task_id": "task-tray-show",
  "domain": "fota",
  "action_kind": "crm.update",
  "target": "hubspot://note",
  "parameters": {},
  "requested_consent_tier": "confirm-first",
  "environment": "prod",
  "policy_version": "1",
  "idempotency_key": "idem-tray-show",
  "expires_at": 1893456000,
  "nonce": "nonce-tray-show",
  "requester_id": "worker-show"
}
JSON
)
  out=$(printf '%s' "$req" | run_worker prepare 2>&1)
  digest=$(printf '%s\n' "$out" | awk -F= '$1=="digest" {print $2; exit}')
  [ -n "$digest" ] || fail "prepare must emit a digest"
  set +e
  out=$(run_tray show "$digest" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "tray show exit"
  assert_contains "$out" 'canonical action context' "delegates to gateway show"
  assert_contains "$out" "digest=$digest" "show names the digest"
  assert_contains "$out" 'crm.update' "show includes action kind"
  pass "tray show renders the gateway canonical action context"
}

test_help_exits_zero
test_empty_tray_counts
test_age_sort_and_expiry
test_approved_omitted
test_order_filter_and_counts
test_read_only_refuses_approve
test_show_delegates_to_gateway
