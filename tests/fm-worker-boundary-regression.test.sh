#!/usr/bin/env bash
# Contract and ambient-baseline tests for the synthetic worker-boundary pack.
set -eu

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
. "$ROOT/bin/fm-timeout-lib.sh"

PACK="$ROOT/bin/fm-worker-boundary-regression.sh"
MANIFEST="$ROOT/docs/fm-worker-boundary-source.json"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-worker-boundary-regression.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
REPORT="$TMP/ambient.json"
STDOUT="$TMP/ambient.stdout"
STDERR="$TMP/ambient.stderr"

expected_probes='network.ipv4
network.ipv6
network.dns
network.doh
network.loopback-tcp
network.loopback-udp
descriptor.inherited-open
ipc.unix-arbitrary
credential.keychain-file
credential.keychain-api
credential.ssh-agent-env
credential.ssh-agent-connect
credential.git-helper-env
credential.git-helper-exec
credential.captain-chrome
privacy.clipboard-service
privacy.tcc-service
privacy.tcc-database
control.docker-socket
gateway.database-read
gateway.inbox-read
gateway.audit-write
gateway.actionrequest-malformed
gateway.actionrequest-replayed
gateway.actionrequest-oversized
gateway.actionrequest-flooded
artifact.symlink-escape
artifact.traversal
terminal.control-output
resource.memory
resource.processes
resource.output
resource.wall-clock
recovery.crash-restart
launcher.drift
source.root-owned-ancestor-chain
source.no-worker-selected-privileged-open
source.no-production-trust-override
source.single-purpose-socket-schemas
source.socket-peer-credentials'

actual_probes=$($PACK --list-probes)
[ "$actual_probes" = "$expected_probes" ] || fail "probe inventory must cover every Step 1 adversarial class"
pass "probe inventory is stable and complete"

set +e
"$PACK" --target ambient --report "$REPORT" >"$STDOUT" 2>"$STDERR"
rc=$?
set -e
expect_code 1 "$rc" "ambient baseline"
[ ! -s "$STDERR" ] || fail "healthy ambient baseline must not emit setup errors"

python3 - "$REPORT" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
assert report["schema"] == "fm-worker-boundary-report.v1"
assert report["target"] == "ambient"
assert report["synthetic_only"] is True
assert report["temporary_root"] == "<temporary-root>"
assert report["summary"]["total"] == 40
assert report["summary"]["failed"] > 0
records = {record["probe"]: record for record in report["records"]}
assert len(records) == 40
for record in records.values():
    assert record["synthetic"] is True
    assert record["evaluated_as"] == "native-account"
    assert record["expected"]["native-account"]
    assert record["expected"]["nested-container"]

observed_ambient_exposures = {
    "network.ipv4": "REACHABLE",
    "network.dns": "REACHABLE",
    "network.doh": "REACHABLE",
    "credential.ssh-agent-env": "PRESENT",
    "credential.ssh-agent-connect": "REACHABLE",
    "credential.keychain-file": "REACHABLE",
    "credential.keychain-api": "REACHABLE",
    "credential.captain-chrome": "REACHABLE",
    "privacy.clipboard-service": "REACHABLE",
    "privacy.tcc-service": "REACHABLE",
    "control.docker-socket": "REACHABLE",
    "gateway.inbox-read": "REACHABLE",
    "gateway.audit-write": "REACHABLE",
}
for probe, actual in observed_ambient_exposures.items():
    assert records[probe]["actual"] == actual, (probe, records[probe]["actual"])
    assert records[probe]["result"] == "FAIL"

# An IPv6 canary that cannot bind is unmeasured, never enforced, so it still fails.
assert records["network.ipv6"]["actual"] in ("REACHABLE", "CANARY_UNAVAILABLE"), records["network.ipv6"]["actual"]
assert records["network.ipv6"]["result"] == "FAIL"

assert records["gateway.actionrequest-malformed"]["actual"] == "REJECTED"
assert records["gateway.actionrequest-replayed"]["actual"] == "REJECTED"
assert records["recovery.crash-restart"]["actual"] == "STATE_PRESERVED"

# The ambient launcher bounds nothing, so a probe recorded as bounded, sanitized,
# or limited here would mean the payload never ran rather than that it was denied.
assert records["terminal.control-output"]["actual"] == "UNSANITIZED"
assert records["resource.output"]["actual"] == "UNBOUNDED"
assert records["resource.memory"]["actual"] == "ALLOCATED"
assert records["resource.processes"]["actual"] == "SPAWNED"
assert records["resource.wall-clock"]["actual"] == "HARNESS_KILLED"
assert records["launcher.drift"]["actual"] == "UNATTESTED"

