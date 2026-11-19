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

`fm-web.py conversation --home <home>` prints the same reading as one JSON
document (schema fm-web-conversation.v1), for another page that shows a
home's conversation without this server: the Deck reads every local crew home
this way. Its fields are schema, home, generated_at, session, state (busy,
idle or offline), note, older, version and items, each item exactly as the
page receives it, so its html is already escaped and safe to insert.

Beside the conversation the page mirrors the terminal workspace: the bridge
strip's band and the Factory pane's overview and factory pages, as tabs. It
reads both from the code on disk, `bin/fm-factory.py --screen` and
`bin/fm-bridge-strip.sh fields`, so it selects, counts and words nothing of
its own; mirror_model only lays them out and swaps the few terms docs/web.md
lists. A button on the page is one of the pane's writing keys: POST /api/act
hands the action to `bin/fm-factory.py act`, which sends the note that key
sends. The page decides and merges nothing. This process never takes the
session lock, never drains wakes, and never writes backlog or fleet state.

The page's settings (text size, style, light or dark, reduced motion) live in
the browser's own storage; SETTINGS_JS owns them and is served as
/settings.js.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import datetime
import hashlib
import hmac
import html
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
SCREEN_SCHEMA = "fm-factory-screen.v1"
MIRROR_TTL_SECONDS = 2.0
MIRROR_TIMEOUT_SECONDS = 150
STRIP_TIMEOUT_SECONDS = 20
ACT_BODY_MAX = 32 * 1024
ACT_TEXT_MAX = 4000
ACT_TIMEOUT_SECONDS = 120
ACT_ACTIONS = ("answer", "keep", "change", "discuss", "talk", "settled", "steer", "read")
ACT_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:@/+-]{0,199}$")
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


# --- the mirror: the Factory pane's screen and the bridge strip's fields ------

# The page's own words for the pane's and the strip's jargon. Every other word
# on the page is theirs; docs/web.md lists these.
PLAIN_WORDS = {"ready to merge": "ready for your OK", "PR ready": "ready for your OK", "landed": "went live"}
PLAIN_PHRASES = (
    ("nothing queued", "nothing waiting to start"),
    ("queued", "waiting to start"),
    ("ready to merge", "ready for your OK"),
    ("deferred to a date", "put off to a date"),
    ("deferred", "put off"),
)
# The pane's sentences that end in jargon after a title: only the ending is swapped.
PLAIN_ENDINGS = (
    (" is ready to merge", " is ready for your OK"),
    (" has its PR ready.", " is ready for your OK."),
    (" and land it", " and make it live"),
)
# What the pane says after a key, in the page's case.
PLAIN_SAID = (("\u2713 SENT to Starship: ", "Sent to Starship: "), ("\u2717 NOT SENT: ", "Not sent: "))
# The pane says what a colour means; the page gives each meaning one mark.
MARKS = {"amber": "work", "ember": "work", "red": "you", "green": "done", "cyan": "here"}


def plain_word(word: Any) -> str:
    word = str(word or "")
    return PLAIN_WORDS.get(word, word)


def plain_phrase(text: Any) -> str:
    text = str(text or "")
    for jargon, plain in PLAIN_PHRASES:
        text = text.replace(jargon, plain)
    return text


def plain_ending(text: Any) -> str:
    text = str(text or "")
    for jargon, plain in PLAIN_ENDINGS:
        if text.endswith(jargon):
            return text[: -len(jargon)] + plain
    return text


def plain_said(text: Any) -> str:
    text = str(text or "")
    for shout, plain in PLAIN_SAID:
        if text.startswith(shout):
            return plain + plain_ending(text[len(shout) :])
    return text


def parse_fields(text: str) -> Dict[str, str]:
    """bin/fm-bridge-strip.sh fields: one key=value per line."""
    fields: Dict[str, str] = {}
    for line in text.splitlines():
        key, sep, value = line.partition("=")
        if sep and re.fullmatch(r"[a-z_]+", key):
            fields[key] = value.strip()
    return fields


def _job_model(job: Dict[str, Any]) -> Dict[str, Any]:
    busy = job.get("state") == "busy"
    return {
        "id": job.get("id"),
        "title": job.get("title") or "",
        "busy": busy,
        # What a busy worker says it is doing is its own words; a state is the pane's.
        "words": (job.get("words") or "") if busy else plain_phrase(job.get("words")).replace(" · ", ", "),
        "elapsed": job.get("elapsed") or "",
        "quiet": bool(job.get("quiet")),
        "step": job.get("step") if isinstance(job.get("step"), int) else 1,
        "mark": MARKS.get(job.get("colour") or "", ""),
        "queue": plain_phrase(job.get("queue")),
        "read": bool(job.get("read")),
    }


def _feed_model(feed: Dict[str, Any]) -> Dict[str, Any]:
    title = str(feed.get("title") or "")
    return {
        "title": title[:1] + title[1:].lower(),
        "events": [
            {
                "when": event.get("when") or "",
                "actor": event.get("actor") or "",
                "word": plain_word(event.get("word")),
                "mark": MARKS.get(event.get("colour") or "", ""),
                "text": plain_ending(event.get("text")),
            }
            for event in feed.get("events") or []
        ],
    }


def _need_model(need: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "id": need.get("id"),
        "asking": need.get("asking"),
        "project": need.get("factory"),
        "project_name": need.get("factory_name") or "",
        "question": need.get("kind") == "question",
        "ask": plain_ending(need.get("ask") or need.get("title")),
        "why": need.get("why") or "",
        "options": [
            {"key": option.get("key"), "label": option.get("label") or "", "suggested": bool(option.get("suggested"))}
            for option in need.get("options") or []
        ],
        "suggested_by": need.get("suggested_by") or "Starship",
        "recommendation": need.get("recommendation") or "",
        "holds_up": list(need.get("holds_up") or []),
        "waited": need.get("waited") or "",
        "answered": need.get("answered"),
        "checking": bool(need.get("checking")),
        "mate": need.get("mate") or "",
        "pr": need.get("pr") or "",
        "read": bool(need.get("read")),
    }


def _project_model(factory: Dict[str, Any]) -> Dict[str, Any]:
    page = factory.get("page") or {}
    nxt = factory.get("next")
    return {
        "id": factory.get("id"),
        "name": factory.get("name") or "",
        "about": ". ".join(str(words) for words in factory.get("about") or []),
        "idle": factory.get("state") == "idle",
        "you_steer": factory.get("steered_by") == "you",
        "queue": [plain_phrase(part) for part in str(factory.get("queue") or "").split(" · ") if part],
        "jobs": [_job_model(job) for job in factory.get("jobs") or []],
        "routine": [
            {"kind": line.get("kind") or "", "words": list(line.get("words") or []), "now": line.get("now") or ""}
            for line in factory.get("routine") or []
        ],
        "next": {
            "title": nxt.get("title") or "",
            "once_you_answer": bool(nxt.get("once_you_answer")),
            "then": nxt.get("then") or 0,
        }
        if isinstance(nxt, dict)
        else None,
        "page": {
            "needs": list(page.get("needs") or []),
            "queue": [plain_phrase(part) for part in page.get("queue") or []],
            "jobs": [_job_model(job) for job in page.get("jobs") or []],
            "workers": [_job_model(job) for job in page.get("workers") or []],
            "folded": [
                {
                    "words": plain_phrase(group.get("words")),
                    "jobs": [
                        {"title": job.get("title") or "", "queue": plain_phrase(job.get("queue"))}
                        for job in group.get("jobs") or []
                    ],
                }
                for group in page.get("folded") or []
            ],
            "rules": list(page.get("rules") or []),
            "rules_size": str(page.get("rules_size") or "").replace(" · ", ". "),
            "rules_mark": page.get("rules_mark") or "",
            "learned": [
                {"when": item.get("when") or "", "what": item.get("what") or ""} for item in page.get("learned") or []
            ],
            "feed": _feed_model(page.get("feed") or {}),
            "talk": [
                {"when": line.get("when") or "", "who": line.get("who") or "", "said": line.get("said") or ""}
                for line in page.get("talk") or []
            ],
        },
    }


def mirror_model(screen: Dict[str, Any], fields: Dict[str, str]) -> Dict[str, Any]:
    """What the page shows: the Factory pane's screen (bin/fm-factory.py
    --screen) and the bridge strip's fields (bin/fm-bridge-strip.sh fields),
    in the page's plain words. It selects and counts nothing itself."""
    counts = screen.get("counts") or {}
    known = counts.get("busy") is not None
    lamps: List[Dict[str, Any]] = []
    if known:
        decisions = counts.get("decisions") or 0
        lamps = [
            {"mark": "work", "count": counts.get("busy") or 0, "words": "busy"},
            {"mark": "you", "count": decisions, "words": "decision for you" if decisions == 1 else "decisions for you"},
            {"mark": "done", "count": counts.get("ready_to_merge") or 0, "words": "ready for your OK"},
        ]
    needs = [_need_model(need) for need in screen.get("needs") or []]
    listed = {need["id"]: need for need in needs}
    call = None
    if fields.get("call_id") and fields.get("call_title"):
        # The strip names the call; the pane's card for it has its whole title.
        card = listed.get(fields["call_id"])
        call = {
            "id": fields["call_id"],
            "title": card["ask"] if card else fields["call_title"],
            "question": fields.get("call_kind") != "merge",
            "listed": card is not None,
        }
    elif needs:
        call = {"id": needs[0]["id"], "title": needs[0]["ask"], "question": needs[0]["question"], "listed": True}
    return {
        "clock": screen.get("clock") or "",
        "band": {
            "lamps": lamps,
            "note": "" if known and counts.get("reading") != "past" else (fields.get("age") or "") if known else "reading the crew",
            "call": call,
            "alert": re.sub(r"\bfailed\b", "hit a problem", fields.get("alert") or ""),
            "night": fields.get("night") or "",
            "night_done": fields.get("night_mark") == "done",
            "battery": fields.get("battery") or "",
            "battery_mark": fields.get("battery_mark") or "",
        },
        "summary": [
            {"words": plain_phrase(piece.get("words")), "mark": MARKS.get(piece.get("colour") or "", "")}
            for piece in screen.get("count_words") or []
        ],
        "queue": [plain_phrase(words) for words in screen.get("queue") or []],
        "needs": needs,
        "projects": [_project_model(factory) for factory in screen.get("factories") or []],
        "feed": _feed_model(screen.get("feed") or {}),
        "steps": [plain_word(step) for step in screen.get("steps") or []],
    }


def child_env(home: Path, root: Path) -> Dict[str, str]:
    env = dict(os.environ)
    env["FM_HOME"] = str(home)
    env["FM_ROOT_OVERRIDE"] = str(root)
    return env


