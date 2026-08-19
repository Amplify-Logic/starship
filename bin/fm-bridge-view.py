#!/usr/bin/env python3
"""Starship bridge view: phone page on IPv4 loopback.

The bind address is the literal LOOPBACK constant. There is no flag or
environment variable that widens it. Tailscale Serve publishes HTTPS in
front of this process; Funnel stays off.

This process never takes the session lock, never drains wakes, and never
writes backlog or fleet state. Session and passcode files live under the
home's 0700 bridge/ directory. Logs also go there, not into state/.
The only extra write path is authenticated photo drops into
data/bridge-inbox/ (mode 0700 quarantined storage).
"""

from __future__ import annotations

import argparse
import base64
import fcntl
import hashlib
import hmac
import html
import json
import os
import re
import secrets
import selectors
import signal
import socket
import subprocess
import sys
import threading
import time
import unicodedata
from contextlib import contextmanager
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import parse_qs, unquote, urlparse

LOOPBACK = "127.0.0.1"
DEFAULT_PORT = 8766
SESSION_TTL_SECONDS = 7 * 24 * 60 * 60
CACHE_TTL_SECONDS = 30
SNAPSHOT_TIMEOUT_SECONDS = 20
SNAPSHOT_MAX_BYTES = 1_000_000
COOKIE_NAME = "fm_bridge_sid"
COOKIE_PATH = "/"
SCRYPT_N = 2**14
SCRYPT_R = 8
SCRYPT_P = 1
SCRYPT_DKLEN = 32
BUCKET_CAP_NEEDS = 5
BUCKET_CAP_UNDERWAY = 8
BUCKET_CAP_LANDED = 6
BUCKET_CAP_WAITING = 5
STALE_CLIENT_SECONDS = 90
REFRESH_CLIENT_SECONDS = 30
MAILBOX_PORT = 8765
MAILBOX_LAUNCHD = "com.firstmate.glasses-voice-mailbox"
UPLOAD_MAX_BYTES = 15 * 1024 * 1024
BODY_DRAIN_TIMEOUT_SECONDS = 1.0
UPLOAD_RATE_LIMIT = 30
UPLOAD_RATE_WINDOW_SECONDS = 3600
UPLOAD_FIELD = "photo"
ALLOWED_CONTENT_TYPES = {
    "image/jpeg",
    "image/png",
    "image/webp",
    "image/heic",
    "image/heif",
}
HEIF_BRANDS = {
    b"heic",
    b"heix",
    b"heif",
    b"heis",
    b"heim",
    b"mif1",
    b"msf1",
    b"hevc",
    b"hevx",
}
SNIFF_TO_EXT = {"jpeg": "jpg", "png": "png", "webp": "webp", "heic": "heic"}
GITHUB_PR_RE = re.compile(r"^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+$")
IPV4_RE = re.compile(r"^\d{1,3}(?:\.\d{1,3}){3}$")
HOST_LABEL_RE = re.compile(r"^[A-Za-z0-9.-]+(?::\d+)?$")
CHILD_PATH = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"

TEST_MODE = os.environ.get("FM_BRIDGE_VIEW_TEST") == "1"


def fail(message: str, code: int = 1) -> None:
    print(f"fm-bridge-view: {message}", file=sys.stderr)
    raise SystemExit(code)


def is_ip_host(host: str) -> bool:
    name = host.split("%", 1)[0]
    if name.startswith("[") and name.endswith("]"):
        name = name[1:-1]
    if IPV4_RE.match(name):
        return True
    try:
        socket.inet_pton(socket.AF_INET6, name)
        return True
    except OSError:
        return False


def split_hostport(value: str) -> Tuple[str, Optional[str]]:
    raw = value.strip().lower()
    if raw.startswith("["):
        end = raw.find("]")
        if end == -1:
            return raw, None
        host = raw[1:end]
        rest = raw[end + 1 :]
        port = rest[1:] if rest.startswith(":") else None
        return host, port
    if raw.count(":") == 1:
        host, port = raw.split(":", 1)
        return host, port
    return raw, None


def load_host_config(home: Path) -> str:
    env_host = os.environ.get("FM_BRIDGE_VIEW_HOST", "").strip()
    if env_host:
        return env_host
    path = home / "config" / "bridge-view"
    if not path.is_file():
        return ""
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line.startswith("host="):
            return line.split("=", 1)[1].strip()
    return ""


def bridge_dir(home: Path) -> Path:
    return home / "bridge"


def ensure_bridge_dir(home: Path) -> Path:
    path = bridge_dir(home)
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path, 0o700)
    return path


def write_private(path: Path, data: bytes) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, data)
    finally:
        os.close(fd)
    os.chmod(path, 0o600)


def inbox_dir(home: Path) -> Path:
    return home / "data" / "bridge-inbox"


def ensure_inbox_dir(home: Path) -> Path:
    path = inbox_dir(home)
    if path.exists() and path.is_symlink():
        raise RuntimeError("bridge inbox path is a symlink")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path, 0o700)
    return path


def normalize_content_type(value: str) -> str:
    return value.split(";", 1)[0].strip().lower()


def sniff_image(data: bytes) -> Optional[str]:
    if len(data) >= 3 and data[:3] == b"\xff\xd8\xff":
        return "jpeg"
    if len(data) >= 8 and data[:8] == b"\x89PNG\r\n\x1a\n":
        return "png"
    if len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "webp"
    if len(data) >= 12 and data[4:8] == b"ftyp":
        brands = {data[8:12]}
        offset = 16
        while offset + 4 <= min(len(data), 64):
            brands.add(data[offset : offset + 4])
            offset += 4
        if brands & HEIF_BRANDS:
            return "heic"
    return None


def safe_original_name(name: str) -> str:
    cleaned = name.replace("\\", "/").replace("\x00", "")
    base = Path(cleaned).name.strip()
    if not base or base in {".", ".."}:
        return "photo"
    return base[:200]


def _multipart_boundary(content_type: str) -> Optional[bytes]:
    parts = [item.strip() for item in content_type.split(";")]
    if not parts or parts[0].lower() != "multipart/form-data":
        return None
    for item in parts[1:]:
        if item.lower().startswith("boundary="):
            value = item.split("=", 1)[1].strip().strip('"')
            if value:
                try:
                    return value.encode("ascii")
                except UnicodeEncodeError:
                    return None
    return None


def _disposition_filename(disposition: str) -> str:
    match = re.search(r"filename\*=(?:UTF-8''|utf-8'')([^;]+)", disposition, re.I)
    if match:
        return unquote(match.group(1).strip().strip('"'))
    match = re.search(r'filename="([^"]*)"', disposition, re.I)
    if match:
        return match.group(1)
    match = re.search(r"filename=([^;]+)", disposition, re.I)
    if match:
        return match.group(1).strip().strip('"')
    return ""


