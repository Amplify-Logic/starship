#!/usr/bin/env bash
# Behavior tests for gateway v2 Step 2 sub-order items 1 through 4.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GW="$ROOT/bin/fm-action-gateway-v2.py"
TMP=$(fm_test_tmproot fm-action-gateway-v2)
export FM_ACTION_GATEWAY_TEST=1
export TMPDIR="$TMP/runtime"
mkdir -p "$TMPDIR"
trap 'if [ -n "${SERVER_PID:-}" ]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi; rm -rf "$TMP"' EXIT

request() {
  local task=${1:-job-one} idem=${2:-idem-one} nonce=${3:-caller-nonce-one} params=${4:-'"recipient":"captain@exämple.test","subject":"Hello","body":"Exact bytes"'}
  cat <<JSON
{"task_id":"$task","domain":"synthetic","action_kind":"email.send","target":"smtp://münich.example.test","parameters":{$params},"requested_consent_tier":"confirm-first","environment":"test","policy_version":"v2","idempotency_key":"$idem","expires_at":1893456000,"nonce":"$nonce","requester_id":"worker-claim-is-not-authority"}
JSON
}

kv_get() {
  local blob=$1 key=$2
  printf '%s\n' "$blob" | awk -F= -v key="$key" '$1==key {print substr($0,index($0,"=")+1); exit}'
}

reset_gateway() {
  rm -rf "$TMPDIR/fm-gateway-v2-state"
}

run_prepare() {
  "$GW" prepare
}

test_help_and_old_broker_untouched() {
  local help landed=054aa7f
  help=$($GW --help)
  assert_contains "$help" 'sub-order items 1 through 4' "help scope"
  assert_contains "$help" 'no outward executor' "help execution boundary"
  git -C "$ROOT" cat-file -e "$landed^{commit}" 2>/dev/null || fail "landed broker commit $landed must be reachable"
  git -C "$ROOT" diff --quiet "$landed" -- bin/fm-action-gateway.sh || fail "landed broker must remain untouched since $landed"
  pass "gateway v2 is separate and the landed broker remains untouched since $landed"
}