def read_screen(home: Path, root: Path) -> Dict[str, Any]:
    """The Factory pane's screen as data, from the code on disk."""
    proc = subprocess.run(
        [sys.executable, str(root / "bin" / "fm-factory.py"), "--screen"],
        env=child_env(home, root),
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=MIRROR_TIMEOUT_SECONDS,
    )
    if proc.returncode != 0:
        detail = (proc.stderr or "").strip().splitlines()[-1:] or ["the projects could not be read"]
        raise RuntimeError(detail[0].removeprefix("fm-factory: "))
    screen = json.loads(proc.stdout)
    if not isinstance(screen, dict) or screen.get("schema") != SCREEN_SCHEMA:
        raise RuntimeError("the projects came back in a form this page does not know")
    return screen


def read_fields(home: Path, root: Path) -> Dict[str, str]:
    """The bridge strip's fields; a strip that cannot be read leaves the band
    with its lamps only, since those come from the screen."""
    try:
        proc = subprocess.run(
            ["bash", str(root / "bin" / "fm-bridge-strip.sh"), "fields"],
            env=child_env(home, root),
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=STRIP_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.SubprocessError):
        return {}
    return parse_fields(proc.stdout) if proc.returncode == 0 else {}


class FleetCache:
    """One reading of the projects for every open page, at most every
    MIRROR_TTL_SECONDS, and at once after an action."""

    def __init__(self, home: Path, root: Path) -> None:
        self.home = home
        self.root = root
        self.lock = threading.Lock()
        self.refresh = threading.Lock()
        self.payload: Optional[Dict[str, Any]] = None
        self.fetched_at = 0.0

    def drop(self) -> None:
        with self.lock:
            self.fetched_at = 0.0

    def get(self) -> Dict[str, Any]:
        with self.refresh:
            with self.lock:
                if self.payload is not None and time.monotonic() - self.fetched_at < MIRROR_TTL_SECONDS:
                    return self.payload
            model = mirror_model(read_screen(self.home, self.root), read_fields(self.home, self.root))
            # The clock moves every minute; it is left out of the version so a
            # page redraws only when something it shows changed.
            digest = hashlib.sha256(
                json.dumps({k: v for k, v in model.items() if k != "clock"}, sort_keys=True).encode()
            ).hexdigest()[:20]
            payload = {"version": digest, "model": model}
            with self.lock:
                self.payload = payload
                self.fetched_at = time.monotonic()
            return payload


def decode_act_body(body: bytes) -> Dict[str, Any]:
    """One action for bin/fm-factory.py act, with nothing in it the page may not send."""
    try:
        payload = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError("the request was not JSON") from exc
    if not isinstance(payload, dict) or payload.get("action") not in ACT_ACTIONS:
        raise ValueError("the page asked for something this page cannot do")
    ask: Dict[str, Any] = {"action": payload["action"]}
    for key in ("item", "asking", "option", "factory", "job"):
        value = payload.get(key)
        if value is None:
            continue
        if not isinstance(value, str) or not ACT_NAME_RE.match(value):
            raise ValueError(f"{key} is not a name this page knows")
        ask[key] = value
    who = payload.get("who")
    if who is not None:
        if who not in ("you", "Starship"):
            raise ValueError("who steers is you or Starship")
        ask["who"] = who
    text = payload.get("text")
    if text is not None:
        if not isinstance(text, str) or len(text) > ACT_TEXT_MAX:
            raise ValueError("the words are too long")
        ask["text"] = text
    return ask


def factory_act(home: Path, root: Path, ask: Dict[str, Any]) -> Tuple[int, Dict[str, Any]]:
    """Hand one action to bin/fm-factory.py act, the only path in: it sends the
    note the Factory pane's own key sends. Returns the HTTP status and answer."""
    proc = subprocess.run(
        [sys.executable, str(root / "bin" / "fm-factory.py"), "act"],
        env=child_env(home, root),
        input=json.dumps(ask),
        capture_output=True,
        text=True,
        timeout=ACT_TIMEOUT_SECONDS,
    )
    if proc.returncode == 2:
        return 400, {"ok": False, "said": "Not sent: the page asked for something that cannot be done."}
    try:
        answer = json.loads(proc.stdout) if proc.returncode == 0 else None
    except json.JSONDecodeError:
        answer = None
    if not isinstance(answer, dict):
        detail = (proc.stderr or "").strip().splitlines()[-1:] or ["nothing came back"]
        return 502, {"ok": False, "said": "Not sent: " + detail[0].removeprefix("fm-factory: ")}
    return 200, {"ok": bool(answer.get("ok")), "said": plain_said(answer.get("said"))}


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
        self.mirror = FleetCache(home, root)
        self.send_lock = threading.Lock()
        self.act_lock = threading.Lock()


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
        elif parsed.path == "/api/mirror":
            try:
                payload = STATE.mirror.get()
            except Exception as exc:  # the page says why instead of breaking
                self._json(503, {"error": str(exc) or "the projects could not be read"})
                return
            since = query.get("since", [""])[0]
            if since and since == payload["version"]:
                self._json(200, {"version": since, "unchanged": True, "clock": payload["model"]["clock"]})
            else:
                self._json(200, payload)
        elif parsed.path == "/settings.js":
            self._send(200, SETTINGS_JS.encode("utf-8"), "text/javascript; charset=utf-8")
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
        path = urlparse(self.path).path
        if path not in ("/api/send", "/api/act"):
            self._text(404, "not found", close=True)
            return
        if length < 0 or length > (SEND_BODY_MAX if path == "/api/send" else ACT_BODY_MAX):
            self._text(413, "too large", close=True)
            return
        body = self.rfile.read(length)
        if path == "/api/act":
            self._act(body)
            return
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

    def _act(self, body: bytes) -> None:
        try:
            ask = decode_act_body(body)
        except ValueError as exc:
            self._json(400, {"ok": False, "said": f"Not sent: {exc}."})
            return
        with STATE.act_lock:
            try:
                status, answer = factory_act(STATE.home, STATE.root, ask)
            except (OSError, subprocess.SubprocessError) as exc:
                status, answer = 502, {"ok": False, "said": f"Not sent: {exc}."}
        STATE.mirror.drop()
        self._json(status, answer)


# --- page --------------------------------------------------------------------

