#!/usr/bin/env bash
# Behavior tests for gateway v2 Step 2 sub-order items 1 through 6.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GW="$ROOT/bin/fm-action-gateway-v2.py"
SINK="$ROOT/bin/fm-action-safe-sink-v2.py"
RUNNER="$ROOT/bin/fm-action-runner-v2.py"
TMP=$(fm_test_tmproot fm-action-gateway-v2)
export FM_ACTION_GATEWAY_TEST=1
export TMPDIR="$TMP/runtime"
mkdir -p "$TMPDIR"
# The peer-credential case binds real AF_UNIX sockets, whose path is capped at
# 104 bytes on macOS and 108 on Linux. The shared fixture root resolves TMPDIR
# to its physical path, which on macOS prefixes /private and leaves no room for
# a channel socket underneath it, so the sockets get their own short root and
# the same EXIT trap removes it.
SOCKET_TMP=$(mktemp -d /tmp/fm-gw2.XXXXXX)
trap 'if [ -n "${SERVER_PID:-}" ]; then kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; fi; rm -rf "$TMP" "$SOCKET_TMP"' EXIT

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
  # Two roots, because the broker owns one and the executor owns the other.
  chmod -R u+rwX "$TMPDIR/fm-gateway-v2-sink" 2>/dev/null || true
  rm -rf "$TMPDIR/fm-gateway-v2-state" "$TMPDIR/fm-gateway-v2-sink"
}

sink_root() {
  $GW inspect-test-paths | python3 -c 'import json,sys; print(json.load(sys.stdin)["sink_root"])'
}

run_prepare() {
  "$GW" prepare
}

