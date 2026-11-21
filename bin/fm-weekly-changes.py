#!/usr/bin/env python3
"""fm-weekly-changes.py - opt-in weekly plain "what changed" page.

Usage:
  fm-weekly-changes.py run
  fm-weekly-changes.py preview [--days N] [--out FILE]
  fm-weekly-changes.py latest
  fm-weekly-changes.py open
  fm-weekly-changes.py status
  fm-weekly-changes.py interval
  fm-weekly-changes.py --help

Once a week, at about the configured local weekday and time (Monday 07:00 by
default), this writes one calm local web page saying, in plain words, what
changed in every registered project over the past week, for a reader who does
not open pull requests:

  - a lead sentence: how many changes landed across how many projects
  - per project, busiest first: the changelog highlights added that week, then
    every pull request merged that week, each shown by the first section of its
    description headed "In short" (falling back to its title without any
    "feat(scope):" style prefix), with a link to the pull request
  - the projects where nothing landed, and the projects that could not be read
    and why, so a quiet week is never confused with a broken one

A summary can miss nuance, so the page says so and every line links to the
pull request it came from.

PROJECTS. Every row of data/projects.md (the "- <name> [<tokens>] - <desc>"
grammar bin/fm-project-mode.sh owns) is a project. Its local copy is
projects/<name> or projects/<alias> under FM_HOME; a row with neither whose
name or alias equals the code root's directory name (the firstmate repository
itself, registered as a project) is read from the code root. The row's
label=<word> names it, else bin/fm-project-display-name.sh does. Only a copy
whose origin is on github.com is read; the page names the others.

SOURCES. It reads GitHub through `gh` (FM_WEEKLY_CHANGES_GH overrides the
command) and never changes anything there or in a project copy, which it only
asks for its origin:
  gh pr list --repo <owner/repo> --state merged --search merged:>=<date> \
    --limit 200 --json number,title,url,body,mergedAt
  gh api repos/<owner/repo>/commits?path=CHANGELOG.md&until=<iso>&per_page=1
  gh api -H 'Accept: application/vnd.github.raw+json' \
    repos/<owner/repo>/contents/CHANGELOG.md?ref=<sha>
Changelog highlights are the top-level "- " bullets of the default branch's
root CHANGELOG.md at the end of the week that were not in it at the start,
each shown by its bold lead when it has one.

IT ONLY REPORTS. It never wakes firstmate, writes no backlog, inbox or status
record, never takes the per-home session lock (only a private mutex over its
own directory), and its only network use is the read-only gh calls above.

`run` is the scheduled entry point (bin/fm-weekly-changes-schedule.sh installs
it on macOS launchd) and the manual command. It writes the page for the latest
weekly slot whose time has passed, once; a slot missed while the machine slept
is written on the first run after it wakes. The page covers the `days` before
that slot. When every project that should be read fails, nothing is written
and it exits 1, so the next scheduled run tries the same slot again; when only
some fail, the page is written and names them.
`preview` writes the page for the `days` ending now to --out FILE, or prints it,
and works whether or not the home has opted in. `latest` prints the newest
page's path, `open` opens it in the default browser, `status` prints the
resolved settings and the newest page, and `interval` prints the schedule's
poll cadence.

PAGES. data/weekly-changes/pages/<slot-local-date>.html holds each week's page
(the newest 26 are kept) and data/weekly-changes/latest.html is a copy of the
newest; each is one self-contained HTML file with no script and no outside
resource, replaced whole and atomically. bin/fm-web.py serves latest.html at
/weekly on the friendly mirror.

CONFIGURATION. Opt-in is per home and per device: with no `enabled = true`
line in private gitignored config/weekly-changes, `run` does nothing at all, so
cloning the repo or seeding a secondmate home never enrols it. Lines are
`key = value`; `#` starts a comment line, and unknown keys are refused.
  enabled           true to arm this home (default false)
  weekday           the slot's local weekday, monday..sunday (default monday)
  time              the slot's local HH:MM (default 07:00)
  days              how many days one page covers (default 7)
  interval_seconds  scheduled poll cadence (default 3600)

Environment:
  FM_HOME                  operational home whose registry and pages are used
  FM_ROOT_OVERRIDE         code root (defaults to this script's repository)
  FM_WEEKLY_CHANGES_NOW    epoch second used as "now" (tests)
  FM_WEEKLY_CHANGES_GH     gh command (default gh)
  FM_WEEKLY_CHANGES_OPEN   command `open` hands the page path to
"""