PAGE_CSS = r"""
:root{
--font:system-ui,-apple-system,"Segoe UI",sans-serif;
--bg:#F1EBDF;--surface:#FBF8F1;--surface-2:#F4EFE5;--ink:#262624;--ink-2:#63605A;--line:#E2DACB;--edge:#C2B8A5;
--hull:#FBF8F1;--hull-ink:#262624;--hull-2:#63605A;--hull-line:#E2DACB;--hull-soft:#F4EFE5;
--plate:#34373A;--plate-ink:#EDEBE6;--mic:#5B8496;
--here:#3E6577;--here-bg:#E4EAE8;--on-here:#FFFFFF;
--work:#7A6233;--work-bg:#F3EAD3;--work-lamp:#CDA963;
--done:#44705A;--done-bg:#E4EDE3;--done-lamp:#7FB497;
--you:#9C5548;--you-bg:#F5E6E0;--you-lamp:#D08A7A;
--code:#EFE9DD;--shadow:0 1px 2px rgba(38,38,36,.04),0 6px 18px rgba(38,38,36,.05);
}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){
--bg:#14181A;--surface:#1B2023;--surface-2:#22282B;--ink:#E4E8EA;--ink-2:#9AA4A9;--line:#2E3538;--edge:#4A5458;
--hull:#1B2023;--hull-ink:#E4E8EA;--hull-2:#9AA4A9;--hull-line:#2E3538;--hull-soft:#22282B;
--plate:#2A3236;--plate-ink:#E9EDEF;--mic:#5B8496;
--here:#8DB4C4;--here-bg:#223038;--on-here:#10191D;
--work:#D3BC8A;--work-bg:#2C281E;--work-lamp:#BFA36A;
--done:#9CC4AD;--done-bg:#1F2B25;--done-lamp:#7FAE94;
--you:#DDA596;--you-bg:#33231F;--you-lamp:#C98778;
--code:#262C2F;--shadow:0 1px 2px rgba(0,0,0,.2),0 6px 18px rgba(0,0,0,.2);
}}
:root[data-theme="dark"]{
--bg:#14181A;--surface:#1B2023;--surface-2:#22282B;--ink:#E4E8EA;--ink-2:#9AA4A9;--line:#2E3538;--edge:#4A5458;
--hull:#1B2023;--hull-ink:#E4E8EA;--hull-2:#9AA4A9;--hull-line:#2E3538;--hull-soft:#22282B;
--plate:#2A3236;--plate-ink:#E9EDEF;--mic:#5B8496;
--here:#8DB4C4;--here-bg:#223038;--on-here:#10191D;
--work:#D3BC8A;--work-bg:#2C281E;--work-lamp:#BFA36A;
--done:#9CC4AD;--done-bg:#1F2B25;--done-lamp:#7FAE94;
--you:#DDA596;--you-bg:#33231F;--you-lamp:#C98778;
--code:#262C2F;--shadow:0 1px 2px rgba(0,0,0,.2),0 6px 18px rgba(0,0,0,.2);
}
/* Lively: the same page with stronger colours. Calm is the default. */
:root[data-style="lively"]{
--bg:#F1EBDF;--surface:#FDFAF4;--surface-2:#F6F1E7;--ink:#14232D;--ink-2:#4C5F6B;--line:#DDD5C5;--edge:#B9AE9B;
--hull:#143242;--hull-ink:#EAF2F5;--hull-2:#9FB6C2;--hull-line:#2C4C5D;--hull-soft:rgba(255,255,255,.07);
--plate:#143242;--plate-ink:#EAF2F5;--mic:#2F7FE0;
--here:#0B6B88;--here-bg:#DDEEF2;--on-here:#FFFFFF;
--work:#8F5C0B;--work-bg:#FBF0D9;--work-lamp:#E6A93A;
--done:#1F6F45;--done-bg:#E1F1E7;--done-lamp:#49B678;
--you:#B5371F;--you-bg:#FBE8E3;--you-lamp:#EE6447;
--code:#EFE9DD;--shadow:0 1px 2px rgba(20,35,45,.06),0 8px 24px rgba(20,35,45,.07);
}
@media (prefers-color-scheme:dark){:root[data-style="lively"]:not([data-theme="light"]){
--bg:#0E181E;--surface:#15232B;--surface-2:#1A2B35;--ink:#E7EEF2;--ink-2:#9FB2BE;--line:#2A3D49;--edge:#3D5564;
--hull:#1B3442;--hull-ink:#EAF2F5;--hull-2:#9FB6C2;--hull-line:#345566;--hull-soft:rgba(255,255,255,.07);
--plate:#1B3442;--plate-ink:#EAF2F5;--mic:#2F7FE0;
--here:#62C6E2;--here-bg:#12333F;--on-here:#06222B;
--work:#E7B95F;--work-bg:#33290F;--work-lamp:#E6A93A;
--done:#74CB95;--done-bg:#143021;--done-lamp:#49B678;
--you:#F39078;--you-bg:#3A1B14;--you-lamp:#EE6447;
--code:#1F313B;--shadow:0 1px 2px rgba(0,0,0,.3),0 8px 24px rgba(0,0,0,.28);
}}
:root[data-style="lively"][data-theme="dark"]{
--bg:#0E181E;--surface:#15232B;--surface-2:#1A2B35;--ink:#E7EEF2;--ink-2:#9FB2BE;--line:#2A3D49;--edge:#3D5564;
--hull:#1B3442;--hull-ink:#EAF2F5;--hull-2:#9FB6C2;--hull-line:#345566;--hull-soft:rgba(255,255,255,.07);
--plate:#1B3442;--plate-ink:#EAF2F5;--mic:#2F7FE0;
--here:#62C6E2;--here-bg:#12333F;--on-here:#06222B;
--work:#E7B95F;--work-bg:#33290F;--work-lamp:#E6A93A;
--done:#74CB95;--done-bg:#143021;--done-lamp:#49B678;
--you:#F39078;--you-bg:#3A1B14;--you-lamp:#EE6447;
--code:#1F313B;--shadow:0 1px 2px rgba(0,0,0,.3),0 8px 24px rgba(0,0,0,.28);
}
:root{color-scheme:light dark}
:root[data-theme="light"]{color-scheme:light}
:root[data-theme="dark"]{color-scheme:dark}
*{box-sizing:border-box}
html{height:100%}
body{height:100%;margin:0;background:var(--bg);color:var(--ink);font:1rem/1.5 var(--font);-webkit-font-smoothing:antialiased}
button,textarea,input{font:inherit;color:inherit}
button{cursor:pointer}
h1,h2,h3,h4,p,ul,ol{margin:0;padding:0}
ul,ol{list-style:none}
svg{width:1em;height:1em;flex:none}
[hidden]{display:none!important}
:focus-visible{outline:2px solid var(--here);outline-offset:2px;border-radius:.375rem}
.app{display:flex;flex-direction:column;height:100dvh;min-height:0}

.toprow{display:flex;align-items:flex-end;gap:.75rem;padding:.625rem 1rem 0}
.tabs{flex:1;min-width:0;display:flex;gap:.125rem;overflow-x:auto;scrollbar-width:none}
.tabs::-webkit-scrollbar{display:none}
.tab{flex:none;border:0;background:none;padding:.5rem .875rem .625rem;font-size:.94rem;color:var(--ink-2);border-bottom:3px solid transparent;white-space:nowrap}
.tab:hover{color:var(--ink)}
.tab .dot{display:inline-block;margin-left:.4rem;vertical-align:.06rem}
.tab[aria-selected="true"]{color:var(--ink);font-weight:600;border-bottom-color:var(--here)}
.gear{flex:none;display:inline-flex;align-items:center;gap:.4rem;border:1px solid var(--line);background:var(--surface);border-radius:.5rem;padding:.25rem .7rem;font-size:.84rem;color:var(--ink-2);margin-bottom:.5rem}
.gear:hover,.gear[aria-expanded="true"]{color:var(--ink);border-color:var(--edge)}
.gear svg{font-size:1rem}

.bridge{margin:0 1rem;background:var(--hull);color:var(--hull-ink);border-radius:.875rem;padding:.75rem 1.125rem;display:flex;align-items:center;gap:.625rem 1.125rem;flex-wrap:wrap;border:1px solid var(--line)}
.brand{display:flex;align-items:center;gap:.5rem;font-weight:600;font-size:1.125rem;letter-spacing:.04em}
.brand svg{color:var(--here);font-size:1rem}
.lamps{display:flex;gap:.5rem 1.125rem;flex-wrap:wrap;padding-left:1.125rem;border-left:1px solid var(--hull-line)}
.lamp{display:flex;align-items:center;gap:.56rem;font-size:.94rem;white-space:nowrap}
.lamp i{width:.69rem;height:.69rem;border-radius:50%;border:1.5px solid var(--hull-2);opacity:.6}
.lamp b{font-weight:600;font-variant-numeric:tabular-nums}
.lamp:not(.lit){color:var(--hull-2)}
.lamp.lit i{border:0;opacity:1}
.lamp.work.lit i{background:var(--work-lamp)}
.lamp.you.lit i{background:var(--you-lamp)}
.lamp.done.lit i{background:var(--done-lamp)}
.band-note{font-size:.875rem;color:var(--hull-2)}
.sides{display:flex;align-items:center;gap:.5rem 1.125rem;flex-wrap:wrap}
.urgent{flex:1 1 21rem;min-width:0;display:flex;align-items:center;gap:.625rem;text-align:left;background:var(--hull-soft);border:1px solid var(--hull-line);color:inherit;border-radius:.625rem;padding:.44rem .5rem .44rem .75rem}
button.urgent:hover{border-color:var(--edge)}
.urgent .k{font-size:.81rem;color:var(--hull-2);white-space:nowrap}
.urgent .t{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-weight:600;font-size:.94rem}
.urgent .go{font-size:.81rem;background:var(--surface);color:var(--ink);border:1px solid var(--edge);border-radius:.44rem;padding:.06rem .625rem;font-weight:600}
.urgent.none{color:var(--hull-2);font-size:.94rem}
@media (max-width:110rem){.urgent{order:5;flex-basis:100%}.sides{margin-left:auto}}
.alert{display:flex;align-items:center;gap:.5rem;font-size:.875rem;font-weight:600;background:var(--you-bg);color:var(--you);border-radius:999px;padding:.25rem .75rem}
.alert i{width:.5rem;height:.5rem;border-radius:50%;background:var(--you-lamp);flex:none}
.aside{font-size:.84rem;color:var(--hull-2);white-space:nowrap;display:flex;align-items:center;gap:.375rem}
.aside svg{font-size:1.25rem}
.aside.good{color:var(--done)}.aside.low{color:var(--work)}.aside.critical{color:var(--you);font-weight:600}

.main{flex:1;min-height:0;display:grid;grid-template-columns:minmax(0,1.2fr) minmax(0,1fr);gap:.875rem;padding:.875rem 1rem 1rem}
.pane{min-height:0;min-width:0;background:var(--surface);border:1px solid var(--line);border-radius:1rem;display:flex;flex-direction:column;overflow:hidden}
.pane-head{display:flex;align-items:baseline;gap:.625rem;padding:.875rem 1.25rem .625rem;flex-wrap:wrap}
.pane-head h2{font-size:1.125rem;font-weight:600}
.pane-head .when{margin-left:auto;font-size:.875rem;color:var(--ink-2);font-variant-numeric:tabular-nums}
.state{display:inline-flex;align-items:center;gap:.375rem;font-size:.81rem;font-weight:600;border-radius:999px;padding:.125rem .625rem;background:var(--surface-2);color:var(--ink-2)}
.state.busy{background:var(--work-bg);color:var(--work)}
.state.offline{background:var(--you-bg);color:var(--you)}
.side-switch{display:none}
.state:empty{display:none}

#log{flex:1;min-height:0;overflow-y:auto;padding:.5rem 1.375rem 1rem}
.wrap{max-width:48rem;margin:0 auto}
.msg{display:flex;margin:.875rem 0}
.msg.user{justify-content:flex-end}
.bubble{max-width:85%;padding:.625rem .875rem;border-radius:1rem 1rem .25rem 1rem;background:var(--here-bg);overflow-wrap:anywhere}
.msg.assistant{gap:.75rem;align-items:flex-start}
.av{width:1.875rem;height:1.875rem;border-radius:50%;background:var(--surface-2);border:1px solid var(--line);color:var(--here);display:grid;place-items:center;font-size:.875rem;flex:none;margin-top:.125rem}
.msg.assistant .bubble{max-width:100%;min-width:0;background:transparent;padding:.125rem 0;border-radius:0}
.bubble p{margin:.5em 0}.bubble p:first-child{margin-top:0}.bubble p:last-child{margin-bottom:0}
.bubble h3,.bubble h4,.bubble h5,.bubble h6{margin:.8em 0 .3em;font-size:1em}
.bubble h3{font-size:1.08em}
.bubble ul,.bubble ol{margin:.5em 0;padding-left:1.4em}
.bubble ul{list-style:disc}.bubble ol{list-style:decimal}
.bubble li+li{margin-top:.3em}
.bubble a{color:var(--here)}
.bubble code{background:var(--code);padding:.06em .3em;border-radius:.3em;font:.84em/1.4 ui-monospace,SFMono-Regular,Menlo,monospace}
.bubble pre{background:var(--code);padding:.625rem .75rem;border-radius:.625rem;overflow-x:auto}
.bubble pre code{background:none;padding:0}
.bubble blockquote{margin:.4em 0;padding-left:.75rem;border-left:3px solid var(--line);color:var(--ink-2)}
.bubble hr{border:none;border-top:1px solid var(--line);margin:.8em 0}
.table{overflow-x:auto}
.bubble table{border-collapse:collapse;margin:.4em 0;font-size:.9em}
.bubble th,.bubble td{border:1px solid var(--line);padding:.25rem .5rem;text-align:left;vertical-align:top}
.chip{display:inline-block;font-size:.78rem;color:var(--ink-2);margin-top:.25rem}
details.quiet{margin:.125rem 0 .125rem 2.625rem;font-size:.84rem;color:var(--ink-2)}
details.quiet summary{cursor:pointer;list-style:none;padding:.125rem 0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
details.quiet summary::-webkit-details-marker{display:none}
details.quiet summary::before{content:"\25B8";display:inline-block;width:1em;transition:transform .15s}
details.quiet[open] summary::before{transform:rotate(90deg)}
details.quiet .name{color:var(--ink);font-weight:500}
details.quiet.err .name{color:var(--you)}
details.quiet pre{white-space:pre-wrap;overflow-wrap:anywhere;background:var(--code);color:var(--ink);padding:.5rem .625rem;border-radius:.5rem;font:.78rem/1.45 ui-monospace,SFMono-Regular,Menlo,monospace;max-height:20rem;overflow:auto;margin:.25rem 0 .5rem}
.compact{display:flex;align-items:center;gap:.625rem;margin:1rem 0}
.compact::before,.compact::after{content:"";flex:1;border-top:1px dashed var(--line)}
.compact details{font-size:.78rem;color:var(--ink-2);text-align:center}
.compact details pre{text-align:left;white-space:pre-wrap;max-height:20rem;overflow:auto;background:var(--code);padding:.5rem;border-radius:.5rem}
.note{color:var(--ink-2);text-align:center;font-size:.84rem;margin:.75rem 0}
.note:empty{display:none}
#compose{border-top:1px solid var(--line);padding:.75rem 1rem .625rem;background:var(--surface)}
#compose .wrap{display:flex;flex-direction:column;gap:.375rem}
#row{display:flex;gap:.5rem;align-items:flex-end}
#input{flex:1;min-width:0;resize:none;min-height:2.875rem;max-height:12.5rem;padding:.69rem .875rem;border-radius:.75rem;border:1px solid var(--line);background:var(--bg);outline:none}
#input:focus{border-color:var(--here)}
#thumbs{display:flex;gap:.375rem;flex-wrap:wrap}
#thumbs:empty{display:none}
.thumb{position:relative}
.thumb img{height:3.5rem;border-radius:.5rem;border:1px solid var(--line)}
.thumb button{position:absolute;top:-.375rem;right:-.375rem;border:none;border-radius:50%;width:1.25rem;height:1.25rem;background:var(--ink);color:var(--bg);font-size:.75rem;line-height:1.25rem;padding:0}
#result{font-size:.78rem;color:var(--ink-2);min-height:1em}
#result.failed{color:var(--you)}
body.drag #log{outline:2px dashed var(--here);outline-offset:-.5rem}

.btn{display:inline-flex;align-items:center;gap:.44rem;border:1px solid var(--line);background:var(--surface);border-radius:.625rem;padding:.5rem .81rem;font-size:.94rem;font-weight:500;white-space:nowrap}
.btn:hover:not(:disabled){border-color:var(--edge)}
.btn.primary{background:var(--here);border-color:var(--here);color:var(--on-here);font-weight:600}
.btn.small{padding:.31rem .625rem;font-size:.875rem}
.btn.plain{border-color:transparent;background:none;color:var(--here);padding-inline:.375rem}
.btn:disabled{opacity:.6;cursor:default}
.btn svg{font-size:1.06rem}
#send{height:2.875rem}

.p-top{padding:0 1.25rem .75rem;border-bottom:1px solid var(--line)}
.sum{font-size:.94rem}
.sum b{font-weight:600}
.queue{font-size:.875rem;color:var(--ink-2);margin-top:.19rem}
.notice{margin-top:.625rem;font-size:.9rem;border-radius:.625rem;padding:.5rem .75rem;font-weight:500}
.notice.ok{background:var(--done-bg);color:var(--done)}
.notice.info{background:var(--here-bg);color:var(--here)}
.notice.bad{background:var(--you-bg);color:var(--you)}
.p-body{flex:1;min-height:0;overflow-y:auto;padding:1rem 1.25rem 2rem}
.sec+.sec{margin-top:1.625rem}
.sec>h3{font-size:1rem;font-weight:600;display:flex;align-items:baseline;gap:.5rem;margin-bottom:.625rem}
.sec>h3 .n{font-size:.81rem;font-weight:600;border-radius:999px;padding:0 .5rem;background:var(--surface-2);color:var(--ink-2);border:1px solid var(--line)}
.sec>h3 small{font-size:.875rem;font-weight:400;color:var(--ink-2)}
.empty{font-size:.94rem;color:var(--ink-2)}

.call{border:1px solid var(--line);border-radius:.75rem;background:var(--surface)}
.call+.call{margin-top:.5rem}
.call.open{border-color:var(--edge);box-shadow:var(--shadow)}
.call.flash{animation:flash 1.2s ease-out}
@keyframes flash{0%{background:var(--here-bg)}100%{background:var(--surface)}}
.call-row{width:100%;border:0;background:none;text-align:left;display:flex;align-items:center;gap:.625rem;padding:.625rem .875rem;border-radius:.75rem}
.dot{width:.56rem;height:.56rem;border-radius:50%;flex:none;background:var(--edge)}
.dot.you{background:var(--you-lamp)}.dot.done{background:var(--done-lamp)}.dot.work{background:var(--work-lamp)}.dot.here{background:var(--here)}
.call-title{flex:1;min-width:0;font-weight:600;font-size:.94rem;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.call.open .call-title{white-space:normal;font-size:1rem}
.call-meta{flex:none;max-width:45%;font-size:.84rem;color:var(--ink-2);text-align:right;display:flex;flex-direction:column;line-height:1.3}
.call-body{padding:0 .875rem .875rem 2.06rem}
.call-body>*+*{margin-top:.625rem}
.why{font-size:.94rem}
.opts{display:grid;gap:.375rem}
.opt{display:flex;align-items:center;gap:.625rem;width:100%;text-align:left;border:1px solid var(--line);border-radius:.625rem;background:var(--surface);padding:.56rem .75rem;font-size:.94rem}
.opt:hover:not(:disabled){border-color:var(--here)}
.opt:disabled{cursor:default}
.opt .ring{width:1rem;height:1rem;border-radius:50%;border:1.5px solid var(--ink-2);flex:none;display:grid;place-items:center}
.opt.picked{border-color:var(--here);background:var(--here-bg)}
.opt.picked .ring{border-color:var(--here)}
.opt.picked .ring::after{content:"";width:.5rem;height:.5rem;border-radius:50%;background:var(--here)}
.opt .l{flex:1;min-width:0}
.tag{font-size:.78rem;font-weight:600;color:var(--here);background:var(--here-bg);border-radius:999px;padding:.06rem .56rem;white-space:nowrap}
.opt.picked .tag{background:var(--surface)}
.confirm,.talk{border:1px solid var(--edge);border-radius:.75rem;padding:.75rem .875rem;background:var(--surface)}
.confirm p{font-size:.94rem}
.unsent{font-size:.81rem;color:var(--ink-2)}
.talk .unsent{margin-top:.5rem}
.rowb{display:flex;flex-wrap:wrap;gap:.5rem;align-items:center;margin-top:.625rem}
.call-body>.rowb{margin-top:.625rem}
.holds{font-size:.875rem;color:var(--ink-2)}
.holds a{color:var(--here);overflow-wrap:anywhere}
.said{font-size:.9rem;border-radius:.625rem;padding:.5rem .75rem;background:var(--here-bg);color:var(--here);font-weight:500}
.talk-head{font-size:.875rem;font-weight:600}
.talk textarea{display:block;width:100%;margin-top:.5rem;border:1px solid var(--line);border-radius:.625rem;padding:.56rem .75rem;background:var(--bg);resize:vertical;outline:none}
.talk textarea:focus{border-color:var(--here)}

.proj{border-top:1px solid var(--line);padding:.75rem 0}
.proj:first-of-type{border-top:0;padding-top:0}
.proj-head{display:flex;align-items:center;gap:.375rem .75rem;flex-wrap:wrap}
.proj-name{border:0;background:none;padding:0;font-weight:600;font-size:1rem;text-decoration:underline;text-decoration-color:var(--line);text-underline-offset:.25rem}
.proj-name:hover{text-decoration-color:var(--here);color:var(--here)}
.proj-q{font-size:.875rem;color:var(--ink-2)}
.steer{margin-left:auto;display:flex;align-items:center;gap:.5rem;font-size:.84rem;color:var(--ink-2)}
.seg{display:flex;border:1px solid var(--line);border-radius:.5rem;overflow:hidden;background:var(--surface)}
.seg button{border:0;background:none;padding:.125rem .625rem;font-size:.84rem;color:var(--ink-2)}
.seg button[aria-pressed="true"]{background:var(--here-bg);color:var(--ink);font-weight:600}
.job{margin-top:.625rem;border-radius:.75rem;background:var(--surface-2);padding:.69rem .875rem}
.job-top{display:flex;gap:.625rem;align-items:baseline}
.job-top .dot{align-self:center}
.job-title{flex:1;min-width:0;font-weight:600;font-size:.94rem}
.mins{font-size:.84rem;color:var(--ink-2);white-space:nowrap;font-variant-numeric:tabular-nums}
.steps{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:.31rem;margin-top:.625rem}
.steps li{font-size:.81rem;color:var(--ink-2);padding-top:.44rem;border-top:.25rem solid var(--line);border-radius:.125rem;line-height:1.25;display:flex;gap:.25rem;align-items:flex-start}
.steps li svg{font-size:.875rem;margin-top:.06rem}
.steps li.done{border-top-color:var(--done-lamp);color:var(--done)}
.steps li.now{border-top-color:var(--work-lamp);color:var(--work);font-weight:600}
.job-foot{display:flex;justify-content:space-between;align-items:baseline;gap:.25rem .75rem;flex-wrap:wrap;margin-top:.56rem}
.doing{font-size:.9rem;flex:1 1 13rem}
.doing.quiet{color:var(--work);font-weight:500}
.job-foot .btn{margin-left:auto}
.jobline{display:flex;gap:.625rem;align-items:baseline;margin-top:.5rem;font-size:.94rem}
.jobline .dot{align-self:center}
.jobline .t{flex:1;min-width:0}
.jobline .w{font-size:.84rem;color:var(--ink-2);white-space:nowrap}
.jobline .w.you{color:var(--you)}.jobline .w.done{color:var(--done)}.jobline .w.work{color:var(--work)}
.line{font-size:.875rem;color:var(--ink-2);margin-top:.5rem;display:flex;gap:.5rem;flex-wrap:wrap}
.line b{font-weight:600;color:var(--ink)}
.line .r{margin-left:auto}
.feed li{display:grid;grid-template-columns:4.25rem minmax(0,1fr);gap:.125rem .625rem;padding:.5rem 0;border-top:1px solid var(--line);font-size:.9rem}
.feed li:first-child{border-top:0}
.feed time{color:var(--ink-2);font-variant-numeric:tabular-nums;font-size:.84rem;padding-top:.06rem}
.feed .who{font-weight:600}
.word{font-size:.78rem;font-weight:600;border-radius:999px;padding:.06rem .56rem;margin:0 .25rem;white-space:nowrap;background:var(--surface-2);color:var(--ink-2)}
.word.you{background:var(--you-bg);color:var(--you)}.word.done{background:var(--done-bg);color:var(--done)}
.word.here{background:var(--here-bg);color:var(--here)}.word.work{background:var(--work-bg);color:var(--work)}

.pp-head{padding:1rem 1.375rem .75rem;border-bottom:1px solid var(--line)}
.pp-head h2{font-size:1.375rem;font-weight:600}
.pp-head>p{color:var(--ink-2);font-size:.94rem}
.pp-head .steer{margin-left:0}
.all{font-size:.875rem;color:var(--ink-2);margin-top:.625rem}
.list li{padding:.5rem 0;border-top:1px solid var(--line);font-size:.94rem;display:flex;gap:.625rem;align-items:baseline}
.list li:first-child{border-top:0}
.list .w{margin-left:auto;font-size:.84rem;color:var(--ink-2);white-space:nowrap}
.bul li{font-size:.94rem;padding-left:1rem;position:relative}
.bul li+li{margin-top:.375rem}
.bul li::before{content:"";position:absolute;left:.125rem;top:.62em;width:.31rem;height:.31rem;border-radius:50%;background:var(--ink-2)}
.bul time{color:var(--ink-2);font-size:.84rem;margin-right:.5rem}
.warn{color:var(--you)}.near{color:var(--work)}
.worker{border:1px solid var(--line);border-radius:.75rem;padding:.75rem .875rem;background:var(--surface)}
.worker+.worker{margin-top:.625rem}
.worker.sel{border-color:var(--edge);box-shadow:var(--shadow)}
.worker h4{font-size:.94rem;font-weight:600;display:flex;gap:.625rem;align-items:baseline}
.worker h4 span{margin-left:auto;font-size:.84rem;color:var(--ink-2);font-weight:400;white-space:nowrap}
.worker .doing{margin-top:.5rem;font-size:.9rem}
.worker .doing.quiet{color:var(--work);font-weight:500}

.settings{position:fixed;top:3.25rem;right:1rem;z-index:30;width:21rem;max-width:calc(100vw - 1.5rem);max-height:calc(100dvh - 4rem);overflow-y:auto;background:var(--surface);border:1px solid var(--edge);border-radius:1rem;box-shadow:var(--shadow),0 12px 36px rgba(0,0,0,.14);padding:1rem 1.125rem 1.125rem}
.settings h2{font-size:1.06rem;font-weight:600;display:flex;align-items:center}
.settings h2 button{margin-left:auto}
.set{margin-top:1rem}
.set>label,.set>.lbl{display:flex;align-items:baseline;gap:.5rem;font-size:.9rem;font-weight:600}
.set .now{margin-left:auto;font-weight:400;color:var(--ink-2);font-size:.84rem}
.hint{font-size:.81rem;color:var(--ink-2);margin-top:.25rem}
.settings>.hint{margin-top:1rem}
.size-row{display:flex;align-items:center;gap:.625rem;margin-top:.5rem}
.size-row .a{color:var(--ink-2);line-height:1}
.size-row .a.s{font-size:.8rem}.size-row .a.l{font-size:1.45rem}
.size-row input{flex:1;min-width:0;accent-color:var(--here)}
.set .seg{margin-top:.5rem}
.set .seg button{flex:1;padding:.375rem .5rem;font-size:.9rem}
.switch{display:flex;align-items:center;gap:.625rem;margin-top:.5rem;font-size:.9rem;font-weight:400}
.switch input{width:1.125rem;height:1.125rem;accent-color:var(--here)}

/* Lively's stronger marks */
[data-style="lively"] .bridge{border-color:transparent;box-shadow:var(--shadow)}
[data-style="lively"] .brand svg{color:#8FD6EA}
[data-style="lively"] .lamp.work.lit i{box-shadow:0 0 0 .25rem rgba(230,169,58,.22)}
[data-style="lively"] .lamp.you.lit i{box-shadow:0 0 0 .25rem rgba(238,100,71,.24)}
[data-style="lively"] .lamp.done.lit i{box-shadow:0 0 0 .25rem rgba(73,182,120,.24)}
[data-style="lively"] button.urgent:hover{background:rgba(255,255,255,.12)}
[data-style="lively"] .urgent .go{background:var(--hull-ink);color:var(--hull);border-color:transparent}
[data-style="lively"] .alert{background:#5A2118;color:#FFD9CF}
[data-style="lively"] .aside.good{color:#8EDCAF}
[data-style="lively"] .aside.low{color:#F0C36C}
[data-style="lively"] .aside.critical{color:#FFB3A3}
[data-style="lively"] .av{background:var(--hull);color:#8FD6EA;border-color:transparent}
[data-style="lively"] .sum .c-work{color:var(--work)}
[data-style="lively"] .sum .c-you{color:var(--you)}
[data-style="lively"] .sum .c-done{color:var(--done)}
[data-style="lively"] .sec>h3 .n{background:var(--you-bg);color:var(--you);border-color:transparent}
[data-style="lively"] .call.open{border-color:var(--you);box-shadow:0 0 0 3px var(--you-bg)}
[data-style="lively"] .call.fin.open{border-color:var(--done);box-shadow:0 0 0 3px var(--done-bg)}
[data-style="lively"] .confirm,[data-style="lively"] .talk{border:1.5px solid var(--here)}
[data-style="lively"] .seg button[aria-pressed="true"],[data-style="lively"] .side-switch button[aria-pressed="true"]{background:var(--ink);color:var(--bg)}
[data-style="lively"] .job .job-top .dot.work{animation:glow 2s infinite ease-in-out}
@keyframes glow{50%{box-shadow:0 0 0 .31rem rgba(230,169,58,.25)}}
[data-style="lively"] .worker.sel{border-color:var(--here);box-shadow:0 0 0 3px var(--here-bg)}

@media (max-width:61rem){
.app{height:auto;min-height:100dvh}
.main{display:block;padding:.75rem}
.pane{overflow:visible}
.pane+.pane{margin-top:.75rem}
#log,.p-body{overflow:visible}
.side-switch{display:flex;margin:.75rem .75rem 0;border:1px solid var(--line);border-radius:.75rem;overflow:hidden;background:var(--surface)}
.side-switch button{flex:1;border:0;background:none;padding:.56rem;font-size:.94rem;color:var(--ink-2)}
.side-switch button[aria-pressed="true"]{background:var(--here-bg);color:var(--ink);font-weight:600}
.main[data-side="chat"] #panelPane,.main[data-side="projects"] #chatPane{display:none}
.bridge{margin:0 .75rem;padding:.75rem .875rem;gap:.625rem 1rem}
.lamps{padding-left:0;border-left:0;width:100%}
.sides{margin-left:0}
.urgent{flex-wrap:wrap}
.urgent .t{white-space:normal;flex-basis:60%}
.toprow{padding-inline:.75rem}
.gear span{display:none}
#compose{position:sticky;bottom:0;border-radius:0 0 1rem 1rem}
.settings{right:.75rem}
}
@media (max-width:32rem){
.call-body{padding-left:.875rem}
.steps li{font-size:.75rem}
}
@media (prefers-reduced-motion:reduce){*,*::before,*::after{animation:none!important;transition:none!important}}
[data-motion="less"] *,[data-motion="less"] *::before,[data-motion="less"] *::after{animation:none!important;transition:none!important}
"""

