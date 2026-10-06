#!/usr/bin/env python3
"""Firstmate web: the primary first mate's conversation in a localhost page.

The bind address is the literal LOOPBACK constant. There is no flag or
environment variable that widens it, and nothing here publishes it on a
tailnet.

Every request must carry the home's token: once as ?token= on the first
visit, which sets an HttpOnly SameSite=Strict cookie and redirects to a clean
URL, and as that cookie afterwards. The Host header must name this loopback
port on 127.0.0.1, so a rebound DNS name cannot reach the page.
Every POST also needs the page's CSRF header and, when the browser sends one,
a same-origin Origin. The token lives in state/web/token (0600 in a 0700
directory); docs/web.md owns the security model.

The conversation is read, never written: the session id is the one the live
lock holder's Claude process records in <claude-config>/sessions/<pid>.json,
which Claude Code rewrites when /clear starts a new session, else
state/.lock-session (bin/fm-lock.sh is its only writer, and it is not re-keyed
on /clear). The transcript is <claude-config>/projects/*/<id>.jsonl,
re-resolved on every read so a restarted, cleared or compacted session is
followed. Only the tail is parsed.

Sending never types anywhere itself. Every message, with any pasted images
saved into state/desk-voice/shots/, goes through
`bin/fm-desk-voice.sh send --source web`, which types into the primary's own
chat only when that is safe and otherwise uses the durable mailbox.

The fleet panel reuses bin/fm-bridge-view.py's read-only snapshot and
projection. This process never takes the session lock, never drains wakes,
and never writes backlog or fleet state.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import datetime
import hashlib
import hmac
import html
import importlib.util
import json
import os
import re
import secrets
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple
from urllib.parse import parse_qs, urlparse

LOOPBACK = "127.0.0.1"
DEFAULT_PORT = 8767
COOKIE_PREFIX = "fm_web_"
CSRF_HEADER = "X-FM-CSRF"
TAIL_ITEMS = 160
TAIL_FIRST_WINDOW = 2 * 1024 * 1024
TAIL_MAX_WINDOW = 64 * 1024 * 1024
TOOL_DETAIL_MAX = 6000
SUMMARY_MAX = 140
SEND_BODY_MAX = 24 * 1024 * 1024
SEND_IMAGES_MAX = 8
SEND_TEXT_MAX = 20000
SEND_TIMEOUT_SECONDS = 90
SESSION_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]{7,80}$")
IMAGE_MAGIC = (
    (b"\x89PNG\r\n\x1a\n", "png"),
    (b"\xff\xd8\xff", "jpg"),
    (b"GIF87a", "gif"),
    (b"GIF89a", "gif"),
)
TOOL_SUMMARY_KEYS = (
    "description",
    "file_path",
    "path",
    "pattern",
    "url",
    "query",
    "skill",
    "command",
    "prompt",
)
EVENT_TAG_RE = re.compile(r"^\s*<([A-Za-z][A-Za-z0-9_-]*)")
SUMMARY_TAG_RE = re.compile(r"<summary>(.*?)</summary>", re.S)
COMMAND_NAME_RE = re.compile(r"<command-name>(.*?)</command-name>", re.S)
COMMAND_ARGS_RE = re.compile(r"<command-args>(.*?)</command-args>", re.S)
SKIPPED_TAGS = {"local-command-stdout", "local-command-stderr", "local-command-caveat"}
BASH_MODE_TAGS = {"bash-input", "bash-stdout", "bash-stderr"}
INTERRUPT_RE = re.compile(r"^\[Request interrupted by user")


def fail(message: str, code: int = 1) -> None:
    print(f"fm-web: {message}", file=sys.stderr)
    sys.exit(code)


# --- token -----------------------------------------------------------------


def web_dir(home: Path) -> Path:
    return home / "state" / "web"


def ensure_web_dir(home: Path) -> Path:
    path = web_dir(home)
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path, 0o700)
    return path


def load_or_create_token(home: Path) -> str:
    """The home's random token, created once with owner-only permissions."""
    path = ensure_web_dir(home) / "token"
    try:
        token = path.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        token = ""
    if re.fullmatch(r"[A-Za-z0-9_-]{32,}", token or ""):
        os.chmod(path, 0o600)
        return token
    token = secrets.token_urlsafe(32)
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(token + "\n")
    os.chmod(path, 0o600)
    return token


def derive(token: str, purpose: str) -> str:
    return hmac.new(token.encode(), purpose.encode(), hashlib.sha256).hexdigest()


# --- transcript resolution -------------------------------------------------


def claude_config_dirs(home: Path) -> List[Path]:
    """Where a Claude primary's transcripts can live, most specific first.

    CLAUDE_CONFIG_DIR, this home's pinned accounts under data/accounts/claude/,
    then ~/.claude.
    """
    dirs: List[Path] = []
    env_dir = os.environ.get("CLAUDE_CONFIG_DIR")
    if env_dir:
        dirs.append(Path(env_dir))
    accounts = home / "data" / "accounts" / "claude"
    if accounts.is_dir():
        dirs.extend(sorted(p for p in accounts.iterdir() if p.is_dir()))
    user_home = os.environ.get("HOME")
    if user_home:
        dirs.append(Path(user_home) / ".claude")
    return dirs


def lock_session_id(home: Path) -> Optional[str]:
    path = home / "state" / ".lock-session"
    if path.is_symlink() or not path.is_file():
        return None
    try:
        first = path.read_text(encoding="utf-8").splitlines()[0].strip()
    except (OSError, IndexError, UnicodeDecodeError):
        return None
    return first if SESSION_ID_RE.match(first) else None


def lock_pid(home: Path) -> Optional[int]:
    try:
        first = (home / "state" / ".lock").read_text(encoding="utf-8").splitlines()[0].strip()
    except (OSError, IndexError, UnicodeDecodeError):
        return None
    return int(first) if first.isdigit() else None


def lock_pid_alive(home: Path) -> Optional[bool]:
    """True or False for the lock's recorded pid, None when there is no lock."""
    pid = lock_pid(home)
    if pid is None:
        return None
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def live_session_id(home: Path) -> Optional[str]:
    """The session id the live lock holder's Claude process records now.

    The lock's pid is the Claude model-loop process, and Claude Code keeps
    <claude-config>/sessions/<pid>.json naming its current session, rewritten
    when /clear starts a new one. A dead holder's leftover file is ignored.
    """
    pid = lock_pid(home)
    if pid is None or not lock_pid_alive(home):
        return None
    for base in claude_config_dirs(home):
        try:
            record = json.loads((base / "sessions" / f"{pid}.json").read_text(encoding="utf-8"))
        except (OSError, ValueError, UnicodeDecodeError):
            continue
        if not isinstance(record, dict) or record.get("pid") != pid:
            continue
        session = record.get("sessionId")
        if isinstance(session, str) and SESSION_ID_RE.match(session):
            return session
    return None