def _disposition_name(disposition: str) -> str:
    match = re.search(r'name="([^"]*)"', disposition, re.I)
    if match:
        return match.group(1)
    match = re.search(r"name=([^;]+)", disposition, re.I)
    if match:
        return match.group(1).strip().strip('"')
    return ""


def parse_multipart_photo(content_type: str, body: bytes) -> Optional[Tuple[bytes, str, str]]:
    boundary = _multipart_boundary(content_type)
    if not boundary:
        return None
    delim = b"--" + boundary
    index = body.find(delim)
    if index == -1:
        return None
    chunks = body[index:].split(delim)
    for chunk in chunks:
        if chunk in (b"", b"--", b"--\r\n", b"--\n"):
            continue
        if chunk.startswith(b"--"):
            continue
        if chunk.startswith(b"\r\n"):
            chunk = chunk[2:]
        elif chunk.startswith(b"\n"):
            chunk = chunk[1:]
        header_end = chunk.find(b"\r\n\r\n")
        sep_len = 4
        if header_end == -1:
            header_end = chunk.find(b"\n\n")
            sep_len = 2
        if header_end == -1:
            continue
        header_blob = chunk[:header_end].decode("utf-8", "replace")
        payload = chunk[header_end + sep_len :]
        if payload.endswith(b"\r\n"):
            payload = payload[:-2]
        elif payload.endswith(b"\n"):
            payload = payload[:-1]
        disposition = ""
        part_type = ""
        for line in header_blob.splitlines():
            lower = line.lower()
            if lower.startswith("content-disposition:"):
                disposition = line.split(":", 1)[1].strip()
            elif lower.startswith("content-type:"):
                part_type = line.split(":", 1)[1].strip()
        field = _disposition_name(disposition)
        filename = _disposition_filename(disposition)
        if field != UPLOAD_FIELD:
            continue
        return (
            payload,
            safe_original_name(filename or "photo"),
            normalize_content_type(part_type),
        )
    return None


def extract_upload(content_type: str, body: bytes) -> Optional[Tuple[bytes, str, str]]:
    normalized = normalize_content_type(content_type)
    if normalized == "multipart/form-data":
        return parse_multipart_photo(content_type, body)
    if normalized in ALLOWED_CONTENT_TYPES:
        return body, "photo", normalized
    return None


def photos_received_today(home: Path) -> int:
    inbox = inbox_dir(home)
    if not inbox.is_dir() or inbox.is_symlink():
        return 0
    today = time.strftime("%Y-%m-%d", time.gmtime())
    count = 0
    try:
        names = os.listdir(inbox)
    except OSError:
        return 0
    for name in names:
        if not name.endswith(".json") or name.startswith("."):
            continue
        path = inbox / name
        if path.is_symlink() or not path.is_file():
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError):
            continue
        if not isinstance(data, dict):
            continue
        received = str(data.get("received_at") or "")
        if received.startswith(today):
            count += 1
    return count


def write_inbox_pair(home: Path, payload: bytes, original_name: str, content_type: str, kind: str) -> str:
    inbox = ensure_inbox_dir(home)
    ext = SNIFF_TO_EXT[kind]
    sidecar = {
        "received_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "original_name": original_name,
        "size": len(payload),
        "content_type": content_type,
    }
    sidecar_bytes = json.dumps(sidecar, indent=2, sort_keys=True).encode("utf-8") + b"\n"
    for _ in range(16):
        stem = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + secrets.token_hex(8)
        dest = inbox / f"{stem}.{ext}"
        side = inbox / f"{stem}.json"
        if dest.exists() or side.exists() or dest.is_symlink() or side.is_symlink():
            continue
        stage = inbox / f".{stem}.{os.getpid()}.{secrets.token_hex(4)}.stage"
        tmp = stage / f"photo.{ext}"
        tmp_json = stage / "sidecar.json"
        staged = False
        published_side = False
        published_dest = False
        try:
            stage.mkdir(mode=0o700)
            staged = True
            write_private(tmp, payload)
            write_private(tmp_json, sidecar_bytes)
            os.link(tmp_json, side)
            published_side = True
            os.link(tmp, dest)
            published_dest = True
        except FileExistsError:
            continue
        except OSError:
            raise
        finally:
            if not published_dest and published_side:
                try:
                    side.unlink()
                except FileNotFoundError:
                    pass
            if published_dest and not published_side:
                try:
                    dest.unlink()
                except FileNotFoundError:
                    pass
            if staged:
                try:
                    tmp.unlink()
                except FileNotFoundError:
                    pass
                try:
                    tmp_json.unlink()
                except FileNotFoundError:
                    pass
                try:
                    stage.rmdir()
                except FileNotFoundError:
                    pass
        return stem
    raise RuntimeError("could not allocate a unique inbox name")


def scrypt_hash(password: str, salt: bytes) -> bytes:
    normalized = unicodedata.normalize("NFC", password).encode("utf-8")
    return hashlib.scrypt(
        normalized, salt=salt, n=SCRYPT_N, r=SCRYPT_R, p=SCRYPT_P, dklen=SCRYPT_DKLEN
    )


def format_passcode_record(salt: bytes, digest: bytes) -> str:
    return "scrypt$n={n}$r={r}$p={p}${salt}${digest}\n".format(
        n=SCRYPT_N,
        r=SCRYPT_R,
        p=SCRYPT_P,
        salt=base64.b64encode(salt).decode("ascii"),
        digest=base64.b64encode(digest).decode("ascii"),
    )


def parse_passcode_record(text: str) -> Tuple[bytes, bytes]:
    parts = text.strip().split("$")
    if len(parts) != 6 or parts[0] != "scrypt":
        fail("passcode hash file is malformed")
    try:
        salt = base64.b64decode(parts[4])
        digest = base64.b64decode(parts[5])
    except Exception:
        fail("passcode hash file is malformed")
    return salt, digest


def hash_passcode(password: str) -> str:
    salt = secrets.token_bytes(16)
    digest = scrypt_hash(password, salt)
    return format_passcode_record(salt, digest)


def verify_passcode(password: str, record: str) -> bool:
    salt, expected = parse_passcode_record(record)
    actual = scrypt_hash(password, salt)
    return hmac.compare_digest(actual, expected)


def generate_passcode() -> str:
    return secrets.token_urlsafe(24)