# The settings are a script of their own so they can be run without a browser.
SETTINGS_JS = r"""
/* The page's settings: how they are kept in this browser and put on the page.
   Kept apart from the page's own script so they can be run on their own. */
(function (root) {
  'use strict';
  var KEY = 'fm-web-settings';
  /* Text size steps, as a percentage of the browser's own size. */
  var TEXT_STEPS = [87.5, 100, 112.5, 125, 150];
  var TEXT_NAMES = ['Small', 'Normal', 'Large', 'Larger', 'Largest'];
  var DEFAULTS = { text: 1, style: 'calm', theme: 'auto', motion: 'auto' };
  var CHOICES = { style: ['calm', 'lively'], theme: ['auto', 'light', 'dark'], motion: ['auto', 'less'] };

  /* Whatever comes in, a whole and valid set of settings comes out. */
  function clean(given) {
    var out = { text: DEFAULTS.text, style: DEFAULTS.style, theme: DEFAULTS.theme, motion: DEFAULTS.motion };
    if (!given || typeof given !== 'object') return out;
    if (typeof given.text === 'number' && given.text === Math.floor(given.text) &&
        given.text >= 0 && given.text < TEXT_STEPS.length) out.text = given.text;
    Object.keys(CHOICES).forEach(function (name) {
      if (CHOICES[name].indexOf(given[name]) >= 0) out[name] = given[name];
    });
    return out;
  }

  /* A browser that blocks storage, or holds something unreadable, gets the defaults. */
  function load(storage) {
    try {
      return clean(JSON.parse(storage.getItem(KEY)));
    } catch (error) {
      return clean(null);
    }
  }

  function save(storage, settings) {
    var kept = clean(settings);
    try {
      storage.setItem(KEY, JSON.stringify(kept));
    } catch (error) { /* shown for this visit only */ }
    return kept;
  }

  /* Put the settings on the page's root element; the stylesheet does the rest. */
  function apply(element, settings) {
    var kept = clean(settings);
    element.style.fontSize = TEXT_STEPS[kept.text] + '%';
    element.setAttribute('data-style', kept.style);
    element.setAttribute('data-theme', kept.theme);
    element.setAttribute('data-motion', kept.motion);
    return kept;
  }

  var api = { KEY: KEY, TEXT_STEPS: TEXT_STEPS, TEXT_NAMES: TEXT_NAMES, DEFAULTS: DEFAULTS,
              clean: clean, load: load, save: save, apply: apply };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.FMSettings = api;
})(typeof window !== 'undefined' ? window : this);
"""