def find_transcript(home: Path, session: str) -> Optional[Path]:
    best: Optional[Path] = None
    best_mtime = -1.0
    for base in claude_config_dirs(home):
        projects = base / "projects"
        if not projects.is_dir():
            continue
        for candidate in projects.glob(f"*/{session}.jsonl"):
            try:
                mtime = candidate.stat().st_mtime
            except OSError:
                continue
            if mtime > best_mtime:
                best, best_mtime = candidate, mtime
    return best


def resolve_transcript(home: Path) -> Tuple[Optional[str], Optional[Path]]:
    """The live session first, then the lock sidecar's.

    A just-cleared session has no transcript until its first message, so the
    sidecar's conversation stays on the page until then.
    """
    sessions = [s for s in (live_session_id(home), lock_session_id(home)) if s]
    for session in sessions:
        path = find_transcript(home, session)
        if path is not None:
            return session, path
    return (sessions[0] if sessions else None), None


# --- markdown ----------------------------------------------------------------

INLINE_TOKEN_RE = re.compile(
    r"(`[^`\n]+`)"
    r"|(\[[^\]\n]+\]\((?:https?://)[^\s<>()\"']+\))"
    r"|(https?://[^\s<>\"'`]+)"
)
BOLD_RE = re.compile(r"\*\*(?=\S)(.+?)(?<=\S)\*\*")
ITALIC_RE = re.compile(r"(?<![*\w])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![*\w])")
STRIKE_RE = re.compile(r"~~(?=\S)(.+?)(?<=\S)~~")
LINK_PARTS_RE = re.compile(r"^\[([^\]]+)\]\(([^)]+)\)$")
TRAILING_PUNCT = ".,;:!?)"


def _anchor(url: str, label_html: str) -> str:
    return (
        f'<a href="{html.escape(url, quote=True)}" target="_blank" '
        f'rel="noopener noreferrer">{label_html}</a>'
    )


def _emphasis(escaped: str) -> str:
    escaped = BOLD_RE.sub(r"<strong>\1</strong>", escaped)
    escaped = ITALIC_RE.sub(r"<em>\1</em>", escaped)
    return STRIKE_RE.sub(r"<del>\1</del>", escaped)


def render_inline(text: str) -> str:
    """Escape everything, then add code, links and emphasis.

    Only http and https links become anchors; every other byte reaches the
    page escaped, so no input can open a tag or an attribute.
    """
    out: List[str] = []
    pos = 0
    for match in INLINE_TOKEN_RE.finditer(text):
        out.append(_emphasis(html.escape(text[pos:match.start()], quote=True)))
        code, link, bare = match.groups()
        if code:
            out.append(f"<code>{html.escape(code[1:-1], quote=True)}</code>")
        elif link:
            parts = LINK_PARTS_RE.match(link)
            label, url = (parts.group(1), parts.group(2)) if parts else (link, "")
            out.append(_anchor(url, _emphasis(html.escape(label, quote=True))))
        else:
            url = bare
            tail = ""
            while url and url[-1] in TRAILING_PUNCT:
                tail = url[-1] + tail
                url = url[:-1]
            out.append(_anchor(url, html.escape(url, quote=True)) + html.escape(tail, quote=True))
        pos = match.end()
    out.append(_emphasis(html.escape(text[pos:], quote=True)))
    return "".join(out)


FENCE_RE = re.compile(r"^\s*(```|~~~)")
HEADING_RE = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
BULLET_RE = re.compile(r"^(\s*)[-*+]\s+(.*)$")
ORDERED_RE = re.compile(r"^(\s*)(\d+)[.)]\s+(.*)$")
RULE_RE = re.compile(r"^\s*(?:-{3,}|\*{3,}|_{3,})\s*$")
TABLE_SEP_RE = re.compile(r"^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$")


def _table_cells(line: str) -> List[str]:
    line = line.strip()
    if line.startswith("|"):
        line = line[1:]
    if line.endswith("|"):
        line = line[:-1]
    return [cell.strip() for cell in line.split("|")]


def _render_list(block: List[Tuple[int, str, str, int]]) -> str:
    """Nested lists from (indent, ul|ol, text, number) rows; deeper indents
    nest inside the previous item, so bullets under a numbered step stay
    bullets. A numbered list starts at its first item's number."""
    out: List[str] = []
    stack: List[Tuple[int, str]] = []
    for indent, tag, body_text, number in block:
        while stack and indent < stack[-1][0]:
            out.append(f"</li></{stack.pop()[1]}>")
        if stack and indent == stack[-1][0] and tag != stack[-1][1]:
            out.append(f"</li></{stack.pop()[1]}>")
        if not stack or indent > stack[-1][0]:
            if len(stack) >= 4 and stack:
                indent = stack[-1][0]
                out.append("</li>")
            else:
                out.append(f'<ol start="{number}">' if tag == "ol" and number != 1 else f"<{tag}>")
                stack.append((indent, tag))
        else:
            out.append("</li>")
        out.append("<li>" + "<br>".join(render_inline(part) for part in body_text.split("\n")))
    while stack:
        out.append(f"</li></{stack.pop()[1]}>")
    return "".join(out)