assert records["source.root-owned-ancestor-chain"]["actual"] == "FAIL"
assert records["source.no-worker-selected-privileged-open"]["actual"] == "FAIL"
assert records["source.no-production-trust-override"]["actual"] == "FAIL"
assert records["source.single-purpose-socket-schemas"]["actual"] == "FAIL"
assert records["source.socket-peer-credentials"]["actual"] == "FAIL"

encoded = json.dumps(report, sort_keys=True)
assert "/Users/" not in encoded
assert "/home/" not in encoded
assert "SSH_AUTH_SOCK" not in encoded
assert "SYNTHETIC_SECRET_NOT_REAL" not in encoded
PY
pass "ambient launch and workspace gateway reproduce only synthetic boundary exposures"

NOOP_ADAPTER="$TMP/noop-adapter.sh"
cat >"$NOOP_ADAPTER" <<'SH'
#!/usr/bin/env bash
exit 0
SH
REJECTING_GATEWAY="$TMP/rejecting-gateway.sh"
cat >"$REJECTING_GATEWAY" <<'SH'
#!/usr/bin/env bash
exit 1
SH
STATELESS_GATEWAY="$TMP/stateless-gateway.sh"
cat >"$STATELESS_GATEWAY" <<'SH'
#!/usr/bin/env bash
printf 'digest=%s\n' synthetic-stateless-digest
exit 0
SH
chmod +x "$NOOP_ADAPTER" "$REJECTING_GATEWAY" "$STATELESS_GATEWAY"

set +e
"$PACK" --target native-account --launcher-adapter "$NOOP_ADAPTER" --gateway "$REJECTING_GATEWAY" \
  --report "$TMP/noop.json" >"$TMP/noop.stdout" 2>"$TMP/noop.stderr"
noop_rc=$?
set -e
expect_code 1 "$noop_rc" "launcher and gateway that prove nothing"
[ ! -s "$TMP/noop.stderr" ] || fail "a silent launcher and a rejecting gateway must fail as verdicts, not as setup errors"
python3 - "$TMP/noop.json" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
records = {record["probe"]: record for record in report["records"]}
assert report["summary"]["failed"] == 40, report["summary"]
expected_states = {
    "terminal.control-output": "NOT_RUN",
    "resource.output": "NOT_RUN",
    "resource.memory": "NOT_REPORTED",
    "resource.processes": "NOT_REPORTED",
    "resource.wall-clock": "UNBOUNDED",
    "network.ipv4": "NOT_RUN",
    "gateway.database-read": "NO_BASELINE",
    "gateway.inbox-read": "NO_BASELINE",
    "gateway.audit-write": "NO_BASELINE",
    "gateway.actionrequest-malformed": "NO_BASELINE",
    "gateway.actionrequest-replayed": "NO_BASELINE",
    "gateway.actionrequest-oversized": "NO_BASELINE",
    "gateway.actionrequest-flooded": "NO_BASELINE",
}
for probe, state in expected_states.items():
    assert records[probe]["actual"] == state, (probe, records[probe]["actual"])
PY
pass "a silent launcher and a gateway that accepts no baseline turn no probe green"

set +e
"$PACK" --target native-account --launcher-adapter "$NOOP_ADAPTER" --gateway "$STATELESS_GATEWAY" \
  --report "$TMP/stateless.json" >"$TMP/stateless.stdout" 2>"$TMP/stateless.stderr"
stateless_rc=$?
set -e
expect_code 1 "$stateless_rc" "gateway that accepts the baseline but writes no state"
[ ! -s "$TMP/stateless.stderr" ] || fail "a stateless gateway must fail as verdicts, not as setup errors"
python3 - "$TMP/stateless.json" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
records = {record["probe"]: record for record in report["records"]}
for probe in ("gateway.database-read", "gateway.inbox-read", "gateway.audit-write"):
    assert records[probe]["actual"] == "NO_CANARY", (probe, records[probe]["actual"])
    assert records[probe]["result"] == "FAIL"
PY
pass "gateway state boundaries need an existing canary before they can pass"

ESCAPING_ADAPTER="$TMP/escaping-adapter.sh"
cat >"$ESCAPING_ADAPTER" <<'SH'
#!/usr/bin/env bash
set -eu
scenario=
while [ $# -gt 0 ]; do
  case "$1" in
    --scenario) scenario=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ "$scenario" = wall-clock ] || exit 0