test_strict_parser_rejections() {
  local out rc deep
  reset_gateway

  set +e
  out=$(printf '%s' '{"task_id":"one","task_id":"two"}' | run_prepare 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "duplicate key"
  assert_contains "$out" 'duplicate key refused' "duplicate key message"

  set +e
  out=$(request | python3 -c 'import json,sys; value=json.load(sys.stdin); value["unknown"]=1; print(json.dumps(value))' | run_prepare 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "unknown key"
  assert_contains "$out" 'unknown ActionRequest keys' "unknown key message"

  for number in '1.0' '1e2' 'NaN' 'Infinity'; do
    set +e
    out=$(request job-number "idem-${number//[^A-Za-z0-9]/x}" nonce-number '"recipient":"a@example.test","amount_minor":'"$number"',"currency":"USD"' | run_prepare 2>&1)
    rc=$?
    set -e
    expect_code 1 "$rc" "number $number"
  done

  set +e
  out=$(request job-money idem-money nonce-money '"recipient":"a@example.test","amount_minor":100,"amount_cents":100,"currency":"USD"' | run_prepare 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "ambiguous money"
  assert_contains "$out" 'ambiguous money' "ambiguous money message"

  set +e
  out=$(request job-string-money idem-string-money nonce-string-money '"recipient":"a@example.test","amount_minor":"1.00","currency":"USD"' | run_prepare 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "string money"
  assert_contains "$out" 'integer minor-unit' "string money message"

  deep=$(python3 - <<'PY'
import json
value = "bottom"
for _ in range(20):
    value = [value]
print(json.dumps(value))
PY
)
  set +e
  out=$(printf '%s' "$deep" | run_prepare 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "deep JSON"
  assert_contains "$out" 'nesting exceeds' "depth message"

  set +e
  out=$(python3 -c 'import sys; sys.stdout.write("{" + "X" * 70000)' | run_prepare 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "oversized request"
  assert_contains "$out" 'request exceeds' "size message"

  set +e
  out=$(printf '%s' '{"x":"\ud800"}' | run_prepare 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "unpaired surrogate"
  assert_contains "$out" 'surrogate refused' "surrogate message"
  pass "strict parser rejects duplicate, unknown, noncanonical numeric, ambiguous money, depth, size, and Unicode hazards"
}

test_canonicalization_matches_rfc8785() {
  python3 - "$GW" <<'PY' || fail "canonicalization must match the RFC 8785 sorting sample"
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("gw", sys.argv[1])
gateway = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gateway)

# RFC 8785 section 3.2.3. The U+FB33 and U+1F600 pair is the reason the RFC
# mandates UTF-16 code-unit ordering: code-point ordering sorts them the other
# way, so a canonicalizer that sorts by code point produces a different digest.
sample = {
    "\u20ac": "Euro Sign",
    "\r": "Carriage Return",
    "\ufb33": "Hebrew Letter Dalet With Dagesh",
    "1": "One",
    "\U0001f600": "Emoji: Grinning Face",
    "\u0080": "Control",
    "\u00f6": "Latin Small Letter O With Diaeresis",
}
rfc_order = ["\r", "1", "\u0080", "\u00f6", "\u20ac", "\U0001f600", "\ufb33"]
assert sorted(sample) != rfc_order, "sample must actually discriminate the two orderings"
expected = "{" + ",".join(
    "%s:%s" % (gateway.jcs_string(key), gateway.jcs_string(sample[key])) for key in rfc_order
) + "}"
assert gateway.jcs(sample) == expected, gateway.jcs(sample)

# The digest must bind the canonical form, not the caller's key order.
plan = {"schema": "fm.execution-plan.v2", "job_id": "demo", "recipients": ["a@example.test"]}
shuffled = {"recipients": ["a@example.test"], "schema": "fm.execution-plan.v2", "job_id": "demo"}
assert gateway.canonical_bytes(plan) == gateway.canonical_bytes(shuffled)

for outside in (2 ** 53, float("nan"), 1.5):
    try:
        gateway.jcs(outside)
    except gateway.GatewayError:
        continue
    raise AssertionError("jcs accepted a value outside the RFC 8785 subset: %r" % (outside,))
PY
  pass "canonicalization matches the RFC 8785 UTF-16 sorting sample and binds the digest"
}

test_closed_plan_resolution() {
  local out digest request_id database
  reset_gateway
  out=$(request | run_prepare)
  digest=$(kv_get "$out" digest)
  request_id=$(kv_get "$out" request_id)
  [ "${#digest}" -eq 64 ] || fail "plan digest must be SHA-256"
  [ "${#request_id}" -eq 32 ] || fail "request ID must be broker-generated"
  database=$($GW inspect-test-paths | python3 -c 'import json,sys; print(json.load(sys.stdin)["database"])')
  python3 - "$database" "$digest" "$(id -u)" <<'PY'
import base64
import hashlib
import json
import sqlite3
import sys

database, digest, uid = sys.argv[1], sys.argv[2], int(sys.argv[3])
db = sqlite3.connect(database)
db.row_factory = sqlite3.Row
row = db.execute("SELECT * FROM requests WHERE digest=?", (digest,)).fetchone()
assert row is not None
plan = json.loads(row["plan_jcs"])
assert plan["schema"] == "fm.execution-plan.v2"
assert plan["provider_account"] == {
    "account_id": "safe-sink:test-only",
    "environment": "test-disabled-outward",
    "provider": "firstmate-local-safe-sink",
}
assert plan["endpoint"]["host_punycode"] == "xn--mnich-kva.example.test"
assert plan["method"] == "SAFE_SINK_APPEND"
assert plan["money"] == {"amount_minor": None, "currency": None}
assert plan["recipient_count"] == 1
assert plan["recipients"][0]["punycode"] == "captain@xn--exmple-cua.test"
assert base64.b64decode(plan["message"]["body_bytes_b64"]) == b"Exact bytes"
assert plan["message"]["body_sha256"] == hashlib.sha256(b"Exact bytes").hexdigest()
assert plan["attachment_count"] == 0
assert plan["redirect_policy"] == {"maximum": 0, "mode": "deny"}
assert plan["resource_limits"]["request_bytes"] == 65536
assert len(plan["policy_manifest_hash"]) == 64
assert len(plan["executor"]["sha256"]) == 64
assert plan["executor"]["outward_execution"] is False
assert plan["executor"]["kind"].startswith("disabled-safe-sink")
assert plan["requester"]["peer_uid"] == uid
assert plan["requester"]["authority_from_request"] is False
assert plan["compatibility_hints"]["self_declared_requester_ignored"] is True
assert plan["broker_nonce"] != "caller-nonce-one"
assert plan["expires_at"] - plan["prepared_at"] == 300
assert row["request_id"] == plan["request_id"]
assert row["broker_nonce"] == plan["broker_nonce"]
PY
  pass "server resolves every closed-plan field and ignores caller authority, nonce, and expiry"
}

test_sqlite_uniqueness_replay_concurrency_and_tombstones() {
  local out digest database winners rc1 rc2
  reset_gateway
  out=$(request job-replay idem-replay nonce-replay | run_prepare)
  digest=$(kv_get "$out" digest)

  set +e
  out=$(request job-replay idem-replay nonce-replay | run_prepare 2>&1)
  rc1=$?
  set -e
  expect_code 1 "$rc1" "exact replay"
  assert_contains "$out" 'idempotency key replay refused' "replay refusal"

  set +e
  out=$(request job-other idem-replay nonce-other | run_prepare 2>&1)
  rc1=$?
  set -e
  expect_code 1 "$rc1" "idempotency conflict"

  request job-race idem-race nonce-race >"$TMP/race-request.json"
  set +e
  run_prepare <"$TMP/race-request.json" >"$TMP/race-a" 2>&1 &
  local pid_a=$!
  run_prepare <"$TMP/race-request.json" >"$TMP/race-b" 2>&1 &
  local pid_b=$!
  wait "$pid_a"; rc1=$?
  wait "$pid_b"; rc2=$?
  set -e
  winners=0
  [ "$rc1" -eq 0 ] && winners=$((winners + 1))
  [ "$rc2" -eq 0 ] && winners=$((winners + 1))
  [ "$winners" -eq 1 ] || fail "concurrent prepare must have one winner, got $winners"

  database=$($GW inspect-test-paths | python3 -c 'import json,sys; print(json.load(sys.stdin)["database"])')
  python3 - "$database" <<'PY'
import sqlite3
import sys

db = sqlite3.connect(sys.argv[1])
required = {
    "requests",
    "request_id_tombstones",
    "nonce_tombstones",
    "idempotency_tombstones",
    "challenges",
    "approvals",
    "capabilities",
    "token_consumptions",
    "audit_events",
}
tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
assert required <= tables
for table in ("requests", "request_id_tombstones", "nonce_tombstones", "idempotency_tombstones", "challenges", "approvals", "capabilities", "token_consumptions"):
    indexes = list(db.execute(f"PRAGMA index_list({table})"))
    assert any(row[2] for row in indexes), (table, indexes)
assert db.execute("SELECT COUNT(*) FROM request_id_tombstones").fetchone()[0] == 2
assert db.execute("SELECT COUNT(*) FROM nonce_tombstones").fetchone()[0] == 2
assert db.execute("SELECT COUNT(*) FROM idempotency_tombstones").fetchone()[0] == 2
PY

  rm -f "$TMPDIR/fm-gateway-v2-state/audit-v2.jsonl"
  out=$($GW status --digest "$digest")
  assert_contains "$out" 'state=prepared' "state survives audit rotation"
  set +e
  request job-replay idem-replay nonce-replay | run_prepare >"$TMP/post-rotate" 2>&1
  rc1=$?
  set -e
  expect_code 1 "$rc1" "replay after audit rotation"
  pass "SQLite transactions enforce concurrent uniqueness and durable tombstones survive audit rotation"
}

test_crash_recovery_marks_unknown() {
  local out digest database
  reset_gateway
  out=$(request job-crash idem-crash nonce-crash | run_prepare)
  digest=$(kv_get "$out" digest)
  $GW test-mark-executing --digest "$digest"
  out=$($GW status --digest "$digest")
  assert_contains "$out" 'state=unknown' "interrupted execution state"
  database=$($GW inspect-test-paths | python3 -c 'import json,sys; print(json.load(sys.stdin)["database"])')
  python3 - "$database" "$digest" <<'PY'
import sqlite3
import sys

db = sqlite3.connect(sys.argv[1])
row = db.execute("SELECT state,reconciliation_required FROM requests WHERE digest=?", (sys.argv[2],)).fetchone()
assert row == ("unknown", 1), row
count = db.execute("SELECT COUNT(*) FROM audit_events WHERE event_type='execution-uncertain'").fetchone()[0]
assert count == 1, count
PY
  pass "restart recovery durably changes executing to unknown and requires reconciliation"
}

rpc() {
  local socket_path=$1 payload=$2
  python3 - "$socket_path" "$payload" <<'PY'
import json
import socket
import struct
import sys

path, payload = sys.argv[1:]
body = payload.encode()
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(path)
sock.sendall(struct.pack("!I", len(body)) + body)
header = sock.recv(4)
assert len(header) == 4
length = struct.unpack("!I", header)[0]
response = bytearray()
while len(response) < length:
    chunk = sock.recv(length - len(response))
    assert chunk
    response.extend(chunk)
print(response.decode())
PY
}

stall_then_rpc() {
  local socket_path=$1 payload=$2
  python3 - "$socket_path" "$payload" <<'PY'
import socket
import struct
import sys

path, payload = sys.argv[1:]
stalled = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
stalled.connect(path)
stalled.sendall(b"\x00\x00")
body = payload.encode()
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(30)
sock.connect(path)
sock.sendall(struct.pack("!I", len(body)) + body)
header = sock.recv(4)
assert len(header) == 4
length = struct.unpack("!I", header)[0]
response = bytearray()
while len(response) < length:
    chunk = sock.recv(length - len(response))
    assert chunk
    response.extend(chunk)
stalled.close()
sock.close()
print(response.decode())
PY
}

envelope_for() {
  local capability=$1 request_json=$2 idem=$3 nonce=$4 target=${5:-}
  python3 - "$capability" "$request_json" "$idem" "$nonce" "$target" <<'PY'
import json
import sys

capability, request_json, idem, nonce, target = sys.argv[1:]
action = json.loads(request_json)
action["idempotency_key"] = idem
action["nonce"] = nonce
if target:
    action["target"] = target
print(json.dumps({"schema": "fm.prepare.v2", "capability": capability, "action": action}, separators=(",", ":")))
PY
}

issue_cap() {
  local purpose=$1 job=$2 uid=${3:-$(id -u)}
  $GW issue-capability --purpose "$purpose" --job-id "$job" --uid "$uid" | awk -F= '$1=="capability" {print $2}'
}

test_distinct_peer_credential_protocols() {
  local cap bad_cap approval_cap execution_cap request_json prepare_payload response request_id digest
  reset_gateway
  SOCKET_ROOT="$TMP/sockets"
  mkdir -p "$SOCKET_ROOT"
  $GW serve --socket-root "$SOCKET_ROOT" >"$TMP/server.out" 2>"$TMP/server.err" &
  SERVER_PID=$!
  for _ in $(seq 1 250); do
    grep -q 'fm.gateway-listeners.v2' "$TMP/server.out" 2>/dev/null && break
    sleep 0.02
  done
  grep -q 'fm.gateway-listeners.v2' "$TMP/server.out" 2>/dev/null || fail "server never advertised readiness: $(cat "$TMP/server.err")"
  for channel in prepare approval execution; do
    [ -S "$SOCKET_ROOT/$channel.sock" ] || fail "$channel socket missing after advertised readiness: $(cat "$TMP/server.err")"
  done

  cap=$(issue_cap prepare socket-job)
  bad_cap=$(issue_cap prepare socket-job "$(( $(id -u) + 1 ))")
  approval_cap=$(issue_cap approval socket-job)
  execution_cap=$(issue_cap execution socket-job)
  request_json=$(request socket-job socket-idem socket-nonce)
  prepare_payload=$(python3 - "$cap" "$request_json" <<'PY'
import json
import sys
print(json.dumps({"schema":"fm.prepare.v2","capability":sys.argv[1],"action":json.loads(sys.argv[2])}, separators=(",", ":")))
PY
)
  response=$(rpc "$SOCKET_ROOT/prepare.sock" "$prepare_payload")
  request_id=$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["request_id"])')
  digest=$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["digest"])')
  [ -n "$request_id" ] && [ -n "$digest" ] || fail "prepare protocol must resolve a request"

  response=$(rpc "$SOCKET_ROOT/prepare.sock" "{\"schema\":\"fm.prepare.v2\",\"capability\":\"$bad_cap\",\"action\":$request_json}")
  assert_contains "$response" 'capability does not match protocol purpose and peer credentials' "peer UID binding"

  response=$(rpc "$SOCKET_ROOT/approval.sock" "$prepare_payload")
  assert_contains "$response" 'unknown approval envelope keys' "schema cannot cross sockets"

  local challenge_payload
  challenge_payload="{\"schema\":\"fm.approval.v2\",\"op\":\"challenge\",\"capability\":\"$approval_cap\",\"request_id\":\"$request_id\",\"ui_id\":\"test-ui\"}"
  response=$(rpc "$SOCKET_ROOT/approval.sock" "$challenge_payload")
  assert_contains "$response" 'challenge-issued' "approval challenge"
  assert_contains "$response" 'secure-signature-verifier-is-step-2.5' "signature boundary"

  local approve_payload
  approve_payload="{\"schema\":\"fm.approval.v2\",\"op\":\"approve\",\"capability\":\"$approval_cap\",\"request_id\":\"$request_id\",\"ui_id\":\"test-ui\",\"challenge_id\":\"not-authority\",\"signature\":\"not-authority\"}"
  response=$(rpc "$SOCKET_ROOT/approval.sock" "$approve_payload")
  assert_contains "$response" 'approval submission disabled' "unsigned approval refused"

  local execution_payload
  execution_payload="{\"schema\":\"fm.execution.v2\",\"capability\":\"$execution_cap\",\"request_id\":\"$request_id\",\"idempotency_key\":\"socket-idem\"}"
  response=$(rpc "$SOCKET_ROOT/execution.sock" "$execution_payload")
  assert_contains "$response" 'requires a signed approved immutable plan' "execution state binding"

  local crafted_payload survivor_payload
  crafted_payload=$(envelope_for "$cap" "$request_json" socket-idem-crafted socket-nonce-crafted 'https://[::1')
  response=$(rpc "$SOCKET_ROOT/prepare.sock" "$crafted_payload")
  assert_contains "$response" 'target is not a parseable URL' "crafted target is a refusal, not a crash"

  survivor_payload=$(envelope_for "$cap" "$request_json" socket-idem-survivor socket-nonce-survivor)
  response=$(stall_then_rpc "$SOCKET_ROOT/prepare.sock" "$survivor_payload")
  assert_contains "$response" '"ok":true' "channel survives a crafted target and a stalled client"

  kill "$SERVER_PID"
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=
  pass "prepare, approval, and execution schemas are socket-separated and bound to peer UID plus per-job capabilities"
}

test_regression_pack_gateway_expectations() {
  local report rc
  reset_gateway
  report="$TMP/v2-regression.json"
  set +e
  TMPDIR=/tmp "$ROOT/bin/fm-worker-boundary-regression.sh" --target ambient --gateway "$GW" --report "$report" >"$TMP/v2-pack.out" 2>"$TMP/v2-pack.err"
  rc=$?
  set -e
  expect_code 1 "$rc" "ambient boundary remains red outside gateway"
  [ ! -s "$TMP/v2-pack.err" ] || fail "v2 pack adapter failed: $(cat "$TMP/v2-pack.err")"
  python3 - "$report" <<'PY'
import json
import sys
records = {item["probe"]: item for item in json.load(open(sys.argv[1], encoding="utf-8"))["records"]}
assert records["gateway.actionrequest-malformed"]["actual"] == "REJECTED"
assert records["gateway.actionrequest-replayed"]["actual"] == "REJECTED"
assert records["gateway.actionrequest-oversized"]["actual"] == "REJECTED"
assert records["gateway.actionrequest-flooded"]["actual"] == "RATE_LIMITED"
assert records["recovery.crash-restart"]["actual"] == "STATE_PRESERVED"
for probe in ("gateway.database-read", "gateway.inbox-read", "gateway.audit-write"):
    assert records[probe]["actual"] != "NO_CANARY", (probe, records[probe])
PY
  pass "gateway v2 satisfies the Step 1 malformed, replay, oversized, flooded, and restart expectations"
}

test_production_direct_adapter_refused() {
  local out rc
  reset_gateway
  set +e
  out=$(env -u FM_ACTION_GATEWAY_TEST TMPDIR="$TMP/no-production-state" "$GW" prepare 2>&1 <<'JSON'
{}
JSON
)
  rc=$?
  set -e
  expect_code 1 "$rc" "production direct prepare"
  assert_contains "$out" 'direct prepare is test-only' "production uses socket"
  [ ! -e "$TMP/no-production-state/fm-gateway-v2-state" ] || fail "production must not redirect state through TMPDIR"
  pass "production refuses the direct test adapter and has no caller-selected trust-state root"
}

test_help_and_old_broker_untouched
test_strict_parser_rejections
test_canonicalization_matches_rfc8785
test_closed_plan_resolution
test_sqlite_uniqueness_replay_concurrency_and_tombstones
test_crash_recovery_marks_unknown
test_distinct_peer_credential_protocols
test_regression_pack_gateway_expectations
test_production_direct_adapter_refused