def render_markdown(text: str) -> str:
    """A small, safe Markdown subset: paragraphs, headings, lists, quotes,
    rules, fenced code and pipe tables. All text is escaped first."""
    lines = text.replace("\x00", "").replace("\r\n", "\n").split("\n")
    out: List[str] = []
    para: List[str] = []
    i = 0

    def flush() -> None:
        if para:
            out.append("<p>" + "<br>".join(render_inline(item) for item in para) + "</p>")
            para.clear()

    while i < len(lines):
        line = lines[i]
        if FENCE_RE.match(line):
            flush()
            fence = FENCE_RE.match(line).group(1)
            body: List[str] = []
            i += 1
            while i < len(lines) and not lines[i].strip().startswith(fence):
                body.append(lines[i])
                i += 1
            i += 1
            out.append("<pre><code>" + html.escape("\n".join(body), quote=True) + "</code></pre>")
            continue
        if not line.strip():
            flush()
            i += 1
            continue
        heading = HEADING_RE.match(line)
        if heading:
            flush()
            level = min(6, len(heading.group(1)) + 2)
            out.append(f"<h{level}>{render_inline(heading.group(2))}</h{level}>")
            i += 1
            continue
        if RULE_RE.match(line):
            flush()
            out.append("<hr>")
            i += 1
            continue
        if "|" in line and i + 1 < len(lines) and TABLE_SEP_RE.match(lines[i + 1]):
            flush()
            head = _table_cells(line)
            rows: List[List[str]] = []
            i += 2
            while i < len(lines) and "|" in lines[i] and lines[i].strip():
                rows.append(_table_cells(lines[i]))
                i += 1
            parts = ["<div class=\"table\"><table><thead><tr>"]
            parts.extend(f"<th>{render_inline(cell)}</th>" for cell in head)
            parts.append("</tr></thead><tbody>")
            for row in rows:
                parts.append("<tr>" + "".join(f"<td>{render_inline(cell)}</td>" for cell in row) + "</tr>")
            parts.append("</tbody></table></div>")
            out.append("".join(parts))
            continue
        if line.lstrip().startswith(">"):
            flush()
            quote: List[str] = []
            while i < len(lines) and lines[i].lstrip().startswith(">"):
                quote.append(lines[i].lstrip()[1:].lstrip())
                i += 1
            out.append("<blockquote>" + render_markdown("\n".join(quote)) + "</blockquote>")
            continue
        if BULLET_RE.match(line) or ORDERED_RE.match(line):
            flush()
            block: List[Tuple[int, str, str, int]] = []
            while i < len(lines):
                bullet = BULLET_RE.match(lines[i])
                number = ORDERED_RE.match(lines[i])
                if bullet:
                    block.append((len(bullet.group(1)), "ul", bullet.group(2), 0))
                elif number:
                    block.append((len(number.group(1)), "ol", number.group(3), int(number.group(2))))
                elif lines[i].strip() and lines[i].startswith("  ") and block:
                    indent, tag, body_text, start = block[-1]
                    block[-1] = (indent, tag, body_text + "\n" + lines[i].strip(), start)
                else:
                    break
                i += 1
            out.append(_render_list(block))
            continue
        para.append(line)
        i += 1
    flush()
    return "".join(out)


# --- transcript parsing ------------------------------------------------------


def _clip(text: str, limit: int) -> str:
    text = text.strip()
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


def _one_line(text: str, limit: int = SUMMARY_MAX) -> str:
    return _clip(" ".join(text.split()), limit)


def _block_text(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, dict):
                if block.get("type") == "text":
                    parts.append(str(block.get("text") or ""))
                elif block.get("type") == "image":
                    parts.append("[image]")
            elif isinstance(block, str):
                parts.append(block)
        return "\n".join(parts)
    return ""


def tool_summary(name: str, tool_input: Any) -> str:
    if isinstance(tool_input, dict):
        for key in TOOL_SUMMARY_KEYS:
            value = tool_input.get(key)
            if isinstance(value, str) and value.strip():
                return _one_line(value)
        for value in tool_input.values():
            if isinstance(value, str) and value.strip():
                return _one_line(value)
    return ""


def _user_item(uid: str, ts: str, text: str, images: int = 0) -> Dict[str, Any]:
    return {
        "id": uid,
        "kind": "user",
        "ts": ts,
        "html": render_markdown(text) if text.strip() else "",
        "images": images,
    }


def _event_item(uid: str, ts: str, label: str, detail: str) -> Dict[str, Any]:
    return {
        "id": uid,
        "kind": "event",
        "ts": ts,
        "summary": _one_line(label),
        "detail": _clip(detail, TOOL_DETAIL_MAX),
    }


def _classify_user_string(uid: str, ts: str, text: str, origin_kind: str) -> Optional[Dict[str, Any]]:
    command = COMMAND_NAME_RE.search(text[:2000])
    if command:
        args = COMMAND_ARGS_RE.search(text)
        line = command.group(1).strip()
        if args and args.group(1).strip():
            line += " " + args.group(1).strip()
        return _user_item(uid, ts, line)
    if origin_kind == "human":
        return _user_item(uid, ts, text)
    tag = EVENT_TAG_RE.match(text)
    if tag:
        if tag.group(1) in SKIPPED_TAGS:
            return None
        summary = SUMMARY_TAG_RE.search(text)
        label = summary.group(1) if summary else tag.group(1).replace("-", " ")
        return _event_item(uid, ts, label, text)
    if origin_kind and origin_kind != "human":
        return _event_item(uid, ts, origin_kind.replace("-", " "), text)
    return _user_item(uid, ts, text)


def _starts_turn(text: str) -> bool:
    tag = EVENT_TAG_RE.match(text)
    return not (tag and tag.group(1) in BASH_MODE_TAGS)


