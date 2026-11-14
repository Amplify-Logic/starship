#!/usr/bin/env python3
"""fm-factory.py - the Factory pane: one record of the owner's factories, drawn.

A factory is one segment of the owner's work: a crew with its own work list,
rules, memory and workers. data/factories.md names a home's factories and maps
each to its projects; with no registry every registered project in
data/projects.md is its own factory. docs/factory-pane.md owns what the pane
shows and why, and docs/configuration.md owns the registry format; this header
owns the commands.

Usage:
  fm-factory.py --data [--fresh]          print the record as JSON (fm-factory.v1)
  fm-factory.py --plain [--factory ID] [--width N] [--fresh]
                                          print the screen as plain text
  fm-factory.py view [--factory ID]       the live pane (Herdr runs it through
                                          bin/fm-factory-pane.sh run)
  fm-factory.py follow <task-id>          a read-only live copy of one worker's
                                          pane, for an opened factory tab
  fm-factory.py open-tab <factory-id>     open, or focus, that factory's Herdr
                                          tab: its page on the left and its live
                                          workers stacked on the right
  fm-factory.py refresh                   rebuild the cached record once

One record, two readers: every word on screen comes from the record, and every
state is a word, so an agent reading the pane as text loses nothing.

Where the record comes from. Live work, decisions and the work list come only
from bin/fm-fleet-snapshot.sh --json, and each task's state word comes from the
same fold the status bar counts with (fm_fleet_status_bucket in
bin/fm-fleet-status-lib.sh), so the pane can never disagree with the strip.
The rest are event records the home already keeps: the [at=] times on status
lines, the turn times in state/<id>.busy-state, state/<id>.turn-ended, the
optional one-line state/<id>.step a worker may write to say what it is doing,
whether a running worker's pane text changed since the last reading
(bin/fm-peek.sh), and the owner's own notes and Starship's replies
(bin/fm-inbox.sh receipts).

What the pane writes. Its cache and its own records live in state/factory/:
record.json (the cached record), activity.json (when each worker's pane last
changed), last-look (when the owner last closed the pane), steer.log (who
steers each factory), and tabs/ (the factory tabs it opened). Every writing key
goes through a path Starship already has and acts only on the highlighted row:
an answer, keep, ask-for-changes or talk becomes a captain inbox note
(bin/fm-inbox.sh note) that Starship acts on under its own rules, so the pane
merges nothing, answers no hold itself and steers no worker. Who steers is a
recorded choice that Starship is also told about; it grants nothing.

Environment:
  FM_HOME                     the home whose factories are shown (default: this
                              code root)
  HERDR_BIN_PATH              the Herdr binary (default: herdr on PATH)
  FM_FACTORY_TTL              seconds a cached record is used before a refresh
                              is started (default 20)
  FM_FACTORY_QUIET_MINUTES    minutes without a sign of life before a running
                              job reads as quiet (default 15)
Test seams:
  FM_FACTORY_SNAPSHOT         a fleet snapshot JSON file used instead of running
                              bin/fm-fleet-snapshot.sh
  FM_FACTORY_NOW              the current epoch
  FM_FACTORY_PEEK             pane reader run as `<cmd> <task-id> <lines>`
                              (default bin/fm-peek.sh); empty skips pane reads
  FM_FACTORY_INBOX            inbox command (default bin/fm-inbox.sh)
Exit: 0 on success; 1 when a step fails, with the reason on stderr; 2 on a usage
error.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import select
import shlex
import signal
import subprocess
import sys
import time
from typing import Any, Dict, List, Optional, Tuple

SCHEMA = "fm-factory.v1"
ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
BIN = os.path.join(ROOT, "bin")
STEPS = ["planning", "building", "checking", "ready for you"]
FEED_CAP = 30
LOOK_BACK_DEFAULT = 12 * 3600
LOOK_BACK_MAX = 48 * 3600
MIRROR_CAP = 4


# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------

def home_dir() -> str:
    return os.environ.get("FM_HOME") or ROOT


def now_epoch() -> int:
    raw = os.environ.get("FM_FACTORY_NOW", "")
    return int(raw) if raw.isdigit() else int(time.time())


def env_int(name: str, default: int) -> int:
    raw = os.environ.get(name, "")
    return int(raw) if raw.isdigit() else default


def pane_dir(home: str) -> str:
    return os.path.join(home, "state", "factory")


def read_text(path: str, limit: int = 1_000_000) -> str:
    try:
        with open(path, "rb") as handle:
            return handle.read(limit).decode("utf-8", errors="replace")
    except OSError:
        return ""


def mtime(path: str) -> Optional[int]:
    try:
        return int(os.stat(path).st_mtime)
    except OSError:
        return None


def write_atomic(path: str, text: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.replace(tmp, path)


def slug(text: str) -> str:
    out = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return out or "factory"


def iso(epoch: Optional[int]) -> Optional[str]:
    if epoch is None:
        return None
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


def parse_iso(text: Optional[str]) -> Optional[int]:
    if not text:
        return None
    text = text.strip()
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%MZ", "%Y-%m-%d"):
        try:
            import calendar
            return int(calendar.timegm(time.strptime(text, fmt)))
        except ValueError:
            continue
    return None


def clock(epoch: int) -> str:
    return time.strftime("%H:%M", time.localtime(epoch))


def when_words(epoch: int, now: int) -> str:
    """HH:MM today, else a short day and time."""
    if time.strftime("%Y%m%d", time.localtime(epoch)) == time.strftime("%Y%m%d", time.localtime(now)):
        return clock(epoch)
    if now - epoch < 6 * 86400:
        return time.strftime("%a %H:%M", time.localtime(epoch))
    return time.strftime("%d %b", time.localtime(epoch))


def minutes_words(minutes: int) -> str:
    minutes = max(minutes, 0)
    if minutes < 1:
        return "just now"
    if minutes < 60:
        return "%d min" % minutes
    hours, rest = divmod(minutes, 60)
    if hours >= 24:
        return "%d d" % (hours // 24)
    if hours >= 3 or rest == 0:
        return "%d h" % hours
    return "%d h %d min" % (hours, rest)


def plural(count: int, one: str, many: str) -> str:
    return "%d %s" % (count, one if count == 1 else many)


def meta_values(path: Optional[str]) -> Dict[str, str]:
    values: Dict[str, str] = {}
    for line in read_text(path or "").splitlines():
        if "=" in line:
            key, val = line.split("=", 1)
            values.setdefault(key.strip(), val)
    return values


# --------------------------------------------------------------------------
# Registries
# --------------------------------------------------------------------------

PROJECT_ROW_RE = re.compile(r"^- (.+?)(?: \[([^\]]*)\])?(?: - |$)")


def load_projects(home: str) -> List[Dict[str, Any]]:
    """data/projects.md rows: name, its label= and alias= tokens, in order."""
    rows = []
    for line in read_text(os.path.join(home, "data", "projects.md")).splitlines():
        match = PROJECT_ROW_RE.match(line)
        if not match:
            continue
        name = match.group(1).strip()
        tokens = (match.group(2) or "").split()
        label = next((t[6:] for t in tokens if t.startswith("label=") and len(t) > 6), None)
        aliases = [t[6:] for t in tokens if t.startswith("alias=") and len(t) > 6]
        rows.append({"name": name, "label": label, "aliases": aliases})
    return rows


def display_name(project: str) -> str:
    try:
        out = subprocess.run(["bash", os.path.join(BIN, "fm-project-display-name.sh"), project],
                             capture_output=True, text=True, timeout=5)
        name = out.stdout.strip()
        if out.returncode == 0 and name:
            return name
    except (OSError, subprocess.SubprocessError):
        pass
    return project


def load_registry(home: str) -> Tuple[List[Dict[str, Any]], str]:
    """data/factories.md, or one factory per registered project without it.

    Returns the factories and the word for where they came from.
    """
    text = read_text(os.path.join(home, "data", "factories.md"))
    factories: List[Dict[str, Any]] = []
    current: Optional[Dict[str, Any]] = None
    section = None
    for raw in text.splitlines():
        line = raw.rstrip()
        if line.startswith("## "):
            current = {"name": line[3:].strip(), "id": None, "about": None, "projects": [],
                       "rules": [], "learned": []}
            factories.append(current)
            section = None
            continue
        if current is None or not line.strip():
            continue
        stripped = line.strip()
        lower = stripped.lower()
        if lower in ("rules:", "learned:"):
            section = lower[:-1]
            continue
        if stripped.startswith("- ") and section:
            item = stripped[2:].strip()
            if section == "rules":
                current["rules"].append(item)
            else:
                match = re.match(r"^(\d{4}-\d{2}-\d{2})\s*(?::|-)\s*(.+)$", item)
                if match:
                    current["learned"].append({"when": match.group(1), "what": match.group(2).strip()})
                else:
                    current["learned"].append({"when": None, "what": item})
            continue
        match = re.match(r"^(id|about|projects):\s*(.*)$", stripped, re.I)
        if match:
            key, value = match.group(1).lower(), match.group(2).strip()
            section = None
            if key == "projects":
                current["projects"] = [p.strip() for p in value.split(",") if p.strip()]
            elif value:
                current[key] = value
    if factories:
        seen = set()
        for factory in factories:
            factory["id"] = slug(factory["id"] or factory["name"])
            base, count = factory["id"], 2
            while factory["id"] in seen:
                factory["id"] = "%s-%d" % (base, count)
                count += 1
            seen.add(factory["id"])
        return factories, "registry"
    for row in load_projects(home):
        factories.append({"name": row["label"] or display_name(row["name"]), "id": slug(row["name"]),
                          "about": None, "projects": [row["name"]],
                          "rules": [], "learned": []})
    return factories, "projects"


# --------------------------------------------------------------------------
# Reading the fleet
# --------------------------------------------------------------------------

def load_snapshot(home: str) -> Dict[str, Any]:
    seam = os.environ.get("FM_FACTORY_SNAPSHOT")
    if seam:
        with open(seam, encoding="utf-8") as handle:
            return json.load(handle)
    env = dict(os.environ, FM_HOME=home)
    out = subprocess.run(["bash", os.path.join(BIN, "fm-fleet-snapshot.sh"), "--json"],
                         capture_output=True, text=True, timeout=120, env=env)
    if out.returncode != 0:
        raise RuntimeError("the fleet snapshot failed: %s" % (out.stderr.strip().splitlines() or ["no reason"])[-1])
    return json.loads(out.stdout)


def buckets_for(tasks: List[Dict[str, Any]]) -> Dict[str, str]:
    """Each task's field from the status bar's own fold, in one bash call."""
    lines = []
    for task in tasks:
        raw = ((task.get("current_state") or {}).get("raw") or "").replace("\t", " ").replace("\n", " ")
        meta = (((task.get("paths") or {}).get("meta") or {}).get("path") or "")
        lines.append("%s\t%s\t%s" % (task.get("id", ""), raw, meta))
    if not lines:
        return {}
    script = (
        '. "$1/fm-fleet-status-lib.sh" || exit 1\n'
        'while IFS="$(printf "\\t")" read -r id line meta; do\n'
        '  printf "%s\\t%s\\n" "$id" "$(fm_fleet_status_bucket "$line" "$meta" 2>/dev/null)"\n'
        'done\n'
    )
    try:
        out = subprocess.run(["bash", "-c", script, "fm-factory", BIN], input="\n".join(lines) + "\n",
                             capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return {}
    result = {}
    for line in out.stdout.splitlines():
        if "\t" in line:
            key, value = line.split("\t", 1)
            result[key] = value.strip()
    return result


STATUS_RE = re.compile(r"^([a-z][a-z-]*)((?:\s*\[[^\]]*\])*)\s*:\s?(.*)$")


def status_events(path: Optional[str]) -> List[Dict[str, Any]]:
    events = []
    for line in read_text(path or "").splitlines():
        match = STATUS_RE.match(line.strip())
        if not match:
            continue
        tags = dict(re.findall(r"\[([a-z-]+)=([^\]]*)\]", match.group(2)))
        at = tags.get("at", "")
        events.append({"verb": match.group(1), "at": int(at) if at.isdigit() else None,
                       "key": tags.get("key"), "text": match.group(3)})
    return events


def busy_ts(home: str, task_id: str) -> Optional[int]:
    match = re.search(r"\bts=(\d+)", read_text(os.path.join(home, "state", "%s.busy-state" % task_id), 4096))
    return int(match.group(1)) if match else None


def stated_step(home: str, task_id: str) -> Tuple[Optional[str], Optional[int]]:
    path = os.path.join(home, "state", "%s.step" % task_id)
    text = read_text(path, 2048).strip().splitlines()
    if not text:
        return None, None
    words = re.sub(r"\s+", " ", text[0]).strip()[:140]
    return (words or None), mtime(path)


def started_at(meta: Dict[str, str]) -> Optional[int]:
    for key in ("spawn_gen", "busy_gen"):
        match = re.match(r"^[sg](\d{9,})\.", meta.get(key, ""))
        if match:
            return int(match.group(1))
    return None


def pane_activity(home: str, running_ids: List[str], now: int, write: bool) -> Dict[str, int]:
    """When each running worker's pane text last changed, as far as seen."""
    path = os.path.join(pane_dir(home), "activity.json")
    try:
        seen = json.loads(read_text(path) or "{}")
    except ValueError:
        seen = {}
    peek = os.environ.get("FM_FACTORY_PEEK")
    if peek is None:
        peek = os.path.join(BIN, "fm-peek.sh")
    result: Dict[str, int] = {}
    fresh: Dict[str, Any] = {}
    for task_id in running_ids:
        old = seen.get(task_id) or {}
        if peek:
            try:
                out = subprocess.run(shlex.split(peek) + [task_id, "15"], capture_output=True, text=True,
                                     timeout=10, env=dict(os.environ, FM_HOME=home))
                text = out.stdout if out.returncode == 0 else ""
            except (OSError, subprocess.SubprocessError):
                text = ""
            if text:
                digest = hashlib.sha256(text.encode("utf-8", "replace")).hexdigest()
                # A first sight says nothing about when the text last changed.
                changed = now if old.get("hash") and old["hash"] != digest else old.get("changed_at")
                fresh[task_id] = {"hash": digest, "changed_at": changed}
            elif old:
                fresh[task_id] = old
        elif old:
            fresh[task_id] = old
        if fresh.get(task_id, {}).get("changed_at"):
            result[task_id] = int(fresh[task_id]["changed_at"])
    if write and peek:
        try:
            write_atomic(path, json.dumps(fresh, sort_keys=True))
        except OSError:
            pass
    return result