from __future__ import annotations

import calendar
import fcntl
import html
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Dict, List, Optional, Tuple

SCRIPT_DIR = Path(__file__).resolve().parent
ROOT = Path(os.environ.get("FM_ROOT_OVERRIDE") or SCRIPT_DIR.parent)
HOME = Path(os.environ.get("FM_HOME") or ROOT)
CONFIG_FILE = HOME / "config" / "weekly-changes"
PAGE_DIR = HOME / "data" / "weekly-changes"
PAGES = PAGE_DIR / "pages"
LATEST = PAGE_DIR / "latest.html"
KEEP_PAGES = 26
PR_LIMIT = 200
GH_TIMEOUT = 60
TEXT_MAX = 320
HIGHLIGHTS_MAX = 8
CHANGELOG = "CHANGELOG.md"

WEEKDAYS = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
DEFAULTS = {"enabled": "false", "weekday": "monday", "time": "07:00", "days": "7",
            "interval_seconds": "3600"}

# One data/projects.md row; the name ends at the first " [" or " - ", as in
# bin/fm-project-mode.sh.
PROJECT_ROW_RE = re.compile(r"^- (.+?)(?: \[([^\]]*)\])?(?: - |$)")
GITHUB_RE = re.compile(r"github\.com[:/]+([^/\s]+)/([^/\s]+?)(?:\.git)?/?$")
IN_SHORT_RE = re.compile(r"^\s{0,3}#{1,6}\s*in short\s*#*\s*$", re.I)
SECTION_END_RE = re.compile(r"^\s{0,3}#{1,6}\s|^\s*<details\b|^\s*</details>", re.I)
# Inline HTML a PR description may carry; any other angle-bracket text is kept
# as written and escaped on the page.
HTML_TAG_RE = re.compile(
    r"</?(?:a|b|i|em|strong|code|kbd|br|p|span|div|sub|sup|img|details|summary)\b[^>]*>", re.I)
TITLE_PREFIX_RE = re.compile(r"^[A-Za-z]+(?:\([^)]*\))?!?:\s+")


def die(message: str, code: int = 2) -> None:
    print(f"fm-weekly-changes: {message}", file=sys.stderr)
    sys.exit(code)


def now() -> float:
    raw = os.environ.get("FM_WEEKLY_CHANGES_NOW", "")
    if raw:
        if not raw.isdigit():
            die(f"FM_WEEKLY_CHANGES_NOW must be epoch seconds: {raw}")
        return float(raw)
    return time.time()


# --- configuration ----------------------------------------------------------

def load_config() -> Dict[str, str]:
    cfg = dict(DEFAULTS)
    try:
        text = CONFIG_FILE.read_text(encoding="utf-8")
    except FileNotFoundError:
        text = ""
    except OSError as exc:
        die(f"cannot read {CONFIG_FILE}: {exc}")
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            die(f"config/weekly-changes line {number} is not 'key = value'")
        key, value = (part.strip() for part in line.split("=", 1))
        if key not in DEFAULTS:
            die(f"config/weekly-changes has an unknown key: {key}")
        cfg[key] = value
    if cfg["enabled"] not in ("true", "false"):
        die(f"enabled must be true or false: {cfg['enabled']}")
    cfg["weekday"] = cfg["weekday"].lower()
    if cfg["weekday"] not in WEEKDAYS:
        die(f"weekday must be one of {', '.join(WEEKDAYS)}: {cfg['weekday']}")
    match = re.fullmatch(r"([01]\d|2[0-3]):([0-5]\d)", cfg["time"])
    if not match:
        die(f"time must be HH:MM: {cfg['time']}")
    for key in ("days", "interval_seconds"):
        if not re.fullmatch(r"[1-9]\d*", cfg[key]):
            die(f"{key} must be a positive integer: {cfg[key]}")
    return cfg


# --- time -------------------------------------------------------------------

def local_at(day: time.struct_time, hour: int, minute: int) -> float:
    """Epoch of HH:MM local on day's calendar date, honouring daylight saving."""
    return time.mktime((day.tm_year, day.tm_mon, day.tm_mday, hour, minute, 0, 0, 0, -1))


def shift_days(epoch: float, days: int, hour: int, minute: int) -> float:
    """HH:MM local on the calendar date `days` before epoch's local date."""
    noon = time.localtime(epoch)
    probe = time.mktime((noon.tm_year, noon.tm_mon, noon.tm_mday - days, 12, 0, 0, 0, 0, -1))
    return local_at(time.localtime(probe), hour, minute)


