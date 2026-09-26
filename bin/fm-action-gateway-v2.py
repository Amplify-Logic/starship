#!/usr/bin/env python3
"""Firstmate action gateway v2 broker.

This program implements isolation-program Step 2 sub-order items 1 through 6:
strict parsing, the closed immutable plan, SQLite-authoritative state,
peer-authenticated channels, approval signature verification against an enrolled
approver, and lease-bounded execution settled against the deterministic safe
sink's own receipt store.

The only executor it will claim for is bin/fm-action-safe-sink-v2.py, whose exact
bytes are bound into every plan. Nothing here performs an outward action, and no
approval class that the broker itself could forge is accepted outside test mode.

Usage:
  fm-action-gateway-v2.py prepare
  fm-action-gateway-v2.py status --digest HEX
  fm-action-gateway-v2.py inspect-test-paths
  fm-action-gateway-v2.py issue-capability --purpose prepare|approval|execution --job-id ID [--uid UID]
  fm-action-gateway-v2.py enroll-approver --approver-id ID --algorithm ALG --key-material B64 [--attestation-ref REF]
  fm-action-gateway-v2.py list-approvers
  fm-action-gateway-v2.py revoke-approver --approver-id ID
  fm-action-gateway-v2.py serve [--socket-root PATH]
  fm-action-gateway-v2.py test-mark-executing --digest HEX [--lease-seconds N]

Approval algorithms are ed25519 and ecdsa-p256-sha256, both verified against an
enrolled public key, plus hmac-sha256-test, which is enrollable and accepted only
under FM_ACTION_GATEWAY_TEST=1 and is recorded everywhere as proving transcript
binding rather than approver authenticity.

Production state has one fixed location.
FM_ACTION_GATEWAY_TEST=1 enables a synthetic temporary-root adapter derived from
TMPDIR so the Step 1 regression pack can exercise this code without installation.
The production service must use the fixed launch definitions planned for Step 5;
bin/fm-gateway-install-v2.sh previews that installation and never performs it.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import contextlib
import ctypes
import errno
import functools
import hashlib
import hmac
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
PRODUCTION_SINK_ROOT = Path("/var/db/firstmate/sink")
PRODUCTION_SOCKET_ROOT = Path("/var/run/firstmate/gateway")
MAX_REQUEST_BYTES = 64 * 1024
MAX_FRAME_BYTES = 96 * 1024
MAX_DEPTH = 12
MAX_ITEMS = 256
MAX_STRING_BYTES = 32 * 1024
# The claim reply hands the executor the exact stored plan bytes as base64, and
# base64 expands by 4/3. A plan past this ceiling could never be delivered
# inside one bounded string, so it is refused while it is still a request and
# nothing has been approved, rather than after a claim has already moved it to
# executing.
# Published as max_plan_jcs_bytes in POLICY_MANIFEST, because a caller sizing a
# request against the per-field maxima alone would build plans this refuses.
MAX_PLAN_JCS_BYTES = (MAX_STRING_BYTES // 4) * 3
MAX_ATTACHMENTS = 8
MAX_ATTACHMENT_BYTES = 256 * 1024
MAX_MESSAGE_BYTES = 32 * 1024
MAX_RECIPIENTS = 64
MAX_PREPARES_PER_WINDOW = 8
RATE_WINDOW_SECONDS = 60
PLAN_TTL_SECONDS = 300
CHALLENGE_TTL_SECONDS = 60
EXECUTION_LEASE_SECONDS = 60
CONNECTION_DEADLINE_SECONDS = 5.0
SAFE_INTEGER = 9_007_199_254_740_991
MAX_DEVICE_SETTINGS = 16
MAX_SIGNATURE_BYTES = 512
DIGEST_RE = re.compile(r"[0-9a-f]{64}")
ID_RE = re.compile(r"[A-Za-z0-9._-]{1,96}")
CURRENCY_RE = re.compile(r"[A-Z]{3}")
EMAIL_RE = re.compile(r"([^@\s]+)@([^@\s]+)")
SAFE_SINK_PROGRAM = "fm-action-safe-sink-v2.py"

# Approver assurance classes. The class is recorded on the approval row, in the
# audit event, and in status output, so no reader has to infer how much an
# approval proves.
#
# ASSURANCE_PRODUCTION covers asymmetric algorithms where the broker holds only
# a public key and therefore cannot mint an approval. ASSURANCE_TEST covers the
# stdlib HMAC class, where the broker holds the verification key and could forge
# an approval: it proves transcript binding, challenge binding, replay refusal
# and the state machine, and it proves nothing about approver authenticity.
# Enrollment refuses the test class outside test mode, so production can never
# silently fall back to it.
ASSURANCE_PRODUCTION = "asymmetric-enrolled-key"
ASSURANCE_TEST = "software-test-hmac"
ALGORITHM_ASSURANCE = {
    "ecdsa-p256-sha256": ASSURANCE_PRODUCTION,
    "ed25519": ASSURANCE_PRODUCTION,
    "hmac-sha256-test": ASSURANCE_TEST,
}

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
        "device",
    }
)
ATTACHMENT_KEYS = frozenset({"name", "media_type", "content_b64"})
DEVICE_KEYS = frozenset({"identifier_kind", "identifier", "settings", "eligibility", "preview_hash"})
DEVICE_SETTING_KEYS = frozenset(
    {"key", "requested_raw", "encoding", "encoding_confirmed", "encoding_evidence", "decoded_value", "unit"}
)
DEVICE_ELIGIBILITY_KEYS = frozenset({"status", "evidence_ref"})
DEVICE_IDENTIFIER_KINDS = frozenset({"portal-device-id"})
DEVICE_ELIGIBILITY_STATUSES = frozenset({"observed", "unverified"})
# Only the staging kind is registered. device.config.read stays unregistered
# because an operator hold covers reading a device's request rows, and
# registering the kind here would read as pre-authorization for it.
DEVICE_ACTIONS = frozenset({"device.config.stage"})
ALLOWED_ACTIONS = frozenset(
    {
        "email.send",
        "message.send",
        "payment",
        "purchase",
        "http.request",
    }
    | DEVICE_ACTIONS
)
# Every device.* kind carries the non-graduatable device ceiling, so no device
# action can ever be graduated out of per-action approval.
CEILING_DEVICE = "device"

POLICY_MANIFEST = {
    "schema": "fm.gateway-policy.v2",
    "policy_revision": 4,
    "outward_execution": False,
    "executor": "deterministic-safe-sink",
    "redirect_policy": "deny",
    "allowed_actions": sorted(ALLOWED_ACTIONS),
    "device_actions": sorted(DEVICE_ACTIONS),
    "device_ceiling": CEILING_DEVICE,
    "device_ceiling_graduatable": False,
    "approval_signature_required": True,
    "approver_assurance_classes": sorted({ASSURANCE_PRODUCTION, ASSURANCE_TEST}),
    "approval_signature_algorithms": sorted(ALGORITHM_ASSURANCE),
    "execution_lease_seconds": EXECUTION_LEASE_SECONDS,
    "max_request_bytes": MAX_REQUEST_BYTES,
    "max_message_bytes": MAX_MESSAGE_BYTES,
    "max_attachment_bytes": MAX_ATTACHMENT_BYTES,
    "max_attachments": MAX_ATTACHMENTS,
    "max_recipients": MAX_RECIPIENTS,
    "max_device_settings": MAX_DEVICE_SETTINGS,
    "max_plan_jcs_bytes": MAX_PLAN_JCS_BYTES,
    "size_limit_model": (
        "the max_* per-field values are upper bounds on one field in isolation; "
        "max_plan_jcs_bytes bounds the whole resolved canonical plan and is the binding "
        "constraint, so the usable size of any one field is max_plan_jcs_bytes minus the "
        "rest of the resolved plan and is always smaller than that field's own maximum"
    ),
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


def resolve_device(parameters: Dict[str, Any]) -> Dict[str, Any]:
    """Resolve the device payload without ever altering a requested value.

    The gateway records the exact wire value the caller asked for, the caller's
    declared encoding, and the caller's declared reading of that value. It never
    decodes, never re-encodes, never clamps to a band, and never substitutes a
    floor: a value the gateway changed is a value nobody approved. The only
    decoding judgement it enforces is a refusal - a setting whose encoding is not
    explicitly declared and confirmed against observed evidence cannot be staged
    at all.
    """
    raw = require_exact_keys(parameters["device"], DEVICE_KEYS, DEVICE_KEYS, "device")
    identifier_kind = required_string(raw["identifier_kind"], "device.identifier_kind", 64)
    if identifier_kind not in DEVICE_IDENTIFIER_KINDS:
        fail("unknown device identifier kind")
    identifier = required_string(raw["identifier"], "device.identifier", 128)
    preview_hash = required_string(raw["preview_hash"], "device.preview_hash", 64)
    if not DIGEST_RE.fullmatch(preview_hash):
        fail("device.preview_hash must be lowercase SHA-256 hex of the rendered target preview")
    eligibility = require_exact_keys(raw["eligibility"], DEVICE_ELIGIBILITY_KEYS, DEVICE_ELIGIBILITY_KEYS, "device.eligibility")
    status = required_string(eligibility["status"], "device.eligibility.status", 32)
    if status not in DEVICE_ELIGIBILITY_STATUSES:
        fail("device eligibility status must be observed or unverified")
    settings = raw["settings"]
    if not isinstance(settings, list) or not settings:
        fail("device action requires at least one setting")
    if len(settings) > MAX_DEVICE_SETTINGS:
        fail(f"device action accepts at most {MAX_DEVICE_SETTINGS} settings")
    resolved: List[Dict[str, Any]] = []
    seen: set[str] = set()
    for entry in settings:
        item = require_exact_keys(entry, DEVICE_SETTING_KEYS, DEVICE_SETTING_KEYS, "device.settings entry")
        key = required_string(item["key"], "device.settings.key", 128)
        if key in seen:
            fail("duplicate device setting key refused")
        seen.add(key)
        if isinstance(item["requested_raw"], bool) or not isinstance(item["requested_raw"], int):
            fail("device setting requested_raw must be the exact integer wire value")
        if item["encoding_confirmed"] is not True:
            fail(f"device setting {key} refused: encoding is not confirmed")
        resolved.append(
            {
                "key": key,
                "requested_raw": item["requested_raw"],
                "encoding": required_string(item["encoding"], "device.settings.encoding", 128),
                "encoding_confirmed": True,
                "encoding_evidence": required_string(item["encoding_evidence"], "device.settings.encoding_evidence", 256),
                # Declared by the caller and displayed next to the wire value.
                # The gateway binds it into the reviewable plan so the approver
                # sees both, and asserts nothing about whether it is correct.
                "decoded_value": required_string(item["decoded_value"], "device.settings.decoded_value", 128),
                "decoded_value_source": "caller-declared",
                "unit": required_string(item["unit"], "device.settings.unit", 32),
            }
        )
    return {
        "identifier_kind": identifier_kind,
        "identifier": identifier,
        "settings": resolved,
        "setting_count": len(resolved),
        "eligibility": {"status": status, "evidence_ref": required_string(eligibility["evidence_ref"], "device.eligibility.evidence_ref", 256)},
        "preview_hash": preview_hash,
        "preview_reverification_required": True,
        "ceiling": CEILING_DEVICE,
        "graduatable": False,
    }


def safe_sink_path() -> Path:
    return Path(__file__).resolve().parent / SAFE_SINK_PROGRAM


def file_identity(path: Path) -> str:
    try:
        return sha256_bytes(path.read_bytes())
    except OSError as exc:
        fail(f"cannot read the executor program {path.name}: {exc}")


def executable_identity() -> Tuple[str, str]:
    """Identify the executor the plan authorizes, not the broker that wrote it.

    The plan binds the exact safe-sink bytes, so an executor swapped after
    approval is refused at claim time instead of running under someone else's
    approval.
    """
    return file_identity(safe_sink_path()), "fm-action-safe-sink-v2/2.6"


def sink_record(plan_digest: str, request_id: str, idempotency_key: str, operation: str) -> Dict[str, str]:
    """The deterministic record the safe sink appends for one approved plan.

    Every member is ASCII hex or a registry slug, so compact sorted-key JSON is
    byte-identical to the canonical form. bin/fm-action-safe-sink-v2.py builds
    the same object from the same inputs, which is what lets the broker verify a
    settlement against the sink's own store instead of trusting the executor.
    """
    return {
        "schema": "fm.safe-sink-record.v2",
        "plan_digest": plan_digest,
        "request_id": request_id,
        "idempotency_key": idempotency_key,
        "operation": operation,
    }


def sink_record_digest(plan_digest: str, request_id: str, idempotency_key: str, operation: str) -> str:
    record = sink_record(plan_digest, request_id, idempotency_key, operation)
    return sha256_bytes(json.dumps(record, sort_keys=True, separators=(",", ":")).encode("utf-8"))


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
    is_device = req["action_kind"] in DEVICE_ACTIONS
    if is_device:
        if "device" not in parameters:
            fail("device actions require a device payload")
        carried = sorted(set(parameters) - {"device"})
        if carried:
            fail(f"device actions refuse money and messaging parameters: {', '.join(carried)}")
    elif "device" in parameters:
        fail("device payload refused on a non-device action kind")
    device = resolve_device(parameters) if is_device else None
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
        "device": device,
        "ceiling": CEILING_DEVICE if is_device else None,
        "graduatable": False,
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
            "kind": "deterministic-safe-sink",
            "program": SAFE_SINK_PROGRAM,
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
    if len(encoded) > MAX_PLAN_JCS_BYTES:
        fail(f"resolved plan exceeds the {MAX_PLAN_JCS_BYTES}-byte executable plan ceiling")
    return plan, sha256_bytes(encoded), sha256_bytes(canonical_bytes(req))


def test_mode() -> bool:
    return os.environ.get("FM_ACTION_GATEWAY_TEST") == "1"


def state_root() -> Path:
    if test_mode():
        tmp = Path(os.environ.get("TMPDIR", "/tmp"))
        return tmp / "fm-gateway-v2-state"
    return PRODUCTION_ROOT


def sink_root() -> Path:
    """Where the executor's receipt store lives, which is not the broker's root.

    The broker root is broker-owned and broker-only. The receipt store is the
    executor's, and this process reaches it through group read alone: it opens
    that store read-only and has no write path to it anywhere, which is what
    makes a receipt evidence rather than something the broker could author.
    bin/fm-action-safe-sink-v2.py resolves the same root by the same rule.
    """
    if test_mode():
        tmp = Path(os.environ.get("TMPDIR", "/tmp"))
        return tmp / "fm-gateway-v2-sink"
    return PRODUCTION_SINK_ROOT


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
          reconciliation_required INTEGER NOT NULL DEFAULT 0 CHECK(reconciliation_required IN (0,1)),
          attempt INTEGER NOT NULL DEFAULT 0,
          lease_hash TEXT UNIQUE,
          lease_expires_at INTEGER
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
          approved_at INTEGER NOT NULL,
          algorithm TEXT NOT NULL DEFAULT '',
          assurance_class TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE IF NOT EXISTS approvers (
          approver_id TEXT PRIMARY KEY,
          algorithm TEXT NOT NULL,
          assurance_class TEXT NOT NULL,
          key_material TEXT NOT NULL,
          key_digest TEXT NOT NULL UNIQUE,
          attestation_ref TEXT NOT NULL,
          attestation_verified INTEGER NOT NULL DEFAULT 0 CHECK(attestation_verified IN (0,1)),
          enrolled_at INTEGER NOT NULL,
          revoked_at INTEGER
        );
        CREATE TABLE IF NOT EXISTS executions (
          execution_id TEXT PRIMARY KEY,
          request_id TEXT NOT NULL REFERENCES requests(request_id),
          attempt INTEGER NOT NULL,
          lease_hash TEXT NOT NULL UNIQUE,
          expected_record_digest TEXT NOT NULL,
          claimed_at INTEGER NOT NULL,
          lease_expires_at INTEGER NOT NULL,
          settled_at INTEGER,
          outcome TEXT,
          executor_claimed_outcome TEXT,
          observed_record_digest TEXT,
          UNIQUE(request_id, attempt)
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
    add_missing_columns(db)


def add_missing_columns(db: sqlite3.Connection) -> None:
    """Add columns a database created by an earlier revision does not have.

    CREATE TABLE IF NOT EXISTS silently keeps an older shape, so an existing
    state directory would otherwise lose the lease and assurance columns and
    fall back to the pre-lease behaviour without saying so.
    """
    wanted = {
        "requests": (
            ("attempt", "INTEGER NOT NULL DEFAULT 0"),
            ("lease_hash", "TEXT"),
            ("lease_expires_at", "INTEGER"),
        ),
        "approvals": (
            ("algorithm", "TEXT NOT NULL DEFAULT ''"),
            ("assurance_class", "TEXT NOT NULL DEFAULT ''"),
        ),
    }
    for table, columns in wanted.items():
        present = {row["name"] for row in db.execute(f"PRAGMA table_info({table})")}
        for name, declaration in columns:
            if name not in present:
                db.execute(f"ALTER TABLE {table} ADD COLUMN {name} {declaration}")
    index = "CREATE UNIQUE INDEX IF NOT EXISTS requests_lease_hash ON requests(lease_hash) WHERE lease_hash IS NOT NULL"
    db.execute(index)


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


def mark_unknown(db: sqlite3.Connection, request_id: str, digest: str, reason: str, now: int) -> None:
    """Durably move one interrupted execution to unknown inside an open transaction.

    The append is durable and one-way. An unknown request never returns to
    approval or execution through any implemented protocol, because a request
    whose outcome nobody observed is exactly the one that must not be retried
    automatically.

    A request another caller already moved records nothing further: the state is
    already what this would write, and a second event would claim a transition
    that did not happen here.
    """
    moved = db.execute(
        "UPDATE requests SET state='unknown', reconciliation_required=1, lease_hash=NULL, lease_expires_at=NULL WHERE request_id=? AND state='executing'",
        (request_id,),
    ).rowcount
    if moved == 0:
        return
    db.execute(
        "UPDATE executions SET settled_at=?, outcome='unknown' WHERE request_id=? AND settled_at IS NULL",
        (now, request_id),
    )
    append_audit(
        db,
        "execution-uncertain",
        request_id,
        {
            "schema": "fm.audit-event.v2",
            "event": "execution-uncertain",
            "request_id": request_id,
            "digest": digest,
            "state": "unknown",
            "reason": reason,
            "provider_reconciliation_required": True,
            "at": now,
        },
        now,
    )


class DeferredUnknown(Exception):
    """An interrupted execution whose `unknown` must outlive the refusal.

    mark_unknown() writes state, clears the lease, settles the attempt, and
    records an audit row. Raising the refusal from inside the same transaction
    would roll every one of those back while the JSONL evidence append survived,
    leaving a file that claims a reconciliation the database never recorded.
    Raising this instead leaves the reading transaction to roll back untouched,
    commits the unknown in its own transaction, and only then refuses.
    """

    def __init__(self, request_id: str, digest: str, reason: str, refusal: str, now: int) -> None:
        super().__init__(refusal)
        self.request_id = request_id
        self.digest = digest
        self.reason = reason
        self.refusal = refusal
        self.now = now


def unknown_recorded_before_refusal(handler: Callable[..., Dict[str, Any]]) -> Callable[..., Dict[str, Any]]:
    """Commit a DeferredUnknown durably, then raise the refusal it carries."""

    @functools.wraps(handler)
    def wrapper(db: sqlite3.Connection, *args: Any, **kwargs: Any) -> Dict[str, Any]:
        try:
            return handler(db, *args, **kwargs)
        except DeferredUnknown as deferred:
            with transaction(db):
                mark_unknown(db, deferred.request_id, deferred.digest, deferred.reason, deferred.now)
            fail(deferred.refusal)

    return wrapper


def recover_interrupted(db: sqlite3.Connection) -> None:
    """Reconcile executions a crash interrupted; a process runs this once at startup.

    Only an execution whose lease deadline has passed is reconciled. A live
    lease is left alone, so a concurrent caller on another socket cannot rewrite
    an execution window that is still running - which is the whole difference
    between a crash default and a per-read rewrite.
    """
    now = int(time.time())
    query = "SELECT request_id,digest FROM requests WHERE state='executing' AND (lease_expires_at IS NULL OR lease_expires_at <= ?)"
    if db.execute(f"SELECT 1 FROM ({query}) LIMIT 1", (now,)).fetchone() is None:
        return
    with transaction(db):
        for row in list(db.execute(query, (now,))):
            mark_unknown(db, row["request_id"], row["digest"], "execution lease expired without a verified settlement", now)


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
    # Hex, not urlsafe base64: a capability travels as its own argv word
    # (fm-action-runner-v2.py run --capability TOKEN), and a urlsafe token that
    # happened to begin with '-' was read by argparse as an option instead.
    token = secrets.token_hex(32)
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


def decode_base64_exact(value: Any, label: str, maximum: int) -> bytes:
    text = required_string(value, label, maximum * 2)
    try:
        raw = base64.b64decode(text.encode("ascii"), validate=True)
    except (binascii.Error, ValueError, UnicodeEncodeError):
        fail(f"{label} must be canonical base64")
    if base64.b64encode(raw).decode("ascii") != text:
        fail(f"{label} must be canonical base64")
    if not raw or len(raw) > maximum:
        fail(f"{label} length refused")
    return raw


def verify_signature(algorithm: str, key_material: str, message: bytes, signature: bytes) -> bool:
    """Verify one approval signature, or refuse by name when the class cannot be checked.

    There is no fallback path. An algorithm whose verification primitive is not
    available on this machine refuses the approval and says which primitive is
    missing, because accepting an unverified approval would be exactly the
    silent substitution this boundary exists to prevent.
    """
    if algorithm == "hmac-sha256-test":
        if not test_mode():
            fail("the software test approver class is refused outside test mode")
        secret = base64.b64decode(key_material.encode("ascii"), validate=True)
        return hmac.compare_digest(hmac.new(secret, message, hashlib.sha256).digest(), signature)
    if algorithm not in ALGORITHM_ASSURANCE:
        fail("unknown approval signature algorithm")
    try:
        from cryptography.exceptions import InvalidSignature
        from cryptography.hazmat.primitives import hashes as crypto_hashes
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric import ec, ed25519
    except ImportError:
        fail(
            "approval signature verification for "
            f"{algorithm} needs the cryptography module, which is not importable here; "
            "refusing to accept an unverified approval"
        )
    public_bytes = base64.b64decode(key_material.encode("ascii"), validate=True)
    try:
        if algorithm == "ed25519":
            ed25519.Ed25519PublicKey.from_public_bytes(public_bytes).verify(signature, message)
            return True
        key = serialization.load_der_public_key(public_bytes)
        if not isinstance(key, ec.EllipticCurvePublicKey) or key.curve.name != "secp256r1":
            fail("ecdsa-p256-sha256 requires a secp256r1 public key")
        key.verify(signature, message, ec.ECDSA(crypto_hashes.SHA256()))
        return True
    except InvalidSignature:
        return False
    except (ValueError, TypeError) as exc:
        fail(f"approval signature verification refused the enrolled key: {exc}")


def enroll_approver(
    db: sqlite3.Connection,
    approver_id: str,
    algorithm: str,
    key_material: str,
    attestation_ref: str,
    now: int,
) -> Dict[str, Any]:
    if not ID_RE.fullmatch(approver_id):
        fail("approver_id must be path-safe")
    assurance = ALGORITHM_ASSURANCE.get(algorithm)
    if assurance is None:
        fail("unknown approval signature algorithm")
    if assurance == ASSURANCE_TEST and not test_mode():
        fail("the software test approver class is enrollable only in test mode")
    decode_base64_exact(key_material, "approver key material", 1024)
    if assurance == ASSURANCE_PRODUCTION and not attestation_ref:
        fail("a production approver requires an attestation reference")
    digest = sha256_bytes(key_material.encode("ascii"))
    try:
        db.execute(
            "INSERT INTO approvers(approver_id,algorithm,assurance_class,key_material,key_digest,attestation_ref,attestation_verified,enrolled_at) VALUES(?,?,?,?,?,?,0,?)",
            (approver_id, algorithm, assurance, key_material, digest, attestation_ref, now),
        )
    except sqlite3.IntegrityError as exc:
        fail(f"approver enrollment refused: {exc}")
    append_audit(
        db,
        "approver-enrolled",
        None,
        {
            "schema": "fm.audit-event.v2",
            "event": "approver-enrolled",
            "approver_id": approver_id,
            "algorithm": algorithm,
            "assurance_class": assurance,
            "key_digest": digest,
            "attestation_ref": attestation_ref,
            # Apple attestation is verified by the captain-at-the-Mac Step 5
            # proof, not here. Recording false is the honest value.
            "attestation_verified": False,
            "at": now,
        },
        now,
    )
    return {"approver_id": approver_id, "algorithm": algorithm, "assurance_class": assurance, "key_digest": digest}


def submit_approval(
    db: sqlite3.Connection,
    request_id: str,
    ui_id: str,
    challenge_id: str,
    approver_id: str,
    signature_b64: Any,
    capability_job_id: str,
    now: int,
) -> Dict[str, Any]:
    required_string(ui_id, "ui_id", 128)
    if not ID_RE.fullmatch(required_string(challenge_id, "challenge_id", 96)):
        fail("challenge_id must be path-safe")
    if not ID_RE.fullmatch(required_string(approver_id, "approver_id", 96)):
        fail("approver_id must be path-safe")
    signature = decode_base64_exact(signature_b64, "approval signature", MAX_SIGNATURE_BYTES)
    with transaction(db):
        row = db.execute("SELECT * FROM requests WHERE request_id=?", (request_id,)).fetchone()
        if row is None:
            fail("unknown request_id")
        if row["job_id"] != capability_job_id:
            fail("approval capability is not scoped to the request job")
        if row["state"] != "prepared" or row["expires_at"] <= now:
            fail("request is not eligible for approval")
        challenge = db.execute("SELECT * FROM challenges WHERE challenge_id=?", (challenge_id,)).fetchone()
        if challenge is None or challenge["request_id"] != request_id:
            fail("unknown challenge for this request")
        if challenge["consumed_at"] is not None:
            fail("challenge already consumed")
        if challenge["expires_at"] <= now:
            fail("challenge expired")
        if challenge["ui_id"] != ui_id:
            fail("approval ui_id does not match the challenged UI")
        # Recompute the transcript from stored state rather than trusting any
        # transcript the caller echoes back, then require the stored digest to
        # match. The signature is over the exact bytes the approver was shown.
        transcript = transcript_for_challenge(row, challenge["challenge_nonce"], challenge["expires_at"])
        encoded = canonical_bytes(transcript)
        transcript_digest = sha256_bytes(encoded)
        if transcript_digest != challenge["transcript_digest"]:
            fail("resolved plan no longer reproduces the challenged transcript")
        approver = db.execute("SELECT * FROM approvers WHERE approver_id=?", (approver_id,)).fetchone()
        if approver is None:
            fail("unknown approver")
        if approver["revoked_at"] is not None:
            fail("approver is revoked")
        if approver["assurance_class"] == ASSURANCE_TEST and not test_mode():
            fail("the software test approver class is refused outside test mode")
        # A refused signature is recorded in its own transaction below. Auditing
        # it here would roll the record back along with the refusal, losing the
        # one event a reader most needs to see.
        signature_verified = verify_signature(approver["algorithm"], approver["key_material"], encoded, signature)
        algorithm = str(approver["algorithm"])
        assurance_class = str(approver["assurance_class"])
        digest = str(row["digest"])
    if not signature_verified:
        with transaction(db):
            append_audit(
                db,
                "approval-signature-refused",
                request_id,
                {
                    "schema": "fm.audit-event.v2",
                    "event": "approval-signature-refused",
                    "request_id": request_id,
                    "digest": digest,
                    "approver_id": approver_id,
                    "transcript_digest": transcript_digest,
                    "at": now,
                },
                now,
            )
        fail("approval signature does not verify against the enrolled approver key")
    with transaction(db):
        approval_id = secrets.token_hex(16)
        signature_hash = sha256_bytes(signature)
        try:
            db.execute(
                "INSERT INTO approvals(approval_id,request_id,challenge_id,transcript_digest,signature_hash,approver_identity,approved_at,algorithm,assurance_class) VALUES(?,?,?,?,?,?,?,?,?)",
                (
                    approval_id,
                    request_id,
                    challenge_id,
                    transcript_digest,
                    signature_hash,
                    approver_id,
                    now,
                    algorithm,
                    assurance_class,
                ),
            )
        except sqlite3.IntegrityError:
            fail("approval replay refused")
        db.execute("UPDATE challenges SET consumed_at=? WHERE challenge_id=? AND consumed_at IS NULL", (now, challenge_id))
        changed = db.execute(
            "UPDATE requests SET state='approved' WHERE request_id=? AND state='prepared'",
            (request_id,),
        ).rowcount
        if changed != 1:
            fail("request left the prepared state during approval")
        append_audit(
            db,
            "approved",
            request_id,
            {
                "schema": "fm.audit-event.v2",
                "event": "approved",
                "request_id": request_id,
                "digest": digest,
                "state": "approved",
                "approval_id": approval_id,
                "approver_id": approver_id,
                "algorithm": algorithm,
                "assurance_class": assurance_class,
                "approver_authenticity_proved": assurance_class == ASSURANCE_PRODUCTION,
                "transcript_digest": transcript_digest,
                "signature_hash": signature_hash,
                "at": now,
            },
            now,
        )
    return {
        "schema": SCHEMA_APPROVAL,
        "state": "approved",
        "request_id": request_id,
        "approval_id": approval_id,
        "transcript_digest": transcript_digest,
        "assurance_class": assurance_class,
        "approver_authenticity_proved": assurance_class == ASSURANCE_PRODUCTION,
        "outward_execution": False,
    }


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


# One word per state for a reader who needs to know how far an action actually
# got. "queued" and "sent" are deliberately the same state: once a lease is out,
# the broker knows the attempt is in flight and does not know whether the effect
# landed, and pretending otherwise is the error this whole boundary exists to
# avoid.
SETTLEMENT_WORDS = {
    "prepared": "awaiting-approval",
    "approved": "approved-not-yet-queued",
    "executing": "queued-and-sent-outcome-not-yet-observed",
    "succeeded": "independently-observed-as-applied",
    "failed": "independently-observed-as-not-applied",
    "unknown": "unobserved-requires-reconciliation",
}


def status_action(db: sqlite3.Connection, digest: str) -> Dict[str, Any]:
    row = get_request_by_digest(db, digest)
    approval = db.execute("SELECT * FROM approvals WHERE request_id=?", (row["request_id"],)).fetchone()
    return {
        "schema": "fm.gateway-status.v2",
        "decision": "confirm-first",
        "state": row["state"],
        "settlement": SETTLEMENT_WORDS[row["state"]],
        "request_id": row["request_id"],
        "digest": row["digest"],
        "expires_at": row["expires_at"],
        "attempt": row["attempt"],
        "lease_expires_at": row["lease_expires_at"],
        "assurance_class": approval["assurance_class"] if approval is not None else "",
        "approver_authenticity_proved": bool(approval is not None and approval["assurance_class"] == ASSURANCE_PRODUCTION),
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
        "approval_enabled": True,
        "signature_over": "canonical transcript bytes",
    }


def sink_database_path() -> Path:
    return sink_root() / "safe-sink-v2.sqlite3"


def observed_sink_record(idempotency_key: str) -> Tuple[str, Optional[str]]:
    """Read the safe sink's own receipt store and report what it actually holds.

    This is the whole point of the settle path: the broker never learns whether
    an action was applied from the executor's own report. It opens the sink's
    store read-only and looks, so an executor that claims success it did not
    achieve settles unknown rather than succeeded.
    """
    path = sink_database_path()
    try:
        os.stat(path)
    except FileNotFoundError:
        # The sink creates its root and its store on first use, so no store
        # means the sink has never applied anything - including this request.
        # Reporting that as unreadable would make the very first execution need
        # reconciliation it does not need.
        return "absent", None
    except OSError:
        # A store this process is not permitted to look at is a different fact
        # from a store that is not there, and settles unknown rather than
        # failed.
        return "sink-unreadable", None
    try:
        connection = sqlite3.connect(f"file:{urllib.parse.quote(str(path))}?mode=ro", uri=True, timeout=10)
    except sqlite3.Error:
        return "sink-unreadable", None
    try:
        connection.row_factory = sqlite3.Row
        row = connection.execute("SELECT record_digest FROM receipts WHERE idempotency_key=?", (idempotency_key,)).fetchone()
    except sqlite3.Error:
        return "sink-unreadable", None
    finally:
        connection.close()
    if row is None:
        return "absent", None
    return "present", str(row["record_digest"])


@unknown_recorded_before_refusal
def claim_execution(db: sqlite3.Connection, request_id: str, idempotency_key: Any, capability_job_id: str, now: int) -> Dict[str, Any]:
    with transaction(db):
        row = db.execute("SELECT * FROM requests WHERE request_id=?", (request_id,)).fetchone()
        if row is None:
            fail("unknown request_id")
        if row["job_id"] != capability_job_id:
            fail("execution capability is not scoped to the request job")
        if row["idempotency_key"] != idempotency_key:
            fail("execution idempotency key does not bind to the immutable plan")
        if row["state"] == "executing":
            if row["lease_expires_at"] is not None and row["lease_expires_at"] > now:
                fail("execution is already claimed by a live lease")
            raise DeferredUnknown(
                str(row["request_id"]),
                str(row["digest"]),
                "execution lease expired without a verified settlement",
                "the previous execution lease expired; this request now requires provider reconciliation",
                now,
            )
        if row["state"] != "approved":
            fail("execution requires a signed approved immutable plan")
        if row["expires_at"] <= now:
            fail("the approved plan expired before execution was claimed")
        stored_plan = bytes(row["plan_jcs"])
        if len(stored_plan) > MAX_PLAN_JCS_BYTES:
            # Refused before the state moves, so the request stays approved and
            # claimable instead of stranding under a lease nobody holds.
            fail("the approved plan exceeds the executable plan ceiling and cannot be delivered to an executor")
        plan = strict_json(stored_plan, MAX_FRAME_BYTES)
        current_executor = file_identity(safe_sink_path())
        if current_executor != plan["executor"]["sha256"]:
            fail("the executor program changed after approval; this plan authorizes different bytes")
        lease = secrets.token_urlsafe(32)
        attempt = int(row["attempt"]) + 1
        expected = sink_record_digest(row["digest"], row["request_id"], row["idempotency_key"], plan["operation"])
        lease_expires_at = now + EXECUTION_LEASE_SECONDS
        db.execute(
            "UPDATE requests SET state='executing', attempt=?, lease_hash=?, lease_expires_at=? WHERE request_id=? AND state='approved'",
            (attempt, capability_hash(lease), lease_expires_at, request_id),
        )
        try:
            db.execute(
                "INSERT INTO executions(execution_id,request_id,attempt,lease_hash,expected_record_digest,claimed_at,lease_expires_at) VALUES(?,?,?,?,?,?,?)",
                (secrets.token_hex(16), request_id, attempt, capability_hash(lease), expected, now, lease_expires_at),
            )
        except sqlite3.IntegrityError:
            fail("execution claim replay refused")
        append_audit(
            db,
            "execution-claimed",
            request_id,
            {
                "schema": "fm.audit-event.v2",
                "event": "execution-claimed",
                "request_id": request_id,
                "digest": row["digest"],
                "state": "executing",
                "attempt": attempt,
                "lease_expires_at": lease_expires_at,
                "executor_sha256": current_executor,
                "at": now,
            },
            now,
        )
    return {
        "schema": SCHEMA_EXECUTION,
        "state": "executing",
        "request_id": request_id,
        "attempt": attempt,
        "lease": lease,
        "lease_expires_at": lease_expires_at,
        # The exact stored canonical bytes, not a re-serialized copy. The
        # executor hashes the bytes it is handed, so no second canonicalizer has
        # to agree with this one for the settlement check to mean anything.
        "plan_b64": base64.b64encode(stored_plan).decode("ascii"),
        "plan_digest": row["digest"],
        "expected_record_digest": expected,
        "outward_execution": False,
    }


@unknown_recorded_before_refusal
def settle_execution(db: sqlite3.Connection, request_id: str, lease: Any, claimed: Any, capability_job_id: str, now: int) -> Dict[str, Any]:
    if not isinstance(lease, str) or not lease or len(lease) > 256:
        fail("missing execution lease")
    if claimed not in ("succeeded", "failed", "unknown"):
        fail("executor outcome must be succeeded, failed, or unknown")
    with transaction(db):
        row = db.execute("SELECT * FROM requests WHERE request_id=?", (request_id,)).fetchone()
        if row is None:
            fail("unknown request_id")
        if row["job_id"] != capability_job_id:
            fail("execution capability is not scoped to the request job")
        if row["state"] != "executing":
            # A late settle never resurrects a terminal state. The request keeps
            # whatever the crash default already recorded.
            fail(f"settle refused: request is {row['state']}, not executing")
        if row["lease_hash"] != capability_hash(lease):
            fail("settle refused: lease does not match the live execution claim")
        if row["lease_expires_at"] is None or row["lease_expires_at"] <= now:
            raise DeferredUnknown(
                str(row["request_id"]),
                str(row["digest"]),
                "settlement arrived after the execution lease expired",
                "settle refused: the execution lease expired; this request now requires provider reconciliation",
                now,
            )
        execution = db.execute(
            "SELECT * FROM executions WHERE request_id=? AND attempt=?",
            (request_id, row["attempt"]),
        ).fetchone()
        if execution is None:
            fail("settle refused: no claim record for this attempt")
        presence, observed = observed_sink_record(row["idempotency_key"])
        if presence == "present" and observed == execution["expected_record_digest"]:
            outcome, reason = "succeeded", "sink holds exactly the record this approved plan resolves to"
        elif presence == "absent":
            outcome, reason = "failed", "sink holds no record for this operation, so nothing was applied"
        elif presence == "present":
            outcome, reason = "unknown", "sink holds a record that does not match this approved plan"
        else:
            outcome, reason = "unknown", "the sink receipt store could not be read"
        db.execute(
            "UPDATE requests SET state=?, reconciliation_required=?, lease_hash=NULL, lease_expires_at=NULL WHERE request_id=? AND state='executing'",
            (outcome, 1 if outcome == "unknown" else 0, request_id),
        )
        db.execute(
            "UPDATE executions SET settled_at=?, outcome=?, executor_claimed_outcome=?, observed_record_digest=? WHERE execution_id=?",
            (now, outcome, claimed, observed, execution["execution_id"]),
        )
        append_audit(
            db,
            "execution-settled",
            request_id,
            {
                "schema": "fm.audit-event.v2",
                "event": "execution-settled",
                "request_id": request_id,
                "digest": row["digest"],
                "state": outcome,
                "attempt": row["attempt"],
                "executor_claimed_outcome": claimed,
                "broker_observed": presence,
                "expected_record_digest": execution["expected_record_digest"],
                "observed_record_digest": observed,
                "outcome_source": "broker-read-of-sink-store",
                "reason": reason,
                "provider_reconciliation_required": outcome == "unknown",
                "at": now,
            },
            now,
        )
    return {
        "schema": SCHEMA_EXECUTION,
        "state": outcome,
        "request_id": request_id,
        "attempt": row["attempt"],
        "executor_claimed_outcome": claimed,
        "outcome_source": "broker-read-of-sink-store",
        "reason": reason,
        "reconciliation_required": outcome == "unknown",
        "outward_execution": False,
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
        {"schema", "op", "capability", "request_id", "ui_id", "challenge_id", "approver_id", "signature"},
        {"schema", "op", "capability", "request_id", "ui_id"},
        "approval envelope",
    )
    if envelope["schema"] != SCHEMA_APPROVAL:
        fail("wrong schema on approval channel")
    now = int(time.time())
    with transaction(db):
        capability_job_id = verify_capability(db, envelope["capability"], PURPOSE_APPROVAL, peer_uid, now)
    if envelope["op"] == "challenge":
        if {"challenge_id", "approver_id", "signature"} & set(envelope):
            fail("challenge request contains approval-only fields")
        return issue_challenge(db, envelope["request_id"], envelope["ui_id"], capability_job_id, now)
    if envelope["op"] == "approve":
        for field in ("challenge_id", "approver_id", "signature"):
            if field not in envelope:
                fail(f"approval submission requires {field}")
        return submit_approval(
            db,
            envelope["request_id"],
            envelope["ui_id"],
            envelope["challenge_id"],
            envelope["approver_id"],
            envelope["signature"],
            capability_job_id,
            now,
        )
    fail("unknown approval operation")


def protocol_execution(db: sqlite3.Connection, message: Any, peer_uid: int) -> Dict[str, Any]:
    envelope = require_exact_keys(
        message,
        {"schema", "op", "capability", "request_id", "idempotency_key", "lease", "outcome"},
        {"schema", "op", "capability", "request_id"},
        "execution envelope",
    )
    if envelope["schema"] != SCHEMA_EXECUTION:
        fail("wrong schema on execution channel")
    now = int(time.time())
    with transaction(db):
        capability_job_id = verify_capability(db, envelope["capability"], PURPOSE_EXECUTION, peer_uid, now)
    if envelope["op"] == "claim":
        if {"lease", "outcome"} & set(envelope):
            fail("claim request contains settle-only fields")
        if "idempotency_key" not in envelope:
            fail("claim requires idempotency_key")
        return claim_execution(db, envelope["request_id"], envelope["idempotency_key"], capability_job_id, now)
    if envelope["op"] == "settle":
        if "idempotency_key" in envelope:
            fail("settle request contains claim-only fields")
        for field in ("lease", "outcome"):
            if field not in envelope:
                fail(f"settle requires {field}")
        return settle_execution(db, envelope["request_id"], envelope["lease"], envelope["outcome"], capability_job_id, now)
    fail("unknown execution operation")


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
    order = (
        "decision",
        "state",
        "settlement",
        "digest",
        "request_id",
        "expires_at",
        "attempt",
        "lease_expires_at",
        "assurance_class",
        "approver_authenticity_proved",
        "reconciliation_required",
        "requester_uid",
        "job_id",
        "reason",
    )
    for key in order:
        if key in value:
            rendered = value[key]
            if isinstance(rendered, bool):
                rendered = "true" if rendered else "false"
            elif rendered is None:
                rendered = ""
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
    mark_parser.add_argument("--lease-seconds", type=int, default=0)
    enroll_parser = subparsers.add_parser("enroll-approver")
    enroll_parser.add_argument("--approver-id", required=True)
    enroll_parser.add_argument("--algorithm", choices=sorted(ALGORITHM_ASSURANCE), required=True)
    enroll_parser.add_argument("--key-material", required=True, help="base64 public key, or base64 shared secret for the test class")
    enroll_parser.add_argument("--attestation-ref", default="")
    subparsers.add_parser("list-approvers")
    revoke_parser = subparsers.add_parser("revoke-approver")
    revoke_parser.add_argument("--approver-id", required=True)
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
        print(
            jcs(
                {
                    "schema": "fm.gateway-test-paths.v2",
                    "database": str(database_path()),
                    "approval_state": str(database_path()),
                    "audit": str(audit_path()),
                    "state_root": str(state_root()),
                    "sink_root": str(sink_root()),
                    "sink_database": str(sink_database_path()),
                }
            )
        )
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
            lease_expires_at = int(time.time()) + args.lease_seconds if args.lease_seconds > 0 else None
            with transaction(db):
                db.execute(
                    "UPDATE requests SET state='executing', lease_expires_at=? WHERE request_id=?",
                    (lease_expires_at, row["request_id"]),
                )
        return 0
    if args.command == "enroll-approver":
        # Refuse a forbidden approver class before opening any state, so the
        # refusal is the reason the caller sees rather than whatever the
        # production state directory happens to say about permissions.
        assurance = ALGORITHM_ASSURANCE.get(args.algorithm)
        if assurance == ASSURANCE_TEST and not test_mode():
            fail("the software test approver class is enrollable only in test mode")
        if assurance == ASSURANCE_PRODUCTION and not args.attestation_ref:
            fail("a production approver requires an attestation reference")
        with open_database() as db:
            with transaction(db):
                record = enroll_approver(db, args.approver_id, args.algorithm, args.key_material, args.attestation_ref, int(time.time()))
        for key in ("approver_id", "algorithm", "assurance_class", "key_digest"):
            print(f"{key}={record[key]}")
        return 0
    if args.command == "list-approvers":
        with open_database() as db:
            rows = list(db.execute("SELECT approver_id,algorithm,assurance_class,key_digest,attestation_verified,revoked_at FROM approvers ORDER BY approver_id"))
        for row in rows:
            revoked = "true" if row["revoked_at"] is not None else "false"
            print(
                f"approver_id={row['approver_id']} algorithm={row['algorithm']} assurance_class={row['assurance_class']} "
                f"key_digest={row['key_digest']} attestation_verified={'true' if row['attestation_verified'] else 'false'} revoked={revoked}"
            )
        return 0
    if args.command == "revoke-approver":
        now = int(time.time())
        with open_database() as db:
            with transaction(db):
                changed = db.execute(
                    "UPDATE approvers SET revoked_at=? WHERE approver_id=? AND revoked_at IS NULL",
                    (now, args.approver_id),
                ).rowcount
                if changed != 1:
                    fail("unknown or already revoked approver")
                append_audit(
                    db,
                    "approver-revoked",
                    None,
                    {"schema": "fm.audit-event.v2", "event": "approver-revoked", "approver_id": args.approver_id, "at": now},
                    now,
                )
        print(f"approver_id={args.approver_id}")
        print("revoked=true")
        return 0
    fail("unknown command")


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (GatewayError, sqlite3.Error, OSError) as exc:
        print(f"fm-action-gateway-v2: {exc}", file=sys.stderr)
        raise SystemExit(1)
