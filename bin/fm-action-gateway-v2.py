#!/usr/bin/env python3
"""Firstmate action gateway v2 for unprivileged protocol tests.

This program implements isolation-program Step 2 sub-order items 1 through 4.
It has no outward executor and cannot complete an approval until the Step 2.5
signature verifier is installed.

Usage:
  fm-action-gateway-v2.py prepare
  fm-action-gateway-v2.py status --digest HEX
  fm-action-gateway-v2.py inspect-test-paths
  fm-action-gateway-v2.py issue-capability --purpose prepare|approval|execution --job-id ID [--uid UID]
  fm-action-gateway-v2.py serve [--socket-root PATH]
  fm-action-gateway-v2.py test-mark-executing --digest HEX

Production state has one fixed location.
FM_ACTION_GATEWAY_TEST=1 enables a synthetic temporary-root adapter derived from
TMPDIR so the Step 1 regression pack can exercise this code without installation.
The production service must use the fixed launch definitions planned for Step 5.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import contextlib
import ctypes
import errno
import hashlib
import json
import math
import os
import re
import secrets
import socket
import sqlite3
import stat
import struct
import sys
import threading
import time
import unicodedata
import urllib.parse
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, NoReturn, Optional, Sequence, Tuple

SCHEMA_PREPARE = "fm.prepare.v2"
SCHEMA_APPROVAL = "fm.approval.v2"
SCHEMA_EXECUTION = "fm.execution.v2"
PURPOSE_PREPARE = "prepare"
PURPOSE_APPROVAL = "approval"
PURPOSE_EXECUTION = "execution"
PRODUCTION_ROOT = Path("/var/db/firstmate/gateway")
PRODUCTION_SOCKET_ROOT = Path("/var/run/firstmate/gateway")
MAX_REQUEST_BYTES = 64 * 1024
MAX_FRAME_BYTES = 96 * 1024
MAX_DEPTH = 12
MAX_ITEMS = 256
MAX_STRING_BYTES = 32 * 1024
MAX_ATTACHMENTS = 8
MAX_ATTACHMENT_BYTES = 256 * 1024
MAX_MESSAGE_BYTES = 32 * 1024
MAX_RECIPIENTS = 64
MAX_PREPARES_PER_WINDOW = 8
RATE_WINDOW_SECONDS = 60
PLAN_TTL_SECONDS = 300
CHALLENGE_TTL_SECONDS = 60
CONNECTION_DEADLINE_SECONDS = 5.0
SAFE_INTEGER = 9_007_199_254_740_991
DIGEST_RE = re.compile(r"[0-9a-f]{64}")
ID_RE = re.compile(r"[A-Za-z0-9._-]{1,96}")
CURRENCY_RE = re.compile(r"[A-Z]{3}")
EMAIL_RE = re.compile(r"([^@\s]+)@([^@\s]+)")

REQUEST_KEYS = frozenset(
    {
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
    }
)
PARAMETER_KEYS = frozenset(
    {
        "recipient",
        "recipients",
        "to",
        "subject",
        "body",
        "message",
        "amount_minor",
        "amount_cents",
        "currency",
        "attachments",
    }
)
ATTACHMENT_KEYS = frozenset({"name", "media_type", "content_b64"})
ALLOWED_ACTIONS = frozenset(
    {
        "email.send",
        "message.send",
        "payment",
        "purchase",
        "http.request",
    }
)

POLICY_MANIFEST = {
    "schema": "fm.gateway-policy.v2",
    "outward_execution": False,
    "executor": "disabled",
    "redirect_policy": "deny",
    "allowed_actions": sorted(ALLOWED_ACTIONS),
    "max_request_bytes": MAX_REQUEST_BYTES,
    "max_message_bytes": MAX_MESSAGE_BYTES,
    "max_attachment_bytes": MAX_ATTACHMENT_BYTES,
    "max_attachments": MAX_ATTACHMENTS,
    "max_recipients": MAX_RECIPIENTS,
    "plan_ttl_seconds": PLAN_TTL_SECONDS,
}


class GatewayError(Exception):
    """A refusal safe to return over a narrow protocol."""


class DuplicateKey(GatewayError):
    pass


def fail(message: str) -> NoReturn:
    raise GatewayError(message)


def object_without_duplicates(pairs: List[Tuple[str, Any]]) -> Dict[str, Any]:
    result: Dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateKey(f"duplicate key refused: {key}")
        result[key] = value
    return result


def reject_float(value: str) -> NoReturn:
    raise GatewayError(f"non-integer JSON number refused: {value}")


def reject_constant(value: str) -> NoReturn:
    raise GatewayError(f"non-finite JSON number refused: {value}")


def validate_bounds(value: Any, depth: int = 0) -> None:
    if depth > MAX_DEPTH:
        fail(f"JSON nesting exceeds {MAX_DEPTH}")
    if value is None or isinstance(value, bool):
        return
    if isinstance(value, int):
        if abs(value) > SAFE_INTEGER:
            fail("integer exceeds the RFC 8785 interoperable range")
        return
    if isinstance(value, float):
        if not math.isfinite(value):
            fail("non-finite number refused")
        fail("floating-point numbers are refused; use typed integer minor units")
    if isinstance(value, str):
        if any(0xD800 <= ord(character) <= 0xDFFF for character in value):
            fail("unpaired Unicode surrogate refused")
        if len(value.encode("utf-8")) > MAX_STRING_BYTES:
            fail("JSON string exceeds size limit")
        return
    if isinstance(value, list):
        if len(value) > MAX_ITEMS:
            fail("JSON array exceeds item limit")
        for item in value:
            validate_bounds(item, depth + 1)
        return
    if isinstance(value, dict):
        if len(value) > MAX_ITEMS:
            fail("JSON object exceeds member limit")
        for key, item in value.items():
            if not isinstance(key, str):
                fail("JSON object keys must be strings")
            validate_bounds(key, depth + 1)
            validate_bounds(item, depth + 1)
        return
    fail(f"unsupported JSON value type: {type(value).__name__}")


def strict_json(raw: bytes, maximum: int = MAX_REQUEST_BYTES) -> Any:
    if len(raw) > maximum:
        fail(f"request exceeds {maximum} bytes")
    try:
        text = raw.decode("utf-8", "strict")
    except UnicodeDecodeError as exc:
        fail(f"request is not UTF-8: {exc}")
    try:
        value = json.loads(
            text,
            object_pairs_hook=object_without_duplicates,
            parse_float=reject_float,
            parse_constant=reject_constant,
        )
    except GatewayError:
        raise
    except (json.JSONDecodeError, UnicodeError, RecursionError, ValueError) as exc:
        fail(f"malformed JSON refused: {exc}")
    validate_bounds(value)
    return value


def utf16_sort_key(value: str) -> bytes:
    return value.encode("utf-16-be", "surrogatepass")


def jcs_string(value: str) -> str:
    # Python's encoder emits the RFC 8785-compatible escapes for strings when
    # ensure_ascii is false and separators are irrelevant for one scalar.
    return json.dumps(value, ensure_ascii=False, allow_nan=False)


def jcs(value: Any) -> str:
    """Canonicalize the integer-only RFC 8785 subset accepted by this gateway."""
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, int) and not isinstance(value, bool):
        if abs(value) > SAFE_INTEGER:
            fail("integer exceeds the RFC 8785 interoperable range")
        return str(value)
    if isinstance(value, str):
        return jcs_string(value)
    if isinstance(value, list):
        return "[" + ",".join(jcs(item) for item in value) + "]"
    if isinstance(value, dict):
        keys = sorted(value, key=utf16_sort_key)
        return "{" + ",".join(jcs_string(key) + ":" + jcs(value[key]) for key in keys) + "}"
    fail(f"value is outside the accepted RFC 8785 subset: {type(value).__name__}")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def canonical_bytes(value: Any) -> bytes:
    validate_bounds(value)
    return jcs(value).encode("utf-8")


def require_exact_keys(value: Any, allowed: Iterable[str], required: Iterable[str], label: str) -> Dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{label} must be an object")
    allowed_set = set(allowed)
    required_set = set(required)
    unknown = sorted(set(value) - allowed_set)
    missing = sorted(required_set - set(value))
    if unknown:
        fail(f"unknown {label} keys: {', '.join(unknown)}")
    if missing:
        fail(f"missing {label} keys: {', '.join(missing)}")
    return value


def required_string(value: Any, label: str, maximum: int = 4096) -> str:
    if not isinstance(value, str) or not value or "\x00" in value:
        fail(f"{label} must be a non-empty string without NUL")
    if len(value.encode("utf-8")) > maximum:
        fail(f"{label} exceeds its size limit")
    return value


def normalized_email(value: Any) -> Dict[str, str]:
    raw = required_string(value, "recipient", 512)
    match = EMAIL_RE.fullmatch(raw)
    if not match:
        fail(f"recipient is not a complete address: {raw!r}")
    local, domain = match.groups()
    try:
        punycode = domain.rstrip(".").encode("idna").decode("ascii").lower()
    except UnicodeError:
        fail(f"recipient domain cannot be normalized: {domain!r}")
    if not punycode or len(punycode) > 253:
        fail("recipient domain is invalid")
    unicode_domain = unicodedata.normalize("NFC", domain.rstrip("."))
    return {
        "address": f"{local}@{punycode}",
        "unicode": f"{local}@{unicode_domain}",
        "punycode": f"{local}@{punycode}",
    }


def normalized_endpoint(target: Any) -> Dict[str, Any]:
    raw = required_string(target, "target", 2048)
    try:
        parsed = urllib.parse.urlsplit(raw)
        hostname = parsed.hostname
    except ValueError as exc:
        fail(f"target is not a parseable URL: {exc}")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        fail("target credentials, query, and fragment are refused")
    scheme = parsed.scheme.lower()
    if scheme not in ("https", "smtp"):
        fail("target scheme must be https or smtp")
    if not hostname:
        fail("target must have a complete host")
    try:
        host = hostname.encode("idna").decode("ascii").lower()
    except UnicodeError:
        fail("target host cannot be normalized")
    try:
        port = parsed.port
    except ValueError:
        fail("target port is invalid")
    if port is not None and port not in (443, 465, 587):
        fail("target port is not allowlisted")
    default_port = 443 if scheme == "https" else 587
    normalized_port = port or default_port
    path = parsed.path or "/"
    if any(segment in (".", "..") for segment in path.split("/")):
        fail("target path traversal is refused")
    netloc = host if normalized_port == default_port else f"{host}:{normalized_port}"
    return {
        "url": urllib.parse.urlunsplit((scheme, netloc, path, "", "")),
        "scheme": scheme,
        "host_punycode": host,
        "host_unicode": unicodedata.normalize("NFC", hostname),
        "port": normalized_port,
        "path": path,
    }


def resolve_recipients(parameters: Dict[str, Any]) -> List[Dict[str, str]]:
    candidate_keys = [key for key in ("recipient", "recipients", "to") if key in parameters]
    if len(candidate_keys) > 1:
        fail("recipient aliases are ambiguous; supply exactly one recipient field")
    if not candidate_keys:
        return []
    value = parameters[candidate_keys[0]]
    values = value if isinstance(value, list) else [value]
    if not values or len(values) > MAX_RECIPIENTS:
        fail("recipient count is outside the allowed range")
    normalized = [normalized_email(item) for item in values]
    addresses = [item["address"] for item in normalized]
    if len(addresses) != len(set(addresses)):
        fail("duplicate recipients are refused")
    return normalized


def resolve_money(parameters: Dict[str, Any]) -> Dict[str, Any]:
    money_keys = [key for key in ("amount_minor", "amount_cents") if key in parameters]
    if len(money_keys) > 1:
        fail("ambiguous money fields are refused")
    if not money_keys:
        if "currency" in parameters:
            fail("currency without an integer minor-unit amount is refused")
        return {"amount_minor": None, "currency": None}
    amount = parameters[money_keys[0]]
    if isinstance(amount, bool) or not isinstance(amount, int):
        fail("money must use an integer minor-unit value")
    if amount < 0 or amount > 100_000_000_000:
        fail("money amount is outside the allowed range")
    currency = parameters.get("currency")
    if not isinstance(currency, str) or not CURRENCY_RE.fullmatch(currency):
        fail("money requires an uppercase ISO 4217 currency")
    return {"amount_minor": amount, "currency": currency}


def resolve_attachments(parameters: Dict[str, Any]) -> List[Dict[str, Any]]:
    raw_attachments = parameters.get("attachments", [])
    if not isinstance(raw_attachments, list) or len(raw_attachments) > MAX_ATTACHMENTS:
        fail("attachments must be a bounded array")
    resolved: List[Dict[str, Any]] = []
    total = 0
    for index, raw in enumerate(raw_attachments):
        attachment = require_exact_keys(raw, ATTACHMENT_KEYS, ATTACHMENT_KEYS, f"attachment[{index}]")
        name = required_string(attachment["name"], "attachment name", 255)
        if name in (".", "..") or "/" in name or "\\" in name or any(ord(ch) < 32 for ch in name):
            fail("attachment name is not path-safe")
        media_type = required_string(attachment["media_type"], "attachment media_type", 255)
        encoded = required_string(attachment["content_b64"], "attachment content_b64", MAX_ATTACHMENT_BYTES * 2)
        try:
            content = base64.b64decode(encoded, validate=True)
        except (ValueError, binascii.Error):
            fail("attachment content_b64 is not canonical base64")
        if base64.b64encode(content).decode("ascii") != encoded:
            fail("attachment content_b64 is not canonical base64")
        total += len(content)
        if len(content) > MAX_ATTACHMENT_BYTES or total > MAX_ATTACHMENT_BYTES:
            fail("attachment bytes exceed the resource limit")
        resolved.append(
            {
                "index": index,
                "name": name,
                "media_type": media_type,
                "size": len(content),
                "sha256": sha256_bytes(content),
                "bytes_b64": encoded,
            }
        )
    return resolved


def resolve_message(parameters: Dict[str, Any]) -> Dict[str, Any]:
    message_keys = [key for key in ("body", "message") if key in parameters]
    if len(message_keys) > 1:
        fail("body and message together are ambiguous")
    body = parameters.get(message_keys[0], "") if message_keys else ""
    body = required_string(body, "message", MAX_MESSAGE_BYTES) if body != "" else ""
    subject = parameters.get("subject", "")
    if not isinstance(subject, str):
        fail("subject must be a string")
    subject_bytes = subject.encode("utf-8")
    body_bytes = body.encode("utf-8")
    if len(subject_bytes) + len(body_bytes) > MAX_MESSAGE_BYTES:
        fail("message bytes exceed the resource limit")
    return {
        "subject_bytes_b64": base64.b64encode(subject_bytes).decode("ascii"),
        "subject_sha256": sha256_bytes(subject_bytes),
        "body_bytes_b64": base64.b64encode(body_bytes).decode("ascii"),
        "body_sha256": sha256_bytes(body_bytes),
        "total_bytes": len(subject_bytes) + len(body_bytes),
    }


def executable_identity() -> Tuple[str, str]:
    source = Path(__file__).resolve().read_bytes()
    return sha256_bytes(source), "fm-action-gateway-v2/2.0-test"


def resolve_plan(request: Any, requester: Dict[str, Any], now: int) -> Tuple[Dict[str, Any], str, str]:
    req = require_exact_keys(request, REQUEST_KEYS, REQUEST_KEYS, "ActionRequest")
    for key in ("task_id", "domain", "action_kind", "target", "requested_consent_tier", "environment", "policy_version", "idempotency_key", "nonce", "requester_id"):
        required_string(req[key], key)
    if not ID_RE.fullmatch(req["task_id"]):
        fail("task_id must be path-safe")
    if not ID_RE.fullmatch(req["idempotency_key"]):
        fail("idempotency_key must be path-safe")
    if req["action_kind"] not in ALLOWED_ACTIONS:
        fail("unknown action_kind refused by the closed registry")
    if req["requested_consent_tier"] != "confirm-first":
        fail("gateway v2 accepts only confirm-first requests")
    if isinstance(req["expires_at"], bool) or not isinstance(req["expires_at"], int):
        fail("expires_at must be an integer compatibility hint")
    parameters = require_exact_keys(req["parameters"], PARAMETER_KEYS, (), "parameters")
    endpoint = normalized_endpoint(req["target"])
    recipients = resolve_recipients(parameters)
    money = resolve_money(parameters)
    message = resolve_message(parameters)
    attachments = resolve_attachments(parameters)
    if req["action_kind"] in ("email.send", "message.send") and not recipients:
        fail("messaging requires complete recipients")
    if req["action_kind"] in ("payment", "purchase") and money["amount_minor"] is None:
        fail("money actions require integer minor units and currency")
    policy_hash = sha256_bytes(canonical_bytes(POLICY_MANIFEST))
    executor_hash, executor_version = executable_identity()
    request_id = secrets.token_hex(16)
    broker_nonce = secrets.token_hex(32)
    expires_at = now + PLAN_TTL_SECONDS
    plan = {
        "schema": "fm.execution-plan.v2",
        "request_id": request_id,
        "broker_nonce": broker_nonce,
        "prepared_at": now,
        "expires_at": expires_at,
        "operation": req["action_kind"],
        "provider_account": {
            "provider": "firstmate-local-safe-sink",
            "account_id": "safe-sink:test-only",
            "environment": "test-disabled-outward",
        },
        "endpoint": endpoint,
        "method": "SAFE_SINK_APPEND",
        "money": money,
        "recipients": recipients,
        "recipient_count": len(recipients),
        "message": message,
        "attachments": attachments,
        "attachment_count": len(attachments),
        "redirect_policy": {"mode": "deny", "maximum": 0},
        "resource_limits": {
            "request_bytes": MAX_REQUEST_BYTES,
            "message_bytes": MAX_MESSAGE_BYTES,
            "attachment_bytes": MAX_ATTACHMENT_BYTES,
            "attachments": MAX_ATTACHMENTS,
            "recipients": MAX_RECIPIENTS,
            "wall_seconds": 10,
        },
        "policy_manifest_hash": policy_hash,
        "executor": {
            "kind": "disabled-safe-sink-pending-step-2.6",
            "sha256": executor_hash,
            "version": executor_version,
            "outward_execution": False,
        },
        "requester": requester,
        "job_id": requester["job_id"],
        "idempotency_key": req["idempotency_key"],
        "compatibility_hints": {
            "caller_nonce_sha256": sha256_bytes(req["nonce"].encode("utf-8")),
            "caller_expiry_ignored": True,
            "self_declared_requester_ignored": True,
        },
    }
    encoded = canonical_bytes(plan)
    return plan, sha256_bytes(encoded), sha256_bytes(canonical_bytes(req))


def test_mode() -> bool:
    return os.environ.get("FM_ACTION_GATEWAY_TEST") == "1"


def state_root() -> Path:
    if test_mode():
        tmp = Path(os.environ.get("TMPDIR", "/tmp"))
        return tmp / "fm-gateway-v2-state"
    return PRODUCTION_ROOT


def socket_root() -> Path:
    if test_mode():
        return state_root() / "run"
    return PRODUCTION_SOCKET_ROOT


def ensure_private_directory(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)
    path.chmod(0o700)
    mode = stat.S_IMODE(path.stat().st_mode)
    if mode != 0o700:
        fail(f"state directory mode must be 0700, got {mode:04o}")


def database_path() -> Path:
    return state_root() / "gateway-v2.sqlite3"


def audit_path() -> Path:
    return state_root() / "audit-v2.jsonl"


def connect_database() -> sqlite3.Connection:
    root = state_root()
    ensure_private_directory(root)
    db_path = database_path()
    connection = sqlite3.connect(db_path, timeout=10, isolation_level=None)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA foreign_keys=ON")
    connection.execute("PRAGMA journal_mode=WAL")
    connection.execute("PRAGMA synchronous=FULL")
    initialize_schema(connection)
    with contextlib.suppress(OSError):
        db_path.chmod(0o600)
    return connection


@contextlib.contextmanager
def open_database() -> Iterable[sqlite3.Connection]:
    """Own one connection for a command or a socket thread and always close it."""
    connection = connect_database()
    try:
        with connection:
            yield connection
    finally:
        connection.close()


def initialize_schema(db: sqlite3.Connection) -> None:
    db.executescript(
        """
        CREATE TABLE IF NOT EXISTS requests (
          request_id TEXT PRIMARY KEY,
          digest TEXT NOT NULL UNIQUE,
          broker_nonce TEXT NOT NULL UNIQUE,
          idempotency_key TEXT NOT NULL UNIQUE,
          request_fingerprint TEXT NOT NULL UNIQUE,
          requester_uid INTEGER NOT NULL,
          job_id TEXT NOT NULL,
          plan_jcs BLOB NOT NULL,
          state TEXT NOT NULL CHECK(state IN ('prepared','approved','executing','succeeded','failed','unknown')),
          prepared_at INTEGER NOT NULL,
          expires_at INTEGER NOT NULL,
          reconciliation_required INTEGER NOT NULL DEFAULT 0 CHECK(reconciliation_required IN (0,1))
        );
        CREATE TABLE IF NOT EXISTS request_id_tombstones (
          request_id TEXT PRIMARY KEY,
          digest TEXT NOT NULL UNIQUE,
          created_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS nonce_tombstones (
          nonce TEXT PRIMARY KEY,
          request_id TEXT NOT NULL UNIQUE,
          created_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS idempotency_tombstones (
          idempotency_key TEXT PRIMARY KEY,
          request_id TEXT NOT NULL UNIQUE,
          request_fingerprint TEXT NOT NULL,
          created_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS challenges (
          challenge_id TEXT PRIMARY KEY,
          challenge_nonce TEXT NOT NULL UNIQUE,
          request_id TEXT NOT NULL UNIQUE REFERENCES requests(request_id),
          ui_id TEXT NOT NULL,
          transcript_digest TEXT NOT NULL UNIQUE,
          created_at INTEGER NOT NULL,
          expires_at INTEGER NOT NULL,
          consumed_at INTEGER
        );
        CREATE TABLE IF NOT EXISTS approvals (
          approval_id TEXT PRIMARY KEY,
          request_id TEXT NOT NULL UNIQUE REFERENCES requests(request_id),
          challenge_id TEXT NOT NULL UNIQUE REFERENCES challenges(challenge_id),
          transcript_digest TEXT NOT NULL UNIQUE,
          signature_hash TEXT NOT NULL UNIQUE,
          approver_identity TEXT NOT NULL,
          approved_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS capabilities (
          capability_hash TEXT PRIMARY KEY,
          purpose TEXT NOT NULL CHECK(purpose IN ('prepare','approval','execution')),
          job_id TEXT NOT NULL,
          peer_uid INTEGER NOT NULL,
          created_at INTEGER NOT NULL,
          expires_at INTEGER NOT NULL,
          consumed_at INTEGER
        );
        CREATE TABLE IF NOT EXISTS token_consumptions (
          token_hash TEXT PRIMARY KEY,
          purpose TEXT NOT NULL,
          request_id TEXT,
          consumed_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS rate_events (
          peer_uid INTEGER NOT NULL,
          occurred_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS audit_events (
          sequence INTEGER PRIMARY KEY AUTOINCREMENT,
          event_type TEXT NOT NULL,
          request_id TEXT,
          event_jcs BLOB NOT NULL,
          created_at INTEGER NOT NULL
        );
        """
    )


def transaction(db: sqlite3.Connection) -> contextlib.AbstractContextManager[None]:
    @contextlib.contextmanager
    def managed() -> Iterable[None]:
        db.execute("BEGIN IMMEDIATE")
        try:
            yield
        except Exception:
            db.execute("ROLLBACK")
            raise
        else:
            db.execute("COMMIT")
    return managed()


def append_audit(db: sqlite3.Connection, event_type: str, request_id: Optional[str], event: Dict[str, Any], now: int) -> None:
    encoded = canonical_bytes(event)
    db.execute(
        "INSERT INTO audit_events(event_type,request_id,event_jcs,created_at) VALUES(?,?,?,?)",
        (event_type, request_id, encoded, now),
    )
    # The JSONL file is evidence only. SQLite state and tombstones remain the
    # authority and survive audit-file rotation.
    line = encoded + b"\n"
    path = audit_path()
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        os.write(fd, line)
        os.fsync(fd)
    finally:
        os.close(fd)


def recover_interrupted(db: sqlite3.Connection) -> None:
    """Reconcile executions a crash interrupted; a process runs this once at startup."""
    now = int(time.time())
    if db.execute("SELECT 1 FROM requests WHERE state='executing' LIMIT 1").fetchone() is None:
        return
    with transaction(db):
        rows = list(db.execute("SELECT request_id,digest FROM requests WHERE state='executing'"))
        for row in rows:
            db.execute(
                "UPDATE requests SET state='unknown', reconciliation_required=1 WHERE request_id=? AND state='executing'",
                (row["request_id"],),
            )
            append_audit(
                db,
                "execution-uncertain",
                row["request_id"],
                {
                    "schema": "fm.audit-event.v2",
                    "event": "execution-uncertain",
                    "request_id": row["request_id"],
                    "digest": row["digest"],
                    "state": "unknown",
                    "provider_reconciliation_required": True,
                    "at": now,
                },
                now,
            )


def requester_identity(peer_uid: int, job_id: str) -> Dict[str, Any]:
    return {
        "principal": "peer-credential",
        "peer_uid": peer_uid,
        "job_id": job_id,
        "authority_from_request": False,
    }


def check_rate_limit(db: sqlite3.Connection, peer_uid: int, now: int) -> None:
    db.execute("DELETE FROM rate_events WHERE occurred_at < ?", (now - RATE_WINDOW_SECONDS,))
    count = db.execute("SELECT COUNT(*) FROM rate_events WHERE peer_uid=?", (peer_uid,)).fetchone()[0]
    db.execute("INSERT INTO rate_events(peer_uid,occurred_at) VALUES(?,?)", (peer_uid, now))
    if count >= MAX_PREPARES_PER_WINDOW:
        fail("prepare rate limit exceeded")


def capability_hash(token: str) -> str:
    return sha256_bytes(token.encode("ascii"))


def issue_capability(db: sqlite3.Connection, purpose: str, job_id: str, peer_uid: int, now: int) -> str:
    if purpose not in (PURPOSE_PREPARE, PURPOSE_APPROVAL, PURPOSE_EXECUTION):
        fail("unknown capability purpose")
    if not ID_RE.fullmatch(job_id):
        fail("job_id must be path-safe")
    token = secrets.token_urlsafe(32)
    db.execute(
        "INSERT INTO capabilities(capability_hash,purpose,job_id,peer_uid,created_at,expires_at) VALUES(?,?,?,?,?,?)",
        (capability_hash(token), purpose, job_id, peer_uid, now, now + 600),
    )
    return token


def verify_capability(db: sqlite3.Connection, token: Any, purpose: str, peer_uid: int, now: int, consume: bool = False, request_id: Optional[str] = None) -> str:
    if not isinstance(token, str) or not token or len(token) > 256:
        fail("missing per-job capability")
    token_hash = capability_hash(token)
    row = db.execute("SELECT * FROM capabilities WHERE capability_hash=?", (token_hash,)).fetchone()
    if row is None:
        fail("unknown per-job capability")
    if row["purpose"] != purpose or row["peer_uid"] != peer_uid:
        fail("capability does not match protocol purpose and peer credentials")
    if row["expires_at"] <= now or row["consumed_at"] is not None:
        fail("capability expired or consumed")
    if consume:
        db.execute("UPDATE capabilities SET consumed_at=? WHERE capability_hash=? AND consumed_at IS NULL", (now, token_hash))
        try:
            db.execute(
                "INSERT INTO token_consumptions(token_hash,purpose,request_id,consumed_at) VALUES(?,?,?,?)",
                (token_hash, purpose, request_id, now),
            )
        except sqlite3.IntegrityError:
            fail("capability token replay refused")
    return str(row["job_id"])


def prepare_action(db: sqlite3.Connection, action: Any, peer_uid: int, job_id: str, now: Optional[int] = None) -> Dict[str, Any]:
    current = int(time.time()) if now is None else now
    requester = requester_identity(peer_uid, job_id)
    plan, digest, fingerprint = resolve_plan(action, requester, current)
    if plan["job_id"] != job_id:
        fail("resolved plan job mismatch")
    with transaction(db):
        check_rate_limit(db, peer_uid, current)
        for query, value, message in (
            ("SELECT 1 FROM idempotency_tombstones WHERE idempotency_key=?", plan["idempotency_key"], "idempotency key replay refused"),
            ("SELECT 1 FROM requests WHERE request_fingerprint=?", fingerprint, "request replay refused"),
        ):
            if db.execute(query, (value,)).fetchone() is not None:
                fail(message)
        try:
            db.execute(
                "INSERT INTO requests(request_id,digest,broker_nonce,idempotency_key,request_fingerprint,requester_uid,job_id,plan_jcs,state,prepared_at,expires_at) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                (
                    plan["request_id"],
                    digest,
                    plan["broker_nonce"],
                    plan["idempotency_key"],
                    fingerprint,
                    peer_uid,
                    job_id,
                    canonical_bytes(plan),
                    "prepared",
                    current,
                    plan["expires_at"],
                ),
            )
            db.execute(
                "INSERT INTO request_id_tombstones(request_id,digest,created_at) VALUES(?,?,?)",
                (plan["request_id"], digest, current),
            )
            db.execute(
                "INSERT INTO nonce_tombstones(nonce,request_id,created_at) VALUES(?,?,?)",
                (plan["broker_nonce"], plan["request_id"], current),
            )
            db.execute(
                "INSERT INTO idempotency_tombstones(idempotency_key,request_id,request_fingerprint,created_at) VALUES(?,?,?,?)",
                (plan["idempotency_key"], plan["request_id"], fingerprint, current),
            )
        except sqlite3.IntegrityError as exc:
            fail(f"unique request identity refused: {exc}")
        append_audit(
            db,
            "prepared",
            plan["request_id"],
            {
                "schema": "fm.audit-event.v2",
                "event": "prepared",
                "request_id": plan["request_id"],
                "digest": digest,
                "state": "prepared",
                "requester": requester,
                "at": current,
            },
            current,
        )
    return {
        "schema": SCHEMA_PREPARE,
        "decision": "confirm-first",
        "state": "prepared",
        "request_id": plan["request_id"],
        "digest": digest,
        "expires_at": plan["expires_at"],
        "requester_uid": peer_uid,
        "job_id": job_id,
        "outward_execution": False,
    }


def get_request_by_digest(db: sqlite3.Connection, digest: str) -> sqlite3.Row:
    if not DIGEST_RE.fullmatch(digest):
        fail("digest must be lowercase SHA-256 hex")
    row = db.execute("SELECT * FROM requests WHERE digest=?", (digest,)).fetchone()
    if row is None:
        fail("unknown digest")
    return row


def status_action(db: sqlite3.Connection, digest: str) -> Dict[str, Any]:
    row = get_request_by_digest(db, digest)
    return {
        "schema": "fm.gateway-status.v2",
        "decision": "confirm-first",
        "state": row["state"],
        "request_id": row["request_id"],
        "digest": row["digest"],
        "expires_at": row["expires_at"],
        "reconciliation_required": bool(row["reconciliation_required"]),
        "outward_execution": False,
    }


def transcript_for_challenge(row: sqlite3.Row, challenge_nonce: str, challenge_expires: int) -> Dict[str, Any]:
    plan = strict_json(bytes(row["plan_jcs"]), MAX_FRAME_BYTES)
    return {
        "schema": "fm.approval-transcript.v2",
        "resolved_plan": plan,
        "resolved_plan_digest": row["digest"],
        "gateway_challenge": challenge_nonce,
        "challenge_expires_at": challenge_expires,
        "policy_manifest_hash": plan["policy_manifest_hash"],
        "executor_hash": plan["executor"]["sha256"],
        "executor_version": plan["executor"]["version"],
        "provider_account": plan["provider_account"],
    }


def issue_challenge(db: sqlite3.Connection, request_id: str, ui_id: str, capability_job_id: str, now: int) -> Dict[str, Any]:
    required_string(ui_id, "ui_id", 128)
    with transaction(db):
        row = db.execute("SELECT * FROM requests WHERE request_id=?", (request_id,)).fetchone()
        if row is None:
            fail("unknown request_id")
        if row["job_id"] != capability_job_id:
            fail("approval capability is not scoped to the request job")
        if row["state"] != "prepared" or row["expires_at"] <= now:
            fail("request is not eligible for approval")
        if db.execute("SELECT 1 FROM challenges WHERE request_id=?", (request_id,)).fetchone() is not None:
            fail("challenge already issued for request")
        challenge_id = secrets.token_hex(16)
        challenge_nonce = secrets.token_hex(32)
        expires_at = min(row["expires_at"], now + CHALLENGE_TTL_SECONDS)
        transcript = transcript_for_challenge(row, challenge_nonce, expires_at)
        transcript_digest = sha256_bytes(canonical_bytes(transcript))
        db.execute(
            "INSERT INTO challenges(challenge_id,challenge_nonce,request_id,ui_id,transcript_digest,created_at,expires_at) VALUES(?,?,?,?,?,?,?)",
            (challenge_id, challenge_nonce, request_id, ui_id, transcript_digest, now, expires_at),
        )
        append_audit(
            db,
            "challenge-issued",
            request_id,
            {
                "schema": "fm.audit-event.v2",
                "event": "challenge-issued",
                "request_id": request_id,
                "challenge_id": challenge_id,
                "transcript_digest": transcript_digest,
                "ui_id": ui_id,
                "at": now,
            },
            now,
        )
    return {
        "schema": SCHEMA_APPROVAL,
        "state": "challenge-issued",
        "challenge_id": challenge_id,
        "transcript": transcript,
        "transcript_digest": transcript_digest,
        "approval_enabled": False,
        "reason": "secure-signature-verifier-is-step-2.5",
    }


def protocol_prepare(db: sqlite3.Connection, message: Any, peer_uid: int) -> Dict[str, Any]:
    envelope = require_exact_keys(message, {"schema", "capability", "action"}, {"schema", "capability", "action"}, "prepare envelope")
    if envelope["schema"] != SCHEMA_PREPARE:
        fail("wrong schema on prepare channel")
    now = int(time.time())
    with transaction(db):
        job_id = verify_capability(db, envelope["capability"], PURPOSE_PREPARE, peer_uid, now)
    action = envelope["action"]
    if not isinstance(action, dict) or action.get("task_id") != job_id:
        fail("prepare capability is not scoped to this job")
    return prepare_action(db, action, peer_uid, job_id, now)


def protocol_approval(db: sqlite3.Connection, message: Any, peer_uid: int) -> Dict[str, Any]:
    envelope = require_exact_keys(
        message,
        {"schema", "op", "capability", "request_id", "ui_id", "challenge_id", "signature"},
        {"schema", "op", "capability", "request_id", "ui_id"},
        "approval envelope",
    )
    if envelope["schema"] != SCHEMA_APPROVAL:
        fail("wrong schema on approval channel")
    now = int(time.time())
    with transaction(db):
        capability_job_id = verify_capability(db, envelope["capability"], PURPOSE_APPROVAL, peer_uid, now)
    if envelope["op"] == "challenge":
        if "challenge_id" in envelope or "signature" in envelope:
            fail("challenge request contains approval-only fields")
        return issue_challenge(db, envelope["request_id"], envelope["ui_id"], capability_job_id, now)
    if envelope["op"] == "approve":
        # Sub-order 4 exposes the isolated protocol but cannot accept approval
        # before sub-order 5 installs mutual UI auth and exact-transcript signing.
        fail("approval submission disabled until the Step 2.5 signature verifier is installed")
    fail("unknown approval operation")


def protocol_execution(db: sqlite3.Connection, message: Any, peer_uid: int) -> Dict[str, Any]:
    envelope = require_exact_keys(
        message,
        {"schema", "capability", "request_id", "idempotency_key"},
        {"schema", "capability", "request_id", "idempotency_key"},
        "execution envelope",
    )
    if envelope["schema"] != SCHEMA_EXECUTION:
        fail("wrong schema on execution channel")
    now = int(time.time())
    with transaction(db):
        capability_job_id = verify_capability(db, envelope["capability"], PURPOSE_EXECUTION, peer_uid, now)
        row = db.execute("SELECT * FROM requests WHERE request_id=?", (envelope["request_id"],)).fetchone()
        if row is None:
            fail("unknown request_id")
        if row["job_id"] != capability_job_id:
            fail("execution capability is not scoped to the request job")
        if row["idempotency_key"] != envelope["idempotency_key"]:
            fail("execution idempotency key does not bind to the immutable plan")
        if row["state"] != "approved":
            fail("execution requires a signed approved immutable plan")
        fail("execution disabled until the deterministic safe sink lands in Step 2.6")


def peer_credentials(connection: socket.socket) -> Tuple[int, int]:
    # Darwin exposes getpeereid in libc even when Python's socket object omits
    # the convenience method. Linux exposes SO_PEERCRED. LOCAL_PEERCRED remains
    # the kernel-level Darwin socket option behind getpeereid.
    if hasattr(connection, "getpeereid"):
        uid, gid = connection.getpeereid()  # type: ignore[attr-defined]
        return int(uid), int(gid)
    if sys.platform == "darwin":
        uid_value = ctypes.c_uint()
        gid_value = ctypes.c_uint()
        libc = ctypes.CDLL(None, use_errno=True)
        getpeereid = libc.getpeereid
        getpeereid.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_uint), ctypes.POINTER(ctypes.c_uint)]
        getpeereid.restype = ctypes.c_int
        if getpeereid(connection.fileno(), ctypes.byref(uid_value), ctypes.byref(gid_value)) != 0:
            error_number = ctypes.get_errno()
            fail(f"getpeereid failed: {os.strerror(error_number)}")
        return int(uid_value.value), int(gid_value.value)
    if hasattr(socket, "SO_PEERCRED"):
        raw = connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
        _pid, uid, gid = struct.unpack("3i", raw)
        return int(uid), int(gid)
    LOCAL_PEERCRED = getattr(socket, "LOCAL_PEERCRED", None)
    if LOCAL_PEERCRED is not None:
        fail("LOCAL_PEERCRED parsing is marked for privileged Step 5 platform proof")
    fail("no supported peer-credential primitive on this platform")


def receive_frame(connection: socket.socket, deadline: float) -> bytes:
    def receive_exactly(size: int) -> bytes:
        buffer = bytearray()
        while len(buffer) < size:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                fail("protocol frame deadline exceeded")
            connection.settimeout(remaining)
            try:
                chunk = connection.recv(min(8192, size - len(buffer)))
            except TimeoutError:
                fail("protocol frame deadline exceeded")
            if not chunk:
                fail("truncated protocol frame")
            buffer.extend(chunk)
        return bytes(buffer)

    length = struct.unpack("!I", receive_exactly(4))[0]
    if length == 0 or length > MAX_FRAME_BYTES:
        fail("protocol frame size refused")
    return receive_exactly(length)


def send_frame(connection: socket.socket, value: Dict[str, Any]) -> None:
    body = canonical_bytes(value)
    connection.sendall(struct.pack("!I", len(body)) + body)


def refusal_text(exc: BaseException) -> str:
    if isinstance(exc, (GatewayError, sqlite3.Error, OSError)):
        return str(exc) or type(exc).__name__
    return f"gateway refused the request: {type(exc).__name__}"


def handle_connection(
    db: sqlite3.Connection,
    connection: socket.socket,
    handler: Callable[[sqlite3.Connection, Any, int], Dict[str, Any]],
) -> None:
    deadline = time.monotonic() + CONNECTION_DEADLINE_SECONDS
    try:
        connection.settimeout(CONNECTION_DEADLINE_SECONDS)
        peer_uid, _peer_gid = peer_credentials(connection)
        message = strict_json(receive_frame(connection, deadline), MAX_FRAME_BYTES)
        connection.settimeout(CONNECTION_DEADLINE_SECONDS)
        result = handler(db, message, peer_uid)
        send_frame(connection, {"ok": True, "result": result})
    except Exception as exc:
        if not isinstance(exc, (GatewayError, sqlite3.Error, OSError)):
            print(f"fm-action-gateway-v2: handler failure: {type(exc).__name__}: {exc}", file=sys.stderr, flush=True)
        if db.in_transaction:
            with contextlib.suppress(sqlite3.Error):
                db.execute("ROLLBACK")
        with contextlib.suppress(Exception):
            send_frame(connection, {"ok": False, "error": refusal_text(exc)})


def serve_channel(
    path: Path,
    handler: Callable[[sqlite3.Connection, Any, int], Dict[str, Any]],
    ready: threading.Event,
    stopped: threading.Event,
) -> None:
    try:
        serve_socket(path, handler, ready)
    finally:
        stopped.set()


def serve_socket(path: Path, handler: Callable[[sqlite3.Connection, Any, int], Dict[str, Any]], ready: threading.Event) -> None:
    with contextlib.suppress(FileNotFoundError):
        path.unlink()
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        listener.bind(str(path))
        path.chmod(0o600)
        listener.listen(16)
        with open_database() as db:
            ready.set()
            while True:
                try:
                    connection, _ = listener.accept()
                except OSError as exc:
                    if exc.errno in (errno.EBADF, errno.EINVAL, errno.ENOTSOCK):
                        return
                    print(f"fm-action-gateway-v2: accept failed on {path.name}: {exc}", file=sys.stderr, flush=True)
                    time.sleep(0.05)
                    continue
                with connection:
                    handle_connection(db, connection, handler)
    finally:
        listener.close()


def serve(root: Path) -> None:
    ensure_private_directory(root)
    with open_database() as db:
        recover_interrupted(db)
    handlers = {
        root / "prepare.sock": protocol_prepare,
        root / "approval.sock": protocol_approval,
        root / "execution.sock": protocol_execution,
    }
    readiness: List[threading.Event] = []
    stopped = threading.Event()
    for path, handler in handlers.items():
        ready = threading.Event()
        thread = threading.Thread(target=serve_channel, args=(path, handler, ready, stopped), daemon=True)
        thread.start()
        readiness.append(ready)
    for ready in readiness:
        if not ready.wait(5):
            fail("protocol socket failed to start")
    print(jcs({"schema": "fm.gateway-listeners.v2", "prepare": str(root / "prepare.sock"), "approval": str(root / "approval.sock"), "execution": str(root / "execution.sock")}))
    sys.stdout.flush()
    while not stopped.wait(1):
        pass
    fail("a protocol channel stopped serving; the gateway refuses to serve a partial boundary")


def read_stdin_bounded() -> bytes:
    raw = sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1)
    if len(raw) > MAX_REQUEST_BYTES:
        fail(f"request exceeds {MAX_REQUEST_BYTES} bytes")
    return raw


def emit_key_values(value: Dict[str, Any]) -> None:
    order = ("decision", "state", "digest", "request_id", "expires_at", "requester_uid", "job_id", "reason")
    for key in order:
        if key in value:
            rendered = value[key]
            if isinstance(rendered, bool):
                rendered = "true" if rendered else "false"
            print(f"{key}={rendered}")


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("prepare")
    status_parser = subparsers.add_parser("status")
    status_parser.add_argument("--digest", required=True)
    subparsers.add_parser("inspect-test-paths")
    capability_parser = subparsers.add_parser("issue-capability")
    capability_parser.add_argument("--purpose", choices=(PURPOSE_PREPARE, PURPOSE_APPROVAL, PURPOSE_EXECUTION), required=True)
    capability_parser.add_argument("--job-id", required=True)
    capability_parser.add_argument("--uid", type=int, default=os.getuid())
    serve_parser = subparsers.add_parser("serve")
    serve_parser.add_argument("--socket-root")
    mark_parser = subparsers.add_parser("test-mark-executing")
    mark_parser.add_argument("--digest", required=True)
    return parser.parse_args(argv)


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    if args.command in ("inspect-test-paths", "issue-capability", "test-mark-executing") and not test_mode():
        fail(f"{args.command} is available only in unprivileged test mode")
    if args.command == "prepare":
        action = strict_json(read_stdin_bounded())
        if not test_mode():
            fail("direct prepare is test-only; production uses the peer-authenticated prepare socket")
        if not isinstance(action, dict):
            fail("ActionRequest must be an object")
        job_id = action.get("task_id")
        if not isinstance(job_id, str):
            fail("ActionRequest task_id is required")
        with open_database() as db:
            recover_interrupted(db)
            result = prepare_action(db, action, os.getuid(), job_id)
        emit_key_values(result)
        return 0
    if args.command == "status":
        with open_database() as db:
            recover_interrupted(db)
            emit_key_values(status_action(db, args.digest))
        return 0
    if args.command == "inspect-test-paths":
        print(jcs({"schema": "fm.gateway-test-paths.v2", "database": str(database_path()), "approval_state": str(database_path()), "audit": str(audit_path())}))
        return 0
    if args.command == "issue-capability":
        with open_database() as db:
            with transaction(db):
                token = issue_capability(db, args.purpose, args.job_id, args.uid, int(time.time()))
        print(f"capability={token}")
        return 0
    if args.command == "serve":
        root = Path(args.socket_root) if args.socket_root else socket_root()
        if args.socket_root and not test_mode():
            fail("socket root override is test-only")
        serve(root)
        return 0
    if args.command == "test-mark-executing":
        with open_database() as db:
            recover_interrupted(db)
            row = get_request_by_digest(db, args.digest)
            with transaction(db):
                db.execute("UPDATE requests SET state='executing' WHERE request_id=?", (row["request_id"],))
        return 0
    fail("unknown command")


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (GatewayError, sqlite3.Error, OSError) as exc:
        print(f"fm-action-gateway-v2: {exc}", file=sys.stderr)
        raise SystemExit(1)