def latest_slot(cfg: Dict[str, str], at: float) -> float:
    hour, minute = (int(x) for x in cfg["time"].split(":"))
    want = WEEKDAYS.index(cfg["weekday"])
    for back in range(8):
        candidate = shift_days(at, back, hour, minute)
        if time.localtime(candidate).tm_wday == want and candidate <= at:
            return candidate
    raise AssertionError("no weekly slot in the last eight days")


def iso_utc(epoch: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


def parse_iso(value: str) -> Optional[float]:
    match = re.fullmatch(r"(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.\d+)?Z", value or "")
    if not match:
        return None
    return float(calendar.timegm(tuple(int(g) for g in match.groups()) + (0, 0, 0)))


def day_words(epoch: float, with_year: bool, with_month: bool = True) -> str:
    t = time.localtime(epoch)
    text = f"{WEEKDAYS[t.tm_wday].capitalize()} {t.tm_mday}"
    if with_month:
        text += time.strftime(" %B", t)
    if with_year:
        text += f" {t.tm_year}"
    return text


def range_words(start: float, end: float) -> str:
    s, e = time.localtime(start), time.localtime(end)
    same_month = (s.tm_year, s.tm_mon) == (e.tm_year, e.tm_mon)
    return (f"{day_words(start, s.tm_year != e.tm_year, not same_month)} "
            f"to {day_words(end, True)}")


# --- projects ---------------------------------------------------------------

def display_name(name: str, tokens: List[str]) -> str:
    for token in tokens:
        if token.startswith("label=") and len(token) > len("label="):
            return token[len("label="):]
    try:
        out = subprocess.run([str(SCRIPT_DIR / "fm-project-display-name.sh"), name],
                             capture_output=True, text=True, timeout=10, check=True)
        return out.stdout.strip() or name
    except (OSError, subprocess.SubprocessError):
        return name


def registered_projects() -> List[Dict[str, object]]:
    try:
        text = (HOME / "data" / "projects.md").read_text(encoding="utf-8")
    except FileNotFoundError:
        return []
    except (OSError, UnicodeDecodeError) as exc:
        die(f"cannot read data/projects.md: {exc}", 1)
    projects = []
    for line in text.splitlines():
        match = PROJECT_ROW_RE.match(line)
        if not match:
            continue
        name = match.group(1).strip()
        tokens = (match.group(2) or "").split()
        aliases = [t[len("alias="):] for t in tokens if t.startswith("alias=") and len(t) > len("alias=")]
        copy = None
        for candidate in [name, *aliases]:
            if "/" in candidate or candidate in (".", ".."):
                continue
            path = HOME / "projects" / candidate
            if path.is_dir():
                copy = path
                break
        if copy is None and ROOT.name in [name, *aliases]:
            copy = ROOT
        projects.append({"name": name, "label": display_name(name, tokens), "copy": copy})
    return projects


def github_slug(copy: Path) -> Optional[str]:
    try:
        out = subprocess.run(["git", "-C", str(copy), "remote", "get-url", "origin"],
                             capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    match = GITHUB_RE.search(out.stdout.strip()) if out.returncode == 0 else None
    return f"{match.group(1)}/{match.group(2)}" if match else None


# --- GitHub reads -------------------------------------------------------------

def gh(*args: str) -> str:
    command = shlex.split(os.environ.get("FM_WEEKLY_CHANGES_GH") or "gh") + list(args)
    env = dict(os.environ, GH_PROMPT_DISABLED="1", GH_NO_UPDATE_NOTIFIER="1")
    try:
        out = subprocess.run(command, capture_output=True, text=True, timeout=GH_TIMEOUT, env=env)
    except (OSError, subprocess.SubprocessError) as exc:
        raise RuntimeError(str(exc)) from exc
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip() or f"gh exited {out.returncode}")
    return out.stdout


def merged_prs(slug: str, start: float, end: float) -> Tuple[List[Dict[str, object]], bool]:
    since = time.strftime("%Y-%m-%d", time.gmtime(start - 86400))
    raw = gh("pr", "list", "--repo", slug, "--state", "merged", "--search", f"merged:>={since}",
             "--limit", str(PR_LIMIT), "--json", "number,title,url,body,mergedAt")
    try:
        rows = json.loads(raw or "[]")
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"unreadable pull request list: {exc}") from exc
    found = []
    for row in rows if isinstance(rows, list) else []:
        merged = parse_iso(str(row.get("mergedAt") or ""))
        if merged is None or not start <= merged < end:
            continue
        url = str(row.get("url") or "")
        found.append({
            "merged": merged,
            "url": url if url.startswith("https://") else "",
            "text": in_short(str(row.get("body") or "")) or plain_title(str(row.get("title") or "")),
        })
    found.sort(key=lambda item: item["merged"])
    return found, len(rows) >= PR_LIMIT