test_help_and_old_broker_separate() {
  local help
  help=$($GW --help)
  assert_contains "$help" 'sub-order items 1 through 6' "help scope"
  assert_contains "$help" 'Nothing here performs an outward action' "help execution boundary"
  # v2 is a separate program, not a rewrite of the landed broker: neither script
  # names the other, so v2 can neither delegate to nor be reached from the
  # landed confirm-first broker. This used to be a whole-file freeze of
  # bin/fm-action-gateway.sh against its landing commit, which made this file a
  # veto on every later change to the landed broker. The landed broker's own
  # behaviour - its registry, privilege separation, and stubbed executor - is
  # owned by tests/fm-action-gateway.test.sh, so separation is all this asserts.
  ! grep -q 'fm-action-gateway-v2' "$ROOT/bin/fm-action-gateway.sh" \
    || fail "the landed broker must not reference gateway v2"
  ! grep -q 'fm-action-gateway\.sh' "$GW" \
    || fail "gateway v2 must not reference the landed broker"
  pass "gateway v2 is a program separate from the landed broker"
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
assert plan["executor"]["kind"] == "deterministic-safe-sink"
assert plan["executor"]["program"] == "fm-action-safe-sink-v2.py"
assert plan["device"] is None
assert plan["ceiling"] is None
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

# A capability is handed to the runner as its own argv word, so no issued token
# may be readable as an option. Base64url tokens began with '-' about one time
# in 64, and argparse then refused the documented --capability TOKEN form.
test_issued_capabilities_are_never_option_like() {
  local cap _
  reset_gateway
  for _ in 1 2 3 4 5 6 7 8; do
    cap=$(issue_cap execution argv-job)
    printf '%s' "$cap" | grep -Eq '^[A-Za-z0-9]+$' \
      || fail "issued capability can be misread as a command-line option: $cap"
  done
  pass "every issued capability is a plain argv word the runner can never read as an option"
}

test_distinct_peer_credential_protocols() {
  local cap bad_cap approval_cap execution_cap request_json prepare_payload response request_id digest
  reset_gateway
  SOCKET_ROOT="$SOCKET_TMP/s"
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
  assert_contains "$response" '"approval_enabled":true' "approval submission is live"
  assert_contains "$response" 'canonical transcript bytes' "the approver signs the exact transcript"

  local approve_payload
  approve_payload="{\"schema\":\"fm.approval.v2\",\"op\":\"approve\",\"capability\":\"$approval_cap\",\"request_id\":\"$request_id\",\"ui_id\":\"test-ui\",\"challenge_id\":\"not-authority\",\"approver_id\":\"nobody\",\"signature\":\"AAAA\"}"
  response=$(rpc "$SOCKET_ROOT/approval.sock" "$approve_payload")
  assert_contains "$response" 'unknown challenge for this request' "approval must name the issued challenge"

  approve_payload="{\"schema\":\"fm.approval.v2\",\"op\":\"approve\",\"capability\":\"$approval_cap\",\"request_id\":\"$request_id\",\"ui_id\":\"test-ui\"}"
  response=$(rpc "$SOCKET_ROOT/approval.sock" "$approve_payload")
  assert_contains "$response" 'approval submission requires challenge_id' "an unsigned approval is refused"

  local execution_payload
  execution_payload="{\"schema\":\"fm.execution.v2\",\"op\":\"claim\",\"capability\":\"$execution_cap\",\"request_id\":\"$request_id\",\"idempotency_key\":\"socket-idem\"}"
  response=$(rpc "$SOCKET_ROOT/execution.sock" "$execution_payload")
  assert_contains "$response" 'requires a signed approved immutable plan' "execution state binding"

  execution_payload="{\"schema\":\"fm.execution.v2\",\"op\":\"settle\",\"capability\":\"$execution_cap\",\"request_id\":\"$request_id\",\"lease\":\"not-a-lease\",\"outcome\":\"succeeded\"}"
  response=$(rpc "$SOCKET_ROOT/execution.sock" "$execution_payload")
  assert_contains "$response" 'settle refused: request is prepared, not executing' "settle cannot invent an execution"

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

device_request() {
  local task=${1:-dev-job} idem=${2:-dev-idem} nonce=${3:-dev-nonce} settings=${4:-} eligibility=${5:-unverified}
  if [ -z "$settings" ]; then
    settings='{"key":"synthetic_setting_a","requested_raw":135,"encoding":"synthetic-declared-encoding-a","encoding_confirmed":true,"encoding_evidence":"fixture://observed-row-a","decoded_value":"13.5","unit":"synthetic-unit"}'
  fi
  cat <<JSON
{"task_id":"$task","domain":"synthetic","action_kind":"device.config.stage","target":"https://portal.example.test/commands","parameters":{"device":{"identifier_kind":"portal-device-id","identifier":"SYNTHETIC-DEVICE-0001","settings":[$settings],"eligibility":{"status":"$eligibility","evidence_ref":"fixture://no-read-authorized"},"preview_hash":"0000000000000000000000000000000000000000000000000000000000000000"}},"requested_consent_tier":"confirm-first","environment":"test","policy_version":"v2","idempotency_key":"$idem","expires_at":1893456000,"nonce":"$nonce","requester_id":"worker-claim-is-not-authority"}
JSON
}

gateway_database() {
  $GW inspect-test-paths | python3 -c 'import json,sys; print(json.load(sys.stdin)["database"])'
}

# Sign the exact canonical transcript the broker recomputes, exactly as a real
# signing UI would: the signer canonicalizes with the same rule the broker uses,
# because a signature over differently-serialized bytes is a signature over a
# different document.
sign_transcript() {
  local transcript_json=$1 secret=$2
  python3 - "$ROOT/bin/fm-action-gateway-v2.py" "$transcript_json" "$secret" <<'PY'
import base64
import hashlib
import hmac
import importlib.util
import json
import sys

module_path, transcript_json, secret = sys.argv[1:]
spec = importlib.util.spec_from_file_location("fm_gateway_v2", module_path)
gateway = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gateway)
encoded = gateway.canonical_bytes(json.loads(transcript_json))
print(base64.b64encode(hmac.new(base64.b64decode(secret), encoded, hashlib.sha256).digest()).decode())
PY
}

new_secret() {
  python3 -c 'import base64, os; print(base64.b64encode(os.urandom(32)).decode())'
}

# One short fixed socket directory per suite run. AF_UNIX paths are capped at
# 104 bytes on Darwin, and a per-test directory name pushes a temp root over it.
start_server() {
  SOCKET_ROOT="$TMP/sk"
  [ -n "${TMP:-}" ] || fail "socket root needs the suite temp root"
  if [ -d "$SOCKET_ROOT" ]; then
    find "$SOCKET_ROOT" -mindepth 1 -delete
  fi
  mkdir -p "$SOCKET_ROOT"
  $GW serve --socket-root "$SOCKET_ROOT" >"$TMP/server-$1.out" 2>"$TMP/server-$1.err" &
  SERVER_PID=$!
  for _ in $(seq 1 250); do
    grep -q 'fm.gateway-listeners.v2' "$TMP/server-$1.out" 2>/dev/null && return 0
    sleep 0.02
  done
  fail "server never advertised readiness: $(cat "$TMP/server-$1.err")"
}

stop_server() {
  [ -n "${SERVER_PID:-}" ] || return 0
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=
}

json_field() {
  local blob=$1 expression=$2
  printf '%s' "$blob" | python3 -c "import json,sys; value=json.load(sys.stdin); print($expression)"
}

test_device_plan_preserves_the_exact_request() {
  local out rc digest database
  reset_gateway

  out=$(device_request | run_prepare)
  digest=$(kv_get "$out" digest)
  [ "${#digest}" -eq 64 ] || fail "device action must resolve a closed plan"
  database=$(gateway_database)
  python3 - "$database" "$digest" <<'PY'
import json
import sqlite3
import sys

db = sqlite3.connect(sys.argv[1])
db.row_factory = sqlite3.Row
row = db.execute("SELECT plan_jcs FROM requests WHERE digest=?", (sys.argv[2],)).fetchone()
plan = json.loads(row["plan_jcs"])
device = plan["device"]
# The exact integer the caller asked for reaches the plan untouched. No band, no
# floor, no corrective rounding: a value the gateway changed is a value nobody
# approved.
assert device["settings"][0]["requested_raw"] == 135, device
assert device["settings"][0]["encoding"] == "synthetic-declared-encoding-a", device
assert device["settings"][0]["encoding_confirmed"] is True, device
assert device["settings"][0]["decoded_value"] == "13.5", device
# The declared reading is carried for the approver to see and is labelled as the
# caller's claim, never as something the gateway verified.
assert device["settings"][0]["decoded_value_source"] == "caller-declared", device
assert device["eligibility"]["status"] == "unverified", device
assert device["preview_hash"] == "0" * 64, device
assert device["preview_reverification_required"] is True, device
assert device["ceiling"] == "device", device
assert device["graduatable"] is False, device
assert plan["ceiling"] == "device", plan
assert plan["money"] == {"amount_minor": None, "currency": None}, plan
assert plan["recipients"] == [], plan
PY

  set +e
  out=$(device_request job-unconfirmed idem-unconfirmed nonce-unconfirmed \
    '{"key":"synthetic_setting_a","requested_raw":135,"encoding":"synthetic-declared-encoding-a","encoding_confirmed":false,"encoding_evidence":"fixture://none","decoded_value":"13.5","unit":"synthetic-unit"}' | run_prepare 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "unconfirmed encoding"
  assert_contains "$out" 'encoding is not confirmed' "a setting whose encoding is unconfirmed cannot be staged"

  set +e
  out=$(device_request job-dup idem-dup nonce-dup \
    '{"key":"same","requested_raw":1,"encoding":"e","encoding_confirmed":true,"encoding_evidence":"fixture://a","decoded_value":"1","unit":"u"},{"key":"same","requested_raw":2,"encoding":"e","encoding_confirmed":true,"encoding_evidence":"fixture://a","decoded_value":"2","unit":"u"}' | run_prepare 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "duplicate setting key"
  assert_contains "$out" 'duplicate device setting key refused' "a duplicate key would make the approved value ambiguous"

  set +e
  out=$(device_request job-float idem-float nonce-float \
    '{"key":"a","requested_raw":13.5,"encoding":"e","encoding_confirmed":true,"encoding_evidence":"fixture://a","decoded_value":"13.5","unit":"u"}' | run_prepare 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "non-integer wire value"

  set +e
  out=$(device_request | python3 -c 'import json,sys; v=json.load(sys.stdin); v["parameters"]["recipient"]="a@example.test"; v["idempotency_key"]="idem-mixed"; print(json.dumps(v))' | run_prepare 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "device plus messaging"
  assert_contains "$out" 'device actions refuse money and messaging parameters' "a device plan has no messaging payload"

  set +e
  out=$(request job-devparam idem-devparam nonce-devparam '"recipient":"a@example.test","device":{"identifier_kind":"portal-device-id","identifier":"x","settings":[],"eligibility":{"status":"observed","evidence_ref":"r"},"preview_hash":"0"}' | run_prepare 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "device payload on a messaging action"
  assert_contains "$out" 'device payload refused on a non-device action kind' "only a device kind carries a device payload"

  set +e
  out=$(device_request job-elig idem-elig nonce-elig '' assumed 2>/dev/null | run_prepare 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "invented eligibility status"

  pass "a device action resolves a closed plan that preserves the exact wire value, confirmed encoding, and honest eligibility"
}

test_approval_requires_a_verified_signature() {
  local out digest request_id secret approval_cap response transcript challenge_id signature database
  reset_gateway
  out=$(device_request approve-job approve-idem approve-nonce | run_prepare)
  digest=$(kv_get "$out" digest)
  request_id=$(kv_get "$out" request_id)
  secret=$(new_secret)
  $GW enroll-approver --approver-id test-ui --algorithm hmac-sha256-test --key-material "$secret" >/dev/null
  $GW enroll-approver --approver-id retired-ui --algorithm hmac-sha256-test --key-material "$(new_secret)" >/dev/null
  $GW revoke-approver --approver-id retired-ui >/dev/null

  start_server approval
  approval_cap=$(issue_cap approval approve-job)
  response=$(rpc "$SOCKET_ROOT/approval.sock" "{\"schema\":\"fm.approval.v2\",\"op\":\"challenge\",\"capability\":\"$approval_cap\",\"request_id\":\"$request_id\",\"ui_id\":\"test-ui\"}")
  transcript=$(json_field "$response" 'json.dumps(value["result"]["transcript"])')
  challenge_id=$(json_field "$response" 'value["result"]["challenge_id"]')

  response=$(rpc "$SOCKET_ROOT/approval.sock" "{\"schema\":\"fm.approval.v2\",\"op\":\"approve\",\"capability\":\"$(issue_cap approval approve-job)\",\"request_id\":\"$request_id\",\"ui_id\":\"test-ui\",\"challenge_id\":\"$challenge_id\",\"approver_id\":\"test-ui\",\"signature\":\"$(printf 'A%.0s' $(seq 1 44))\"}")
  assert_contains "$response" 'approval signature does not verify' "a wrong signature cannot approve"
  out=$($GW status --digest "$digest")
  assert_contains "$out" 'state=prepared' "a refused signature leaves the request unapproved"

  signature=$(sign_transcript "$transcript" "$secret")
  response=$(rpc "$SOCKET_ROOT/approval.sock" "{\"schema\":\"fm.approval.v2\",\"op\":\"approve\",\"capability\":\"$(issue_cap approval approve-job)\",\"request_id\":\"$request_id\",\"ui_id\":\"test-ui\",\"challenge_id\":\"$challenge_id\",\"approver_id\":\"retired-ui\",\"signature\":\"$signature\"}")
  assert_contains "$response" 'approver is revoked' "a revoked approver cannot approve"

  response=$(rpc "$SOCKET_ROOT/approval.sock" "{\"schema\":\"fm.approval.v2\",\"op\":\"approve\",\"capability\":\"$(issue_cap approval approve-job)\",\"request_id\":\"$request_id\",\"ui_id\":\"test-ui\",\"challenge_id\":\"$challenge_id\",\"approver_id\":\"test-ui\",\"signature\":\"$signature\"}")
  assert_contains "$response" '"state":"approved"' "a verified signature over the exact transcript approves"
  assert_contains "$response" '"approver_authenticity_proved":false' "the software test class never claims approver authenticity"

  response=$(rpc "$SOCKET_ROOT/approval.sock" "{\"schema\":\"fm.approval.v2\",\"op\":\"approve\",\"capability\":\"$(issue_cap approval approve-job)\",\"request_id\":\"$request_id\",\"ui_id\":\"test-ui\",\"challenge_id\":\"$challenge_id\",\"approver_id\":\"test-ui\",\"signature\":\"$signature\"}")
  assert_contains "$response" 'request is not eligible for approval' "the same signature cannot approve twice"
  stop_server

  out=$($GW status --digest "$digest")
  assert_contains "$out" 'state=approved' "approval is durable"
  assert_contains "$out" 'assurance_class=software-test-hmac' "status names how much the approval proves"

  database=$(gateway_database)
  python3 - "$database" <<'PY'
import json
import sqlite3
import sys

db = sqlite3.connect(sys.argv[1])
db.row_factory = sqlite3.Row
approvals = list(db.execute("SELECT * FROM approvals"))
assert len(approvals) == 1, approvals
assert approvals[0]["assurance_class"] == "software-test-hmac"
challenge = db.execute("SELECT consumed_at FROM challenges").fetchone()
assert challenge["consumed_at"] is not None, "the challenge must be one-shot"
events = [json.loads(row[0]) for row in db.execute("SELECT event_jcs FROM audit_events WHERE event_type='approved'")]
assert len(events) == 1, events
assert events[0]["approver_authenticity_proved"] is False, events[0]
refusals = db.execute("SELECT COUNT(*) FROM audit_events WHERE event_type='approval-signature-refused'").fetchone()[0]
assert refusals == 1, refusals
PY

  set +e
  out=$(env -u FM_ACTION_GATEWAY_TEST TMPDIR="$TMP/no-prod-enroll" "$GW" enroll-approver --approver-id x --algorithm hmac-sha256-test --key-material "$secret" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "test class outside test mode"
  assert_contains "$out" 'enrollable only in test mode' "production can never fall back to the forgeable class"

  pass "approval requires a signature that verifies over the exact challenged transcript, and records how much it proves"
}

approve_request() {  # <job> <request_id> <secret>
  local job=$1 request_id=$2 secret=$3 response transcript challenge_id signature
  response=$(rpc "$SOCKET_ROOT/approval.sock" "{\"schema\":\"fm.approval.v2\",\"op\":\"challenge\",\"capability\":\"$(issue_cap approval "$job")\",\"request_id\":\"$request_id\",\"ui_id\":\"test-ui\"}")
  transcript=$(json_field "$response" 'json.dumps(value["result"]["transcript"])')
  challenge_id=$(json_field "$response" 'value["result"]["challenge_id"]')
  signature=$(sign_transcript "$transcript" "$secret")
  response=$(rpc "$SOCKET_ROOT/approval.sock" "{\"schema\":\"fm.approval.v2\",\"op\":\"approve\",\"capability\":\"$(issue_cap approval "$job")\",\"request_id\":\"$request_id\",\"ui_id\":\"test-ui\",\"challenge_id\":\"$challenge_id\",\"approver_id\":\"test-ui\",\"signature\":\"$signature\"}")
  assert_contains "$response" '"state":"approved"' "fixture approval"
}

test_execution_is_leased_and_settled_from_the_sink() {
  local out digest request_id secret response lease
  reset_gateway
  out=$(device_request exec-job exec-idem exec-nonce | run_prepare)
  digest=$(kv_get "$out" digest)
  request_id=$(kv_get "$out" request_id)
  secret=$(new_secret)
  $GW enroll-approver --approver-id test-ui --algorithm hmac-sha256-test --key-material "$secret" >/dev/null
  start_server execution
  approve_request exec-job "$request_id" "$secret"

  response=$(rpc "$SOCKET_ROOT/execution.sock" "{\"schema\":\"fm.execution.v2\",\"op\":\"claim\",\"capability\":\"$(issue_cap execution exec-job)\",\"request_id\":\"$request_id\",\"idempotency_key\":\"wrong-key\"}")
  assert_contains "$response" 'does not bind to the immutable plan' "the execution key binds to the approved plan"

  response=$(rpc "$SOCKET_ROOT/execution.sock" "{\"schema\":\"fm.execution.v2\",\"op\":\"claim\",\"capability\":\"$(issue_cap execution exec-job)\",\"request_id\":\"$request_id\",\"idempotency_key\":\"exec-idem\"}")
  assert_contains "$response" '"state":"executing"' "claim moves the request into execution"
  assert_contains "$response" '"attempt":1' "the attempt ordinal is visible"
  lease=$(json_field "$response" 'value["result"]["lease"]')

  # A live lease is the difference between a crash default and a per-read
  # rewrite: another caller must not be able to take an execution window that is
  # still running, and a status read must not rewrite it either.
  response=$(rpc "$SOCKET_ROOT/execution.sock" "{\"schema\":\"fm.execution.v2\",\"op\":\"claim\",\"capability\":\"$(issue_cap execution exec-job)\",\"request_id\":\"$request_id\",\"idempotency_key\":\"exec-idem\"}")
  assert_contains "$response" 'already claimed by a live lease' "a second claim cannot duplicate a live execution"
  out=$($GW status --digest "$digest")
  assert_contains "$out" 'state=executing' "a status read leaves a live lease alone"

  response=$(rpc "$SOCKET_ROOT/execution.sock" "{\"schema\":\"fm.execution.v2\",\"op\":\"settle\",\"capability\":\"$(issue_cap execution exec-job)\",\"request_id\":\"$request_id\",\"lease\":\"forged-lease\",\"outcome\":\"succeeded\"}")
  assert_contains "$response" 'lease does not match' "a forged lease cannot settle"

  # The executor never ran, so the sink holds nothing. The runner claiming
  # success changes nothing: the broker reads the sink itself.
  response=$(rpc "$SOCKET_ROOT/execution.sock" "{\"schema\":\"fm.execution.v2\",\"op\":\"settle\",\"capability\":\"$(issue_cap execution exec-job)\",\"request_id\":\"$request_id\",\"lease\":\"$lease\",\"outcome\":\"succeeded\"}")
  assert_contains "$response" '"state":"failed"' "a claimed success with nothing in the sink settles from the sink"
  assert_contains "$response" '"executor_claimed_outcome":"succeeded"' "the claim is recorded, not believed"
  assert_contains "$response" 'broker-read-of-sink-store' "the outcome names its own source"
  stop_server

  pass "execution is claimed under a one-shot lease and settled from the sink rather than from the executor's report"
}

test_runner_drives_one_effect_and_repeats_do_not_duplicate() {
  local out digest request_id secret result rc store receipts
  reset_gateway
  out=$(device_request run-job run-idem run-nonce | run_prepare)
  digest=$(kv_get "$out" digest)
  request_id=$(kv_get "$out" request_id)
  secret=$(new_secret)
  $GW enroll-approver --approver-id test-ui --algorithm hmac-sha256-test --key-material "$secret" >/dev/null
  start_server runner
  approve_request run-job "$request_id" "$secret"

  set +e
  result=$($RUNNER run --socket-root "$SOCKET_ROOT" --capability "$(issue_cap execution run-job)" --request-id "$request_id" --idempotency-key run-idem 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "runner success exit"
  assert_contains "$result" '"broker_state":"succeeded"' "the broker settles succeeded from its own read of the sink"
  assert_contains "$result" '"outcome_source":"broker-read-of-sink-store"' "the outcome names its own source"

  out=$($GW status --digest "$digest")
  assert_contains "$out" 'state=succeeded' "the durable state is succeeded"
  assert_contains "$out" 'settlement=independently-observed-as-applied' "status distinguishes applied from claimed"

  # The repeated click. The request is terminal, so there is no second claim and
  # therefore no second effect.
  set +e
  result=$($RUNNER run --socket-root "$SOCKET_ROOT" --capability "$(issue_cap execution run-job)" --request-id "$request_id" --idempotency-key run-idem 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "repeat run refused"
  assert_contains "$result" 'requires a signed approved immutable plan' "a terminal request cannot be executed again"
  stop_server

  store=$(sink_root)
  [ "$store" != "$(dirname "$(gateway_database)")" ] || fail "the receipt store must not live under the broker root"
  receipts=$(python3 - "$store/safe-sink-v2.sqlite3" <<'PY'
import sqlite3
import sys

db = sqlite3.connect(sys.argv[1])
print(db.execute("SELECT COUNT(*) FROM receipts").fetchone()[0])
PY
)
  [ "$receipts" = 1 ] || fail "exactly one receipt must exist after a repeat, got $receipts"
  [ "$(wc -l < "$store/safe-sink-v2.jsonl" | tr -d ' ')" = 1 ] || fail "exactly one record must be appended"

  pass "the runner drives exactly one effect and a repeat produces no second one"
}

test_expired_lease_becomes_unknown_and_never_resurrects() {
  local out digest request_id secret response database lease
  reset_gateway
  out=$(device_request lease-job lease-idem lease-nonce | run_prepare)
  digest=$(kv_get "$out" digest)
  request_id=$(kv_get "$out" request_id)
  secret=$(new_secret)
  $GW enroll-approver --approver-id test-ui --algorithm hmac-sha256-test --key-material "$secret" >/dev/null
  start_server lease
  approve_request lease-job "$request_id" "$secret"
  response=$(rpc "$SOCKET_ROOT/execution.sock" "{\"schema\":\"fm.execution.v2\",\"op\":\"claim\",\"capability\":\"$(issue_cap execution lease-job)\",\"request_id\":\"$request_id\",\"idempotency_key\":\"lease-idem\"}")
  lease=$(json_field "$response" 'value["result"]["lease"]')

  # A live lease survives a restart-time recovery pass.
  out=$($GW status --digest "$digest")
  assert_contains "$out" 'state=executing' "recovery leaves a live lease running"

  # Expire it the way a dead executor would: the deadline passes with nothing
  # settled.
  $GW test-mark-executing --digest "$digest"
  out=$($GW status --digest "$digest")
  assert_contains "$out" 'state=unknown' "an expired lease becomes unknown"
  assert_contains "$out" 'reconciliation_required=true' "unknown requires reconciliation"
  assert_contains "$out" 'settlement=unobserved-requires-reconciliation' "unknown is never rendered as failed"

  response=$(rpc "$SOCKET_ROOT/execution.sock" "{\"schema\":\"fm.execution.v2\",\"op\":\"settle\",\"capability\":\"$(issue_cap execution lease-job)\",\"request_id\":\"$request_id\",\"lease\":\"$lease\",\"outcome\":\"succeeded\"}")
  assert_contains "$response" 'request is unknown, not executing' "a late settle cannot resurrect a terminal state"

  response=$(rpc "$SOCKET_ROOT/execution.sock" "{\"schema\":\"fm.execution.v2\",\"op\":\"claim\",\"capability\":\"$(issue_cap execution lease-job)\",\"request_id\":\"$request_id\",\"idempotency_key\":\"lease-idem\"}")
  assert_contains "$response" 'requires a signed approved immutable plan' "an unknown request cannot be retried automatically"
  stop_server

  out=$($GW status --digest "$digest")
  assert_contains "$out" 'state=unknown' "unknown is durable"
  database=$(gateway_database)
  python3 - "$database" <<'PY'
import sqlite3
import sys

db = sqlite3.connect(sys.argv[1])
count = db.execute("SELECT COUNT(*) FROM audit_events WHERE event_type='execution-uncertain'").fetchone()[0]
assert count == 1, count
PY
  pass "an expired execution lease becomes unknown, and neither a late settle nor a retry can leave that state"
}

test_a_plan_too_large_to_deliver_is_refused_before_it_is_executable() {
  local out rc body digest request_id secret response database stored
  reset_gateway
  # The claim reply carries the stored plan as base64, which expands 4/3, so a
  # plan past the ceiling could never be delivered inside one bounded protocol
  # string. It is refused while it is still a request and nothing is approved.
  body=$(python3 -c 'print("x" * 20000)')
  set +e
  out=$(request size-job size-idem size-nonce "\"recipient\":\"a@example.test\",\"subject\":\"s\",\"body\":\"$body\"" | run_prepare 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "oversize plan"
  assert_contains "$out" 'executable plan ceiling' "the refusal states the limit"
  # The manifest is hashed into every plan and is what a caller sizes its
  # payloads against, so the published ceiling has to be the enforced one.
  if ! python3 - "$ROOT/bin/fm-action-gateway-v2.py" "$out" <<'MANIFEST'
import importlib.util
import sys

module_path, refusal = sys.argv[1:]
spec = importlib.util.spec_from_file_location("fm_gateway_v2", module_path)
gateway = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gateway)
manifest = gateway.POLICY_MANIFEST
published = manifest["max_plan_jcs_bytes"]
assert published == gateway.MAX_PLAN_JCS_BYTES, published
assert str(published) in refusal, (published, refusal)
assert manifest["policy_revision"] >= 4, manifest["policy_revision"]
assert published < manifest["max_message_bytes"], manifest
assert "binding" in manifest["size_limit_model"], manifest["size_limit_model"]
MANIFEST
  then
    fail "the policy manifest must publish the ceiling the gateway actually enforces"
  fi
  database=$(gateway_database)
  if ! python3 - "$database" <<'NOROW'
import sqlite3
import sys

db = sqlite3.connect(sys.argv[1])
assert db.execute("SELECT COUNT(*) FROM requests").fetchone()[0] == 0, "a refused prepare must store nothing"
assert db.execute("SELECT COUNT(*) FROM idempotency_tombstones").fetchone()[0] == 0, "a refused prepare must burn no key"
NOROW
  then
    fail "a plan refused at prepare must leave no state behind"
  fi

  # The claim path checks the same ceiling before it moves any state, so a
  # stored plan that somehow grew past it leaves the request approved and still
  # claimable rather than stranded under a lease nobody holds.
  out=$(device_request size2-job size2-idem size2-nonce | run_prepare)
  digest=$(kv_get "$out" digest)
  request_id=$(kv_get "$out" request_id)
  secret=$(new_secret)
  $GW enroll-approver --approver-id test-ui --algorithm hmac-sha256-test --key-material "$secret" >/dev/null
  start_server size
  approve_request size2-job "$request_id" "$secret"
  stored="$TMP/stored-plan.jcs"
  python3 - "$database" "$digest" "$stored" <<'BLOAT'
import sqlite3
import sys

database, digest, stored = sys.argv[1:]
db = sqlite3.connect(database, isolation_level=None)
row = db.execute("SELECT plan_jcs FROM requests WHERE digest=?", (digest,)).fetchone()
open(stored, "wb").write(bytes(row[0]))
db.execute("UPDATE requests SET plan_jcs=? WHERE digest=?", (b'{"pad":"' + b"x" * 30000 + b'"}', digest))
BLOAT
  response=$(rpc "$SOCKET_ROOT/execution.sock" "{\"schema\":\"fm.execution.v2\",\"op\":\"claim\",\"capability\":\"$(issue_cap execution size2-job)\",\"request_id\":\"$request_id\",\"idempotency_key\":\"size2-idem\"}")
  assert_contains "$response" 'exceeds the executable plan ceiling' "an undeliverable plan is refused at claim"
  out=$($GW status --digest "$digest")
  assert_contains "$out" 'state=approved' "a refused claim leaves the request approved, not executing"

  python3 - "$database" "$digest" "$stored" <<'RESTORE'
import sqlite3
import sys

database, digest, stored = sys.argv[1:]
db = sqlite3.connect(database, isolation_level=None)
db.execute("UPDATE requests SET plan_jcs=? WHERE digest=?", (open(stored, "rb").read(), digest))
RESTORE
  response=$(rpc "$SOCKET_ROOT/execution.sock" "{\"schema\":\"fm.execution.v2\",\"op\":\"claim\",\"capability\":\"$(issue_cap execution size2-job)\",\"request_id\":\"$request_id\",\"idempotency_key\":\"size2-idem\"}")
  assert_contains "$response" '"state":"executing"' "the request was left claimable"
  stop_server
  pass "a plan too large to hand an executor is refused at prepare and again before any state moves"
}

test_an_unbound_executor_is_refused_before_it_runs() {
  local out digest request_id secret result rc marker unbound store
  reset_gateway
  out=$(device_request bound-job bound-idem bound-nonce | run_prepare)
  digest=$(kv_get "$out" digest)
  request_id=$(kv_get "$out" request_id)
  secret=$(new_secret)
  $GW enroll-approver --approver-id test-ui --algorithm hmac-sha256-test --key-material "$secret" >/dev/null
  start_server bound
  approve_request bound-job "$request_id" "$secret"

  # A program that would announce itself if it ever ran. The plan binds the
  # safe sink's exact bytes, so this one must never receive the approved plan.
  marker="$TMP/unbound-executor-ran"
  unbound="$TMP/unbound-executor.py"
  cat > "$unbound" <<UNBOUND
#!/usr/bin/env python3
import sys
open("$marker", "w").write("ran")
sys.stdin.buffer.read()
print("{}")
UNBOUND

  set +e
  result=$($RUNNER run --socket-root "$SOCKET_ROOT" --capability "$(issue_cap execution bound-job)" --request-id "$request_id" --idempotency-key bound-idem --executor "$unbound" 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "unbound executor refused"
  assert_contains "$result" 'refused to run an unbound executor' "the executor entry point does not choose the executor"
  assert_contains "$result" 'not the ones this approved plan binds' "the refusal names the bound-hash mismatch"
  assert_absent "$marker" "the unbound program must never receive the approved plan"
  assert_contains "$result" '"broker_state":"failed"' "the broker settles from its own read, which holds nothing"
  stop_server

  store=$(sink_root)
  assert_absent "$store/safe-sink-v2.jsonl" "nothing was applied, so the receipt store stays empty"
  out=$($GW status --digest "$digest")
  assert_contains "$out" 'state=failed' "a refused executor leaves nothing applied"
  pass "an executor whose bytes the plan does not bind is refused before it runs anything"
}

test_an_unreadable_sink_store_settles_unknown() {
  local out digest request_id secret response lease store
  [ "$(id -u)" != 0 ] || fail "this suite must not run as root: root can read a mode-0000 file"
  reset_gateway
  # First request: a real application, so the store exists and holds a record.
  out=$(device_request read-job read-idem read-nonce | run_prepare)
  request_id=$(kv_get "$out" request_id)
  secret=$(new_secret)
  $GW enroll-approver --approver-id test-ui --algorithm hmac-sha256-test --key-material "$secret" >/dev/null
  start_server unreadable
  approve_request read-job "$request_id" "$secret"
  $RUNNER run --socket-root "$SOCKET_ROOT" --capability "$(issue_cap execution read-job)" --request-id "$request_id" --idempotency-key read-idem >/dev/null

  # Second request, settled while the store cannot be read at all. An outcome
  # the broker cannot observe is unknown; it is never guessed from the
  # executor's own report.
  out=$(device_request read2-job read2-idem read2-nonce | run_prepare)
  digest=$(kv_get "$out" digest)
  request_id=$(kv_get "$out" request_id)
  approve_request read2-job "$request_id" "$secret"
  response=$(rpc "$SOCKET_ROOT/execution.sock" "{\"schema\":\"fm.execution.v2\",\"op\":\"claim\",\"capability\":\"$(issue_cap execution read2-job)\",\"request_id\":\"$request_id\",\"idempotency_key\":\"read2-idem\"}")
  lease=$(json_field "$response" 'value["result"]["lease"]')
  store=$(sink_root)
  chmod 0000 "$store/safe-sink-v2.sqlite3"
  response=$(rpc "$SOCKET_ROOT/execution.sock" "{\"schema\":\"fm.execution.v2\",\"op\":\"settle\",\"capability\":\"$(issue_cap execution read2-job)\",\"request_id\":\"$request_id\",\"lease\":\"$lease\",\"outcome\":\"succeeded\"}")
  chmod 0640 "$store/safe-sink-v2.sqlite3"
  assert_contains "$response" '"state":"unknown"' "a store the broker cannot read settles unknown"
  assert_contains "$response" 'could not be read' "the reason names what the broker could not observe"
  assert_contains "$response" '"reconciliation_required":true' "unknown requires reconciliation"
  stop_server

  out=$($GW status --digest "$digest")
  assert_contains "$out" 'state=unknown' "unknown is durable"
  assert_contains "$out" 'settlement=unobserved-requires-reconciliation' "unknown is never rendered as failed"
  pass "a receipt store the broker cannot read settles unknown rather than inventing an outcome"
}

# The durable record is what a reconciler reads, and the JSONL evidence append
# is not transactional: an unknown that rolled back with its refusal would leave
# the evidence file claiming a reconciliation the database never recorded. This
# reads the database immediately after each refusal, before any later command
# can run a recovery pass and repair what the socket path failed to write.
assert_recorded_unknown() {  # <request-id> <path-label>
  if ! python3 - "$(gateway_database)" "$1" "$2" <<'DURABLE'
import sqlite3
import sys

database, request_id, label = sys.argv[1:]
db = sqlite3.connect(database)
db.row_factory = sqlite3.Row
row = db.execute(
    "SELECT state,reconciliation_required,lease_hash,lease_expires_at FROM requests WHERE request_id=?",
    (request_id,),
).fetchone()
assert row["state"] == "unknown", (label, dict(row))
assert row["reconciliation_required"] == 1, (label, dict(row))
assert row["lease_hash"] is None and row["lease_expires_at"] is None, (label, dict(row))
outcomes = [r["outcome"] for r in db.execute("SELECT outcome FROM executions WHERE request_id=?", (request_id,))]
assert outcomes == ["unknown"], (label, outcomes)
events = db.execute(
    "SELECT COUNT(*) FROM audit_events WHERE event_type='execution-uncertain' AND request_id=?",
    (request_id,),
).fetchone()[0]
assert events == 1, (label, events)
DURABLE
  then
    fail "the $2 path must record unknown durably before it refuses"
  fi
}

test_an_expired_lease_is_recorded_before_the_refusal_is_raised() {
  local out digest request_id second_digest second_id secret response lease second_lease
  reset_gateway
  secret=$(new_secret)
  $GW enroll-approver --approver-id test-ui --algorithm hmac-sha256-test --key-material "$secret" >/dev/null
  out=$(device_request durable-job durable-idem durable-nonce | run_prepare)
  digest=$(kv_get "$out" digest)
  request_id=$(kv_get "$out" request_id)
  out=$(device_request durable2-job durable2-idem durable2-nonce | run_prepare)
  second_digest=$(kv_get "$out" digest)
  second_id=$(kv_get "$out" request_id)
  start_server durable
  approve_request durable-job "$request_id" "$secret"
  approve_request durable2-job "$second_id" "$secret"

  # Each request is claimed, expired the way a dead executor would expire it,
  # and then driven through one socket path. Nothing that runs a recovery pass
  # is allowed to intervene before the assertion, so what is asserted is what
  # the socket path itself wrote.
  response=$(rpc "$SOCKET_ROOT/execution.sock" "{\"schema\":\"fm.execution.v2\",\"op\":\"claim\",\"capability\":\"$(issue_cap execution durable-job)\",\"request_id\":\"$request_id\",\"idempotency_key\":\"durable-idem\"}")
  lease=$(json_field "$response" 'value["result"]["lease"]')
  [ -n "$lease" ] || fail "the first claim must succeed"
  $GW test-mark-executing --digest "$digest" --lease-seconds 0
  response=$(rpc "$SOCKET_ROOT/execution.sock" "{\"schema\":\"fm.execution.v2\",\"op\":\"settle\",\"capability\":\"$(issue_cap execution durable-job)\",\"request_id\":\"$request_id\",\"lease\":\"$lease\",\"outcome\":\"succeeded\"}")
  assert_contains "$response" 'the execution lease expired' "a settle after the lease expired is refused"
  assert_recorded_unknown "$request_id" settle

  response=$(rpc "$SOCKET_ROOT/execution.sock" "{\"schema\":\"fm.execution.v2\",\"op\":\"claim\",\"capability\":\"$(issue_cap execution durable2-job)\",\"request_id\":\"$second_id\",\"idempotency_key\":\"durable2-idem\"}")
  second_lease=$(json_field "$response" 'value["result"]["lease"]')
  [ -n "$second_lease" ] || fail "the second claim must succeed"
  $GW test-mark-executing --digest "$second_digest" --lease-seconds 0
  response=$(rpc "$SOCKET_ROOT/execution.sock" "{\"schema\":\"fm.execution.v2\",\"op\":\"claim\",\"capability\":\"$(issue_cap execution durable2-job)\",\"request_id\":\"$second_id\",\"idempotency_key\":\"durable2-idem\"}")
  assert_contains "$response" 'the previous execution lease expired' "a claim against an expired lease is refused"
  assert_recorded_unknown "$second_id" claim
  stop_server

  out=$($GW status --digest "$digest")
  assert_contains "$out" 'state=unknown' "the settle path's unknown is durable"
  out=$($GW status --digest "$second_digest")
  assert_contains "$out" 'state=unknown' "the claim path's unknown is durable"
  pass "an expired lease is committed as unknown before the refusal is raised, on both the claim and settle paths"
}

test_executor_swap_after_approval_is_refused() {
  local out digest request_id secret response copied
  reset_gateway
  out=$(device_request swap-job swap-idem swap-nonce | run_prepare)
  digest=$(kv_get "$out" digest)
  request_id=$(kv_get "$out" request_id)
  secret=$(new_secret)
  $GW enroll-approver --approver-id test-ui --algorithm hmac-sha256-test --key-material "$secret" >/dev/null
  start_server swap
  approve_request swap-job "$request_id" "$secret"

  copied="$TMP/sink-backup.py"
  cp "$SINK" "$copied"
  printf '\n# changed after approval\n' >> "$SINK"
  response=$(rpc "$SOCKET_ROOT/execution.sock" "{\"schema\":\"fm.execution.v2\",\"op\":\"claim\",\"capability\":\"$(issue_cap execution swap-job)\",\"request_id\":\"$request_id\",\"idempotency_key\":\"swap-idem\"}")
  cp "$copied" "$SINK"
  assert_contains "$response" 'executor program changed after approval' "an approval authorizes exact executor bytes"
  stop_server

  out=$($GW status --digest "$digest")
  assert_contains "$out" 'state=approved' "a refused claim leaves the approval intact"
  pass "an executor swapped after approval cannot run under the old consent"
}

test_help_and_old_broker_separate
test_strict_parser_rejections
test_canonicalization_matches_rfc8785
test_closed_plan_resolution
test_sqlite_uniqueness_replay_concurrency_and_tombstones
test_issued_capabilities_are_never_option_like
test_crash_recovery_marks_unknown
test_distinct_peer_credential_protocols
test_regression_pack_gateway_expectations
test_production_direct_adapter_refused
test_device_plan_preserves_the_exact_request
test_approval_requires_a_verified_signature
test_execution_is_leased_and_settled_from_the_sink
test_runner_drives_one_effect_and_repeats_do_not_duplicate
test_expired_lease_becomes_unknown_and_never_resurrects
test_a_plan_too_large_to_deliver_is_refused_before_it_is_executable
test_an_unbound_executor_is_refused_before_it_runs
test_an_unreadable_sink_store_settles_unknown
test_an_expired_lease_is_recorded_before_the_refusal_is_raised
test_executor_swap_after_approval_is_refused
