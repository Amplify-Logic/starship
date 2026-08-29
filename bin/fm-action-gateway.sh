#!/usr/bin/env bash
# fm-action-gateway.sh - privilege-separated confirm-first outward-action broker.
#
# Single choke-point for ActionRequests. This slice is a real broker:
# privilege-separated captain approval, exclusive-locked atomic state transitions,
# deny-by-default operation registry, digest-bound one-shot approvals, and
# non-graduatable hard ceilings for spend + real-person messaging.
# Execution remains stubbed: the broker emits decisions and durable records only.
# It never performs an outward side effect (no network, mail, payment, or device
# commands). Schema and contract: docs/action-gateway.md.
#
# Commands:
#   prepare [--file <path>]     worker: validate, append prepared, emit confirm-first
#   show --digest H             render canonical action context (captain review)
#   approve --digest H --approver-id ID
#                               captain-only: privilege-separated approval
#   execute --digest H          captain-only stub: approved -> executing -> unknown
#   status  --digest H          replay log; print current state for digest
#   gate-check --digest H       fail closed unless digest is approved (choke helper)
#   replay                      rebuild all states; crash-safe confirm-first default
#   classify --action-kind K    print severity, ceiling, and whether K is graduatable
#   -h|--help
#
# Default (no command, stdin or --file): prepare.
#
# Environment:
#   FM_HOME / FM_DATA_OVERRIDE - home and data roots (override requires test mode)
#   FM_ACTION_GATEWAY_TEST=1   - allow path overrides and test captain secret via env
#   FM_ACTION_AUDIT_LOG        - override audit log path (test mode only)
#   FM_ACTION_GATEWAY_ROOT     - override gateway state root (test mode only)
#   FM_ACTION_GATEWAY_NOW      - override unix epoch for expiry tests (test mode only)
#   FM_ACTION_GATEWAY_ROLE     - worker (default) | captain
#   FM_ACTION_REQUESTER_ID     - default requester_id when omitted from request
#   FM_ACTION_CAPTAIN_SECRET   - captain secret (test mode); else config/action-captain-secret
#
# Exit:
#   0 on success (decision/state printed after durable append when required)
#   1 on usage, schema, policy, auth, digest, replay, or audit failure
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() {
  cat <<'EOF' >&2
usage: fm-action-gateway.sh prepare [--file <path>]
       fm-action-gateway.sh show --digest <hex>
       fm-action-gateway.sh approve --digest <hex> --approver-id <id>
       fm-action-gateway.sh execute --digest <hex>
       fm-action-gateway.sh status --digest <hex>
       fm-action-gateway.sh gate-check --digest <hex>
       fm-action-gateway.sh replay
       fm-action-gateway.sh classify --action-kind <kind>
       fm-action-gateway.sh -h|--help

Privilege-separated confirm-first action broker: workers prepare requests;
only a distinct captain identity with the captain secret may approve.
Spend and real-person messaging are structurally non-autonomous.
Never executes an outward action. Schema and contract: docs/action-gateway.md.
EOF
}

fail() {
  printf 'fm-action-gateway: %s\n' "$*" >&2
  exit 1
}

require_test_mode_for_overrides() {
  if [ -n "${FM_ACTION_AUDIT_LOG:-}" ] || [ -n "${FM_ACTION_GATEWAY_ROOT:-}" ] \
    || [ -n "${FM_DATA_OVERRIDE:-}" ] || [ -n "${FM_ACTION_GATEWAY_NOW:-}" ] \
    || [ -n "${FM_ACTION_CAPTAIN_SECRET:-}" ]; then
    if [ "${FM_ACTION_GATEWAY_TEST:-}" != "1" ]; then
      fail "path/secret/time overrides require FM_ACTION_GATEWAY_TEST=1"
    fi
  fi
}

gateway_root() {
  if [ -n "${FM_ACTION_GATEWAY_ROOT:-}" ]; then
    printf '%s\n' "$FM_ACTION_GATEWAY_ROOT"
    return 0
  fi
  printf '%s\n' "$DATA/action-gateway"
}

audit_log_path() {
  if [ -n "${FM_ACTION_AUDIT_LOG:-}" ]; then
    printf '%s\n' "$FM_ACTION_AUDIT_LOG"
    return 0
  fi
  printf '%s\n' "$(gateway_root)/action-audit.log"
}

captain_secret_path() {
  printf '%s\n' "$FM_HOME/config/action-captain-secret"
}