def changelog_sha(slug: str, until: float) -> Optional[str]:
    raw = gh("api", f"repos/{slug}/commits?path={CHANGELOG}&until={iso_utc(until)}&per_page=1")
    rows = json.loads(raw or "[]")
    return str(rows[0]["sha"]) if rows else None


def changelog_bullets(slug: str, sha: Optional[str]) -> List[str]:
    if not sha:
        return []
    text = gh("api", "-H", "Accept: application/vnd.github.raw+json",
              f"repos/{slug}/contents/{CHANGELOG}?ref={sha}")
    return [line.rstrip() for line in text.splitlines() if line.startswith("- ")]


def changelog_highlights(slug: str, start: float, end: float) -> List[str]:
    try:
        old_sha, new_sha = changelog_sha(slug, start), changelog_sha(slug, end)
        if new_sha is None or new_sha == old_sha:
            return []
        before = set(changelog_bullets(slug, old_sha))
        added = [b for b in changelog_bullets(slug, new_sha) if b not in before]
    except (RuntimeError, json.JSONDecodeError, KeyError, IndexError, TypeError) as exc:
        raise RuntimeError(f"changelog: {exc}") from exc
    highlights = []
    for bullet in added:
        lead = re.match(r"- \*\*(.+?)\*\*", bullet)
        text = clean(lead.group(1) if lead else bullet[2:])
        if text and text not in highlights:
            highlights.append(text)
    return highlights


# --- plain text -------------------------------------------------------------

def shorten(text: str) -> str:
    if len(text) <= TEXT_MAX:
        return text
    cut = text[:TEXT_MAX].rsplit(" ", 1)[0].rstrip(",;:")
    return cut + "..."


def clean(text: str) -> str:
    text = re.sub(r"!\[[^\]]*\]\([^)]*\)", "", text)
    text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"`([^`]*)`", r"\1", text)
    text = re.sub(r"(\*\*|__)(.+?)\1", r"\2", text)
    text = HTML_TAG_RE.sub("", text)
    text = re.sub(r"\s+", " ", text).strip()
    return shorten(text)


def in_short(body: str) -> str:
    body = re.sub(r"<!--.*?-->", "", body, flags=re.S)
    lines = body.splitlines()
    for index, line in enumerate(lines):
        if IN_SHORT_RE.match(line):
            taken = []
            for following in lines[index + 1:]:
                if SECTION_END_RE.match(following):
                    break
                stripped = re.sub(r"^\s*(?:>\s*|[-*]\s+)", "", following).strip()
                if stripped:
                    taken.append(stripped)
            return clean(" ".join(taken))
    return ""


def plain_title(title: str) -> str:
    text = clean(TITLE_PREFIX_RE.sub("", title.strip()))
    return text[:1].upper() + text[1:] if text else "A change with no title"


# --- the page ---------------------------------------------------------------

def collect(start: float, end: float) -> Tuple[Dict[str, object], int]:
    """The page's facts and how many readable projects failed outright."""
    busy, quiet, unread = [], [], []
    attempted = failed = 0
    for project in registered_projects():
        label = str(project["label"])
        copy = project["copy"]
        if copy is None:
            unread.append((label, "it has no copy on this computer"))
            continue
        slug = github_slug(copy)  # type: ignore[arg-type]
        if slug is None:
            unread.append((label, "it is not on GitHub"))
            continue
        attempted += 1
        try:
            prs, capped = merged_prs(slug, start, end)
        except RuntimeError:
            failed += 1
            unread.append((label, "GitHub could not be reached for it"))
            continue
        note = ""
        try:
            highlights = changelog_highlights(slug, start, end)
        except RuntimeError:
            highlights = []
            note = "Its changelog could not be read this time."
        if capped:
            note = (note + " " if note else "") + f"Only the newest {PR_LIMIT} changes were read."
        if prs or highlights:
            busy.append({"label": label, "prs": prs, "highlights": highlights, "note": note})
        else:
            quiet.append(label)
    busy.sort(key=lambda p: (-len(p["prs"]), str(p["label"]).lower()))  # type: ignore[arg-type]
    facts = {"start": start, "end": end, "busy": busy, "quiet": quiet, "unread": unread}
    return facts, (failed if failed == attempted and attempted else 0)