class Conversation:
    """Folds transcript entries into display items, oldest first."""

    def __init__(self) -> None:
        self.items: List[Dict[str, Any]] = []
        self.tools: Dict[str, Dict[str, Any]] = {}
        self.busy = False
        self.last_assistant_msg: Optional[str] = None
        self.pending_compact: Optional[Dict[str, Any]] = None

    def add(self, entry: Dict[str, Any]) -> None:
        if not isinstance(entry, dict) or entry.get("isSidechain"):
            return
        kind = entry.get("type")
        uid = str(entry.get("uuid") or f"x{len(self.items)}")
        ts = str(entry.get("timestamp") or "")
        if kind == "system":
            self._system(entry, uid, ts)
        elif kind == "user":
            self._user(entry, uid, ts)
        elif kind == "assistant":
            self._assistant(entry, uid, ts)
        elif kind == "attachment":
            attachment = entry.get("attachment") or {}
            if isinstance(attachment, dict) and attachment.get("type") == "queued_command":
                origin = attachment.get("origin") or {}
                if isinstance(origin, dict) and origin.get("kind") == "human":
                    prompt = attachment.get("prompt")
                    text = _block_text(prompt)
                    if text.strip():
                        self._push(_user_item(uid, ts, text))
                        self.busy = True

    def _push(self, item: Dict[str, Any]) -> None:
        self.items.append(item)
        if item["kind"] != "assistant":
            self.last_assistant_msg = None

    def _system(self, entry: Dict[str, Any], uid: str, ts: str) -> None:
        subtype = entry.get("subtype")
        if subtype in ("turn_duration", "local_command"):
            self.busy = False
        elif subtype == "compact_boundary":
            item = {"id": uid, "kind": "compact", "ts": ts, "summary": "Conversation compacted", "detail": ""}
            self._push(item)
            self.pending_compact = item

    def _user(self, entry: Dict[str, Any], uid: str, ts: str) -> None:
        message = entry.get("message") or {}
        content = message.get("content") if isinstance(message, dict) else None
        if entry.get("isCompactSummary") or entry.get("isVisibleInTranscriptOnly"):
            if self.pending_compact is not None:
                text = _block_text(content)
                joined = (self.pending_compact["detail"] + "\n\n" + text).strip()
                self.pending_compact["detail"] = _clip(joined, TOOL_DETAIL_MAX)
            return
        if entry.get("isMeta"):
            return
        origin = entry.get("origin") or {}
        origin_kind = str(origin.get("kind") or "") if isinstance(origin, dict) else ""
        if isinstance(content, str):
            item = _classify_user_string(uid, ts, content, origin_kind)
            if item is not None:
                self._push(item)
                self.busy = self.busy or _starts_turn(content)
            return
        if not isinstance(content, list):
            return
        texts: List[str] = []
        images = 0
        for block in content:
            if not isinstance(block, dict):
                continue
            btype = block.get("type")
            if btype == "tool_result":
                self._tool_result(block)
                self.busy = True
            elif btype == "text":
                texts.append(str(block.get("text") or ""))
            elif btype == "image":
                images += 1
        text = "\n".join(texts).strip()
        if text and INTERRUPT_RE.match(text):
            self._push(_event_item(uid, ts, "Interrupted", text))
            self.busy = False
            return
        if text or images:
            item = _classify_user_string(uid, ts, text, origin_kind)
            if item is None:
                return
            if item["kind"] == "user":
                item["images"] = images
            self._push(item)
            self.busy = self.busy or _starts_turn(text)

    def _tool_result(self, block: Dict[str, Any]) -> None:
        tool = self.tools.get(str(block.get("tool_use_id") or ""))
        if tool is None:
            return
        tool["pending"] = False
        tool["error"] = bool(block.get("is_error"))
        tool["result"] = _clip(_block_text(block.get("content")), TOOL_DETAIL_MAX)

    def _assistant(self, entry: Dict[str, Any], uid: str, ts: str) -> None:
        message = entry.get("message") or {}
        if not isinstance(message, dict):
            return
        self.busy = True
        content = message.get("content")
        if isinstance(content, str):
            content = [{"type": "text", "text": content}]
        if not isinstance(content, list):
            return
        msg_id = str(message.get("id") or uid)
        for index, block in enumerate(content):
            if not isinstance(block, dict):
                continue
            btype = block.get("type")
            if btype == "text":
                text = str(block.get("text") or "")
                if not text.strip():
                    continue
                last = self.items[-1] if self.items else None
                if last is not None and last["kind"] == "assistant" and self.last_assistant_msg == msg_id:
                    last["text"] += "\n\n" + text
                    last["html"] = render_markdown(last["text"])
                else:
                    self._push(
                        {
                            "id": f"{uid}:{index}",
                            "kind": "assistant",
                            "ts": ts,
                            "text": text,
                            "html": render_markdown(text),
                        }
                    )
                    self.last_assistant_msg = msg_id
            elif btype == "tool_use":
                name = str(block.get("name") or "tool")
                tool_input = block.get("input")
                try:
                    shown_input = json.dumps(tool_input, indent=2, ensure_ascii=False)
                except (TypeError, ValueError):
                    shown_input = str(tool_input)
                item = {
                    "id": str(block.get("id") or f"{uid}:{index}"),
                    "kind": "tool",
                    "ts": ts,
                    "name": name,
                    "summary": tool_summary(name, tool_input),
                    "input": _clip(shown_input, TOOL_DETAIL_MAX),
                    "result": "",
                    "pending": True,
                    "error": False,
                }
                self.tools[item["id"]] = item
                self._push(item)

    def public_items(self, limit: int) -> List[Dict[str, Any]]:
        shown = self.items[-limit:] if limit else list(self.items)
        return [{k: v for k, v in item.items() if k != "text"} for item in shown]


def parse_lines(lines: Iterable[str]) -> Conversation:
    conversation = Conversation()
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except (json.JSONDecodeError, ValueError):
            continue
        conversation.add(entry)
    return conversation


def read_tail(path: Path, want_items: int = TAIL_ITEMS) -> Tuple[Conversation, bool]:
    """Parse only the end of the transcript, widening until enough items show.

    Returns the conversation and whether older history exists before it.
    """
    size = path.stat().st_size
    window = TAIL_FIRST_WINDOW
    while True:
        start = max(0, size - window)
        with open(path, "rb") as handle:
            handle.seek(start)
            data = handle.read(size - start)
        lines = data.decode("utf-8", "replace").split("\n")
        if start > 0:
            lines = lines[1:]
        conversation = parse_lines(lines)
        if start == 0 or len(conversation.items) >= want_items or window >= TAIL_MAX_WINDOW:
            return conversation, start > 0
        window = min(window * 4, TAIL_MAX_WINDOW)


class TranscriptCache:
    def __init__(self, home: Path) -> None:
        self.home = home
        self.lock = threading.Lock()
        self.key: Optional[Tuple[str, int, int]] = None
        self.value: Optional[Dict[str, Any]] = None

    def get(self) -> Dict[str, Any]:
        session, path = resolve_transcript(self.home)
        alive = lock_pid_alive(self.home)
        if path is None:
            reason = (
                "No first mate session is recorded for this home yet."
                if session is None
                else "The first mate's conversation file was not found."
            )
            return {"session": session, "state": "offline", "items": [], "older": False, "note": reason, "version": f"none:{session}"}
        stat = path.stat()
        key = (str(path), stat.st_size, stat.st_mtime_ns)
        with self.lock:
            if key != self.key or self.value is None:
                conversation, older = read_tail(path)
                self.value = {
                    "items": conversation.public_items(TAIL_ITEMS),
                    "older": older,
                    "busy": conversation.busy,
                }
                self.key = key
            value = dict(self.value)
        busy = value.pop("busy")
        state = "offline" if alive is False else ("busy" if busy else "idle")
        value.update(
            {
                "session": session,
                "state": state,
                "note": "",
                "version": f"{session}:{stat.st_size}:{stat.st_mtime_ns}:{state}",
            }
        )
        return value


# --- fleet panel (reuses the bridge view's snapshot) -----------------------


def load_bridge_module(root: Path) -> Any:
    path = root / "bin" / "fm-bridge-view.py"
    spec = importlib.util.spec_from_file_location("fm_bridge_view", str(path))
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FleetCache:
    """The bridge view's glance (needs you, under way, just finished), read
    with its bounded, read-only snapshot child and cached for its TTL."""

    def __init__(self, home: Path, root: Path) -> None:
        self.home = home
        self.root = root
        self.lock = threading.Lock()
        self.refresh = threading.Lock()
        self.payload: Optional[Dict[str, Any]] = None
        self.fetched_at = 0.0
        self.bridge: Any = None

    def _load(self) -> Dict[str, Any]:
        if self.bridge is None:
            self.bridge = load_bridge_module(self.root)
        model = self.bridge.run_snapshot(self.home, self.root)
        observation = self.bridge.project_observation(model)
        return {
            "needs_you": observation.get("needs_you", {}),
            "under_way": observation.get("under_way", {}),
            "just_finished": observation.get("just_finished", {}),
            "generated": observation.get("generated"),
        }

    def get(self) -> Dict[str, Any]:
        ttl = getattr(self.bridge, "CACHE_TTL_SECONDS", 30)
        with self.refresh:
            with self.lock:
                if self.payload is not None and time.monotonic() - self.fetched_at < ttl:
                    return dict(self.payload)
            payload = self._load()
            with self.lock:
                self.payload = payload
                self.fetched_at = time.monotonic()
            return dict(payload)


