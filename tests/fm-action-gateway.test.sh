#!/usr/bin/env bash
# Behavior tests for bin/fm-action-gateway.sh broker:
# privilege separation, atomic transitions, choke-point, ceilings, no outward exec.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GW_SH="$ROOT/bin/fm-action-gateway.sh"
TMP=$(fm_test_tmproot fm-action-gateway)
HOME_DIR="$TMP/home"
DATA_DIR="$HOME_DIR/data"
GW_ROOT="$DATA_DIR/action-gateway"
AUDIT="$GW_ROOT/action-audit.log"
SECRET="test-captain-secret-n1"
mkdir -p "$DATA_DIR" "$HOME_DIR/config"
printf '%s\n' "$SECRET" > "$HOME_DIR/config/action-captain-secret"
chmod 600 "$HOME_DIR/config/action-captain-secret"

# Expiry inside the broker's per-severity ceiling (MAX_TTL_SECONDS), so prepare
# and approve stay valid unless a test overrides now. It must be relative to the
# real clock now that the broker caps freshness: a fixed far-future constant is
# exactly what that ceiling refuses.
EXPIRY=$(( $(date +%s) + 600 ))

valid_request() {
  local kind=${1:-purchase}
  local tier=${2:-autonomous}
  local amount_json=${3:-'"amount_cents": 100,'}
  local idem=${4:-idem-gw-1}
  local nonce=${5:-nonce-gw-1}
  local requester=${6:-worker-1}
  cat <<JSON
{
  "task_id": "task-gw-1",
  "domain": "travel",
  "action_kind": "$kind",
  "target": "https://airline.example/checkout",
  "parameters": { ${amount_json} "currency": "EUR" },
  "requested_consent_tier": "$tier",
  "environment": "prod",
  "policy_version": "1",
  "idempotency_key": "$idem",
  "expires_at": $EXPIRY,
  "nonce": "$nonce",
  "requester_id": "$requester"
}
JSON
}

messaging_request() {
  cat <<JSON
{
  "task_id": "task-msg-1",
  "domain": "music-outreach",
  "action_kind": "email.send",
  "target": "smtp://mail.example",
  "parameters": { "recipient": "artist@example.com", "subject": "hello" },
  "requested_consent_tier": "autonomous",
  "environment": "prod",
  "policy_version": "1",
  "idempotency_key": "idem-msg-1",
  "expires_at": $EXPIRY,
  "nonce": "nonce-msg-1",
  "requester_id": "worker-msg"
}
JSON
}

run_worker() {
  FM_ACTION_GATEWAY_TEST=1 \
  FM_HOME="$HOME_DIR" \
  FM_DATA_OVERRIDE="$DATA_DIR" \
  FM_ACTION_GATEWAY_ROOT="$GW_ROOT" \
  FM_ACTION_AUDIT_LOG="$AUDIT" \
  FM_ACTION_GATEWAY_ROLE=worker \
  FM_ACTION_CAPTAIN_SECRET="$SECRET" \
    "$GW_SH" "$@"
}

run_captain() {
  FM_ACTION_GATEWAY_TEST=1 \
  FM_HOME="$HOME_DIR" \
  FM_DATA_OVERRIDE="$DATA_DIR" \
  FM_ACTION_GATEWAY_ROOT="$GW_ROOT" \
  FM_ACTION_AUDIT_LOG="$AUDIT" \
  FM_ACTION_GATEWAY_ROLE=captain \
  FM_ACTION_CAPTAIN_SECRET="$SECRET" \
    "$GW_SH" "$@"
}

kv_get() {
  local blob=$1 key=$2
  printf '%s\n' "$blob" | awk -F= -v k="$key" '$1==k {print substr($0,index($0,"=")+1); exit}'
}