# Broker core. Args: <gateway_root> <audit_path> <captain_secret_path> <cmd_json>
# Prints key=value result lines on stdout; non-zero + stderr on failure.
broker_py() {
  local gw_root=$1
  local audit_path=$2
  local secret_path=$3
  local cmd_json=$4
  python3 - "$gw_root" "$audit_path" "$secret_path" "$cmd_json" <<'PY'
import fcntl
import hashlib
import json
import os
import re
import secrets
import sys
import time
import uuid

GW_ROOT = sys.argv[1]
AUDIT_PATH = sys.argv[2]
SECRET_PATH = sys.argv[3]
CMD_JSON = sys.argv[4] if len(sys.argv) > 4 else ""

# Deny-by-default operation registry.
# Severity mirrors Atelier tool_taxonomy: read / costly / external / irreversible.
# Unknown action_kind is refused at prepare.
OPERATION_REGISTRY = {
    # read
    "http.get": "read",
    "file.read": "read",
    # costly
    "http.request": "costly",
    "llm.complete": "costly",
    "scrape.url": "costly",
    # external
    "calendar.create": "external",
    "crm.update": "external",
    "file.write.remote": "external",
    "kb.fact.publish": "external",
    "course.publish": "external",
    "sheet.write": "external",
    # irreversible: money, real-person messaging, or customer-site device mutation
    # — structurally confirm-first
    "purchase": "irreversible",
    "payment": "irreversible",
    "spend": "irreversible",
    "transfer": "irreversible",
    "checkout": "irreversible",
    "ad.spend": "irreversible",
    "email.send": "irreversible",
    "message.send": "irreversible",
    "sms.send": "irreversible",
    "chat.send": "irreversible",
    "notify.person": "irreversible",
    "outreach.send": "irreversible",
    "social.post": "irreversible",
    "submission.send": "irreversible",
    "booking.request": "irreversible",
    "device.config.push": "irreversible",
    "device.firmware.push": "irreversible",
}

ALLOWED_TIERS = frozenset({"confirm-first", "autonomous", "sandbox"})
REQUIRED = (
    "task_id",
    "domain",
    "action_kind",
    "target",
    "parameters",
    "requested_consent_tier",
    "environment",
    "policy_version",
    "idempotency_key",
    "expires_at",
    "nonce",
    "requester_id",
)
TERMINAL = frozenset({"succeeded", "failed", "unknown"})
VALID_STATES = frozenset(
    {"prepared", "approved", "executing", "succeeded", "failed", "unknown"}
)
# Legal predecessor for each mutating event type (None = first event).
LEGAL_TRANSITIONS = {
    "prepared": {None},
    "approved": {"prepared"},
    "executing": {"approved"},
    "succeeded": {"executing"},
    "failed": {"executing"},
    "unknown": {"executing"},
    "refused": {"prepared", "approved"},  # does not advance state
}


def fail(msg: str, code: int = 1) -> None:
    print(f"fm-action-gateway: {msg}", file=sys.stderr)
    sys.exit(code)


def test_mode() -> bool:
    return os.environ.get("FM_ACTION_GATEWAY_TEST", "") == "1"


def now_ts() -> int:
    if test_mode():
        env = os.environ.get("FM_ACTION_GATEWAY_NOW", "").strip()
        if env:
            return int(env)
    return int(time.time())


def canonical_json(obj) -> str:
    return json.dumps(obj, separators=(",", ":"), sort_keys=True, ensure_ascii=False)


def extract_amount(params: dict):
    for key in ("amount_cents", "amount", "price_cents", "value_cents"):
        if key in params:
            return params[key]
    return None


def extract_recipient(params: dict):
    for key in ("recipient", "to", "email", "phone", "address"):
        if key in params:
            return params[key]
    return None


def resolve_severity(action_kind: str) -> str:
    if action_kind not in OPERATION_REGISTRY:
        fail(
            "unknown action_kind (deny-by-default registry): "
            f"{action_kind!r}; register it explicitly before use"
        )
    return OPERATION_REGISTRY[action_kind]


def classify_ceiling(severity: str, action_kind: str, params: dict):
    """Return 'spend', 'messaging', or None. Floor cannot be raised later."""
    if severity == "irreversible":
        if action_kind in {
            "purchase",
            "payment",
            "spend",
            "transfer",
            "checkout",
            "ad.spend",
        } or extract_amount(params) is not None:
            return "spend"
        return "messaging"
    if extract_amount(params) is not None:
        return "spend"
    if extract_recipient(params) is not None:
        return "messaging"
    return None


def digest_payload(req: dict) -> dict:
    params = req["parameters"]
    return {
        "amount": extract_amount(params),
        "domain": req["domain"],
        "environment": req["environment"],
        "expires_at": req["expires_at"],
        "idempotency_key": req["idempotency_key"],
        "nonce": req["nonce"],
        "operation": req["action_kind"],
        "parameters": params,
        "policy_version": req["policy_version"],
        "recipient": extract_recipient(params),
        "requested_consent_tier": req["requested_consent_tier"],
        "requester_id": req["requester_id"],
        "target": req["target"],
        "task_id": req["task_id"],
    }


def action_digest(req: dict) -> str:
    raw = canonical_json(digest_payload(req)).encode("utf-8")
    return hashlib.sha256(raw).hexdigest()


def validate_request(obj):
    if not isinstance(obj, dict):
        fail("ActionRequest must be a JSON object")
    # Inject requester_id from env when omitted (worker spawn sets it).
    if "requester_id" not in obj:
        env_req = os.environ.get("FM_ACTION_REQUESTER_ID", "").strip()
        if env_req:
            obj = dict(obj)
            obj["requester_id"] = env_req
    missing = [k for k in REQUIRED if k not in obj]
    if missing:
        fail("missing fields: " + ", ".join(missing))
    unknown = sorted(set(obj) - set(REQUIRED))
    if unknown:
        fail("unknown fields: " + ", ".join(unknown))

    task_id = obj["task_id"]
    if (
        not isinstance(task_id, str)
        or not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", task_id)
        or re.fullmatch(r"\.+", task_id)
    ):
        fail("task_id must be 1-64 chars from [A-Za-z0-9._-] and not dots-only")

    for key in (
        "domain",
        "action_kind",
        "target",
        "requested_consent_tier",
        "environment",
        "policy_version",
        "idempotency_key",
        "nonce",
        "requester_id",
    ):
        val = obj[key]
        if not isinstance(val, str) or not val.strip():
            fail(f"{key} must be a non-empty string")
        if key in ("requester_id",) and not re.fullmatch(
            r"[A-Za-z0-9._@-]{1,128}", val
        ):
            fail(f"{key} must be 1-128 chars from [A-Za-z0-9._@-]")

    if not isinstance(obj["parameters"], dict):
        fail("parameters must be a JSON object")

    if obj["requested_consent_tier"] not in ALLOWED_TIERS:
        fail(
            "requested_consent_tier must be one of: "
            + ", ".join(sorted(ALLOWED_TIERS))
        )

    exp = obj["expires_at"]
    if not isinstance(exp, int) or isinstance(exp, bool) or exp <= 0:
        fail("expires_at must be a positive unix timestamp integer")

    # Deny-by-default: must resolve.
    resolve_severity(obj["action_kind"])
    return obj


def inbox_dir() -> str:
    return os.path.join(GW_ROOT, "captain-inbox")


def inbox_path(digest: str) -> str:
    return os.path.join(inbox_dir(), f"{digest}.approval")


def lock_path() -> str:
    return os.path.join(GW_ROOT, "action-gateway.lock")


def ensure_gateway_dirs() -> None:
    os.makedirs(GW_ROOT, mode=0o700, exist_ok=True)
    os.makedirs(inbox_dir(), mode=0o700, exist_ok=True)
    try:
        os.chmod(GW_ROOT, 0o700)
        os.chmod(inbox_dir(), 0o700)
    except OSError:
        pass


def read_captain_secret() -> str:
    # Authoritative secret is the captain secret file. Env is never the
    # expected value when the file exists (otherwise a wrong env would
    # redefine the secret and defeat verification).
    if os.path.isfile(SECRET_PATH):
        try:
            with open(SECRET_PATH, "r", encoding="utf-8") as fh:
                secret = fh.read().strip()
        except OSError as exc:
            fail(f"cannot read captain secret: {exc}")
        if not secret:
            fail("captain secret file is empty")
        return secret
    if test_mode():
        env_secret = os.environ.get("FM_ACTION_CAPTAIN_SECRET", "").strip()
        if env_secret:
            return env_secret
    fail(
        "captain secret missing: create config/action-captain-secret "
        "(mode 0600) or set FM_ACTION_CAPTAIN_SECRET under test mode"
    )


def role() -> str:
    r = os.environ.get("FM_ACTION_GATEWAY_ROLE", "worker").strip().lower()
    if r not in ("worker", "captain"):
        fail("FM_ACTION_GATEWAY_ROLE must be worker or captain")
    return r


def require_captain(op: str) -> None:
    if role() != "captain":
        fail(f"{op} requires FM_ACTION_GATEWAY_ROLE=captain (privilege separation)")


def require_captain_secret() -> None:
    expected = read_captain_secret()
    got = (
        os.environ.get("FM_ACTION_APPROVER_SECRET", "")
        or os.environ.get("FM_ACTION_CAPTAIN_SECRET", "")
    )
    if not got:
        if test_mode():
            # Tests must present the secret explicitly so wrong-secret cases fail.
            fail("approval refused: captain secret missing or incorrect")
        # Production: reading config/action-captain-secret is the capability proof.
        got = expected
    if not secrets.compare_digest(got, expected):
        fail("approval refused: captain secret missing or incorrect")


def read_events(path: str):
    if not os.path.isfile(path):
        return []
    events = []
    with open(path, "r", encoding="utf-8") as fh:
        for line_no, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError as exc:
                fail(f"corrupt audit log at line {line_no}: {exc}")
            if not isinstance(ev, dict) or "event" not in ev:
                fail(f"corrupt audit log at line {line_no}: missing event")
            events.append(ev)
    return events


def replay_states(events):
    """Rebuild per-digest state with legal transition enforcement."""
    by_digest = {}
    by_idem = {}
    used_nonces = set()
    used_tokens = set()
    for line_no, ev in enumerate(events, 1):
        et = ev["event"]
        digest = ev.get("digest")
        if et not in LEGAL_TRANSITIONS and et != "refused":
            fail(f"unknown event type {et!r} at audit line {line_no}")
        if not digest:
            fail(f"audit line {line_no}: missing digest")

        st = by_digest.get(digest)
        prior = None if st is None else st["state"]
        allowed_priors = LEGAL_TRANSITIONS.get(et, set())
        if et == "refused":
            if prior not in allowed_priors:
                fail(
                    f"illegal transition at line {line_no}: "
                    f"{prior!r} -> refused"
                )
        elif prior not in allowed_priors:
            fail(
                f"illegal transition at line {line_no}: "
                f"{prior!r} -> {et}"
            )

        if st is None:
            st = {
                "digest": digest,
                "state": None,
                "request_id": ev.get("request_id"),
                "request": ev.get("request"),
                "decision": "confirm-first",
                "ceiling": ev.get("ceiling"),
                "severity": ev.get("severity"),
                "idempotency_key": ev.get("idempotency_key"),
                "expires_at": ev.get("expires_at"),
                "approval_token_hash": ev.get("approval_token_hash"),
                "requester_id": ev.get("requester_id"),
                "approver_id": None,
                "approved_at": None,
                "token_consumed": False,
                "events": [],
            }
            by_digest[digest] = st

        st["events"].append(ev)
        if et == "prepared":
            req = ev.get("request") or {}
            nonce = req.get("nonce") if isinstance(req, dict) else None
            if nonce:
                if nonce in used_nonces:
                    fail(f"nonce reuse detected at audit line {line_no}")
                used_nonces.add(nonce)
            # Recompute digest from stored request; refuse drift.
            if isinstance(req, dict) and req:
                recomputed = action_digest(req)
                if recomputed != digest:
                    fail(
                        f"stored digest mismatch at line {line_no}: "
                        f"log={digest} recomputed={recomputed}"
                    )
            st["state"] = "prepared"
            st["request"] = ev.get("request", st["request"])
            st["request_id"] = ev.get("request_id", st["request_id"])
            st["decision"] = ev.get("decision", "confirm-first")
            st["ceiling"] = ev.get("ceiling")
            st["severity"] = ev.get("severity")
            st["idempotency_key"] = ev.get("idempotency_key")
            st["expires_at"] = ev.get("expires_at")
            st["approval_token_hash"] = ev.get("approval_token_hash")
            st["requester_id"] = ev.get("requester_id") or (
                req.get("requester_id") if isinstance(req, dict) else None
            )
            if st["idempotency_key"]:
                by_idem[st["idempotency_key"]] = digest
        elif et == "approved":
            st["state"] = "approved"
            st["token_consumed"] = True
            st["approver_id"] = ev.get("approver_id")
            st["approved_at"] = ev.get("ts")
            if ev.get("approval_token_hash"):
                used_tokens.add(ev["approval_token_hash"])
        elif et == "executing":
            st["state"] = "executing"
        elif et in TERMINAL:
            st["state"] = et
        elif et == "refused":
            pass
        if st["state"] not in VALID_STATES and st["state"] is not None:
            fail(f"invalid state {st['state']!r} for digest {digest}")

    crash_unknown = []
    for digest, st in by_digest.items():
        if st["state"] == "executing":
            st["state"] = "unknown"
            st["decision"] = "confirm-first"
            crash_unknown.append(digest)
        st["decision"] = "confirm-first"
    return by_digest, by_idem, used_tokens, used_nonces, crash_unknown


def emit_kv(result: dict) -> None:
    if os.environ.get("FM_ACTION_GATEWAY_JSON", "") == "1":
        print(canonical_json(result))
        return
    order = (
        "decision",
        "state",
        "digest",
        "request_id",
        "ceiling",
        "severity",
        "expires_at",
        "reason",
        "idempotency_key",
        "requester_id",
        "approver_id",
        "approved_at",
        "event",
    )
    for key in order:
        if key in result and result[key] is not None:
            print(f"{key}={result[key]}")


def append_event(path: str, event: dict) -> None:
    line = canonical_json(event) + "\n"
    data = line.encode("utf-8")
    parent = os.path.dirname(path) or "."
    os.makedirs(parent, mode=0o700, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        written = 0
        while written < len(data):
            n = os.write(fd, data[written:])
            if n <= 0:
                raise OSError("short write to audit log")
            written += n
        os.fsync(fd)
    finally:
        os.close(fd)
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass
    dir_fd = os.open(parent, os.O_RDONLY)
    try:
        os.fsync(dir_fd)
    finally:
        os.close(dir_fd)


def write_captain_inbox(digest: str, payload: dict) -> None:
    ensure_gateway_dirs()
    path = inbox_path(digest)
    raw = canonical_json(payload) + "\n"
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.write(fd, raw.encode("utf-8"))
        os.fsync(fd)
    finally:
        os.close(fd)


def read_captain_inbox(digest: str) -> dict:
    path = inbox_path(digest)
    if not os.path.isfile(path):
        fail("approval refused: captain inbox entry missing for digest")
    with open(path, "r", encoding="utf-8") as fh:
        return json.loads(fh.read())


def consume_captain_inbox(digest: str) -> None:
    path = inbox_path(digest)
    try:
        os.remove(path)
    except FileNotFoundError:
        pass


def cmd_prepare(cmd: dict, by_digest, by_idem, used_nonces):
    # Workers prepare; captains may also prepare but still cannot self-approve.
    req = validate_request(cmd["request"])
    severity = resolve_severity(req["action_kind"])
    digest = action_digest(req)
    ceiling = classify_ceiling(severity, req["action_kind"], req["parameters"])
    decision = "confirm-first"
    # Structural ceiling: irreversible never graduates to autonomous.
    if severity == "irreversible" and req["requested_consent_tier"] != "confirm-first":
        pass  # decision stays confirm-first regardless

    idem = req["idempotency_key"]
    if req["nonce"] in used_nonces:
        fail("nonce reuse refused")

    if idem in by_idem:
        existing_digest = by_idem[idem]
        if existing_digest != digest:
            fail(
                "idempotency_key reuse with differing digest "
                f"(existing={existing_digest}, new={digest})"
            )
        st = by_digest[existing_digest]
        emit_kv(
            {
                "decision": "confirm-first",
                "state": st["state"],
                "digest": existing_digest,
                "request_id": st["request_id"],
                "ceiling": st.get("ceiling"),
                "severity": st.get("severity"),
                "expires_at": st.get("expires_at"),
                "idempotency_key": idem,
                "requester_id": st.get("requester_id"),
                "reason": "idempotent-replay",
                "event": "prepared",
            }
        )
        return

    if digest in by_digest:
        st = by_digest[digest]
        emit_kv(
            {
                "decision": "confirm-first",
                "state": st["state"],
                "digest": digest,
                "request_id": st["request_id"],
                "ceiling": st.get("ceiling"),
                "severity": st.get("severity"),
                "expires_at": st.get("expires_at"),
                "idempotency_key": idem,
                "requester_id": st.get("requester_id"),
                "reason": "digest-already-prepared",
                "event": "prepared",
            }
        )
        return

    if req["expires_at"] <= now_ts():
        fail("request already expired at prepare")

    # One-shot token: written ONLY to captain inbox, never to worker stdout.
    token = secrets.token_hex(32)
    token_hash = hashlib.sha256(token.encode("utf-8")).hexdigest()
    request_id = str(uuid.uuid4())
    event = {
        "ts": now_ts(),
        "event": "prepared",
        "state": "prepared",
        "request_id": request_id,
        "digest": digest,
        "decision": decision,
        "ceiling": ceiling,
        "severity": severity,
        "idempotency_key": idem,
        "expires_at": req["expires_at"],
        "approval_token_hash": token_hash,
        "requester_id": req["requester_id"],
        "request": req,
        "execution": "stubbed",
    }
    append_event(AUDIT_PATH, event)
    write_captain_inbox(
        digest,
        {
            "digest": digest,
            "request_id": request_id,
            "approval_token": token,
            "requester_id": req["requester_id"],
            "canonical": digest_payload(req),
            "severity": severity,
            "ceiling": ceiling,
            "ts": now_ts(),
        },
    )
    # Privilege separation: never emit approval_token to the requester.
    emit_kv(
        {
            "decision": decision,
            "state": "prepared",
            "digest": digest,
            "request_id": request_id,
            "ceiling": ceiling,
            "severity": severity,
            "expires_at": req["expires_at"],
            "idempotency_key": idem,
            "requester_id": req["requester_id"],
            "event": "prepared",
            "reason": "awaiting-captain-approval",
        }
    )


def cmd_classify(cmd: dict) -> None:
    """Registry-only: severity, ceiling, and whether this kind may graduate.

    Reuses resolve_severity + classify_ceiling. Irreversible kinds and any
    kind the ceiling classifier labels spend or messaging are non-graduatable.
    Unknown kinds are refused (deny by default). No audit I/O.
    """
    kind = cmd.get("action_kind")
    if not isinstance(kind, str) or not kind.strip():
        fail("classify requires --action-kind")
    kind = kind.strip()
    severity = resolve_severity(kind)
    ceiling = classify_ceiling(severity, kind, {})
    if severity == "irreversible" or ceiling in {"spend", "messaging"}:
        graduatable = "no"
    else:
        graduatable = "yes"
    print(f"action_kind={kind}")
    print(f"severity={severity}")
    print(f"ceiling={ceiling or ''}")
    print(f"graduatable={graduatable}")


def cmd_show(cmd: dict, by_digest):
    digest = cmd.get("digest")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        fail("show requires --digest <sha256-hex>")
    st = by_digest.get(digest)
    if st is None:
        fail("unknown digest")
    req = st.get("request") or {}
    canonical = digest_payload(req) if req else {}
    # Human-readable trusted display for captain review before approve.
    print("=== action gateway: canonical action context ===")
    print(f"digest={digest}")
    print(f"state={st['state']}")
    print(f"request_id={st.get('request_id')}")
    print(f"requester_id={st.get('requester_id')}")
    print(f"severity={st.get('severity')}")
    print(f"ceiling={st.get('ceiling')}")
    print(f"expires_at={st.get('expires_at')}")
    print(f"decision_posture=confirm-first")
    print("--- canonical fields ---")
    print(canonical_json(canonical))
    if st.get("approver_id"):
        print(f"approver_id={st['approver_id']}")
        print(f"approved_at={st.get('approved_at')}")


def cmd_approve(cmd: dict, by_digest):
    require_captain("approve")
    require_captain_secret()

    digest = cmd.get("digest")
    approver_id = cmd.get("approver_id")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        fail("approve requires --digest <sha256-hex>")
    if not isinstance(approver_id, str) or not re.fullmatch(
        r"[A-Za-z0-9._@-]{1,128}", approver_id or ""
    ):
        fail("approve requires --approver-id <id>")

    st = by_digest.get(digest)
    if st is None:
        fail("unknown digest: not prepared")
    if st["state"] in TERMINAL:
        fail(f"digest already terminal: {st['state']}")
    if st["state"] == "approved":
        fail("approval already consumed for this digest")
    if st["state"] == "executing":
        fail("digest is executing; cannot approve")
    if st["state"] != "prepared":
        fail(f"digest not in prepared state (state={st['state']})")

    requester_id = st.get("requester_id")
    if not requester_id:
        fail("approval refused: prepared request missing requester_id")
    # Structural: requester must never approve its own request.
    if secrets.compare_digest(str(requester_id), str(approver_id)):
        refuse = {
            "ts": now_ts(),
            "event": "refused",
            "state": st["state"],
            "digest": digest,
            "request_id": st["request_id"],
            "requester_id": requester_id,
            "approver_id": approver_id,
            "reason": "self-approval-forbidden",
            "decision": "confirm-first",
        }
        append_event(AUDIT_PATH, refuse)
        fail("approval refused: requester cannot approve its own request")

    if st.get("expires_at") is not None and int(st["expires_at"]) <= now_ts():
        refuse = {
            "ts": now_ts(),
            "event": "refused",
            "state": st["state"],
            "digest": digest,
            "request_id": st["request_id"],
            "reason": "expired",
            "decision": "confirm-first",
        }
        append_event(AUDIT_PATH, refuse)
        fail("approval refused: digest expired")

    # Read one-shot token from captain inbox (never from worker argv).
    inbox = read_captain_inbox(digest)
    token = inbox.get("approval_token")
    if not isinstance(token, str) or not token:
        fail("approval refused: captain inbox token missing")
    token_hash = hashlib.sha256(token.encode("utf-8")).hexdigest()
    if token_hash != st.get("approval_token_hash"):
        refuse = {
            "ts": now_ts(),
            "event": "refused",
            "state": st["state"],
            "digest": digest,
            "request_id": st["request_id"],
            "reason": "token-mismatch-or-digest-swap",
            "decision": "confirm-first",
        }
        append_event(AUDIT_PATH, refuse)
        fail("approval refused: inbox token does not bind to this digest")

    if st.get("token_consumed"):
        fail("approval refused: token replay")

    # Irreversible actions stay confirm-first forever; approval authorizes one shot.
    approved_at = now_ts()
    event = {
        "ts": approved_at,
        "event": "approved",
        "state": "approved",
        "digest": digest,
        "request_id": st["request_id"],
        "approval_token_hash": token_hash,
        "requester_id": requester_id,
        "approver_id": approver_id,
        "decision": "confirm-first",
        "ceiling": st.get("ceiling"),
        "severity": st.get("severity"),
        "execution": "stubbed",
    }
    append_event(AUDIT_PATH, event)
    consume_captain_inbox(digest)
    emit_kv(
        {
            "decision": "confirm-first",
            "state": "approved",
            "digest": digest,
            "request_id": st["request_id"],
            "ceiling": st.get("ceiling"),
            "severity": st.get("severity"),
            "requester_id": requester_id,
            "approver_id": approver_id,
            "approved_at": approved_at,
            "event": "approved",
            "reason": "captain-privilege-separated-approval",
        }
    )


def cmd_execute(cmd: dict, by_digest):
    """Stub executor: record executing -> unknown. NEVER performs an action."""
    require_captain("execute")
    require_captain_secret()

    digest = cmd.get("digest")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        fail("execute requires --digest <sha256-hex>")
    st = by_digest.get(digest)
    if st is None:
        fail("unknown digest: not prepared")
    if st["state"] in TERMINAL:
        fail(f"digest already terminal: {st['state']}")
    if st["state"] != "approved":
        fail(f"execute requires approved state (state={st['state']})")
    if st.get("expires_at") is not None and int(st["expires_at"]) <= now_ts():
        fail("execute refused: digest expired")
    if not st.get("approver_id"):
        fail("execute refused: missing attributable approver_id")
    if st.get("requester_id") and secrets.compare_digest(
        str(st["requester_id"]), str(st["approver_id"])
    ):
        fail("execute refused: self-approved digest is invalid")

    ceiling = st.get("ceiling")
    exec_ev = {
        "ts": now_ts(),
        "event": "executing",
        "state": "executing",
        "digest": digest,
        "request_id": st["request_id"],
        "decision": "confirm-first",
        "ceiling": ceiling,
        "severity": st.get("severity"),
        "requester_id": st.get("requester_id"),
        "approver_id": st.get("approver_id"),
        "execution": "stubbed",
    }
    append_event(AUDIT_PATH, exec_ev)
    term = {
        "ts": now_ts(),
        "event": "unknown",
        "state": "unknown",
        "digest": digest,
        "request_id": st["request_id"],
        "decision": "confirm-first",
        "ceiling": ceiling,
        "severity": st.get("severity"),
        "reason": "execution-not-wired",
        "execution": "stubbed",
    }
    append_event(AUDIT_PATH, term)
    emit_kv(
        {
            "decision": "confirm-first",
            "state": "unknown",
            "digest": digest,
            "request_id": st["request_id"],
            "ceiling": ceiling,
            "severity": st.get("severity"),
            "event": "unknown",
            "reason": "execution-not-wired",
        }
    )


def cmd_status(cmd: dict, by_digest):
    digest = cmd.get("digest")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        fail("status requires --digest <sha256-hex>")
    st = by_digest.get(digest)
    if st is None:
        fail("unknown digest")
    emit_kv(
        {
            "decision": "confirm-first",
            "state": st["state"],
            "digest": digest,
            "request_id": st["request_id"],
            "ceiling": st.get("ceiling"),
            "severity": st.get("severity"),
            "expires_at": st.get("expires_at"),
            "idempotency_key": st.get("idempotency_key"),
            "requester_id": st.get("requester_id"),
            "approver_id": st.get("approver_id"),
            "approved_at": st.get("approved_at"),
            "event": "status",
        }
    )


def cmd_gate_check(cmd: dict, by_digest):
    """Choke-point helper: succeed only when digest is currently approved."""
    digest = cmd.get("digest")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        fail("gate-check requires --digest <sha256-hex>")
    st = by_digest.get(digest)
    if st is None:
        fail("gate-check refused: unknown digest")
    if st["state"] != "approved":
        fail(f"gate-check refused: state={st['state']} (need approved)")
    if not st.get("approver_id"):
        fail("gate-check refused: approval not attributable")
    if st.get("requester_id") and secrets.compare_digest(
        str(st["requester_id"]), str(st["approver_id"])
    ):
        fail("gate-check refused: self-approval is invalid")
    if st.get("expires_at") is not None and int(st["expires_at"]) <= now_ts():
        fail("gate-check refused: digest expired")
    emit_kv(
        {
            "decision": "confirm-first",
            "state": "approved",
            "digest": digest,
            "request_id": st["request_id"],
            "requester_id": st.get("requester_id"),
            "approver_id": st.get("approver_id"),
            "event": "gate-check",
            "reason": "approved-choke-point",
        }
    )


def cmd_replay(by_digest, crash_unknown):
    for digest in crash_unknown:
        st = by_digest[digest]
        append_event(
            AUDIT_PATH,
            {
                "ts": now_ts(),
                "event": "unknown",
                "state": "unknown",
                "digest": digest,
                "request_id": st["request_id"],
                "decision": "confirm-first",
                "ceiling": st.get("ceiling"),
                "severity": st.get("severity"),
                "reason": "crash-replay-default-confirm-first",
                "execution": "stubbed",
            },
        )
        st["state"] = "unknown"
    emit_kv(
        {
            "decision": "confirm-first",
            "state": "replayed",
            "reason": "crash-safe-confirm-first",
            "event": "replay",
        }
    )
    print(f"actions={len(by_digest)}")
    print(f"crash_unknown_recovered={len(crash_unknown)}")


def with_lock(fn):
    ensure_gateway_dirs()
    os.makedirs(GW_ROOT, mode=0o700, exist_ok=True)
    lp = lock_path()
    # Exclusive lock serializes the full read/check/transition/append cycle.
    fd = os.open(lp, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        return fn()
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)


def main():
    try:
        cmd = json.loads(CMD_JSON)
    except json.JSONDecodeError as exc:
        fail(f"invalid broker command JSON: {exc}")
    if not isinstance(cmd, dict) or "op" not in cmd:
        fail("broker command must be a JSON object with op")

    op = cmd["op"]

    # classify is a pure registry lookup: no lock, no audit I/O.
    if op == "classify":
        cmd_classify(cmd)
        return

    def run():
        events = read_events(AUDIT_PATH)
        by_digest, by_idem, _used, used_nonces, crash_unknown = replay_states(events)
        if op == "prepare":
            if "request" not in cmd:
                fail("prepare requires request object")
            cmd_prepare(cmd, by_digest, by_idem, used_nonces)
        elif op == "show":
            cmd_show(cmd, by_digest)
        elif op == "approve":
            cmd_approve(cmd, by_digest)
        elif op == "execute":
            cmd_execute(cmd, by_digest)
        elif op == "status":
            cmd_status(cmd, by_digest)
        elif op == "gate-check":
            cmd_gate_check(cmd, by_digest)
        elif op == "replay":
            cmd_replay(by_digest, crash_unknown)
        else:
            fail(f"unknown op: {op}")

    with_lock(run)


if __name__ == "__main__":
    main()
PY
}

run_broker() {
  local gw_root=$1
  local audit_path=$2
  local secret_path=$3
  local cmd_json=$4
  local err_file out
  err_file=$(mktemp "${TMPDIR:-/tmp}/fm-action-gateway.XXXXXX")
  if ! out=$(broker_py "$gw_root" "$audit_path" "$secret_path" "$cmd_json" 2>"$err_file"); then
    cat "$err_file" >&2 || true
    rm -f "$err_file"
    return 1
  fi
  rm -f "$err_file"
  printf '%s\n' "$out"
}

read_request_input() {
  local file=$1
  if [ -n "$file" ]; then
    [ -f "$file" ] || fail "request file not found: $file"
    cat "$file"
  else
    cat
  fi
}

broker_paths() {
  GW_ROOT=$(gateway_root)
  AUDIT_PATH=$(audit_log_path)
  SECRET_PATH=$(captain_secret_path)
}

cmd_prepare() {
  local file='' input request_json cmd_json
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --file)
        [ "$#" -ge 2 ] || fail "--file requires a path"
        file=$2
        shift 2
        ;;
      -*)
        fail "unknown flag: $1"
        ;;
      *)
        fail "unexpected argument: $1"
        ;;
    esac
  done
  input=$(read_request_input "$file")
  printf '%s' "$input" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' \
    >/dev/null 2>&1 || fail "schema validation failed"
  request_json=$(printf '%s' "$input" | python3 -c 'import json,sys; json.dump(json.loads(sys.stdin.read()), sys.stdout, separators=(",",":"))')
  broker_paths
  cmd_json=$(python3 -c 'import json,sys; print(json.dumps({"op":"prepare","request":json.loads(sys.argv[1])}))' "$request_json")
  run_broker "$GW_ROOT" "$AUDIT_PATH" "$SECRET_PATH" "$cmd_json" || fail "prepare failed"
}