# --- sending ---------------------------------------------------------------


def sniff_image(data: bytes) -> Optional[str]:
    for magic, ext in IMAGE_MAGIC:
        if data.startswith(magic):
            return ext
    if len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "webp"
    return None


def save_image(home: Path, data: bytes) -> Path:
    """Save one pasted image where the desk floater saves its screenshots."""
    ext = sniff_image(data)
    if ext is None:
        raise ValueError("only PNG, JPEG, GIF or WebP images can be attached")
    shots = home / "state" / "desk-voice" / "shots"
    shots.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(shots, 0o700)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    path = shots / f"{stamp}-{secrets.token_hex(4)}.{ext}"
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(data)
    return path


def desk_voice_send(home: Path, root: Path, text: str, images: List[Path]) -> Dict[str, str]:
    """Hand the message to bin/fm-desk-voice.sh send, the only path in."""
    script = root / "bin" / "fm-desk-voice.sh"
    argv = [str(script), "send", "--source", "web"]
    for image in images:
        argv.extend(["--image", str(image)])
    argv.append("--")
    if text:
        argv.append(text)
    env = dict(os.environ)
    env["FM_HOME"] = str(home)
    env["FM_ROOT_OVERRIDE"] = str(root)
    proc = subprocess.run(
        argv,
        env=env,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=SEND_TIMEOUT_SECONDS,
    )
    line = (proc.stdout or "").strip().splitlines()[-1:] or [""]
    outcome = line[0]
    if proc.returncode != 0 or not outcome:
        detail = (proc.stderr or "").strip().splitlines()[-1:] or ["the message could not be delivered"]
        return {"outcome": "failed", "detail": detail[0].removeprefix("fm-desk-voice: ")}
    if outcome.startswith("sent-unconfirmed:"):
        return {"outcome": "typed-unconfirmed", "detail": "Typed into the first mate's chat; the send was not confirmed."}
    if outcome.startswith("sent:"):
        return {"outcome": "typed", "detail": "Typed into the first mate's chat."}
    if outcome.startswith("mailbox:"):
        return {"outcome": "mailbox", "detail": "The chat was busy, so it went to the first mate's mailbox."}
    return {"outcome": "failed", "detail": outcome}


def decode_send_body(body: bytes) -> Tuple[str, List[bytes]]:
    try:
        payload = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError("the request was not JSON") from exc
    if not isinstance(payload, dict):
        raise ValueError("the request was not an object")
    text = payload.get("text") or ""
    if not isinstance(text, str):
        raise ValueError("text must be a string")
    if len(text) > SEND_TEXT_MAX:
        raise ValueError("the message is too long")
    raw_images = payload.get("images") or []
    if not isinstance(raw_images, list) or len(raw_images) > SEND_IMAGES_MAX:
        raise ValueError(f"attach at most {SEND_IMAGES_MAX} images")
    images: List[bytes] = []
    for item in raw_images:
        if not isinstance(item, str):
            raise ValueError("images must be data URLs")
        data = item.split(",", 1)[1] if item.startswith("data:") and "," in item else item
        try:
            images.append(base64.b64decode(data, validate=True))
        except (ValueError, binascii.Error) as exc:
            raise ValueError("an image could not be read") from exc
    if not text.strip() and not images:
        raise ValueError("nothing to send")
    return text.strip(), images


# --- HTTP ------------------------------------------------------------------


def csp(nonce: str) -> str:
    return (
        "default-src 'none'; "
        f"style-src 'nonce-{nonce}'; "
        f"script-src 'nonce-{nonce}'; "
        "img-src 'self' data: blob:; "
        "connect-src 'self'; "
        "form-action 'none'; "
        "base-uri 'none'; "
        "frame-ancestors 'none'"
    )


class WebState:
    def __init__(self, home: Path, root: Path, port: int, token: str) -> None:
        self.home = home
        self.root = root
        self.token = token
        self.host = f"{LOOPBACK}:{port}"
        self.cookie_name = f"{COOKIE_PREFIX}{port}"
        self.cookie_value = derive(token, "cookie")
        self.csrf = derive(token, "csrf")
        self.transcript = TranscriptCache(home)
        self.fleet = FleetCache(home, root)
        self.send_lock = threading.Lock()


STATE: Optional[WebState] = None


class WebHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "fm-web"
    sys_version = ""

    def log_request(self, code: Any = "-", size: Any = "-") -> None:
        if self.command == "GET" and self.path.startswith("/api/") and isinstance(code, int) and 200 <= code < 300:
            return
        super().log_request(code, size)

    def log_message(self, fmt: str, *args: Any) -> None:
        if STATE is None:
            return
        try:
            with open(web_dir(STATE.home) / "web.log", "a", encoding="utf-8") as handle:
                # The query string can carry the token, so only the path is logged.
                handle.write("%s - %s\n" % (self.log_date_time_string(), (fmt % args).split("?", 1)[0]))
        except OSError:
            pass

    # guards

    def _host_ok(self) -> bool:
        return (self.headers.get("Host") or "").strip().lower() == STATE.host

    def _cookie_ok(self) -> bool:
        raw = self.headers.get("Cookie") or ""
        for part in raw.split(";"):
            name, _, value = part.strip().partition("=")
            if name == STATE.cookie_name and hmac.compare_digest(value.strip(), STATE.cookie_value):
                return True
        return False

    def _post_ok(self) -> bool:
        if not self._cookie_ok():
            return False
        csrf = self.headers.get(CSRF_HEADER) or ""
        if not hmac.compare_digest(csrf, STATE.csrf):
            return False
        origin = (self.headers.get("Origin") or "").strip().rstrip("/").lower()
        if origin and origin != f"http://{STATE.host}":
            return False
        site = (self.headers.get("Sec-Fetch-Site") or "").strip().lower()
        return site in {"", "same-origin", "none"}

    # responses

    def _send(self, status: int, body: bytes, content_type: str, headers: Optional[List[Tuple[str, str]]] = None) -> None:
        nonce = getattr(self, "_nonce", "") or secrets.token_urlsafe(16)
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Security-Policy", csp(nonce))
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        for name, value in headers or []:
            self.send_header(name, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, status: int, payload: Dict[str, Any], headers: Optional[List[Tuple[str, str]]] = None) -> None:
        self._send(status, json.dumps(payload).encode("utf-8"), "application/json; charset=utf-8", headers)

    def _text(self, status: int, message: str, close: bool = False) -> None:
        headers = [("Connection", "close")] if close else None
        if close:
            self.close_connection = True
        self._send(status, (message + "\n").encode("utf-8"), "text/plain; charset=utf-8", headers)

    # methods

    def do_GET(self) -> None:  # noqa: N802
        if not self._host_ok():
            self._text(403, "forbidden host")
            return
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        if parsed.path == "/" and "token" in query:
            supplied = query["token"][0]
            if hmac.compare_digest(supplied, STATE.token):
                cookie = (
                    f"{STATE.cookie_name}={STATE.cookie_value}; Path=/; HttpOnly; "
                    "SameSite=Strict; Max-Age=31536000"
                )
                self._send(303, b"", "text/plain", [("Location", "/"), ("Set-Cookie", cookie)])
            else:
                self._text(403, "wrong token; run bin/fm-web.sh url for the current link")
            return
        if not self._cookie_ok():
            self._text(403, "open the link from bin/fm-web.sh url to sign in")
            return
        if parsed.path == "/":
            self._nonce = secrets.token_urlsafe(16)
            self._send(200, page_html(self._nonce, STATE.csrf).encode("utf-8"), "text/html; charset=utf-8")
        elif parsed.path == "/api/conversation":
            try:
                payload = STATE.transcript.get()
            except OSError as exc:
                payload = {"state": "offline", "items": [], "note": f"cannot read the conversation: {exc}", "version": "error"}
            since = query.get("since", [""])[0]
            if since and since == payload.get("version"):
                self._json(200, {"version": since, "unchanged": True, "state": payload.get("state")})
            else:
                self._json(200, payload)
        elif parsed.path == "/api/fleet":
            try:
                self._json(200, STATE.fleet.get())
            except Exception as exc:  # the panel says why instead of breaking the page
                self._json(503, {"error": str(exc) or "fleet snapshot failed"})
        else:
            self._text(404, "not found")

    def do_HEAD(self) -> None:  # noqa: N802
        self.do_GET()

    def do_POST(self) -> None:  # noqa: N802
        raw_length = (self.headers.get("Content-Length") or "").strip()
        length = int(raw_length) if raw_length.isdigit() else -1
        if not self._host_ok():
            self._text(403, "forbidden host", close=True)
            return
        if not self._post_ok():
            self._text(403, "forbidden", close=True)
            return
        if urlparse(self.path).path != "/api/send":
            self._text(404, "not found", close=True)
            return
        if length < 0 or length > SEND_BODY_MAX:
            self._text(413, "too large", close=True)
            return
        body = self.rfile.read(length)
        try:
            text, blobs = decode_send_body(body)
            images = [save_image(STATE.home, blob) for blob in blobs]
        except ValueError as exc:
            self._json(400, {"outcome": "failed", "detail": str(exc)})
            return
        with STATE.send_lock:
            try:
                result = desk_voice_send(STATE.home, STATE.root, text, images)
            except (OSError, subprocess.SubprocessError) as exc:
                result = {"outcome": "failed", "detail": str(exc)}
        self._json(200 if result["outcome"] != "failed" else 502, result)


# --- page --------------------------------------------------------------------