reset_gw() {
  rm -rf "$GW_ROOT"
  mkdir -p "$GW_ROOT"
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
  reset_gw
  set +e
  out=$(printf '%s' '{"task_id":"x"}' | run_worker prepare 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "missing fields exit"
  assert_contains "$out" 'missing fields' "missing fields message"
  [ ! -f "$AUDIT" ] || [ ! -s "$AUDIT" ] || fail "invalid request must not append audit"

  set +e
  out=$(printf '%s' '{"task_id":"../x","domain":"d","action_kind":"purchase","target":"t","parameters":{},"requested_consent_tier":"confirm-first","environment":"e","policy_version":"1","idempotency_key":"i","expires_at":'"$EXPIRY"',"nonce":"n","requester_id":"r"}' | run_worker 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "bad task_id exit"

  set +e
  out=$(printf '%s' '{"task_id":"ok","domain":"d","action_kind":"not.registered","target":"t","parameters":{},"requested_consent_tier":"confirm-first","environment":"e","policy_version":"1","idempotency_key":"i","expires_at":'"$EXPIRY"',"nonce":"n","requester_id":"r"}' | run_worker 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "deny-by-default unknown kind"
  assert_contains "$out" 'deny-by-default' "registry refusal"
  pass "schema validation and deny-by-default registry reject bad requests"
}

test_prepare_confirm_first_no_token_to_worker() {
  local out rc digest line
  reset_gw
  set +e
  out=$(valid_request purchase autonomous | run_worker prepare 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "prepare exit"
  assert_contains "$out" 'decision=confirm-first' "ceiling forces confirm-first"
  assert_contains "$out" 'state=prepared' "prepared state"
  assert_contains "$out" 'ceiling=spend' "spend ceiling recorded"
  assert_contains "$out" 'severity=irreversible' "irreversible severity"
  assert_not_contains "$out" 'decision=autonomous' "autonomous tier cannot raise spend floor"
  assert_not_contains "$out" 'approval_token=' "worker must never receive approval_token"
  digest=$(kv_get "$out" digest)
  [ -n "$digest" ] || fail "digest required"
  [ "${#digest}" -eq 64 ] || fail "digest must be sha256 hex"
  [ -f "$GW_ROOT/captain-inbox/${digest}.approval" ] || fail "captain inbox must hold token"
  line=$(tail -n1 "$AUDIT")
  assert_contains "$line" '"event":"prepared"' "audit prepared event"
  assert_contains "$line" '"execution":"stubbed"' "audit marks execution stubbed"
  pass "prepare records prepared + spend ceiling; token stays in captain inbox"
}

test_requester_cannot_approve_own_request() {
  local out rc digest
  reset_gw
  out=$(valid_request purchase confirm-first '"amount_cents": 100,' idem-self nonce-self worker-1 | run_worker prepare 2>&1)
  digest=$(kv_get "$out" digest)
  [ -n "$digest" ] || fail "digest required"

  # Even with captain role + secret, same identity as requester is refused.
  set +e
  out=$(run_captain approve --digest "$digest" --approver-id worker-1 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "self-approval exit"
  assert_contains "$out" 'requester cannot approve its own request' "self-approval message"
  out=$(run_worker status --digest "$digest" 2>&1)
  assert_contains "$out" 'state=prepared' "state remains prepared after self-approval refusal"
  pass "requester cannot approve its own request"
}

test_worker_role_cannot_approve() {
  local out rc digest
  reset_gw
  out=$(valid_request http.request confirm-first '' idem-role nonce-role worker-2 | run_worker prepare 2>&1)
  digest=$(kv_get "$out" digest)

  set +e
  out=$(run_worker approve --digest "$digest" --approver-id captain-1 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "worker approve exit"
  assert_contains "$out" 'requires FM_ACTION_GATEWAY_ROLE=captain' "role separation"
  pass "worker role cannot approve"
}

test_wrong_captain_secret_refused() {
  local out rc digest
  reset_gw
  out=$(valid_request http.request confirm-first '' idem-sec nonce-sec worker-3 | run_worker prepare 2>&1)
  digest=$(kv_get "$out" digest)

  set +e
  out=$(
    FM_ACTION_GATEWAY_TEST=1 \
    FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$DATA_DIR" \
    FM_ACTION_GATEWAY_ROOT="$GW_ROOT" FM_ACTION_AUDIT_LOG="$AUDIT" \
    FM_ACTION_GATEWAY_ROLE=captain \
    FM_ACTION_CAPTAIN_SECRET=wrong-secret \
      "$GW_SH" approve --digest "$digest" --approver-id captain-1 2>&1
  )
  rc=$?
  set -e
  expect_code 1 "$rc" "wrong secret exit"
  assert_contains "$out" 'captain secret' "secret refusal"
  pass "wrong captain secret is refused"
}

test_distinct_captain_approval_and_gate_check() {
  local out rc digest
  reset_gw
  out=$(valid_request http.request confirm-first '' idem-ok nonce-ok worker-4 | run_worker prepare 2>&1)
  digest=$(kv_get "$out" digest)
  assert_not_contains "$out" 'approval_token=' "no token on prepare stdout"

  out=$(run_captain show --digest "$digest" 2>&1)
  assert_contains "$out" 'canonical action context' "trusted show display"
  assert_contains "$out" "digest=$digest" "show includes digest"

  set +e
  out=$(run_worker gate-check --digest "$digest" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "gate-check before approve"
  assert_contains "$out" 'gate-check refused' "choke refuses unapproved"

  out=$(run_captain approve --digest "$digest" --approver-id captain-1 2>&1)
  assert_contains "$out" 'state=approved' "approved state"
  assert_contains "$out" 'approver_id=captain-1' "attributable approver"
  assert_contains "$out" 'approved_at=' "timestamped approval"

  out=$(run_worker gate-check --digest "$digest" 2>&1)
  assert_contains "$out" 'state=approved' "gate-check passes after approval"
  assert_contains "$out" 'approver_id=captain-1' "gate-check surfaces approver"

  # Token consumed: second approve fails.
  set +e
  out=$(run_captain approve --digest "$digest" --approver-id captain-2 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "second approve exit"
  assert_contains "$out" 'already consumed' "one-shot approval"
  pass "distinct captain approval is attributable, idempotent, and unlocks gate-check"
}

test_atomic_concurrent_approve_single_winner() {
  local out digest rc1 rc2 winners
  reset_gw
  out=$(valid_request http.request confirm-first '' idem-race nonce-race worker-5 | run_worker prepare 2>&1)
  digest=$(kv_get "$out" digest)

  # Two concurrent captain approvers; exclusive lock allows exactly one success.
  set +e
  run_captain approve --digest "$digest" --approver-id captain-a >"$TMP/race-a.out" 2>&1 &
  local pid_a=$!
  run_captain approve --digest "$digest" --approver-id captain-b >"$TMP/race-b.out" 2>&1 &
  local pid_b=$!
  wait "$pid_a"
  rc1=$?
  wait "$pid_b"
  rc2=$?
  set -e

  winners=0
  if [ "$rc1" -eq 0 ]; then
    winners=$((winners + 1))
    assert_contains "$(cat "$TMP/race-a.out")" 'state=approved' "winner a approved"
  fi
  if [ "$rc2" -eq 0 ]; then
    winners=$((winners + 1))
    assert_contains "$(cat "$TMP/race-b.out")" 'state=approved' 'winner b approved'
  fi
  [ "$winners" -eq 1 ] || fail "expected exactly one concurrent approve success, got $winners (rc1=$rc1 rc2=$rc2)"
  local approved_count
  approved_count=$(grep -c '"event":"approved"' "$AUDIT" || true)
  [ "$approved_count" -eq 1 ] || fail "expected exactly one approved audit event, got $approved_count"
  pass "concurrent approve: exclusive lock yields a single winner"
}

test_token_on_argv_rejected() {
  local out rc digest
  reset_gw
  out=$(valid_request http.request confirm-first '' idem-argv nonce-argv worker-6 | run_worker prepare 2>&1)
  digest=$(kv_get "$out" digest)
  set +e
  out=$(run_captain approve --digest "$digest" --approver-id captain-1 --token leaked 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "argv token refused"
  assert_contains "$out" 'no longer accepts --token' "argv token blocked"
  pass "approve rejects --token on argv (inbox only)"
}

test_expiry_refused() {
  local out rc digest
  reset_gw
  out=$(valid_request http.request confirm-first '' idem-exp nonce-exp worker-7 | run_worker prepare 2>&1)
  digest=$(kv_get "$out" digest)
  set +e
  out=$(
    FM_ACTION_GATEWAY_TEST=1 \
    FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$DATA_DIR" \
    FM_ACTION_GATEWAY_ROOT="$GW_ROOT" FM_ACTION_AUDIT_LOG="$AUDIT" \
    FM_ACTION_GATEWAY_ROLE=captain \
    FM_ACTION_CAPTAIN_SECRET="$SECRET" \
    FM_ACTION_GATEWAY_NOW=$((EXPIRY + 10)) \
      "$GW_SH" approve --digest "$digest" --approver-id captain-1 2>&1
  )
  rc=$?
  set -e
  expect_code 1 "$rc" "expired approve exit"
  assert_contains "$out" 'expired' "expiry refusal"
  pass "expired approvals are refused"
}

test_state_transitions_execute_stub_to_unknown() {
  local out rc digest count
  reset_gw
  out=$(valid_request http.request confirm-first '' idem-exec nonce-exec worker-8 | run_worker prepare 2>&1)
  digest=$(kv_get "$out" digest)

  set +e
  out=$(run_captain execute --digest "$digest" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "execute before approve refused"
  assert_contains "$out" 'requires approved' "must be approved first"

  out=$(run_captain approve --digest "$digest" --approver-id captain-1 2>&1)
  assert_contains "$out" 'state=approved' "approved"

  set +e
  out=$(run_worker execute --digest "$digest" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "worker cannot execute"
  assert_contains "$out" 'requires FM_ACTION_GATEWAY_ROLE=captain' "execute privilege separation"

  out=$(run_captain execute --digest "$digest" 2>&1)
  assert_contains "$out" 'state=unknown' "stub ends unknown"
  assert_contains "$out" 'execution-not-wired' "explicit stub reason"
  out=$(run_worker status --digest "$digest" 2>&1)
  assert_contains "$out" 'state=unknown' "status shows unknown"
  count=$(grep -c '"event":"executing"' "$AUDIT" || true)
  [ "$count" -eq 1 ] || fail "expected one executing event"
  pass "state machine prepared->approved->executing->unknown (stub)"
}

test_messaging_ceiling_non_graduatable() {
  local out
  reset_gw
  out=$(messaging_request | run_worker prepare 2>&1)
  assert_contains "$out" 'decision=confirm-first' "messaging confirm-first"
  assert_contains "$out" 'ceiling=messaging' "messaging ceiling"
  assert_contains "$out" 'severity=irreversible' "messaging irreversible"
  assert_not_contains "$out" 'decision=autonomous' "tier cannot raise messaging floor"
  pass "messaging hard ceiling stays confirm-first"
}

test_occ_registry_classifications() {
  local out rc
  reset_gw
  out=$(valid_request device.config.push confirm-first '' idem-dcp nonce-dcp worker-dcp | run_worker prepare 2>&1)
  assert_contains "$out" 'severity=irreversible' "device.config.push irreversible"
  assert_contains "$out" 'decision=confirm-first' "device.config.push confirm-first"

  reset_gw
  out=$(valid_request device.firmware.push confirm-first '' idem-dfp nonce-dfp worker-dfp | run_worker prepare 2>&1)
  assert_contains "$out" 'severity=irreversible' "device.firmware.push irreversible"

  reset_gw
  out=$(valid_request kb.fact.publish confirm-first '' idem-kfp nonce-kfp worker-kfp | run_worker prepare 2>&1)
  assert_contains "$out" 'severity=external' "kb.fact.publish external"

  reset_gw
  out=$(valid_request course.publish confirm-first '' idem-cp nonce-cp worker-cp | run_worker prepare 2>&1)
  assert_contains "$out" 'severity=external' "course.publish external"

  reset_gw
  out=$(valid_request sheet.write confirm-first '' idem-sw nonce-sw worker-sw | run_worker prepare 2>&1)
  assert_contains "$out" 'severity=external' "sheet.write external"
  pass "ops command center registry kinds classify at prepare"
}

test_classify_graduatable_query() {
  local out rc
  set +e
  out=$("$GW_SH" classify --action-kind device.config.push 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "classify irreversible exit"
  assert_contains "$out" 'action_kind=device.config.push' "classify names kind"
  assert_contains "$out" 'severity=irreversible' "classify severity"
  assert_contains "$out" 'graduatable=no' "irreversible is not graduatable"

  out=$("$GW_SH" classify --action-kind email.send 2>&1)
  assert_contains "$out" 'graduatable=no' "messaging is not graduatable"
  assert_contains "$out" 'ceiling=messaging' "email.send ceiling"

  out=$("$GW_SH" classify --action-kind crm.update 2>&1)
  assert_contains "$out" 'severity=external' "crm.update external"
  assert_contains "$out" 'graduatable=yes' "external without spend/messaging may graduate"

  out=$("$GW_SH" classify --action-kind kb.fact.publish 2>&1)
  assert_contains "$out" 'graduatable=yes' "kb.fact.publish may graduate"

  set +e
  out=$("$GW_SH" classify --action-kind not.registered 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "unknown kind classify exit"
  assert_contains "$out" 'deny-by-default' "unknown kind refused"
  pass "classify reuses the ceiling classifier for graduation"
}

# docs/action-gateway.md enumerates the registered irreversible and external
# kinds in prose while the broker's registry owns them. Both lists are compared
# through `classify --list` so the check reads the executable, never its source.
test_doc_kind_lists_match_registry() {
  local doc="$ROOT/docs/action-gateway.md"
  local listing rc severity prose doc_kinds registry_kinds missing extra

  set +e
  listing=$("$GW_SH" classify --list 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "classify --list exit"
  assert_contains "$listing" 'action_kind=purchase severity=irreversible' \
    "classify --list dumps the registry"

  for severity in irreversible external; do
    prose=$(grep -c "^Registered $severity kinds include " "$doc" || true)
    [ "$prose" = "1" ] || fail \
      "docs/action-gateway.md must carry exactly one 'Registered $severity kinds include' line (found $prose)"

    # shellcheck disable=SC2016  # backticks are literal Markdown code fences here
    doc_kinds=$(grep "^Registered $severity kinds include " "$doc" |
      grep -o '`[^`]*`' | tr -d '`' | sort -u)
    registry_kinds=$(printf '%s\n' "$listing" |
      sed -n "s/^action_kind=\\(.*\\) severity=$severity\$/\\1/p" | sort -u)

    [ -n "$doc_kinds" ] || fail "no $severity kinds parsed from docs/action-gateway.md"
    [ -n "$registry_kinds" ] || fail "no $severity kinds reported by classify --list"

    missing=$(comm -13 <(printf '%s\n' "$doc_kinds") <(printf '%s\n' "$registry_kinds") | tr '\n' ' ')
    extra=$(comm -23 <(printf '%s\n' "$doc_kinds") <(printf '%s\n' "$registry_kinds") | tr '\n' ' ')
    [ -z "${missing// /}" ] || fail \
      "docs/action-gateway.md omits registered $severity kinds: ${missing% }"
    [ -z "${extra// /}" ] || fail \
      "docs/action-gateway.md lists $severity kinds the registry does not register: ${extra% }"
  done
  pass "doc kind enumerations match the broker registry"
}

test_crash_replay_defaults_to_confirm_first() {
  local out digest
  reset_gw
  out=$(valid_request http.request confirm-first '' idem-crash nonce-crash worker-9 | run_worker prepare 2>&1)
  digest=$(kv_get "$out" digest)
  out=$(run_captain approve --digest "$digest" --approver-id captain-1 2>&1)
  assert_contains "$out" 'state=approved' "approved before simulated crash"

  python3 -c '
import json, sys
path, digest = sys.argv[1], sys.argv[2]
line = json.dumps({
  "ts": 1,
  "event": "executing",
  "state": "executing",
  "digest": digest,
  "request_id": "crash-sim",
  "decision": "confirm-first",
  "execution": "stubbed",
}, separators=(",", ":"), sort_keys=True) + "\n"
with open(path, "a", encoding="utf-8") as fh:
    fh.write(line)
' "$AUDIT" "$digest"

  out=$(run_worker status --digest "$digest" 2>&1)
  assert_contains "$out" 'state=unknown' "replay views executing as unknown"
  assert_contains "$out" 'decision=confirm-first' "posture confirm-first"

  out=$(run_captain replay 2>&1)
  assert_contains "$out" 'decision=confirm-first' "replay decision"
  assert_contains "$out" 'crash_unknown_recovered=1' "persisted recovery"
  out=$(run_worker status --digest "$digest" 2>&1)
  assert_contains "$out" 'state=unknown' "persisted unknown after replay"
  pass "crash replay defaults to confirm-first and recovers executing"
}

test_illegal_transition_forged_approved_refused() {
  local out rc
  reset_gw
  # Forge an approved event with no prepared predecessor.
  mkdir -p "$GW_ROOT"
  python3 -c '
import json, sys
path = sys.argv[1]
line = json.dumps({
  "ts": 1,
  "event": "approved",
  "state": "approved",
  "digest": "a" * 64,
  "request_id": "forged",
  "decision": "confirm-first",
  "approver_id": "attacker",
}, separators=(",", ":"), sort_keys=True) + "\n"
with open(path, "w", encoding="utf-8") as fh:
    fh.write(line)
' "$AUDIT"
  set +e
  out=$(run_worker status --digest "$(printf 'a%.0s' {1..64})" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "forged approved refused"
  assert_contains "$out" 'illegal transition' "state machine enforcement"
  pass "replay rejects forged approved without prepared"
}

test_idempotency_key_conflict() {
  local out rc
  reset_gw
  valid_request purchase confirm-first '"amount_cents": 100,' idem-same nonce-1 | run_worker prepare >/dev/null
  set +e
  out=$(valid_request purchase confirm-first '"amount_cents": 200,' idem-same nonce-2 | run_worker prepare 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "idempotency conflict exit"
  assert_contains "$out" 'idempotency_key reuse with differing digest' "conflict message"
  pass "idempotency key reuse with differing digest is refused"
}

test_overrides_require_test_mode() {
  local out rc
  set +e
  out=$(
    FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$DATA_DIR" \
      FM_ACTION_AUDIT_LOG="$AUDIT" \
      "$GW_SH" prepare 2>&1 <<'JSON'
{"task_id":"x"}
JSON
  )
  rc=$?
  set -e
  expect_code 1 "$rc" "override without test mode"
  assert_contains "$out" 'FM_ACTION_GATEWAY_TEST=1' "test mode required"
  pass "production path overrides require FM_ACTION_GATEWAY_TEST=1"
}

test_file_input_prepare() {
  local req out rc
  reset_gw
  req="$TMP/req.json"
  valid_request purchase confirm-first '"amount_cents": 50,' idem-file-1 nonce-file | cat > "$req"
  set +e
  out=$(run_worker --file "$req" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "--file exit"
  assert_contains "$out" 'decision=confirm-first' "--file decision"
  assert_contains "$out" 'state=prepared' "--file state"
  assert_not_contains "$out" 'approval_token=' "--file must not leak token"
  pass "--file input prepares without leaking approval_token"
}

test_audit_failure_yields_no_decision() {
  local out rc blocked
  blocked="$TMP/blocked-audit"
  mkdir -p "$blocked"
  set +e
  out=$(
    valid_request | FM_ACTION_GATEWAY_TEST=1 \
      FM_HOME="$HOME_DIR" FM_DATA_OVERRIDE="$DATA_DIR" \
      FM_ACTION_GATEWAY_ROOT="$GW_ROOT" \
      FM_ACTION_AUDIT_LOG="$blocked" \
      FM_ACTION_GATEWAY_ROLE=worker \
      FM_ACTION_CAPTAIN_SECRET="$SECRET" \
      "$GW_SH" prepare 2>&1
  )
  rc=$?
  set -e
  expect_code 1 "$rc" "audit failure exit"
  assert_not_contains "$out" 'decision=' "no decision when audit path is unusable"
  pass "failed audit write emits no decision"
}

test_no_outward_effect_codepaths() {
  local hits out digest
  set +e
  hits=$(
    grep -E \
      -e '\bcurl\b' -e '\bwget\b' -e '\bnc\b' -e '\bopenssl\s+s_client\b' \
      -e 'urllib\.request' -e 'http\.client' -e 'smtplib' -e 'socket\.create_connection' \
      -e 'subprocess\.' -e 'os\.system' -e 'requests\.' \
      "$GW_SH" || true
  )
  set -e
  [ -z "$hits" ] || fail "gateway source must not call outward effect primitives: $hits"

  reset_gw
  out=$(valid_request http.request confirm-first '' idem-noeff nonce-noeff worker-10 | run_worker prepare 2>&1)
  digest=$(kv_get "$out" digest)
  run_captain approve --digest "$digest" --approver-id captain-1 >/dev/null
  out=$(run_captain execute --digest "$digest" 2>&1)
  assert_contains "$out" 'execution-not-wired' "execute is stub"
  find "$TMP" -type f ! -path "$AUDIT" ! -path "$TMP/req.json" ! -path "$HOME_DIR/config/action-captain-secret" \
    ! -path "$GW_ROOT/*" 2>/dev/null \
    | grep -E 'mail|smtp|http-out|payment|egress' \
    && fail "unexpected egress artifact under temp root" || true
  pass "no code path performs a real outward effect"
}


test_device_ceiling_is_non_graduatable() {
  local out
  # Correction 7. An external kind with neither money nor a recipient used to
  # classify with no ceiling at all, and fm-order.sh graduates on exactly that
  # answer - so a device action could have been graduated out of per-change
  # approval. Customer hardware is not graduatable at any severity.
  out=$(run_worker classify --action-kind device.config.stage 2>&1)
  assert_contains "$out" 'severity=external' "staging is external"
  assert_contains "$out" 'ceiling=device' "staging carries the device ceiling"
  assert_contains "$out" 'graduatable=no' "staging cannot be graduated"

  # The same kind shape without a device prefix is unaffected.
  out=$(run_worker classify --action-kind sheet.write 2>&1)
  assert_contains "$out" 'graduatable=yes' "a non-device external kind is unchanged"

  # device.config.push previously reported ceiling=messaging, which mislabelled
  # every audit record and deck card for a device action.
  out=$(run_worker classify --action-kind device.config.push 2>&1)
  assert_contains "$out" 'ceiling=device' "push is labelled device, not messaging"
  assert_contains "$out" 'graduatable=no' "push stays non-graduatable"
  pass "every device kind carries a non-graduatable device ceiling"
}

test_broker_caps_approval_freshness() {
  local out rc
  reset_gw
  # Correction 5. A caller-chosen expiry with no ceiling lets a worker mint an
  # approval window that never goes stale, which defeats the requirement that
  # stale approval data stops with an honest state.
  set +e
  out=$(
    valid_request device.config.stage confirm-first '' idem-ttl nonce-ttl worker-ttl \
      | sed "s/\"expires_at\": [0-9]*/\"expires_at\": 4102444800/" \
      | run_worker prepare 2>&1
  )
  rc=$?
  set -e
  expect_code 1 "$rc" "over-ceiling expiry exit"
  assert_contains "$out" 'exceeds the broker ceiling' "refusal names the ceiling"
  assert_contains "$out" 'maximum 1800s' "refusal states the external maximum"

  # A request inside the ceiling still prepares normally.
  out=$(valid_request device.config.stage confirm-first '' idem-ttl2 nonce-ttl2 worker-ttl2 \
    | run_worker prepare 2>&1)
  assert_contains "$out" 'state=prepared' "an expiry inside the ceiling prepares"
  pass "the broker caps approval freshness per severity"
}

test_help_exits_zero
test_schema_rejects_missing_and_bad_fields
test_prepare_confirm_first_no_token_to_worker
test_requester_cannot_approve_own_request
test_worker_role_cannot_approve
test_wrong_captain_secret_refused
test_distinct_captain_approval_and_gate_check
test_atomic_concurrent_approve_single_winner
test_token_on_argv_rejected
test_expiry_refused
test_state_transitions_execute_stub_to_unknown
test_messaging_ceiling_non_graduatable
test_occ_registry_classifications
test_classify_graduatable_query
test_doc_kind_lists_match_registry
test_crash_replay_defaults_to_confirm_first
test_illegal_transition_forged_approved_refused
test_idempotency_key_conflict
test_overrides_require_test_mode
test_file_input_prepare
test_audit_failure_yields_no_decision
test_no_outward_effect_codepaths
test_device_ceiling_is_non_graduatable
test_broker_caps_approval_freshness