class SessionStore:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.lock_path = path.with_suffix(path.suffix + ".lock")
        self.lock = threading.Lock()

    @contextmanager
    def _locked(self):
        with self.lock:
            fd = os.open(str(self.lock_path), os.O_RDWR | os.O_CREAT, 0o600)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX)
                yield
            finally:
                fcntl.flock(fd, fcntl.LOCK_UN)
                os.close(fd)

    def _load(self) -> Dict[str, Any]:
        if not self.path.is_file():
            return {"sessions": {}}
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return {"sessions": {}}
        sessions = data.get("sessions")
        if not isinstance(sessions, dict):
            return {"sessions": {}}
        return {"sessions": sessions}

    def _save(self, data: Dict[str, Any]) -> None:
        payload = json.dumps(data, indent=2, sort_keys=True).encode("utf-8")
        temporary = self.path.with_name(f".{self.path.name}.{os.getpid()}.{secrets.token_hex(8)}")
        try:
            write_private(temporary, payload)
            os.replace(temporary, self.path)
        finally:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass

    def create(self) -> str:
        token = secrets.token_urlsafe(32)
        now = int(time.time())
        with self._locked():
            data = self._load()
            data["sessions"][token] = {
                "created": now,
                "expires": now + SESSION_TTL_SECONDS,
            }
            self._save(data)
        return token

    def valid(self, token: str) -> bool:
        if not token:
            return False
        now = int(time.time())
        with self._locked():
            data = self._load()
            row = data["sessions"].get(token)
            if not isinstance(row, dict):
                return False
            expires = int(row.get("expires") or 0)
            if expires <= now:
                data["sessions"].pop(token, None)
                self._save(data)
                return False
            return True

    def revoke(self, token: str) -> None:
        with self._locked():
            data = self._load()
            if token in data["sessions"]:
                data["sessions"].pop(token, None)
                self._save(data)

    def revoke_all(self) -> None:
        with self._locked():
            self._save({"sessions": {}})

    def record_upload(self, token: str) -> str:
        """Record one upload attempt. Returns ok, limited, or invalid."""
        if not token:
            return "invalid"
        now = int(time.time())
        window_start = now - UPLOAD_RATE_WINDOW_SECONDS
        with self._locked():
            data = self._load()
            row = data["sessions"].get(token)
            if not isinstance(row, dict):
                return "invalid"
            expires = int(row.get("expires") or 0)
            if expires <= now:
                data["sessions"].pop(token, None)
                self._save(data)
                return "invalid"
            raw_times = row.get("uploads") or []
            times: List[int] = []
            if isinstance(raw_times, list):
                for item in raw_times:
                    try:
                        stamp = int(item)
                    except (TypeError, ValueError):
                        continue
                    if stamp > window_start:
                        times.append(stamp)
            if len(times) >= UPLOAD_RATE_LIMIT:
                row["uploads"] = times
                self._save(data)
                return "limited"
            times.append(now)
            row["uploads"] = times
            self._save(data)
            return "ok"


def omitted_total(omitted: List[Dict[str, Any]], prefix: str, shown: int) -> int:
    for row in omitted:
        surface = str(row.get("surface") or "")
        if surface.startswith(prefix + " showing "):
            match = re.search(r" of (\d+)", surface)
            if match:
                return int(match.group(1))
    return shown


def map_dot(state: str) -> str:
    return {
        "parked": "Needs you",
        "working": "Under way",
        "paused": "Waiting",
        "done": "Ready",
        "failed": "Failed",
        "blocked": "Stuck",
        "unknown": "Stuck",
    }.get(state, "Under way")


def allowlisted_pr(url: str) -> Optional[str]:
    if GITHUB_PR_RE.match(url):
        return url
    return None


def project_observation(model: Dict[str, Any]) -> Dict[str, Any]:
    omitted = model.get("omitted") or []
    if not isinstance(omitted, list):
        omitted = []
    decisions = model.get("decisions_open") or []
    in_flight = model.get("in_flight") or []
    landed = model.get("landed") or []
    gates = model.get("gates") or []
    if not isinstance(decisions, list):
        decisions = []
    if not isinstance(in_flight, list):
        in_flight = []
    if not isinstance(landed, list):
        landed = []
    if not isinstance(gates, list):
        gates = []

    stuck_states = {"blocked", "failed", "parked"}
    needs_items: List[Dict[str, str]] = []
    for row in decisions:
        summary = str(row.get("summary") or "").strip()
        if summary:
            needs_items.append({"title": summary, "dot": "Needs you"})
    stuck_items: List[Dict[str, str]] = []
    underway_items: List[Dict[str, str]] = []
    waiting_live: List[Dict[str, str]] = []
    unknown_live = False
    for row in in_flight:
        state = str(row.get("state") or "")
        title = str(row.get("title") or "").strip() or "Untitled work"
        item = {"title": title, "dot": map_dot(state)}
        if state in stuck_states:
            stuck_items.append(item)
        elif state == "paused":
            waiting_live.append(item)
        elif state == "unknown":
            unknown_live = True
            underway_items.append(item)
        else:
            underway_items.append(item)
    needs_items.extend(stuck_items)

    landed_items: List[Dict[str, str]] = []
    for row in landed:
        title = str(row.get("what") or "").strip() or "Finished work"
        artifact = str(row.get("artifact") or "")
        pr = allowlisted_pr(artifact)
        item = {"title": title, "dot": "Ready"}
        if pr:
            item["url"] = pr
        landed_items.append(item)

    waiting_items: List[Dict[str, str]] = []
    waiting_items.extend(waiting_live)
    for row in gates:
        title = str(row.get("title") or "").strip() or "Queued work"
        waiting_items.append({"title": title, "dot": "Waiting"})

    decisions_total = omitted_total(omitted, "decisions_open", len(decisions))
    in_flight_total = omitted_total(omitted, "in_flight", len(in_flight))
    landed_total = omitted_total(omitted, "landed", len(landed))
    gates_total = omitted_total(omitted, "gates", len(gates))
    extra_decisions = max(0, decisions_total - len(decisions))
    extra_in_flight = max(0, in_flight_total - len(in_flight))
    extra_landed = max(0, landed_total - len(landed))
    extra_gates = max(0, gates_total - len(gates))

    def cap(items: List[Dict[str, str]], limit: int, extra: int) -> Tuple[List[Dict[str, str]], int]:
        more = extra + max(0, len(items) - limit)
        return items[:limit], more

    needs, needs_more = cap(needs_items, BUCKET_CAP_NEEDS, extra_decisions)
    underway, underway_more = cap(underway_items, BUCKET_CAP_UNDERWAY, extra_in_flight)
    finished, finished_more = cap(landed_items, BUCKET_CAP_LANDED, extra_landed)
    waiting, waiting_more = cap(waiting_items, BUCKET_CAP_WAITING, extra_gates)

    incomplete_reasons: List[str] = []
    for row in omitted:
        surface = str(row.get("surface") or "")
        if "unreadable" in surface or "unavailable" in surface or "truncated" in surface:
            incomplete_reasons.append(surface)
        if "main in-flight" in surface or "unstructured current" in surface:
            incomplete_reasons.append(surface)
    if unknown_live:
        incomplete_reasons.append("a live worker state is unknown")

    return {
        "generated": model.get("generated"),
        "needs_you": {"items": needs, "more": needs_more, "incomplete": bool(incomplete_reasons)},
        "under_way": {"items": underway, "more": underway_more, "incomplete": unknown_live or bool(incomplete_reasons)},
        "just_finished": {"items": finished, "more": finished_more, "incomplete": bool(extra_landed)},
        "waiting": {"items": waiting, "more": waiting_more, "incomplete": bool(incomplete_reasons)},
        "incomplete": bool(incomplete_reasons),
    }