cmd_show() {
  local digest='' cmd_json
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --digest)
        [ "$#" -ge 2 ] || fail "--digest requires a value"
        digest=$2
        shift 2
        ;;
      -*)
        fail "unknown flag: $1"
        ;;
      *)
        fail "unexpected argument: $1"
        ;;
    esac
  done
  [ -n "$digest" ] || fail "show requires --digest"
  broker_paths
  cmd_json=$(python3 -c 'import json,sys; print(json.dumps({"op":"show","digest":sys.argv[1]}))' "$digest")
  run_broker "$GW_ROOT" "$AUDIT_PATH" "$SECRET_PATH" "$cmd_json" || fail "show failed"
}

cmd_approve() {
  local digest='' approver_id='' cmd_json
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --digest)
        [ "$#" -ge 2 ] || fail "--digest requires a value"
        digest=$2
        shift 2
        ;;
      --approver-id)
        [ "$#" -ge 2 ] || fail "--approver-id requires a value"
        approver_id=$2
        shift 2
        ;;
      --token)
        fail "approve no longer accepts --token (captain inbox only; privilege separation)"
        ;;
      -*)
        fail "unknown flag: $1"
        ;;
      *)
        fail "unexpected argument: $1"
        ;;
    esac
  done
  [ -n "$digest" ] || fail "approve requires --digest"
  [ -n "$approver_id" ] || fail "approve requires --approver-id"
  broker_paths
  cmd_json=$(python3 -c 'import json,sys; print(json.dumps({"op":"approve","digest":sys.argv[1],"approver_id":sys.argv[2]}))' "$digest" "$approver_id")
  run_broker "$GW_ROOT" "$AUDIT_PATH" "$SECRET_PATH" "$cmd_json" || fail "approve failed"
}