def inbox_cmd() -> List[str]:
    seam = os.environ.get("FM_FACTORY_INBOX")
    return shlex.split(seam) if seam else ["bash", os.path.join(BIN, "fm-inbox.sh")]


def inbox_receipts(home: str) -> List[Dict[str, Any]]:
    try:
        out = subprocess.run(inbox_cmd() + ["receipts", "--all-pending", "--all-handled", "--all-replies"],
                             capture_output=True, text=True, timeout=20, env=dict(os.environ, FM_HOME=home))
        data = json.loads(out.stdout) if out.returncode == 0 and out.stdout.strip() else {}
    except (OSError, subprocess.SubprocessError, ValueError):
        return []
    notes = []
    for group in ("pending", "handled"):
        for note in data.get(group) or []:
            if (note.get("request_id") or "").startswith("factory."):
                note = dict(note)
                note["handled"] = group == "handled"
                notes.append(note)
    return notes


def steer_log(home: str) -> List[Tuple[int, str, str]]:
    rows = []
    for line in read_text(os.path.join(pane_dir(home), "steer.log")).splitlines():
        parts = line.split("\t")
        if len(parts) == 3 and parts[0].isdigit() and parts[2] in ("you", "Starship"):
            rows.append((int(parts[0]), parts[1], parts[2]))
    return rows


# --------------------------------------------------------------------------
# Plain words from prose
# --------------------------------------------------------------------------