def plural(n: int, one: str, many: str) -> str:
    return f"{n} {one if n == 1 else many}"


def lead_sentence(busy: List[Dict[str, object]]) -> str:
    total = sum(len(p["prs"]) for p in busy)  # type: ignore[arg-type]
    if not busy:
        return "Nothing landed this week."
    if total == 0:
        return "No pull requests landed this week, but the changelog moved."
    if len(busy) == 1:
        return f"{plural(total, 'change', 'changes')} landed in {busy[0]['label']}."
    return f"{plural(total, 'change', 'changes')} landed across {len(busy)} projects."


CSS = """
:root{--bg:#f7f5f0;--card:#fffdf8;--ink:#23211c;--soft:#6b665c;--line:#e4dfd3;--accent:#2f6f62;--chip:#ece8dd}
@media (prefers-color-scheme: dark){:root{--bg:#161614;--card:#1f1e1b;--ink:#ece8df;--soft:#a39e92;--line:#34322c;--accent:#7cc4b2;--chip:#2a2925}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:17px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
main{max-width:760px;margin:0 auto;padding:40px 16px 64px}
h1{font-size:30px;line-height:1.2;margin:0 0 6px;letter-spacing:-.01em}
.range{color:var(--soft);margin:0 0 22px}
.lead{font-size:20px;margin:0 0 28px}
section{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:20px 22px;margin:0 0 18px}
h2{font-size:21px;margin:0 0 12px;display:flex;align-items:baseline;gap:10px;flex-wrap:wrap}
h2 span{font-size:14px;font-weight:500;color:var(--soft);background:var(--chip);border-radius:999px;padding:2px 10px}
h3{font-size:13px;text-transform:uppercase;letter-spacing:.06em;color:var(--soft);margin:16px 0 6px}
ul{list-style:none;margin:0;padding:0}
li{padding:9px 0;border-top:1px solid var(--line)}
li:first-child{border-top:0}
.when{color:var(--soft);font-size:14px;margin-right:6px}
a{color:var(--accent);text-decoration:none;font-size:15px;white-space:nowrap}
a:hover{text-decoration:underline}
.note{color:var(--soft);font-size:15px;margin:10px 0 0}
.quiet{color:var(--soft);margin:22px 0 6px}
footer{color:var(--soft);font-size:14px;margin-top:30px;border-top:1px solid var(--line);padding-top:14px}
"""


def render(facts: Dict[str, object], generated: float) -> str:
    e = html.escape
    start, end = float(facts["start"]), float(facts["end"])  # type: ignore[arg-type]
    busy: List[Dict[str, object]] = facts["busy"]  # type: ignore[assignment]
    parts = [
        "<!doctype html>",
        '<html lang="en"><head><meta charset="utf-8">',
        '<meta name="viewport" content="width=device-width, initial-scale=1">',
        "<title>What changed this week</title>",
        f"<style>{CSS}</style></head><body><main>",
        "<h1>What changed this week</h1>",
        f'<p class="range">{e(range_words(start, end))}</p>',
        f'<p class="lead">{e(lead_sentence(busy))}</p>',
    ]
    for project in busy:
        prs: List[Dict[str, object]] = project["prs"]  # type: ignore[assignment]
        highlights: List[str] = project["highlights"]  # type: ignore[assignment]
        count = plural(len(prs), "change", "changes")
        parts.append(f"<section><h2>{e(str(project['label']))} <span>{e(count)}</span></h2>")
        if highlights:
            parts.append("<h3>Highlights</h3><ul>")
            parts.extend(f"<li>{e(h)}</li>" for h in highlights[:HIGHLIGHTS_MAX])
            parts.append("</ul>")
        if prs:
            parts.append("<h3>What landed</h3><ul>")
            for pr in prs:
                when = WEEKDAYS[time.localtime(float(pr["merged"])).tm_wday][:3].capitalize()  # type: ignore[arg-type]
                link = f' <a href="{e(str(pr["url"]), quote=True)}">See the change</a>' if pr["url"] else ""
                parts.append(f'<li><span class="when">{e(when)}</span>{e(str(pr["text"]))}{link}</li>')
            parts.append("</ul>")
        if project["note"]:
            parts.append(f'<p class="note">{e(str(project["note"]))}</p>')
        parts.append("</section>")
    quiet: List[str] = facts["quiet"]  # type: ignore[assignment]
    unread: List[Tuple[str, str]] = facts["unread"]  # type: ignore[assignment]
    if quiet:
        parts.append(f'<p class="quiet">Nothing landed in {e(", ".join(quiet))}.</p>')
    for label, why in unread:
        parts.append(f'<p class="quiet">{e(label)} was not read: {e(why)}.</p>')
    stamp = time.localtime(generated)
    parts.append(
        "<footer>Each line is the change's own short summary, so it can miss nuance: "
        "open a change to see all of it. "
        f"Made {e(day_words(generated, True))} at {stamp.tm_hour:02d}:{stamp.tm_min:02d}.</footer>"
    )
    parts.append("</main></body></html>\n")
    return "\n".join(parts)


