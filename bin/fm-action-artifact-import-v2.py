#!/usr/bin/env python3
"""Firstmate action gateway v2 quarantine artifact importer.

The Step 2.7 importer. It is the only sanctioned way an archive from outside the
isolation boundary becomes files inside it, and its contract is deliberately
blunt: an archive is imported in full or not at all.

Every member is validated before a single byte is written. If any member fails,
the importer writes nothing, leaves the destination exactly as it found it, and
exits nonzero. There is no partial import, because a partial import of a hostile
archive is the escape it was built to achieve - the first members land, then the
one that would have been refused is what everyone looks at.

What it refuses, and why each one is an escape rather than a malformed file:

  absolute path        writes outside the destination by naming its own root
  parent traversal     walks out of the destination with ..
  symlink or hardlink  redirects a later member's write to wherever it points
  device, fifo, socket  makes something no archive needs to carry
  duplicate name       lets a later member overwrite an already-validated one
  non-portable name    empty, ., NUL or control characters in a path component
  oversize, too many   exhausts the importing side instead of escaping it

The destination must exist, be a directory, and be empty. A caller that wants to
replace an import removes the directory first, so no import ever merges into
files somebody else placed.

Usage:
  fm-action-artifact-import-v2.py --input ARCHIVE --destination DIRECTORY
  fm-action-artifact-import-v2.py --input ARCHIVE --inspect

The first form is the argv contract bin/fm-worker-boundary-regression.sh's
--artifact-adapter expects. The second validates and reports without importing.
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import tarfile
import tempfile
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any, Dict, List, NoReturn, Sequence, Tuple

MAX_MEMBERS = 4096
MAX_MEMBER_BYTES = 64 * 1024 * 1024
MAX_TOTAL_BYTES = 256 * 1024 * 1024
MAX_NAME_BYTES = 1024
MAX_PATH_DEPTH = 32


class ImportRefused(Exception):
    """One named reason the archive was refused, safe to print."""


def refuse(message: str) -> NoReturn:
    raise ImportRefused(message)


def check_name(name: str) -> PurePosixPath:
    if not name or len(name.encode("utf-8")) > MAX_NAME_BYTES:
        refuse("member name is empty or too long")
    if "\x00" in name:
        refuse("member name contains NUL")
    if any(ord(character) < 0x20 or ord(character) == 0x7F for character in name):
        refuse(f"member name contains a control character: {name!r}")
    if name.startswith("/") or name.startswith("\\"):
        refuse(f"absolute member path refused: {name!r}")
    if ":" in name.split("/")[0] and len(name.split("/")[0]) == 2:
        refuse(f"drive-qualified member path refused: {name!r}")
    path = PurePosixPath(name)
    if path.is_absolute():
        refuse(f"absolute member path refused: {name!r}")
    parts = path.parts
    if not parts or len(parts) > MAX_PATH_DEPTH:
        refuse(f"member path depth refused: {name!r}")
    for part in parts:
        if part in ("", ".", ".."):
            refuse(f"member path escapes the destination: {name!r}")
    return path


def inspect_tar(archive: Path) -> List[Tuple[str, int]]:
    members: List[Tuple[str, int]] = []
    try:
        handle = tarfile.open(archive, "r:*")
    except (tarfile.TarError, OSError) as exc:
        refuse(f"archive is not a readable tar: {exc}")
    with handle:
        for info in handle:
            if len(members) >= MAX_MEMBERS:
                refuse(f"archive carries more than {MAX_MEMBERS} members")
            if info.issym() or info.islnk():
                refuse(f"link member refused: {info.name!r}")
            if info.ischr() or info.isblk() or info.isfifo() or info.isdev():
                refuse(f"device or fifo member refused: {info.name!r}")
            if not (info.isfile() or info.isdir()):
                refuse(f"unsupported member type refused: {info.name!r}")
            check_name(info.name)
            if info.size > MAX_MEMBER_BYTES:
                refuse(f"member exceeds the size ceiling: {info.name!r}")
            members.append((info.name, info.size if info.isfile() else 0))
    return members


def inspect_zip(archive: Path) -> List[Tuple[str, int]]:
    members: List[Tuple[str, int]] = []
    try:
        handle = zipfile.ZipFile(archive)
    except (zipfile.BadZipFile, OSError) as exc:
        refuse(f"archive is not a readable zip: {exc}")
    with handle:
        for info in handle.infolist():
            if len(members) >= MAX_MEMBERS:
                refuse(f"archive carries more than {MAX_MEMBERS} members")
            # The high 16 bits of external_attr carry the unix mode; S_IFLNK is
            # 0o120000. A zip can carry a symlink exactly like a tar can.
            mode = (info.external_attr >> 16) & 0o170000
            if mode == 0o120000:
                refuse(f"link member refused: {info.filename!r}")
            if mode and mode not in (0o100000, 0o040000):
                refuse(f"unsupported member type refused: {info.filename!r}")
            check_name(info.filename.rstrip("/") if info.is_dir() else info.filename)
            if info.file_size > MAX_MEMBER_BYTES:
                refuse(f"member exceeds the size ceiling: {info.filename!r}")
            members.append((info.filename, 0 if info.is_dir() else info.file_size))
    return members


def validate(archive: Path) -> Dict[str, Any]:
    if not archive.is_file():
        refuse("input archive is not a regular file")
    kind = "zip" if zipfile.is_zipfile(archive) else "tar"
    members = inspect_zip(archive) if kind == "zip" else inspect_tar(archive)
    if not members:
        refuse("archive carries no members")
    seen = set()
    total = 0
    for name, size in members:
        normalized = str(check_name(name.rstrip("/") if name.endswith("/") else name))
        if normalized in seen:
            refuse(f"duplicate member name refused: {name!r}")
        seen.add(normalized)
        total += size
        if total > MAX_TOTAL_BYTES:
            refuse("archive exceeds the total size ceiling")
    return {"kind": kind, "member_count": len(members), "total_bytes": total}


def extract_into(archive: Path, kind: str, staging: Path) -> None:
    if kind == "zip":
        with zipfile.ZipFile(archive) as handle:
            handle.extractall(staging)
        return
    with tarfile.open(archive, "r:*") as handle:
        # Python's own filter is a second, independent refusal of the same
        # escapes; the validation pass above is not weakened by leaning on it.
        handle.extractall(staging, filter="data")


def import_archive(archive: Path, destination: Path) -> Dict[str, Any]:
    summary = validate(archive)
    if not destination.is_dir():
        refuse("destination is not an existing directory")
    if any(destination.iterdir()):
        refuse("destination is not empty")
    staging = Path(tempfile.mkdtemp(prefix="fm-artifact-import.", dir=str(destination.parent)))
    try:
        extract_into(archive, summary["kind"], staging)
        for entry in sorted(staging.iterdir()):
            shutil.move(str(entry), str(destination / entry.name))
    except Exception as exc:  # noqa: BLE001 - any failure means nothing is imported
        for entry in list(destination.iterdir()):
            if entry.is_dir() and not entry.is_symlink():
                shutil.rmtree(entry, ignore_errors=True)
            else:
                entry.unlink(missing_ok=True)
        refuse(f"extraction refused, nothing imported: {exc}")
    finally:
        shutil.rmtree(staging, ignore_errors=True)
    return {"schema": "fm.artifact-import.v2", "outcome": "imported", **summary}


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--input", required=True)
    parser.add_argument("--destination")
    parser.add_argument("--inspect", action="store_true")
    args = parser.parse_args(argv)
    if not args.inspect and not args.destination:
        parser.error("--destination is required unless --inspect is given")
    return args


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    archive = Path(args.input)
    if args.inspect:
        summary = validate(archive)
        print(json.dumps({"schema": "fm.artifact-import.v2", "outcome": "accepted", **summary}, sort_keys=True, separators=(",", ":")))
        return 0
    result = import_archive(archive, Path(args.destination))
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (ImportRefused, OSError) as exc:
        print(f"fm-action-artifact-import-v2: refused: {exc}", file=sys.stderr)
        raise SystemExit(1)
