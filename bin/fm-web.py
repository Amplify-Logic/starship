#!/usr/bin/env python3
"""Firstmate web: the primary first mate's conversation in a localhost page.

The bind address is the literal LOOPBACK constant. There is no flag or
environment variable that widens it, and nothing here publishes it on a
tailnet.

Every request must carry the home's token: once as ?token= on the first
visit, or as a ?code= that `fm-web.py signin-code` made and that works once
within SIGNIN_CODE_SECONDS, either of which sets an HttpOnly SameSite=Strict
cookie and redirects to a clean URL, and as that cookie afterwards. The only
exceptions are the files that hold nothing private: the page's look and rules
(/settings.js, /view.js), its icons and its web app manifest, so a browser can
install the page as its own app; and the address itself, which without the
cookie shows a page saying what this is and how to get in. The Host header must name this loopback
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
followed. Only the tail is parsed. Text the machinery types into the chat (a
doorbell or operational input, NOTICE_RE) becomes a quiet notice, and the
pictures in the owner's messages (pasted images, and image paths) are served by
an opaque id at /api/picture/<id>, only while the shown conversation holds
them. The desk voice's "Screenshots:" paths and paths under its shots folder
are taken out of the words; any other image path stays as the owner wrote it.
A message the owner types while the first mate works waits in Claude Code's
own queue, which the transcript records as queue-operation entries before the
message is read in; the reading carries those still queued as `waiting`, shown
as faded bubbles, until the transcript shows each read in (Conversation's
_queue_operation and _delivered own the matching).
A file the first mate's reply names under the home's data/ or .lavish/ folder
is a link to /api/file/<home path>, served read-only in its own type
(home_file owns which files qualify); a page or drawing runs sandboxed.

Sending never types anywhere itself. Every message, with any pasted images
saved into state/desk-voice/shots/, goes through
`bin/fm-desk-voice.sh send --source web --stdin`, which types into the
primary's own chat only when that is safe and otherwise uses the durable
mailbox. The words go on standard input, never as one argument, so a long
paste is not refused by the 128 KiB single-argument limit on Linux.

While the first mate is ready, the conversation reading also carries the
suggested next prompt Claude shows in its empty chat box, read in the
background by `bin/fm-desk-voice.sh suggestion` (suggestion_reader), which types
nothing; the page shows it in its own empty message box and Tab fills it in.
The status row under that box is `bin/fm-status-bar.sh --replay --own`.

The server restarts itself in place when its own code on disk changes
(watch_code), so an update reaches a running page; every conversation reading
carries the code it runs as `build`, and the page reloads on a new one.

`fm-web.py conversation --home <home>` prints the same reading as one JSON
document (schema fm-web-conversation.v1), for another page that shows a
home's conversation without this server: the Deck reads every local crew home
this way. Its fields are schema, home, generated_at, session, state (busy,
idle or offline), since (when the turn under way began, while busy and known), note,
older, version, items and waiting (the owner's messages still queued), each
item exactly as the page receives it, so its html is already escaped and safe
to insert.

Beside the conversation the page mirrors the terminal workspace: the bridge
strip's band and the Factory pane's overview and factory pages, as tabs. It
reads both from the code on disk, `bin/fm-factory.py --screen` and
`bin/fm-bridge-strip.sh fields`, so it selects, counts and words nothing of
its own; mirror_model only lays them out and swaps the few terms docs/web.md
lists. A button on the page is one of the pane's writing keys: POST /api/act
hands the action to `bin/fm-factory.py act`, which sends the note that key
sends; a button on a project tab says `in_tab`, so it records no look, as a
key in a factory's tab does not. The page decides and merges nothing. This process never takes the
session lock, never drains wakes, and never writes backlog or fleet state.

The page's settings (text size, style, light or dark, colours, reduced
motion, key hints, panel sizes) live in the browser's own storage; SETTINGS_JS owns them
and is served as /settings.js. VIEW_JS, served as /view.js, owns the page's
plain rules: the chat folded into messages and one quiet line per run of
steps, links shown as short labels, and what each key does, which is always
the act of the button it stands for.
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
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple
from urllib.parse import parse_qs, quote, unquote, urlparse

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
SEND_TEXT_MAX = 200000
SEND_TIMEOUT_SECONDS = 90
SCREEN_SCHEMA = "fm-factory-screen.v1"
MIRROR_TTL_SECONDS = 2.0
MIRROR_TIMEOUT_SECONDS = 150
STRIP_TIMEOUT_SECONDS = 20
STATUS_ROW_TIMEOUT_SECONDS = 20
SUGGESTION_TTL_SECONDS = 2.0
SUGGESTION_TIMEOUT_SECONDS = 20
SUGGESTION_MAX = 2000
# The server's own code: a change on disk restarts it in place (watch_code).
CODE_PATH = Path(__file__).resolve()
CODE_CHECK_SECONDS = float(os.environ.get("FM_WEB_CODE_CHECK_SECONDS") or 2.0)
ANSI_RE = re.compile(r"\x1b\[([0-9;]*)m")
# The status bar's colours as the page's tones (docs/status-bar.md owns what
# each colour means); anything else is plain.
ANSI_TONES = {"92": "green", "93": "yellow", "91": "red", "91;1": "alarm", "95": "magenta", "96": "cyan",
              "2": "dim", "1": "bold"}
ACT_BODY_MAX = 32 * 1024
ACT_TEXT_MAX = 4000
ACT_TIMEOUT_SECONDS = 120
ACT_ACTIONS = ("answer", "keep", "change", "discuss", "talk", "settled", "steer", "read", "revive", "drop")
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
# What machinery types into the first mate's chat looks like the owner's own
# words in the transcript: a doorbell such as the desk voice's mailbox ring
# (bin/fm-desk-voice.sh) or the inbox's, and operational input, which starts
# with an invisible mark (bin/fm-operational-input.sh). The page shows those as
# quiet notices, never as the owner's messages.
NOTICE_RE = re.compile(r"^\s*(?:\u2063|\[firstmate ([a-z -]+)\]|: Firstmate operational input waiting)")
NOTICE_WORDS = {"desk-voice": "A message waited in the mailbox", "inbox": "A note waited in the inbox"}
# The pictures in the owner's messages: Claude Code's pasted image placeholders,
# the desk voice's "Screenshots: <path>..." line, and any absolute image path
# the owner pasted, quoted or bare (a dragged file's spaces arrive escaped as
# "\ "). Only the screenshots line's paths and paths under the desk voice's
# shots folder leave the words; any other path stays as the owner wrote it.
IMAGE_PLACEHOLDER_RE = re.compile(r"\s*\[Image #\d+\]")
SCREENSHOTS_LINE_RE = re.compile(r"(?:^|(?<=\s))Screenshots:[^\n]*")
SCREENSHOTS_LEFT_RE = re.compile(r"(?:^|(?<=\s))Screenshots:[ \t]*(?=\n|$)")
IMAGE_PATH_RE = re.compile(
    r"(['\"])(/[^'\"\n]+?\.(?:png|jpe?g|gif|webp))\1"
    r"|(?<![^\s'\"(])(/(?:\\ |[^\s'\"\\])+?\.(?:png|jpe?g|gif|webp))(?=$|[\s'\").,;:!?])", re.I)
PICTURE_MAX = 20 * 1024 * 1024
PICTURE_ID_RE = re.compile(r"^[0-9a-f]{24}$")
PICTURE_TYPES = {"png": "image/png", "jpg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"}
# The files a reply may link: an existing file under one of these folders of
# the home, named home-relative or absolute, with one of these types, and no
# hidden part below the folder. The page opens one at /api/file/<home path>,
# read-only; home_file owns the check, after every symlink is resolved.
FILE_DIRS = ("data", ".lavish")
FILE_TYPES = {
    ".html": "text/html; charset=utf-8", ".htm": "text/html; charset=utf-8",
    ".svg": "image/svg+xml", ".pdf": "application/pdf",
    ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp",
    ".md": "text/plain; charset=utf-8", ".markdown": "text/plain; charset=utf-8", ".txt": "text/plain; charset=utf-8",
    ".log": "text/plain; charset=utf-8", ".csv": "text/plain; charset=utf-8", ".json": "text/plain; charset=utf-8",
}
# Types that can run script are served in a sandbox with an opaque origin, so
# a page from the home can never read or send as this page.
FILE_ACTIVE = (".html", ".htm", ".svg")
FILE_MAX = 64 * 1024 * 1024
FILE_HREF = "/api/file/"
FILE_PATH_RE = re.compile(r"(?<![\w/.~-])((?:/|(?:data|\.lavish)/)[^\s<>\"'`()\[\]{}:]+)")
SIGNIN_CODE_RE = re.compile(r"^[A-Za-z0-9_-]{24,64}$")
SIGNIN_CODE_SECONDS = 120


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
    r"|" + FILE_PATH_RE.pattern
)
BOLD_RE = re.compile(r"\*\*(?=\S)(.+?)(?<=\S)\*\*")
ITALIC_RE = re.compile(r"(?<![*\w])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![*\w])")
STRIKE_RE = re.compile(r"~~(?=\S)(.+?)(?<=\S)~~")
LINK_PARTS_RE = re.compile(r"^\[([^\]]+)\]\(([^)]+)\)$")
TRAILING_PUNCT = ".,;:!?)"
PATH_TRAILING = TRAILING_PUNCT + "*_"


def _anchor(url: str, label_html: str) -> str:
    return (
        f'<a href="{html.escape(url, quote=True)}" target="_blank" '
        f'rel="noopener noreferrer">{label_html}</a>'
    )


def _emphasis(escaped: str) -> str:
    escaped = BOLD_RE.sub(r"<strong>\1</strong>", escaped)
    escaped = ITALIC_RE.sub(r"<em>\1</em>", escaped)
    return STRIKE_RE.sub(r"<del>\1</del>", escaped)


def home_file(home: Path, name: str) -> Optional[Tuple[str, Path]]:
    """The home path and resolved file <name> names, when a reply may link it.

    <name> is home-relative or absolute. It names a linkable file only when,
    with every symlink resolved, it is an existing regular file of a FILE_TYPES
    type under one of the home's FILE_DIRS with no hidden part below it; a ../
    escape or a symlink out resolves elsewhere and is refused.
    """
    if not name or "\x00" in name or len(name) > 4096:
        return None
    try:
        base = home.resolve(strict=True)
        given = Path(name)
        real = (given if given.is_absolute() else base / given).resolve(strict=True)
    except (OSError, RuntimeError, ValueError):
        return None
    for folder in FILE_DIRS:
        try:
            rel = real.relative_to(base / folder)
        except ValueError:
            continue
        if not rel.parts or any(part.startswith(".") for part in rel.parts):
            return None
        if real.suffix.lower() not in FILE_TYPES or not real.is_file():
            return None
        return (Path(folder) / rel).as_posix(), real
    return None


def file_linker(home: Path) -> Any:
    """What render_markdown links a path with: its /api/file/ address, or None."""
    def link(name: str) -> Optional[str]:
        found = home_file(home, name)
        return FILE_HREF + quote(found[0]) if found else None
    return link


def render_inline(text: str, link: Any = None) -> str:
    """Escape everything, then add code, links and emphasis.

    Only http and https links become anchors, and, with <link>, a path or a
    code span that is only a path, when link(path) gives its address; every
    other byte reaches the page escaped, so no input can open a tag or an
    attribute. Code and links stand in as placeholders while emphasis is
    applied to the whole line, so bold or italic words that hold code or a
    link still render.
    """
    text = text.replace("\x00", "")
    out: List[str] = []
    tokens: List[str] = []
    pos = 0
    seek = 0
    while True:
        match = INLINE_TOKEN_RE.search(text, seek)
        if match is None:
            break
        code, markdown_link, bare, path = match.groups()
        href = None
        if path:
            tail = ""
            while path and path[-1] in PATH_TRAILING:
                tail = path[-1] + tail
                path = path[:-1]
            href = link(path) if link and path else None
            if href is None:
                # Not a linked file: its words stay text, and a link or code
                # that starts inside them is still found.
                seek = match.start() + 1
                continue
        out.append(html.escape(text[pos:match.start()], quote=True))
        seek = match.end()
        if path:
            tokens.append(_anchor(href, html.escape(path, quote=True)))
            out.append(f"\x00{len(tokens) - 1}\x00" + html.escape(tail, quote=True))
            pos = match.end()
            continue
        if code:
            shown = f"<code>{html.escape(code[1:-1], quote=True)}</code>"
            href = link(code[1:-1].strip()) if link else None
            tokens.append(_anchor(href, shown) if href else shown)
        elif markdown_link:
            parts = LINK_PARTS_RE.match(markdown_link)
            label, url = (parts.group(1), parts.group(2)) if parts else (markdown_link, "")
            tokens.append(_anchor(url, _emphasis(html.escape(label, quote=True))))
        else:
            url = bare
            tail = ""
            while url and url[-1] in TRAILING_PUNCT:
                tail = url[-1] + tail
                url = url[:-1]
            tokens.append(_anchor(url, html.escape(url, quote=True)) + html.escape(tail, quote=True))
        out.append(f"\x00{len(tokens) - 1}\x00")
        pos = match.end()
    out.append(html.escape(text[pos:], quote=True))
    return re.sub("\x00(\\d+)\x00", lambda m: tokens[int(m.group(1))], _emphasis("".join(out)))


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


def _render_list(block: List[Tuple[int, str, str, int]], link: Any = None) -> str:
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
        out.append("<li>" + "<br>".join(render_inline(part, link) for part in body_text.split("\n")))
    while stack:
        out.append(f"</li></{stack.pop()[1]}>")
    return "".join(out)


def render_markdown(text: str, link: Any = None) -> str:
    """A small, safe Markdown subset: paragraphs, headings, lists, quotes,
    rules, fenced code and pipe tables. All text is escaped first; <link>
    links paths, as render_inline says."""
    lines = text.replace("\x00", "").replace("\r\n", "\n").split("\n")
    out: List[str] = []
    para: List[str] = []
    i = 0

    def flush() -> None:
        if para:
            out.append("<p>" + "<br>".join(render_inline(item, link) for item in para) + "</p>")
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
            out.append(f"<h{level}>{render_inline(heading.group(2), link)}</h{level}>")
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
            parts.extend(f"<th>{render_inline(cell, link)}</th>" for cell in head)
            parts.append("</tr></thead><tbody>")
            for row in rows:
                parts.append("<tr>" + "".join(f"<td>{render_inline(cell, link)}</td>" for cell in row) + "</tr>")
            parts.append("</tbody></table></div>")
            out.append("".join(parts))
            continue
        if line.lstrip().startswith(">"):
            flush()
            quote: List[str] = []
            while i < len(lines) and lines[i].lstrip().startswith(">"):
                quote.append(lines[i].lstrip()[1:].lstrip())
                i += 1
            out.append("<blockquote>" + render_markdown("\n".join(quote), link) + "</blockquote>")
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
            out.append(_render_list(block, link))
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


def picture_id(ref: str) -> str:
    return hashlib.sha256(ref.encode("utf-8", "replace")).hexdigest()[:24]


def owner_pictures(text: str, shots: Optional[str] = None) -> Tuple[str, List[str]]:
    """The owner's words, and the paths of the images they name, each once.

    Only a path to a file that is there now is a picture. It leaves the words
    when it is on the desk voice's "Screenshots:" line or under <shots>, the
    desk voice's shots folder, and the label goes once its paths are gone; any
    other image path stays in the words as written and is shown beneath too.
    """
    paths: List[str] = []
    lines = [m.span() for m in SCREENSHOTS_LINE_RE.finditer(text)]
    shots_dir = os.path.join(os.path.realpath(shots), "") if shots else None
    taken = False

    def take(match: "re.Match[str]") -> str:
        nonlocal taken
        path = match.group(2) or match.group(3).replace("\\ ", " ")
        if not os.path.isfile(path):
            return match.group(0)
        if path not in paths:
            paths.append(path)
        if any(a <= match.start() < b for a, b in lines) or (
                shots_dir and os.path.realpath(path).startswith(shots_dir)):
            taken = True
            return ""
        return match.group(0)

    kept = IMAGE_PATH_RE.sub(take, text)
    if taken:
        kept = SCREENSHOTS_LEFT_RE.sub("", kept)
        kept = re.sub(r"[ \t]{2,}", " ", kept).strip()
    return kept, paths


def _user_item(uid: str, ts: str, text: str, images: int = 0) -> Dict[str, Any]:
    if images:
        text = IMAGE_PLACEHOLDER_RE.sub("", text).strip()
    return {
        "id": uid,
        "kind": "user",
        "ts": ts,
        "html": "",
        "images": images,
        "pictures": [],
        "_text": text,
    }


def _notice_item(uid: str, ts: str, text: str) -> Optional[Dict[str, Any]]:
    """A doorbell or operational input typed into the chat, as a quiet notice."""
    notice = NOTICE_RE.match(text)
    if not notice:
        return None
    label = NOTICE_WORDS.get(notice.group(1) or "", "A notice for firstmate")
    return _event_item(uid, ts, label, text.replace("\u2063", ""))


def _owner_item(uid: str, ts: str, text: str, images: int = 0) -> Dict[str, Any]:
    return _notice_item(uid, ts, text) or _user_item(uid, ts, text, images)


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
        return _owner_item(uid, ts, text)
    tag = EVENT_TAG_RE.match(text)
    if tag:
        if tag.group(1) in SKIPPED_TAGS:
            return None
        summary = SUMMARY_TAG_RE.search(text)
        label = summary.group(1) if summary else tag.group(1).replace("-", " ")
        return _event_item(uid, ts, label, text)
    if origin_kind and origin_kind != "human":
        return _event_item(uid, ts, origin_kind.replace("-", " "), text)
    return _owner_item(uid, ts, text)


def _starts_turn(text: str) -> bool:
    tag = EVENT_TAG_RE.match(text)
    return not (tag and tag.group(1) in BASH_MODE_TAGS)


def _words(text: str) -> str:
    return " ".join(text.split())


class Conversation:
    """Folds transcript entries into display items, oldest first."""

    def __init__(self, shots: Optional[str] = None, link: Any = None) -> None:
        self.shots = shots
        # Links the paths in the first mate's replies (render_inline).
        self.link = link
        self.items: List[Dict[str, Any]] = []
        self.tools: Dict[str, Dict[str, Any]] = {}
        self.busy = False
        # When the turn under way began: the timestamp of the entry that made
        # the conversation busy, so the page can say how long it has worked.
        self.turn_started: Optional[str] = None
        # Whether that entry started the turn: a turn whose first entry was not
        # read began earlier, so its start is unknown.
        self.turn_opened = False
        self.opening = False
        self.last_assistant_msg: Optional[str] = None
        self.pending_compact: Optional[Dict[str, Any]] = None
        # Each picture an owner's message shows, by its id: ("path", path) or
        # ("data", media type, base64), read only when the page asks for it.
        self.pictures: Dict[str, Tuple[str, ...]] = {}
        # Messages typed while the first mate works, as Claude Code's own
        # queue records them ("queue-operation" entries), oldest first: each
        # is its timestamp, its words, whether it reads as the owner's own
        # message, and whether the transcript already shows it read in, until
        # the queue takes it out.
        self.queue: List[List[Any]] = []

    def add(self, entry: Dict[str, Any]) -> None:
        if not isinstance(entry, dict) or entry.get("isSidechain"):
            return
        kind = entry.get("type")
        if kind == "queue-operation":
            self._queue_operation(entry)
            return
        uid = str(entry.get("uuid") or f"x{len(self.items)}")
        ts = str(entry.get("timestamp") or "")
        was_busy = self.busy
        self.opening = False
        self._entry(entry, kind, uid, ts)
        if not self.busy:
            self.turn_started = None
        elif not was_busy:
            self.turn_started = ts or None
            self.turn_opened = self.opening
        elif not self.turn_started:
            self.turn_started = ts or None

    def _entry(self, entry: Dict[str, Any], kind: Any, uid: str, ts: str) -> None:
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
                        self._push(_owner_item(uid, ts, text))
                        self.busy = self.opening = True

    def _queue_operation(self, entry: Dict[str, Any]) -> None:
        """Follow Claude Code's queue of messages typed mid-turn.

        An enqueue adds one; a remove names the words it takes out; popAll
        and clear empty it. A dequeue names nothing: the owner's messages go
        before the machinery's notices, so it takes the oldest of the owner's,
        else the oldest. The transcript may show a message read in before or
        after its dequeue or remove, so _delivered only marks it read and the
        queue operation takes a marked one first. A message queued before the
        part of the transcript read is unknown here, so its dequeue or remove
        can at worst hide one still waiting: the page may miss a waiting
        message, never show a read one as waiting.
        """
        operation = entry.get("operation")
        if operation == "enqueue":
            text = _block_text(entry.get("content"))
            ts = str(entry.get("timestamp") or "")
            shown = _classify_user_string("", ts, text, "") if text.strip() else None
            self.queue.append([ts, text, shown is not None and shown["kind"] == "user", False])
        elif operation == "dequeue":
            self._take([queued for queued in self.queue if queued[3]]
                       or [queued for queued in self.queue if queued[2]] or self.queue)
        elif operation == "remove":
            words = _words(_block_text(entry.get("content")))
            matching = [queued for queued in self.queue if _words(queued[1]) == words]
            self._take([queued for queued in matching if queued[3]] or matching)
        elif operation in ("popAll", "clear"):
            self.queue.clear()

    def _take(self, candidates: List[List[Any]]) -> None:
        if candidates:
            self.queue.remove(candidates[0])

    def _delivered(self, text: str) -> None:
        """The transcript shows <text> read in: it is no longer waiting."""
        words = _words(text)
        for queued in self.queue:
            if not queued[3] and _words(queued[1]) == words:
                queued[3] = True
                return

    def waiting_items(self) -> List[Dict[str, Any]]:
        """The owner's messages still queued, as faded bubbles to show."""
        waiting: List[Dict[str, Any]] = []
        for index, (ts, text, owner, read) in enumerate(self.queue):
            if not owner or read:
                continue
            item = _user_item("waiting:" + picture_id(f"{index}:{ts}:{text}"), ts, text)
            self._render_user(item)
            item["waiting"] = True
            waiting.append(item)
        return waiting

    def _render_user(self, item: Dict[str, Any], blobs: Optional[List[Tuple[str, str]]] = None) -> None:
        text, paths = owner_pictures(item.pop("_text"), self.shots)
        item["html"] = render_markdown(text) if text.strip() else ""
        for index, (media, data) in enumerate(blobs or []):
            pid = picture_id(f"{item['id']}:{index}")
            self.pictures[pid] = ("data", media, data)
            item["pictures"].append(pid)
        for path in paths:
            pid = picture_id("path:" + path)
            self.pictures[pid] = ("path", path)
            item["pictures"].append(pid)

    def _push(self, item: Dict[str, Any], blobs: Optional[List[Tuple[str, str]]] = None) -> None:
        if item["kind"] == "user":
            self._delivered(item["_text"])
            self._render_user(item, blobs)
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
                if _starts_turn(content):
                    self.busy = self.opening = True
            return
        if not isinstance(content, list):
            return
        texts: List[str] = []
        images = 0
        blobs: List[Tuple[str, str]] = []
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
                source = block.get("source")
                if isinstance(source, dict) and source.get("type") == "base64" and isinstance(source.get("data"), str):
                    blobs.append((str(source.get("media_type") or ""), source["data"]))
        text = "\n".join(texts).strip()
        if text and INTERRUPT_RE.match(text):
            self._push(_event_item(uid, ts, "Interrupted", text))
            self.busy = False
            return
        if text or images:
            item = _classify_user_string(uid, ts, text, origin_kind)
            if item is None:
                return
            if item["kind"] == "user" and images:
                item = _user_item(uid, ts, text, images)
            self._push(item, blobs)
            if _starts_turn(text):
                self.busy = self.opening = True

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
                    last["html"] = render_markdown(last["text"], self.link)
                else:
                    self._push(
                        {
                            "id": f"{uid}:{index}",
                            "kind": "assistant",
                            "ts": ts,
                            "text": text,
                            "html": render_markdown(text, self.link),
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
                about = tool_input.get("description") if isinstance(tool_input, dict) else None
                item = {
                    "id": str(block.get("id") or f"{uid}:{index}"),
                    "kind": "tool",
                    "ts": ts,
                    "name": name,
                    "summary": tool_summary(name, tool_input),
                    "about": _one_line(about) if isinstance(about, str) else "",
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

    def shown_pictures(self, items: List[Dict[str, Any]]) -> Dict[str, Tuple[str, ...]]:
        """The pictures of the shown items only, so the page can ask for no other."""
        wanted = {pid for item in items for pid in item.get("pictures") or []}
        return {pid: ref for pid, ref in self.pictures.items() if pid in wanted}


def parse_lines(lines: Iterable[str], shots: Optional[str] = None, link: Any = None) -> Conversation:
    conversation = Conversation(shots, link)
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


def read_tail(path: Path, shots: Optional[str] = None, want_items: int = TAIL_ITEMS,
              link: Any = None) -> Tuple[Conversation, bool]:
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
        conversation = parse_lines(lines, shots, link)
        if start == 0 or len(conversation.items) >= want_items or window >= TAIL_MAX_WINDOW:
            return conversation, start > 0
        window = min(window * 4, TAIL_MAX_WINDOW)


class TranscriptCache:
    def __init__(self, home: Path, link_files: bool = False) -> None:
        self.home = home
        # Only this server serves /api/file/, so only its reading links files;
        # the conversation command's reader shows the paths as plain words.
        self.link = file_linker(home) if link_files else None
        self.lock = threading.Lock()
        self.key: Optional[Tuple[str, int, int]] = None
        self.value: Optional[Dict[str, Any]] = None
        self.pictures: Dict[str, Tuple[str, ...]] = {}

    def picture(self, pid: str) -> Optional[Tuple[bytes, str]]:
        """One picture the shown conversation holds, as its bytes and type.

        Only an id the last reading handed out is known, and only an image
        whose bytes are one of the page's image types is served.
        """
        with self.lock:
            ref = self.pictures.get(pid)
        if ref is None:
            return None
        if ref[0] == "path":
            try:
                if os.path.getsize(ref[1]) > PICTURE_MAX:
                    return None
                with open(ref[1], "rb") as handle:
                    data = handle.read(PICTURE_MAX + 1)
            except OSError:
                return None
        else:
            try:
                data = base64.b64decode(ref[2], validate=False)
            except (ValueError, binascii.Error):
                return None
        ext = sniff_image(data)
        if ext is None or len(data) > PICTURE_MAX:
            return None
        return data, PICTURE_TYPES[ext]

    def get(self) -> Dict[str, Any]:
        session, path = resolve_transcript(self.home)
        alive = lock_pid_alive(self.home)
        if path is None:
            reason = (
                "No firstmate session is recorded for this home yet."
                if session is None
                else "Firstmate's conversation file was not found."
            )
            return {"session": session, "state": "offline", "items": [], "waiting": [], "older": False, "note": reason,
                    "version": f"none:{session}"}
        stat = path.stat()
        key = (str(path), stat.st_size, stat.st_mtime_ns)
        with self.lock:
            if key != self.key or self.value is None:
                conversation, older = read_tail(path, str(self.home / "state" / "desk-voice" / "shots"),
                                                link=self.link)
                items = conversation.public_items(TAIL_ITEMS)
                waiting = conversation.waiting_items()
                self.value = {
                    "items": items,
                    "waiting": waiting,
                    "older": older,
                    "busy": conversation.busy,
                    "since": conversation.turn_started if conversation.turn_opened or not older else None,
                }
                self.pictures = conversation.shown_pictures(items + waiting)
                self.key = key
            value = dict(self.value)
        busy = value.pop("busy")
        since = value.pop("since")
        state = "offline" if alive is False else ("busy" if busy else "idle")
        value.update(
            {
                "session": session,
                "state": state,
                "since": since if state == "busy" else None,
                "note": "",
                "version": f"{session}:{stat.st_size}:{stat.st_mtime_ns}:{state}",
            }
        )
        return value


# --- the mirror: the Factory pane's screen and the bridge strip's fields ------

# The page's own words for the pane's and the strip's jargon. Every other word
# on the page is theirs; docs/web.md lists these.
PLAIN_WORDS = {"ready to merge": "ready for your OK", "PR ready": "ready for your OK"}
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
        "summary": [
            {"label": part.get("label") or "", "text": part.get("text") or ""}
            for part in need.get("summary") or []
            if isinstance(part, dict) and part.get("text")
        ],
        "read": bool(need.get("read")),
    }


def _shelves_model(shelves: Dict[str, Any]) -> Dict[str, Any]:
    """NEEDS YOU's two shelves as the pane words them: the older questions still open and the calls put off."""
    older = shelves.get("older") or {}
    coming = shelves.get("coming") or {}
    return {
        "older": {
            "heading": older.get("heading") or "",
            "note": older.get("note") or "",
            "items": [
                {
                    "id": item.get("id"),
                    "asking": item.get("asking"),
                    "project": item.get("factory"),
                    "project_name": item.get("factory_name") or "",
                    "title": item.get("title") or "",
                    "since": item.get("since") or "",
                    "asked": item.get("asked") or "",
                }
                for item in older.get("items") or []
            ],
        },
        "coming": {
            "heading": coming.get("heading") or "",
            "rest": coming.get("rest") or "",
            "after": coming.get("after") or "",
            "items": [
                {
                    "project": item.get("factory"),
                    "project_name": item.get("factory_name") or "",
                    "title": item.get("title") or "",
                    "when": item.get("when") or "",
                }
                for item in coming.get("items") or []
            ],
        },
    }


def _new_model(item: Dict[str, Any]) -> Dict[str, Any]:
    """One outcome as New on the overview and Lately on a project's tab tell it: its word as a label, then the work."""
    return {
        "id": item.get("id"),
        "label": (lambda word: word[:1].upper() + word[1:])(plain_word(item.get("word")))
        if item.get("word") in PLAIN_WORDS
        else item.get("label") or "",
        "text": item.get("text") or "",
        "when": item.get("when") or "",
        "pr": item.get("pr") or "",
        "read": bool(item.get("read")),
        "mark": MARKS.get(item.get("colour") or "", ""),
    }


def _project_model(factory: Dict[str, Any]) -> Dict[str, Any]:
    page = factory.get("page") or {}
    nxt = factory.get("next")
    return {
        "id": factory.get("id"),
        "name": factory.get("name") or "",
        "about": ". ".join(str(words) for words in factory.get("about") or []),
        "you_steer": factory.get("steered_by") == "you",
        # The factory told as Now, New and Next, as the pane tells it (fm-factory.py View.told).
        "quiet": bool(factory.get("quiet")),
        "quiet_words": factory.get("quiet_words") or "",
        "badge": factory.get("badge") or "",
        "now": factory.get("now") or "",
        "jobs": [_job_model(job) for job in factory.get("jobs") or []],
        "new": [_new_model(item) for item in factory.get("new") or [] if isinstance(item, dict)],
        "more": factory.get("more") or 0,
        "more_words": factory.get("more_words") or "",
        "routine": [
            {"kind": line.get("kind") or "", "words": list(line.get("words") or []), "now": line.get("now") or ""}
            for line in factory.get("routine") or []
        ],
        "next": {"title": nxt.get("title") or "", "words": nxt.get("words") or ""} if isinstance(nxt, dict) else None,
        "page": {
            "needs": list(page.get("needs") or []),
            # The tab top to bottom, as the pane's page (fm-factory.py View.page_parts).
            "state": page.get("state") or "",
            "now": [_job_model(job) for job in page.get("now") or []],
            "lately": [_new_model(item) for item in page.get("lately") or [] if isinstance(item, dict)],
            "lately_since": page.get("lately_since") or "",
            "next": [_job_model(job) for job in page.get("next") or []],
            "lined": page.get("lined") or 0,
            "coming": [
                {"title": item.get("title") or "", "when": item.get("when") or ""} for item in page.get("coming") or []
            ],
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
            "shelves": _shelves_model(page.get("shelves") or {}),
            # The pane lists what was said oldest first, above its keys line; the page reads from the top.
            "talk": [
                {"when": line.get("when") or "", "who": line.get("who") or "", "said": line.get("said") or ""}
                for line in reversed(page.get("talk") or [])
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
            {"mark": "work", "count": counts.get("busy") or 0, "words": "busy", "short": "busy"},
            {"mark": "you", "count": decisions, "words": "decision for you" if decisions == 1 else "decisions for you",
             "short": "for you"},
            {"mark": "done", "count": counts.get("ready_to_merge") or 0, "words": "ready for your OK", "short": "for your OK"},
        ]
    needs = [_need_model(need) for need in screen.get("needs") or []]
    listed = {need["id"]: need for need in needs}
    call = None
    if needs:
        # The first card is the most pressing call, in the one order the strip's
        # call is the first of too, so the header and the list always agree.
        call = {"id": needs[0]["id"], "title": needs[0]["ask"], "question": needs[0]["question"], "listed": True}
    elif fields.get("call_id") and fields.get("call_title"):
        # The strip names the call; the pane's card for it has its whole title.
        card = listed.get(fields["call_id"])
        call = {
            "id": fields["call_id"],
            "title": card["ask"] if card else fields["call_title"],
            "question": fields.get("call_kind") != "merge",
            "listed": card is not None,
        }
    stopped = [job for job in screen.get("stopped") or [] if isinstance(job, dict) and job.get("id")]
    return {
        "clock": screen.get("clock") or "",
        "band": {
            "lamps": lamps,
            "note": "" if known and counts.get("reading") != "past" else (fields.get("age") or "") if known else "reading the crew",
            "call": call,
            "alert": re.sub(r"\bfailed\b", "hit a problem", fields.get("alert") or ""),
            # The job the alert's "stopped" opens: the one the overview reads stopped.
            "stopped": {"project": stopped[0].get("factory"), "job": stopped[0].get("id")}
            if stopped and "stopped" in (fields.get("alert") or "") else None,
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
        "sentences": [
            {"words": plain_phrase(said.get("words")), "to": said.get("to") or "",
             "mark": MARKS.get(said.get("colour") or "", "")}
            for said in screen.get("sentences") or []
            if isinstance(said, dict)
        ],
        "first_up": screen.get("first_up") or (needs[0]["id"] if needs else None),
        "shelves": _shelves_model(screen.get("shelves") or {}),
        "needs": needs,
        "projects": [_project_model(factory) for factory in screen.get("factories") or []],
        "factories_heading": screen.get("factories_heading") or "",
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


def status_segments(row: str) -> List[Dict[str, str]]:
    """The status bar's styled row as words, each with the tone its colour gives."""
    segments: List[Dict[str, str]] = []
    tone = ""
    pos = 0
    for match in ANSI_RE.finditer(row):
        if match.start() > pos:
            segments.append({"text": row[pos:match.start()], "tone": tone})
        tone = ANSI_TONES.get(match.group(1), "")
        pos = match.end()
    if pos < len(row):
        segments.append({"text": row[pos:], "tone": tone})
    return [seg for seg in segments if seg["text"]]


def read_status_row(home: Path, root: Path) -> List[Dict[str, str]]:
    """The primary's own groups of the terminal's status bar row (model and
    effort, usage, cost), drawn again by bin/fm-status-bar.sh --replay --own
    from the figures its last render saved; the header already shows the
    fleet. An empty list when it cannot be read, so the page leaves it out."""
    try:
        proc = subprocess.run(
            ["bash", str(root / "bin" / "fm-status-bar.sh"), "--replay", "--own"],
            env=child_env(home, root),
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=STATUS_ROW_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.SubprocessError):
        return []
    row = proc.stdout.strip().splitlines()[0] if proc.returncode == 0 and proc.stdout.strip() else ""
    return status_segments(row)


def read_suggestion(home: Path, root: Path) -> str:
    """The suggested next prompt Claude shows in the primary's empty chat box,
    read by bin/fm-desk-voice.sh suggestion; empty when there is none."""
    try:
        proc = subprocess.run(
            ["bash", str(root / "bin" / "fm-desk-voice.sh"), "suggestion"],
            env=child_env(home, root),
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=SUGGESTION_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    lines = proc.stdout.strip().splitlines() if proc.returncode == 0 else []
    return lines[0].strip()[:SUGGESTION_MAX] if lines else ""


def suggestion_reader(home: Path, root: Path) -> Any:
    """Claude's suggested next prompt for every open page, as a function of
    whether the first mate is ready. It is read in the background, at most
    every SUGGESTION_TTL_SECONDS and only while the first mate is ready, so a
    poll never waits on the screen read; while it works there is none."""
    lock = threading.Lock()
    held = {"value": "", "at": float("-inf"), "reading": False, "turn": 0}

    def read(turn: int) -> None:
        value = read_suggestion(home, root)
        with lock:
            held["reading"] = False
            if held["turn"] == turn:
                held.update(value=value, at=time.monotonic())

    def get(ready: bool) -> str:
        with lock:
            if not ready:
                held.update(value="", at=float("-inf"), turn=held["turn"] + 1)
                return ""
            if not held["reading"] and time.monotonic() - held["at"] >= SUGGESTION_TTL_SECONDS:
                held["reading"] = True
                threading.Thread(target=read, args=(held["turn"],), daemon=True).start()
            return held["value"]

    return get


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
            model["status"] = read_status_row(self.home, self.root)
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
    in_tab = payload.get("in_tab")
    if in_tab is not None:
        if in_tab is not True:
            raise ValueError("in_tab is true or absent")
        ask["in_tab"] = True
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
    argv.append("--stdin")
    env = dict(os.environ)
    env["FM_HOME"] = str(home)
    env["FM_ROOT_OVERRIDE"] = str(root)
    proc = subprocess.run(
        argv,
        env=env,
        input=text,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        timeout=SEND_TIMEOUT_SECONDS,
    )
    line = (proc.stdout or "").strip().splitlines()[-1:] or [""]
    outcome = line[0]
    if proc.returncode != 0 or not outcome:
        detail = (proc.stderr or "").strip().splitlines()[-1:] or ["the message could not be delivered"]
        return {"outcome": "failed", "detail": detail[0].removeprefix("fm-desk-voice: ")}
    if outcome.startswith("sent-unconfirmed:"):
        return {"outcome": "typed-unconfirmed", "detail": "Typed into firstmate's chat; the send was not confirmed."}
    if outcome.startswith("sent:"):
        return {"outcome": "typed", "detail": "Typed into firstmate's chat."}
    if outcome.startswith("mailbox:"):
        return {"outcome": "mailbox", "detail": "The chat was busy, so it went to firstmate's mailbox."}
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
        raise ValueError(f"the message is too long: at most {SEND_TEXT_MAX:,} characters")
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


# --- the ship mark and the app icon ---------------------------------------
#
# One small rocket, drawn nose up in a unit square and tilted to climb up and
# to the right, the way Starship's own ship is drawn elsewhere: a pointed hull
# with a round window, two fins, a nozzle and a flame. The same points draw the
# page's mark, the browser tab's icon and the installed app's icon.

SHIP_HULL = [(0.5, 0.04), (0.535, 0.08), (0.57, 0.14), (0.6, 0.22), (0.625, 0.31), (0.635, 0.40),
             (0.635, 0.70), (0.365, 0.70), (0.365, 0.40), (0.375, 0.31), (0.4, 0.22), (0.43, 0.14), (0.465, 0.08)]
SHIP_FINS = [[(0.635, 0.50), (0.75, 0.62), (0.76, 0.78), (0.635, 0.69)],
             [(0.365, 0.50), (0.25, 0.62), (0.24, 0.78), (0.365, 0.69)]]
SHIP_NOZZLE = [(0.43, 0.70), (0.57, 0.70), (0.55, 0.76), (0.45, 0.76)]
SHIP_FLAME = [(0.45, 0.79), (0.465, 0.88), (0.5, 0.97), (0.535, 0.88), (0.55, 0.79)]
SHIP_WINDOW = (0.5, 0.36, 0.075)


def _turned(points: List[Tuple[float, float]], scale: float = 1.0, inset: float = 0.0) -> List[Tuple[float, float]]:
    """Turn points 45 degrees clockwise about the centre, then fit them."""
    out = []
    c = 0.70710678
    for x, y in points:
        dx, dy = x - 0.5, y - 0.5
        out.append((0.5 + (dx * c - dy * c) * scale + inset, 0.5 + (dx * c + dy * c) * scale + inset))
    return out


def _circle(cx: float, cy: float, r: float, steps: int = 28) -> List[Tuple[float, float]]:
    import math
    return [(cx + r * math.cos(2 * math.pi * i / steps), cy + r * math.sin(2 * math.pi * i / steps)) for i in range(steps)]


def ship_parts(scale: float = 1.0) -> Dict[str, List[List[Tuple[float, float]]]]:
    """The tilted rocket's shapes in unit coordinates, scaled about the centre."""
    def fit(points: List[Tuple[float, float]]) -> List[Tuple[float, float]]:
        return [(0.5 + (x - 0.5) * scale, 0.5 + (y - 0.5) * scale) for x, y in _turned(points)]
    cx, cy, r = SHIP_WINDOW
    return {
        "hull": [fit(SHIP_HULL)] + [fit(fin) for fin in SHIP_FINS] + [fit(SHIP_NOZZLE)],
        "window": [fit(_circle(cx, cy, r))],
        "flame": [fit(SHIP_FLAME)],
    }


def _svg_path(polys: List[List[Tuple[float, float]]], size: float) -> str:
    return " ".join("M" + " L".join("%.2f %.2f" % (x * size, y * size) for x, y in poly) + "Z" for poly in polys)


def ship_mark_path() -> str:
    """The one-colour mark: the hull with the window cut out, and the flame."""
    parts = ship_parts(1.08)
    return _svg_path(parts["hull"] + parts["window"] + parts["flame"], 24)


ICON_SKY = (0x14, 0x32, 0x42)
ICON_HULL = (0xF6, 0xF2, 0xEA)
ICON_WINDOW = (0x62, 0xC6, 0xE2)
ICON_FLAME = (0xF0, 0xA8, 0x3A)


def _rounded_square(inset: float, radius: float) -> List[Tuple[float, float]]:
    import math
    lo, hi = inset, 1 - inset
    points: List[Tuple[float, float]] = []
    for cx, cy, start in ((hi - radius, lo + radius, -90), (hi - radius, hi - radius, 0),
                          (lo + radius, hi - radius, 90), (lo + radius, lo + radius, 180)):
        for step in range(9):
            angle = math.radians(start + step * 90 / 8)
            points.append((cx + radius * math.cos(angle), cy + radius * math.sin(angle)))
    return points


def icon_shapes() -> List[Tuple[List[List[Tuple[float, float]]], Tuple[int, int, int]]]:
    """The app icon: the rocket on a night-blue rounded square."""
    parts = ship_parts(0.86)
    return [([_rounded_square(0.06, 0.2)], ICON_SKY), (parts["flame"], ICON_FLAME),
            (parts["hull"], ICON_HULL), (parts["window"], ICON_WINDOW)]


def icon_svg() -> str:
    def hexed(rgb: Tuple[int, int, int]) -> str:
        return "#%02X%02X%02X" % rgb
    paths = "".join(f'<path d="{_svg_path(polys, 64)}" fill="{hexed(rgb)}"/>' for polys, rgb in icon_shapes())
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">{paths}</svg>\n'


def _coverage(polys: List[List[Tuple[float, float]]], size: int, samples: int = 4) -> List[float]:
    """How much of each pixel the shapes cover, 0 to 1 (even-odd, supersampled rows)."""
    cover = [0.0] * (size * size)
    weight = 1.0 / samples
    edges = []
    for poly in polys:
        for i, (x0, y0) in enumerate(poly):
            x1, y1 = poly[(i + 1) % len(poly)]
            if y0 != y1:
                edges.append((x0 * size, y0 * size, x1 * size, y1 * size))
    for sub in range(size * samples):
        y = (sub + 0.5) / samples
        xs = sorted(x0 + (y - y0) * (x1 - x0) / (y1 - y0) for x0, y0, x1, y1 in edges
                    if (y0 <= y < y1) or (y1 <= y < y0))
        base = int(y) * size
        for a, b in zip(xs[0::2], xs[1::2]):
            a, b = max(0.0, a), min(float(size), b)
            if b <= a:
                continue
            ia, ib = int(a), int(b)
            if ia == ib:
                cover[base + ia] += (b - a) * weight
                continue
            cover[base + ia] += (ia + 1 - a) * weight
            for i in range(base + ia + 1, base + ib):
                cover[i] += weight
            if ib < size:
                cover[base + ib] += (b - ib) * weight
    return cover


_ICON_PNGS: Dict[int, bytes] = {}


def icon_png(size: int) -> bytes:
    """The app icon as a PNG of <size> pixels, drawn once per size."""
    if size in _ICON_PNGS:
        return _ICON_PNGS[size]
    red = [0.0] * (size * size)
    green = [0.0] * (size * size)
    blue = [0.0] * (size * size)
    alpha = [0.0] * (size * size)
    for polys, (r, g, b) in icon_shapes():
        for i, c in enumerate(_coverage(polys, size)):
            if c <= 0:
                continue
            c = min(c, 1.0)
            keep = 1 - c
            red[i] = r * c + red[i] * keep
            green[i] = g * c + green[i] * keep
            blue[i] = b * c + blue[i] * keep
            alpha[i] = c + alpha[i] * keep
    rows = bytearray()
    for y in range(size):
        rows.append(0)
        for i in range(y * size, (y + 1) * size):
            a = alpha[i]
            if a <= 0:
                rows.extend(b"\0\0\0\0")
                continue
            rows.extend((min(255, round(red[i] / a)), min(255, round(green[i] / a)),
                         min(255, round(blue[i] / a)), min(255, round(a * 255))))

    def chunk(kind: bytes, body: bytes) -> bytes:
        return len(body).to_bytes(4, "big") + kind + body + zlib.crc32(kind + body).to_bytes(4, "big")

    header = size.to_bytes(4, "big") * 2 + bytes((8, 6, 0, 0, 0))
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b"")
    _ICON_PNGS[size] = png
    return png


ICON_SIZES = (32, 180, 192, 512)


def manifest_json() -> str:
    """The web app manifest, so a browser offers to install the page as its own app."""
    return json.dumps({
        "name": "Starship",
        "short_name": "Starship",
        "description": "Your firstmate and every project's work, in plain words.",
        "start_url": "/",
        "scope": "/",
        "display": "standalone",
        "background_color": "#F1EBDF",
        "theme_color": "#143242",
        "icons": [{"src": "/icon.svg", "sizes": "any", "type": "image/svg+xml"}]
        + [{"src": f"/icon-{n}.png", "sizes": f"{n}x{n}", "type": "image/png"} for n in (192, 512)],
    }, indent=1) + "\n"


# --- one-time sign-in links ------------------------------------------------
#
# bin/fm-web.sh open hands the browser a link that works once, within
# SIGNIN_CODE_SECONDS, instead of the token: the link sits on a command line
# where other processes can read it, so it must be worth nothing afterwards.
# Only a hash of each code is kept, in state/web/codes/ (owner-only).


def codes_dir(home: Path) -> Path:
    return web_dir(home) / "codes"


def make_signin_code(home: Path) -> str:
    ensure_web_dir(home)
    folder = codes_dir(home)
    folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(folder, 0o700)
    now = int(time.time())
    for old in folder.iterdir():
        try:
            if int(old.read_text(encoding="utf-8").strip() or 0) < now:
                old.unlink()
        except (OSError, ValueError):
            pass
    code = secrets.token_urlsafe(24)
    fd = os.open(str(folder / hashlib.sha256(code.encode()).hexdigest()), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(f"{now + SIGNIN_CODE_SECONDS}\n")
    return code


def use_signin_code(home: Path, code: str) -> bool:
    """True once for a code make_signin_code gave out, while it is fresh."""
    if not SIGNIN_CODE_RE.match(code or ""):
        return False
    path = codes_dir(home) / hashlib.sha256(code.encode()).hexdigest()
    try:
        expires = int(path.read_text(encoding="utf-8").strip() or 0)
        path.unlink()
    except (OSError, ValueError):
        return False
    return expires >= int(time.time())


# --- HTTP ------------------------------------------------------------------


# A linked page or drawing runs in a sandbox without allow-same-origin: its
# origin is opaque, so the sign-in cookie never goes with its requests and it
# can neither read this page nor send through it. It may load what it needs
# from anywhere, as it would opened from disk.
FILE_SANDBOX_CSP = (
    "sandbox allow-scripts allow-popups allow-popups-to-escape-sandbox allow-modals allow-downloads; "
    "default-src * data: blob: 'unsafe-inline' 'unsafe-eval'; frame-ancestors 'none'"
)


def csp(nonce: str) -> str:
    return (
        "default-src 'none'; "
        f"style-src 'nonce-{nonce}'; "
        f"script-src 'nonce-{nonce}'; "
        "img-src 'self' data: blob:; "
        "manifest-src 'self'; "
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
        self.transcript = TranscriptCache(home, link_files=True)
        self.mirror = FleetCache(home, root)
        self.suggestion = suggestion_reader(home, root)
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

    def _send(self, status: int, body: bytes, content_type: str, headers: Optional[List[Tuple[str, str]]] = None,
              cache: str = "no-store", policy: Optional[str] = None) -> None:
        nonce = getattr(self, "_nonce", "") or secrets.token_urlsafe(16)
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache)
        self.send_header("Content-Security-Policy", policy or csp(nonce))
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

    def _signed_in(self) -> None:
        cookie = (
            f"{STATE.cookie_name}={STATE.cookie_value}; Path=/; HttpOnly; "
            "SameSite=Strict; Max-Age=31536000"
        )
        self._send(303, b"", "text/plain", [("Location", "/"), ("Set-Cookie", cookie)])

    def _signin_page(self, stale: bool) -> None:
        """What the address shows without a sign-in: what this is and how to get in."""
        self._nonce = secrets.token_urlsafe(16)
        self._send(403, signin_html(self._nonce, stale).encode("utf-8"), "text/html; charset=utf-8")

    def _public(self, path: str) -> bool:
        """The files any visitor on this Mac may fetch: the look, the icons and the manifest. They hold nothing private."""
        if path == "/settings.js":
            self._send(200, SETTINGS_JS.encode("utf-8"), "text/javascript; charset=utf-8")
        elif path == "/view.js":
            self._send(200, VIEW_JS.encode("utf-8"), "text/javascript; charset=utf-8")
        elif path == "/manifest.webmanifest":
            self._send(200, manifest_json().encode("utf-8"), "application/manifest+json")
        elif path == "/icon.svg":
            self._send(200, icon_svg().encode("utf-8"), "image/svg+xml", cache="max-age=3600")
        elif re.fullmatch(r"/icon-(\d+)\.png", path) and int(path[6:-4]) in ICON_SIZES:
            self._send(200, icon_png(int(path[6:-4])), "image/png", cache="max-age=3600")
        else:
            return False
        return True

    def do_GET(self) -> None:  # noqa: N802
        if not self._host_ok():
            self._text(403, "forbidden host")
            return
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        if parsed.path == "/" and "token" in query:
            if hmac.compare_digest(query["token"][0], STATE.token):
                self._signed_in()
            else:
                self._signin_page(stale=True)
            return
        if parsed.path == "/" and "code" in query:
            if use_signin_code(STATE.home, query["code"][0]):
                self._signed_in()
            else:
                self._signin_page(stale=True)
            return
        if self._public(parsed.path):
            return
        if not self._cookie_ok():
            if parsed.path == "/":
                self._signin_page(stale=False)
            else:
                self._text(403, "sign in first")
            return
        if parsed.path == "/":
            self._nonce = secrets.token_urlsafe(16)
            self._send(200, page_html(self._nonce, STATE.csrf, weekly_path(STATE.home).is_file()).encode("utf-8"),
                       "text/html; charset=utf-8")
        elif parsed.path == "/weekly":
            page = weekly_page(STATE.home)
            if page is None:
                self._text(404, "No weekly page has been written yet.")
                return
            # The page carries one inline <style> and no script, so the
            # response's nonce is the only thing it needs to render.
            self._nonce = secrets.token_urlsafe(16)
            body = page.replace("<style>", f'<style nonce="{self._nonce}">', 1)
            self._send(200, body.encode("utf-8"), "text/html; charset=utf-8")
        elif parsed.path.startswith("/api/picture/"):
            pid = parsed.path[len("/api/picture/"):]
            found = STATE.transcript.picture(pid) if PICTURE_ID_RE.match(pid) else None
            if found is None:
                self._text(404, "not found")
            else:
                self._send(200, found[0], found[1], cache="private, max-age=86400")
        elif parsed.path.startswith(FILE_HREF):
            self._file(unquote(parsed.path[len(FILE_HREF):]))
        elif parsed.path == "/api/conversation":
            try:
                payload = STATE.transcript.get()
            except OSError as exc:
                payload = {"state": "offline", "items": [], "note": f"cannot read the conversation: {exc}", "version": "error"}
            payload["suggestion"] = STATE.suggestion(payload.get("state") == "idle")
            payload["build"] = BUILD
            since = query.get("since", [""])[0]
            if since and since == payload.get("version"):
                self._json(200, {"version": since, "unchanged": True, "state": payload.get("state"),
                                 "since": payload.get("since"), "suggestion": payload["suggestion"],
                                 "build": BUILD})
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
        else:
            self._text(404, "not found")

    def _file(self, name: str) -> None:
        """One file a reply may link (home_file), read-only, in its own type."""
        found = None
        if not name.startswith("/") and ".." not in name.split("/"):
            found = home_file(STATE.home, name)
        data = None
        if found is not None:
            try:
                fd = os.open(found[1], os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
                with os.fdopen(fd, "rb") as handle:
                    data = handle.read(FILE_MAX + 1)
            except OSError:
                data = None
        if data is None or len(data) > FILE_MAX:
            self._text(404, "not found")
            return
        suffix = found[1].suffix.lower()
        policy = (FILE_SANDBOX_CSP if suffix in FILE_ACTIVE
                  else "default-src 'none'; img-src 'self' data:; style-src 'unsafe-inline'; "
                       "object-src 'self'; frame-ancestors 'none'")
        self._send(200, data, FILE_TYPES[suffix], policy=policy)

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
--bg:#ECE8E1;--surface:#FCFAF6;--surface-2:#F4F0E9;--ink:#2A2A28;--ink-2:#66625C;--line:#E2DBCF;--edge:#C9BFAE;
--hull:#FCFAF6;--hull-ink:#2A2A28;--hull-2:#66625C;--hull-line:#E2DBCF;--hull-soft:#F1EDE5;
--plate:#34373A;--plate-ink:#EDEBE6;--mic:#5B8496;
--here:#47707F;--here-bg:#E1ECF0;--on-here:#FFFFFF;
--work:#7E6431;--work-bg:#F6ECD4;--work-lamp:#DDBB79;
--done:#46735E;--done-bg:#DFEEE4;--done-lamp:#8CC2A2;
--you:#9F5749;--you-bg:#F7E2DC;--you-lamp:#DF9989;
--code:#EFEAE0;--shadow:0 1px 2px rgba(38,38,36,.05),0 4px 14px rgba(38,38,36,.06);
}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){
--bg:#13171A;--surface:#1C2226;--surface-2:#232A2F;--ink:#E6E9EB;--ink-2:#A0A9AE;--line:#2F373C;--edge:#4B565C;
--hull:#1C2226;--hull-ink:#E6E9EB;--hull-2:#A0A9AE;--hull-line:#2F373C;--hull-soft:#252D32;
--plate:#2A3236;--plate-ink:#E9EDEF;--mic:#5B8496;
--here:#9DC3D2;--here-bg:#21333B;--on-here:#10191D;
--work:#DDC796;--work-bg:#2F2A1F;--work-lamp:#CFB27A;
--done:#A8CFB8;--done-bg:#1F2F27;--done-lamp:#8DBCA1;
--you:#E5B0A2;--you-bg:#372623;--you-lamp:#D79686;
--code:#262D31;--shadow:0 1px 2px rgba(0,0,0,.22),0 4px 14px rgba(0,0,0,.2);
}}
:root[data-theme="dark"]{
--bg:#13171A;--surface:#1C2226;--surface-2:#232A2F;--ink:#E6E9EB;--ink-2:#A0A9AE;--line:#2F373C;--edge:#4B565C;
--hull:#1C2226;--hull-ink:#E6E9EB;--hull-2:#A0A9AE;--hull-line:#2F373C;--hull-soft:#252D32;
--plate:#2A3236;--plate-ink:#E9EDEF;--mic:#5B8496;
--here:#9DC3D2;--here-bg:#21333B;--on-here:#10191D;
--work:#DDC796;--work-bg:#2F2A1F;--work-lamp:#CFB27A;
--done:#A8CFB8;--done-bg:#1F2F27;--done-lamp:#8DBCA1;
--you:#E5B0A2;--you-bg:#372623;--you-lamp:#D79686;
--code:#262D31;--shadow:0 1px 2px rgba(0,0,0,.22),0 4px 14px rgba(0,0,0,.2);
}
/* Lively: the same page with stronger colours. Calm is the default. In light, the header is
   light too, as in Calm; --mark, --avatar, --good, --low, --critical and --alert-* are its accents. */
:root[data-style="lively"]{
--bg:#F1EBDF;--surface:#FDFAF4;--surface-2:#F6F1E7;--ink:#14232D;--ink-2:#4C5F6B;--line:#DDD5C5;--edge:#B9AE9B;
--hull:#FDFAF4;--hull-ink:#14232D;--hull-2:#4C5F6B;--hull-line:#DDD5C5;--hull-soft:#F6F1E7;
--mark:#0B6B88;--avatar:#143242;--good:#1F6F45;--low:#8F5C0B;--critical:#B5371F;--alert-bg:#FBE8E3;--alert-ink:#B5371F;
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
--mark:#8FD6EA;--avatar:#1B3442;--good:#8EDCAF;--low:#F0C36C;--critical:#FFB3A3;--alert-bg:#5A2118;--alert-ink:#FFD9CF;
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
--mark:#8FD6EA;--avatar:#1B3442;--good:#8EDCAF;--low:#F0C36C;--critical:#FFB3A3;--alert-bg:#5A2118;--alert-ink:#FFD9CF;
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
body{height:100%;margin:0;background:var(--bg);color:var(--ink);font:1rem/1.45 var(--font);-webkit-font-smoothing:antialiased}
button,textarea,input{font:inherit;color:inherit}
button{cursor:pointer}
h1,h2,h3,h4,p,ul,ol{margin:0;padding:0}
ul,ol{list-style:none}
svg{width:1em;height:1em;flex:none}
[hidden]{display:none!important}
:focus-visible{outline:2px solid var(--here);outline-offset:2px;border-radius:.375rem}
.app{display:flex;flex-direction:column;height:100dvh;min-height:0}
kbd,.kh{font:600 .68rem/1 ui-monospace,SFMono-Regular,Menlo,monospace;padding:.16rem .32rem;border:1px solid var(--line);border-bottom-width:2px;border-radius:.3rem;color:var(--ink-2);background:var(--surface-2);white-space:nowrap}
.kh{margin-left:.125rem;font-weight:500}
.btn.primary .kh{background:transparent;border-color:currentColor;color:inherit;opacity:.8}
[data-keys="hide"] .kh,[data-keys="hide"] .keystrip{display:none!important}

/* One slim header: the mark, the tabs, the lamps, the alert, the battery. */
.top{display:flex;align-items:center;gap:.375rem .875rem;padding:.3rem .75rem;background:var(--hull);color:var(--hull-ink);border-bottom:1px solid var(--hull-line);min-height:2.75rem}
.brand{display:flex;align-items:center;gap:.4rem;font-weight:600;font-size:.94rem;letter-spacing:.04em;white-space:nowrap}
.brand svg{color:var(--here);font-size:1.15rem}
.tabs{flex:1 1 auto;min-width:0;display:flex;gap:.125rem;overflow-x:auto;scrollbar-width:none}
.tabs::-webkit-scrollbar{display:none}
.tab{flex:none;border:0;background:none;padding:.3rem .65rem;font-size:.875rem;color:var(--hull-2);border-radius:.5rem;white-space:nowrap;box-shadow:inset 0 -2px 0 transparent}
.tab:hover{color:var(--hull-ink)}
.tab .dot{display:inline-block;margin-left:.375rem;vertical-align:.06rem}
.tab[aria-selected="true"]{color:var(--hull-ink);font-weight:600;background:var(--hull-soft);box-shadow:inset 0 -2px 0 var(--here)}
.band{display:flex;align-items:center;gap:.375rem .875rem;justify-content:flex-end;min-width:0}
.lamps{display:flex;gap:.375rem .75rem}
.lamp{display:flex;align-items:center;gap:.375rem;font-size:.84rem;white-space:nowrap}
.lamp i{width:.56rem;height:.56rem;border-radius:50%;border:1.5px solid var(--hull-2);opacity:.6}
.lamp b{font-weight:600;font-variant-numeric:tabular-nums}
.lamp:not(.lit){color:var(--hull-2)}
.lamp.lit i{border:0;opacity:1}
.lamp.work.lit i{background:var(--work-lamp)}
.lamp.you.lit i{background:var(--you-lamp)}
.lamp.done.lit i{background:var(--done-lamp)}
.band-note{font-size:.81rem;color:var(--hull-2)}
.alert{display:flex;align-items:center;gap:.375rem;font-size:.81rem;font-weight:600;background:var(--you-bg);color:var(--you);border-radius:999px;padding:.125rem .625rem;white-space:nowrap}
.alert i{width:.44rem;height:.44rem;border-radius:50%;background:var(--you-lamp);flex:none}
.aside{font-size:.81rem;color:var(--hull-2);white-space:nowrap;display:flex;align-items:center;gap:.3rem}
.aside svg{font-size:1.1rem}
.aside.good{color:var(--done)}.aside.low{color:var(--work)}.aside.critical{color:var(--you);font-weight:600}
.tools{display:flex;align-items:center;gap:.375rem}
.gear,.qbtn{flex:none;display:inline-flex;align-items:center;gap:.375rem;border:1px solid var(--hull-line);background:transparent;color:var(--hull-2);border-radius:.5rem;padding:.2rem .6rem;font-size:.81rem}
.qbtn{padding:.2rem .5rem;font-weight:600;text-decoration:none}
.gear:hover,.gear[aria-expanded="true"],.qbtn:hover,.qbtn[aria-expanded="true"]{color:var(--hull-ink);border-color:var(--edge)}
.gear svg{font-size:.95rem}
.lamp .s{display:none}
@media (max-width:92rem){.lamp .w{display:none}.lamp .s{display:inline}}
@media (max-width:105rem){.aside.night span{display:none}}

/* The two sides, with a divider that moves between them. */
.main{flex:1;min-height:0;display:grid;grid-template-columns:minmax(0,calc((100% - .75rem) * var(--split,.55))) .75rem minmax(0,1fr);padding:.5rem .625rem .375rem}
/* A project's tab: its Needs you beside the rest on a wide screen (.pp-cols). */
#project.main{display:block}
#project .pane{height:100%;max-width:84rem;margin:0 auto}
.divider{position:relative;cursor:col-resize;border-radius:.375rem;touch-action:none;outline-offset:-2px}
.divider::after{content:"";position:absolute;top:50%;left:50%;width:.25rem;height:2.75rem;transform:translate(-50%,-50%);border-radius:999px;background:var(--line);transition:background .15s}
.divider:hover::after,.divider:focus-visible::after,.divider.drag::after{background:var(--here)}
.divider:hover,.divider.drag{background:var(--here-bg)}
.pane{min-height:0;min-width:0;background:var(--surface);border:1px solid var(--line);border-radius:.875rem;display:flex;flex-direction:column;overflow:hidden}
.pane-head{display:flex;align-items:baseline;gap:.5rem;padding:.5rem .875rem .375rem;flex-wrap:wrap}
.pane-head h2{font-size:1rem;font-weight:600}
.pane-head .sub{font-size:.81rem;color:var(--ink-2)}
.pane-head .when{margin-left:auto;font-size:.81rem;color:var(--ink-2);font-variant-numeric:tabular-nums}
.state{display:inline-flex;align-items:center;gap:.375rem;font-size:.78rem;font-weight:600;border-radius:999px;padding:.06rem .56rem;background:var(--surface-2);color:var(--ink-2)}
.state.busy{background:var(--work-bg);color:var(--work)}
.state.offline{background:var(--you-bg);color:var(--you)}
.side-switch{display:none}
.state:empty{display:none}

#log{flex:1;min-height:0;overflow-y:auto;padding:.25rem 1rem .75rem}
.wrap{max-width:var(--wrap,48rem);margin:0 auto}
.msg{display:flex;margin:.625rem 0}
.msg.user{justify-content:flex-end}
.bubble{max-width:85%;padding:.5rem .75rem;border-radius:.875rem .875rem .25rem .875rem;background:var(--here-bg);overflow-wrap:anywhere}
.msg.assistant{gap:.625rem;align-items:flex-start}
.av{width:1.75rem;height:1.75rem;border-radius:50%;background:var(--surface-2);border:1px solid var(--line);color:var(--here);display:grid;place-items:center;font-size:1rem;flex:none;margin-top:.06rem}
.msg.assistant .bubble{max-width:100%;min-width:0;background:transparent;padding:.06rem 0;border-radius:0}
.bubble p{margin:.45em 0}.bubble p:first-child{margin-top:0}.bubble p:last-child{margin-bottom:0}
.bubble h3,.bubble h4,.bubble h5,.bubble h6{margin:.75em 0 .3em;font-size:1em}
.bubble h3{font-size:1.06em}
.bubble ul,.bubble ol{margin:.45em 0;padding-left:1.4em}
.bubble ul{list-style:disc}.bubble ol{list-style:decimal}
.bubble li+li{margin-top:.25em}
.bubble a{color:var(--here)}
.bubble code{background:var(--code);padding:.06em .3em;border-radius:.3em;font:.84em/1.4 ui-monospace,SFMono-Regular,Menlo,monospace}
.bubble pre{background:var(--code);padding:.5rem .7rem;border-radius:.5rem;overflow-x:auto}
.bubble pre code{background:none;padding:0}
.bubble blockquote{margin:.4em 0;padding-left:.75rem;border-left:3px solid var(--line);color:var(--ink-2)}
.bubble hr{border:none;border-top:1px solid var(--line);margin:.75em 0}
.table{overflow-x:auto}
.bubble table{border-collapse:collapse;margin:.4em 0;font-size:.9em}
.bubble th,.bubble td{border:1px solid var(--line);padding:.2rem .5rem;text-align:left;vertical-align:top}
.chip{display:inline-block;font-size:.78rem;color:var(--ink-2);margin-top:.25rem}
.pics{display:flex;gap:.375rem;flex-wrap:wrap;justify-content:flex-end}
.bubble>.pics:not(:first-child){margin-top:.375rem}
.pics a{display:block;line-height:0}
.pics img{height:4.5rem;max-width:10rem;object-fit:cover;border-radius:.5rem;border:1px solid var(--line);background:var(--surface)}
details.quiet{margin:.125rem 0 .125rem 2.375rem;font-size:.84rem;color:var(--ink-2)}
details.quiet summary{cursor:pointer;list-style:none;padding:.06rem 0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
details.quiet summary::-webkit-details-marker{display:none}
details.quiet summary::before{content:"\25B8";display:inline-block;width:1em;transition:transform .15s}
details.quiet[open] summary::before{transform:rotate(90deg)}
details.quiet.err summary{color:var(--you)}
/* While the first mate works: a moving mark, what it is doing, and for how long. */
.live{display:flex;align-items:center;gap:.5rem;margin:.375rem 0 .25rem 2.375rem;font-size:.84rem;color:var(--ink-2)}
.live[hidden]{display:none}
.msg.waiting{flex-direction:column;align-items:flex-end}
.msg.waiting .bubble{opacity:.55;border:1px dashed var(--edge)}
.msg.waiting .wait{margin-top:.25rem;font-size:.78rem;color:var(--ink-2)}
.live .what{min-width:0;overflow:hidden;white-space:nowrap;text-overflow:ellipsis}
.live .took{flex:none;font-variant-numeric:tabular-nums}
.live .dots{flex:none;display:inline-flex;gap:.2rem}
.live .dots i{width:.38rem;height:.38rem;border-radius:50%;background:var(--work);opacity:.6;animation:live 1.2s infinite ease-in-out}
.live .dots i:nth-child(2){animation-delay:.2s}
.live .dots i:nth-child(3){animation-delay:.4s}
@keyframes live{0%,80%,100%{opacity:.25;transform:scale(.75)}40%{opacity:1;transform:scale(1)}}
.steps-list{margin:.25rem 0 .375rem 1em;padding-left:.75rem;border-left:2px solid var(--line)}
.steps-list li{padding:.06rem 0;overflow-wrap:anywhere}
.steps-list li.err{color:var(--you)}
.compact{display:flex;align-items:center;gap:.625rem;margin:.75rem 0}
.compact::before,.compact::after{content:"";flex:1;border-top:1px dashed var(--line)}
.compact details{font-size:.78rem;color:var(--ink-2);text-align:center}
.compact details pre{text-align:left;white-space:pre-wrap;max-height:20rem;overflow:auto;background:var(--code);padding:.5rem;border-radius:.5rem}
.note{color:var(--ink-2);text-align:center;font-size:.84rem;margin:.625rem 0}
.note:empty{display:none}
#compose{border-top:1px solid var(--line);padding:.5rem .75rem .375rem;background:var(--surface)}
#compose .wrap{display:flex;flex-direction:column;gap:.3rem}
#row{display:flex;gap:.5rem;align-items:flex-end}
#input{flex:1;min-width:0;resize:none;min-height:2.5rem;max-height:12.5rem;padding:.5rem .75rem;border-radius:.625rem;border:1px solid var(--line);background:var(--bg);outline:none}
#input:focus{border-color:var(--here)}
#input::placeholder{color:var(--ink-2);opacity:1}
#input.suggested::placeholder{color:var(--ink-2);opacity:.85}
#thumbs{display:flex;gap:.375rem;flex-wrap:wrap}
#thumbs:empty{display:none}
.thumb{position:relative}
.thumb img{height:3.25rem;border-radius:.5rem;border:1px solid var(--line)}
.thumb button{position:absolute;top:-.375rem;right:-.375rem;border:none;border-radius:50%;width:1.25rem;height:1.25rem;background:var(--ink);color:var(--bg);font-size:.75rem;line-height:1.25rem;padding:0}
#foot{display:flex;gap:.25rem 1rem;align-items:baseline;justify-content:space-between;flex-wrap:wrap}
#result{font-size:.78rem;color:var(--ink-2);min-height:1em;margin-left:auto;text-align:right}
#result.failed{color:var(--you)}
body.drag #log{outline:2px dashed var(--here);outline-offset:-.5rem}

.btn{display:inline-flex;align-items:center;gap:.4rem;border:1px solid var(--line);background:var(--surface);border-radius:.56rem;padding:.375rem .7rem;font-size:.9rem;font-weight:500;white-space:nowrap}
.btn:hover:not(:disabled){border-color:var(--edge)}
.btn.primary{background:var(--here);border-color:var(--here);color:var(--on-here);font-weight:600}
.btn.small{padding:.25rem .56rem;font-size:.84rem}
.btn.plain{border-color:transparent;background:none;color:var(--here);padding-inline:.3rem}
.btn:disabled{opacity:.6;cursor:default}
.btn svg{font-size:1rem}
#send{height:2.5rem}

.p-top{padding:0 .875rem .5rem;border-bottom:1px solid var(--line)}
.sum{font-size:.9rem}
.sum b{font-weight:600}
.queue{font-size:.84rem;color:var(--ink-2);margin-top:.125rem}
.says{display:flex;flex-direction:column;align-items:flex-start;gap:.1rem}
.say{border:0;background:none;padding:0;text-align:left;font-size:.94rem;line-height:1.4;color:var(--ink)}
.say:hover{text-decoration:underline;text-underline-offset:.15em}
.say.c-you{color:var(--you);font-weight:600}
.say.c-work{color:var(--ink)}
.shelf{margin-top:.75rem;border-top:1px dashed var(--line);padding-top:.5rem}
.shelf>h4{font-size:.9rem;font-weight:600}
.shelf>.note-line{font-size:.84rem;color:var(--ink-2);margin:.1rem 0 .3rem}
.shelf ul{list-style:none;margin:0;padding:0}
.shelf li{display:flex;flex-wrap:wrap;align-items:baseline;gap:.25rem .6rem;padding:.3rem 0;border-bottom:1px solid var(--line)}
.shelf li:last-child{border-bottom:0}
.shelf li .t{flex:1 1 14rem;min-width:0;font-size:.9rem;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
.shelf li .w{font-size:.8rem;color:var(--ink-2);white-space:nowrap}
.shelf li .when{flex:none;width:6.5rem;font-size:.84rem;font-weight:600}
.shelf li .side{margin-left:auto;display:flex;flex-direction:column;align-items:flex-end;gap:.25rem}
.shelf li .rowb{display:flex;gap:.375rem;flex-wrap:wrap;justify-content:flex-end}
.shelf li .rowb .btn{padding:.125rem .5rem;font-size:.8rem}
.shelf li .confirm{text-align:right}
.shelf .group{font-size:.8rem;color:var(--ink-2);margin-top:.4rem;font-weight:600}
.alert-btn{border:0;font-family:inherit;cursor:pointer}
.notice{margin-top:.5rem;font-size:.875rem;border-radius:.56rem;padding:.375rem .7rem;font-weight:500}
.notice.ok{background:var(--done-bg);color:var(--done)}
.notice.info{background:var(--here-bg);color:var(--here)}
.notice.bad{background:var(--you-bg);color:var(--you)}
.p-body{flex:1;min-height:0;overflow-y:auto;padding:.625rem .875rem 1.25rem}
.sec+.sec{margin-top:1.125rem}
.sec>h3{font-size:.94rem;font-weight:600;display:flex;align-items:baseline;gap:.5rem;margin-bottom:.4rem}
.sec>h3 .n{font-size:.78rem;font-weight:600;border-radius:999px;padding:0 .45rem;background:var(--surface-2);color:var(--ink-2);border:1px solid var(--line)}
.sec>h3 small{font-size:.84rem;font-weight:400;color:var(--ink-2)}
.empty{font-size:.9rem;color:var(--ink-2)}
.urgent-line{font-size:.875rem;margin-bottom:.4rem;color:var(--you)}
.urgent-line b{font-weight:600}

.call{border:1px solid var(--line);border-radius:.7rem;background:var(--surface)}
.call+.call{margin-top:.375rem}
.call.open{border-color:var(--edge);box-shadow:var(--shadow)}
.call.flash{animation:flash 1.2s ease-out}
@keyframes flash{0%{background:var(--here-bg)}100%{background:var(--surface)}}
.call.hl,.proj.hl,.quiet-facs li.hl{outline:2px solid var(--here);outline-offset:1px}
.call-row{width:100%;border:0;background:none;text-align:left;display:flex;align-items:center;gap:.56rem;padding:.45rem .7rem;border-radius:.7rem}
.dot{width:.5rem;height:.5rem;border-radius:50%;flex:none;background:var(--edge)}
.dot.you{background:var(--you-lamp)}.dot.done{background:var(--done-lamp)}.dot.work{background:var(--work-lamp)}.dot.here{background:var(--here)}
.call-title{flex:1;min-width:0;font-weight:600;font-size:.9rem;overflow:hidden;overflow-wrap:anywhere;display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:2;line-clamp:2}
.call.open .call-title{display:block;-webkit-line-clamp:unset;line-clamp:none;font-size:.94rem}
.call-meta{flex:none;max-width:45%;font-size:.8rem;color:var(--ink-2);text-align:right;display:flex;flex-direction:column;line-height:1.25}
.call-body{padding:0 .7rem .7rem 1.75rem}
.call-body>*+*{margin-top:.5rem}
.why{font-size:.9rem}
.opts{display:grid;gap:.3rem}
.opt{display:flex;align-items:center;gap:.56rem;width:100%;text-align:left;border:1px solid var(--line);border-radius:.56rem;background:var(--surface);padding:.4rem .65rem;font-size:.9rem}
.opt:hover:not(:disabled){border-color:var(--here)}
.opt:disabled{cursor:default}
.opt .ring{width:.94rem;height:.94rem;border-radius:50%;border:1.5px solid var(--ink-2);flex:none;display:grid;place-items:center}
.opt.picked{border-color:var(--here);background:var(--here-bg)}
.opt.picked .ring{border-color:var(--here)}
.opt.picked .ring::after{content:"";width:.45rem;height:.45rem;border-radius:50%;background:var(--here)}
.opt .l{flex:1;min-width:0}
.tag{font-size:.75rem;font-weight:600;color:var(--here);background:var(--here-bg);border-radius:999px;padding:.03rem .5rem;white-space:nowrap}
.tag.urgent{color:var(--you);background:var(--you-bg)}
.tag.first{color:var(--you);background:var(--you-bg)}
.opt.picked .tag{background:var(--surface)}
.confirm,.talk{border:1px solid var(--edge);border-radius:.7rem;padding:.6rem .75rem;background:var(--surface)}
.confirm p{font-size:.9rem}
.unsent{font-size:.8rem;color:var(--ink-2)}
.talk .unsent{margin-top:.4rem}
.rowb{display:flex;flex-wrap:wrap;gap:.4rem;align-items:center;margin-top:.5rem}
.call-body>.rowb{margin-top:.5rem}
.pr-short{display:grid;grid-template-columns:max-content 1fr;gap:.25rem .8rem;margin:0;font-size:.9rem}
.pr-short dt{color:var(--ink-2)}
.pr-short dd{margin:0}
.holds{font-size:.84rem;color:var(--ink-2)}
.holds a{color:var(--here);overflow-wrap:anywhere}
.said{font-size:.875rem;border-radius:.56rem;padding:.375rem .7rem;background:var(--here-bg);color:var(--here);font-weight:500}
.talk-head{font-size:.84rem;font-weight:600}
.talk textarea{display:block;width:100%;margin-top:.4rem;border:1px solid var(--line);border-radius:.56rem;padding:.45rem .7rem;background:var(--bg);resize:vertical;outline:none}
.talk textarea:focus{border-color:var(--here)}
.lk{color:var(--here);text-decoration:underline;text-decoration-color:var(--line);text-underline-offset:.2rem}

.clip{display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:2;line-clamp:2;overflow:hidden;overflow-wrap:anywhere}
.clip.over{cursor:pointer}
.clip.full{display:block;-webkit-line-clamp:unset;line-clamp:none}

.proj{border-top:1px solid var(--line);padding:.56rem .25rem;border-radius:.375rem}
.proj:first-of-type{border-top:0;padding-top:.125rem}
.proj-head{display:flex;align-items:center;gap:.25rem .625rem;flex-wrap:wrap}
.proj-name{border:0;background:none;padding:0;font-weight:600;font-size:.94rem;text-decoration:underline;text-decoration-color:var(--line);text-underline-offset:.25rem}
.proj-name:hover{text-decoration-color:var(--here);color:var(--here)}
.badge{font-size:.75rem;font-weight:600;border-radius:999px;padding:.03rem .5rem;background:var(--you-bg);color:var(--you)}
.told{display:grid;grid-template-columns:3rem minmax(0,1fr);gap:.375rem .56rem;margin-top:.45rem}
.told dt{font-size:.78rem;font-weight:600;color:var(--ink-2);padding-top:.12rem}
.told dd{margin:0;min-width:0;font-size:.875rem}
.told dd>p+p,.told dd>p+.job,.told dd>p+.jobline{margin-top:.3rem}
.told dd>.job:first-child,.told dd>.jobline:first-child,.told dd>.line:first-child{margin-top:0}
.told .jobline .w{white-space:normal;text-align:right}
@media (max-width:40rem){.told{grid-template-columns:minmax(0,1fr);gap:.2rem}.told dt{padding-top:.3rem}}
.news time{color:var(--ink-2);font-size:.8rem;font-variant-numeric:tabular-nums;margin-right:.45rem}
.verb{font-weight:600;margin-right:.3rem;color:var(--ink-2)}
.verb.done{color:var(--done)}.verb.work{color:var(--work)}.verb.you{color:var(--you)}.verb.here{color:var(--here)}
.news .btn{margin-left:.45rem}
.quiet-facs{border-top:1px solid var(--line);padding:.56rem .25rem 0;margin-top:.25rem}
.quiet-facs h4{font-size:.84rem;font-weight:600;color:var(--ink-2)}
.quiet-facs li{display:flex;flex-wrap:wrap;gap:.1rem .625rem;align-items:baseline;margin-top:.3rem;font-size:.875rem}
.quiet-facs .w{color:var(--ink-2)}
.steer-note{margin-left:auto;font-size:.8rem;color:var(--here);font-weight:600}
.seg{display:flex;border:1px solid var(--line);border-radius:.45rem;overflow:hidden;background:var(--surface)}
.seg button{border:0;background:none;padding:.1rem .56rem;font-size:.8rem;color:var(--ink-2)}
.seg button[aria-pressed="true"]{background:var(--here-bg);color:var(--ink);font-weight:600}
.job{margin-top:.45rem;border-radius:.625rem;background:var(--surface-2);padding:.5rem .7rem}
.job-top{display:flex;gap:.56rem;align-items:baseline}
.job-top .dot{align-self:center}
.job-title{flex:1;min-width:0;font-weight:600;font-size:.9rem}
.mins{font-size:.8rem;color:var(--ink-2);white-space:nowrap;font-variant-numeric:tabular-nums}
.steps{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:.25rem;margin-top:.45rem}
.steps li{font-size:.78rem;color:var(--ink-2);padding-top:.3rem;border-top:.2rem solid var(--line);border-radius:.125rem;line-height:1.2;display:flex;gap:.2rem;align-items:flex-start}
.steps li svg{font-size:.84rem;margin-top:.03rem}
.steps li.done{border-top-color:var(--done-lamp);color:var(--done)}
.steps li.now{border-top-color:var(--work-lamp);color:var(--work);font-weight:600}
.job-foot{display:flex;justify-content:space-between;align-items:baseline;gap:.2rem .7rem;flex-wrap:wrap;margin-top:.4rem}
.doing{font-size:.875rem;flex:1 1 13rem}
.doing.quiet{color:var(--work);font-weight:500}
.job-foot .btn{margin-left:auto}
/* A row too narrow for its title and its state puts the state under the title, never squeezing the title. */
.jobline{display:flex;flex-wrap:wrap;gap:0 .56rem;align-items:baseline;margin-top:.375rem;font-size:.9rem}
.jobline .dot{align-self:center}
.jobline .t{flex:1 1 14rem;min-width:0}
.jobline .w{margin-left:auto;font-size:.8rem;color:var(--ink-2);white-space:nowrap}
.jobline .w.you{color:var(--you)}.jobline .w.done{color:var(--done)}.jobline .w.work{color:var(--work)}
.jobline.sel{border-radius:.5rem;box-shadow:0 0 0 3px var(--here-bg);background:var(--here-bg);padding:.15rem .4rem}
.line{font-size:.84rem;color:var(--ink-2);margin-top:.375rem;display:flex;gap:.45rem;flex-wrap:wrap}
.line b{font-weight:600;color:var(--ink)}
.line .r{margin-left:auto}
.feed li{display:grid;grid-template-columns:4rem minmax(0,1fr);gap:.125rem .56rem;padding:.375rem 0;border-top:1px solid var(--line);font-size:.875rem}
.feed li:first-child{border-top:0}
.feed time{color:var(--ink-2);font-variant-numeric:tabular-nums;font-size:.8rem;padding-top:.06rem}
.feed .who{font-weight:600}
.word{font-size:.75rem;font-weight:600;border-radius:999px;padding:.03rem .5rem;margin:0 .25rem;white-space:nowrap;background:var(--surface-2);color:var(--ink-2)}
.word.you{background:var(--you-bg);color:var(--you)}.word.done{background:var(--done-bg);color:var(--done)}
.word.here{background:var(--here-bg);color:var(--here)}.word.work{background:var(--work-bg);color:var(--work)}

.pp-head{padding:.625rem .875rem .5rem;border-bottom:1px solid var(--line)}
.pp-head h2{font-size:1.125rem;font-weight:600}
.pp-head>p{color:var(--ink-2);font-size:.875rem}
.pp-head .about{color:var(--ink-2);font-size:.875rem}
.pp-state{font-size:.9rem;margin-top:.2rem}
.pp-state.you{color:var(--you)}
.pp-col .news{font-size:.875rem;margin-top:.3rem}
.pp-head .acts{align-items:center;gap:.4rem .9rem;flex-wrap:wrap;margin-top:.5rem}
.steer-line{font-size:.82rem;color:var(--ink-2)}
.lk-btn{border:0;background:none;padding:0;font:inherit;color:var(--here);text-decoration:underline;text-underline-offset:.2rem;cursor:pointer}
.lk-btn:disabled{opacity:.6;cursor:default}
/* A wide tab sets Needs you beside the rest; a narrow one, or one with nothing that needs you, is one column. */
.pp-cols{display:grid;grid-template-columns:minmax(0,1.15fr) minmax(0,1fr);gap:0 .75rem;align-items:start}
.pp-cols.one{grid-template-columns:minmax(0,1fr)}
.pp-col{min-width:0}
.pp-cols.one .pp-col{max-width:48rem}
.dated li{display:grid;grid-template-columns:7.5rem minmax(0,1fr);gap:.56rem;padding:.3rem 0;border-top:1px solid var(--line);font-size:.9rem}
.dated li:first-child{border-top:0}
.dated .when{color:var(--ink-2);font-size:.82rem;font-variant-numeric:tabular-nums;padding-top:.05rem}
.sec>h4{font-size:.84rem;font-weight:600;color:var(--ink-2);margin-top:.6rem}
.all{font-size:.84rem;color:var(--ink-2);margin-top:.5rem}
.list li{padding:.375rem 0;border-top:1px solid var(--line);font-size:.9rem;display:flex;gap:.56rem;align-items:baseline}
.list li:first-child{border-top:0}
.list li>span:first-child{flex:1;min-width:0}
.list .w{margin-left:auto;font-size:.8rem;color:var(--ink-2);white-space:nowrap}
.bul li{font-size:.9rem;padding-left:1rem;position:relative}
.bul li+li{margin-top:.3rem}
.bul li::before{content:"";position:absolute;left:.125rem;top:.62em;width:.3rem;height:.3rem;border-radius:50%;background:var(--ink-2)}
.bul time{color:var(--ink-2);font-size:.8rem;margin-right:.5rem}
.warn{color:var(--you)}.near{color:var(--work)}

/* The primary's own part of the terminal's status bar row, word for word, under the message box. */
.statusrow{min-width:0;font-size:.78rem;color:var(--ink-2);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-variant-numeric:tabular-nums}
.statusrow[hidden]{display:none}
.statusrow .t-green{color:var(--done)}.statusrow .t-yellow{color:var(--work)}
.statusrow .t-red,.statusrow .t-magenta{color:var(--you)}.statusrow .t-alarm{color:var(--you);font-weight:700}
.statusrow .t-cyan{color:var(--here)}.statusrow .t-dim{opacity:.7}.statusrow .t-bold{color:var(--ink);font-weight:600}
.keystrip{display:flex;gap:.2rem 1rem;flex-wrap:wrap;align-items:center;padding:.125rem .875rem .375rem;font-size:.75rem;color:var(--ink-2);min-height:1.5rem}
.keystrip span{display:inline-flex;align-items:center;gap:.3rem;white-space:nowrap}
.keystrip.confirming{color:var(--here);font-weight:600}

.settings,.sheet{position:fixed;z-index:30;background:var(--surface);border:1px solid var(--edge);border-radius:.875rem;box-shadow:var(--shadow),0 12px 36px rgba(0,0,0,.14);overflow-y:auto}
.settings{top:3rem;right:.75rem;width:21rem;max-width:calc(100vw - 1.5rem);max-height:calc(100dvh - 3.75rem);padding:.875rem 1rem 1rem}
.sheet{top:50%;left:50%;transform:translate(-50%,-50%);width:30rem;max-width:calc(100vw - 2rem);max-height:calc(100dvh - 2rem);padding:1rem 1.125rem 1.125rem}
.settings h2,.sheet h2{font-size:1rem;font-weight:600;display:flex;align-items:center}
.settings h2 button,.sheet h2 button{margin-left:auto}
.sheet table{width:100%;border-collapse:collapse;margin-top:.625rem;font-size:.9rem}
.sheet td{padding:.3rem .25rem;border-top:1px solid var(--line);vertical-align:baseline}
.sheet td:first-child{white-space:nowrap;width:1%;padding-right:.875rem}
.sheet tr:first-child td{border-top:0}
.set{margin-top:.875rem}
.set>label,.set>.lbl{display:flex;align-items:baseline;gap:.5rem;font-size:.875rem;font-weight:600}
.set .now{margin-left:auto;font-weight:400;color:var(--ink-2);font-size:.8rem}
.hint{font-size:.8rem;color:var(--ink-2);margin-top:.25rem}
.settings>.hint{margin-top:.875rem}
.size-row{display:flex;align-items:center;gap:.625rem;margin-top:.45rem}
.size-row .a{color:var(--ink-2);line-height:1}
.size-row .a.s{font-size:.8rem}.size-row .a.l{font-size:1.45rem}
.size-row input{flex:1;min-width:0;accent-color:var(--here)}
.set .seg{margin-top:.45rem}
.set .seg button{flex:1;padding:.3rem .5rem;font-size:.875rem}
.switch{display:flex;align-items:center;gap:.56rem;margin-top:.45rem;font-size:.875rem;font-weight:400}
.switch input{width:1.06rem;height:1.06rem;accent-color:var(--here)}
.set .btn{margin-top:.45rem}
.swatches{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:.4rem;margin-top:.45rem}
.swatches button{display:flex;flex-direction:column;align-items:center;gap:.25rem;border:1px solid var(--line);border-radius:.5rem;background:var(--surface);padding:.35rem .2rem .3rem;font-size:.75rem;color:var(--ink-2)}
.swatches button[aria-pressed="true"]{border-color:var(--here);box-shadow:0 0 0 2px var(--here-bg);color:var(--ink);font-weight:600}
.sw{display:flex;width:2.25rem;height:1.25rem;border-radius:.3rem;overflow:hidden;border:1px solid var(--edge)}
.sw i{flex:1}
.sw.own{background:conic-gradient(#e0605a,#e6b84c,#6cbf73,#4fa6d9,#9a7ad8,#e0605a)}
.pickers{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:.4rem;margin-top:.5rem}
.pickers[hidden]{display:none}
.pick{display:flex;flex-direction:column;align-items:center;gap:.2rem;font-size:.8rem;color:var(--ink-2)}
.pick input{width:100%;height:2rem;padding:0;border:1px solid var(--edge);border-radius:.4rem;background:var(--surface);cursor:pointer}
#colourNote:empty{display:none}
#colourNote{color:var(--you)}

/* Calm: pastel tints and gentle contrast, with the same clear grouping Lively
   has: each section of a panel is its own soft card, and the counts, the open
   call and the section badges carry their pastel colour. Lively is untouched. */
:root:not([data-style="lively"]) .top{box-shadow:var(--shadow)}
:root:not([data-style="lively"]) .sec{background:var(--surface-2);border:1px solid var(--line);border-radius:.8rem;padding:.6rem .7rem .7rem}
:root:not([data-style="lively"]) .sec+.sec{margin-top:.75rem}
:root:not([data-style="lively"]) .sec .job{background:var(--surface);border:1px solid var(--line)}
:root:not([data-style="lively"]) .sum .c-work{color:var(--work)}
:root:not([data-style="lively"]) .sum .c-you{color:var(--you)}
:root:not([data-style="lively"]) .sum .c-done{color:var(--done)}
:root:not([data-style="lively"]) .sec>h3 .n{background:var(--you-bg);color:var(--you);border-color:transparent}
:root:not([data-style="lively"]) .call.open{border-color:var(--you-lamp);box-shadow:0 0 0 3px var(--you-bg)}
:root:not([data-style="lively"]) .call.fin.open{border-color:var(--done-lamp);box-shadow:0 0 0 3px var(--done-bg)}
:root:not([data-style="lively"]) .job.sel{box-shadow:0 0 0 3px var(--here-bg)}

/* Lively's stronger marks */
[data-style="lively"] .top{border-bottom-color:transparent;box-shadow:var(--shadow)}
[data-style="lively"] .brand svg{color:var(--mark)}
[data-style="lively"] .lamp.work.lit i{box-shadow:0 0 0 .2rem rgba(230,169,58,.22)}
[data-style="lively"] .lamp.you.lit i{box-shadow:0 0 0 .2rem rgba(238,100,71,.24)}
[data-style="lively"] .lamp.done.lit i{box-shadow:0 0 0 .2rem rgba(73,182,120,.24)}
[data-style="lively"] .alert{background:var(--alert-bg);color:var(--alert-ink)}
[data-style="lively"] .aside.good{color:var(--good)}
[data-style="lively"] .aside.low{color:var(--low)}
[data-style="lively"] .aside.critical{color:var(--critical)}
[data-style="lively"] .tab[aria-selected="true"]{box-shadow:inset 0 -2px 0 var(--mark)}
[data-style="lively"] .av{background:var(--avatar);color:#8FD6EA;border-color:transparent}
[data-style="lively"] .sum .c-work{color:var(--work)}
[data-style="lively"] .sum .c-you{color:var(--you)}
[data-style="lively"] .sum .c-done{color:var(--done)}
[data-style="lively"] .sec>h3 .n{background:var(--you-bg);color:var(--you);border-color:transparent}
[data-style="lively"] .call.open{border-color:var(--you);box-shadow:0 0 0 3px var(--you-bg)}
[data-style="lively"] .call.fin.open{border-color:var(--done);box-shadow:0 0 0 3px var(--done-bg)}
[data-style="lively"] .confirm,[data-style="lively"] .talk{border:1.5px solid var(--here)}
[data-style="lively"] .seg button[aria-pressed="true"],[data-style="lively"] .side-switch button[aria-pressed="true"]{background:var(--ink);color:var(--bg)}
[data-style="lively"] .job .job-top .dot.work{animation:glow 2s infinite ease-in-out}
@keyframes glow{50%{box-shadow:0 0 0 .3rem rgba(230,169,58,.25)}}
[data-style="lively"] .job.sel{box-shadow:0 0 0 3px var(--here-bg)}

@media (max-width:61rem){
.app{height:auto;min-height:100dvh}
.top{flex-wrap:wrap;padding:.375rem .625rem}
.tools{order:2;margin-left:auto}
.band{order:4;flex-basis:100%;flex-wrap:wrap;justify-content:flex-start;gap:.25rem .75rem}
.tabs{order:5;flex-basis:100%}
.main{display:block;padding:.5rem}
#home .divider{display:none}
.pane{overflow:visible}
.pane+.pane{margin-top:.5rem}
#log,.p-body{overflow:visible}
.side-switch{display:flex;margin:.5rem .5rem 0;border:1px solid var(--line);border-radius:.625rem;overflow:hidden;background:var(--surface)}
.side-switch button{flex:1;border:0;background:none;padding:.45rem;font-size:.9rem;color:var(--ink-2)}
.side-switch button[aria-pressed="true"]{background:var(--here-bg);color:var(--ink);font-weight:600}
.main[data-side="chat"] #panelPane,.main[data-side="projects"] #chatPane{display:none}
#project .pane{height:auto}
.pp-cols{grid-template-columns:minmax(0,1fr)}
.dated li{grid-template-columns:5.6rem minmax(0,1fr)}
.gear span{display:none}
#compose{position:sticky;bottom:0;border-radius:0 0 .875rem .875rem}
.settings{right:.5rem}
.keystrip{display:none}
}
@media (max-width:32rem){
.call-body{padding-left:.7rem}
.steps li{font-size:.72rem}
}
/* A screen worked by touch has no keys to hint at. */
@media (hover:none) and (pointer:coarse){.kh,.keystrip{display:none!important}}
@media (prefers-reduced-motion:reduce){*,*::before,*::after{animation:none!important;transition:none!important}}
[data-motion="less"] *,[data-motion="less"] *::before,[data-motion="less"] *::after{animation:none!important;transition:none!important}

/* The page a visitor sees before signing in. */
.sym{position:absolute;width:0;height:0;overflow:hidden}
.gate{min-height:100dvh;display:grid;place-items:center;padding:1.5rem 1rem}
.gate-card{width:34rem;max-width:100%;background:var(--surface);border:1px solid var(--line);border-radius:1rem;box-shadow:var(--shadow);padding:1.5rem 1.5rem 1.25rem}
.gate-card .mark{display:flex;align-items:center;gap:.6rem;font-size:1.25rem;font-weight:600;letter-spacing:.04em}
.gate-card .mark svg{font-size:2rem;color:var(--here)}
.gate-card>p{margin-top:.75rem;color:var(--ink-2)}
.gate-card h2{font-size:1rem;font-weight:600;margin-top:1.125rem}
.gate-card ol{list-style:decimal;padding-left:1.25rem;margin-top:.375rem}
.gate-card li{margin-top:.375rem}
.gate-card code{background:var(--code);padding:.06em .35em;border-radius:.3em;font:.88em/1.4 ui-monospace,SFMono-Regular,Menlo,monospace}
.gate-card .notice{margin-top:.875rem}
.gate-card .hint{margin-top:1rem}
"""

# The settings are a script of their own so they can be run without a browser.
SETTINGS_JS = r"""
/* The page's settings: how they are kept in this browser and put on the page.
   Kept apart from the page's own script so they can be run on their own. */
(function (root) {
  'use strict';
  var KEY = 'fm-web-settings.v2';
  /* The first version's key: its look carries over, its text size does not,
     since its steps were not these. */
  var OLD_KEY = 'fm-web-settings';
  /* Text size steps, as a percentage of the browser's own size; Normal is the middle one. */
  var TEXT_STEPS = [80, 90, 100, 120, 145];
  var TEXT_NAMES = ['Smaller', 'Small', 'Normal', 'Large', 'Largest'];
  /* The chat column's widest, in rem at Normal. Below Normal it keeps Normal's
     width on the screen, so smaller text fits more words on a line; from
     Normal up it scales with the text. */
  var WRAP_REM = 48;
  /* Where each divider sits, as the share the first panel takes, and how far it may go. */
  var SPLITS = { split: [0.25, 0.75] };
  /* The ready-made colour schemes, each an accent, a background and a text
     colour for light and for dark. Default is the page's own colours, with
     nothing put over them; Custom is the person's own three, kept for light
     and for dark apart. */
  var SCHEMES = {
    sea: { name: 'Sea', light: { accent: '#1f6a85', bg: '#e3edf0', ink: '#15303a' },
           dark: { accent: '#7fc8e0', bg: '#0f1d23', ink: '#e2eef2' } },
    green: { name: 'Green', light: { accent: '#3b6a45', bg: '#e5eae0', ink: '#222b24' },
             dark: { accent: '#9ccb9f', bg: '#121a14', ink: '#e3ece4' } },
    warm: { name: 'Warm', light: { accent: '#a64e28', bg: '#f4e8de', ink: '#33241c' },
            dark: { accent: '#f0a47d', bg: '#1e1612', ink: '#f2e8e1' } },
    slate: { name: 'Slate', light: { accent: '#4a5ba8', bg: '#e6e8ee', ink: '#22252e' },
             dark: { accent: '#a3b1f0', bg: '#14161c', ink: '#e6e8ef' } },
    paper: { name: 'Paper', light: { accent: '#2f5f7a', bg: '#f4ecdc', ink: '#2b2620' },
             dark: { accent: '#8fb8cf', bg: '#1f1c18', ink: '#ece3d1' } }
  };
  var COLOURS = ['default'].concat(Object.keys(SCHEMES), ['custom']);
  var PICKS = ['accent', 'bg', 'ink'];
  /* Text, and the accent, must reach this contrast on every background they
     sit on (the usual 4.5 to 1 for readable text). */
  var READABLE = 4.5;
  var DEFAULTS = { text: 2, style: 'calm', theme: 'auto', motion: 'auto', keys: 'show', split: 0.55,
                   colours: 'default', custom: null };
  var CHOICES = { style: ['calm', 'lively'], theme: ['auto', 'light', 'dark'], motion: ['auto', 'less'],
                  keys: ['show', 'hide'], colours: COLOURS };

  /* Whatever comes in, a whole and valid set of settings comes out. */
  function clean(given) {
    var out = {};
    Object.keys(DEFAULTS).forEach(function (name) { out[name] = DEFAULTS[name]; });
    if (!given || typeof given !== 'object') return out;
    if (typeof given.text === 'number' && given.text === Math.floor(given.text) &&
        given.text >= 0 && given.text < TEXT_STEPS.length) out.text = given.text;
    Object.keys(CHOICES).forEach(function (name) {
      if (CHOICES[name].indexOf(given[name]) >= 0) out[name] = given[name];
    });
    Object.keys(SPLITS).forEach(function (name) {
      var value = given[name], range = SPLITS[name];
      if (typeof value === 'number' && isFinite(value)) {
        out[name] = Math.round(Math.min(range[1], Math.max(range[0], value)) * 1000) / 1000;
      }
    });
    out.custom = cleanCustom(given.custom);
    return out;
  }

  function isHex(value) { return typeof value === 'string' && /^#[0-9a-f]{6}$/i.test(value); }

  /* Custom colours: for light and for dark, three colours or nothing. */
  function cleanCustom(given) {
    if (!given || typeof given !== 'object') return null;
    var out = { light: null, dark: null }, any = false;
    ['light', 'dark'].forEach(function (mode) {
      var set = given[mode];
      if (set && typeof set === 'object' && PICKS.every(function (k) { return isHex(set[k]); })) {
        out[mode] = {};
        PICKS.forEach(function (k) { out[mode][k] = set[k].toLowerCase(); });
        any = true;
      }
    });
    return any ? out : null;
  }

  /* ---- colour sums ---- */
  function rgb(h) { return [1, 3, 5].map(function (i) { return parseInt(h.slice(i, i + 2), 16); }); }
  function hex(c) {
    return '#' + c.map(function (v) { return ('0' + Math.round(Math.min(255, Math.max(0, v))).toString(16)).slice(-2); }).join('');
  }
  function mix(a, b, share) {
    var x = rgb(a), y = rgb(b);
    return hex([0, 1, 2].map(function (i) { return x[i] + (y[i] - x[i]) * share; }));
  }
  function luminance(h) {
    var c = rgb(h).map(function (v) {
      v /= 255;
      return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
    });
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
  }
  function contrast(a, b) {
    var x = luminance(a), y = luminance(b);
    return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
  }
  function least(fg, backs) {
    return Math.min.apply(null, backs.map(function (b) { return contrast(fg, b); }));
  }
  /* The colour itself when it reads on every background given, else the
     nearest shade of it that does: moved toward black or white, whichever
     reads better on all of them. */
  function readable(fg, backs, min) {
    if (least(fg, backs) >= min) return fg;
    var to = least('#000000', backs) >= least('#ffffff', backs) ? '#000000' : '#ffffff';
    for (var step = 1; step <= 50; step++) {
      var shade = mix(fg, to, step / 50);
      if (least(shade, backs) >= min) return shade;
    }
    return to;
  }

  var STATUS = ['work', 'done', 'you', 'good', 'low', 'critical'];

  /* The whole page's colours from an accent, a background and a text colour.
     status holds the Style's own state colours (work, done, you and Lively's
     good, low, critical) as the page shows them, so each can be kept readable
     on the new background. nudged names the picks that were too faint and are
     shown as the nearest readable shade instead. A mid-grey background on
     which neither black nor white text reads is lifted until black does. */
  function palette(picks, status) {
    var bg = picks.bg, dark = luminance(bg) < 0.18, nudged = [];
    var backsOf = function (b) { return [b, mix(b, '#ffffff', dark ? 0.05 : 0.7), mix(b, '#ffffff', dark ? 0.09 : 0.35)]; };
    if (dark && least('#ffffff', backsOf(bg)) < READABLE) dark = false;
    if (!dark) {
      var lifted = readable(bg, ['#000000'], READABLE);
      if (lifted !== bg) { bg = lifted; nudged.push('bg'); }
    }
    var backs = backsOf(bg), surface = backs[1], surface2 = backs[2];
    var ink = readable(picks.ink, backs, READABLE);
    if (ink !== picks.ink) nudged.push('ink');
    var accent = readable(picks.accent, backs, READABLE);
    if (accent !== picks.accent) nudged.push('accent');
    var ink2 = readable(mix(ink, bg, 0.35), backs, READABLE);
    var line = mix(bg, ink, dark ? 0.14 : 0.1), edge = mix(bg, ink, dark ? 0.28 : 0.22);
    var vars = {
      '--bg': bg, '--surface': surface, '--surface-2': surface2, '--ink': ink, '--ink-2': ink2,
      '--line': line, '--edge': edge, '--code': mix(bg, ink, 0.06),
      '--hull': surface, '--hull-ink': ink, '--hull-2': ink2, '--hull-line': line, '--hull-soft': surface2,
      '--here': accent, '--here-bg': mix(surface, accent, 0.14), '--mark': accent,
      '--on-here': contrast('#ffffff', accent) >= contrast('#111111', accent) ? '#ffffff' : '#111111',
      'color-scheme': dark ? 'dark' : 'light'
    };
    Object.keys(status || {}).forEach(function (name) {
      if (STATUS.indexOf(name) < 0 || !isHex(status[name])) return;
      var shade = readable(status[name].toLowerCase(), [surface, surface2], READABLE);
      vars['--' + name] = shade;
      if (name === 'work' || name === 'done' || name === 'you') vars['--' + name + '-bg'] = mix(surface, shade, 0.14);
      if (name === 'critical') { vars['--alert-ink'] = shade; vars['--alert-bg'] = mix(surface, shade, 0.14); }
    });
    return { vars: vars, nudged: nudged, dark: dark };
  }
  /* Every property a colour scheme may put on the page, so the next one starts clean. */
  var COLOUR_PROPS = Object.keys(palette({ accent: '#000000', bg: '#ffffff', ink: '#000000' },
    { work: '#000000', done: '#000000', you: '#000000', good: '#000000', low: '#000000', critical: '#000000' }).vars);

  /* Whether the page is dark now: the setting, or with Auto this computer's. */
  function isDark(settings, systemDark) {
    var kept = clean(settings);
    return kept.theme === 'dark' || (kept.theme === 'auto' && !!systemDark);
  }

  /* The three colours the page wears in light or dark, or null for the page's own. */
  function picksFor(settings, dark) {
    var kept = clean(settings), mode = dark ? 'dark' : 'light';
    if (kept.colours === 'custom') return kept.custom ? kept.custom[mode] : null;
    return SCHEMES[kept.colours] ? SCHEMES[kept.colours][mode] : null;
  }

  /* The page's own colours, from its Style and light or dark, as it shows
     them with no scheme on: its three picks and its state colours. */
  function own(element) {
    var out = { picks: null, status: {} }, saved = {};
    if (typeof getComputedStyle !== 'function') return out;
    COLOUR_PROPS.forEach(function (name) {
      saved[name] = element.style.getPropertyValue(name);
      element.style.removeProperty(name);
    });
    var style = getComputedStyle(element);
    function read(name) {
      var value = String(style.getPropertyValue(name) || '').trim().toLowerCase();
      return isHex(value) ? value : null;
    }
    var picks = { accent: read('--here'), bg: read('--bg'), ink: read('--ink') };
    if (picks.accent && picks.bg && picks.ink) out.picks = picks;
    STATUS.forEach(function (name) { var value = read('--' + name); if (value) out.status[name] = value; });
    COLOUR_PROPS.forEach(function (name) { if (saved[name]) element.style.setProperty(name, saved[name]); });
    return out;
  }

  function read(storage, key) {
    var raw = storage.getItem(key);
    return raw == null ? null : JSON.parse(raw);
  }

  /* A browser that blocks storage, or holds something unreadable, gets the defaults. */
  function load(storage) {
    try {
      var kept = read(storage, KEY);
      if (kept != null) return clean(kept);
      var old = read(storage, OLD_KEY);
      return clean(old && typeof old === 'object' ? { style: old.style, theme: old.theme, motion: old.motion } : null);
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

  function wrapWidth(text) {
    var step = TEXT_STEPS[text];
    return Math.round(WRAP_REM * Math.max(1, 100 / step) * 100) / 100 + 'rem';
  }

  /* Put the settings on the page's root element; the stylesheet does the rest,
     except a colour scheme's colours, which go on the element itself.
     systemDark says whether this computer is in dark mode, for Auto. */
  function apply(element, settings, systemDark) {
    var kept = clean(settings);
    element.style.fontSize = TEXT_STEPS[kept.text] + '%';
    element.style.setProperty('--wrap', wrapWidth(kept.text));
    element.style.setProperty('--split', String(kept.split));
    element.setAttribute('data-style', kept.style);
    element.setAttribute('data-theme', kept.theme);
    element.setAttribute('data-motion', kept.motion);
    element.setAttribute('data-keys', kept.keys);
    element.setAttribute('data-colours', kept.colours);
    COLOUR_PROPS.forEach(function (name) { element.style.removeProperty(name); });
    var picks = picksFor(kept, isDark(kept, systemDark));
    if (picks) {
      var vars = palette(picks, own(element).status).vars;
      Object.keys(vars).forEach(function (name) { element.style.setProperty(name, vars[name]); });
    }
    return kept;
  }

  var api = { KEY: KEY, OLD_KEY: OLD_KEY, TEXT_STEPS: TEXT_STEPS, TEXT_NAMES: TEXT_NAMES, SPLITS: SPLITS,
              DEFAULTS: DEFAULTS, SCHEMES: SCHEMES, READABLE: READABLE, clean: clean, load: load, save: save,
              apply: apply, isDark: isDark, picksFor: picksFor, own: own, palette: palette, contrast: contrast };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.FMSettings = api;
})(typeof window !== 'undefined' ? window : this);
"""

# How the page words and folds what it is handed, and what each key does: a
# script of its own, with no page in it, so it can be run without a browser.
VIEW_JS = r"""
/* The page's plain rules: the chat folded into messages and one quiet line per
   run of steps, links shown as short labels, and the keys, which name the same
   buttons, and so send the same notes, as a click. */
(function (root) {
  'use strict';

  function plural(count, one, many) { return count + ' ' + (count === 1 ? one : many); }
  function base(path) { var parts = String(path || '').split('/'); return parts[parts.length - 1] || String(path || ''); }

  /* One step the first mate took, in a few plain words. */
  function stepWords(item) {
    if (item.kind === 'event') return item.summary || 'A notice for firstmate';
    var name = item.name || '', about = item.about || '', summary = item.summary || '';
    if (name === 'Read') return 'Read ' + base(summary);
    if (/^(Edit|Write|NotebookEdit)$/.test(name)) return 'Changed ' + base(summary);
    if (name === 'Grep' || name === 'Glob') return 'Searched for ' + summary;
    if (name === 'WebFetch' || name === 'WebSearch') return 'Looked something up on the web';
    if (name === 'Agent' || name === 'Task') return about ? 'Asked a helper: ' + about : 'Asked a helper';
    if (name === 'Skill') return 'Read its notes on ' + (summary || 'a task');
    if (name.indexOf('mcp__') === 0) return about || 'Used a connected app';
    if (name === 'Bash') return about || 'Ran a command';
    return about || 'Took a step';
  }

  /* The conversation as messages, with each run of steps between them folded
     into one quiet line that opens on the steps. */
  function foldChat(items) {
    var rows = [], group = null;
    (items || []).forEach(function (item) {
      if (item.kind === 'tool' || item.kind === 'event') {
        if (!group) {
          group = { kind: 'quiet', id: 'q:' + item.id, steps: [], pending: false, error: false };
          rows.push(group);
        }
        group.steps.push({ text: stepWords(item), error: !!item.error });
        group.pending = group.pending || !!item.pending;
        group.error = group.error || !!item.error;
        return;
      }
      group = null;
      rows.push({ kind: item.kind, id: item.id, item: item });
    });
    return rows;
  }

  /* What the first mate is doing right now, in a few plain words, from the
     last thing the conversation shows: the step it is waiting on, else it is
     thinking. Its own short description of a step is used only when it holds
     no path, command or code. */
  function plainAbout(text) {
    text = String(text || '').replace(/\s+/g, ' ').trim();
    if (!text || /[\/\\`{}<>$|=]|https?:/.test(text)) return '';
    return text.length > 80 ? text.slice(0, 79).replace(/\s+\S*$/, '') + '…' : text;
  }
  function nowWords(items) {
    var last = (items || [])[(items || []).length - 1];
    if (!last || last.kind !== 'tool' || !last.pending) return 'Thinking';
    var name = last.name || '', about = plainAbout(last.about);
    if (name === 'Read') return 'Reading a file';
    if (/^(Edit|Write|NotebookEdit)$/.test(name)) return 'Changing a file';
    if (name === 'Grep' || name === 'Glob') return 'Searching the files';
    if (name === 'WebFetch' || name === 'WebSearch') return 'Looking something up on the web';
    if (name === 'Agent' || name === 'Task') return about ? 'Waiting on a helper: ' + about : 'Waiting on a helper';
    if (name === 'Skill') return 'Reading its notes';
    if (name.indexOf('mcp__') === 0) return about || 'Using a connected app';
    if (name === 'Bash') return about || 'Running a command';
    return about || 'Taking a step';
  }

  /* How long the turn has run: 9s, 2m 05s, 1h 03m. */
  function took(ms) {
    var s = Math.max(0, Math.floor((ms || 0) / 1000));
    var two = function (n) { return (n < 10 ? '0' : '') + n; };
    if (s < 60) return s + 's';
    if (s < 3600) return Math.floor(s / 60) + 'm ' + two(s % 60) + 's';
    return Math.floor(s / 3600) + 'h ' + two(Math.floor(s / 60) % 60) + 'm';
  }

  /* What a message typed while the first mate works says under its faded
     bubble: it will be read next, or, once the first mate has stopped or it
     has waited past WAIT_LONG_MS, that it is still waiting. */
  var WAIT_LONG_MS = 120000;
  function waitingWords(item, state, now) {
    var at = Date.parse((item && item.ts) || '');
    var long = !isNaN(at) && now - at > WAIT_LONG_MS;
    return state === 'busy' && !long ? 'Waiting, Firstmate will read it next' : 'Still waiting, Firstmate has not read it yet';
  }

  function quietLabel(group) {
    var things = plural(group.steps.length, 'thing', 'things');
    return group.pending ? 'Looking at ' + things + '…' : 'Looked at ' + things;
  }

  /* A link's short label: what it is, not its address. */
  function linkLabel(url) {
    var path = '', host = '';
    var found = /^https?:\/\/([^\/?#]+)([^?#]*)/i.exec(url);
    if (found) { host = found[1].toLowerCase().replace(/^www\./, ''); path = found[2]; }
    if (/\/pull\/\d+/.test(path)) return 'the pull request';
    if (/\/merge_requests\/\d+/.test(path)) return 'the merge request';
    if (/\/issues\/\d+/.test(path)) return 'the issue';
    if (/\/commit\//.test(path)) return 'the change';
    return host || 'the link';
  }

  /* Text split into words and links, each link with its short label. */
  function linkParts(text) {
    var parts = [], pattern = /https?:\/\/[^\s<>"'`]+/g, last = 0, found;
    text = String(text || '');
    while ((found = pattern.exec(text))) {
      var url = found[0], tail = '';
      while (url && '.,;:!?)'.indexOf(url[url.length - 1]) >= 0) { tail = url[url.length - 1] + tail; url = url.slice(0, -1); }
      if (found.index > last) parts.push({ text: text.slice(last, found.index) });
      parts.push({ text: linkLabel(url), url: url });
      if (tail) parts.push({ text: tail });
      last = found.index + found[0].length;
    }
    if (last < text.length) parts.push({ text: text.slice(last) });
    return parts;
  }

  function plainText(text) { return linkParts(text).map(function (part) { return part.text; }).join(''); }

  /* Every key, for the list the ? key opens. */
  var KEYS = [
    ['↑ ↓', 'Move between the calls and the projects'],
    ['1 2 3', 'Pick that answer for the highlighted question; enter sends it'],
    ['enter', 'Open the highlighted call or project; sends a picked answer'],
    ['k', 'Keep the highlighted finished work and ask Starship to make it live; enter sends it'],
    ['c', 'Ask for changes to the highlighted finished work'],
    ['x', 'Tell Starship the highlighted question looks already settled'],
    ['t', 'Talk the highlighted question through, or talk to a project\'s crew'],
    ['r', 'Read the report'],
    ['s', 'Switch who steers the project'],
    ['esc', 'Back, or cancel'],
    ['?', 'Show or hide this list']];

  /* The one line of keys at the bottom, for what is open now. */
  function keyStrip(ctx) {
    if (ctx && ctx.confirming) return [['enter', 'send to Starship'], ['esc', 'cancel']];
    return [['↑↓', 'move'], ['1/2/3', 'answer'], ['enter', 'open'], ['x', 'settled?'],
            ['k', 'keep'], ['t', 'talk'], ['r', 'read'], ['s', 'who steers'], ['?', 'all keys']];
  }

  /* What a key asks for, as the button it stands for would: the same act and
     the same names, or null for a key that does nothing here. ctx holds the
     highlighted call or project, whether a confirmation is open, the tab, the
     tab's own project, and projectOf to find a call's project. */
  function keyAction(key, ctx) {
    ctx = ctx || {};
    if (ctx.confirming) {
      if (key === 'Enter') return { act: 'send' };
      if (key === 'Escape') return { act: 'cancel' };
      if (key.length !== 1 || key === ' ') return null;
      return { act: 'hint', text:'Press enter to send it to Starship, or esc to cancel.' };
    }
    if (key === 'ArrowDown') return { act: 'move', step: 1 };
    if (key === 'ArrowUp') return { act: 'move', step: -1 };
    if (key === '?') return { act: 'keys' };
    if (key === 'Escape') return { act: 'back' };
    var hl = ctx.hl || null;
    var call = hl && hl.kind === 'call' ? hl.call : null;
    var proj = hl && hl.kind === 'project' ? hl.project : (call ? null : ctx.project || null);
    if (key === 'Enter') {
      if (call) return { act: 'open', id: call.id };
      if (proj && ctx.tab === 'home') return { act: 'tab', id: proj.id };
      return null;
    }
    if (/^[1-9]$/.test(key)) {
      if (call && call.question && (call.options || []).some(function (o) { return o.key === key; })) {
        return { act: 'pick', id: call.id, option: key };
      }
      return null;
    }
    switch (key) {
      case 'x': return call && call.question && !call.checking ? { act: 'settled', id: call.id } : null;
      case 'k': return call && !call.question ? { act: 'keep', id: call.id } : null;
      case 'c': return call && !call.question ? { act: 'talk', kind: 'change', id: call.id } : null;
      case 't':
        if (call) return { act: 'talk', kind: call.question ? 'discuss' : 'change', id: call.id };
        return proj ? { act: 'talk', kind: 'talk', factory: proj.id } : null;
      case 'r':
        if (call) return call.read ? { act: 'read', id: call.id } : null;
        if (proj) {
          var job = (proj.jobs || []).filter(function (j) { return j.read; })[0];
          return job ? { act: 'read', factory: proj.id, job: job.id } : null;
        }
        return null;
      case 's': {
        var steered = proj || (call && ctx.projectOf ? ctx.projectOf(call.project) : null);
        return steered ? { act: 'steer', factory: steered.id, who: steered.you_steer ? 'Starship' : 'you' } : null;
      }
      default: return null;
    }
  }

  /* The note an act sends, exactly as bin/fm-factory.py act takes it. */
  function noteFor(d, call) {
    switch (d.act) {
      case 'settled': return { action: 'settled', item: call.id, asking: call.asking };
      case 'keep': return { action: 'keep', item: call.id, asking: call.asking };
      case 'answer': return { action: 'answer', item: call.id, asking: call.asking, option: d.option };
      case 'steer': return { action: 'steer', factory: d.factory, who: d.who };
      case 'revive': case 'drop': return { action: d.act, item: call.id, asking: call.asking };
      case 'read': return d.id ? { action: 'read', item: d.id } : { action: 'read', factory: d.factory, job: d.job };
      case 'talk':
        return d.kind === 'talk' ? { action: 'talk', factory: d.factory, text: d.text }
          : { action: d.kind, item: d.id, asking: call ? call.asking : undefined, text: d.text };
      default: return null;
    }
  }

  /* The few words beside a call's title: whose it is and how long it has
     waited. On its own project's tab the project is already the heading. */
  function callMeta(call, ownTab, checking) {
    var whose = ownTab ? '' : call.project_name || '';
    if (call.mate) whose = whose ? whose + ', from ' + call.mate : 'from ' + call.mate;
    return [whose, checking ? 'checking' : call.waited || ''].filter(Boolean);
  }

  /* Where a row of tabs scrolls to so one tab is in sight: as little as it
     takes, with a little room beside it, and never past the start. */
  function tabScroll(left, width, tabLeft, tabWidth) {
    var room = 12;
    if (tabLeft - room < left) return Math.max(0, tabLeft - room);
    if (tabLeft + tabWidth + room > left + width) return Math.max(0, tabLeft + tabWidth + room - width);
    return left;
  }

  /* A note sent from a project's own tab is no look, as a key in a factory's tab is not. */
  function withLook(ask, tab) {
    if (tab === 'home') return ask;
    var out = { in_tab: true };
    Object.keys(ask).forEach(function (k) { out[k] = ask[k]; });
    return out;
  }

  var api = { stepWords: stepWords, foldChat: foldChat, quietLabel: quietLabel, nowWords: nowWords, took: took, linkLabel: linkLabel,
              waitingWords: waitingWords, WAIT_LONG_MS: WAIT_LONG_MS,
              linkParts: linkParts, plainText: plainText, KEYS: KEYS, keyStrip: keyStrip,
              keyAction: keyAction, noteFor: noteFor, withLook: withLook, callMeta: callMeta, tabScroll: tabScroll };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.FMView = api;
})(typeof window !== 'undefined' ? window : this);
"""

PAGE_JS = r"""
(function(){
'use strict';
const CSRF=document.body.dataset.csrf,BUILD=document.body.dataset.build||'';
const V=window.FMView,FS=window.FMSettings;
const $=id=>document.getElementById(id);
const log=$('log'),wrap=$('items'),input=$('input'),sendBtn=$('send'),thumbs=$('thumbs'),result=$('result'),stateEl=$('state');
let version='',images=[],sending=false;
/* Claude's suggested next prompt, shown in the empty message box; Tab takes it. */
const PLACEHOLDER=input.placeholder;let suggestion='';
/* The live line: the last items, the turn's start, and when this page first saw it working. */
let shown=[],since=null,working=false,seenAt=0;
/* Messages typed while the first mate works, not read in yet, and its state. */
let waiting=[],chatState='offline';
const KEY_NAMES={Enter:'↵',Escape:'esc'};

function el(tag,cls,text){const e=document.createElement(tag);if(cls)e.className=cls;
  if(text!==undefined)e.textContent=text;return e;}
function add(parent){for(let i=1;i<arguments.length;i++){if(arguments[i])parent.appendChild(arguments[i]);}return parent;}
/* A button; <key> is the key that does the same, shown as a small hint. */
function btn(cls,text,act,data,key){const b=el('button',cls,text);b.type='button';b.dataset.act=act;
  for(const k in (data||{})){if(data[k]!=null)b.dataset[k]=data[k];}
  if(key){const h=el('kbd','kh',KEY_NAMES[key]||key);h.setAttribute('aria-hidden','true');b.appendChild(h);
    b.setAttribute('aria-keyshortcuts',key);}
  return b;}
const NS='http://www.w3.org/2000/svg';
const ICONS={
  sliders:'M2 5h7M12 5h2M2 11h2M7 11h7M10.5 3.5v3M5.5 9.5v3',
  check:'M3.5 8.5l3 3 6-7',
  moon:'M13 9.5A5.5 5.5 0 0 1 6.5 3a5.5 5.5 0 1 0 6.5 6.5z',
  battery:'M2 5.5h10v5H2zM13.5 7v2',
  close:'M4 4l8 8M12 4l-8 8'};
function icon(name){const s=document.createElementNS(NS,'svg');s.setAttribute('viewBox','0 0 16 16');
  s.setAttribute('aria-hidden','true');const p=document.createElementNS(NS,'path');p.setAttribute('d',ICONS[name]);
  p.setAttribute('fill','none');p.setAttribute('stroke','currentColor');p.setAttribute('stroke-width','1.6');
  p.setAttribute('stroke-linecap','round');p.setAttribute('stroke-linejoin','round');s.appendChild(p);return s;}
/* Starship's own ship, drawn once in the page as a symbol. */
function ship(){const s=document.createElementNS(NS,'svg');s.setAttribute('viewBox','0 0 24 24');s.setAttribute('aria-hidden','true');
  const u=document.createElementNS(NS,'use');u.setAttribute('href','#ship');s.appendChild(u);return s;}
/* Words with each link shown as its short label; <live> makes the labels links. */
function linked(text,live){const frag=document.createDocumentFragment();
  V.linkParts(text).forEach(part=>{
    if(!part.url){frag.appendChild(document.createTextNode(part.text));return;}
    if(live){const a=el('a','lk',part.text);a.href=part.url;a.target='_blank';a.rel='noopener noreferrer';frag.appendChild(a);}
    else frag.appendChild(el('span','lk',part.text));});
  return frag;}
function urls(text){return V.linkParts(text).filter(p=>p.url);}

/* ---- the first mate's conversation ---- */
function atBottom(){return log.scrollHeight-log.scrollTop-log.clientHeight<80;}
function pictures(item){
  const box=el('div','pics');
  (item.pictures||[]).forEach(id=>{const a=el('a');a.href='/api/picture/'+encodeURIComponent(id);a.target='_blank';a.rel='noopener';
    const img=el('img');img.src=a.href;img.alt='A picture you sent';img.loading='lazy';a.appendChild(img);box.appendChild(a);});
  return box;
}
function render(items){
  const open=new Set(Array.from(wrap.querySelectorAll('details[open]')).map(d=>d.dataset.id));
  const stick=atBottom();
  const frag=document.createDocumentFragment();
  for(const row of V.foldChat(items)){
    if(row.kind==='quiet'){
      const d=el('details','quiet'+(row.error?' err':''));d.dataset.id=row.id;
      d.appendChild(el('summary','',V.quietLabel(row)));
      const ul=el('ul','steps-list');row.steps.forEach(s=>ul.appendChild(el('li',s.error?'err':'',s.text)));
      d.appendChild(ul);if(open.has(row.id))d.open=true;frag.appendChild(d);continue;
    }
    const item=row.item;
    if(item.kind==='user'||item.kind==='assistant'){
      const msg=el('div','msg '+item.kind);const b=el('div','bubble');
      if(item.kind==='assistant'){const av=el('div','av');av.appendChild(ship());msg.appendChild(av);}
      b.innerHTML=item.html||'';
      if(item.pictures&&item.pictures.length)b.appendChild(pictures(item));
      else if(item.images){b.appendChild(el('div','chip',item.images===1?'1 picture':item.images+' pictures'));}
      msg.appendChild(b);frag.appendChild(msg);
    }else if(item.kind==='compact'){
      const c=el('div','compact');const d=el('details');d.dataset.id=item.id;
      d.appendChild(el('summary','',item.summary));
      if(item.detail){d.appendChild(el('pre','',item.detail));}
      if(open.has(item.id))d.open=true;c.appendChild(d);frag.appendChild(c);
    }
  }
  wrap.replaceChildren(frag);
  if(stick)log.scrollTop=log.scrollHeight;
}
function drawLive(){
  const live=$('live');
  if(!working){if(!live.hidden)live.hidden=true;return;}
  const stick=live.hidden&&atBottom();
  const start=Date.parse(since||'');
  live.querySelector('.what').textContent=V.nowWords(shown);
  live.querySelector('.took').textContent=V.took(Date.now()-(isNaN(start)?seenAt:start));
  if(live.hidden){live.hidden=false;if(stick)log.scrollTop=log.scrollHeight;}
}
/* Each waiting message as a faded bubble below the live line; the transcript
   showing it read in drops it here as its normal bubble appears above. */
function renderWaiting(){
  const box=$('waiting');const stick=atBottom();const frag=document.createDocumentFragment();
  for(const item of waiting){
    const msg=el('div','msg user waiting');const b=el('div','bubble');b.innerHTML=item.html||'';
    if(item.pictures&&item.pictures.length)b.appendChild(pictures(item));
    msg.appendChild(b);msg.appendChild(el('div','wait',V.waitingWords(item,chatState,Date.now())));frag.appendChild(msg);
  }
  box.replaceChildren(frag);
  if(stick)log.scrollTop=log.scrollHeight;
}
function drawWaiting(){
  const notes=$('waiting').querySelectorAll('.wait');
  waiting.forEach((item,i)=>{const words=V.waitingWords(item,chatState,Date.now());
    if(notes[i]&&notes[i].textContent!==words)notes[i].textContent=words;});
}
setInterval(drawLive,1000);
setInterval(drawWaiting,1000);
function setState(state,started){
  if(state==='busy'&&!working)seenAt=Date.now();
  working=state==='busy';since=working?started||null:null;chatState=state;
  stateEl.className='state '+state;
  stateEl.querySelector('.label').textContent=state==='busy'?'Working':state==='idle'?'Ready':'Not running';
}
async function poll(){
  try{
    const r=await fetch('/api/conversation?since='+encodeURIComponent(version),{credentials:'same-origin'});
    if(r.ok){
      const data=await r.json();
      if(!data.unchanged){
        version=data.version||'';
        shown=data.items||[];
        render(shown);
        waiting=data.waiting||[];
        renderWaiting();
        $('note').textContent=data.note||'';
        $('older').hidden=!data.older;
      }
      setState(data.state||'offline',data.since);drawLive();drawWaiting();
      suggest(data.suggestion||'');
      if(data.build&&BUILD&&data.build!==BUILD)reloadWhenFree();
    }
  }catch(e){setState('offline');drawLive();}
  setTimeout(poll,document.hidden?6000:1500);
}
function suggest(text){
  suggestion=text;
  input.placeholder=text||PLACEHOLDER;
  input.classList.toggle('suggested',!!text);
}
/* The server now runs newer code (a Starship update restarted it): load the
   new page, but never over words or pictures waiting in the message box. */
function reloadWhenFree(){if(!sending&&!input.value&&!images.length)location.reload();}
function addImage(file){
  if(!file||!/^image\/(png|jpeg|gif|webp)$/.test(file.type))return;
  const reader=new FileReader();
  reader.onload=()=>{images.push(reader.result);drawThumbs();};
  reader.readAsDataURL(file);
}
function drawThumbs(){
  thumbs.replaceChildren();
  images.forEach((src,i)=>{const t=el('div','thumb');const img=el('img');img.src=src;img.alt='attached picture';
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
input.addEventListener('keydown',e=>{
  if(e.key==='Enter'&&!e.shiftKey&&!e.isComposing){e.preventDefault();send();return;}
  if(e.key==='Tab'&&!e.shiftKey&&!e.altKey&&!e.ctrlKey&&!e.metaKey&&!e.isComposing&&suggestion&&!input.value){
    e.preventDefault();input.value=suggestion;autosize();input.setSelectionRange(input.value.length,input.value.length);}
});
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
let openCall=null,chose=false,confirming=null,talk=null,notice=null,noticeTimer=0,acting=false,selJob=null,hl=null,tabShown=null;
const sent={},asked={};  /* answers and re-checks this page sent that the record does not show yet */
const oldSent={};  /* older questions this page asked about that the record does not show yet */
const full=new Set();    /* the clipped titles opened in full */

function project(id){return M.projects.find(p=>p.id===id)||null;}
function need(id){return M.needs.find(n=>n.id===id)||null;}
function say(ok,text){
  notice=text?{kind:ok?'ok':'bad',text:text}:null;
  clearTimeout(noticeTimer);
  if(notice)noticeTimer=setTimeout(()=>{notice=null;draw();},20000);
}
function clip(cls,text,id){const e=el('span',cls+' clip',text);e.dataset.act='more';e.dataset.key=id;e.title=text;
  if(full.has(id))e.classList.add('full');return e;}
function steps(job,cls){
  const ol=el('ol',cls||'steps');
  M.steps.forEach((name,i)=>{const li=el('li',i<job.step?'done':i===job.step?'now':'');
    if(i<job.step)li.appendChild(icon('check'));li.appendChild(document.createTextNode(name));ol.appendChild(li);});
  return ol;
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
  add(row,go,btn('btn','Cancel','cancel',null,'Escape'));box.appendChild(row);return box;
}
function callCard(n,ownTab){
  const open=openCall===n.id;
  const mine=sent[n.id];
  const answered=n.answered||(mine&&mine.asking===n.asking?mine:null);
  /* The most pressing call is the first card, marked on the overview. */
  const first=!ownTab&&M.first_up===n.id;
  const card=el('div','call'+(open?' open':'')+(n.question?'':' fin')+(hl&&hl.kind==='call'&&hl.id===n.id?' hl':''));
  card.dataset.call=n.id;
  const row=btn('call-row','','open',{id:n.id});row.setAttribute('aria-expanded',String(open));
  row.appendChild(el('span','dot '+(n.question?'you':'done')));
  const title=el('span','call-title');title.appendChild(linked(n.ask,false));row.appendChild(title);
  if(first)row.appendChild(el('span','tag first','First up'));
  const meta=el('span','call-meta');
  const checking=n.checking||asked[n.id]===n.asking;
  V.callMeta(n,ownTab,checking).forEach(words=>meta.appendChild(el('span','',words)));
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
  if(!n.question&&(n.summary||[]).length){const dl=el('dl','pr-short');
    n.summary.forEach(p=>{dl.appendChild(el('dt','',p.label));dl.appendChild(el('dd','',p.text));});
    body.appendChild(dl);}
  const pending=confirming&&confirming.item===n.id?confirming:null;
  if(n.question&&n.options.length){
    const opts=el('div','opts');
    n.options.forEach(o=>{
      const picked=(pending&&pending.option===o.key)||(!pending&&answered&&answered.key===o.key);
      const b=btn('opt'+(picked?' picked':''),'','pick',{id:n.id,option:o.key});
      b.appendChild(el('span','ring'));b.appendChild(el('span','l',o.label));
      if(o.suggested)b.appendChild(el('span','tag','Suggested by '+n.suggested_by));
      const h=el('kbd','kh',o.key);h.setAttribute('aria-hidden','true');b.appendChild(h);b.setAttribute('aria-keyshortcuts',o.key);
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
    const go=btn('btn primary','Send to Starship','send',null,'Enter');go.disabled=acting;
    add(rowb,go,btn('btn','Cancel','cancel',null,'Escape'));box.appendChild(rowb);body.appendChild(box);
  }
  if(n.holds_up.length)body.appendChild(el('p','holds','Holds up: '+n.holds_up.join(', ')));
  const links=urls(n.ask).filter(l=>l.url!==n.pr);
  if(n.pr||links.length){const p=el('p','holds');
    if(n.pr){const a=el('a','','See what changed');a.href=n.pr;a.target='_blank';a.rel='noopener noreferrer';p.appendChild(a);}
    links.forEach((l,i)=>{if(n.pr||i)p.appendChild(document.createTextNode(' · '));
      const a=el('a','','Open '+l.text);a.href=l.url;a.target='_blank';a.rel='noopener noreferrer';p.appendChild(a);});
    body.appendChild(p);}
  const mineTalk=talk&&talk.item===n.id;
  const acts=el('div','rowb');
  if(!n.question){
    const keep=btn('btn primary','Keep it','keep',{id:n.id},'k');keep.disabled=acting||!!pending;acts.appendChild(keep);
    acts.appendChild(btn('btn','Ask for changes','talk',{kind:'change',id:n.id},'c'));
  }else{
    acts.appendChild(btn('btn','Talk it through','talk',{kind:'discuss',id:n.id},'t'));
    if(!checking){const x=btn('btn','This is already settled','settled',{id:n.id},'x');x.disabled=acting;acts.appendChild(x);}
  }
  if(n.read)acts.appendChild(btn('btn plain','Read the report','read',{id:n.id},'r'));
  body.appendChild(acts);
  if(mineTalk)body.appendChild(talkBox(talk.kind==='change'?'What should change?':'Talk it through'));
  card.appendChild(body);return card;
}
function jobCard(job,p,watch){
  const card=el('div','job'+(!watch&&selJob===job.id?' sel':''));card.dataset.job=job.id;
  const top=el('div','job-top');
  add(top,el('span','dot work'),clip('job-title',V.plainText(job.title),'job:'+job.id),job.elapsed?el('span','mins',job.elapsed):null);
  card.appendChild(top);card.appendChild(steps(job));
  const foot=el('div','job-foot');
  foot.appendChild(el('span','doing'+(job.quiet?' quiet':''),job.words));
  if(job.read)foot.appendChild(btn('btn small plain','Read the report','read',{factory:p.id,job:job.id}));
  if(watch)foot.appendChild(btn('btn small plain','Watch this worker','watch',{factory:p.id,job:job.id}));
  card.appendChild(foot);return card;
}
function jobLine(job,p){
  const line=el('div','jobline'+(selJob===job.id?' sel':''));line.dataset.job=job.id;
  add(line,el('span','dot '+job.mark),clip('t',V.plainText(job.title),'job:'+job.id),el('span','w '+job.mark,job.words));
  if(job.read)line.appendChild(btn('btn small plain','Read the report','read',{factory:p.id,job:job.id}));
  return line;
}
function section(title,count,small){
  const sec=el('section','sec');const h=el('h3','',title);
  if(count!=null)h.appendChild(el('span','n',String(count)));
  if(small)h.appendChild(el('small','',small));
  sec.appendChild(h);return sec;
}
function olderItem(id){
  const all=M.shelves.older.items.concat(...M.projects.map(p=>p.page.shelves.older.items));
  return all.find(o=>o.id===id)||null;
}
/* NEEDS YOU's two shelves: the older questions still open, each with Bring back and No longer
   needed (two clicks, as an answer is), and the calls put off to a date with the day each comes back. */
function shelves(sh,ownTab){
  const parts=[];
  if(sh.older.items.length){
    const box=el('div','shelf');box.dataset.shelf='older';
    box.appendChild(el('h4','',sh.older.heading));
    if(sh.older.note)box.appendChild(el('p','note-line',sh.older.note));
    const ul=el('ul');
    sh.older.items.forEach(o=>{
      const li=el('li');li.dataset.older=o.id;
      const asked=o.asked||(oldSent[o.id]&&oldSent[o.id].asking===o.asking?oldSent[o.id].words:'');
      const side=el('div','side');
      add(side,el('span','w',[ownTab?'':o.project_name,asked?asked+', waiting for Starship':o.since].filter(Boolean).join(', ')));
      add(li,el('span','t',o.title),side);
      const pending=confirming&&confirming.older&&confirming.item===o.id?confirming:null;
      if(pending){
        const box2=el('div','confirm');
        box2.appendChild(el('p','',pending.older==='revive'?'Ask Starship to bring this back into Needs you?':'Tell Starship this is no longer needed?'));
        box2.appendChild(el('p','unsent','Not sent yet.'));
        const rowb=el('div','rowb');const go=btn('btn primary','Send to Starship','send',null,'Enter');go.disabled=acting;
        add(rowb,go,btn('btn','Cancel','cancel',null,'Escape'));box2.appendChild(rowb);side.appendChild(box2);
      }else if(!asked){
        const rowb=el('div','rowb');
        const back=btn('btn small','Bring back','oldask',{id:o.id,what:'revive'});back.disabled=acting;
        const gone=btn('btn small','No longer needed','oldask',{id:o.id,what:'drop'});gone.disabled=acting;
        add(rowb,back,gone);side.appendChild(rowb);
      }
      ul.appendChild(li);
    });
    box.appendChild(ul);parts.push(box);
  }
  if(sh.coming.heading){
    const box=el('div','shelf');box.dataset.shelf='coming';
    box.appendChild(el('h4','',sh.coming.heading));
    if(sh.coming.rest)box.appendChild(el('p','note-line',sh.coming.rest));
    if(sh.coming.items.length){const ul=el('ul');
      sh.coming.items.forEach(c=>{const li=el('li');
        add(li,el('span','when',c.when),el('span','t',c.title),ownTab?null:el('span','w',c.project_name));ul.appendChild(li);});
      box.appendChild(ul);}
    if(sh.coming.after)box.appendChild(el('p','note-line',sh.coming.after));
    parts.push(box);
  }
  return parts;
}

function drawTabs(){
  const tabs=$('tabs');
  const list=[{id:'home',name:'Control Centre'}].concat(M.projects.map(p=>({id:p.id,name:p.name,needs:p.page.needs.length})));
  /* Drawing the tabs again must not move the row; only a newly chosen tab is brought into sight. */
  const left=tabs.scrollLeft;let chosen=null;
  tabs.replaceChildren();
  list.forEach(t=>{const b=btn('tab',t.name,'tab',{id:t.id});b.setAttribute('role','tab');
    b.setAttribute('aria-selected',String(t.id===tab));if(t.id===tab)chosen=b;
    if(t.needs){b.title=t.needs===1?'1 thing needs you':t.needs+' things need you';
      b.appendChild(el('span','dot you'));}
    tabs.appendChild(b);});
  tabs.scrollLeft=left;
  if(chosen&&tabShown!==tab){const row=tabs.getBoundingClientRect(),at=chosen.getBoundingClientRect();
    tabs.scrollLeft=V.tabScroll(tabs.scrollLeft,tabs.clientWidth,at.left-row.left+tabs.scrollLeft,at.width);}
  tabShown=tab;
}
function drawBand(){
  const band=M.band,box=$('band');
  const lamps=el('div','lamps');
  band.lamps.forEach(l=>{const d=el('div','lamp '+l.mark+(l.count?' lit':''));d.title=l.count+' '+l.words;
    add(d,el('i'),el('b','',String(l.count)),el('span','w',l.words),el('span','s',l.short||l.words));lamps.appendChild(d);});
  const parts=[lamps];
  if(band.note)parts.push(el('span','band-note',band.note));
  if(band.alert){
    /* "N stopped" opens the job that stopped, which says so and who is on it. */
    const a=band.stopped?btn('alert alert-btn','','stopped',{project:band.stopped.project,job:band.stopped.job}):el('span','alert');
    if(band.stopped)a.title='Open the job that stopped';
    add(a,el('i'),el('span','',band.alert));parts.push(a);}
  if(band.night){const n=el('span','aside night'+(band.night_done?' good':''));n.title=band.night;add(n,icon('moon'),el('span','',band.night));parts.push(n);}
  if(band.battery){const b=el('span','aside'+(band.battery_mark?' '+band.battery_mark:''));
    add(b,icon('battery'),el('span','',band.battery));parts.push(b);}
  box.replaceChildren.apply(box,parts);
}
function drawStatus(){
  const row=$('statusrow'),segs=M.status||[];
  row.hidden=!segs.length;
  row.replaceChildren.apply(row,segs.map(s=>el('span',s.tone?'t-'+s.tone:'',s.text)));
  row.title=segs.map(s=>s.text).join('');
}
function drawTop(){
  const top=$('ptop');top.replaceChildren();
  /* Three plain sentences, each a way to its part of the page. */
  const says=el('div','says');
  M.sentences.forEach(s=>says.appendChild(btn('say'+(s.mark?' c-'+s.mark:''),s.words,'goto',{to:s.to})));
  if(!M.sentences.length)says.appendChild(el('p','sum','reading the crew'));
  top.appendChild(says);
  if(mirrorError)top.appendChild(el('p','notice bad',mirrorError));
  if(notice){const n=el('p','notice '+notice.kind,notice.text);n.setAttribute('role','status');top.appendChild(n);}
}
/* One outcome, as New on the overview and Lately on a project's tab tell it. */
function newsLine(n,p){
  const line=el('p','news');
  add(line,el('time','',n.when),el('span','verb '+n.mark,n.label+':'));
  if(n.pr){const a=el('a','lk',n.text);a.href=n.pr;a.target='_blank';a.rel='noopener noreferrer';a.title='See what changed';line.appendChild(a);}
  else line.appendChild(linked(n.text,true));
  if(n.read)line.appendChild(btn('btn small plain','Read it','read',{factory:p.id,job:n.id}));
  return line;
}
/* A list that names its first few and folds the rest behind one line. */
function folded(words,items,key){
  const d=el('details','quiet');d.dataset.fold=key;d.appendChild(el('summary','',words));
  const ul=el('ul','list');items.forEach(li=>ul.appendChild(li));d.appendChild(ul);return d;
}
function drawHome(){
  $('clock').textContent=M.clock;
  drawTop();
  const body=$('pbody');
  const needs=section('Needs you',M.needs.length,M.needs.length>1?'most pressing first':'');needs.dataset.sec='needs';
  const call=M.band.call;
  if(call&&!call.listed){const u=el('p','urgent-line');u.appendChild(el('b','','Most urgent: '));u.appendChild(linked(call.title,true));needs.appendChild(u);}
  if(M.needs.length)M.needs.forEach(n=>needs.appendChild(callCard(n,false)));
  else needs.appendChild(el('p','empty','Nothing needs you right now.'));
  shelves(M.shelves,false).forEach(part=>needs.appendChild(part));
  /* Each factory told as Now, New and Next; a quiet one is one line under Quiet for now. */
  const facs=section('Your factories',null,M.factories_heading);facs.dataset.sec='factories';
  M.projects.filter(p=>!p.quiet).forEach(p=>{
    const box=el('article','proj'+(hl&&hl.kind==='project'&&hl.id===p.id?' hl':''));box.dataset.proj=p.id;
    const head=el('div','proj-head');
    /* Who steers is switched on the project's own tab; here only a project the owner steers says so. */
    add(head,btn('proj-name',p.name,'tab',{id:p.id}),p.badge?el('span','badge',p.badge):null,
      p.you_steer?el('span','steer-note','You steer'):null);
    box.appendChild(head);
    const dl=el('dl','told');
    const part=(name,dd)=>{dl.appendChild(el('dt','',name));dl.appendChild(dd);};
    const now=el('dd');
    if(p.now)now.appendChild(el('p','',p.now));
    p.jobs.forEach(job=>now.appendChild(job.busy?jobCard(job,p,true):jobLine(job,p)));
    p.routine.forEach(r=>{const line=el('p','line');
      add(line,el('b','',r.kind),el('span','',r.words.join(', ')),r.now?el('span','r',r.now):null);now.appendChild(line);});
    part('Now',now);
    if(p.new.length){const dd=el('dd');
      p.new.forEach(n=>dd.appendChild(newsLine(n,p)));
      if(p.more)dd.appendChild(el('p','line',p.more_words));
      part('New',dd);}
    if(p.next){const dd=el('dd');const line=el('p');
      add(line,el('b','',V.plainText(p.next.title)),document.createTextNode(p.next.words));dd.appendChild(line);part('Next',dd);}
    box.appendChild(dl);facs.appendChild(box);
  });
  const quiet=M.projects.filter(p=>p.quiet);
  if(quiet.length){const q=el('div','quiet-facs');q.appendChild(el('h4','','Quiet for now'));const ul=el('ul');
    quiet.forEach(p=>{const li=el('li',hl&&hl.kind==='project'&&hl.id===p.id?'hl':'');li.dataset.proj=p.id;add(li,btn('proj-name',p.name,'tab',{id:p.id}),el('span','w',p.quiet_words));ul.appendChild(li);});
    q.appendChild(ul);facs.appendChild(q);}
  if(!M.projects.length)facs.appendChild(el('p','empty','No projects yet. Ask your firstmate to add one.'));
  body.replaceChildren(needs,facs);
}
/* A project's tab reads top to bottom, as the pane's page: what it is for and one sentence of
   state, Talk to this crew with who steers as a quiet line, Needs you with its older questions,
   then Happening now, Lately, Up next, Coming back, How this crew works and the Conversation.
   A wide screen sets Needs you beside the rest; a narrow one is one column. */
function drawProject(p){
  const head=$('ppHead');
  const row=el('div','rowb acts');
  const steer=el('p','steer-line');
  const asking=confirming&&confirming.steer&&confirming.steer.factory===p.id;
  steer.appendChild(document.createTextNode(p.you_steer?'You steer this factory. ':'Starship steers this factory. '));
  if(!asking){const ch=btn('lk-btn','Change','steer',{factory:p.id,who:p.you_steer?'Starship':'you'});ch.disabled=acting;steer.appendChild(ch);}
  add(row,btn('btn','Talk to this crew','talk',{kind:'talk',factory:p.id},'t'),steer);
  const top=el('div','pp-title');
  add(top,el('h2','',p.name),p.about?el('p','about',p.about):null,p.page.state?el('p','pp-state'+(p.page.needs.length?' you':''),p.page.state):null);
  head.replaceChildren(top,row);
  if(asking){
    const box=el('div','confirm');
    box.appendChild(el('p','',p.you_steer?'Hand '+p.name+' back to Starship to steer?':'Steer '+p.name+' yourself from now on?'));
    box.appendChild(el('p','unsent','Not sent yet. Starship is told of the change.'));
    const rowb=el('div','rowb');const go=btn('btn primary','Change who steers','send',null,'Enter');go.disabled=acting;
    add(rowb,go,btn('btn','Cancel','cancel',null,'Escape'));box.appendChild(rowb);head.appendChild(box);
  }
  if(talk&&talk.kind==='talk'&&talk.factory===p.id)head.appendChild(talkBox('Talk to the '+p.name+' crew'));
  if(notice){const n=el('p','notice '+notice.kind,notice.text);n.setAttribute('role','status');head.appendChild(n);}
  const left=[],right=[];
  const mine=M.needs.filter(n=>n.project===p.id);
  const older=shelves({older:p.page.shelves.older,coming:{heading:''}},true);
  if(mine.length||older.length){const s=section('Needs you',mine.length);s.dataset.sec='needs';
    mine.forEach(n=>s.appendChild(callCard(n,true)));older.forEach(part=>s.appendChild(part));left.push(s);}
  const now=section('Happening now');now.dataset.sec='now';
  if(p.now)now.appendChild(el('p','line',p.now));
  p.page.now.forEach(job=>now.appendChild(job.busy?jobCard(job,p,false):jobLine(job,p)));
  p.routine.forEach(r=>{const line=el('p','line');
    add(line,el('b','',r.kind),el('span','',r.words.join(', ')),r.now?el('span','r',r.now):null);now.appendChild(line);});
  right.push(now);
  const lately=section('Lately',null,p.page.lately_since);lately.dataset.sec='lately';
  p.page.lately.forEach(n=>lately.appendChild(newsLine(n,p)));
  if(!p.page.lately.length)lately.appendChild(el('p','empty','Nothing new.'));
  right.push(lately);
  const next=section('Up next',null,p.page.lined?p.page.lined+' lined up':'');next.dataset.sec='next';
  p.page.next.forEach(job=>next.appendChild(jobLine(job,p)));
  p.page.folded.forEach(group=>next.appendChild(folded(group.words,group.jobs.map((j,i)=>{
    const li=el('li');add(li,clip('',V.plainText(j.title),'fold:'+group.words+':'+i),el('span','w',j.queue));return li;}),group.words)));
  if(!p.page.next.length&&!p.page.folded.length)next.appendChild(el('p','empty','Nothing lined up.'));
  right.push(next);
  if(p.page.coming.length){
    const s=section('Coming back',null,p.page.coming.length+' put off to a date');s.dataset.sec='coming';
    const item=c=>{const li=el('li');add(li,el('span','when',c.when),el('span','t',c.title));return li;};
    const ul=el('ul','dated');p.page.coming.forEach(c=>ul.appendChild(item(c)));s.appendChild(ul);
    right.push(s);
  }
  const works=section('How this crew works');works.dataset.sec='rules';
  if(p.page.rules.length){const ul=el('ul','bul');p.page.rules.forEach(r=>ul.appendChild(el('li','',r)));works.appendChild(ul);}
  if(p.page.rules_size)works.appendChild(el('p','all'+(p.page.rules_mark==='over'?' warn':p.page.rules_mark==='near'?' near':''),p.page.rules_size));
  if(p.page.learned.length){
    works.appendChild(el('h4','','Learned lately'));const ul=el('ul','bul');
    p.page.learned.forEach(l=>{const li=el('li');if(l.when)li.appendChild(el('time','',l.when));
      li.appendChild(document.createTextNode(l.what));ul.appendChild(li);});
    works.appendChild(ul);
  }
  if(!p.page.rules.length&&!p.page.learned.length)works.appendChild(el('p','empty','No rules written down yet.'));
  right.push(works);
  const conv=section('Conversation');conv.dataset.sec='talk';
  if(p.page.talk.length){const ul=el('ul','feed');
    p.page.talk.forEach(t=>{const li=el('li');li.appendChild(el('time','',t.when));
      const d=el('div');d.appendChild(el('span','who',t.who+': '));d.appendChild(document.createTextNode(t.said));
      li.appendChild(d);ul.appendChild(li);});
    conv.appendChild(ul);}
  else conv.appendChild(el('p','empty','Nothing said here yet. Talk to this crew to start.'));
  right.push(conv);
  const cols=el('div','pp-cols'+(left.length?'':' one'));
  const l=el('div','pp-col');left.forEach(x=>l.appendChild(x));
  const r=el('div','pp-col');right.forEach(x=>r.appendChild(x));
  if(left.length)cols.appendChild(l);cols.appendChild(r);
  const open=new Set(Array.from($('ppBody').querySelectorAll('details[open]')).map(d=>d.dataset.fold));
  $('ppBody').replaceChildren(cols);
  $('ppBody').querySelectorAll('details').forEach(d=>{if(open.has(d.dataset.fold))d.open=true;});
}
function drawKeys(){
  const strip=$('keystrip');strip.replaceChildren();
  strip.classList.toggle('confirming',!!confirming);
  V.keyStrip({confirming:!!confirming}).forEach(k=>{const s=el('span');add(s,el('kbd','',k[0]),document.createTextNode(k[1]));strip.appendChild(s);});
}
function draw(){
  if(!M)return;
  if(tab!=='home'&&!project(tab))tab='home';
  if(!chose&&(!openCall||!need(openCall)))openCall=M.needs.length?M.needs[0].id:null;
  if(confirming&&!(confirming.steer?tab===confirming.steer.factory&&project(tab)&&project(tab).you_steer!==(confirming.steer.who==='you'):confirming.older?olderItem(confirming.item):need(confirming.item)))confirming=null;
  if(talk&&talk.item&&!need(talk.item))talk=null;
  if(hl&&!(hl.kind==='call'?need(hl.id):project(hl.id)))hl=null;
  const active=document.activeElement&&document.activeElement.id==='talkText'?document.activeElement:null;
  const caret=active?[active.selectionStart,active.selectionEnd]:null;
  drawTabs();drawBand();drawStatus();
  $('home').hidden=tab!=='home';$('project').hidden=tab==='home';$('sideSwitch').hidden=tab!=='home';
  if(tab==='home')drawHome();else drawProject(project(tab));
  drawKeys();
  document.querySelectorAll('.clip').forEach(e=>e.classList.toggle('over',e.classList.contains('full')||e.scrollHeight>e.clientHeight+1));
  if(caret){const area=$('talkText');if(area){area.focus();area.setSelectionRange(caret[0],caret[1]);}}
  homeDivider.label();
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
      headers:{'Content-Type':'application/json','X-FM-CSRF':CSRF},body:JSON.stringify(V.withLook(ask,tab))});
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

/* The highlight the arrow keys move: the calls, then the projects, as the pane's. */
function stops(){
  const calls=(tab==='home'?M.needs:M.needs.filter(n=>n.project===tab)).map(n=>({kind:'call',id:n.id}));
  return tab==='home'?calls.concat(M.projects.map(p=>({kind:'project',id:p.id}))):calls;
}
function move(step){
  const list=stops();if(!list.length)return;
  let at=hl?list.findIndex(s=>s.kind===hl.kind&&s.id===hl.id):-1;
  if(at<0&&!hl&&openCall){at=list.findIndex(s=>s.kind==='call'&&s.id===openCall);if(at>=0)step=0;}
  at=at<0?(step>0?0:list.length-1):Math.min(list.length-1,Math.max(0,at+step));
  hl=list[at];
  if(hl.kind==='call'){openCall=hl.id;chose=true;confirming=null;if(talk&&talk.item)talk=null;}
  draw();
  const node=hl.kind==='call'?document.querySelector('[data-call="'+CSS.escape(hl.id)+'"]'):document.querySelector('[data-proj="'+CSS.escape(hl.id)+'"]');
  if(node)node.scrollIntoView({block:'nearest'});
}
function keyContext(){
  const lit=hl||(openCall&&need(openCall)&&(tab==='home'||need(openCall).project===tab)?{kind:'call',id:openCall}:null);
  return {hl:lit?{kind:lit.kind,call:lit.kind==='call'?need(lit.id):null,project:lit.kind==='project'?project(lit.id):null}:null,
    confirming:!!confirming,tab:tab,project:tab!=='home'?project(tab):null,projectOf:id=>project(id)};
}
function openKeys(open){$('keysSheet').hidden=!open;$('keysBtn').setAttribute('aria-expanded',String(open));
  if(open)$('keysClose').focus();}

/* One way in for a click and a key: both name an act and its names. */
async function perform(d){
  let answer=null;
  switch(d.act){
    case 'tab':tab=d.id;selJob=null;hl=null;if(talk&&talk.kind==='talk')talk=null;
      history.replaceState(null,'',tab==='home'?location.pathname:'#'+encodeURIComponent(tab));draw();return;
    case 'back':if(tab!=='home')perform({act:'tab',id:'home'});return;
    case 'move':move(Number(d.step));return;
    case 'keys':openKeys($('keysSheet').hidden);return;
    case 'hint':say(false,d.text);draw();return;
    case 'more':if(full.has(d.key))full.delete(d.key);else full.add(d.key);draw();return;
    case 'call':if(need(d.id))show(d.id,true);else{tab='home';setSide('projects');draw();}return;
    case 'open':chose=true;openCall=openCall===d.id?null:d.id;confirming=null;if(talk&&talk.item)talk=null;
      hl={kind:'call',id:d.id};draw();return;
    case 'pick':openCall=d.id;chose=true;confirming={item:d.id,option:d.option};draw();return;
    case 'oldask':confirming={item:d.id,older:d.what};draw();return;
    case 'goto':{if(tab!=='home')perform({act:'tab',id:'home'});setSide('projects');
      const sec=document.querySelector('#pbody [data-sec="'+CSS.escape(d.to)+'"]');if(sec)sec.scrollIntoView({block:'start'});return;}
    case 'stopped':tab=d.project;selJob=d.job;hl=null;setSide('projects');
      history.replaceState(null,'','#'+encodeURIComponent(tab));draw();
      {const card=document.querySelector('#ppBody [data-job="'+CSS.escape(d.job)+'"]');if(card)card.scrollIntoView({block:'center'});}return;
    case 'keep':openCall=d.id;chose=true;confirming={item:d.id,keep:true};draw();return;
    case 'cancel':confirming=null;talk=null;say(true,'');draw();return;
    case 'talk':confirming=null;talk=d.kind==='talk'?{kind:'talk',factory:d.factory,text:''}:{kind:d.kind,item:d.id,text:''};
      if(d.id){openCall=d.id;chose=true;}
      draw();{const area=$('talkText');if(area)area.focus();}return;
    case 'watch':tab=d.factory;selJob=d.job;hl=null;draw();
      {const card=document.querySelector('#ppBody [data-job="'+CSS.escape(d.job)+'"]');if(card)card.scrollIntoView({block:'center'});}return;
    case 'send':{
      const c=confirming;
      if(c&&c.steer){answer=await act(V.noteFor({act:'steer',factory:c.steer.factory,who:c.steer.who},null));
        if(answer&&answer.ok)confirming=null;break;}
      if(c&&c.older){const o=olderItem(c.item);if(!o)return;
        answer=await act(V.noteFor({act:c.older},o));
        if(answer&&answer.ok){oldSent[o.id]={asking:o.asking,words:c.older==='revive'?'you asked to bring it back':'you said it is no longer needed'};confirming=null;}
        break;}
      const n=c&&need(c.item);if(!n)return;
      answer=await act(V.noteFor(c.keep?{act:'keep'}:{act:'answer',option:c.option},n));
      if(answer&&answer.ok){sent[n.id]={asking:n.asking,key:c.keep?null:c.option};confirming=null;}
      break;}
    case 'talksend':{
      const t=talk;const text=((($('talkText')||{}).value)||'').trim();if(!t)return;
      if(!text){say(false,'Nothing to send yet: type what you want to say first.');draw();return;}
      answer=await act(V.noteFor({act:'talk',kind:t.kind,factory:t.factory,id:t.item,text:text},t.item&&need(t.item)));
      if(answer&&answer.ok)talk=null;
      break;}
    case 'settled':{const n=need(d.id);if(!n)return;answer=await act(V.noteFor({act:'settled'},n));
      if(answer&&answer.ok)asked[n.id]=n.asking;break;}
    case 'steer':
      /* On a project's tab who steers changes after a confirmation, as an answer does. */
      if(tab!=='home'&&!d.sure){confirming={steer:{factory:d.factory,who:d.who}};talk=null;draw();return;}
      answer=await act(V.noteFor(d,null));break;
    case 'read':answer=await act(V.noteFor(d,null));break;
    default:return;
  }
  draw();
  if(answer)mirror(true);
}
document.addEventListener('click',e=>{
  const b=e.target.closest('[data-act]');if(!b||b.disabled)return;
  perform(Object.assign({},b.dataset));
});
document.addEventListener('input',e=>{if(e.target.id==='talkText'&&talk)talk.text=e.target.value;});
function typing(t){return !!(t&&t.closest&&t.closest('textarea,input,select,[contenteditable="true"]'));}
document.addEventListener('keydown',e=>{
  const t=e.target;
  if(t.id==='talkText'&&e.key==='Enter'&&(e.metaKey||e.ctrlKey)){e.preventDefault();
    const go=document.querySelector('[data-act="talksend"]');if(go)go.click();return;}
  if(e.key==='Escape'){
    if(!$('keysSheet').hidden){openKeys(false);$('keysBtn').focus();return;}
    if(!$('settings').hidden){closeSettings();return;}
    if(confirming||talk){perform({act:'cancel'});return;}
    if(typing(t))return;
  }
  /* Keys work only when no typing box has the keyboard, so typing is never taken. */
  if(e.defaultPrevented||typing(t)||e.metaKey||e.ctrlKey||e.altKey||e.isComposing)return;
  if(t.closest&&t.closest('.divider'))return;
  if((e.key==='Enter'||e.key===' ')&&t.closest&&t.closest('button,a,summary'))return;
  if(!M)return;
  const d=V.keyAction(e.key,keyContext());
  if(!d)return;
  e.preventDefault();perform(d);
});
$('sideSwitch').addEventListener('click',e=>{const b=e.target.closest('button');if(b)setSide(b.dataset.side);});

/* ---- settings ---- */
let storage=null;try{storage=window.localStorage;}catch(e){}
let settings=FS.load(storage);
let dim=null;try{dim=window.matchMedia('(prefers-color-scheme: dark)');}catch(e){}
function systemDark(){return !!(dim&&dim.matches);}
function put(next){return FS.apply(document.documentElement,next,systemDark());}
/* Colours: one button per scheme, painted in the light or dark the page shows now. */
{const box=$('schemes');
  ['default'].concat(Object.keys(FS.SCHEMES),['custom']).forEach(name=>{
    const b=el('button');b.type='button';b.dataset.set='colours';b.dataset.value=name;
    const sw=el('span','sw'+(name==='custom'?' own':''));sw.setAttribute('aria-hidden','true');
    if(name!=='custom')for(let i=0;i<3;i++)sw.appendChild(el('i'));
    add(b,sw,el('span','',name==='default'?'Default':name==='custom'?'Custom':FS.SCHEMES[name].name));
    box.appendChild(b);});}
const PICKERS={accent:'pickAccent',bg:'pickBg',ink:'pickInk'};
/* The page's own colours, for Default's swatch and for a picker with nothing kept yet to start from. */
function own(){return FS.own(document.documentElement).picks||{accent:'#47707f',bg:'#ece8e1',ink:'#2a2a28'};}
function mode(){return FS.isDark(settings,systemDark())?'dark':'light';}
function colourNote(nudged){
  const lifted=nudged.indexOf('bg')>=0?'No text reads well on that background, so it is shown a shade lighter.':'';
  const faint=nudged.filter(n=>n!=='bg');
  if(!faint.length)return lifted;
  const what=faint.length>1?'The text and accent colours were':faint[0]==='ink'?'That text colour was':'That accent was';
  return (lifted?lifted+' ':'')+what+' too faint to read on this background, so '+(faint.length>1?'each is':'it is')+' shown in the nearest readable shade.';}
function drawColours(){
  const dark=mode()==='dark';
  document.querySelectorAll('#schemes button').forEach(b=>{
    const picks=b.dataset.value==='default'?own():FS.SCHEMES[b.dataset.value]?FS.SCHEMES[b.dataset.value][mode()]:null;
    if(!picks)return;const is=b.querySelectorAll('.sw i');
    ['bg','ink','accent'].forEach((k,i)=>{is[i].style.background=picks[k];});});
  const custom=settings.colours==='custom';$('pickers').hidden=!custom;
  if(custom){const picks=FS.picksFor(settings,dark)||own();
    Object.keys(PICKERS).forEach(k=>{$(PICKERS[k]).value=picks[k];});}
  $('colourHint').textContent=custom?'Your colours for '+mode()+' are kept apart from those for '+(dark?'light':'dark')+'.'
    :'Each scheme has its own light and dark.';
}
function drawSettings(){
  $('textSize').max=String(FS.TEXT_STEPS.length-1);$('textSize').value=String(settings.text);
  $('textNow').textContent=FS.TEXT_NAMES[settings.text];
  document.querySelectorAll('#settings [data-set]').forEach(b=>b.setAttribute('aria-pressed',String(settings[b.dataset.set]===b.dataset.value)));
  $('lessMotion').checked=settings.motion==='less';
  $('keyHints').checked=settings.keys==='show';
  drawColours();
}
function changeAll(values){
  settings=put(FS.save(storage,Object.assign({},settings,values)));drawSettings();autosize();
  homeDivider.label();
}
function change(name,value){const values={};values[name]=value;changeAll(values);}
/* Custom starts from the colours on screen, for light and for dark alike, and keeps what was picked before. */
function startCustom(){
  if(settings.colours==='custom')return;
  const custom=Object.assign({light:null,dark:null},settings.custom||{});
  ['light','dark'].forEach(m=>{if(!custom[m])custom[m]=FS.picksFor(settings,m==='dark');});
  if(!custom[mode()])custom[mode()]=own();
  $('colourNote').textContent='';
  changeAll({colours:'custom',custom:custom});
}
/* A pick shows at once; letting go keeps it, moved to a readable shade when it was too faint, and says so. */
function pick(input,keep){
  const set=Object.assign({},FS.picksFor(settings,mode()==='dark')||own());set[input.dataset.pick]=input.value.toLowerCase();
  const custom=Object.assign({light:null,dark:null},settings.custom||{});
  const made=FS.palette(set,{});$('colourNote').textContent=colourNote(made.nudged);
  if(keep){set.ink=made.vars['--ink'];set.accent=made.vars['--here'];}
  custom[mode()]=set;
  if(keep)changeAll({custom:custom});
  else put(Object.assign({},settings,{custom:custom}));
}
Object.keys(PICKERS).forEach(k=>{const input=$(PICKERS[k]);
  input.addEventListener('input',()=>pick(input,false));input.addEventListener('change',()=>pick(input,true));});
$('colourReset').addEventListener('click',()=>{$('colourNote').textContent='';changeAll({colours:'default',custom:null});});
if(dim&&dim.addEventListener)dim.addEventListener('change',()=>{settings=put(settings);drawSettings();});
function closeSettings(){$('settings').hidden=true;$('gear').setAttribute('aria-expanded','false');$('gear').focus();}
$('gear').addEventListener('click',()=>{const panel=$('settings');panel.hidden=!panel.hidden;
  $('gear').setAttribute('aria-expanded',String(!panel.hidden));if(!panel.hidden){drawSettings();$('textSize').focus();}});
$('settingsClose').addEventListener('click',closeSettings);
$('textSize').addEventListener('input',e=>change('text',Number(e.target.value)));
$('lessMotion').addEventListener('change',e=>change('motion',e.target.checked?'less':'auto'));
$('keyHints').addEventListener('change',e=>change('keys',e.target.checked?'show':'hide'));
$('resetSizes').addEventListener('click',()=>{Object.keys(FS.SPLITS).forEach(n=>change(n,FS.DEFAULTS[n]));});
$('settings').addEventListener('click',e=>{const b=e.target.closest('[data-set]');if(!b)return;
  if(b.dataset.set==='colours'){$('colourNote').textContent='';if(b.dataset.value==='custom'){startCustom();return;}}
  change(b.dataset.set,b.dataset.value);});
document.addEventListener('click',e=>{if(!$('settings').hidden&&!e.target.closest('#settings')&&!e.target.closest('#gear'))closeSettings();});
$('gear').prepend(icon('sliders'));$('settingsClose').appendChild(icon('close'));$('keysClose').appendChild(icon('close'));
$('keysBtn').addEventListener('click',()=>openKeys($('keysSheet').hidden));
$('keysClose').addEventListener('click',()=>{openKeys(false);$('keysBtn').focus();});
{const body=$('keysList');V.KEYS.forEach(k=>{const tr=el('tr');const a=el('td');a.appendChild(el('kbd','',k[0]));
  add(tr,a,el('td','',k[1]));body.appendChild(tr);});}
drawSettings();

/* ---- the divider: drag, double-click to reset, arrow keys when focused ---- */
function divider(node,main,name){
  function label(){node.setAttribute('aria-orientation','vertical');
    node.setAttribute('aria-valuenow',String(Math.round(settings[name]*100)));}
  function place(value,keep){const range=FS.SPLITS[name];
    value=Math.min(range[1],Math.max(range[0],value));
    if(keep)change(name,value);else{settings[name]=value;put(settings);label();}}
  node.addEventListener('pointerdown',e=>{
    if(e.button!==0)return;e.preventDefault();node.setPointerCapture(e.pointerId);node.classList.add('drag');
    const moved=ev=>{const r=main.getBoundingClientRect();place((ev.clientX-r.left)/r.width,false);};
    const done=()=>{node.classList.remove('drag');node.removeEventListener('pointermove',moved);
      node.removeEventListener('pointerup',done);node.removeEventListener('pointercancel',done);place(settings[name],true);};
    node.addEventListener('pointermove',moved);node.addEventListener('pointerup',done);node.addEventListener('pointercancel',done);
  });
  node.addEventListener('dblclick',()=>place(FS.DEFAULTS[name],true));
  node.addEventListener('keydown',e=>{
    const range=FS.SPLITS[name];const now=settings[name];
    let next=null;
    if(e.key==='ArrowLeft')next=now-0.02;else if(e.key==='ArrowRight')next=now+0.02;
    else if(e.key==='Home')next=range[0];else if(e.key==='End')next=range[1];
    else if(e.key==='Enter')next=FS.DEFAULTS[name];
    if(next===null)return;
    e.preventDefault();e.stopPropagation();place(next,true);
  });
  label();
  return {label:label};
}
const homeDivider=divider($('divHome'),$('home'),'split');

document.querySelectorAll('.brand').forEach(b=>b.prepend(ship()));
setSide('projects');poll();mirror();
})();
"""


def ship_symbol() -> str:
    return (f'<svg class="sym" width="0" height="0" aria-hidden="true"><symbol id="ship" viewBox="0 0 24 24">'
            f'<path d="{ship_mark_path()}" fill="currentColor" fill-rule="evenodd"/></symbol></svg>')


def head_html(nonce: str, title: str) -> str:
    """What every page's head carries: the look, the icons and the manifest."""
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="icon" href="/icon-32.png" sizes="32x32" type="image/png">
<link rel="apple-touch-icon" href="/icon-180.png">
<link rel="manifest" href="/manifest.webmanifest">
<meta name="theme-color" content="#143242">
<meta name="apple-mobile-web-app-title" content="Starship">
<meta name="mobile-web-app-capable" content="yes">
<style nonce="{nonce}">{PAGE_CSS}</style>
<script nonce="{nonce}" src="/settings.js"></script>
<script nonce="{nonce}">(function(){{var s=null,d=false;try{{s=window.localStorage;}}catch(e){{}}
try{{d=window.matchMedia('(prefers-color-scheme: dark)').matches;}}catch(e){{}}
FMSettings.apply(document.documentElement,FMSettings.load(s),d);}})();</script>
"""


def signin_html(nonce: str, stale: bool) -> str:
    """The page the address shows before signing in: what this is and how to get in."""
    note = ('<p class="notice bad">That link has expired or was already used. Ask for a new one.</p>' if stale else "")
    return head_html(nonce, "Starship") + f"""</head>
<body>{ship_symbol()}
<main class="gate"><div class="gate-card">
<div class="mark"><svg viewBox="0 0 24 24" aria-hidden="true"><use href="#ship"/></svg><span>Starship</span></div>
<p>This is your Starship page: your firstmate's chat and every project's work, in plain words. It opens only on this Mac, and only for you.</p>
{note}
<h2>How to get in</h2>
<ol>
<li>Ask your firstmate to open the Starship page. It opens as its own app window, already signed in.</li>
<li>Or, on this Mac, run <code>bin/fm-web.sh open</code> in Terminal, from your Starship folder.</li>
</ol>
<h2>Keep it as an app</h2>
<p>Once you are in, install it so it opens on its own, full screen, with no address bar: in Chrome, choose Install Starship from the menu; in Safari, choose File, then Add to Dock.</p>
</div></main>
</body></html>
"""


def weekly_path(home: Path) -> Path:
    """The newest weekly "what changed" page, which bin/fm-weekly-changes.py owns."""
    return home / "data" / "weekly-changes" / "latest.html"


def weekly_page(home: Path) -> Optional[str]:
    try:
        return weekly_path(home).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None


def page_html(nonce: str, csrf: str, weekly: bool = False) -> str:
    weekly_link = ('<a class="qbtn" href="/weekly" target="_blank" rel="noopener" '
                   'title="What changed this week">This week</a>\n') if weekly else ""
    return head_html(nonce, "Starship") + f"""<script nonce="{nonce}" src="/view.js"></script>
</head>
<body data-csrf="{html.escape(csrf, quote=True)}" data-build="{html.escape(BUILD, quote=True)}">{ship_symbol()}
<div class="app">
<header class="top" id="top">
<div class="brand"><span>Starship</span></div>
<nav class="tabs" id="tabs" role="tablist" aria-label="Projects"></nav>
<div class="band" id="band"><span class="band-note">reading the crew</span></div>
<div class="tools">{weekly_link}<button class="qbtn" id="keysBtn" type="button" aria-expanded="false" aria-controls="keysSheet" aria-label="Keyboard keys" title="Keyboard keys (?)">?</button>
<button class="gear" id="gear" type="button" aria-expanded="false" aria-controls="settings"><span>Settings</span></button></div>
</header>
<div class="side-switch" id="sideSwitch"><button type="button" data-side="chat">Firstmate</button>
<button type="button" data-side="projects">Factories</button></div>
<main class="main" id="home" data-side="projects">
<section class="pane" id="chatPane" aria-label="Firstmate">
<div class="pane-head"><h2>Firstmate</h2>
<span id="state" class="state offline"><span class="label">Connecting</span></span></div>
<div id="log"><div class="wrap">
<p id="older" class="note" hidden>Earlier conversation is in the terminal history.</p>
<div id="items"></div>
<div id="live" class="live" hidden><span class="dots" aria-hidden="true"><i></i><i></i><i></i></span>
<span class="what" role="status"></span><span class="took" aria-hidden="true"></span></div>
<div id="waiting"></div>
<p id="note" class="note"></p></div></div>
<div id="compose"><div class="wrap">
<div id="thumbs"></div>
<div id="row"><textarea id="input" rows="1" placeholder="Message firstmate" aria-label="Message"></textarea>
<button id="send" class="btn primary" type="button">Send</button></div>
<div id="foot"><div class="statusrow" id="statusrow" aria-label="Status bar" hidden></div>
<div id="result" role="status"></div></div>
</div></div>
</section>
<div class="divider" id="divHome" role="separator" tabindex="0" aria-label="Move the line between firstmate and Factories" aria-valuemin="25" aria-valuemax="75" title="Drag to resize; double-click to reset"></div>
<section class="pane" id="panelPane" aria-label="Factories">
<div class="pane-head"><h2>Factories</h2><span class="sub">Each project's work, start to finish</span><span class="when" id="clock"></span></div>
<div class="p-top" id="ptop"><p class="sum">reading the crew</p></div>
<div class="p-body" id="pbody"></div>
</section>
</main>
<main class="main" id="project" hidden>
<section class="pane" aria-label="Project"><div class="pp-head" id="ppHead"></div><div class="p-body" id="ppBody"></div></section>
</main>
<footer class="keystrip" id="keystrip" aria-label="Keys"></footer>
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
<div class="set"><div class="lbl">Colours</div>
<div class="swatches" id="schemes" role="group" aria-label="Colour schemes"></div>
<div class="pickers" id="pickers" hidden>
<label class="pick"><input type="color" id="pickAccent" data-pick="accent">Accent</label>
<label class="pick"><input type="color" id="pickBg" data-pick="bg">Background</label>
<label class="pick"><input type="color" id="pickInk" data-pick="ink">Text</label>
</div>
<p class="hint" id="colourNote" role="status"></p>
<button class="btn small" id="colourReset" type="button">Back to default</button>
<p class="hint" id="colourHint"></p></div>
<div class="set"><div class="lbl">Movement</div>
<label class="switch"><input id="lessMotion" type="checkbox">Reduce motion</label></div>
<div class="set"><div class="lbl">Keyboard</div>
<label class="switch"><input id="keyHints" type="checkbox">Show key hints</label>
<p class="hint">The small letters on the buttons and the line of keys at the bottom. Press ? for every key.</p></div>
<div class="set"><div class="lbl">Panels</div>
<button class="btn small" id="resetSizes" type="button">Put the panels back</button>
<p class="hint">Drag the line between two panels to resize them; double-click it to put it back.</p></div>
<p class="hint">Kept in this browser only.</p>
</section>
<section class="sheet" id="keysSheet" role="dialog" aria-modal="true" aria-label="Keyboard keys" hidden>
<h2>Keyboard keys<button class="btn small plain" id="keysClose" type="button" aria-label="Close the keys"></button></h2>
<p class="hint">They work whenever you are not typing in a box, and send what the buttons send.</p>
<table><tbody id="keysList"></tbody></table>
</section>
<script nonce="{nonce}">{PAGE_JS}</script>
</body></html>
"""


# --- commands ----------------------------------------------------------------


def code_digest() -> Optional[str]:
    try:
        return hashlib.sha256(CODE_PATH.read_bytes()).hexdigest()[:16]
    except OSError:
        return None


# The code this process runs. The page carries it, and reloads itself once a
# reading says the server now runs other code.
BUILD = code_digest() or "unknown"


def restart_argv(port: int) -> List[str]:
    """This process's command line, with the port it bound, so a server
    started on port 0 keeps its port across a restart."""
    args = list(sys.argv[1:])
    for i, arg in enumerate(args):
        if arg == "--port" and i + 1 < len(args):
            args[i + 1] = str(port)
            break
        if arg.startswith("--port="):
            args[i] = f"--port={port}"
            break
    else:
        args += ["--port", str(port)]
    return [sys.executable, sys.argv[0]] + args


def watch_code(port: int) -> None:
    """Restart this server in place once its own code on disk has changed, so
    a Starship update shows on the page without anyone restarting it.

    The new code must read the same on two checks in a row, so a file still
    being written is never run, and must compile, so a broken update leaves
    the running server as it is. The restart replaces this process with the
    same command line, keeping its pid for bin/fm-web.sh; the listening socket
    closes with it and the new code binds the same port again, retrying for a
    few seconds (FM_WEB_RESTARTED)."""
    seen = BUILD
    refused = None
    while True:
        time.sleep(CODE_CHECK_SECONDS)
        now = code_digest()
        if now is None or now == BUILD or now != seen or now == refused:
            seen = now
            continue
        try:
            compile(CODE_PATH.read_bytes(), str(CODE_PATH), "exec")
        except Exception as exc:  # any compile failure keeps the running code
            refused = now
            print(f"not restarting: the changed {CODE_PATH.name} does not compile: {exc}", file=sys.stderr, flush=True)
            continue
        print(f"{CODE_PATH.name} changed on disk; restarting", flush=True)
        sys.stderr.flush()
        os.environ["FM_WEB_RESTARTED"] = "1"
        argv = restart_argv(port)
        STATE.send_lock.acquire()
        STATE.act_lock.acquire()
        try:
            os.execv(argv[0], argv)
        except OSError as exc:
            STATE.act_lock.release()
            STATE.send_lock.release()
            refused = now
            print(f"not restarting: {exc}", file=sys.stderr, flush=True)


def command_serve(home: Path, root: Path, port: int) -> None:
    token = load_or_create_token(home)
    tries = 50 if os.environ.pop("FM_WEB_RESTARTED", "") else 1
    while True:
        try:
            server = ThreadingHTTPServer((LOOPBACK, port), WebHandler)
            break
        except OSError as exc:
            tries -= 1
            if tries <= 0:
                fail(f"could not bind {LOOPBACK}:{port}: {exc}")
            time.sleep(0.1)
    bound = server.server_address[1]
    global STATE
    STATE = WebState(home, root, bound, token)
    print(f"listening on {LOOPBACK}:{bound}", flush=True)
    threading.Thread(target=watch_code, args=(bound,), daemon=True).start()
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
        "since": payload.get("since"),
        "note": payload.get("note", ""),
        "older": bool(payload.get("older")),
        "version": payload.get("version"),
        "items": payload.get("items", []),
        "waiting": payload.get("waiting", []),
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
    code = sub.add_parser("signin-code")
    code.add_argument("--home", required=True)
    conv = sub.add_parser("conversation")
    conv.add_argument("--home", required=True)
    args = parser.parse_args(argv)
    if args.command == "serve":
        command_serve(Path(args.home), Path(args.root), args.port)
    elif args.command == "token":
        print(load_or_create_token(Path(args.home)))
    elif args.command == "signin-code":
        print(make_signin_code(Path(args.home)))
    elif args.command == "conversation":
        command_conversation(Path(args.home))


if __name__ == "__main__":
    main()