# --- writing ----------------------------------------------------------------

def write_atomic(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def build(start: float, end: float) -> Optional[str]:
    facts, failed = collect(start, end)
    if failed:
        print(f"fm-weekly-changes: GitHub could not be read for any of {failed} projects; nothing written",
              file=sys.stderr)
        return None
    return render(facts, now())


def cmd_run(cfg: Dict[str, str]) -> int:
    if cfg["enabled"] != "true":
        return 0
    PAGE_DIR.mkdir(parents=True, exist_ok=True)
    with open(PAGE_DIR / "run.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        at = now()
        slot = latest_slot(cfg, at)
        hour, minute = (int(x) for x in cfg["time"].split(":"))
        page = PAGES / f"{time.strftime('%Y-%m-%d', time.localtime(slot))}.html"
        if page.exists():
            return 0
        text = build(shift_days(slot, int(cfg["days"]), hour, minute), slot)
        if text is None:
            return 1
        write_atomic(page, text)
        write_atomic(LATEST, text)
        for old in sorted(PAGES.glob("*.html"))[:-KEEP_PAGES]:
            old.unlink()
        print(f"wrote: {page}")
    return 0


def cmd_preview(cfg: Dict[str, str], args: List[str]) -> int:
    days, out = int(cfg["days"]), None
    while args:
        flag = args.pop(0)
        if flag == "--days" and args and re.fullmatch(r"[1-9]\d*", args[0]):
            days = int(args.pop(0))
        elif flag == "--out" and args:
            out = Path(args.pop(0))
        else:
            die(f"preview: unexpected argument: {flag}")
    end = now()
    start = end - days * 86400
    text = build(start, end)
    if text is None:
        return 1
    if out is None:
        sys.stdout.write(text)
    else:
        write_atomic(out, text)
        print(f"wrote: {out}")
    return 0


def cmd_status(cfg: Dict[str, str]) -> int:
    print(f"enabled: {cfg['enabled']}")
    print(f"weekday: {cfg['weekday']}")
    print(f"time: {cfg['time']}")
    print(f"days: {cfg['days']}")
    print(f"interval_seconds: {cfg['interval_seconds']}")
    print(f"latest: {LATEST if LATEST.is_file() else 'none yet'}")
    return 0


def cmd_open() -> int:
    if not LATEST.is_file():
        die("no weekly page has been written yet", 1)
    opener = os.environ.get("FM_WEEKLY_CHANGES_OPEN") or ("open" if sys.platform == "darwin" else "xdg-open")
    return subprocess.run(shlex.split(opener) + [str(LATEST)]).returncode


def main(argv: List[str]) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        sys.stderr.write(__doc__ or "")
        return 0 if argv else 2
    command, rest = argv[0], argv[1:]
    if command not in ("preview",) and rest:
        die(f"{command} takes no arguments")
    cfg = load_config()
    if command == "run":
        return cmd_run(cfg)
    if command == "preview":
        return cmd_preview(cfg, rest)
    if command == "latest":
        if not LATEST.is_file():
            die("no weekly page has been written yet", 1)
        print(LATEST)
        return 0
    if command == "open":
        return cmd_open()
    if command == "status":
        return cmd_status(cfg)
    if command == "interval":
        print(cfg["interval_seconds"])
        return 0
    die(f"unknown command: {command}")
    return 2


if __name__ == "__main__":
    for extra in (str(Path.home() / ".local" / "bin"), "/opt/homebrew/bin", "/usr/local/bin"):
        if extra not in os.environ.get("PATH", "").split(":") and os.path.isdir(extra):
            os.environ["PATH"] = os.environ.get("PATH", "") + ":" + extra
    sys.exit(main(sys.argv[1:]))