PAGE_CSS = """
:root{--bg:#f7f7f5;--panel:#ffffff;--ink:#1d1d1f;--muted:#6e6e73;--line:#e3e3e0;
--me:#2f6fde;--me-ink:#ffffff;--them:#ffffff;--code:#f0f0ed;--accent:#2f6fde;--warn:#b25000;
--ok:#1f8a4c;--shadow:0 1px 2px rgba(0,0,0,.06);}
@media (prefers-color-scheme: dark){:root{--bg:#141416;--panel:#1c1c1f;--ink:#ececee;--muted:#9a9aa0;
--line:#2c2c30;--me:#3b74d9;--me-ink:#ffffff;--them:#202024;--code:#26262b;--accent:#7aa7ff;--warn:#ffb168;
--ok:#5fcf8a;--shadow:none;}}
*{box-sizing:border-box}
html,body{height:100%;margin:0}
body{background:var(--bg);color:var(--ink);font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Inter,
Roboto,"Helvetica Neue",Arial,sans-serif;display:flex;flex-direction:column}
header{display:flex;align-items:center;gap:12px;padding:10px 16px;border-bottom:1px solid var(--line);
background:var(--panel)}
header h1{font-size:15px;font-weight:600;margin:0;flex:1}
.state{display:inline-flex;align-items:center;gap:6px;font-size:13px;color:var(--muted)}
.dot{width:8px;height:8px;border-radius:50%;background:var(--muted)}
.state.busy .dot{background:var(--accent);animation:pulse 1.2s ease-in-out infinite}
.state.idle .dot{background:var(--ok)}
.state.offline .dot{background:var(--warn)}
@keyframes pulse{50%{opacity:.3}}
button.ghost{background:none;border:1px solid var(--line);color:var(--ink);border-radius:8px;padding:4px 10px;
font:inherit;font-size:13px;cursor:pointer}
main{flex:1;display:flex;min-height:0}
#chat{flex:1;display:flex;flex-direction:column;min-width:0}
#log{flex:1;overflow-y:auto;padding:20px 16px 8px}
.wrap{max-width:780px;margin:0 auto}
.msg{display:flex;margin:10px 0}
.msg.user{justify-content:flex-end}
.bubble{max-width:85%;padding:9px 14px;border-radius:16px;background:var(--them);box-shadow:var(--shadow);
border:1px solid var(--line);overflow-wrap:anywhere}
.msg.user .bubble{background:var(--me);color:var(--me-ink);border-color:transparent}
.msg.user .bubble a{color:inherit}
.msg.assistant .bubble{max-width:100%;background:transparent;border:none;box-shadow:none;padding:2px 2px}
.bubble p{margin:.35em 0}.bubble p:first-child{margin-top:0}.bubble p:last-child{margin-bottom:0}
.bubble h3,.bubble h4,.bubble h5,.bubble h6{margin:.8em 0 .3em;font-size:1em}
.bubble h3{font-size:1.08em}
.bubble ul,.bubble ol{margin:.35em 0;padding-left:1.4em}
.bubble code{background:var(--code);padding:1px 5px;border-radius:5px;font:13px/1.4 ui-monospace,SFMono-Regular,
Menlo,monospace}
.msg.user .bubble code{background:rgba(255,255,255,.18)}
.bubble pre{background:var(--code);padding:10px 12px;border-radius:10px;overflow-x:auto}
.bubble pre code{background:none;padding:0}
.bubble blockquote{margin:.4em 0;padding-left:12px;border-left:3px solid var(--line);color:var(--muted)}
.bubble hr{border:none;border-top:1px solid var(--line);margin:.8em 0}
.table{overflow-x:auto}
.bubble table{border-collapse:collapse;margin:.4em 0;font-size:14px}
.bubble th,.bubble td{border:1px solid var(--line);padding:4px 8px;text-align:left;vertical-align:top}
.chip{display:inline-block;font-size:12px;opacity:.85;margin-top:4px}
details.quiet{margin:2px 0;font-size:13px;color:var(--muted)}
details.quiet summary{cursor:pointer;list-style:none;padding:2px 0;white-space:nowrap;overflow:hidden;
text-overflow:ellipsis}
details.quiet summary::-webkit-details-marker{display:none}
details.quiet summary::before{content:"\\25B8";display:inline-block;width:1em;transition:transform .15s}
details.quiet[open] summary::before{transform:rotate(90deg)}
details.quiet .name{color:var(--ink);font-weight:500}
details.quiet.err .name{color:var(--warn)}
details.quiet pre{white-space:pre-wrap;overflow-wrap:anywhere;background:var(--code);color:var(--ink);
padding:8px 10px;border-radius:8px;font:12px/1.45 ui-monospace,SFMono-Regular,Menlo,monospace;max-height:320px;
overflow:auto;margin:4px 0 8px}
.compact{display:flex;align-items:center;gap:10px;margin:16px 0}
.compact::before,.compact::after{content:"";flex:1;border-top:1px dashed var(--line)}
.compact details{font-size:12px;color:var(--muted);text-align:center}
.compact details pre{text-align:left;white-space:pre-wrap;max-height:320px;overflow:auto;background:var(--code);
padding:8px;border-radius:8px}
.note{color:var(--muted);text-align:center;font-size:13px;margin:12px 0}
#compose{border-top:1px solid var(--line);background:var(--panel);padding:10px 16px 12px}
#compose .wrap{display:flex;flex-direction:column;gap:6px}
#row{display:flex;gap:8px;align-items:flex-end}
#input{flex:1;resize:none;min-height:42px;max-height:200px;padding:10px 12px;border-radius:12px;
border:1px solid var(--line);background:var(--bg);color:var(--ink);font:inherit;outline:none}
#input:focus{border-color:var(--accent)}
#send{border:none;background:var(--accent);color:#fff;border-radius:12px;padding:0 16px;height:42px;font:inherit;
font-weight:600;cursor:pointer}
#send:disabled{opacity:.5;cursor:default}
#thumbs{display:flex;gap:6px;flex-wrap:wrap}
#thumbs:empty{display:none}
.thumb{position:relative}
.thumb img{height:56px;border-radius:8px;border:1px solid var(--line)}
.thumb button{position:absolute;top:-6px;right:-6px;border:none;border-radius:50%;width:20px;height:20px;
background:var(--ink);color:var(--bg);cursor:pointer;font-size:12px;line-height:20px;padding:0}
#result{font-size:12px;color:var(--muted);min-height:1em}
#result.failed{color:var(--warn)}
body.drag #log{outline:2px dashed var(--accent);outline-offset:-8px}
aside{width:300px;border-left:1px solid var(--line);background:var(--panel);overflow-y:auto;padding:14px 16px}
aside h2{font-size:12px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);margin:16px 0 6px}
aside h2:first-child{margin-top:0}
aside ul{list-style:none;margin:0;padding:0}
aside li{padding:5px 0;border-bottom:1px solid var(--line);font-size:14px}
aside li:last-child{border-bottom:none}
aside li a{color:var(--accent);text-decoration:none}
aside .empty,aside .more{color:var(--muted);font-size:13px}
body.nofleet aside{display:none}
@media (max-width:860px){aside{position:fixed;top:49px;right:0;bottom:0;width:min(320px,90vw);
box-shadow:-4px 0 16px rgba(0,0,0,.15);display:none}body.fleet-open aside{display:block}
body.nofleet aside{display:none}}
@media (min-width:861px){#fleet-toggle{display:none}}
"""