def tidy(text: Optional[str], limit: int = 170) -> str:
    """Prose for the screen: no paths, links or run ids, one or two sentences."""
    text = text or ""
    text = re.sub(r"https?://\S+", "", text)
    text = re.sub(r"(?<![\w.])(?:~|/)[\w.@+-]*(?:/[\w.@+-]+)+/?", "", text)
    text = re.sub(r"\b(?:run|commit)\s+[0-9A-Za-z]{7,}\b", "", text)
    text = re.sub(r"\(\s*[,;]?\s*\)", "", text)
    text = re.sub(r"\(\s*[,;]\s*", "(", text)
    text = re.sub(r"\s+([,.;:])", r"\1", text)
    text = re.sub(r"\s+", " ", text).strip(" ,;:")
    if len(text) > limit:
        cut = text[:limit]
        end = max(cut.rfind(". "), cut.rfind("; "))
        text = (cut[:end + 1] if end > limit // 2 else cut.rsplit(" ", 1)[0] + "…").strip()
    return text


OPTION_SPLIT_RE = re.compile(r"\bOptions?\b\s*[:,-]?\s*", re.I)


def parse_options(text: Optional[str]) -> Tuple[str, List[Dict[str, Any]]]:
    """Split "Options: 1 x, 2 y, 3 z." (or A, B, C) out of a question's prose.

    Returns the prose without the options and the options found. Anything that
    does not read as a run of consecutive keys stays prose and yields no options.
    """
    text = text or ""
    match = OPTION_SPLIT_RE.search(text)
    if not match:
        return text, []
    head, tail = text[:match.start()], text[match.end():]
    first = re.match(r"\s*\(?([1A])[.):]?\s", tail)
    if not first:
        return text, []
    numeric = first.group(1) == "1"
    keys = [str(i) for i in range(1, 10)] if numeric else [chr(c) for c in range(ord("A"), ord("I"))]
    spots = []
    pos = 0
    for key in keys:
        pattern = re.compile(r"(?:^|[,;]\s*|\s|\()\(?%s[.):]?\s+" % re.escape(key))
        found = pattern.search(tail, pos)
        if not found:
            break
        spots.append((key, found.start(), found.end()))
        pos = found.end()
    if len(spots) < 2:
        return text, []
    options = []
    rest = ""
    for index, (key, _start, end) in enumerate(spots):
        stop = spots[index + 1][1] if index + 1 < len(spots) else len(tail)
        label = tail[end:stop]
        if index + 1 == len(spots):
            sentence = re.search(r"\.\s+(?=[A-Z])", label)
            if sentence:
                rest = label[sentence.end():]
                label = label[:sentence.start()]
        label = label.strip().strip(",;.").strip()
        suggested = bool(re.search(r"\(?\brecommended\b\)?", label, re.I))
        label = re.sub(r"\s*\(?\brecommended\b\)?", "", label, flags=re.I).strip(" ,;")
        options.append({"key": key, "label": tidy(label, 70), "suggested": suggested})
    recommend = re.search(r"\brecommend(?:ed|ation)?\b[:\s]+(?:option\s+)?\(?([1-9A-H])\b", head + " " + rest, re.I)
    if recommend and not any(o["suggested"] for o in options):
        for option in options:
            if option["key"].upper() == recommend.group(1).upper():
                option["suggested"] = True
    return (head + " " + rest).strip(), options


# --------------------------------------------------------------------------
# The record
# --------------------------------------------------------------------------

CHECK_WORDS = [
    ("ci running", "waiting for the online checks"),
    ("validating (fixing)", "fixing what the checks found"),
    ("parked at", "answering what the checks found"),
]


def checking_sentence(detail: str) -> str:
    for needle, words in CHECK_WORDS:
        if needle in detail:
            found = re.search(r"(\d+) finding", detail)
            if needle == "parked at" and found:
                return "answering the %s the checks found" % plural(int(found.group(1)), "point", "points")
            return words
    return "running the checks"


def build_record(home: str, now: int, snapshot: Dict[str, Any], since: Optional[int] = None,
                 activity: Optional[Dict[str, int]] = None, notes: Optional[List[Dict[str, Any]]] = None
                 ) -> Dict[str, Any]:
    factories, registry_source = load_registry(home)
    project_rows = load_projects(home)
    quiet_after = env_int("FM_FACTORY_QUIET_MINUTES", 15) * 60
    activity = activity or {}
    notes = notes or []
    if since is None:
        since = now - LOOK_BACK_DEFAULT
    since = max(since, now - LOOK_BACK_MAX)

    # Project name (and alias) -> factory id.
    alias_of: Dict[str, str] = {}
    for row in project_rows:
        for alias in row["aliases"]:
            alias_of[alias.lower()] = row["name"].lower()
    owner: Dict[str, str] = {}
    for factory in factories:
        for project in factory["projects"]:
            owner[project.lower()] = factory["id"]
    other = {"name": "Other work", "id": "other-work", "about": "work no factory claims", "projects": [],
             "rules": [], "learned": []}

    def factory_of(project: Optional[str]) -> str:
        key = (project or "").strip().lower()
        key = alias_of.get(key, key)
        if key in owner:
            return owner[key]
        for alias, name in alias_of.items():
            if name == key and alias in owner:
                return owner[alias]
        if other["id"] not in by_id:
            other.update(steered_by=steering.get(other["id"], "Starship"), jobs=[], needs=[], talk=[])
            factories.append(other)
            by_id[other["id"]] = other
        return other["id"]

    by_id = {f["id"]: f for f in factories}
    steering = {}
    for _at, fid, who in steer_log(home):
        steering[fid] = who
    for factory in factories:
        factory.update(steered_by=steering.get(factory["id"], "Starship"), jobs=[], needs=[], talk=[])

    rows = [r for r in (snapshot.get("backlog") or {}).get("records") or [] if r.get("structured") and r.get("id")]
    row_of = {r["id"]: r for r in rows}
    tasks = [t for t in snapshot.get("tasks") or [] if t.get("kind") != "secondmate" and t.get("id")]
    buckets = buckets_for(tasks)
    needs: List[Dict[str, Any]] = []
    feed: List[Dict[str, Any]] = []
    titles: Dict[str, str] = {}
    task_factory: Dict[str, str] = {}

    def title_of(task_id: str, meta: Optional[Dict[str, str]] = None) -> str:
        row = row_of.get(task_id)
        if row and row.get("title"):
            return row["title"]
        if meta and meta.get("outcome"):
            return meta["outcome"]
        return task_id

    def holds_up(task_id: str) -> List[str]:
        return [r.get("title") or r["id"] for r in rows
                if task_id in (r.get("unresolved_blocker_ids") or []) and r.get("state") != "done"]

    def hold_need(row: Dict[str, Any], fid: str) -> Dict[str, Any]:
        prose, options = parse_options(row.get("hold_reason"))
        since_at = parse_iso(row.get("hold_set")) or parse_iso(row.get("since"))
        held = holds_up(row["id"])
        return {"id": row["id"], "factory": fid, "kind": "question", "ask": row.get("title") or row["id"],
                "title": row.get("title") or row["id"],
                "why": tidy(prose), "options": options, "suggested_by": "Starship" if any(
                    o["suggested"] for o in options) else None,
                "holds_up": held, "since": since_at, "for": "you", "pr": None}

    # Live work: every task with metadata whose work item is not queued or done.
    running_ids = []
    for task in tasks:
        row = row_of.get(task["id"])
        if row and row.get("state") in ("queued", "done"):
            continue
        meta_path = ((task.get("paths") or {}).get("meta") or {}).get("path")
        meta = meta_values(meta_path)
        project = (row or {}).get("repo") or os.path.basename((task.get("project") or "").rstrip("/"))
        fid = factory_of(project)
        task_factory[task["id"]] = fid
        title = title_of(task["id"], meta)
        titles[task["id"]] = title
        state = task.get("current_state") or {}
        detail = state.get("detail") or ""
        bucket = buckets.get(task["id"], "")
        kind = task.get("kind") or "ship"
        job: Dict[str, Any] = {"id": task["id"], "title": title, "kind": kind, "state": None, "step": None,
                               "started": started_at(meta), "doing": None, "doing_from": None,
                               "last_sign_of_life": None, "sign_of_life_from": None, "quiet": False,
                               "until": None, "pr": (task.get("pr") or {}).get("url")}
        if bucket == "working":
            job.update(state="running", step="planning" if kind == "scout" else "building")
        elif bucket == "validating" or (state.get("state") == "parked" and state.get("source") == "run-step"
                                         and bucket != "decision"):
            job.update(state="running", step="checking", doing=checking_sentence(detail), doing_from="checks")
        elif bucket == "decision":
            job.update(state="waiting on you")
            decision = ((task.get("hints") or {}).get("open_decisions") or [{}])[0]
            asked = [e["at"] for e in status_events(((task.get("paths") or {}).get("status_log") or {}).get("path"))
                     if e["verb"] == "needs-decision" and e["key"] == decision.get("key") and e["at"]]
            prose, options = parse_options(decision.get("summary") or detail)
            needs.append({"id": task["id"], "factory": fid, "kind": "question",
                          "ask": "%s: a question for you" % title, "title": title, "why": tidy(prose),
                          "options": options,
                          "suggested_by": "the crew" if any(o["suggested"] for o in options) else None,
                          "holds_up": holds_up(task["id"]), "since": asked[-1] if asked else None, "for": "you",
                          "pr": None,
                          "key": decision.get("key")})
        elif bucket == "ready":
            job.update(state="ready for you", step="ready for you")
            pr = job["pr"]
            found = re.search(r"pr=(https?://\S+)", detail)
            if found:
                pr = found.group(1)
            done_at = [e["at"] for e in status_events(((task.get("paths") or {}).get("status_log") or {}).get("path"))
                       if e["verb"] == "done" and e["at"]]
            needs.append({"id": task["id"], "factory": fid, "kind": "finished work",
                          "ask": "%s is ready for you to look at" % title, "title": title, "why": None,
                          "options": [],
                          "suggested_by": None, "holds_up": [], "since": done_at[-1] if done_at else None,
                          "for": "you", "pr": pr})
        elif bucket == "finished":
            job.update(state="finished" if "PR merged" in detail else "with Starship")
        elif bucket == "paused":
            job.update(state="waiting")
            found = re.search(r"\buntil (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}Z)", detail)
            job["until"] = parse_iso(found.group(1)) if found else None
        elif bucket == "attention":
            job.update(state="stuck")
        elif "gone" in detail or "dead" in detail:
            job.update(state="stopped")
        else:
            job.update(state="no reading")
        if row and row.get("captain_actionable"):
            if not any(n["id"] == row["id"] for n in needs):
                needs.append(hold_need(row, fid))
            else:
                needs[:] = [hold_need(row, fid) if n["id"] == row["id"] else n for n in needs]
            if job["state"] in ("stopped", "no reading", "with Starship"):
                job["state"] = "waiting on you"
        if job["state"] == "running":
            running_ids.append(task["id"])
        by_id[fid]["jobs"].append(job)

    activity = dict(activity)
    seen_pane = activity
    for factory in factories:
        for job in factory["jobs"]:
            if job["state"] != "running":
                continue
            task = next(t for t in tasks if t["id"] == job["id"])
            status_path = ((task.get("paths") or {}).get("status_log") or {}).get("path")
            step_words, step_at = stated_step(home, job["id"])
            signs = [
                (busy_ts(home, job["id"]), "a turn"),
                (mtime(os.path.join(home, "state", "%s.turn-ended" % job["id"])), "a finished turn"),
                (mtime(status_path) if status_path else None, "a status line"),
                (step_at, "a stated step"),
                (seen_pane.get(job["id"]), "pane activity"),
            ]
            signs = [(at, word) for at, word in signs if at]
            if signs:
                at, word = max(signs)
                job["last_sign_of_life"], job["sign_of_life_from"] = min(at, now), word
            if step_words and (not job["started"] or (step_at or 0) >= job["started"]):
                job["doing"], job["doing_from"] = step_words, "the worker"
            if not job["doing"]:
                job["doing"], job["doing_from"] = "at work, no step reported yet", None
            if job["step"] != "checking" and job["last_sign_of_life"] and now - job["last_sign_of_life"] >= quiet_after:
                job["quiet"] = True

    # Queued work and held work items with no live worker.
    for row in rows:
        if row["id"] in task_factory or row.get("state") == "done":
            continue
        fid = factory_of(row.get("repo"))
        title = row.get("title") or row["id"]
        titles[row["id"]] = title
        task_factory.setdefault(row["id"], fid)
        job = {"id": row["id"], "title": title, "kind": row.get("kind") or "task", "state": None, "step": None,
               "started": None, "doing": None, "doing_from": None, "last_sign_of_life": None,
               "sign_of_life_from": None, "quiet": False, "until": None, "pr": row.get("pr_url")}
        if row.get("captain_actionable"):
            job["state"] = "waiting on you"
            needs.append(hold_need(row, fid))
        elif row.get("hold_kind"):
            bucket = row.get("hold_bucket")
            if bucket == "dated" and row.get("hold_until"):
                job["state"] = "on hold until %s" % row["hold_until"]
            elif bucket == "blocked" or row.get("unresolved_blocker_ids"):
                job["state"] = "waits on other work"
            else:
                job["state"] = "on hold"
        elif row.get("unresolved_blocker_ids"):
            job["state"] = "waits on other work"
        elif row.get("state") == "in_flight":
            job["state"] = "no worker"
        else:
            job["state"] = "queued"
        by_id[fid]["jobs"].append(job)

    # In line: the first queued item is next, the rest later.
    for factory in factories:
        queued = [j for j in factory["jobs"] if j["state"] == "queued"]
        for index, job in enumerate(queued):
            job["state"] = "next" if index == 0 else "later"
        order = {"running": 0, "waiting on you": 1, "ready for you": 2, "stuck": 3, "waiting": 4,
                 "stopped": 5, "no worker": 5, "no reading": 5, "with Starship": 6, "finished": 6, "next": 7,
                 "later": 8}
        factory["jobs"].sort(key=lambda j: order.get(j["state"], 9))
        lined = [j for j in factory["jobs"] if j["state"] in ("next", "later", "waiting on you")
                 and not any(n["id"] == j["id"] and n["kind"] == "finished work" for n in needs)]
        lined = [j for j in lined if j["state"] != "waiting on you" or j["started"] is None]
        factory["next"] = None
        if lined:
            first = next((j for j in lined if j["state"] == "next"), lined[0])
            factory["next"] = {"id": first["id"], "title": first["title"],
                               "once_you_answer": first["state"] == "waiting on you",
                               "then": len(lined) - 1}

    # Since you last looked: status events, completions, the owner's own notes.
    for task in snapshot.get("tasks") or []:
        task_id = task.get("id")
        if not task_id or task.get("kind") == "secondmate":
            continue
        fid = task_factory.get(task_id)
        if not fid:
            row = row_of.get(task_id)
            fid = factory_of((row or {}).get("repo") or os.path.basename((task.get("project") or "").rstrip("/")))
        title = titles.get(task_id) or title_of(task_id, meta_values(
            ((task.get("paths") or {}).get("meta") or {}).get("path")))
        events = status_events(((task.get("paths") or {}).get("status_log") or {}).get("path"))
        last_verb = None
        for event in events:
            verb, at = event["verb"], event["at"]
            word = text = None
            if verb == "done":
                word, text = "finished", "%s is finished." % title
            elif verb == "needs-decision":
                word, text = "asked you", "%s has a question for you." % title
            elif verb in ("blocked", "failed"):
                word, text = "stuck", "%s is stuck; Starship is on it." % title
            elif verb == "paused":
                found = re.search(r"\buntil (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}Z)", event["text"])
                again = parse_iso(found.group(1)) if found else None
                if again:
                    word = "waiting · tries again %s" % clock(again)
                    text = "%s is waiting and tries again at %s." % (title, clock(again))
            elif verb == "resolved" and last_verb in ("blocked", "failed"):
                word, text = "fixed itself", "%s is moving again." % title
            if verb != "note":
                last_verb = verb
            if word and at and since <= at <= now:
                feed.append({"at": at, "date": None, "actor": by_id[fid]["name"], "factory": fid, "job": task_id,
                             "word": word, "text": text})
    done_in_feed = {e["job"] for e in feed if e["word"] == "finished"}
    since_day = time.strftime("%Y-%m-%d", time.localtime(since))
    for row in rows:
        completion = row.get("completion") or {}
        date = completion.get("date")
        if row.get("state") != "done" or not date or date < since_day or row["id"] in done_in_feed:
            continue
        fid = factory_of(row.get("repo"))
        merged = completion.get("verb") == "merged"
        feed.append({"at": None, "date": date, "actor": by_id[fid]["name"], "factory": fid, "job": row["id"],
                     "word": "landed" if merged else "finished",
                     "text": "%s is %s." % (row.get("title") or row["id"], "in" if merged else "done")})
    for at, fid, who in steer_log(home):
        if fid in by_id and since <= at <= now:
            feed.append({"at": at, "date": None, "actor": "you", "factory": fid, "job": None,
                         "word": "took the helm" if who == "you" else "handed back",
                         "text": ("You steer %s now." if who == "you" else "Starship steers %s again.")
                         % by_id[fid]["name"]})
    note_words = {"answer": "answered", "keep": "asked to keep", "change": "asked for changes", "talk": "said"}
    for note in notes:
        parts = (note.get("request_id") or "").split(".")
        if len(parts) < 3 or parts[1] not in by_id:
            continue
        fid, kind = parts[1], parts[2]
        if kind == "steer":
            continue  # the steer log carries it, once
        at = parse_iso(note.get("at"))
        first = (note.get("body") or "").strip().splitlines()[:1]
        said = re.sub(r"^[^:]{0,80}:\s*", "", first[0]) if first else ""
        by_id[fid]["talk"].append({"at": at, "who": "you", "said": said})
        reply = note.get("reply") or {}
        if reply.get("body"):
            by_id[fid]["talk"].append({"at": parse_iso(reply.get("at")), "who": "Starship",
                                       "said": tidy(reply["body"], 200)})
        if at and since <= at <= now:
            feed.append({"at": at, "date": None, "actor": "you", "factory": fid, "job": None,
                         "word": note_words.get(kind, "said"), "text": tidy(first[0] if first else "", 120)})
        reply_at = parse_iso(reply.get("at"))
        if reply.get("body") and reply_at and since <= reply_at <= now:
            feed.append({"at": reply_at, "date": None, "actor": "Starship", "factory": fid, "job": None,
                         "word": "replied", "text": tidy(reply["body"], 120)})
    for factory in factories:
        factory["talk"] = sorted(factory["talk"], key=lambda t: t["at"] or 0)[-6:]
    feed.sort(key=lambda e: (e["at"] if e["at"] is not None else (parse_iso(e["date"]) or 0)), reverse=True)
    feed = feed[:FEED_CAP]

    # Questions first, then finished work; a worker waiting before a held item; newest first.
    live_ids = {j["id"] for f in factories for j in f["jobs"] if j["started"]}
    needs.sort(key=lambda n: (0 if n["kind"] == "question" else 1, 0 if n["id"] in live_ids else 1,
                              -(n["since"] or 0)))
    for factory in factories:
        factory["needs"] = [n["id"] for n in needs if n["factory"] == factory["id"]]
        running = [j for j in factory["jobs"] if j["state"] == "running"]
        if factory["needs"]:
            factory["state"] = "needs you"
        elif running:
            factory["state"] = "at work"
        else:
            factory["state"] = "idle"
        idle_marks = [e["at"] for e in feed if e["factory"] == factory["id"] and e["at"]]
        factory["idle_since"] = max(idle_marks) if factory["state"] == "idle" and idle_marks else None
        factory["crew"] = {"workers": len([j for j in factory["jobs"] if j["started"]]), "busy": len(running)}

    if other in factories and not other["jobs"] and not other["needs"]:
        factories.remove(other)
    running_total = sum(1 for f in factories for j in f["jobs"] if j["state"] == "running")
    idle_total = sum(1 for f in factories if f["state"] == "idle")
    count_line = "%s running · %s · %s" % (
        plural(running_total, "job", "jobs"),
        "1 needs you" if len(needs) == 1 else "%d need you" % len(needs),
        "%d idle" % idle_total)
    return {
        "schema": SCHEMA,
        "as_of": iso(now),
        "as_of_epoch": now,
        "since": iso(since),
        "since_epoch": since,
        "home": home,
        "factories_from": registry_source,
        "counts": {"running": running_total, "need_you": len(needs), "idle": idle_total},
        "count_line": count_line,
        "needs_you": needs,
        "factories": [{k: f[k] for k in ("id", "name", "about", "projects", "steered_by", "state",
                                         "idle_since", "crew", "needs", "jobs", "next", "rules", "learned", "talk")}
                      for f in factories],
        "feed": feed,
        "snapshot": {"generated": snapshot.get("generated"), "schema": snapshot.get("schema")},
    }


# --------------------------------------------------------------------------
# The cached record
# --------------------------------------------------------------------------

def last_look(home: str) -> Optional[int]:
    text = read_text(os.path.join(pane_dir(home), "last-look"), 64).strip()
    return int(text) if text.isdigit() else None


def refresh(home: str) -> Dict[str, Any]:
    now = now_epoch()
    snapshot = load_snapshot(home)
    running = [t["id"] for t in snapshot.get("tasks") or []
               if (t.get("current_state") or {}).get("state") == "working"
               and (t.get("current_state") or {}).get("source") == "pane"]
    activity = pane_activity(home, running, now, write=True)
    record = build_record(home, now, snapshot, since=last_look(home), activity=activity,
                          notes=inbox_receipts(home))
    try:
        write_atomic(os.path.join(pane_dir(home), "record.json"), json.dumps(record, indent=1))
    except OSError:
        pass
    return record


def cached(home: str) -> Optional[Dict[str, Any]]:
    try:
        record = json.loads(read_text(os.path.join(pane_dir(home), "record.json")) or "null")
    except ValueError:
        return None
    if isinstance(record, dict) and record.get("schema") == SCHEMA:
        return record
    return None


def refresh_in_background(home: str) -> None:
    """Start one detached refresh unless one is already under way."""
    lock = os.path.join(pane_dir(home), "refresh.lock")
    try:
        os.makedirs(pane_dir(home), exist_ok=True)
        age = time.time() - os.stat(lock).st_mtime if os.path.exists(lock) else None
        if age is not None and age < 180:
            return
        if age is not None:
            os.rmdir(lock)
        os.mkdir(lock)
    except OSError:
        return
    script = os.path.realpath(__file__)
    subprocess.Popen(["/bin/sh", "-c", 'python3 "$1" refresh >/dev/null 2>&1; rmdir "$2" 2>/dev/null',
                      "fm-factory", script, lock],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True, env=dict(os.environ, FM_HOME=home))


def current_record(home: str, fresh: bool) -> Dict[str, Any]:
    if not fresh:
        record = cached(home)
        if record and now_epoch() - int(record.get("as_of_epoch") or 0) <= env_int("FM_FACTORY_TTL", 20):
            return record
    return refresh(home)


# --------------------------------------------------------------------------
# Drawing
# --------------------------------------------------------------------------

PALETTE = {
    "ice": (232, 238, 247),
    "mist": (163, 180, 203),
    "faint": (107, 127, 156),
    "cyan": (116, 215, 234),
    "amber": (255, 182, 72),
    "ember": (150, 110, 58),
    "green": (98, 221, 154),
    "red": (255, 122, 107),
}
BAND = (38, 53, 78)
HULL = (13, 21, 36)


class Row(list):
    band = False
    hull = False


def S(text: Any, colour: str = "ice", bold: bool = False) -> Tuple[str, str, bool]:
    return (str(text), colour, bold)


def seg_len(segs) -> int:
    return sum(len(t) for t, _, _ in segs)


def clip(segs, width: int):
    if seg_len(segs) <= width:
        return list(segs)
    out, room = [], max(width - 1, 0)
    for text, colour, bold in segs:
        if room <= 0:
            break
        out.append((text[:room], colour, bold))
        room -= len(text[:room])
    out.append(("…", "faint", False))
    return out


def row(width: int, left=(), right=(), band: bool = False) -> Row:
    right = list(right)
    if right and seg_len(right) + 16 > width:
        right = []
    left = clip(list(left), width - seg_len(right) - (2 if right else 0))
    gap = width - seg_len(left) - seg_len(right) - (1 if right else 0)
    out = Row(left + [(" " * max(gap, 0), "ice", False)] + right + ([(" ", "ice", False)] if right else []))
    out.band = band
    return out


def wrap(text: str, width: int) -> List[str]:
    lines, line = [], ""
    for word in (text or "").split():
        if line and len(line) + 1 + len(word) > width:
            lines.append(line)
            line = word
        else:
            line = (line + " " + word).strip()
    if line:
        lines.append(line)
    return lines or [""]


STATE_COLOUR = {"running": "amber", "waiting on you": "red", "ready for you": "green", "stuck": "amber",
                "waiting": "amber", "stopped": "faint", "no worker": "faint", "no reading": "faint",
                "with Starship": "mist", "finished": "green", "next": "mist", "later": "faint"}
FEED_COLOUR = {"finished": "green", "landed": "green", "asked you": "red", "stuck": "amber",
               "fixed itself": "mist", "took the helm": "cyan", "handed back": "cyan", "replied": "cyan",
               "answered": "cyan", "asked to keep": "cyan", "asked for changes": "cyan", "said": "cyan"}


def asking(need: Dict[str, Any]) -> str:
    """Which asking of a need this is: its decision key and when it was asked, held or became ready."""
    return ".".join(str(part) for part in (need.get("key"), need.get("since")) if part) or "0"


class View:
    """Draws a record; holds the cursor, the talk box and pending notices."""

    def __init__(self, record: Dict[str, Any], opened: Optional[str] = None, in_tab: bool = False):
        self.opened = opened
        self.in_tab = in_tab
        self.cursor = 0
        self.selected: Optional[Tuple[str, str]] = None
        self.tick = 0
        self.talking: Optional[Dict[str, Any]] = None
        self.confirm: Optional[Dict[str, Any]] = None
        self.notice: Optional[Tuple[str, str, float]] = None
        self.adopt(record)

    def adopt(self, record: Dict[str, Any]) -> None:
        """Take a new record; whatever pointed at something it no longer holds lets go of it."""
        self.record = record
        if self.opened and not self.has_factory(self.opened):
            self.opened = None
        talk = self.talking
        if talk is not None and not (self.has_factory(talk["factory"]) and (
                "item" not in talk or self.need(talk["item"]))):
            talk["gone"] = True
        confirm = self.confirm
        if confirm is not None:
            need = self.need(confirm["item"])
            if need is None or asking(need) != confirm["asked"]:
                self.confirm = None

    # ---- record lookups ----------------------------------------------------

    def now(self) -> int:
        return now_epoch()

    def factory(self, fid: str) -> Dict[str, Any]:
        return next(f for f in self.record["factories"] if f["id"] == fid)

    def has_factory(self, fid: Optional[str]) -> bool:
        return any(f["id"] == fid for f in self.record["factories"])

    def needs(self, fid: Optional[str] = None) -> List[Dict[str, Any]]:
        return [n for n in self.record["needs_you"] if fid in (None, n["factory"])]

    def need(self, ident: str) -> Optional[Dict[str, Any]]:
        return next((n for n in self.record["needs_you"] if n["id"] == ident), None)

    def stops(self) -> List[Tuple[str, str]]:
        if self.opened:
            return [("need", n["id"]) for n in self.needs(self.opened)] or [("factory", self.opened)]
        return [("need", n["id"]) for n in self.needs()] + [("factory", f["id"]) for f in self.ordered()]

    def at(self) -> Tuple[str, str]:
        stops = self.stops()
        if not stops:
            return ("none", "")
        if self.selected in stops:
            self.cursor = stops.index(self.selected)
        self.cursor = max(0, min(self.cursor, len(stops) - 1))
        self.selected = stops[self.cursor]
        return self.selected

    def move(self, step: int) -> None:
        self.at()
        self.cursor += step
        self.selected = None

    def show(self, fid: Optional[str]) -> None:
        self.opened, self.cursor, self.selected = fid, 0, None

    def here(self, kind: str, ident: str) -> bool:
        return self.at() == (kind, ident)

    def mark(self, kind: str, ident: str):
        return S("▸ ", "cyan", True) if self.here(kind, ident) else S("  ")

    def ordered(self) -> List[Dict[str, Any]]:
        factories = self.record["factories"]
        return [f for f in factories if f["state"] != "idle"] + [f for f in factories if f["state"] == "idle"]

    # ---- pieces --------------------------------------------------------------

    def count_line(self, width: int) -> List[Row]:
        counts = self.record["counts"]
        needs = counts["need_you"]
        summary = [S(plural(counts["running"], "job", "jobs") + " running", "amber" if counts["running"] else "faint"),
                   S("  ·  ", "faint"),
                   S("1 needs you" if needs == 1 else "%d need you" % needs, "red" if needs else "faint"),
                   S("  ·  ", "faint"), S("%d idle" % counts["idle"], "faint")]
        head = [S(" S T A R S H I P ", "cyan", True), S(" │  ", "faint")] + summary
        if seg_len(head) + 10 > width:
            head = [S(" STARSHIP ", "cyan", True), S(" │  ", "faint")] + summary
        line = row(width, head, [S(time.strftime("%a %H:%M", time.localtime(self.now())), "mist")])
        line.hull = True
        return [line]

    def need_rows(self, width: int, need: Dict[str, Any], full: bool) -> List[Row]:
        now = self.now()
        fac = self.factory(need["factory"])
        question = need["kind"] == "question"
        waited = ("waiting " if question else "ready ") + minutes_words((now - need["since"]) // 60) \
            if need.get("since") else ("waiting" if question else "ready")
        right = [S(waited, "mist")] if full else [S(fac["name"], "mist"), S(" · ", "faint"), S(waited, "mist")]
        band = self.here("need", need["id"])
        left = [S(" "), self.mark("need", need["id"]), S("● ", "red" if question else "green"),
                S(need["ask"], "ice", True)]
        pad = S("       ")
        if seg_len(left) + seg_len(right) + 3 <= width:
            rows = [row(width, left, right, band=band)]
        else:
            rows = [row(width, left, band=band), row(width, [pad] + right)]
        if question:
            if need.get("why"):
                for line in wrap(need["why"], max(width - 9, 20))[:3 if full else 2]:
                    rows.append(row(width, [pad, S(line, "mist")]))
            for option in need["options"]:
                note = ""
                if option["suggested"]:
                    note = "  · %s suggests this" % (need.get("suggested_by") or "Starship")
                rows.append(row(width, [pad, S(option["key"], "cyan", True), S("  "), S(option["label"], "ice"),
                                        S(note, "mist")]))
            rows.append(row(width, [pad, S("t", "cyan", True), S("  "), S("Talk it through", "ice")]))
            if need.get("holds_up"):
                rows.append(row(width, [pad, S("holds up ", "faint"), S(", ".join(need["holds_up"][:3]), "mist")]))
        else:
            hint = "k  keep it    c  ask for changes" if full or band else "enter shows its factory"
            if need.get("pr") and full:
                rows.append(row(width, [pad, S("the change ", "faint"), S(need["pr"], "mist")]))
            rows.append(row(width, [pad, S(hint, "faint")]))
        return rows

    def track(self, job: Dict[str, Any]):
        current = STEPS.index(job["step"]) if job.get("step") in STEPS else 1
        lit = self.tick % 5
        segs = []
        for index, step in enumerate(STEPS):
            if index < current:
                segs += [S("✓ ", "mist"), S(step, "mist")]
            elif index == current:
                segs += [S("▸ ", "amber", True), S(step, "amber", True)]
            else:
                segs += [S("  "), S(step, "faint")]
            if index == len(STEPS) - 1:
                break
            segs.append(S(" "))
            if index < current:
                segs.append(S("•••••", "mist"))
            elif index > current:
                segs.append(S("·····", "faint"))
            elif job.get("quiet"):
                segs.append(S("•••••", "ember"))
            else:
                segs += [S("•" * lit, "ember"), S("•", "amber", True), S("•" * (4 - lit), "ember")]
            segs.append(S(" "))
        return segs

    def job_rows(self, width: int, job: Dict[str, Any], full: bool) -> List[Row]:
        now = self.now()
        state = job["state"]
        if state == "running":
            elapsed = [S(minutes_words((now - job["started"]) // 60), "mist")] if job.get("started") else []
            if job.get("quiet") and job.get("last_sign_of_life"):
                doing = S("quiet for %d min, no sign of life" % ((now - job["last_sign_of_life"]) // 60), "amber")
            else:
                doing = S(job.get("doing") or "at work", "mist")
            return [row(width, [S("     "), S("● ", "amber"), S(job["title"], "ice")], elapsed),
                    row(width, [S("       ")] + self.track(job)),
                    row(width, [S("       "), doing])]
        colour = STATE_COLOUR.get(state, "faint")
        words = state
        if state == "waiting" and job.get("until"):
            words = "waiting · tries again %s" % clock(job["until"])
        if state == "waiting on you":
            words = "waiting on your answer"
        if state == "ready for you":
            words = "ready for you to look at"
        dot = "● " if state in ("waiting on you", "ready for you", "stuck", "waiting") else "· "
        return [row(width, [S("     "), S(dot, colour), S(job["title"], "ice" if full else "mist")],
                    [S(words, colour)])]

    def steer(self, fac: Dict[str, Any]):
        if fac["steered_by"] == "you":
            return [S("you steer", "cyan")]
        return [S("Starship steers", "faint")]

    def idle_words(self, fac: Dict[str, Any]) -> str:
        now = self.now()
        line = [j for j in fac["jobs"] if j["state"] in ("next", "later")]
        since = "idle since %s" % when_words(fac["idle_since"], now) if fac.get("idle_since") else "idle"
        return "%s · %s" % (since, "%d in line" % len(line) if line else "nothing in line")

    def factory_rows(self, width: int, fac: Dict[str, Any]) -> List[Row]:
        band = self.here("factory", fac["id"])
        head = [S(" "), self.mark("factory", fac["id"]), S(fac["name"], "ice", True)]
        if fac["state"] == "idle":
            return [row(width, head + [S("   " + self.idle_words(fac), "faint")], self.steer(fac), band=band)]
        rows = [row(width, head, self.steer(fac), band=band)]
        for job in fac["jobs"]:
            if job["state"] in ("running", "stuck", "waiting", "stopped", "no worker") or (
                    job["started"] and job["state"] in ("waiting on you", "ready for you")):
                rows += self.job_rows(width, job, full=False)
        nxt = fac.get("next")
        if nxt:
            text = [S("       next  ", "faint"), S(nxt["title"], "mist")]
            if nxt["once_you_answer"]:
                text.append(S(", once you answer", "faint"))
            if nxt["then"]:
                text.append(S(" · then %d more" % nxt["then"], "faint"))
            rows.append(row(width, text))
        return rows

    def feed_rows(self, width: int, fid: Optional[str] = None, cap: int = 12) -> List[Row]:
        now = self.now()
        events = [e for e in self.record["feed"] if fid in (None, e["factory"])][:cap]
        since = self.record.get("since_epoch")
        title = "SINCE YOU LAST LOOKED"
        rows = [row(width, [S(" " + title, "mist", True)]
                    + ([S("   since %s" % when_words(since, now), "faint")] if since else [])), row(width)]
        if not events:
            return rows + [row(width, [S("     nothing new", "faint")])]
        names = max(len(e["actor"]) for e in events) if not fid else 0
        words = max(len(e["word"]) for e in events)
        for event in reversed(events):
            if event["at"]:
                stamp = when_words(event["at"], now)
            elif event["date"] == time.strftime("%Y-%m-%d", time.localtime(now)):
                stamp = "today"
            else:
                stamp = time.strftime("%d %b", time.gmtime(parse_iso(event["date"]) or now))
            left = [S("   "), S(stamp.ljust(9), "faint")]
            if not fid:
                left.append(S(event["actor"].ljust(names + 2), "mist"))
            left.append(S(event["word"].ljust(words + 2), FEED_COLOUR.get(event["word"].split(" ·")[0], "amber")))
            used = seg_len(left)
            lines = wrap(event["text"], max(width - used - 1, 20))
            rows.append(row(width, left + [S(lines[0], "ice")]))
            for extra in lines[1:2]:
                rows.append(row(width, [S(" " * used), S(extra, "ice")]))
        return rows

    def notice_rows(self, width: int) -> List[Row]:
        if self.confirm:
            return [row(width, [S(" "), S(self.confirm["prompt"], "cyan", True)]),
                    row(width, [S("   enter sends · esc cancels", "faint")]), row(width)]
        if not self.notice:
            return []
        return [row(width, [S(" "), S(self.notice[0], self.notice[1], True)]), row(width)]

    def footer(self, width: int) -> List[Row]:
        talk = self.talking
        if talk is not None:
            left = [S(" %s ▸ " % talk["label"], "cyan", True), S(talk["text"], "ice"), S("_", "cyan")]
            if talk.get("gone"):
                return [row(width, left),
                        row(width, [S(" This was settled elsewhere, so nothing will be sent · esc close", "amber")])]
            return [row(width, left), row(width, [S(" enter send · esc close · Starship hears this too", "faint")])]
        kind, ident = self.at()
        keys = ["↑↓ move"]
        if kind == "need":
            need = self.need(ident)
            if need["kind"] == "question" and need["options"]:
                keys.append("%s answer" % "/".join(o["key"] for o in need["options"]))
            elif need["kind"] != "question":
                keys.append("k keep · c changes")
        if not self.opened or not self.in_tab:
            keys.append("enter open" if not self.opened else "esc back")
        elif self.in_tab:
            keys.append("esc back")
        keys += ["t talk", "s who steers", "q quit"]
        return [row(width, [S(" " + " · ".join(keys), "faint")])]

    # ---- the two screens -----------------------------------------------------

    def overview(self, width: int) -> List[Row]:
        rows = self.count_line(width) + [row(width)]
        rows += self.notice_rows(width)
        needs = self.needs()
        if needs:
            rows += [row(width, [S(" NEEDS YOU", "red", True)]), row(width)]
            # The first two and the highlighted one open as cards; the rest
            # stay one line each, so a long list still leaves room for the floor.
            for index, need in enumerate(needs):
                if index < 2 or self.here("need", need["id"]):
                    rows += self.need_rows(width, need, full=False) + [row(width)]
                else:
                    rows += self.need_rows(width, need, full=False)[:1]
            if len(needs) > 2:
                rows.append(row(width))
        else:
            rows += [row(width, [S(" NOTHING NEEDS YOU", "green", True)]), row(width)]
        rows += [row(width, [S(" RIGHT NOW", "mist", True)]), row(width)]
        idle_started = False
        for fac in self.ordered():
            if fac["state"] == "idle" and not idle_started:
                idle_started = True
            rows += self.factory_rows(width, fac)
            if fac["state"] != "idle":
                rows.append(row(width))
        if idle_started:
            rows.append(row(width))
        rows += self.feed_rows(width)
        return rows

    def factory_page(self, width: int) -> List[Row]:
        fac = self.factory(self.opened)
        rows = self.count_line(width) + [row(width)]
        about = fac.get("about") or ", ".join(fac["projects"]) or ""
        crew = fac["crew"]
        rows += [row(width, [S(" "), S("  " if fac["needs"] else "▸ ", "cyan", True), S(fac["name"], "ice", True)],
                     self.steer(fac), band=not fac["needs"]),
                 row(width, [S("   " + " · ".join(x for x in (about, "%s, %d busy" % (
                     plural(crew["workers"], "worker", "workers"), crew["busy"])) if x), "faint")]),
                 row(width)]
        rows += self.notice_rows(width)
        needs = self.needs(fac["id"])
        if needs:
            rows += [row(width, [S(" NEEDS YOU", "red", True)]), row(width)]
            for need in needs:
                rows += self.need_rows(width, need, full=True) + [row(width)]
        rows += [row(width, [S(" WORK, IN ORDER", "mist", True)]), row(width)]
        if not fac["jobs"]:
            rows.append(row(width, [S("     Nothing in line.", "faint")]))
        # Everything moving or waiting on you, then the head of the line; the
        # long tail of the work list folds into two counts.
        shown_line = 0
        folded = {"in line": 0, "on hold": 0}
        for job in fac["jobs"]:
            if job["state"] == "finished":
                continue
            if job["state"] in ("next", "later"):
                shown_line += 1
                if shown_line > 8:
                    folded["in line"] += 1
                    continue
            elif job["state"].startswith("on hold") or job["state"] == "waits on other work":
                folded["on hold"] += 1
                continue
            rows += self.job_rows(width, job, full=True)
        tail = [plural(count, "more " + word if word == "in line" else word, "more " + word
                       if word == "in line" else word) for word, count in folded.items() if count]
        if tail:
            rows.append(row(width, [S("     · " + " · ".join(tail), "faint")]))
        rows += [row(width), row(width, [S(" RULES THIS CREW FOLLOWS", "mist", True)]), row(width)]
        if not fac["rules"]:
            rows.append(row(width, [S("     none written down yet", "faint")]))
        for rule in fac["rules"]:
            for index, line in enumerate(wrap(rule, max(width - 8, 20))):
                rows.append(row(width, [S("     " if index else "   · ", "faint"), S(line, "mist")]))
        rows += [row(width), row(width, [S(" WHAT IT HAS LEARNED LATELY", "mist", True)]), row(width)]
        if not fac["learned"]:
            rows.append(row(width, [S("     nothing recorded yet", "faint")]))
        for item in fac["learned"][-5:]:
            stamp = ""
            if item.get("when"):
                stamp = time.strftime("%d %b", time.gmtime(parse_iso(item["when"]) or 0))
            rows.append(row(width, [S("   "), S(stamp.ljust(8), "faint"), S(item["what"], "mist")]))
        rows += [row(width)] + self.feed_rows(width, fac["id"], cap=8)
        rows += [row(width), row(width, [S(" TALK", "mist", True)]), row(width)]
        if not fac["talk"]:
            rows.append(row(width, [S("     Nothing said here yet. Press t to talk to this crew.", "faint")]))
        for line in fac["talk"]:
            you = line["who"] == "you"
            stamp = when_words(line["at"], self.now()) if line.get("at") else ""
            rows.append(row(width, [S("   "), S(stamp.ljust(9), "faint"),
                                    S(("you" if you else line["who"]).ljust(10), "cyan" if you else "mist"),
                                    S(line["said"], "ice" if you else "mist")]))
        return rows

    def frame(self, width: int, height: Optional[int] = None) -> List[Row]:
        width = max(width, 40)
        body = self.factory_page(width) if self.opened else self.overview(width)
        foot = self.footer(width)
        if height:
            body = body[:max(height - len(foot) - 1, 1)]
            body += [row(width)] * max(height - len(foot) - len(body), 0)
        else:
            body.append(row(width))
        return body + foot


def plain(view: View, width: int) -> str:
    return "\n".join("".join(t for t, _, _ in segs).rstrip() for segs in view.frame(width))


def paint(segs: Row) -> str:
    background = BAND if getattr(segs, "band", False) else (HULL if getattr(segs, "hull", False) else None)
    back = "48;2;%d;%d;%d;" % background if background else "49;"
    out = []
    for text, colour, bold in segs:
        red, green, blue = PALETTE[colour]
        out.append("\x1b[%s%s38;2;%d;%d;%dm%s" % ("1;" if bold else "22;", back, red, green, blue, text))
    return "".join(out) + "\x1b[0m"


# --------------------------------------------------------------------------
# Writing keys: every one goes through an existing Starship path
# --------------------------------------------------------------------------

def send_note(home: str, request_id: str, body: str) -> Tuple[bool, str]:
    """A captain inbox note: the existing path for the owner to tell Starship."""
    request_id = re.sub(r"[^A-Za-z0-9._:-]", "-", request_id)[:128]
    try:
        out = subprocess.run(inbox_cmd() + ["note", "--request-id", request_id, "--json", "-"], input=body,
                             capture_output=True, text=True, timeout=30, env=dict(os.environ, FM_HOME=home))
    except (OSError, subprocess.SubprocessError) as error:
        return False, str(error)
    if out.returncode in (0, 3):
        return True, ""
    return False, (out.stderr.strip().splitlines() or ["the inbox refused it"])[-1]


def record_steer(home: str, fid: str, who: str, now: int) -> None:
    path = os.path.join(pane_dir(home), "steer.log")
    os.makedirs(pane_dir(home), exist_ok=True)
    with open(path, "a", encoding="utf-8") as handle:
        handle.write("%d\t%s\t%s\n" % (now, fid, who))


class Pane:
    """The live pane: a View plus the keys, the cache and Herdr."""

    def __init__(self, home: str, opened: Optional[str], in_tab: bool):
        self.home = home
        record = cached(home)
        if record is None:
            record = refresh(home)
        self.view = View(record, opened=opened, in_tab=in_tab)
        self.loaded = mtime(os.path.join(pane_dir(home), "record.json")) or 0

    def say(self, text: str, colour: str = "green", seconds: int = 8) -> None:
        self.view.notice = (text, colour, time.time() + seconds)

    def reload(self) -> None:
        path = os.path.join(pane_dir(self.home), "record.json")
        stamp = mtime(path) or 0
        if stamp != self.loaded:
            record = cached(self.home)
            if record:
                self.view.adopt(record)
                self.loaded = stamp
        age = now_epoch() - int(self.view.record.get("as_of_epoch") or 0)
        if age > env_int("FM_FACTORY_TTL", 20):
            refresh_in_background(self.home)

    def factory_of_stop(self) -> Optional[str]:
        if self.view.opened:
            return self.view.opened
        kind, ident = self.view.at()
        if kind == "factory":
            return ident
        if kind == "need":
            return self.view.need(ident)["factory"]
        return None

    def need_at(self) -> Optional[Dict[str, Any]]:
        kind, ident = self.view.at()
        return self.view.need(ident) if kind == "need" else None

    def send(self, request_id: str, body: str, done: str) -> None:
        ok, why = send_note(self.home, request_id, body)
        if ok:
            self.say(done, "green")
            refresh_in_background(self.home)
        else:
            self.say("Not sent: %s" % why, "red", 12)

    def key(self, key: str) -> bool:
        view = self.view
        now = now_epoch()
        if view.talking is not None:
            talk = view.talking
            if key == "esc":
                view.talking = None
            elif key == "enter" and talk.get("gone"):
                pass
            elif key == "enter":
                text = talk["text"].strip()
                view.talking = None
                if text:
                    fac = view.factory(talk["factory"])
                    if talk["kind"] == "talk":
                        body = "To the %s crew: %s\n\n(from the Factory pane)" % (fac["name"], text)
                        rid = "factory.%s.talk.%d" % (fac["id"], now)
                    elif talk["kind"] == "change":
                        body = "Changes for %s: %s\n\n(from the Factory pane; item %s%s)" % (
                            talk["title"], text, talk["item"], ", " + talk["pr"] if talk.get("pr") else "")
                        rid = "factory.%s.change.%s.%d" % (fac["id"], talk["item"], now)
                    else:
                        body = "About %s: %s\n\n(from the Factory pane; item %s)" % (talk["title"], text, talk["item"])
                        rid = "factory.%s.talk.%s.%d" % (fac["id"], talk["item"], now)
                    self.send(rid, body, "Sent to Starship. It passes it on to the %s crew." % fac["name"])
            elif key == "backspace":
                talk["text"] = talk["text"][:-1]
            elif key not in KEYS.values():
                # Typed keys arrive one at a time; pasted or sent text arrives whole.
                talk["text"] += "".join(c for c in key if c.isprintable())
            return True
        if view.confirm is not None:
            confirm, view.confirm = view.confirm, None
            if key == "enter":
                self.send(confirm["request_id"], confirm["body"], confirm["done"])
            return True
        lower = key.lower() if len(key) == 1 else key
        need = self.need_at()
        if lower in ("q", "ctrl-c"):
            if view.in_tab and os.environ.get("HERDR_TAB_ID"):
                # Factory tabs open on demand and close with their page.
                try:
                    os.remove(os.path.join(pane_dir(self.home), "tabs", view.opened or ""))
                except OSError:
                    pass
                herdr(["tab", "close", os.environ["HERDR_TAB_ID"]])
            return False
        if key == "up":
            view.move(-1)
        elif key == "down":
            view.move(1)
        elif key == "enter":
            fid = self.factory_of_stop()
            if fid and not view.opened:
                if os.environ.get("HERDR_PANE_ID"):
                    ok, why = open_tab(self.home, fid)
                    if not ok:
                        self.say("The factory tab did not open: %s" % why, "red", 12)
                else:
                    view.show(fid)
        elif key == "esc":
            if view.in_tab:
                origin = os.environ.get("FM_FACTORY_ORIGIN_TAB")
                if origin:
                    herdr(["tab", "focus", origin])
            elif view.opened:
                view.show(None)
        elif need and need["kind"] == "question" and any(o["key"].lower() == lower for o in need["options"]):
            option = next(o for o in need["options"] if o["key"].lower() == lower)
            fac = view.factory(need["factory"])
            view.confirm = {
                "item": need["id"], "asked": asking(need),
                "prompt": "%s: answer %s, %s?" % (need["title"], option["key"], option["label"]),
                "request_id": "factory.%s.answer.%s.%s.%s" % (fac["id"], need["id"], asking(need), option["key"]),
                "body": "Answer for %s: %s %s\n\n(from the Factory pane; item %s%s)" % (
                    need["title"], option["key"], option["label"], need["id"],
                    ", key " + need["key"] if need.get("key") else ""),
                "done": "Answer sent to Starship: %s." % option["label"]}
        elif need and need["kind"] == "finished work" and lower == "k":
            fac = view.factory(need["factory"])
            view.confirm = {
                "item": need["id"], "asked": asking(need),
                "prompt": "Keep %s and ask Starship to land it?" % need["title"],
                "request_id": "factory.%s.keep.%s.%s" % (fac["id"], need["id"], asking(need)),
                "body": "Keep %s: please land it.\n\n(from the Factory pane; item %s%s)" % (
                    need["title"], need["id"],
                    ", " + need["pr"] if need.get("pr") else ""),
                "done": "Sent to Starship: keep it."}
        elif need and need["kind"] == "finished work" and lower == "c":
            view.talking = {"kind": "change", "factory": need["factory"], "text": "", "item": need["id"],
                            "title": need["title"], "pr": need.get("pr"),
                            "label": "What should change in %s" % need["title"]}
        elif lower == "t":
            fid = self.factory_of_stop()
            if need and need["kind"] == "question":
                view.talking = {"kind": "discuss", "factory": need["factory"], "text": "", "item": need["id"],
                                "title": need["title"], "label": "About %s" % need["title"]}
            elif fid:
                view.talking = {"kind": "talk", "factory": fid, "text": "",
                                "label": "To the %s crew" % view.factory(fid)["name"]}
        elif lower == "s":
            fid = self.factory_of_stop()
            if fid:
                fac = view.factory(fid)
                who = "Starship" if fac["steered_by"] == "you" else "you"
                ok, why = send_note(self.home, "factory.%s.steer.%d" % (fid, now),
                                    ("I steer %s myself from now on." if who == "you" else
                                     "Starship steers %s again.") % fac["name"]
                                    + "\n\n(from the Factory pane; who steers is recorded in state/factory/steer.log)")
                if ok:
                    record_steer(self.home, fid, who, now)
                    fac["steered_by"] = who
                    view.record["feed"].insert(0, {
                        "at": now, "date": None, "actor": "you", "factory": fid, "job": None,
                        "word": "took the helm" if who == "you" else "handed back",
                        "text": ("You steer %s now." if who == "you" else "Starship steers %s again.") % fac["name"]})
                    self.say("You steer %s now." % fac["name"] if who == "you"
                             else "Starship steers %s again." % fac["name"], "cyan")
                    refresh_in_background(self.home)
                else:
                    self.say("Who steers did not change: %s" % why, "red", 12)
        return True


KEYS = {b"\x1b[A": "up", b"\x1b[B": "down", b"\x1b[C": "right", b"\x1b[D": "left",
        b"\x1bOA": "up", b"\x1bOB": "down", b"\x1b": "esc", b"\r": "enter", b"\n": "enter",
        b"\x7f": "backspace", b"\x08": "backspace", b"\x03": "ctrl-c"}


def read_key(fd: int) -> str:
    data = os.read(fd, 64)
    if data in KEYS:
        return KEYS[data]
    try:
        return data.decode()
    except UnicodeDecodeError:
        return ""


def live(pane: Pane) -> None:
    import termios
    import tty
    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    out = sys.stdout
    resized = [True]
    signal.signal(signal.SIGWINCH, lambda *_: resized.__setitem__(0, True))
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(SystemExit(0)))
    signal.signal(signal.SIGHUP, lambda *_: (_ for _ in ()).throw(SystemExit(0)))
    out.write("\x1b[?1049h\x1b[?25l\x1b[?7l")
    last_reload = 0.0
    try:
        tty.setraw(fd)
        while True:
            if time.time() - last_reload > 3:
                pane.reload()
                last_reload = time.time()
            size = os.get_terminal_size()
            view = pane.view
            if view.notice and time.time() > view.notice[2]:
                view.notice = None
            rows = view.frame(size.columns, size.lines)
            buf = ["\x1b[?2026h\x1b[H"]
            if resized[0]:
                buf.append("\x1b[2J")
                resized[0] = False
            buf.append("\r\n".join(paint(segs) + "\x1b[K" for segs in rows[:size.lines]))
            buf.append("\x1b[?2026l")
            out.write("".join(buf))
            out.flush()
            deadline = time.time() + 0.4
            while True:
                wait = deadline - time.time()
                if wait <= 0:
                    view.tick += 1
                    break
                ready, _, _ = select.select([fd], [], [], wait)
                if ready:
                    if not pane.key(read_key(fd)):
                        return
                    break
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)
        out.write("\x1b[?7h\x1b[?25h\x1b[?1049l")
        out.flush()
        if not pane.view.in_tab:
            try:
                write_atomic(os.path.join(pane_dir(pane.home), "last-look"), "%d\n" % now_epoch())
            except OSError:
                pass


# --------------------------------------------------------------------------
# Herdr: the factory tab and its live worker copies
# --------------------------------------------------------------------------

def herdr(args: List[str]) -> Tuple[bool, Any]:
    binary = shlex.split(os.environ.get("HERDR_BIN_PATH") or "herdr")
    try:
        out = subprocess.run(binary + args, capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError) as error:
        return False, str(error)
    if out.returncode != 0:
        return False, (out.stderr.strip() or out.stdout.strip() or "Herdr refused").splitlines()[-1]
    try:
        return True, json.loads(out.stdout) if out.stdout.strip() else {}
    except ValueError:
        return True, {}


def dig(data: Any, *paths: str) -> Optional[str]:
    for path in paths:
        node = data
        for part in path.split("."):
            node = node.get(part) if isinstance(node, dict) else None
        if isinstance(node, str) and node:
            return node
    return None


def pane_command(home: str, *args: str) -> str:
    words = ["exec", "env", "FM_HOME=%s" % home]
    for name in ("HERDR_BIN_PATH", "FM_FACTORY_TTL", "FM_FACTORY_QUIET_MINUTES", "FM_FACTORY_SNAPSHOT",
                 "FM_FACTORY_PEEK", "FM_FACTORY_INBOX", "FM_FACTORY_PANE_CONFIG_DIR"):
        if name in os.environ:
            words.append("%s=%s" % (name, os.environ[name]))
    words += ["bash", os.path.join(BIN, "fm-factory-pane.sh")] + list(args)
    return " ".join(shlex.quote(w) for w in words)


def open_tab(home: str, fid: str) -> Tuple[bool, str]:
    """Open (or focus) one factory's tab: its page left, its live workers right."""
    record = cached(home) or refresh(home)
    factory = next((f for f in record["factories"] if f["id"] == fid), None)
    if factory is None:
        return False, "no factory %s" % fid
    tabs = os.path.join(pane_dir(home), "tabs")
    session = os.environ.get("HERDR_SOCKET_PATH", "")
    known = read_text(os.path.join(tabs, fid)).split("\n")
    if len(known) >= 2 and known[1] == session and known[0]:
        ok, _ = herdr(["tab", "get", known[0]])
        if ok:
            ok, why = herdr(["tab", "focus", known[0]])
            return (True, "") if ok else (False, why)
    origin = os.environ.get("HERDR_TAB_ID", "")
    workspace = os.environ.get("HERDR_WORKSPACE_ID", "")
    args = ["tab", "create", "--label", factory["name"], "--focus"]
    if workspace:
        args[2:2] = ["--workspace", workspace]
    ok, data = herdr(args)
    if not ok:
        return False, str(data)
    tab = dig(data, "result.tab.tab_id", "result.tab.id")
    page = dig(data, "result.root_pane.pane_id", "result.root_pane.id")
    if not tab or not page:
        return False, "Herdr opened a tab but did not name it"
    os.makedirs(tabs, exist_ok=True)
    write_atomic(os.path.join(tabs, fid), "%s\n%s\n" % (tab, session))
    ok, why = herdr(["pane", "run", page, pane_command(home, "run", "--factory", fid, "--origin-tab", origin)])
    if not ok:
        return False, "the tab opened, but its page did not start: %s" % why
    workers = [j for j in factory["jobs"] if j["started"] and j["state"] not in ("stopped", "finished")][:MIRROR_CAP]
    above = None
    for index, job in enumerate(workers):
        target, direction = (page, "right") if index == 0 else (above, "down")
        ok, data = herdr(["pane", "split", target, "--direction", direction, "--no-focus"])
        new = dig(data, "result.pane.pane_id", "result.pane.id") if ok else None
        if not new:
            return False, "the tab opened, but a worker's live view did not: %s" % (data if not ok else "no pane")
        herdr(["pane", "run", new, pane_command(home, "follow", job["id"])])
        above = new
    herdr(["pane", "focus", page])
    return True, ""


def follow(home: str, task_id: str) -> None:
    """A read-only live copy of one worker's pane, refreshed every 2 seconds."""
    peek = os.environ.get("FM_FACTORY_PEEK") or os.path.join(BIN, "fm-peek.sh")
    record = cached(home) or {}
    title = task_id
    for factory in record.get("factories") or []:
        for job in factory.get("jobs") or []:
            if job["id"] == task_id:
                title = job["title"]
    out = sys.stdout
    out.write("\x1b[?25l\x1b[?7l")
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(SystemExit(0)))
    try:
        while True:
            size = os.get_terminal_size()
            try:
                got = subprocess.run(shlex.split(peek) + [task_id, str(max(size.lines - 2, 1))],
                                     capture_output=True, text=True, timeout=10, env=dict(os.environ, FM_HOME=home))
                lines = got.stdout.splitlines() if got.returncode == 0 else ["(this worker's pane cannot be read)"]
            except (OSError, subprocess.SubprocessError):
                lines = ["(this worker's pane cannot be read)"]
            head = paint(row(size.columns, [S(" " + title, "cyan", True)], [S("live copy · read only", "faint")]))
            body = [line[:size.columns] for line in lines[-(size.lines - 2):]]
            out.write("\x1b[H\x1b[2J" + head + "\r\n\r\n" + "\r\n".join(body))
            out.flush()
            time.sleep(2)
    finally:
        out.write("\x1b[?7h\x1b[?25h")
        out.flush()


# --------------------------------------------------------------------------
# Entry
# --------------------------------------------------------------------------

def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(prog="fm-factory.py", add_help=True,
                                     description="The Factory pane. See the header of this file.")
    parser.add_argument("command", nargs="?", choices=["view", "follow", "open-tab", "refresh"])
    parser.add_argument("target", nargs="?")
    parser.add_argument("--data", action="store_true")
    parser.add_argument("--plain", action="store_true")
    parser.add_argument("--fresh", action="store_true")
    parser.add_argument("--factory")
    parser.add_argument("--width", type=int, default=92)
    parser.add_argument("--origin-tab")
    try:
        args = parser.parse_args(argv)
    except SystemExit as stop:
        return 2 if stop.code else 0
    home = home_dir()
    try:
        if args.data or args.plain:
            if args.command:
                parser.print_usage(sys.stderr)
                return 2
            record = current_record(home, args.fresh or bool(os.environ.get("FM_FACTORY_SNAPSHOT")))
            if args.data:
                print(json.dumps(record, indent=2, ensure_ascii=False))
            else:
                if args.factory and not any(f["id"] == args.factory for f in record["factories"]):
                    print("fm-factory: no factory %s" % args.factory, file=sys.stderr)
                    return 1
                print(plain(View(record, opened=args.factory), max(args.width, 40)))
            return 0
        if args.command == "refresh":
            refresh(home)
            return 0
        if args.command == "view":
            if args.origin_tab:
                os.environ["FM_FACTORY_ORIGIN_TAB"] = args.origin_tab
            live(Pane(home, args.factory, in_tab=bool(args.factory and os.environ.get("HERDR_PANE_ID"))))
            return 0
        if args.command == "follow" and args.target:
            follow(home, args.target)
            return 0
        if args.command == "open-tab" and args.target:
            ok, why = open_tab(home, args.target)
            if not ok:
                print("fm-factory: %s" % why, file=sys.stderr)
                return 1
            return 0
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
        print("fm-factory: %s" % error, file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 0
    parser.print_usage(sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
