#!/usr/bin/env python3
"""Firstmate action gateway v2 execution entry point.

The Step 2.6 executor side of the boundary. This is the execution socket's peer:
the process the accepted contract already scopes the execution capability to,
running as the executor principal that holds the bound immutable executor code
and owns its receipt store. It is not a relay standing between the capability
holder and the executor, and it is not an ordinary worker - anything that merely
calls prepare never receives this identity and never receives write access to
the receipt store.

Its authority is still narrow: one per-job execution capability and one
short-lived execution lease, and nothing else. It never sees the approval
capability, never sees an approver key, and cannot approve, prepare, or
re-approve anything.

What it does, in order:

  1. claim   Ask the broker for the approved plan. The broker mints a one-shot
             lease, records attempt N, and hands back the exact canonical plan
             bytes it stored.
  2. apply   Pipe those bytes to the executor the plan names. This program does
             not choose the executor: the plan's bound hash does. It hashes the
             program it was asked to run and refuses before running anything
             when those bytes are not the ones the approval authorized, and the
             broker refuses the claim for the same reason on its own side.
  3. settle  Report back. What this program reports does NOT decide the outcome -
             the broker reads the executor's own receipt store and settles from
             what it finds there. A report of success it did not achieve gets
             failed or unknown, whichever the store actually supports.

An executor that dies between step 2 and step 3 loses its lease, and the request
becomes unknown and requires reconciliation. That is the correct result: nobody
observed the outcome, so nobody may assume it.

Usage:
  fm-action-runner-v2.py run --socket-root DIR --capability TOKEN \
      --request-id ID --idempotency-key KEY [--executor PATH]

Exit status is 0 only when the broker settles the request succeeded.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import socket
import struct
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, NoReturn, Optional, Sequence

SCHEMA_EXECUTION = "fm.execution.v2"
MAX_FRAME_BYTES = 96 * 1024
CONNECTION_TIMEOUT_SECONDS = 10.0
DEFAULT_EXECUTOR = Path(__file__).resolve().parent / "fm-action-safe-sink-v2.py"
TERMINAL_EXIT = {"succeeded": 0, "failed": 2, "unknown": 3}


class RunnerError(Exception):
    """A refusal safe to print without leaking the lease or the capability."""


def fail(message: str) -> NoReturn:
    raise RunnerError(message)


def bound_executor_refusal(executor: Path, plan_bytes: bytes) -> Optional[str]:
    """Refuse an executor whose bytes are not the ones the approval bound.

    The approved plan names the exact executor hash the approver consented to.
    Running whatever --executor happens to point at would hand approved plan
    bytes to a program nobody approved, so the check is done here, against the
    file about to be run, before anything runs.
    """
    try:
        plan = json.loads(plan_bytes.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        return f"approved plan is not readable JSON: {exc}"
    bound = plan.get("executor") if isinstance(plan, dict) else None
    if not isinstance(bound, dict) or not isinstance(bound.get("sha256"), str):
        return "approved plan binds no executor hash"
    if bound.get("outward_execution") is not False:
        return "approved plan claims an outward executor"
    try:
        observed = hashlib.sha256(executor.read_bytes()).hexdigest()
    except OSError as exc:
        return f"cannot read the executor named on the command line: {exc}"
    if observed != bound["sha256"]:
        return "executor bytes are not the ones this approved plan binds"
    return None


def call(socket_path: Path, message: Dict[str, Any]) -> Dict[str, Any]:
    body = json.dumps(message, sort_keys=True, separators=(",", ":")).encode("utf-8")
    if len(body) > MAX_FRAME_BYTES:
        fail("request frame exceeds the protocol ceiling")
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.settimeout(CONNECTION_TIMEOUT_SECONDS)
    try:
        connection.connect(str(socket_path))
        connection.sendall(struct.pack("!I", len(body)) + body)
        header = receive_exactly(connection, 4)
        length = struct.unpack("!I", header)[0]
        if length == 0 or length > MAX_FRAME_BYTES:
            fail("reply frame size refused")
        payload = receive_exactly(connection, length)
    except OSError as exc:
        fail(f"execution channel unreachable: {exc}")
    finally:
        connection.close()
    try:
        reply = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"reply is not valid JSON: {exc}")
    if not isinstance(reply, dict):
        fail("reply is not an object")
    if not reply.get("ok"):
        fail(f"broker refused: {reply.get('error', 'unstated reason')}")
    result = reply.get("result")
    if not isinstance(result, dict):
        fail("reply carries no result object")
    return result


def receive_exactly(connection: socket.socket, size: int) -> bytes:
    buffer = bytearray()
    while len(buffer) < size:
        chunk = connection.recv(min(8192, size - len(buffer)))
        if not chunk:
            fail("truncated reply frame")
        buffer.extend(chunk)
    return bytes(buffer)


def run(socket_root: Path, capability: str, request_id: str, idempotency_key: str, executor: Path) -> Dict[str, Any]:
    execution_socket = socket_root / "execution.sock"
    claim = call(
        execution_socket,
        {
            "schema": SCHEMA_EXECUTION,
            "op": "claim",
            "capability": capability,
            "request_id": request_id,
            "idempotency_key": idempotency_key,
        },
    )
    lease = claim.get("lease")
    encoded_plan = claim.get("plan_b64")
    if not isinstance(lease, str) or not isinstance(encoded_plan, str):
        fail("claim reply is missing the lease or the plan")
    try:
        plan_bytes = base64.b64decode(encoded_plan.encode("ascii"), validate=True)
    except (ValueError, UnicodeEncodeError):
        fail("claim reply plan is not canonical base64")
    claimed = "unknown"
    executor_result: Dict[str, Any] = {}
    refusal = bound_executor_refusal(executor, plan_bytes)
    if refusal is not None:
        # Nothing ran, so this is the one outcome that can be reported honestly
        # without observing anything - and the broker still reads the receipt
        # store before it believes it.
        claimed = "failed"
        executor_result = {"error": f"refused to run an unbound executor: {refusal}"}
    else:
        try:
            completed = subprocess.run(  # noqa: S603 - fixed argv, no shell, plan arrives on stdin
                [sys.executable, str(executor), "apply"],
                input=plan_bytes,
                capture_output=True,
                timeout=CONNECTION_TIMEOUT_SECONDS,
                check=False,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            claimed = "unknown"
            executor_result = {"error": f"executor did not complete: {exc}"}
        else:
            if completed.returncode == 0:
                try:
                    executor_result = json.loads(completed.stdout.decode("utf-8"))
                    claimed = "succeeded" if executor_result.get("readback_verified") else "unknown"
                except (UnicodeDecodeError, json.JSONDecodeError):
                    executor_result = {"error": "executor result is not valid JSON"}
                    claimed = "unknown"
            else:
                # A refusing executor is the one case this program can honestly
                # report as nothing-applied, and the broker still checks the
                # receipt store before it believes that.
                claimed = "failed"
                executor_result = {"error": completed.stderr.decode("utf-8", "replace").strip()[:512]}
    settled = call(
        execution_socket,
        {
            "schema": SCHEMA_EXECUTION,
            "op": "settle",
            "capability": capability,
            "request_id": request_id,
            "lease": lease,
            "outcome": claimed,
        },
    )
    return {
        "schema": "fm.runner-result.v2",
        "request_id": request_id,
        "attempt": claim.get("attempt"),
        "executor": executor.name,
        "executor_claimed_outcome": claimed,
        "executor_result": executor_result,
        "broker_state": settled.get("state"),
        "broker_reason": settled.get("reason"),
        "outcome_source": settled.get("outcome_source"),
        "reconciliation_required": settled.get("reconciliation_required"),
    }


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    subparsers = parser.add_subparsers(dest="command", required=True)
    run_parser = subparsers.add_parser("run")
    run_parser.add_argument("--socket-root", required=True)
    run_parser.add_argument("--capability", required=True)
    run_parser.add_argument("--request-id", required=True)
    run_parser.add_argument("--idempotency-key", required=True)
    run_parser.add_argument("--executor", default=str(DEFAULT_EXECUTOR))
    return parser.parse_args(argv)


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    if args.command == "run":
        result = run(
            Path(args.socket_root),
            args.capability,
            args.request_id,
            args.idempotency_key,
            Path(args.executor),
        )
        print(json.dumps(result, sort_keys=True, separators=(",", ":")))
        return TERMINAL_EXIT.get(str(result["broker_state"]), 3)
    fail("unknown command")


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except RunnerError as exc:
        print(f"fm-action-runner-v2: {exc}", file=sys.stderr)
        raise SystemExit(1)