PAGE_JS = """
(function(){
'use strict';
const CSRF = document.body.dataset.csrf;
const log = document.getElementById('log');
const wrap = document.getElementById('items');
const input = document.getElementById('input');
const sendBtn = document.getElementById('send');
const thumbs = document.getElementById('thumbs');
const result = document.getElementById('result');
const stateEl = document.getElementById('state');
let version = '';
let images = [];
let sending = false;

function el(tag, cls, text){const e=document.createElement(tag);if(cls)e.className=cls;
  if(text!==undefined)e.textContent=text;return e;}
function atBottom(){return log.scrollHeight-log.scrollTop-log.clientHeight<80;}

function quiet(item, label, name){
  const d=el('details','quiet'+(item.error?' err':''));d.dataset.id=item.id;
  const s=el('summary');
  const n=el('span','name',name);s.appendChild(n);
  if(label){s.appendChild(document.createTextNode(' \\u00b7 '+label));}
  d.appendChild(s);
  return d;
}

function render(items){
  const open=new Set(Array.from(wrap.querySelectorAll('details[open]')).map(d=>d.dataset.id));
  const stick=atBottom();
  const frag=document.createDocumentFragment();
  for(const item of items){
    if(item.kind==='user'||item.kind==='assistant'){
      const row=el('div','msg '+item.kind);const b=el('div','bubble');
      b.innerHTML=item.html||'';
      if(item.images){b.appendChild(el('div','chip',item.images===1?'1 image':item.images+' images'));}
      row.appendChild(b);frag.appendChild(row);
    }else if(item.kind==='tool'){
      const label=item.pending?(item.summary?item.summary+' \\u2026':'running\\u2026'):item.summary;
      const d=quiet(item,label,item.name);
      if(item.input){d.appendChild(el('pre','',item.input));}
      if(item.result){d.appendChild(el('pre','',item.result));}
      if(open.has(item.id))d.open=true;frag.appendChild(d);
    }else if(item.kind==='event'){
      const d=quiet(item,item.summary,'Note');
      if(item.detail){d.appendChild(el('pre','',item.detail));}
      if(open.has(item.id))d.open=true;frag.appendChild(d);
    }else if(item.kind==='compact'){
      const row=el('div','compact');const d=el('details');d.dataset.id=item.id;
      d.appendChild(el('summary','',item.summary));
      if(item.detail){d.appendChild(el('pre','',item.detail));}
      if(open.has(item.id))d.open=true;row.appendChild(d);frag.appendChild(row);
    }
  }
  wrap.replaceChildren(frag);
  if(stick)log.scrollTop=log.scrollHeight;
}

function setState(state){
  stateEl.className='state '+state;
  stateEl.querySelector('.label').textContent=
    state==='busy'?'Working':state==='idle'?'Ready':'Not running';
}

async function poll(){
  try{
    const r=await fetch('/api/conversation?since='+encodeURIComponent(version),{credentials:'same-origin'});
    if(r.ok){
      const data=await r.json();
      setState(data.state||'offline');
      if(!data.unchanged){
        version=data.version||'';
        const items=data.items||[];
        render(items);
        document.getElementById('note').textContent=data.note||'';
        document.getElementById('older').hidden=!data.older;
      }
    }
  }catch(e){setState('offline');}
  setTimeout(poll, document.hidden?6000:1500);
}

function li(text, url){const l=el('li');if(url){const a=el('a','',text);a.href=url;a.target='_blank';
  a.rel='noopener noreferrer';l.appendChild(a);}else{l.textContent=text;}return l;}
function bucket(id, data){
  const ul=document.getElementById(id);ul.replaceChildren();
  const items=(data&&data.items)||[];
  if(!items.length){ul.appendChild(el('li','empty','Nothing here'));}
  for(const item of items){ul.appendChild(li(item.title,item.url));}
  if(data&&data.more){ul.appendChild(el('li','more','and '+data.more+' more'));}
}
async function fleet(){
  try{
    const r=await fetch('/api/fleet',{credentials:'same-origin'});
    const data=await r.json();
    if(r.ok){bucket('needs',data.needs_you);bucket('underway',data.under_way);bucket('done',data.just_finished);
      document.getElementById('fleet-error').textContent='';}
    else{document.getElementById('fleet-error').textContent=data.error||'Fleet unavailable';}
  }catch(e){document.getElementById('fleet-error').textContent='Fleet unavailable';}
  setTimeout(fleet, 30000);
}

function addImage(file){
  if(!file||!/^image\\/(png|jpeg|gif|webp)$/.test(file.type))return;
  const reader=new FileReader();
  reader.onload=()=>{images.push(reader.result);drawThumbs();};
  reader.readAsDataURL(file);
}
function drawThumbs(){
  thumbs.replaceChildren();
  images.forEach((src,i)=>{const t=el('div','thumb');const img=el('img');img.src=src;img.alt='attached image';
    const x=el('button','','\\u00d7');x.title='Remove';x.addEventListener('click',()=>{images.splice(i,1);drawThumbs();});
    t.appendChild(img);t.appendChild(x);thumbs.appendChild(t);});
}

async function send(){
  const text=input.value.trim();
  if(sending||(!text&&!images.length))return;
  sending=true;sendBtn.disabled=true;result.className='';result.textContent='Sending\\u2026';
  try{
    const r=await fetch('/api/send',{method:'POST',credentials:'same-origin',
      headers:{'Content-Type':'application/json','X-FM-CSRF':CSRF},body:JSON.stringify({text:text,images:images})});
    let data={};try{data=await r.json();}catch(e){}
    if(r.ok){input.value='';images=[];drawThumbs();autosize();
      result.textContent=data.detail||'Sent.';}
    else{result.className='failed';result.textContent=data.detail||('Not sent ('+r.status+')');}
  }catch(e){result.className='failed';result.textContent='Not sent: the page lost its connection.';}
  sending=false;sendBtn.disabled=false;input.focus();
}

function autosize(){input.style.height='auto';input.style.height=Math.min(200,input.scrollHeight)+'px';}
input.addEventListener('input',autosize);
input.addEventListener('keydown',e=>{if(e.key==='Enter'&&!e.shiftKey&&!e.isComposing){e.preventDefault();send();}});
sendBtn.addEventListener('click',send);
input.addEventListener('paste',e=>{for(const item of (e.clipboardData||{}).items||[]){
  if(item.kind==='file'){const f=item.getAsFile();if(f&&f.type.startsWith('image/')){e.preventDefault();addImage(f);}}}});
document.addEventListener('dragover',e=>{e.preventDefault();document.body.classList.add('drag');});
document.addEventListener('dragleave',e=>{if(!e.relatedTarget)document.body.classList.remove('drag');});
document.addEventListener('drop',e=>{e.preventDefault();document.body.classList.remove('drag');
  for(const f of (e.dataTransfer||{}).files||[])addImage(f);});
document.getElementById('fleet-toggle').addEventListener('click',()=>document.body.classList.toggle('fleet-open'));
poll();fleet();input.focus();
})();
"""


def page_html(nonce: str, csrf: str) -> str:
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>First mate</title>
<style nonce="{nonce}">{PAGE_CSS}</style></head>
<body data-csrf="{html.escape(csrf, quote=True)}">
<header><h1>First mate</h1>
<span id="state" class="state offline"><span class="dot"></span><span class="label">Connecting</span></span>
<button id="fleet-toggle" class="ghost" type="button">Fleet</button></header>
<main>
<section id="chat">
<div id="log"><div class="wrap">
<p id="older" class="note" hidden>Earlier conversation is in the terminal history.</p>
<div id="items"></div><p id="note" class="note"></p></div></div>
<div id="compose"><div class="wrap">
<div id="thumbs"></div>
<div id="row"><textarea id="input" rows="1" placeholder="Message the first mate" aria-label="Message"></textarea>
<button id="send" type="button">Send</button></div>
<div id="result" role="status"></div>
</div></div>
</section>
<aside aria-label="Fleet">
<h2>Needs you</h2><ul id="needs"><li class="empty">Loading</li></ul>
<h2>Under way</h2><ul id="underway"><li class="empty">Loading</li></ul>
<h2>Recently done</h2><ul id="done"><li class="empty">Loading</li></ul>
<p id="fleet-error" class="more"></p>
</aside>
</main>
<script nonce="{nonce}">{PAGE_JS}</script>
</body></html>
"""


# --- commands ----------------------------------------------------------------


def command_serve(home: Path, root: Path, port: int) -> None:
    token = load_or_create_token(home)
    try:
        server = ThreadingHTTPServer((LOOPBACK, port), WebHandler)
    except OSError as exc:
        fail(f"could not bind {LOOPBACK}:{port}: {exc}")
    bound = server.server_address[1]
    global STATE
    STATE = WebState(home, root, bound, token)
    print(f"listening on {LOOPBACK}:{bound}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


def main(argv: Optional[List[str]] = None) -> None:
    parser = argparse.ArgumentParser(prog="fm-web.py")
    sub = parser.add_subparsers(dest="command", required=True)
    serve = sub.add_parser("serve")
    serve.add_argument("--home", required=True)
    serve.add_argument("--root", required=True)
    serve.add_argument("--port", type=int, default=DEFAULT_PORT)
    tok = sub.add_parser("token")
    tok.add_argument("--home", required=True)
    args = parser.parse_args(argv)
    if args.command == "serve":
        command_serve(Path(args.home), Path(args.root), args.port)
    elif args.command == "token":
        print(load_or_create_token(Path(args.home)))


if __name__ == "__main__":
    main()