cmd_execute() {
  local digest='' cmd_json
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --digest)
        [ "$#" -ge 2 ] || fail "--digest requires a value"
        digest=$2
        shift 2
        ;;
      -*)
        fail "unknown flag: $1"
        ;;
      *)
        fail "unexpected argument: $1"
        ;;
    esac
  done
  [ -n "$digest" ] || fail "execute requires --digest"
  broker_paths
  cmd_json=$(python3 -c 'import json,sys; print(json.dumps({"op":"execute","digest":sys.argv[1]}))' "$digest")
  run_broker "$GW_ROOT" "$AUDIT_PATH" "$SECRET_PATH" "$cmd_json" || fail "execute failed"
}

cmd_status() {
  local digest='' cmd_json
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --digest)
        [ "$#" -ge 2 ] || fail "--digest requires a value"
        digest=$2
        shift 2
        ;;
      -*)
        fail "unknown flag: $1"
        ;;
      *)
        fail "unexpected argument: $1"
        ;;
    esac
  done
  [ -n "$digest" ] || fail "status requires --digest"
  broker_paths
  cmd_json=$(python3 -c 'import json,sys; print(json.dumps({"op":"status","digest":sys.argv[1]}))' "$digest")
  run_broker "$GW_ROOT" "$AUDIT_PATH" "$SECRET_PATH" "$cmd_json" || fail "status failed"
}