PAGE_JS = r"""
(function(){
'use strict';
const CSRF=document.body.dataset.csrf;
const $=id=>document.getElementById(id);
const log=$('log'),wrap=$('items'),input=$('input'),sendBtn=$('send'),thumbs=$('thumbs'),result=$('result'),stateEl=$('state');
let version='',images=[],sending=false;

function el(tag,cls,text){const e=document.createElement(tag);if(cls)e.className=cls;
  if(text!==undefined)e.textContent=text;return e;}
function add(parent){for(let i=1;i<arguments.length;i++){if(arguments[i])parent.appendChild(arguments[i]);}return parent;}
function btn(cls,text,act,data){const b=el('button',cls,text);b.type='button';b.dataset.act=act;
  for(const k in (data||{})){if(data[k]!=null)b.dataset[k]=data[k];}return b;}
const NS='http://www.w3.org/2000/svg';
const ICONS={
  star:'M8 1.8l1.7 4.1 4.4.4-3.3 2.9 1 4.3L8 11.2l-3.8 2.3 1-4.3-3.3-2.9 4.4-.4z',
  sliders:'M2 5h7M12 5h2M2 11h2M7 11h7M10.5 3.5v3M5.5 9.5v3',
  check:'M3.5 8.5l3 3 6-7',
  moon:'M13 9.5A5.5 5.5 0 0 1 6.5 3a5.5 5.5 0 1 0 6.5 6.5z',
  battery:'M2 5.5h10v5H2zM13.5 7v2',
  close:'M4 4l8 8M12 4l-8 8'};
function icon(name){const s=document.createElementNS(NS,'svg');s.setAttribute('viewBox','0 0 16 16');
  s.setAttribute('aria-hidden','true');const p=document.createElementNS(NS,'path');p.setAttribute('d',ICONS[name]);
  p.setAttribute('fill','none');p.setAttribute('stroke','currentColor');p.setAttribute('stroke-width','1.6');
  p.setAttribute('stroke-linecap','round');p.setAttribute('stroke-linejoin','round');s.appendChild(p);return s;}

/* ---- the first mate's conversation ---- */
function atBottom(){return log.scrollHeight-log.scrollTop-log.clientHeight<80;}
function quiet(item,label,name){
  const d=el('details','quiet'+(item.error?' err':''));d.dataset.id=item.id;
  const s=el('summary');s.appendChild(el('span','name',name));
  if(label){s.appendChild(document.createTextNode(': '+label));}
  d.appendChild(s);return d;
}
function render(items){
  const open=new Set(Array.from(wrap.querySelectorAll('details[open]')).map(d=>d.dataset.id));
  const stick=atBottom();
  const frag=document.createDocumentFragment();
  for(const item of items){
    if(item.kind==='user'||item.kind==='assistant'){
      const row=el('div','msg '+item.kind);const b=el('div','bubble');
      if(item.kind==='assistant'){const av=el('div','av');av.appendChild(icon('star'));row.appendChild(av);}
      b.innerHTML=item.html||'';
      if(item.images){b.appendChild(el('div','chip',item.images===1?'1 image':item.images+' images'));}
      row.appendChild(b);frag.appendChild(row);
    }else if(item.kind==='tool'){
      const label=item.pending?(item.summary?item.summary+' …':'running…'):item.summary;
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
  stateEl.querySelector('.label').textContent=state==='busy'?'Working':state==='idle'?'Ready':'Not running';
}
async function poll(){
  try{
    const r=await fetch('/api/conversation?since='+encodeURIComponent(version),{credentials:'same-origin'});
    if(r.ok){
      const data=await r.json();
      setState(data.state||'offline');
      if(!data.unchanged){
        version=data.version||'';
        render(data.items||[]);
        $('note').textContent=data.note||'';
        $('older').hidden=!data.older;
      }
    }
  }catch(e){setState('offline');}
  setTimeout(poll,document.hidden?6000:1500);
}
function addImage(file){
  if(!file||!/^image\/(png|jpeg|gif|webp)$/.test(file.type))return;
  const reader=new FileReader();
  reader.onload=()=>{images.push(reader.result);drawThumbs();};
  reader.readAsDataURL(file);
}
function drawThumbs(){
  thumbs.replaceChildren();
  images.forEach((src,i)=>{const t=el('div','thumb');const img=el('img');img.src=src;img.alt='attached image';
    const x=el('button','','×');x.title='Remove';x.addEventListener('click',()=>{images.splice(i,1);drawThumbs();});
    t.appendChild(img);t.appendChild(x);thumbs.appendChild(t);});
}
async function send(){
  const text=input.value.trim();
  if(sending||(!text&&!images.length))return;
  sending=true;sendBtn.disabled=true;result.className='';result.textContent='Sending…';
  try{
    const r=await fetch('/api/send',{method:'POST',credentials:'same-origin',
      headers:{'Content-Type':'application/json','X-FM-CSRF':CSRF},body:JSON.stringify({text:text,images:images})});
    let data={};try{data=await r.json();}catch(e){}
    if(r.ok){input.value='';images=[];drawThumbs();autosize();result.textContent=data.detail||'Sent.';}
    else{result.className='failed';result.textContent=data.detail||('Not sent ('+r.status+')');}
  }catch(e){result.className='failed';result.textContent='Not sent: the page lost its connection.';}
  sending=false;sendBtn.disabled=false;input.focus();
}
function autosize(){input.style.height='auto';input.style.height=input.scrollHeight+'px';}
input.addEventListener('input',autosize);
input.addEventListener('keydown',e=>{if(e.key==='Enter'&&!e.shiftKey&&!e.isComposing){e.preventDefault();send();}});
sendBtn.addEventListener('click',send);
input.addEventListener('paste',e=>{for(const item of (e.clipboardData||{}).items||[]){
  if(item.kind==='file'){const f=item.getAsFile();if(f&&f.type.startsWith('image/')){e.preventDefault();addImage(f);}}}});
document.addEventListener('dragover',e=>{e.preventDefault();document.body.classList.add('drag');});
document.addEventListener('dragleave',e=>{if(!e.relatedTarget)document.body.classList.remove('drag');});
document.addEventListener('drop',e=>{e.preventDefault();document.body.classList.remove('drag');
  for(const f of (e.dataTransfer||{}).files||[])addImage(f);});

/* ---- the projects: what the Factory pane and the bridge strip show ---- */
let M=null,mver='',mirrorError='';
let tab=decodeURIComponent(location.hash.slice(1))||'home';
let openCall=null,chose=false,confirming=null,talk=null,notice=null,noticeTimer=0,acting=false,selWorker=null;
const sent={},asked={};  /* answers and re-checks this page sent that the record does not show yet */

function project(id){return M.projects.find(p=>p.id===id)||null;}
function need(id){return M.needs.find(n=>n.id===id)||null;}
function say(ok,text){
  notice=text?{kind:ok?'ok':'bad',text:text}:null;
  clearTimeout(noticeTimer);
  if(notice)noticeTimer=setTimeout(()=>{notice=null;draw();},20000);
}
function steps(job,cls){
  const ol=el('ol',cls||'steps');
  M.steps.forEach((name,i)=>{const li=el('li',i<job.step?'done':i===job.step?'now':'');
    if(i<job.step)li.appendChild(icon('check'));li.appendChild(document.createTextNode(name));ol.appendChild(li);});
  return ol;
}
function steerSwitch(p){
  const box=el('div','steer');box.appendChild(el('span','','Who steers'));
  const seg=el('div','seg');
  const a=btn('','Starship','steer',{factory:p.id,who:'Starship'});a.setAttribute('aria-pressed',String(!p.you_steer));
  const b=btn('','You','steer',{factory:p.id,who:'you'});b.setAttribute('aria-pressed',String(p.you_steer));
  a.disabled=b.disabled=acting;
  add(seg,a,b);box.appendChild(seg);return box;
}
function talkBox(head){
  const box=el('div','talk');
  box.appendChild(el('p','talk-head',head));
  const area=el('textarea');area.id='talkText';area.rows=3;area.value=talk.text||'';
  area.setAttribute('aria-label',head);area.placeholder='Type what you want to say';
  box.appendChild(area);
  box.appendChild(el('p','unsent','Not sent yet.'));
  const row=el('div','rowb');
  const go=btn('btn primary','Send to Starship','talksend');go.disabled=acting;
  add(row,go,btn('btn','Cancel','cancel'));box.appendChild(row);return box;
}
function callCard(n){
  const open=openCall===n.id;
  const mine=sent[n.id];
  const answered=n.answered||(mine&&mine.asking===n.asking?mine:null);
  const card=el('div','call'+(open?' open':'')+(n.question?'':' fin'));card.dataset.call=n.id;
  const row=btn('call-row','','open',{id:n.id});row.setAttribute('aria-expanded',String(open));
  row.appendChild(el('span','dot '+(n.question?'you':'done')));
  row.appendChild(el('span','call-title',n.ask));
  const meta=el('span','call-meta');
  meta.appendChild(el('span','',n.project_name+(n.mate?', from '+n.mate:'')));
  const checking=n.checking||asked[n.id]===n.asking;
  meta.appendChild(el('span','',checking?'checking':n.waited));
  row.appendChild(meta);card.appendChild(row);
  if(!open)return card;
  const body=el('div','call-body');
  if(n.why)body.appendChild(el('p','why',n.why));
  if(checking)body.appendChild(el('p','said','Starship is re-reading what you said about this.'));
  if(answered){
    const option=n.options.find(o=>o.key===answered.key);
    body.appendChild(el('p','said',(option?'You answered: '+option.label+'.':n.question?'You answered.':'You asked to keep it.')
      +' Waiting for Starship to act on it.'));
  }
  const pending=confirming&&confirming.item===n.id?confirming:null;
  if(n.question&&n.options.length){
    const opts=el('div','opts');
    n.options.forEach(o=>{
      const picked=(pending&&pending.option===o.key)||(!pending&&answered&&answered.key===o.key);
      const b=btn('opt'+(picked?' picked':''),'','pick',{id:n.id,option:o.key});
      b.appendChild(el('span','ring'));b.appendChild(el('span','l',o.label));
      if(o.suggested)b.appendChild(el('span','tag','Suggested by '+n.suggested_by));
      b.disabled=acting;opts.appendChild(b);
    });
    body.appendChild(opts);
  }
  if(n.recommendation&&!n.options.some(o=>o.suggested)){
    body.appendChild(el('p','holds','Suggested by '+n.suggested_by+': '+n.recommendation));
  }
  if(pending){
    const box=el('div','confirm');
    const option=n.options.find(o=>o.key===pending.option);
    box.appendChild(el('p','',pending.keep?'Keep this and ask Starship to make it live?':'Send this answer: '+(option?option.label:'')+'?'));
    box.appendChild(el('p','unsent','Not sent yet.'));
    const rowb=el('div','rowb');
    const go=btn('btn primary','Send to Starship','send');go.disabled=acting;
    add(rowb,go,btn('btn','Cancel','cancel'));box.appendChild(rowb);body.appendChild(box);
  }
  if(n.holds_up.length)body.appendChild(el('p','holds','Holds up: '+n.holds_up.join(', ')));
  if(n.pr){const p=el('p','holds');const a=el('a','','See what changed');a.href=n.pr;a.target='_blank';
    a.rel='noopener noreferrer';p.appendChild(a);body.appendChild(p);}
  const mineTalk=talk&&talk.item===n.id;
  const acts=el('div','rowb');
  if(!n.question){
    const keep=btn('btn primary','Keep it','keep',{id:n.id});keep.disabled=acting||!!pending;acts.appendChild(keep);
    acts.appendChild(btn('btn','Ask for changes','talk',{kind:'change',id:n.id}));
  }else{
    acts.appendChild(btn('btn','Talk it through','talk',{kind:'discuss',id:n.id}));
    if(!checking){const x=btn('btn','This is already settled','settled',{id:n.id});x.disabled=acting;acts.appendChild(x);}
  }
  if(n.read)acts.appendChild(btn('btn plain','Read the report','read',{id:n.id}));
  body.appendChild(acts);
  if(mineTalk)body.appendChild(talkBox(talk.kind==='change'?'What should change?':'Talk it through'));
  card.appendChild(body);return card;
}
function jobCard(job,p,watch){
  const card=el('div','job');
  const top=el('div','job-top');
  add(top,el('span','dot work'),el('span','job-title',job.title),job.elapsed?el('span','mins',job.elapsed):null);
  card.appendChild(top);card.appendChild(steps(job));
  const foot=el('div','job-foot');
  foot.appendChild(el('span','doing'+(job.quiet?' quiet':''),job.words));
  if(job.read)foot.appendChild(btn('btn small plain','Read the report','read',{factory:p.id,job:job.id}));
  if(watch)foot.appendChild(btn('btn small plain','Watch this worker','watch',{factory:p.id,job:job.id}));
  card.appendChild(foot);return card;
}
function jobLine(job,p){
  const line=el('div','jobline');
  add(line,el('span','dot '+job.mark),el('span','t',job.title),el('span','w '+job.mark,job.words));
  if(job.read)line.appendChild(btn('btn small plain','Read the report','read',{factory:p.id,job:job.id}));
  return line;
}
function feedList(feed,named){
  const ul=el('ul','feed');
  feed.events.slice().reverse().forEach(e=>{
    const li=el('li');li.appendChild(el('time','',e.when));
    const d=el('div');
    if(named)d.appendChild(el('span','who',e.actor));
    d.appendChild(el('span','word '+e.mark,e.word));
    d.appendChild(document.createTextNode(e.text));
    li.appendChild(d);ul.appendChild(li);
  });
  return ul;
}
function section(title,count,small){
  const sec=el('section','sec');const h=el('h3','',title);
  if(count!=null)h.appendChild(el('span','n',String(count)));
  if(small)h.appendChild(el('small','',small));
  sec.appendChild(h);return sec;
}
function feedSection(feed,named){
  const comma=feed.title.indexOf(', ');
  const sec=section(comma<0?feed.title:feed.title.slice(0,comma),null,comma<0?'':feed.title.slice(comma+2));
  sec.appendChild(feed.events.length?feedList(feed,named):el('p','empty','Nothing new.'));
  return sec;
}

function drawTabs(){
  const tabs=$('tabs');
  const list=[{id:'home',name:'Control Centre'}].concat(M.projects.map(p=>({id:p.id,name:p.name,needs:p.page.needs.length})));
  tabs.replaceChildren();
  list.forEach(t=>{const b=btn('tab',t.name,'tab',{id:t.id});b.setAttribute('role','tab');
    b.setAttribute('aria-selected',String(t.id===tab));
    if(t.needs){b.title=t.needs===1?'1 thing needs you':t.needs+' things need you';
      b.appendChild(el('span','dot you'));}
    tabs.appendChild(b);});
}
function drawBand(){
  const band=M.band,box=$('bridge');
  const brand=el('div','brand');add(brand,icon('star'),el('span','','Starship'));
  const lamps=el('div','lamps');
  band.lamps.forEach(l=>{const d=el('div','lamp '+l.mark+(l.count?' lit':''));
    add(d,el('i'),el('b','',String(l.count)),el('span','',l.words));lamps.appendChild(d);});
  if(band.note)lamps.appendChild(el('span','band-note',band.note));
  let urgent;
  if(band.call){
    urgent=btn('urgent','','call',{id:band.call.id});
    add(urgent,el('span','k',band.call.question?'Most urgent, decide':'Most urgent, ready for your OK'),
      el('span','t',band.call.title),el('span','go','Open'));
  }else{urgent=el('div','urgent none',band.lamps.length?'Nothing needs you right now.':'');}
  const sides=el('div','sides');
  if(band.alert){const a=el('span','alert');add(a,el('i'),el('span','',band.alert));sides.appendChild(a);}
  if(band.night){const n=el('span','aside'+(band.night_done?' good':''));add(n,icon('moon'),el('span','',band.night));sides.appendChild(n);}
  if(band.battery){const b=el('span','aside'+(band.battery_mark?' '+band.battery_mark:''));
    add(b,icon('battery'),el('span','',band.battery));sides.appendChild(b);}
  box.replaceChildren(brand,lamps,urgent,sides);
}
function drawTop(){
  const top=$('ptop');top.replaceChildren();
  const sum=el('p','sum');
  M.summary.forEach((s,i)=>{if(i)sum.appendChild(document.createTextNode(', '));
    sum.appendChild(el(s.mark?'b':'span',s.mark?'c-'+s.mark:'',s.words));});
  top.appendChild(sum);
  if(M.queue.length)top.appendChild(el('p','queue',M.queue.join(', ')));
  if(mirrorError)top.appendChild(el('p','notice bad',mirrorError));
  if(notice){const n=el('p','notice '+notice.kind,notice.text);n.setAttribute('role','status');top.appendChild(n);}
}
function drawHome(){
  $('clock').textContent=M.clock;
  drawTop();
  const body=$('pbody');
  const needs=section('Needs you',M.needs.length);
  if(M.needs.length)M.needs.forEach(n=>needs.appendChild(callCard(n)));
  else needs.appendChild(el('p','empty','Nothing needs you right now.'));
  const now=section('Right now');
  M.projects.forEach(p=>{
    const box=el('div','proj');
    const head=el('div','proj-head');
    add(head,btn('proj-name',p.name,'tab',{id:p.id}),el('span','proj-q',p.queue.join(', ')),steerSwitch(p));
    box.appendChild(head);
    p.jobs.forEach(job=>box.appendChild(job.busy?jobCard(job,p,true):jobLine(job,p)));
    p.routine.forEach(r=>{const line=el('p','line');
      add(line,el('b','',r.kind),el('span','',r.words.join(', ')),r.now?el('span','r',r.now):null);box.appendChild(line);});
    if(p.next){const line=el('p','line');
      add(line,el('span','',p.next.once_you_answer?'Next, once you answer:':'Next:'),el('b','',p.next.title),
        p.next.then?el('span','','then '+p.next.then+' more'):null);box.appendChild(line);}
    now.appendChild(box);
  });
  if(!M.projects.length)now.appendChild(el('p','empty','No projects yet. Ask your first mate to add one.'));
  body.replaceChildren(needs,now,feedSection(M.feed,true));
}
function drawProject(p){
  const head=$('ppHead');
  const row=el('div','rowb');
  add(row,steerSwitch(p),btn('btn','Talk to this crew','talk',{kind:'talk',factory:p.id}));
  head.replaceChildren(el('h2','',p.name),el('p','',p.about),row);
  if(talk&&talk.kind==='talk'&&talk.factory===p.id)head.appendChild(talkBox('Talk to the '+p.name+' crew'));
  if(notice){const n=el('p','notice '+notice.kind,notice.text);n.setAttribute('role','status');head.appendChild(n);}
  const parts=[];
  const mine=M.needs.filter(n=>n.project===p.id);
  if(mine.length){const s=section('Needs you',mine.length);mine.forEach(n=>s.appendChild(callCard(n)));parts.push(s);}
  const work=section('Work',null,p.page.queue.join(', '));
  p.page.jobs.forEach(job=>work.appendChild(job.busy?jobCard(job,p,false):jobLine(job,p)));
  p.page.folded.forEach(group=>{
    const d=el('details','quiet');d.dataset.fold=group.words;d.appendChild(el('summary','',group.words));
    const ul=el('ul','list');
    group.jobs.forEach(j=>{const li=el('li');add(li,el('span','',j.title),el('span','w',j.queue));ul.appendChild(li);});
    d.appendChild(ul);work.appendChild(d);
  });
  if(!p.page.jobs.length&&!p.page.folded.length)work.appendChild(el('p','empty','Nothing under way here.'));
  parts.push(work);
  if(p.page.rules.length){
    const s=section('How this crew works');const ul=el('ul','bul');
    p.page.rules.forEach(r=>ul.appendChild(el('li','',r)));s.appendChild(ul);
    if(p.page.rules_size)s.appendChild(el('p','all'+(p.page.rules_mark==='over'?' warn':p.page.rules_mark==='near'?' near':''),p.page.rules_size));
    parts.push(s);
  }
  if(p.page.learned.length){
    const s=section('What it has learned');const ul=el('ul','bul');
    p.page.learned.forEach(l=>{const li=el('li');if(l.when)li.appendChild(el('time','',l.when));
      li.appendChild(document.createTextNode(l.what));ul.appendChild(li);});
    s.appendChild(ul);parts.push(s);
  }
  if(p.page.talk.length){
    const s=section('Talk');const ul=el('ul','feed');
    p.page.talk.forEach(t=>{const li=el('li');li.appendChild(el('time','',t.when));
      const d=el('div');d.appendChild(el('span','who',t.who+': '));d.appendChild(document.createTextNode(t.said));
      li.appendChild(d);ul.appendChild(li);});
    s.appendChild(ul);parts.push(s);
  }
  parts.push(feedSection(p.page.feed,false));
  const open=new Set(Array.from($('ppBody').querySelectorAll('details[open]')).map(d=>d.dataset.fold));
  $('ppBody').replaceChildren.apply($('ppBody'),parts);
  $('ppBody').querySelectorAll('details').forEach(d=>{if(open.has(d.dataset.fold))d.open=true;});
  const workers=$('workers');workers.replaceChildren();
  $('workersCount').textContent=p.page.workers.length?String(p.page.workers.length):'';
  p.page.workers.forEach(job=>{
    const card=el('div','worker'+(selWorker===job.id?' sel':''));card.dataset.worker=job.id;
    const h=el('h4','',job.title);if(job.elapsed)h.appendChild(el('span','',job.elapsed));
    card.appendChild(h);
    if(job.busy)card.appendChild(steps(job));
    card.appendChild(el('p','doing'+(job.quiet?' quiet':''),job.words));
    if(job.read){const r=el('div','rowb');r.appendChild(btn('btn small plain','Read the report','read',{factory:p.id,job:job.id}));card.appendChild(r);}
    workers.appendChild(card);
  });
  if(!p.page.workers.length)workers.appendChild(el('p','empty','No one is working here right now.'));
}
function draw(){
  if(!M)return;
  if(tab!=='home'&&!project(tab))tab='home';
  if(!chose&&(!openCall||!need(openCall)))openCall=M.needs.length?M.needs[0].id:null;
  if(confirming&&!need(confirming.item))confirming=null;
  if(talk&&talk.item&&!need(talk.item))talk=null;
  const active=document.activeElement&&document.activeElement.id==='talkText'?document.activeElement:null;
  const caret=active?[active.selectionStart,active.selectionEnd]:null;
  drawTabs();drawBand();
  $('home').hidden=tab!=='home';$('project').hidden=tab==='home';$('sideSwitch').hidden=tab!=='home';
  if(tab==='home')drawHome();else drawProject(project(tab));
  if(caret){const area=$('talkText');if(area){area.focus();area.setSelectionRange(caret[0],caret[1]);}}
}
function show(id,flash){
  tab='home';openCall=id;chose=true;setSide('projects');draw();
  const card=document.querySelector('[data-call="'+CSS.escape(id)+'"]');
  if(card){card.scrollIntoView({block:'nearest'});if(flash){card.classList.add('flash');}}
}
function setSide(side){
  $('home').dataset.side=side;
  $('sideSwitch').querySelectorAll('button').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.side===side)));
}
async function act(ask){
  if(acting)return null;
  acting=true;draw();
  let answer={ok:false,said:'Not sent: the page lost its connection.'};
  try{
    const r=await fetch('/api/act',{method:'POST',credentials:'same-origin',
      headers:{'Content-Type':'application/json','X-FM-CSRF':CSRF},body:JSON.stringify(ask)});
    try{answer=await r.json();}catch(e){answer={ok:false,said:'Not sent ('+r.status+').'};}
  }catch(e){}
  acting=false;
  say(answer.ok,answer.said);
  return answer;
}
async function mirror(once){
  try{
    const r=await fetch('/api/mirror?since='+encodeURIComponent(mver),{credentials:'same-origin'});
    const data=await r.json();
    if(r.ok){
      const was=mirrorError;mirrorError='';
      if(data.unchanged){if(M&&M.clock!==data.clock){M.clock=data.clock;$('clock').textContent=data.clock;}if(was)draw();}
      else{M=data.model;mver=data.version;draw();}
    }else{mirrorError=data.error||'The projects could not be read.';if(M)draw();else $('ptop').replaceChildren(el('p','notice bad',mirrorError));}
  }catch(e){mirrorError='The page lost its connection.';if(M)draw();}
  if(!once)setTimeout(mirror,document.hidden?20000:3000);
}
document.addEventListener('click',async e=>{
  const b=e.target.closest('[data-act]');if(!b||b.disabled)return;
  const d=b.dataset;let answer=null;
  switch(d.act){
    case 'tab':tab=d.id;selWorker=null;if(talk&&talk.kind==='talk')talk=null;
      history.replaceState(null,'',tab==='home'?location.pathname:'#'+encodeURIComponent(tab));draw();return;
    case 'call':if(need(d.id))show(d.id,true);else{tab='home';setSide('projects');draw();}return;
    case 'open':chose=true;openCall=openCall===d.id?null:d.id;confirming=null;if(talk&&talk.item)talk=null;draw();return;
    case 'pick':confirming={item:d.id,option:d.option};draw();return;
    case 'keep':confirming={item:d.id,keep:true};draw();return;
    case 'cancel':confirming=null;talk=null;say(true,'');draw();return;
    case 'talk':confirming=null;talk=d.kind==='talk'?{kind:'talk',factory:d.factory,text:''}:{kind:d.kind,item:d.id,text:''};
      draw();{const area=$('talkText');if(area)area.focus();}return;
    case 'watch':tab=d.factory;selWorker=d.job;draw();
      {const card=document.querySelector('[data-worker="'+CSS.escape(d.job)+'"]');if(card)card.scrollIntoView({block:'nearest'});}return;
    case 'send':{
      const c=confirming;const n=c&&need(c.item);if(!n)return;
      answer=await act(c.keep?{action:'keep',item:n.id,asking:n.asking}:{action:'answer',item:n.id,asking:n.asking,option:c.option});
      if(answer&&answer.ok){sent[n.id]={asking:n.asking,key:c.keep?null:c.option};confirming=null;}
      break;}
    case 'talksend':{
      const t=talk;const text=((($('talkText')||{}).value)||'').trim();if(!t)return;
      if(!text){say(false,'Nothing to send yet: type what you want to say first.');draw();return;}
      const n=t.item&&need(t.item);
      answer=await act(t.kind==='talk'?{action:'talk',factory:t.factory,text:text}
        :{action:t.kind,item:t.item,asking:n?n.asking:undefined,text:text});
      if(answer&&answer.ok)talk=null;
      break;}
    case 'settled':{const n=need(d.id);if(!n)return;answer=await act({action:'settled',item:n.id,asking:n.asking});
      if(answer&&answer.ok)asked[n.id]=n.asking;break;}
    case 'steer':answer=await act({action:'steer',factory:d.factory,who:d.who});break;
    case 'read':answer=await act(d.id?{action:'read',item:d.id}:{action:'read',factory:d.factory,job:d.job});break;
    default:return;
  }
  draw();
  if(answer)mirror(true);
});
document.addEventListener('input',e=>{if(e.target.id==='talkText'&&talk)talk.text=e.target.value;});
document.addEventListener('keydown',e=>{
  if(e.target.id==='talkText'&&e.key==='Enter'&&(e.metaKey||e.ctrlKey)){e.preventDefault();
    const go=document.querySelector('[data-act="talksend"]');if(go)go.click();}
  if(e.key==='Escape'){if(!$('settings').hidden){closeSettings();}else if(confirming||talk){confirming=null;talk=null;draw();}}
});
$('sideSwitch').addEventListener('click',e=>{const b=e.target.closest('button');if(b)setSide(b.dataset.side);});

/* ---- settings ---- */
const FS=window.FMSettings;
let storage=null;try{storage=window.localStorage;}catch(e){}
let settings=FS.load(storage);
function drawSettings(){
  $('textSize').max=String(FS.TEXT_STEPS.length-1);$('textSize').value=String(settings.text);
  $('textNow').textContent=FS.TEXT_NAMES[settings.text];
  document.querySelectorAll('#settings [data-set]').forEach(b=>b.setAttribute('aria-pressed',String(settings[b.dataset.set]===b.dataset.value)));
  $('lessMotion').checked=settings.motion==='less';
}
function change(name,value){
  const next={text:settings.text,style:settings.style,theme:settings.theme,motion:settings.motion};
  next[name]=value;settings=FS.apply(document.documentElement,FS.save(storage,next));drawSettings();autosize();
}
function closeSettings(){$('settings').hidden=true;$('gear').setAttribute('aria-expanded','false');$('gear').focus();}
$('gear').addEventListener('click',()=>{const panel=$('settings');panel.hidden=!panel.hidden;
  $('gear').setAttribute('aria-expanded',String(!panel.hidden));if(!panel.hidden){drawSettings();$('textSize').focus();}});
$('settingsClose').addEventListener('click',closeSettings);
$('textSize').addEventListener('input',e=>change('text',Number(e.target.value)));
$('lessMotion').addEventListener('change',e=>change('motion',e.target.checked?'less':'auto'));
$('settings').addEventListener('click',e=>{const b=e.target.closest('[data-set]');if(b)change(b.dataset.set,b.dataset.value);});
document.addEventListener('click',e=>{if(!$('settings').hidden&&!e.target.closest('#settings')&&!e.target.closest('#gear'))closeSettings();});
$('gear').prepend(icon('sliders'));$('settingsClose').appendChild(icon('close'));
drawSettings();

setSide('projects');poll();mirror();
})();
"""