python3 -c '
import os
import time
if os.fork() == 0:
    os.setsid()
    time.sleep(20)
os._exit(0)
'
exit 0
SH
chmod +x "$ESCAPING_ADAPTER"
set +e
fm_run_timeout 90 "$PACK" --target native-account --launcher-adapter "$ESCAPING_ADAPTER" \
  --gateway "$STATELESS_GATEWAY" --report "$TMP/escaping.json" \
  >"$TMP/escaping.stdout" 2>"$TMP/escaping.stderr"
escaping_rc=$?
set -e
expect_code 2 "$escaping_rc" "payload that escapes its process group and holds its pipes"
grep -q 'survived termination' "$TMP/escaping.stderr" \
  || fail "an unkillable payload must name the stuck scenario: $(cat "$TMP/escaping.stderr")"
grep -q 'wall-clock' "$TMP/escaping.stderr" \
  || fail "the stuck scenario must be identified: $(cat "$TMP/escaping.stderr")"
pass "timeout cleanup stays bounded when a payload escapes its process group"

VERIFY_SOURCE="$TMP/install-verifier.py"
PRIV_SOURCE="$TMP/privileged.py"
SOCKET_SOURCE="$TMP/sockets.py"
SECURE_MANIFEST="$TMP/secure-source.json"
cat >"$VERIFY_SOURCE" <<'PY'
# The installer walks every ancestor with stat, rejects a non-root uid, and reports the ancestor chain.
ROOT_UID = 0
PY
cat >"$PRIV_SOURCE" <<'PY'
# Privileged code accepts typed values only and never opens request paths.
TRUST_STATE = "/var/db/firstmate/gateway/state.db"
PY
cat >"$SOCKET_SOURCE" <<'PY'
# dispatch fm.dispatch.v1
# inference fm.inference.v1
# prepare fm.prepare.v1
# approval fm.approval.v1
# execution fm.execution.v1
PEER_CHECK = "SO_PEERCRED"
PY
python3 - "$SECURE_MANIFEST" "$VERIFY_SOURCE" "$PRIV_SOURCE" "$SOCKET_SOURCE" <<'PY'
import json
import sys
manifest, verifier, privileged, sockets = sys.argv[1:]
purposes = ["dispatch", "inference", "prepare", "approval", "execution"]
value = {
    "schema": "fm-worker-boundary-source.v1",
    "privileged_paths": [{
        "kind": "executable",
        "install_path": "/Library/PrivilegedHelperTools/firstmate/runner",
        "ancestor_check_source": verifier,
    }],
    "privileged_sources": [privileged],
    "forbidden_production_trust_env": ["FM_TRUST_STATE_OVERRIDE"],
    "required_socket_purposes": purposes,
    "sockets": [
        {"purpose": purpose, "schema": f"fm.{purpose}.v1", "source": sockets}
        for purpose in purposes
    ],
    "launcher_attestation": {"mode": "restricted"},
}
json.dump(value, open(manifest, "w", encoding="utf-8"))
PY
source_result=$($PACK --check-source-only --source-manifest "$SECURE_MANIFEST")
python3 - "$source_result" <<'PY'
import json
import sys
actual = json.loads(sys.argv[1])
assert actual
assert set(actual.values()) == {"PASS"}, actual
PY
pass "source invariant checker accepts only a complete fixed-path and peer-credential manifest"

HOSTILE_MANIFEST="$TMP/hostile-source.json"
printf '%s\n' '["fm-worker-boundary-source.v1"]' >"$HOSTILE_MANIFEST"
set +e
hostile_result=$("$PACK" --check-source-only --source-manifest "$HOSTILE_MANIFEST" 2>"$TMP/hostile.stderr")
hostile_rc=$?
set -e
expect_code 1 "$hostile_rc" "well-formed but wrongly shaped manifest"
[ ! -s "$TMP/hostile.stderr" ] || fail "a wrongly shaped manifest must fail as a verdict, not as a traceback"
python3 - "$hostile_result" <<'PY'
import json
import sys
actual = json.loads(sys.argv[1])
assert actual
assert set(actual.values()) == {"FAIL"}, actual
PY
pass "source invariant checker reports FAIL rather than crashing on a wrongly shaped manifest"

[ -x "$PACK" ] || fail "boundary pack must be executable"
[ -f "$MANIFEST" ] || fail "committed current-source manifest must exist"
pass "boundary pack is directly executable"