cmd_gate_check() {
  local digest='' cmd_json
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --digest)
        [ "$#" -ge 2 ] || fail "--digest requires a value"
        digest=$2
        shift 2
        ;;
      -*)
        fail "unknown flag: $1"
        ;;
      *)
        fail "unexpected argument: $1"
        ;;
    esac
  done
  [ -n "$digest" ] || fail "gate-check requires --digest"
  broker_paths
  cmd_json=$(python3 -c 'import json,sys; print(json.dumps({"op":"gate-check","digest":sys.argv[1]}))' "$digest")
  run_broker "$GW_ROOT" "$AUDIT_PATH" "$SECRET_PATH" "$cmd_json" || fail "gate-check failed"
}

cmd_replay() {
  local cmd_json
  [ "$#" -eq 0 ] || fail "replay takes no arguments"
  broker_paths
  cmd_json='{"op":"replay"}'
  run_broker "$GW_ROOT" "$AUDIT_PATH" "$SECRET_PATH" "$cmd_json" || fail "replay failed"
}

cmd_classify() {
  local kind='' cmd_json
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --action-kind)
        [ "$#" -ge 2 ] || fail "--action-kind requires a value"
        kind=$2
        shift 2
        ;;
      -*)
        fail "unknown flag: $1"
        ;;
      *)
        fail "unexpected argument: $1"
        ;;
    esac
  done
  [ -n "$kind" ] || fail "classify requires --action-kind"
  broker_paths
  cmd_json=$(python3 -c 'import json,sys; print(json.dumps({"op":"classify","action_kind":sys.argv[1]}))' "$kind")
  run_broker "$GW_ROOT" "$AUDIT_PATH" "$SECRET_PATH" "$cmd_json" || fail "classify failed"
}

main() {
  local op=''

  require_test_mode_for_overrides

  if [ "$#" -eq 0 ]; then
    cmd_prepare
    return 0
  fi

  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    prepare|show|approve|execute|status|gate-check|replay|classify)
      op=$1
      shift
      ;;
    --file)
      cmd_prepare "$@"
      return 0
      ;;
    -*)
      fail "unknown flag: $1"
      ;;
    *)
      fail "unknown command: $1"
      ;;
  esac

  case "$op" in
    prepare) cmd_prepare "$@" ;;
    show) cmd_show "$@" ;;
    approve) cmd_approve "$@" ;;
    execute) cmd_execute "$@" ;;
    status) cmd_status "$@" ;;
    gate-check) cmd_gate_check "$@" ;;
    replay) cmd_replay "$@" ;;
    classify) cmd_classify "$@" ;;
  esac
}

main "$@"