def page_html(nonce: str, csrf: str) -> str:
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Starship</title>
<link rel="icon" href="data:,">
<style nonce="{nonce}">{PAGE_CSS}</style>
<script nonce="{nonce}" src="/settings.js"></script>
<script nonce="{nonce}">(function(){{var s=null;try{{s=window.localStorage;}}catch(e){{}}
FMSettings.apply(document.documentElement,FMSettings.load(s));}})();</script>
</head>
<body data-csrf="{html.escape(csrf, quote=True)}">
<div class="app">
<div class="toprow"><nav class="tabs" id="tabs" role="tablist" aria-label="Projects"></nav>
<button class="gear" id="gear" type="button" aria-expanded="false" aria-controls="settings"><span>Settings</span></button></div>
<header class="bridge" id="bridge"><div class="brand"><span>Starship</span></div>
<div class="lamps"><span class="band-note">reading the crew</span></div></header>
<div class="side-switch" id="sideSwitch"><button type="button" data-side="chat">First mate</button>
<button type="button" data-side="projects">All projects</button></div>
<main class="main" id="home" data-side="projects">
<section class="pane" id="chatPane" aria-label="First mate">
<div class="pane-head"><h2>First mate</h2>
<span id="state" class="state offline"><span class="label">Connecting</span></span></div>
<div id="log"><div class="wrap">
<p id="older" class="note" hidden>Earlier conversation is in the terminal history.</p>
<div id="items"></div><p id="note" class="note"></p></div></div>
<div id="compose"><div class="wrap">
<div id="thumbs"></div>
<div id="row"><textarea id="input" rows="1" placeholder="Message the first mate" aria-label="Message"></textarea>
<button id="send" class="btn primary" type="button">Send</button></div>
<div id="result" role="status"></div>
</div></div>
</section>
<section class="pane" id="panelPane" aria-label="All projects">
<div class="pane-head"><h2>All projects</h2><span class="when" id="clock"></span></div>
<div class="p-top" id="ptop"><p class="sum">reading the crew</p></div>
<div class="p-body" id="pbody"></div>
</section>
</main>
<main class="main" id="project" hidden>
<section class="pane" aria-label="Project"><div class="pp-head" id="ppHead"></div><div class="p-body" id="ppBody"></div></section>
<section class="pane" aria-label="Workers at work">
<div class="pane-head"><h2>Workers at work</h2><span class="state" id="workersCount"></span></div>
<div class="p-body" id="workers"></div></section>
</main>
</div>
<section class="settings" id="settings" aria-label="Settings" hidden>
<h2>Settings<button class="btn small plain" id="settingsClose" type="button" aria-label="Close settings"></button></h2>
<div class="set"><label for="textSize">Text size<span class="now" id="textNow"></span></label>
<div class="size-row"><span class="a s" aria-hidden="true">A</span>
<input id="textSize" type="range" min="0" max="4" step="1">
<span class="a l" aria-hidden="true">A</span></div>
<p class="hint">Everything on the page grows or shrinks with it.</p></div>
<div class="set"><div class="lbl">Style</div>
<div class="seg"><button type="button" data-set="style" data-value="calm">Calm</button>
<button type="button" data-set="style" data-value="lively">Lively</button></div>
<p class="hint">Calm is quiet. Lively uses stronger colours.</p></div>
<div class="set"><div class="lbl">Light or dark</div>
<div class="seg"><button type="button" data-set="theme" data-value="auto">Auto</button>
<button type="button" data-set="theme" data-value="light">Light</button>
<button type="button" data-set="theme" data-value="dark">Dark</button></div>
<p class="hint">Auto follows this computer.</p></div>
<div class="set"><div class="lbl">Movement</div>
<label class="switch"><input id="lessMotion" type="checkbox">Reduce motion</label></div>
<p class="hint">Kept in this browser only.</p>
</section>
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