def mailbox_listener_available() -> bool:
    port = MAILBOX_PORT
    if TEST_MODE:
        override = os.environ.get("FM_BRIDGE_VIEW_MAILBOX_PORT", "").strip()
        if override.isdigit():
            port = int(override)
    launchctl = os.environ.get("FM_BRIDGE_VIEW_LAUNCHCTL", "launchctl")
    uid = os.getuid()
    try:
        proc = subprocess.run(
            [launchctl, "print", f"gui/{uid}/{MAILBOX_LAUNCHD}"],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
            env={"PATH": CHILD_PATH},
        )
        if proc.returncode == 0 and "state = running" in proc.stdout:
            return True
    except (OSError, subprocess.TimeoutExpired):
        pass
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(0.2)
    try:
        result = sock.connect_ex((LOOPBACK, port))
        return result == 0
    except OSError:
        return False
    finally:
        sock.close()


def _tailscale_output(args: List[str]) -> Tuple[int, str]:
    try:
        proc = subprocess.run(
            ["tailscale", *args],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
            env={"PATH": os.environ.get("PATH", CHILD_PATH)},
        )
    except FileNotFoundError:
        return 127, "tailscale not found"
    except subprocess.TimeoutExpired:
        return 124, "timed out"
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def _allow_funnel_from_json(text: str) -> Optional[bool]:
    raw = text.strip()
    if not raw.startswith("{"):
        return None
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        return None
    if not isinstance(parsed, dict):
        return None
    allow = parsed.get("AllowFunnel")
    if isinstance(allow, dict) and any(bool(value) for value in allow.values()):
        return True
    return False


def funnel_is_on() -> Tuple[bool, str]:
    json_rc, json_text = _tailscale_output(["funnel", "status", "--json"])
    if json_rc == 0:
        json_allow = _allow_funnel_from_json(json_text)
        if json_allow is not None:
            return json_allow, json_text.strip() or "No serve config"
    rc, text = _tailscale_output(["funnel", "status"])
    lowered = text.lower()
    if rc == 0 and ("no serve config" in lowered or "funnel is not enabled" in lowered):
        return False, text.strip() or "No serve config"
    if rc == 0 and "tailnet only" in lowered:
        return False, text.strip()
    if rc == 0 and re.search(r"\bfunnel\s+(?:is\s+)?(?:enabled|on|active)\b|\(funnel\)", lowered):
        return True, text.strip()
    if rc == 0 and "https://" in lowered:
        return False, text.strip()
    detail = text.strip() or json_text.strip() or "status unavailable"
    return True, f"could not verify Funnel is off: {detail}"


