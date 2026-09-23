#!/usr/bin/env python3
"""Firstmate action gateway v2 deterministic safe sink.

This is the Step 2.6 executor: the only program bin/fm-action-gateway-v2.py will
ever claim an execution for, and the only component in the v2 boundary that holds
an effect. Its effect is deliberately local and inert - one append-only record in
its own store under its own root - so the whole execution path can be proved end
to end before any outward capability exists.

Three properties matter, and each is enforced here rather than asserted:

  Deterministic  One approved plan resolves to exactly one record. The record is
                 built only from the plan's own identity fields, so the same plan
                 always produces the same bytes and the broker can recompute them
                 without asking this program anything.
  Exactly once   The idempotency key is the receipt store's primary key. A repeat
                 apply reports already-applied and changes nothing, so a repeated
                 click, a retry, or a restart cannot produce a second effect.
  Readable back  After committing, this program re-opens its own store read-only
                 and re-reads the appended line, and reports what it found rather
                 than what it intended.

It refuses any plan that claims an outward executor, and any plan whose bound
executor hash is not this file's exact bytes.

The receipt store belongs to the executor principal, not to the broker. The
broker's own root stays broker-only and this program never touches it; this
store lives under its own root, group-readable so the broker can read the
evidence it settles from and write-protected so the broker can never author it.
That read is also why the store is deliberately not WAL: a read-only opener
needs to create the -shm wal-index beside the database, and a reader with no
write access to this directory is refused outright. TRUNCATE journaling with
full synchronous writes keeps the same durability and stays readable through
group read alone, and a store that ever reports WAL back is refused rather than
used.

The group is guaranteed rather than assumed. The store root is setgid, so the
operating system gives every file in it the reader's group instead of leaving
that to whichever group the executor happens to have first. Every file the store
already holds is checked - regular file, exact mode, exact group - before
anything is written, and a file that does not match is refused rather than
quietly rewritten, because a receipt store whose modes drifted is one the broker
may already have been unable to read.

Usage:
  fm-action-safe-sink-v2.py apply < plan.jcs
  fm-action-safe-sink-v2.py verify --idempotency-key KEY
  fm-action-safe-sink-v2.py inspect-paths

The plan arrives as the exact canonical bytes the broker stored, so the plan
digest is the digest of those bytes and no second canonicalizer has to agree with
the broker's for the record to match.
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
import secrets
import sqlite3
import stat
import sys
import time
import urllib.parse
from pathlib import Path
from typing import Any, Dict, NoReturn, Optional, Sequence, Tuple

PRODUCTION_SINK_ROOT = Path("/var/db/firstmate/sink")
# Setgid, so the group the broker reads through is inherited by every file the
# store creates rather than left to the platform's default-group behaviour.
STORE_DIRECTORY_MODE = 0o2750
STORE_FILE_MODE = 0o640
MAX_PLAN_BYTES = 96 * 1024
PLAN_SCHEMA = "fm.execution-plan.v2"
RECORD_SCHEMA = "fm.safe-sink-record.v2"
RESULT_SCHEMA = "fm.safe-sink-result.v2"


class SinkError(Exception):
    """A refusal safe to print without leaking state."""


def fail(message: str) -> NoReturn:
    raise SinkError(message)


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def test_mode() -> bool:
    return os.environ.get("FM_ACTION_GATEWAY_TEST") == "1"


def sink_root() -> Path:
    """Resolve the executor's own receipt store root.

    Derived, never caller-selected: a sink whose store the caller could move is
    a sink whose receipts the broker cannot trust. It is also deliberately not
    the broker's state root, which stays broker-only. This root is the
    executor's, and the broker reaches it through group read and nothing else.
    tests/fm-action-safe-sink-v2.test.sh asserts the two roots differ by running
    both programs rather than by reading either one's source.
    """
    if test_mode():
        return Path(os.environ.get("TMPDIR", "/tmp")) / "fm-gateway-v2-sink"
    return PRODUCTION_SINK_ROOT


def database_path() -> Path:
    return sink_root() / "safe-sink-v2.sqlite3"


def journal_path() -> Path:
    return sink_root() / "safe-sink-v2.jsonl"


def store_files() -> Tuple[Path, ...]:
    """Every file this store can create, including the SQLite sidecars."""
    database = database_path()
    return (
        database,
        journal_path(),
        Path(f"{database}-journal"),
        Path(f"{database}-wal"),
        Path(f"{database}-shm"),
    )


def describe_store_file(path: Path, expected_gid: int) -> Optional[str]:
    """Say what is wrong with one store file, or None when nothing is.

    The broker's entire access to this evidence is group read on these exact
    files. A wrong group costs it that access; group-write or any other-access
    gives away authority nobody outside the store may hold.
    """
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
    except OSError as exc:
        return f"cannot be examined: {exc}"
    if not stat.S_ISREG(info.st_mode):
        return "is not a regular file"
    mode = stat.S_IMODE(info.st_mode)
    if mode != STORE_FILE_MODE:
        return f"has mode {mode:04o}, not {STORE_FILE_MODE:04o}"
    if info.st_gid != expected_gid:
        return f"has group {info.st_gid}, not the store group {expected_gid}"
    return None


def harden_store_files(expected_gid: int) -> None:
    """Put every file this run created at owner write, group read, and no wider.

    The setgid store root is what actually supplies the group. Setting it here
    too only works for a caller that already belongs to that group, which the
    executor need not; where it does not, the group cannot be corrected and the
    audit below refuses rather than writing evidence the broker cannot read.
    """
    for path in store_files():
        try:
            info = path.lstat()
        except OSError:
            continue
        if not stat.S_ISREG(info.st_mode):
            # Refused by the audit below rather than followed: a chmod through a
            # symlink would write a mode onto a file outside this store.
            continue
        try:
            if stat.S_IMODE(info.st_mode) != STORE_FILE_MODE:
                path.chmod(STORE_FILE_MODE)
            if info.st_gid != expected_gid:
                os.chown(path, -1, expected_gid)
        except OSError as exc:
            fail(f"cannot hold {path.name} at the store's own group and mode: {exc}")
    audit_store_files(expected_gid)


def audit_store_files(expected_gid: int) -> None:
    """Refuse the whole store when any file in it is not what the broker needs."""
    for path in store_files():
        problem = describe_store_file(path, expected_gid)
        if problem is not None:
            fail(f"receipt store file {path.name} {problem}")


def own_identity() -> str:
    return sha256_bytes(Path(__file__).resolve().read_bytes())


def ensure_store_directory(path: Path) -> int:
    """Create the store root setgid, group-readable, and never wider.

    2750 is exactly what lets the broker read this store through group
    membership while holding no authority to write anything in it, and the
    setgid bit is what makes every file in it carry that same group. Returns the
    group every file in the store must have, read from the directory rather than
    named here: this program is not the one that decides who reads its receipts.
    """
    path.mkdir(parents=True, exist_ok=True)
    info = path.stat()
    corrected = False
    if stat.S_IMODE(info.st_mode) != STORE_DIRECTORY_MODE:
        # Only when it is actually wrong. An installed store root is created
        # correctly by the installation, and the executor is not necessarily a
        # member of the group it is shared with, so a needless chmod here would
        # be refused by the operating system.
        try:
            path.chmod(STORE_DIRECTORY_MODE)
        except OSError as exc:
            fail(
                f"store directory is not {STORE_DIRECTORY_MODE:04o} and this process cannot correct it: {exc}. "
                f"Setting setgid requires owning the directory and belonging to its group {info.st_gid}; "
                "the installation is what must create this directory setgid."
            )
        corrected = True
        info = path.stat()
    mode = stat.S_IMODE(info.st_mode)
    if mode & 0o027:
        fail(f"store directory must not be group-writable or open to others, got {mode:04o}")
    if mode & 0o700 != 0o700:
        fail(f"store directory must be owner-accessible, got {mode:04o}")
    if not mode & stat.S_ISGID:
        if corrected:
            # chmod is permitted to report success and drop setgid anyway when
            # the caller is neither privileged nor in the directory's group, so
            # the bit is read back rather than assumed from a clean return.
            fail(
                f"the setgid bit did not take on the store directory (mode is {mode:04o} after the attempt): "
                f"chmod drops it for a caller that is neither privileged nor a member of group {info.st_gid}; "
                "the installation is what must create this directory setgid."
            )
        fail(f"store directory must be setgid so its files inherit the reader's group, got {mode:04o}")
    return info.st_gid


def connect_database() -> Tuple[sqlite3.Connection, int]:
    expected_gid = ensure_store_directory(sink_root())
    # What the store already holds is checked before this run adds to it, so a
    # file whose group or mode drifted is refused rather than written through.
    audit_store_files(expected_gid)
    connection = sqlite3.connect(database_path(), timeout=10, isolation_level=None)
    connection.row_factory = sqlite3.Row
    # Not WAL. A reader without write access to this directory cannot create the
    # -shm wal-index, so a WAL store would refuse the broker's read-only open
    # outright. TRUNCATE keeps full durability with synchronous=FULL and stays
    # readable through group read alone.
    journal_mode = str(connection.execute("PRAGMA journal_mode=TRUNCATE").fetchone()[0]).lower()
    if journal_mode == "wal":
        connection.close()
        fail("the receipt store must not journal in WAL: the broker reads it with no write access to its directory")
    connection.execute("PRAGMA synchronous=FULL")
    # Before the first journal exists: SQLite gives a rollback journal the
    # database file's own permissions, so the database has to be correct first.
    harden_store_files(expected_gid)
    connection.executescript(
        """
        CREATE TABLE IF NOT EXISTS receipts (
          idempotency_key TEXT PRIMARY KEY,
          receipt_id TEXT NOT NULL UNIQUE,
          request_id TEXT NOT NULL UNIQUE,
          plan_digest TEXT NOT NULL UNIQUE,
          record_digest TEXT NOT NULL UNIQUE,
          journal_offset INTEGER,
          applied_at INTEGER NOT NULL
        );
        """
    )
    columns = {str(row["name"]) for row in connection.execute("PRAGMA table_info(receipts)")}
    if "journal_offset" not in columns:
        connection.execute("ALTER TABLE receipts ADD COLUMN journal_offset INTEGER")
    harden_store_files(expected_gid)
    return connection, expected_gid


def record_for(plan_digest: str, request_id: str, idempotency_key: str, operation: str) -> Dict[str, str]:
    """The deterministic record for one approved plan.

    Every member is ASCII hex or a registry slug, so compact sorted-key JSON is
    byte-identical to the canonical form the broker uses. bin/fm-action-gateway-v2.py
    builds the same object in sink_record(); tests/fm-action-safe-sink-v2.test.sh
    proves the two agree by running both rather than by comparing their sources.
    """
    return {
        "schema": RECORD_SCHEMA,
        "plan_digest": plan_digest,
        "request_id": request_id,
        "idempotency_key": idempotency_key,
        "operation": operation,
    }


def record_bytes(record: Dict[str, str]) -> bytes:
    return json.dumps(record, sort_keys=True, separators=(",", ":")).encode("utf-8")


def required_text(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value or len(value) > 256:
        fail(f"plan {label} is missing or refused")
    return value


def parse_plan(raw: bytes) -> Tuple[Dict[str, Any], str]:
    if not raw:
        fail("no plan on stdin")
    if len(raw) > MAX_PLAN_BYTES:
        fail(f"plan exceeds {MAX_PLAN_BYTES} bytes")
    try:
        plan = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"plan is not valid UTF-8 JSON: {exc}")
    if not isinstance(plan, dict) or plan.get("schema") != PLAN_SCHEMA:
        fail(f"plan schema must be {PLAN_SCHEMA}")
    executor = plan.get("executor")
    if not isinstance(executor, dict):
        fail("plan has no bound executor")
    if executor.get("outward_execution") is not False:
        fail("the safe sink refuses a plan that claims an outward executor")
    if executor.get("sha256") != own_identity():
        fail("plan authorizes different executor bytes than this program")
    return plan, sha256_bytes(raw)


def journal_record_digest(offset: Optional[int]) -> Optional[str]:
    """Hash the one journal line the receipt points at.

    The offset is recorded with the receipt, so this is a single seek and one
    line no matter how many records the journal already holds. It reports the
    digest of the bytes that are actually there rather than re-asserting the
    digest it was looking for.
    """
    if offset is None or offset < 0:
        return None
    try:
        with journal_path().open("rb") as handle:
            handle.seek(offset)
            line = handle.readline()
    except OSError:
        return None
    stripped = line.rstrip(b"\n")
    if not stripped:
        return None
    return sha256_bytes(stripped)


def readback(idempotency_key: str, record_digest: str, journal_offset: Optional[int]) -> Dict[str, Optional[str]]:
    """Re-read the committed effect instead of reporting the intended one."""
    observed_receipt: Optional[str] = None
    try:
        connection = sqlite3.connect(f"file:{urllib.parse.quote(str(database_path()))}?mode=ro", uri=True, timeout=10)
    except sqlite3.Error:
        connection = None
    if connection is not None:
        try:
            connection.row_factory = sqlite3.Row
            row = connection.execute("SELECT record_digest FROM receipts WHERE idempotency_key=?", (idempotency_key,)).fetchone()
            observed_receipt = str(row["record_digest"]) if row is not None else None
        except sqlite3.Error:
            observed_receipt = None
        finally:
            connection.close()
    observed_journal = journal_record_digest(journal_offset)
    verified = observed_receipt == record_digest and observed_journal == record_digest
    return {
        "readback_receipt_digest": observed_receipt,
        "readback_journal_digest": observed_journal,
        "readback_verified": verified,
    }


def apply_plan(raw: bytes) -> Dict[str, Any]:
    plan, plan_digest = parse_plan(raw)
    request_id = required_text(plan.get("request_id"), "request_id")
    idempotency_key = required_text(plan.get("idempotency_key"), "idempotency_key")
    operation = required_text(plan.get("operation"), "operation")
    record = record_for(plan_digest, request_id, idempotency_key, operation)
    encoded = record_bytes(record)
    digest = sha256_bytes(encoded)
    connection, expected_gid = connect_database()
    try:
        connection.execute("BEGIN IMMEDIATE")
        existing = connection.execute(
            "SELECT receipt_id,record_digest,journal_offset FROM receipts WHERE idempotency_key=?",
            (idempotency_key,),
        ).fetchone()
        if existing is not None:
            connection.execute("COMMIT")
            outcome = "already-applied"
            receipt_id = str(existing["receipt_id"])
            stored_digest = str(existing["record_digest"])
            stored_offset = existing["journal_offset"]
        else:
            receipt_id = secrets.token_hex(16)
            # The journal is written inside the transaction so a crash between
            # the two leaves the receipt uncommitted rather than leaving a
            # record nothing accounts for. The append offset is recorded with
            # the receipt so verification never has to rescan the journal.
            descriptor = os.open(journal_path(), os.O_WRONLY | os.O_APPEND | os.O_CREAT, STORE_FILE_MODE)
            try:
                # Set on the open descriptor rather than left to the umask, so
                # the journal carries the broker's read authority from the first
                # byte instead of from the hardening pass after the commit.
                journal_info = os.fstat(descriptor)
                if stat.S_IMODE(journal_info.st_mode) != STORE_FILE_MODE:
                    os.fchmod(descriptor, STORE_FILE_MODE)
                if journal_info.st_gid != expected_gid:
                    os.fchown(descriptor, -1, expected_gid)
                stored_offset = os.lseek(descriptor, 0, os.SEEK_END)
                try:
                    connection.execute(
                        "INSERT INTO receipts(idempotency_key,receipt_id,request_id,plan_digest,record_digest,journal_offset,applied_at) VALUES(?,?,?,?,?,?,?)",
                        (idempotency_key, receipt_id, request_id, plan_digest, digest, stored_offset, int(time.time())),
                    )
                except sqlite3.IntegrityError as exc:
                    connection.execute("ROLLBACK")
                    fail(f"safe sink refused a conflicting identity: {exc}")
                os.write(descriptor, encoded + b"\n")
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            connection.execute("COMMIT")
            outcome = "applied"
            stored_digest = digest
    except SinkError:
        raise
    except Exception:
        with contextlib.suppress(sqlite3.Error):
            connection.execute("ROLLBACK")
        raise
    finally:
        connection.close()
    harden_store_files(expected_gid)
    result = {
        "schema": RESULT_SCHEMA,
        "outcome": outcome,
        "receipt_id": receipt_id,
        "request_id": request_id,
        "idempotency_key": idempotency_key,
        "plan_digest": plan_digest,
        "record_digest": stored_digest,
        "outward_execution": False,
    }
    result.update(readback(idempotency_key, stored_digest, stored_offset))
    return result


def verify(idempotency_key: str) -> Dict[str, Any]:
    presence = "absent"
    digest: Optional[str] = None
    if database_path().exists():
        connection, _expected_gid = connect_database()
        try:
            row = connection.execute(
                "SELECT record_digest FROM receipts WHERE idempotency_key=?",
                (idempotency_key,),
            ).fetchone()
        finally:
            connection.close()
        if row is not None:
            presence = "present"
            digest = str(row["record_digest"])
    return {"schema": RESULT_SCHEMA, "outcome": presence, "idempotency_key": idempotency_key, "record_digest": digest}


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("apply")
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--idempotency-key", required=True)
    subparsers.add_parser("inspect-paths")
    return parser.parse_args(argv)


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    if args.command == "apply":
        raw = sys.stdin.buffer.read(MAX_PLAN_BYTES + 1)
        print(json.dumps(apply_plan(raw), sort_keys=True, separators=(",", ":")))
        return 0
    if args.command == "verify":
        print(json.dumps(verify(args.idempotency_key), sort_keys=True, separators=(",", ":")))
        return 0
    if args.command == "inspect-paths":
        paths = {
            "schema": "fm.safe-sink-paths.v2",
            "sink_root": str(sink_root()),
            "database": str(database_path()),
            "journal": str(journal_path()),
            "directory_mode": f"{STORE_DIRECTORY_MODE:04o}",
            "file_mode": f"{STORE_FILE_MODE:04o}",
            "executor_sha256": own_identity(),
        }
        print(json.dumps(paths, sort_keys=True, separators=(",", ":")))
        return 0
    fail("unknown command")


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (SinkError, sqlite3.Error, OSError) as exc:
        print(f"fm-action-safe-sink-v2: {exc}", file=sys.stderr)
        raise SystemExit(1)