CONVERSATION_SCHEMA = "fm-web-conversation.v1"


def command_conversation(home: Path) -> None:
    """Print one read of <home>'s conversation as versioned JSON."""
    if not home.is_dir():
        fail(f"not a home directory: {home}")
    payload = TranscriptCache(home).get()
    document = {
        "schema": CONVERSATION_SCHEMA,
        "home": str(home),
        "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "session": payload.get("session"),
        "state": payload.get("state"),
        "note": payload.get("note", ""),
        "older": bool(payload.get("older")),
        "version": payload.get("version"),
        "items": payload.get("items", []),
    }
    json.dump(document, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")


def main(argv: Optional[List[str]] = None) -> None:
    parser = argparse.ArgumentParser(prog="fm-web.py")
    sub = parser.add_subparsers(dest="command", required=True)
    serve = sub.add_parser("serve")
    serve.add_argument("--home", required=True)
    serve.add_argument("--root", required=True)
    serve.add_argument("--port", type=int, default=DEFAULT_PORT)
    tok = sub.add_parser("token")
    tok.add_argument("--home", required=True)
    conv = sub.add_parser("conversation")
    conv.add_argument("--home", required=True)
    args = parser.parse_args(argv)
    if args.command == "serve":
        command_serve(Path(args.home), Path(args.root), args.port)
    elif args.command == "token":
        print(load_or_create_token(Path(args.home)))
    elif args.command == "conversation":
        command_conversation(Path(args.home))


if __name__ == "__main__":
    main()