def _kill_process_group(proc: subprocess.Popen[bytes]) -> None:
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def _bounded_process_output(proc: subprocess.Popen[bytes]) -> Tuple[bytes, bytes]:
    selector = selectors.DefaultSelector()
    streams = {proc.stdout: bytearray(), proc.stderr: bytearray()}
    terminated = False
    for stream in streams:
        if stream is not None:
            selector.register(stream, selectors.EVENT_READ)
    deadline = time.monotonic() + SNAPSHOT_TIMEOUT_SECONDS
    try:
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                _kill_process_group(proc)
                terminated = True
                raise RuntimeError("bearings snapshot timed out")
            events = selector.select(remaining)
            if not events:
                _kill_process_group(proc)
                terminated = True
                raise RuntimeError("bearings snapshot timed out")
            for key, _ in events:
                chunk = os.read(key.fileobj.fileno(), 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                streams[key.fileobj].extend(chunk)
                if sum(len(output) for output in streams.values()) > SNAPSHOT_MAX_BYTES:
                    _kill_process_group(proc)
                    terminated = True
                    raise RuntimeError("bearings snapshot exceeded size cap")
        try:
            proc.wait(timeout=max(0.1, deadline - time.monotonic()))
        except subprocess.TimeoutExpired as exc:
            _kill_process_group(proc)
            terminated = True
            raise RuntimeError("bearings snapshot timed out") from exc
    finally:
        selector.close()
        if not terminated:
            _kill_process_group(proc)
        proc.wait()
    return bytes(streams.get(proc.stdout, b"")), bytes(streams.get(proc.stderr, b""))


def run_snapshot(home: Path, root: Path) -> Dict[str, Any]:
    script = root / "bin" / "fm-bearings-snapshot.sh"
    if not script.is_file():
        raise RuntimeError(f"bearings snapshot missing: {script}")
    scratch = Path(os.environ.get("TMPDIR") or "/tmp") / f"fm-bridge-view-{os.getpid()}"
    scratch.mkdir(mode=0o700, exist_ok=True)
    env = {
        "PATH": CHILD_PATH,
        "HOME": os.environ.get("HOME", "/var/empty"),
        "TMPDIR": str(scratch),
        "LANG": "C",
        "LC_ALL": "C",
        "FM_HOME": str(home),
        "FM_ROOT_OVERRIDE": str(root),
    }
    proc = subprocess.Popen(
        [str(script), "--json", "--passive-view", "--all-in-flight"],
        cwd=str(scratch),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    stdout, stderr = _bounded_process_output(proc)
    if proc.returncode != 0:
        err = (stderr or stdout).decode("utf-8", "replace").strip()
        raise RuntimeError(err or f"bearings snapshot exited {proc.returncode}")
    try:
        model = json.loads(stdout.decode("utf-8"))
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"bearings snapshot was not JSON: {exc}") from exc
    if not isinstance(model, dict) or model.get("schema") != "fm-bearings.v1":
        raise RuntimeError("bearings snapshot schema mismatch")
    return model


class SnapshotCache:
    def __init__(self, home: Path, root: Path) -> None:
        self.home = home
        self.root = root
        self.lock = threading.Lock()
        self.refresh = threading.Lock()
        self.payload: Optional[Dict[str, Any]] = None
        self.fetched_at = 0.0
        self.error: Optional[str] = None

    def get(self) -> Dict[str, Any]:
        now = time.monotonic()
        with self.lock:
            if self.payload is not None and now - self.fetched_at < CACHE_TTL_SECONDS:
                return dict(self.payload)
        with self.refresh:
            now = time.monotonic()
            with self.lock:
                if self.payload is not None and now - self.fetched_at < CACHE_TTL_SECONDS:
                    return dict(self.payload)
            started = time.time()
            model = run_snapshot(self.home, self.root)
            observation = project_observation(model)
            observation["mailbox_listener"] = mailbox_listener_available()
            observation["read_started"] = model.get("generated")
            observation["server_unix"] = int(started)
            with self.lock:
                self.payload = observation
                self.fetched_at = time.monotonic()
                self.error = None
            return dict(observation)


def csp(nonce: str) -> str:
    return (
        "default-src 'none'; "
        f"style-src 'nonce-{nonce}'; "
        f"script-src 'nonce-{nonce}'; "
        "img-src 'self'; "
        "connect-src 'self'; "
        "form-action 'self'; "
        "base-uri 'none'; "
        "frame-ancestors 'none'"
    )


def security_headers(nonce: str) -> List[Tuple[str, str]]:
    return [
        ("Cache-Control", "no-store"),
        ("Content-Security-Policy", csp(nonce)),
        ("Referrer-Policy", "no-referrer"),
        ("X-Content-Type-Options", "nosniff"),
        ("X-Frame-Options", "DENY"),
    ]


PAGE_CSS = """
:root { color-scheme: dark; }
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; }
body {
  font-family: ui-sans-serif, system-ui, -apple-system, sans-serif;
  background: #101418;
  color: #f2f4f3;
  line-height: 1.45;
  padding: max(1rem, env(safe-area-inset-top)) 1.1rem 2rem;
}
main { max-width: 40rem; margin: 0 auto; }
h1 { font-size: 0.8rem; letter-spacing: 0.18em; text-transform: uppercase; margin: 0 0 0.4rem; color: #9aa7a0; }
h2 { font-size: 0.78rem; letter-spacing: 0.12em; text-transform: uppercase; margin: 1.4rem 0 0.5rem; color: #c5d0c8; }
.meta { color: #c5d0c8; font-size: 0.95rem; }
.warn { color: #e6c07b; font-size: 0.92rem; margin: 0.4rem 0 0; }
ul { list-style: none; padding: 0; margin: 0; }
li { padding: 0.55rem 0; border-bottom: 1px solid #2a3330; font-size: 1.05rem; }
.dot { display: inline-block; width: 0.65rem; height: 0.65rem; border-radius: 50%; margin-right: 0.55rem; background: #6ea8fe; }
.dot.needs { background: #c084fc; }
.dot.under { background: #6ea8fe; }
.dot.wait { background: #fbbf24; }
.dot.ready { background: #34d399; }
.dot.failed { background: #f87171; }
.dot.stuck { background: #fb923c; }
.more, .empty, .incomplete { color: #9aa7a0; font-size: 0.92rem; margin: 0.4rem 0 0; }
a { color: #9cdcfe; }
input, button {
  font: inherit; width: 100%; min-height: 2.75rem; border-radius: 0.5rem;
  border: 1px solid #3b4742; padding: 0.6rem 0.8rem;
}
input { background: #1b2220; color: inherit; margin: 0.8rem 0; }
button { background: #d7e0d8; color: #101418; font-weight: 600; }
.note { color: #9aa7a0; font-size: 0.9rem; }
.ok { color: #34d399; font-size: 0.95rem; margin: 0.4rem 0 0; }
#photo-form { margin: 1.1rem 0 0.4rem; }
#photo-form label { display: block; margin-bottom: 0.35rem; }
#stale {
  display: none; position: fixed; inset: 0; background: #101418;
  color: #f2f4f3; align-items: center; justify-content: center;
  text-align: center; padding: 2rem; font-size: 1.4rem; z-index: 9;
}
#stale.on { display: flex; }
header { display: flex; justify-content: space-between; align-items: baseline; gap: 1rem; }
form.logout { margin: 0; width: auto; }
form.logout button { width: auto; min-height: 2rem; padding: 0.3rem 0.7rem; background: transparent; color: #c5d0c8; border-color: #3b4742; }
"""

PAGE_JS = """
const STALE_MS = %d * 1000;
const REFRESH_MS = %d * 1000;
let lastSuccess = Date.now();
function esc(value) {
  return String(value).replace(/[&<>"']/g, function(ch) {
    return ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]);
  });
}
function setStale(on) {
  const el = document.getElementById('stale');
  if (!el) return;
  el.classList.toggle('on', on);
}
function dotClass(name) {
  if (name === 'Needs you') return 'needs';
  if (name === 'Under way') return 'under';
  if (name === 'Waiting') return 'wait';
  if (name === 'Ready') return 'ready';
  if (name === 'Failed') return 'failed';
  if (name === 'Stuck') return 'stuck';
  return 'under';
}
function renderBucket(id, bucket, emptyText) {
  const root = document.getElementById(id);
  if (!root || !bucket) return;
  const items = bucket.items || [];
  const lines = items.map(function(item) {
    const title = esc(item.title || '');
    const url = item.url || '';
    const safeUrl = /^https:\\/\\/github\\.com\\/[A-Za-z0-9_.-]+\\/[A-Za-z0-9_.-]+\\/pull\\/[0-9]+$/.test(url) ? url : '';
    const label = safeUrl
      ? '<a href="' + safeUrl + '" rel="noreferrer">' + title + '</a>'
      : title;
    return '<li><span class="dot ' + dotClass(item.dot) + '"></span>' + label + '</li>';
  });
  let extra = '';
  if (bucket.more > 0) extra += '<p class="more">' + bucket.more + ' more waiting</p>';
  if (bucket.incomplete) extra += '<p class="incomplete">This list may be incomplete.</p>';
  if (!items.length) {
    extra = '<p class="' + (bucket.incomplete ? 'incomplete' : 'empty') + '">' +
      (bucket.incomplete ? 'This list may be incomplete.' : emptyText) + '</p>' +
      (bucket.more > 0 ? '<p class="more">' + bucket.more + ' more waiting</p>' : '');
  }
  root.innerHTML = (lines.length ? '<ul>' + lines.join('') + '</ul>' : '') + extra;
}
function apply(data) {
  lastSuccess = Date.now();
  setStale(false);
  const age = document.getElementById('observed');
  if (age) age.textContent = 'Observed just now';
  const desk = document.getElementById('desk');
  if (desk) desk.textContent = 'Desk reachable';
  const mail = document.getElementById('mailbox');
  if (mail) mail.textContent = data.mailbox_listener ? 'Mailbox on' : 'Mailbox listener off';
  renderBucket('needs', data.needs_you, 'Nothing needs you right now.');
  renderBucket('underway', data.under_way, 'Nothing is under way.');
  renderBucket('finished', data.just_finished, 'No recent completions.');
  renderBucket('waiting', data.waiting, 'Nothing is waiting.');
  const count = document.getElementById('photo-count');
  if (count) count.textContent = 'Photos received today: ' + (data.photos_today || 0);
}
async function sendPhoto(ev) {
  ev.preventDefault();
  const input = document.getElementById('photo');
  const status = document.getElementById('photo-result');
  if (!input || !status) return;
  if (!input.files || !input.files.length) {
    status.className = 'warn';
    status.textContent = 'Choose a photo first.';
    return;
  }
  status.className = 'note';
  status.textContent = 'Sending photo…';
  try {
    const body = new FormData();
    body.append('photo', input.files[0]);
    const res = await fetch('/upload', {
      method: 'POST',
      body: body,
      credentials: 'same-origin',
      cache: 'no-store'
    });
    const payload = await res.json().catch(function() { return {}; });
    if (!res.ok) {
      status.className = 'warn';
      status.textContent = payload.error || ('Send failed (' + res.status + ')');
      return;
    }
    status.className = 'ok';
    status.textContent = 'Photo received.';
    input.value = '';
    const count = document.getElementById('photo-count');
    if (count && payload.received_today != null) {
      count.textContent = 'Photos received today: ' + payload.received_today;
    }
  } catch (err) {
    status.className = 'warn';
    status.textContent = 'Send failed.';
  }
}
function tickObserved() {
  const age = document.getElementById('observed');
  if (!age) return;
  const seconds = Math.max(0, Math.round((Date.now() - lastSuccess) / 1000));
  age.textContent = 'Observed ' + seconds + ' seconds ago';
  if (Date.now() - lastSuccess > STALE_MS) setStale(true);
}
async function refresh() {
  try {
    const ctl = new AbortController();
    const timer = setTimeout(function() { ctl.abort(); }, 10000);
    const res = await fetch('/api/observation', { credentials: 'same-origin', cache: 'no-store', signal: ctl.signal });
    clearTimeout(timer);
    if (!res.ok) throw new Error('status ' + res.status);
    apply(await res.json());
  } catch (err) {
    tickObserved();
  }
}
document.addEventListener('DOMContentLoaded', function() {
  refresh();
  setInterval(refresh, REFRESH_MS);
  setInterval(tickObserved, 1000);
  document.addEventListener('visibilitychange', function() { if (!document.hidden) refresh(); });
  window.addEventListener('pageshow', function() { refresh(); });
  const form = document.getElementById('photo-form');
  if (form) form.addEventListener('submit', sendPhoto);
});
""" % (STALE_CLIENT_SECONDS, REFRESH_CLIENT_SECONDS)


def login_html(nonce: str, error: str = "") -> str:
    err = f'<p class="warn">{html.escape(error)}</p>' if error else ""
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="referrer" content="no-referrer">
<title>STARSHIP</title>
<style nonce="{nonce}">{PAGE_CSS}</style>
</head>
<body>
<main>
<h1>Starship</h1>
<p>Log in</p>
{err}
<form method="post" action="/login" autocomplete="current-password">
<label for="passcode">Passcode</label>
<input id="passcode" name="passcode" type="password" required>
<button type="submit">Continue</button>
</form>
<p class="note">Only on your private network.</p>
</main>
</body>
</html>
"""


def glance_html(nonce: str) -> str:
    js = PAGE_JS
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="referrer" content="no-referrer">
<title>STARSHIP</title>
<style nonce="{nonce}">{PAGE_CSS}</style>
<script nonce="{nonce}">{js}</script>
</head>
<body>
<div id="stale">Cannot reach the desk.</div>
<main>
<header>
  <h1>Starship</h1>
  <form class="logout" method="post" action="/logout"><button type="submit">Log out</button></form>
</header>
<p class="meta"><span id="desk">Desk reachable</span> · <span id="mailbox">Mailbox…</span></p>
<p class="meta" id="observed">Observed just now</p>
<p class="warn">Summary only. Do not approve from this page.</p>
<h2>Send a photo</h2>
<form id="photo-form" method="post" action="/upload" enctype="multipart/form-data">
  <label for="photo">Photo</label>
  <input id="photo" name="photo" type="file" accept="image/jpeg,image/png,image/webp,image/heic,image/heif,image/*" capture="environment">
  <button type="submit">Send photo</button>
</form>
<p class="meta" id="photo-count">Photos received today: 0</p>
<p id="photo-result" class="note"></p>
<h2>Needs you</h2>
<div id="needs"><p class="empty">Loading…</p></div>
<h2>Under way</h2>
<div id="underway"><p class="empty">Loading…</p></div>
<h2>Just finished</h2>
<div id="finished"><p class="empty">Loading…</p></div>
<h2>Waiting in the wings</h2>
<div id="waiting"><p class="empty">Loading…</p></div>
</main>
</body>
</html>
"""


class BridgeState:
    def __init__(self, home: Path, root: Path, expected_host: str) -> None:
        self.home = home
        self.root = root
        self.expected_host = expected_host.lower()
        self.sessions = SessionStore(bridge_dir(home) / "sessions.json")
        self.cache = SnapshotCache(home, root)
        self.passcode_path = bridge_dir(home) / "passcode.hash"
        self.login_lock = threading.Lock()

    def expected_hosts(self) -> set[str]:
        host = self.expected_host
        return {host, f"{host}:443"}

    def expected_origins(self) -> set[str]:
        host = self.expected_host
        return {f"https://{host}", f"https://{host}:443"}


STATE: Optional[BridgeState] = None


class BridgeHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def handle_one_request(self) -> None:
        self._body_drained = False
        super().handle_one_request()

    def log_message(self, fmt: str, *args: Any) -> None:
        log_path = bridge_dir(STATE.home) / "bridge.log" if STATE else None
        line = "%s - %s\n" % (self.log_date_time_string(), fmt % args)
        if log_path is not None:
            try:
                with open(log_path, "a", encoding="utf-8") as handle:
                    handle.write(line)
            except OSError:
                pass

    def _host_ok(self) -> bool:
        header = (self.headers.get("Host") or "").strip()
        if not header or not HOST_LABEL_RE.match(header):
            return False
        host, _port = split_hostport(header)
        if is_ip_host(host):
            return False
        return header.lower() in STATE.expected_hosts() or host in STATE.expected_hosts()

    def _origin_ok(self) -> bool:
        # When Origin is present it must match the expected Serve origin exactly.
        # iPhone Safari omits Origin on same-origin form POST, or sends the
        # literal string "null" as privacy masking; treat both as absent.
        # Accept an absent Origin only when Fetch Metadata (Sec-Fetch-Site
        # same-origin or none) or an https Referer to the expected host
        # independently proves same-origin.
        origin = (self.headers.get("Origin") or "").strip()
        if origin and origin.lower() != "null":
            return origin.rstrip("/").lower() in STATE.expected_origins()
        site = (self.headers.get("Sec-Fetch-Site") or "").strip().lower()
        if site in {"same-origin", "none"}:
            return True
        referer = (self.headers.get("Referer") or "").strip()
        if not referer:
            return False
        parsed = urlparse(referer)
        if parsed.scheme.lower() != "https":
            return False
        host = (parsed.netloc or "").strip().rstrip("/").lower()
        expected = {item.lower() for item in STATE.expected_hosts()}
        return host in expected

    def _discard_body(self) -> List[Tuple[str, str]]:
        # Early 403/404/413 returns must drain the unread POST body. Leaving it
        # on a keep-alive socket makes the next parse treat passcode=... as a
        # request line (400 / 501). Close instead when the declared length is
        # missing or larger than any accepted upload.
        if getattr(self, "_body_drained", False):
            return []
        self._body_drained = True
        raw = (self.headers.get("Content-Length") or "").strip()
        if not raw.isdigit():
            return [("Connection", "close")] if self.command == "POST" else []
        length = int(raw)
        if length > UPLOAD_MAX_BYTES:
            return [("Connection", "close")]
        remaining = length
        deadline = time.monotonic() + BODY_DRAIN_TIMEOUT_SECONDS
        previous_timeout = self.connection.gettimeout()
        try:
            while remaining:
                timeout = deadline - time.monotonic()
                if timeout <= 0:
                    self.close_connection = True
                    return [("Connection", "close")]
                self.connection.settimeout(timeout)
                chunk = self.rfile.read1(min(remaining, 65536))
                if not chunk:
                    self.close_connection = True
                    return [("Connection", "close")]
                remaining -= len(chunk)
        except (TimeoutError, socket.timeout):
            self.close_connection = True
            return [("Connection", "close")]
        finally:
            self.connection.settimeout(previous_timeout)
        return []

    def _with_drained_body(
        self, extra: Optional[List[Tuple[str, str]]]
    ) -> List[Tuple[str, str]]:
        merged: List[Tuple[str, str]] = list(extra or [])
        for key, value in self._discard_body():
            if not any(existing[0].lower() == key.lower() for existing in merged):
                merged.append((key, value))
        return merged

    def _send(self, code: int, body: bytes, content_type: str, extra: Optional[List[Tuple[str, str]]] = None) -> None:
        nonce = secrets.token_urlsafe(16)
        extra = self._with_drained_body(extra)
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for key, value in security_headers(nonce):
            if key == "Content-Security-Policy" and content_type.startswith("application/json"):
                self.send_header(key, "default-src 'none'; frame-ancestors 'none'")
            elif key == "Content-Security-Policy":
                self.send_header(key, csp(nonce))
            else:
                self.send_header(key, value)
        for key, value in extra:
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def _html(self, code: int, renderer, extra: Optional[List[Tuple[str, str]]] = None, **kwargs: Any) -> None:
        nonce = secrets.token_urlsafe(16)
        extra = self._with_drained_body(extra)
        body = renderer(nonce, **kwargs).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        for key, value in security_headers(nonce):
            self.send_header(key, value)
        for key, value in extra:
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def _session(self) -> str:
        raw = self.headers.get("Cookie") or ""
        cookie = SimpleCookie()
        try:
            cookie.load(raw)
        except Exception:
            return ""
        morsel = cookie.get(COOKIE_NAME)
        return morsel.value if morsel else ""

    def _authed(self) -> bool:
        return STATE.sessions.valid(self._session())

    def _set_cookie(self, token: str) -> str:
        return (
            f"{COOKIE_NAME}={token}; HttpOnly; Secure; SameSite=Strict; "
            f"Path={COOKIE_PATH}; Max-Age={SESSION_TTL_SECONDS}"
        )

    def _clear_cookie(self) -> str:
        return f"{COOKIE_NAME}=; HttpOnly; Secure; SameSite=Strict; Path={COOKIE_PATH}; Max-Age=0"

    def do_GET(self) -> None:  # noqa: N802
        if STATE is None or not self._host_ok():
            self._send(403, b"forbidden\n", "text/plain; charset=utf-8")
            return
        parsed = urlparse(self.path)
        if parsed.path == "/":
            if self._authed():
                self._html(200, glance_html)
            else:
                self._html(200, login_html)
            return
        if parsed.path == "/api/observation":
            if not self._authed():
                self._send(401, b'{"error":"unauthorized"}\n', "application/json")
                return
            try:
                payload = STATE.cache.get()
            except Exception as exc:
                self._send(503, json.dumps({"error": "desk unreachable", "detail": str(exc)}).encode("utf-8"), "application/json")
                return
            payload["photos_today"] = photos_received_today(STATE.home)
            body = json.dumps(payload).encode("utf-8")
            self._send(200, body, "application/json")
            return
        self._send(404, b"not found\n", "text/plain; charset=utf-8")

    def _json_error(self, code: int, message: str, extra: Optional[List[Tuple[str, str]]] = None) -> None:
        body = json.dumps({"error": message}).encode("utf-8") + b"\n"
        self._send(code, body, "application/json", extra=extra)

    def _handle_upload(self) -> None:
        if not self._origin_ok():
            self._send(403, b"forbidden\n", "text/plain; charset=utf-8")
            return
        token = self._session()
        if not STATE.sessions.valid(token):
            self._json_error(401, "unauthorized")
            return
        length_header = self.headers.get("Content-Length")
        if length_header is None or not str(length_header).strip().isdigit():
            self._json_error(400, "missing content length")
            return
        length = int(length_header)
        if length > UPLOAD_MAX_BYTES:
            self._json_error(413, "too large", extra=[("Connection", "close")])
            return
        if length <= 0:
            self._json_error(400, "empty body")
            return
        rate = STATE.sessions.record_upload(token)
        if rate == "invalid":
            self._json_error(401, "unauthorized")
            return
        if rate == "limited":
            self._json_error(429, "too many uploads")
            return
        raw = self.rfile.read(length) if length else b""
        self._body_drained = True
        if len(raw) > UPLOAD_MAX_BYTES:
            self._json_error(413, "too large")
            return
        content_type = self.headers.get("Content-Type") or ""
        extracted = extract_upload(content_type, raw)
        if extracted is None:
            self._json_error(415, "unsupported media type")
            return
        payload, original_name, declared = extracted
        if not payload:
            self._json_error(415, "unsupported media type")
            return
        if declared not in ALLOWED_CONTENT_TYPES:
            self._json_error(415, "unsupported media type")
            return
        kind = sniff_image(payload)
        if kind is None:
            self._json_error(415, "unsupported media type")
            return
        try:
            write_inbox_pair(STATE.home, payload, original_name, declared, kind)
        except Exception as exc:
            self._json_error(500, str(exc) if TEST_MODE else "upload failed")
            return
        body = json.dumps(
            {"ok": True, "received_today": photos_received_today(STATE.home)}
        ).encode("utf-8")
        self._send(200, body, "application/json")

    def do_POST(self) -> None:  # noqa: N802
        if STATE is None or not self._host_ok():
            self._send(403, b"forbidden\n", "text/plain; charset=utf-8")
            return
        parsed = urlparse(self.path)
        if parsed.path == "/upload":
            self._handle_upload()
            return
        if parsed.path not in {"/login", "/logout"}:
            self._send(404, b"not found\n", "text/plain; charset=utf-8")
            return
        if not self._origin_ok():
            self._send(403, b"forbidden\n", "text/plain; charset=utf-8")
            return
        length = int(self.headers.get("Content-Length") or 0)
        if length > 4096:
            self._send(413, b"too large\n", "text/plain; charset=utf-8")
            return
        raw = self.rfile.read(length) if length else b""
        self._body_drained = True
        if parsed.path == "/logout":
            STATE.sessions.revoke(self._session())
            self._html(303, login_html, extra=[("Set-Cookie", self._clear_cookie()), ("Location", "/")])
            return
        fields = parse_qs(raw.decode("utf-8", "replace"))
        password = (fields.get("passcode") or [""])[0]
        record_path = STATE.passcode_path
        if not record_path.is_file():
            self._html(500, login_html, error="Passcode is not initialized.")
            return
        record = record_path.read_text(encoding="utf-8")
        with STATE.login_lock:
            ok = verify_passcode(password, record)
            if not TEST_MODE:
                time.sleep(0.2 if ok else 0.8)
        if not ok:
            self._html(401, login_html, error="That passcode was not accepted.")
            return
        STATE.sessions.revoke(self._session())
        token = STATE.sessions.create()
        self.send_response(303)
        nonce = secrets.token_urlsafe(16)
        self.send_header("Location", "/")
        self.send_header("Set-Cookie", self._set_cookie(token))
        self.send_header("Content-Length", "0")
        for key, value in security_headers(nonce):
            self.send_header(key, value)
        self.end_headers()


def command_init_passcode(home: Path) -> None:
    ensure_bridge_dir(home)
    hash_path = bridge_dir(home) / "passcode.hash"
    if hash_path.is_file():
        fail("passcode hash already exists; revoke or replace it by hand")
    password = generate_passcode()
    write_private(hash_path, hash_passcode(password).encode("utf-8"))
    plaintext = home / "data" / "bridge-view-passcode.txt"
    plaintext.parent.mkdir(parents=True, exist_ok=True)
    write_private(plaintext, (password + "\n").encode("utf-8"))
    print(plaintext)


def command_revoke(home: Path) -> None:
    ensure_bridge_dir(home)
    SessionStore(bridge_dir(home) / "sessions.json").revoke_all()
    print("revoked")


def command_render_plist(home: Path, root: Path) -> None:
    script = root / "bin" / "fm-bridge-view.sh"
    log = bridge_dir(home) / "bridge.log"
    print(
        f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.firstmate.bridge-view</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>{script}</string>
    <string>serve</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>FM_HOME</key>
    <string>{home}</string>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>WorkingDirectory</key>
  <string>{root}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>10</integer>
  <key>StandardOutPath</key>
  <string>{log}</string>
  <key>StandardErrorPath</key>
  <string>{log}</string>
</dict>
</plist>
"""
    )


def command_mailbox() -> None:
    print("on" if mailbox_listener_available() else "off")


def command_funnel() -> None:
    on, detail = funnel_is_on()
    if on:
        fail(f"Tailscale Funnel is on; refuse to publish the bridge: {detail}")
    print(detail or "No serve config")


def command_serve(home: Path, root: Path, port: int, host: str) -> None:
    if not host:
        fail("expected Serve hostname is missing; set FM_BRIDGE_VIEW_HOST or config/bridge-view host=")
    if is_ip_host(host):
        fail("expected host must be a MagicDNS name, not an IP")
    ensure_bridge_dir(home)
    on, detail = funnel_is_on()
    if on:
        fail(f"Tailscale Funnel is on; refuse to publish the bridge: {detail}")
    if not (bridge_dir(home) / "passcode.hash").is_file() and not TEST_MODE:
        fail("passcode hash is missing; run fm-bridge-view.sh init-passcode")
    global STATE
    STATE = BridgeState(home, root, host)
    try:
        ThreadingHTTPServer.allow_reuse_address = True
        server = ThreadingHTTPServer((LOOPBACK, port), BridgeHandler)
        server.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    except OSError as exc:
        fail(f"could not bind {LOOPBACK}:{port}: {exc}")
    bound = server.server_address[1]
    print(f"listening on {LOOPBACK}:{bound}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("stopping", flush=True)
    finally:
        server.server_close()


def main(argv: Optional[List[str]] = None) -> None:
    parser = argparse.ArgumentParser(prog="fm-bridge-view.py")
    sub = parser.add_subparsers(dest="command", required=True)
    serve = sub.add_parser("serve")
    serve.add_argument("--home", required=True)
    serve.add_argument("--root", required=True)
    serve.add_argument("--port", type=int, default=DEFAULT_PORT)
    serve.add_argument("--host", default="")
    initp = sub.add_parser("init-passcode")
    initp.add_argument("--home", required=True)
    revoke = sub.add_parser("revoke-sessions")
    revoke.add_argument("--home", required=True)
    plist = sub.add_parser("render-plist")
    plist.add_argument("--home", required=True)
    plist.add_argument("--root", required=True)
    sub.add_parser("mailbox-listener")
    sub.add_parser("check-funnel")
    args = parser.parse_args(argv)
    if args.command == "serve":
        command_serve(Path(args.home), Path(args.root), args.port, args.host or load_host_config(Path(args.home)))
    elif args.command == "init-passcode":
        command_init_passcode(Path(args.home))
    elif args.command == "revoke-sessions":
        command_revoke(Path(args.home))
    elif args.command == "render-plist":
        command_render_plist(Path(args.home), Path(args.root))
    elif args.command == "mailbox-listener":
        command_mailbox()
    elif args.command == "check-funnel":
        command_funnel()


if __name__ == "__main__":
    main()
