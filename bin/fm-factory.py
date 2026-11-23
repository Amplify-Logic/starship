#!/usr/bin/env python3
"""fm-factory.py - the Factory pane: one record of the owner's factories, drawn.

A factory is one segment of the owner's work: a crew with its own work list,
rules, memory and workers. data/factories.md names a home's factories and maps
each to its projects; with no registry every registered project in
data/projects.md is its own factory. docs/factory-pane.md owns what the pane
shows and why, and the registry's `routine:` line ("Routine work");
docs/fork-configuration.md owns the rest of the registry format; this header owns
the commands.

Usage:
  fm-factory.py --data [--fresh]          print the record as JSON (fm-factory.v1)
  fm-factory.py --plain [--factory ID] [--item ID] [--width N] [--height N] [--fresh]
                                          print the screen as plain text; with
                                          --height, only what a pane that tall
                                          shows when it opens; with --item, the
                                          highlight is on that item of NEEDS YOU
  fm-factory.py --screen [--fresh]        print the screen as data
                                          (fm-factory-screen.v1): what the
                                          overview and every factory's page
                                          show, in the pane's own words, from
                                          the cached record kept current the
                                          way a live pane keeps it. A second
                                          screen such as bin/fm-web.py draws it
  fm-factory.py act                       one writing key pressed from a second
                                          screen: reads one JSON action on
                                          stdin, sends the note that key sends
                                          in the pane, and prints
                                          {"ok": ..., "said": ...}; exit 2 when
                                          the action cannot be read (act() owns
                                          the actions and their fields)
  fm-factory.py view [--factory ID] [--item ID]
                                          the live pane (Herdr runs it through
                                          bin/fm-factory-pane.sh run); --item
                                          starts the highlight on that item of
                                          NEEDS YOU
  fm-factory.py follow <task-id>          a read-only live copy of one worker's
                                          pane, for an opened factory tab
  fm-factory.py open-tab <factory-id>     open, or focus, that factory's Herdr
                                          tab: its page on the left and its live
                                          workers stacked on the right
  fm-factory.py workers <factory-id> --page <pane-id>
                                          split a live copy of each of that
                                          factory's running workers beside its
                                          page pane, the way open-tab does
  fm-factory.py profile <project> [--data-dir DIR]
                                          print a first line holding the size
                                          of the rules of the factory that
                                          claims <project> (by its projects,
                                          an alias included), the cap and that
                                          factory's name, space separated, then
                                          its Rules: lines, one per line;
                                          nothing when there are none
                                          (bin/fm-brief.sh adds them to a job's
                                          instructions when the size is at most
                                          the cap)
  fm-factory.py refresh                   rebuild the cached record once
  fm-factory.py refresh-calls             rebuild it with fresh owner's calls on
                                          the last full refresh's workers, or,
                                          with no such reading, refresh it whole
                                          once the last refresh's rest is over

One record, two readers: every word on screen comes from the record, and every
state is a word, so an agent reading the pane as text loses nothing.

Staying current. A running pane keeps the code it started with in memory, while
the record it draws is rebuilt by a fresh process with whatever code is on disk.
So the live pane and each live copy compare this file's checksum before every
frame, and when it changed and the new file is non-empty and compiles, they
re-execute themselves in place: the same process and Herdr pane, the new code.

Where the record comes from. The count line is the overview reading the bridge
strip and the status bar show (fm_fleet_status_counts `overview` in
bin/fm-fleet-status-lib.sh), in the same words (docs/status-bar.md "Fleet
words"), so the three never show different numbers for the same moment. Live
work, decisions and the work list come only from bin/fm-fleet-snapshot.sh
--light, and each task's state word comes from the same fold the overview counts
with (fm_fleet_status_bucket in that library). NEEDS YOU is exactly
fm_owner_calls in that library over the overview reading's ready work, the
calls the overview counts and the tap page shows, and each question's options
and suggestion come from bin/fm-tap-desk.sh shapes, the reading its tap card
shows, so the pane can never disagree with either.
The queue is every work item nobody has started, counted in that same pass by
what will start it (queue_word below); what is held and what still waits on
other work is read as the backlog's own adapter reads it. A closed work item
reads as finished work only when landed_delivery in bin/fm-landed-lib.sh finds
its merged change, landing or report; closed without one, it reads closed,
or settled when it was a call of the owner's.
The rest are event records the home already keeps: the [at=] times on status
lines, the turn times in state/<id>.busy-state, state/<id>.turn-ended, the
optional one-line state/<id>.step a worker may write to say what it is doing,
whether a running worker's pane text changed since the last reading
(bin/fm-peek.sh), and the owner's own notes and Starship's replies
(bin/fm-inbox.sh receipts).

What the pane writes. Its cache and its own records live in state/factory/:
record.json (the cached record), basis.json (the fleet reading the last full
refresh used), inputs (inputs_digest when it began), shapes.json (questions'
shapes the calls rebuilds read on that reading), rebuild.lock and rebuild.last
(the one rebuild under way, and when the last full refresh ended and how long it took),
activity.json (when each worker's pane last changed), last-look
(when the owner last looked: the newest sign of a look on its first line, when
the look before that ended on its second), steer.log (who steers each factory),
tabs/ (the factory tabs it opened), talk-<pid>.wav while a spoken note is
being written down, read.log (what the last Read printed), and
pr-summaries.json (each ready PR's short section, kept half an hour), and
merged-at.json (when each PR that went live was merged, kept once known). A look is a key
pressed in the pane, or the pane focused in Herdr for a few seconds (asked with
`herdr pane get`); focus alone keeps a look going for at most 15 minutes after
the focus began or the last key press, so a pane left focused does not look
forever. A factory's own tab records none, since it shows one factory only.

A PR's short section. Finished work waiting for the merge word shows the In
short, See it, You need to and Risk parts of its PR's description (the sections
.github/pull_request_template.md asks for) above `k  keep it`, read with
`gh pr view` for a GitHub PR and kept for half an hour (pr_summaries); a PR
opened without those sections, or one that cannot be read, shows none.

Read. A call or job has something to read when its task has a report or a page
of its own (data/<id>/report.md or data/<id>/page.html) or its hold reason names
a report under the home's data/; its record carries those as `read`, the sources
bin/fm-read.sh is given, and fm-read.sh owns which page opens. `r` reads the
highlighted call, or on a factory the first job or report in New it shows
with something to read, and a click on any `r  Read the report` line reads that one; the reader runs in the
background, so the pane never waits on it. Likewise a change in New that went
live shows an `o  See what changed` line: `o` on its factory opens the first
such PR in the browser, and a click on the line opens that one.

How fresh it is. A full refresh reads every worker, which takes seconds, so the
live pane starts one only once the record's workers are FM_FACTORY_TTL old and
a status, record or backlog file changed since the last one began
(inputs_digest), or once they are FM_FACTORY_MAX_AGE old whatever changed,
unless the machine is busy (machine_busy). That safety refresh exists because
a worker's pane activity, a job gone quiet and a change merged elsewhere are
recorded in no file, so without it the pane would go stale.
FM_FACTORY_TTL is a minute because a busy fleet writes those files every few
seconds, so the pane refreshed whole about as often as it allowed: at 20
seconds two open panes on a three-job fleet started about seven fleet
readings and twelve job-state reads a minute, and each whole refresh costs
several seconds of processor time; at a minute it is about two and four, however
many panes are open. The owner's calls do not wait on it (below).
A full refresh reads its slow inputs side by side, the held questions' options
beside the fleet reading since they need only the backlog, and keeps those
options from the last one while the owner's calls have not moved (kept_shapes).
Every pane and live copy of a home starts its rebuilds, full or of the
owner's calls, under one lock the rebuild holds until it exits, so two never
run side by side, and after a full refresh the next waits as long as that one
took, at least a minute on a busy machine (rebuild_wait). A pane that opens
with no record waits for that lock and builds the first one only if no other
pane built it meanwhile (first_record).
The owner's calls cannot wait that long: once a second the pane reads the
owner's calls signal (bin/fm-owner-calls-signal-lib.sh), and when it has moved
past the one the record was built under it rebuilds the record from basis.json
with the backlog and the inbox read afresh (refresh-calls), so a decision
answered, parked, released, closed or added, or a note to Starship, shows in
NEEDS YOU within a second or two. --data and --plain catch the calls up the same
way before they print a cached record. Every writing key
goes through a path Starship already has and acts only on the highlighted row:
an answer, keep, ask-for-changes or talk becomes a captain inbox note
(bin/fm-inbox.sh note) that Starship acts on under its own rules, so the pane
merges nothing, answers no hold itself and steers no worker. Who steers is a
recorded choice that Starship is also told about; it grants nothing.
`x` (Already settled?) on a held question files a reconcile request for it
through bin/fm-captain-hold.sh reconcile-requests under the pane's bound
source id `factory-pane` (bin/fm-factory-pane.sh binds it), then wakes
Starship with an inbox note naming the call. It only asks: Starship re-reads
the conversation and closes the call with evidence or rewrites it.
docs/factory-pane.md ("Keys") owns when the card reads `checking` and how
the wake note is named.

The talk box. Where this machine has a microphone recorder (mic_command) and
the home has the desk voice's speech key, t listens at once: the recorder's
samples are read here, the newest few seconds are written down every couple of
seconds by the desk voice's own command (bin/fm-deepgram-stt.sh) and shown in
the box, and when the speaker stops or presses enter the whole note is written
down once and sent (the Voice class owns the bounds). So the microphone's
sound goes to that speech service from the first speech on, as the desk
voice's does. A first typed key or esc drops the recording: nothing more of it
is written down and no file of it stays. Without a recorder or the key the box
is typed from the start. A recording that cannot be written down goes to the
desk voice's unsent recordings (bin/fm-desk-voice.sh keep).

Environment:
  FM_HOME                     the home whose factories are shown (default: this
                              code root)
  HERDR_BIN_PATH              the Herdr binary (default: herdr on PATH)
  FM_TERMINAL_THEME           auto (default), light or dark; see
                              bin/fm_terminal_theme.py for detection
  FM_FACTORY_TTL              seconds a cached record is used before a refresh
                              is started (default 60)
  FM_FACTORY_MAX_AGE          seconds after which a refresh is started even
                              though no file it reads changed, unless the
                              machine is busy (default 300)
  FM_FACTORY_QUIET_MINUTES    minutes without a sign of life before a running
                              job reads as quiet (default 15)
  FM_FACTORY_FOCUS_FILE       a file the live overview reads and removes: an
                              item id written there moves the highlight to
                              that item (bin/fm-factory-pane.sh open --item)
  FM_FACTORY_MIC              the microphone recorder: a command that writes
                              16 kHz mono 16-bit little-endian samples to its
                              standard output until stopped (default: ffmpeg
                              on the Mac's default input; empty: no voice,
                              the talk box is typed)
Test seams:
  FM_FACTORY_SNAPSHOT         a fleet snapshot JSON file used instead of running
                              bin/fm-fleet-snapshot.sh
  FM_FACTORY_NOW              the current epoch
  FM_FACTORY_LOADAVG          the one-minute load average, read instead of the
                              machine's own
  FM_FACTORY_PEEK             pane reader run as `<cmd> <task-id> <lines>`
                              (default bin/fm-peek.sh); empty skips pane reads
  FM_FACTORY_INBOX            inbox command (default bin/fm-inbox.sh)
  FM_FACTORY_SHAPES           decision shapes command, run with the decision
                              ids as arguments (default bin/fm-tap-desk.sh
                              shapes)
  FM_FACTORY_CAPTAIN_HOLD     captain-hold command (default
                              bin/fm-captain-hold.sh)
  FM_FACTORY_STT              the command that writes a recording down, run as
                              `<cmd> <audio-file>` (default
                              bin/fm-deepgram-stt.sh); set, it also stands in
                              for the speech key
  FM_FACTORY_PR_BODY          the command that prints a PR's description, run
                              as `<cmd> <pr-url>` (default `gh pr view`, for
                              GitHub PRs only); empty reads none
  FM_FACTORY_PR_MERGED        the command that prints when a PR was merged
                              (an ISO time), run as `<cmd> <pr-url>` (default
                              `gh pr view`, for GitHub PRs only); empty reads
                              none
  FM_FACTORY_READ             reader command, run with the item's read sources
                              as arguments (default bin/fm-read.sh)
  FM_FACTORY_OPEN             the command that opens a change's PR, run as
                              `<cmd> <pr-url>` (default open on macOS,
                              xdg-open elsewhere)
Exit: 0 on success; 1 when a step fails, with the reason on stderr; 2 on a usage
error.
"""

from __future__ import annotations

import argparse
import array
import fcntl
import hashlib
import json
import math
import os
import re
import select
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

from fm_terminal_theme import DARK, palette, remembered_theme, select_theme
import wave
from typing import Any, Dict, List, Optional, Tuple

SCHEMA = "fm-factory.v1"
SCREEN_SCHEMA = "fm-factory-screen.v1"
ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
BIN = os.path.join(ROOT, "bin")
STEPS = ["planning", "building", "checking", "ready to merge"]
FEED_CAP = 30
LOOK_BACK_DEFAULT = 12 * 3600
LOOK_BACK_MAX = 48 * 3600
LOOK_GAP = 15 * 60      # this long without a sign of a look ends the look
FOCUS_HOLD = 5          # seconds the pane stays focused before it counts as a look
FOCUS_CAP = 15 * 60     # focus alone keeps a look going this long after it began or the last key
MIRROR_CAP = 4
# A factory's rules go into each of its jobs' briefs only while their "- " list
# is at most this many characters (profile_size); bin/fm-brief.sh leaves a
# larger list out whole. The factory page shows the size against this cap.
PROFILE_CAP = 1500
# A factory tab opens a live copy only of a worker at work: busy, with
# Starship, needing a look or failed, or waiting on the owner's decision.
# Parked, held, queued and finished jobs get none.
MIRROR_STATES = ("busy", "with Starship", "needs a look", "failed", "decision for you")
# An open copy also stays through a moment the fleet cannot be read, and closes
# its pane once its job really ends: gone from the record or in any other state.
MIRROR_KEEP = MIRROR_STATES + ("no reading",)

# The captured-source id the pane files reconcile requests under; installing
# the pane binds it (bin/fm-factory-pane.sh), which is the owner's opt-in.
SETTLED_SOURCE = "factory-pane"
VOICE_RATE = 16000        # the talk box's microphone: samples a second, one channel, 16 bits
VOICE_CHUNK = 1600        # samples heard at a time: a tenth of a second
VOICE_SPEECH = 60         # the quietest level that can be speech, of 32768
VOICE_SETTLE = 5          # first tenths of a second that only measure the room, never speech
VOICE_LOUDEST_ROOM = 500  # the loudest a room's own level is taken to be while it is measured
VOICE_QUIET_STOP = 20     # tenths of a second of quiet after speech that end a recording
VOICE_NO_SPEECH = 600     # tenths of a second without any speech before a recording stops listening
VOICE_MAX = 1800          # the longest recording, in tenths of a second
VOICE_LIVE_WINDOW = 8     # seconds of the newest sound written down to show the words while speaking
VOICE_LIVE_EVERY = 2.0    # the least seconds between two of those writings
VOICE_LIVE_BACKOFF = 4.0  # seconds to wait after one failed, doubling up to VOICE_LIVE_BACKOFF_MAX
VOICE_LIVE_BACKOFF_MAX = 30.0
# Rebuilds of the record: what a whole refresh reads that a file records (each
# state/<id> file with one of these endings, beside the files inputs_digest
# names), and how they are spaced out (rebuild_wait).
INPUT_ENDINGS = (".status", ".meta", ".busy-state", ".turn-ended", ".step")
REBUILD_CHECK_EVERY = 2   # the least seconds between two checks of whether a whole refresh is due
BUSY_PER_CORE = 2.0       # a one-minute load average this many times the cores is a busy machine
BUSY_GAP = 60             # a busy machine gets at least this many seconds between two full refreshes
FAILED_GAP = 15           # and a rebuild that failed at least this many before the next tries
REBUILD_LIMIT = 300       # a rebuild still running after this many seconds stops itself


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
    # toISOString() stamps (the tap shapes' held_since) carry milliseconds.
    text = re.sub(r"\.\d+Z$", "Z", text.strip())
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


def day_words(date: str) -> str:
    """A YYYY-MM-DD date as "1 Dec", with its year only when that is not this year."""
    epoch = parse_iso(date)
    if epoch is None:
        return date
    day = time.gmtime(epoch)
    words = "%d %s" % (day.tm_mday, time.strftime("%b", day))
    return words if day.tm_year == time.gmtime(now_epoch()).tm_year else "%s %d" % (words, day.tm_year)


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


def load_projects(home: str, data: Optional[str] = None) -> List[Dict[str, Any]]:
    """data/projects.md rows: name, its label= and alias= tokens, in order."""
    rows = []
    for line in read_text(os.path.join(data or os.path.join(home, "data"), "projects.md")).splitlines():
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


ROUTINE_ALL = "Routine work"


def routine_marks(value: str) -> List[str]:
    """A factory's `routine:` field: every job (`yes`), none (`no`), or the job title starts it lists."""
    if value.strip().lower() == "yes":
        return [ROUTINE_ALL]
    if value.strip().lower() in ("", "no"):
        return []
    return [kind.strip() for kind in value.split(",") if kind.strip()]


def routine_kind(marks: List[str], title: str) -> Optional[str]:
    """Which routine kind a job is in its factory, by its title, or None for ordinary work."""
    if ROUTINE_ALL in marks:
        return ROUTINE_ALL
    text = (title or "").lower()
    for kind in marks:
        start = kind.lower()
        if text.startswith(start) and not text[len(start):len(start) + 1].isalpha():
            return kind
    return None


def load_registry(home: str, data: Optional[str] = None) -> Tuple[List[Dict[str, Any]], str]:
    """data/factories.md, or one factory per registered project without it.

    Returns the factories and the word for where they came from. <data> is the
    data directory when it is not the home's own.
    """
    data = data or os.path.join(home, "data")
    text = read_text(os.path.join(data, "factories.md"))
    factories: List[Dict[str, Any]] = []
    current: Optional[Dict[str, Any]] = None
    section = None
    for raw in text.splitlines():
        line = raw.rstrip()
        if line.startswith("## "):
            current = {"name": line[3:].strip(), "id": None, "about": None, "projects": [],
                       "rules": [], "learned": [], "routine": []}
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
        match = re.match(r"^(id|about|projects|routine):\s*(.*)$", stripped, re.I)
        if match:
            key, value = match.group(1).lower(), match.group(2).strip()
            section = None
            if key == "projects":
                current["projects"] = [p.strip() for p in value.split(",") if p.strip()]
            elif key == "routine":
                current["routine"] = routine_marks(value)
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
    for row in load_projects(home, data):
        factories.append({"name": row["label"] or display_name(row["name"]), "id": slug(row["name"]),
                          "about": None, "projects": [row["name"]],
                          "rules": [], "learned": [], "routine": []})
    return factories, "projects"


def project_owner(factories: List[Dict[str, Any]], project_rows: List[Dict[str, Any]]):
    """A function from a work item's project word, an alias included, to the id
    of the factory whose projects name it, or None when no factory does."""
    alias_of: Dict[str, str] = {}
    for row in project_rows:
        for alias in row["aliases"]:
            alias_of[alias.lower()] = row["name"].lower()
    owner: Dict[str, str] = {}
    for factory in factories:
        for project in factory["projects"]:
            owner[project.lower()] = factory["id"]

    def owner_of(project: Optional[str]) -> Optional[str]:
        key = (project or "").strip().lower()
        key = alias_of.get(key, key)
        if key in owner:
            return owner[key]
        for alias, name in alias_of.items():
            if name == key and alias in owner:
                return owner[alias]
        return None
    return owner_of


def profile_size(rules: List[str]) -> int:
    """The size of a factory's rules as a brief carries them: characters, not
    bytes, of one "- " line per rule, each with its newline. PROFILE_CAP is
    measured against this, by the brief and the factory page alike."""
    return sum(len("- %s\n" % rule) for rule in rules)


def print_profile(data: str, project: str) -> int:
    """`profile`: the factory that claims <project> and its profile, its Rules:
    lines (never its Learned: lines).

    Prints the rules' profile_size, PROFILE_CAP and the factory's name on the
    first line, space separated, and each rule after it, in file order, and
    nothing at all when there is no registry, no factory claims the project, or
    that factory has no rules. bin/fm-brief.sh owns what a brief does with it."""
    if not os.path.isfile(os.path.join(data, "factories.md")):
        return 0
    factories, _ = load_registry(data, data)
    fid = project_owner(factories, load_projects(data, data))(project)
    factory = next((f for f in factories if f["id"] == fid), None)
    if factory and factory["rules"]:
        print(profile_size(factory["rules"]), PROFILE_CAP, factory["name"])
        for line in factory["rules"]:
            print(line)
    return 0


# --------------------------------------------------------------------------
# Reading the fleet
# --------------------------------------------------------------------------

def load_snapshot(home: str) -> Dict[str, Any]:
    seam = os.environ.get("FM_FACTORY_SNAPSHOT")
    if seam:
        with open(seam, encoding="utf-8") as handle:
            return json.load(handle)
    env = dict(os.environ, FM_HOME=home)
    out = subprocess.run(["bash", os.path.join(BIN, "fm-fleet-snapshot.sh"), "--light"],
                         capture_output=True, text=True, timeout=120, env=env)
    if out.returncode != 0:
        raise RuntimeError("the fleet snapshot failed: %s" % (out.stderr.strip().splitlines() or ["no reason"])[-1])
    return json.loads(out.stdout)


def live_tasks(snapshot: Dict[str, Any]) -> List[Dict[str, Any]]:
    """The snapshot's ordinary tasks; second mates are not work."""
    return [t for t in snapshot.get("tasks") or [] if t.get("kind") != "secondmate" and t.get("id")]


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


def alive_ids(tasks: List[Dict[str, Any]]) -> set:
    """The tasks the overview's own liveness check (_fm_fleet_liveness) reads alive, in one bash call."""
    lines = []
    for task in tasks:
        meta = (((task.get("paths") or {}).get("meta") or {}).get("path") or "")
        if task.get("id") and meta:
            lines.append("%s\t%s" % (task["id"], meta))
    if not lines:
        return set()
    script = (
        '. "$1/fm-fleet-status-lib.sh" || exit 1\n'
        'probe=${FM_FLEET_STATE_PROBE:-_fm_fleet_probe_default}\n'
        'while IFS="$(printf "\\t")" read -r id meta; do\n'
        '  printf "%s\\t%s\\n" "$id" "$(_fm_fleet_liveness "$meta" 0 "$probe" 2>/dev/null </dev/null)"\n'
        'done\n'
    )
    try:
        out = subprocess.run(["bash", "-c", script, "fm-factory", BIN], input="\n".join(lines) + "\n",
                             capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return set()
    return {line.split("\t", 1)[0] for line in out.stdout.splitlines()
            if "\t" in line and line.split("\t", 1)[1].strip() == "alive"}


def overview_reading(home: str) -> Optional[Dict[str, Any]]:
    """The overview reading the bridge strip and the status bar show.

    It is fm_fleet_status_counts `overview` in bin/fm-fleet-status-lib.sh, a
    cache read that never waits on the workers. None when it cannot be read;
    `known` 0 when no good reading exists yet, 2 when it is the last good one
    but no longer current. `ready_list` is None when the reading predates the
    list, and otherwise the tasks behind its merges. `failed` and `lost` are
    the broken work the bridge strip's alert counts (None when the reading has
    no such figures), and `lost_list` the tasks behind `lost`.
    """
    script = '. "$1/fm-fleet-status-lib.sh" && fm_fleet_status_counts "$2" overview'
    try:
        out = subprocess.run(["bash", "-c", script, "fm-factory", BIN, os.path.join(home, "state")],
                             capture_output=True, text=True, timeout=20, stdin=subprocess.DEVNULL,
                             env=dict(os.environ, FM_HOME=home))
    except (OSError, subprocess.SubprocessError):
        return None
    fields = out.stdout.rstrip("\n").split("\t")
    if out.returncode != 0 or len(fields) < 10:
        return None
    try:
        _records, working, _stopped, validating, _paused, _attention, ready, known, age, decisions = (
            int(x) for x in fields[:10])
    except ValueError:
        return None
    if known not in (0, 1, 2) or decisions > ready:
        return None
    # The list and the calls signal are given together, so a reading with no
    # signal has no list yet, while one with a signal and `-` has no ready work.
    ready_list = None
    if len(fields) >= 18 and fields[10] != "-" and fields[16] != "-":
        ready_list = sorted(x for x in fields[17].split(" ") if x and x != "-")
    failed = lost = None
    if len(fields) >= 12 and fields[10].isdigit() and fields[11].isdigit():
        failed, lost = int(fields[10]), int(fields[11])
    lost_list = sorted(x for x in fields[18].split(" ") if x and x != "-") if len(fields) >= 19 else []
    return {"known": known, "age": age if known else 0, "busy": working + validating,
            "decisions": decisions, "ready_to_merge": ready - decisions, "ready_list": ready_list,
            "failed": failed if known else None, "lost": lost if known else None,
            "lost_list": lost_list if known else []}


def overview_ready_list(overview: Optional[Dict[str, Any]]) -> Optional[List[str]]:
    """The overview reading's ready work, or None before a reading that has it."""
    return (overview or {}).get("ready_list") if (overview or {}).get("known") else None


def overview_call_buckets(overview: Optional[Dict[str, Any]], buckets: Dict[str, str]) -> Dict[str, str]:
    """The buckets the owner's calls are read on: the overview's ready work is
    the merges, so NEEDS YOU is the count the overview shows; this pane's own
    buckets stand in only until a reading with that list exists."""
    ready_list = overview_ready_list(overview)
    return {ident: "ready" for ident in ready_list} if ready_list is not None else buckets


def overview_counts(overview: Optional[Dict[str, Any]], idle: int) -> Dict[str, Any]:
    """The count line's figures: the overview reading's, plus the idle factories.

    They are only ever the overview's, so the count line never shows a number
    the bridge strip and the status bar do not; NEEDS YOU is rebuilt when the
    overview's ready work changes.
    """
    if not overview or not overview["known"]:
        return {"reading": "unknown", "age": 0, "busy": None, "decisions": None, "ready_to_merge": None,
                "idle": idle, "failed": None, "lost": None, "lost_list": []}
    return {"reading": "current" if overview["known"] == 1 else "past", "age": overview["age"],
            "busy": overview["busy"], "decisions": overview["decisions"],
            "ready_to_merge": overview["ready_to_merge"], "idle": idle,
            "failed": overview.get("failed"), "lost": overview.get("lost"),
            "lost_list": list(overview.get("lost_list") or [])}


def age_words(seconds: int) -> str:
    """The strip's and status bar's words for how old a past reading is."""
    if seconds < 60:
        return "a moment ago"
    if seconds < 3600:
        return "%dm ago" % (seconds // 60)
    return "%dh ago" % (seconds // 3600)


def count_words(counts: Dict[str, Any], short: bool = False) -> List[Tuple[str, str]]:
    """The count line as (words, colour) pieces, in the overview's words."""
    if counts.get("busy") is None:
        pieces = [("reading the crew", "faint")]
    else:
        busy, decisions, merge = counts["busy"], counts["decisions"], counts["ready_to_merge"]
        decision_words = "decision" if decisions == 1 else "decisions"
        pieces = [("%d busy" % busy, "amber" if busy else "faint"),
                  ("%d %s" % (decisions, decision_words if short else decision_words + " for you"),
                   "red" if decisions else "faint"),
                  ("%d %s" % (merge, "to merge" if short else "ready to merge"), "green" if merge else "faint")]
    pieces.append(("%d idle" % counts["idle"], "faint"))
    if counts.get("reading") == "past" and not short:
        pieces[-2] = (pieces[-2][0] + " (%s)" % age_words(counts.get("age") or 0), pieces[-2][1])
    return pieces


def count_line_text(counts: Dict[str, Any]) -> str:
    return " · ".join(words for words, _colour in count_words(counts))


def date_words(date: str) -> str:
    """A YYYY-MM-DD date with its day of the week, as "Mon 23 Nov"."""
    epoch = parse_iso(date)
    return "%s %s" % (time.strftime("%a", time.gmtime(epoch)), day_words(date)) if epoch is not None else date


def sentences(record: Dict[str, Any], now: int) -> List[Dict[str, str]]:
    """The three sentences at the top of both screens, in place of rows of counts.

    The first says how many things need the owner (the overview's calls, the
    count NEEDS YOU lists) and how many more wait on its two shelves, so every
    call that waits on him is counted once and named somewhere; the second
    how many jobs run and how many stopped, the figures the bridge strip shows;
    the third what went live and which reports came in since the last look.
    Each has the part of the screen it speaks for: `needs`, or `factories`, where each factory's Now and New are.
    """
    counts = record.get("counts") or {}
    older, later = len(record.get("older") or []), len(record.get("coming_back") or [])
    calls = 0
    if counts.get("busy") is None:
        first = "Reading what needs you."
        second = "Reading the crew."
    else:
        calls = (counts.get("decisions") or 0) + (counts.get("ready_to_merge") or 0)
        first = "Nothing needs you." if not calls else "%s %s you." % (
            plural(calls, "thing", "things"), "needs" if calls == 1 else "need")
        shelves = []
        if older:
            shelves.append("%s %s still open" % (plural(older, "older question", "older questions"),
                                                 "is" if older == 1 else "are"))
        if later:
            shelves.append("%d %s put off to a date" % (later, ("more " if older or calls else "") +
                                                        ("is" if later == 1 else "are")))
        if shelves:
            first += " %s." % ", and ".join(shelves)
        busy = counts["busy"]
        second = "Nothing is running." if not busy else "%s %s running." % (
            plural(busy, "job", "jobs"), "is" if busy == 1 else "are")
        trouble = []
        if counts.get("lost"):
            trouble.append("%d %s stopped" % (counts["lost"], "has" if counts["lost"] == 1 else "have"))
        if counts.get("failed"):
            trouble.append("%d hit a problem" % counts["failed"])
        if trouble:
            many = len(trouble) > 1 or (counts.get("lost") or 0) + (counts.get("failed") or 0) > 1
            second += " %s, and Starship is on %s." % (" and ".join(trouble), "them" if many else "it")
        if counts.get("reading") == "past":
            second = second[:-1] + " (%s)." % age_words(counts.get("age") or 0)
    news = record.get("news") or {}
    live, reports = news.get("went_live") or 0, news.get("report_ready") or 0
    when = since_words(record, now)
    moved = []
    if live:
        moved.append("%s went live" % plural(live, "change", "changes"))
    if reports:
        moved.append("%s %s ready" % (plural(reports, "report", "reports"), "is" if reports == 1 else "are"))
    third = ("%s %s." % (" and ".join(moved), when)) if moved else \
        "Nothing went live and no report came in %s." % when
    trouble = bool(counts.get("lost") or counts.get("failed"))
    return [{"words": first, "to": "needs", "colour": "red" if calls else "mist"},
            {"words": second, "to": "factories", "colour": "amber" if trouble or counts.get("busy") else "mist"},
            {"words": third[0].upper() + third[1:], "to": "factories", "colour": "green" if moved else "mist"}]


def since_words(record: Dict[str, Any], now: int) -> str:
    """Since when the feed tells what moved, as the third sentence says it: "since you looked at 20:24"."""
    since = record.get("since_epoch")
    return {"12 hours": "in the last 12 hours", "48 hours": "in the last 48 hours"}.get(
        record.get("since_from") or "", "since you looked at %s" % when_words(since, now) if since else "lately")


def news_heading(record: Dict[str, Any], now: int) -> str:
    """Since when a factory's New tells what moved: the feed's start, in the third sentence's words."""
    since = record.get("since_epoch")
    return {"12 hours": "new in the last 12 hours", "48 hours": "new in the last 48 hours"}.get(
        record.get("since_from") or "", "new since you looked at %s" % when_words(since, now) if since else "new lately")


def shelves(record: Dict[str, Any], now: int, fid: Optional[str] = None) -> Dict[str, Any]:
    """The words of NEEDS YOU's two shelves, overall or for one factory.

    `older` is every older question still open: a call that waited undated
    past the snapshot's age and so left NEEDS YOU, oldest first. `coming` is
    every call put off to a date, soonest first: the ones that come back this
    week by name and date, the rest counted, and the date the next of those
    comes back.
    """
    older = [o for o in record.get("older") or [] if fid in (None, o["factory"])]
    later = [c for c in record.get("coming_back") or [] if fid in (None, c["factory"])]
    week_end = time.strftime("%Y-%m-%d", time.gmtime(now + 7 * 86400))
    soon = [c for c in later if c["until"] <= week_end]
    rest = later[len(soon):]
    oldest = next((o["since"] for o in older if o.get("since")), None)
    coming = {"heading": "", "rest": "", "items": soon, "after": ""}
    if later:
        coming["heading"] = ("%s %s back this week" % (plural(len(soon), "thing", "things"),
                                                       "comes" if len(soon) == 1 else "come")
                             if soon else "Nothing comes back this week")
        if rest:
            coming["rest"] = "%d %s put off to %s." % (len(rest), ("more " if soon else "") +
                                                       ("is" if len(rest) == 1 else "are"),
                                                       "a later date" if len(rest) == 1 else "later dates")
            coming["after"] = ("After that, the next is on %s." if soon else "The next is on %s.") % (
                day_words(rest[0]["until"]))
    return {"older": older,
            "older_heading": "%s %s still open" % (plural(len(older), "older question", "older questions"),
                                                   "is" if len(older) == 1 else "are") if older else "",
            "older_note": ("%s Needs you after waiting with no date set" % ("It left" if len(older) == 1 else "They left") +
                           (", %s since %s." % ("waiting" if len(older) == 1 else "the oldest", day_words(oldest))
                            if oldest else ".")) if older else "",
            "coming": coming}


OLDER_ASKED = {"revive": "you asked to bring it back", "drop": "you said it is no longer needed"}


def axi_backlog(home: str) -> Dict[str, Any]:
    """The backlog as the home's tasks-axi adapter reads it (`fm-fleet-snapshot.sh --axi-backlog`)."""
    state = os.path.join(home, "state")
    read = subprocess.run(["bash", os.path.join(BIN, "fm-fleet-snapshot.sh"), "--axi-backlog"],
                          capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL,
                          env=dict(os.environ, FM_HOME=home, FM_STATE_OVERRIDE=state))
    try:
        backlog = json.loads(read.stdout) if read.returncode == 0 else None
    except ValueError:
        backlog = None
    if not isinstance(backlog, dict):
        raise RuntimeError("could not read what waits on the owner")
    return backlog


def owner_calls(home: str, buckets: Dict[str, str], backlog: Optional[Dict[str, Any]] = None
                ) -> Tuple[List[str], List[str], List[Dict[str, Any]], List[Dict[str, str]]]:
    """The owner's calls, from fm_owner_calls in bin/fm-fleet-status-lib.sh.

    That function is the one definition of what really waits on the owner, the
    count the bridge strip and the tap page show too: the held decisions that
    wait on him now, and the PRs and ready branches waiting for his merge word.
    Its decisions come from the backlog as the home's tasks-axi adapter reads it
    (axi_backlog, read here unless the caller already did) and handed over with
    the buckets the pane already read; those records come back too, so a held
    decision the markdown snapshot lacks can still be drawn. Last come the PRs
    a second mate has ready for the owner's merge word, each as its mate, its child
    and its URL (fm_secondmate_ready_prs there).
    """
    state = os.path.join(home, "state")
    if backlog is None:
        backlog = axi_backlog(home)
    with tempfile.TemporaryDirectory(prefix="fm-factory-calls.") as tmp:
        bucket_file = os.path.join(tmp, "buckets")
        backlog_file = os.path.join(tmp, "backlog.json")
        with open(bucket_file, "w", encoding="utf-8") as handle:
            for task_id, bucket in buckets.items():
                handle.write("%s\t%s\n" % (task_id, bucket))
        with open(backlog_file, "w", encoding="utf-8") as handle:
            json.dump(backlog, handle)
        script = '. "$1/fm-fleet-status-lib.sh" && fm_owner_calls "$2" "$3" "$4"'
        out = subprocess.run(["bash", "-c", script, "fm-factory", BIN, state,
                              bucket_file, backlog_file], capture_output=True, text=True, timeout=60)
    if out.returncode != 0:
        raise RuntimeError("could not read what waits on the owner")
    decisions, merges, mate_prs = [], [], []
    for line in out.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) >= 2 and parts[0] == "decision":
            decisions.append(parts[1])
        elif len(parts) >= 2 and parts[0] == "merge":
            merges.append(parts[1])
        elif len(parts) >= 4 and parts[0] == "mate-merge":
            at = parts[4] if len(parts) >= 5 else ""
            mate_prs.append({"mate": parts[1], "child": parts[2], "url": parts[3],
                             "since": int(at) if at.isdigit() else None})
    records = [r for r in backlog.get("records") or [] if r.get("structured") and r.get("id")]
    return decisions, merges, records, mate_prs


def decision_shapes(home: str, ids: List[str]) -> Dict[str, Dict[str, Any]]:
    """Each held decision's options and recommendation, as its tap card shows them.

    bin/fm-tap-desk.sh shapes owns that reading, including the options and the
    recommendation `fm-tap-desk.sh mark` records. A decision it cannot read is
    simply missing here and is shown as its plain question.
    """
    if not ids:
        return {}
    seam = os.environ.get("FM_FACTORY_SHAPES")
    cmd = shlex.split(seam) if seam else ["bash", os.path.join(BIN, "fm-tap-desk.sh"), "shapes"]
    try:
        out = subprocess.run(cmd + ids, capture_output=True, text=True, timeout=60,
                             env=dict(os.environ, FM_HOME=home))
        data = json.loads(out.stdout) if out.returncode == 0 and out.stdout.strip() else {}
    except (OSError, subprocess.SubprocessError, ValueError):
        return {}
    shapes = {}
    for shape in data.get("decisions") or []:
        if isinstance(shape, dict) and shape.get("id") in ids:
            shapes[shape["id"]] = shape
    return shapes


def shapes_for(home: str, ids: List[str], rows: Dict[str, Dict[str, Any]],
               known: Optional[Dict[str, Dict[str, Any]]]) -> Dict[str, Dict[str, Any]]:
    """decision_shapes for <ids>, reusing a shape in <known> while its question is unchanged.

    A shape read for a question is kept only while that question still has the
    hold stamp it was read under; a question held again reads its shape anew.
    Shapes read here are added to <known>, so the caller can keep them.
    """
    if known is None:
        return decision_shapes(home, ids)
    shapes = {}
    for ident in ids:
        shape = known.get(ident)
        held = parse_iso((rows.get(ident) or {}).get("hold_set"))
        if shape and held is not None and parse_iso(shape.get("held_since")) == held:
            shapes[ident] = shape
    missing = [ident for ident in ids if ident not in shapes]
    fetched = decision_shapes(home, missing)
    known.update(fetched)
    shapes.update(fetched)
    return shapes


def read_calls(home: str, buckets: Dict[str, str], backlog: Optional[Dict[str, Any]],
               known_shapes: Optional[Dict[str, Dict[str, Any]]]
               ) -> Tuple[List[str], List[str], List[Dict[str, Any]], Dict[str, Dict[str, Any]],
                          List[Dict[str, str]]]:
    """owner_calls, plus the shapes of its held decisions (shapes_for)."""
    decision_ids, merge_ids, adapter_rows, mate_prs = owner_calls(home, buckets, backlog)
    shapes = shapes_for(home, decision_ids, {r["id"]: r for r in adapter_rows}, known_shapes)
    return decision_ids, merge_ids, adapter_rows, shapes, mate_prs


def ready_reports(rows: List[Tuple[str, str, str]]) -> List[bool]:
    """Whether each ship `done:` line is its ready report, not a handoff to the checks.

    fm_dod_should_gate_ship_done in bin/fm-dod-lib.sh owns that reading, the one
    the status bar counts with. Each row is (kind, mode, status line).
    """
    if not rows:
        return []
    script = (
        '. "$1/fm-classify-lib.sh" && . "$1/fm-dod-lib.sh" || exit 1\n'
        'while IFS="$(printf "\\037")" read -r kind mode line; do\n'
        '  if fm_dod_should_gate_ship_done "$kind" "$mode" "$line"; then echo yes; else echo no; fi\n'
        'done\n'
    )
    text = "".join("%s\x1f%s\x1f%s\n" % tuple(c.replace("\x1f", " ").replace("\n", " ") for c in row) for row in rows)
    try:
        out = subprocess.run(["bash", "-c", script, "fm-factory", BIN], input=text,
                             capture_output=True, text=True, timeout=60)
        answers = out.stdout.split()
    except (OSError, subprocess.SubprocessError):
        answers = []
    return [index < len(answers) and answers[index] == "yes" for index in range(len(rows))]


def delivered_ids(rows: List[Dict[str, Any]]) -> set:
    """The closed work items that are deliveries: a merged change, a report, or a local landing.

    landed_delivery in bin/fm-landed-lib.sh owns that reading, the one Recently
    Landed is selected with. When it cannot be asked, a row's own completion
    word (merged or reported) is the evidence.
    """
    rows = [r for r in rows if r.get("state") == "done" and r.get("id")]
    if not rows:
        return set()
    script = '. "$1/fm-landed-lib.sh" && jq -r "$FM_LANDED_JQ_DEFS .[] | select(landed_delivery) | .id"'
    try:
        out = subprocess.run(["bash", "-c", script, "fm-factory", BIN], input=json.dumps(rows),
                             capture_output=True, text=True, timeout=30)
        if out.returncode == 0:
            return set(out.stdout.split("\n")) - {""}
    except (OSError, subprocess.SubprocessError):
        pass
    return {r["id"] for r in rows if (r.get("completion") or {}).get("verb") in ("merged", "reported")}


TASK_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
REPORT_PATH_RE = re.compile(r"[~\w./-]+\.md\b")


def read_sources(home: str, ident: str, mentions: Tuple[Any, ...] = ()) -> List[str]:
    """What Read opens for one item: its task id when the task has a report or a
    page of its own, then each other report under the home's data/ its words name.

    bin/fm-read.sh owns which page that opens: the task's own page.html first,
    else every source rendered into one reading page.
    """
    data = os.path.realpath(os.path.join(home, "data"))
    sources: List[str] = []
    seen = set()
    if TASK_ID_RE.match(ident or ""):
        folder = os.path.join(data, ident)
        if os.path.isfile(os.path.join(folder, "report.md")) or os.path.isfile(os.path.join(folder, "page.html")):
            sources.append(ident)
            seen.add(os.path.join(folder, "report.md"))
    for text in mentions:
        for match in REPORT_PATH_RE.finditer(text if isinstance(text, str) else ""):
            path = os.path.expanduser(match.group(0))
            real = os.path.realpath(path if os.path.isabs(path) else os.path.join(home, path))
            if real.startswith(data + os.sep) and real not in seen and os.path.isfile(real):
                seen.add(real)
                sources.append(real)
    return sources


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

    def peek_one(task_id: str) -> str:
        try:
            out = subprocess.run(shlex.split(peek) + [task_id, "15"], capture_output=True, text=True,
                                 timeout=10, env=dict(os.environ, FM_HOME=home))
            return out.stdout if out.returncode == 0 else ""
        except (OSError, subprocess.SubprocessError):
            return ""

    # Each peek reads one pane; they run side by side rather than one after another.
    texts = side_by_side(*[(lambda t=task_id: peek_one(t)) for task_id in running_ids]) if peek else []
    for index, task_id in enumerate(running_ids):
        old = seen.get(task_id) or {}
        if peek:
            text = texts[index]
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


def captain_hold_cmd() -> List[str]:
    seam = os.environ.get("FM_FACTORY_CAPTAIN_HOLD")
    return shlex.split(seam) if seam else ["bash", os.path.join(BIN, "fm-captain-hold.sh")]


def reconcile_pending(home: str) -> Dict[str, int]:
    """Each pending reconcile request: task id -> when it was requested.

    bin/fm-captain-hold.sh owns the request record and `reconcile list` is its
    read; a request leaves it when Starship closes the call with evidence,
    notes it, or records an answer.
    """
    try:
        out = subprocess.run(captain_hold_cmd() + ["reconcile", "list"], capture_output=True, text=True,
                             timeout=20, stdin=subprocess.DEVNULL, env=dict(os.environ, FM_HOME=home))
    except (OSError, subprocess.SubprocessError):
        return {}
    if out.returncode != 0:
        return {}
    pending = {}
    for line in out.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) >= 2 and parts[1].startswith("requested="):
            at = parse_iso(parts[1][len("requested="):])
            if at is not None:
                pending[parts[0]] = at
    return pending


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

# A work item's own id alone in brackets, such as (shop-plans-page-p1), or a
# revision mark such as (r2): names the fleet files work under, which tell the
# owner nothing. Any other bracketed words, (v2) or (x2), are the writer's own.
INTERNAL_NAME = r"\(\s*(?:(?:[a-z0-9]+-){2,}[a-z]{1,2}\d{1,3}|r\d{1,2})\s*\)"


def file_path(match: "re.Match[str]") -> str:
    """A path under the home, such as data/x/report.md or src/photos/, left out; words with a slash, such as and/or, stay."""
    token = match.group(0)
    path = token.rstrip(".")           # a sentence's own full stop is not the path's
    if path.endswith("/") or re.search(r"\.[A-Za-z][A-Za-z0-9]{0,4}$", path.rsplit("/", 1)[-1]):
        return token[len(path):]
    return token


def card_words(text: Optional[str]) -> str:
    """Card text, a call's title, reason and suggestion, without file paths or a work item's id or revision mark in brackets.

    A web address stays as written, so a screen can still offer its link.
    """
    parts = re.split(r"(https?://\S+)", text or "")
    for index in range(0, len(parts), 2):
        part = re.sub(r"(?<![\w.])(?:~|/)[\w.@+-]*(?:/[\w.@+-]+)+/?", "", parts[index])
        # A path under the home: its first part holds no dot, so a web address written without its scheme is none.
        part = re.sub(r"(?<![\w./~@+-])[\w@+-]+(?:/[\w.@+-]+)+/?", file_path, part)
        parts[index] = re.sub(INTERNAL_NAME, "", part)
    text = re.sub(r"\(\s*[,;]?\s*\)", "", "".join(parts))
    text = re.sub(r"\s+([,.;:])", r"\1", text)
    return re.sub(r"\s+", " ", text).strip(" ,;:")


def tidy(text: Optional[str], limit: Optional[int] = 170) -> str:
    """Prose for the screen: no paths, links or run ids, and with a limit, one or two sentences."""
    text = text or ""
    text = re.sub(r"https?://\S+", "", text)
    text = re.sub(r"(?<![\w.])(?:~|/)[\w.@+-]*(?:/[\w.@+-]+)+/?", "", text)
    text = re.sub(r"\b(?:run|commit)\s+[0-9A-Za-z]{7,}\b", "", text)
    text = re.sub(r"\(\s*[,;]?\s*\)", "", text)
    text = re.sub(r"\(\s*[,;]\s*", "(", text)
    text = re.sub(r"\s+([,.;:])", r"\1", text)
    text = re.sub(r"\s+", " ", text).strip(" ,;:")
    if limit and len(text) > limit:
        cut = text[:limit]
        end = max(cut.rfind(". "), cut.rfind("; "))
        text = (cut[:end + 1] if end > limit // 2 else cut.rsplit(" ", 1)[0] + "…").strip()
    return text


def plain_words(value: Any) -> str:
    """Text to show, or nothing: a missing value never prints as None or null."""
    text = value if isinstance(value, str) else ""
    return "" if text.strip().lower() in ("", "none", "null", "-", "undefined") else text


# The short plain section a PR opens with (.github/pull_request_template.md),
# shown beside the merge choice: its four parts, in this order.
PR_SUMMARY_PARTS = ("In short", "See it", "You need to", "Risk")
# How long a PR's short section is kept before it is read again.
PR_SUMMARY_KEEP = 1800


def pr_summary(body: Optional[str]) -> List[Dict[str, str]]:
    """The In short, See it, You need to and Risk lines of a PR description, each as plain words.

    A part is the text under its heading up to the next heading or the folded
    technical detail, with the template's comments left out; a part that is
    missing or empty is left out, so a PR opened without the template shows none.
    """
    text = re.sub(r"<!--.*?(?:-->|$)", "", body or "", flags=re.S)
    parts: Dict[str, List[str]] = {}
    current: Optional[str] = None
    for line in text.splitlines():
        if re.match(r"\s*<details\b", line, re.I):
            break
        heading = re.match(r"\s{0,3}#{1,3}\s+(.+?)\s*#*\s*$", line)
        if heading:
            name = heading.group(1).strip().lower()
            current = name if name not in parts else None
            if current is not None:
                parts[current] = []
            continue
        if current is not None:
            parts[current].append(re.sub(r"^\s*(?:[-*+]|\d+\.)\s+", "", line).strip())
    summary = []
    for label in PR_SUMMARY_PARTS:
        words = re.sub(r"\*\*|__|`", "", " ".join(parts.get(label.lower()) or []))
        # A link or a screenshot reads as its own words, not as half-written markdown.
        words = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", words)
        words = tidy(words, 240)
        if words:
            summary.append({"label": label, "text": words})
    return summary


def pr_command(seam_name: str, url: str, field: str) -> Optional[List[str]]:
    """The command that prints one field of a PR (<seam_name> stands in for it), or None when it is not read."""
    seam = os.environ.get(seam_name)
    if seam is not None:
        return shlex.split(seam) + [url] if seam.strip() else None
    if not re.match(r"https://github\.com/[^/\s]+/[^/\s]+/pull/\d+$", url):
        return None
    return ["gh", "pr", "view", url, "--json", field, "--jq", "." + field]


def pr_body_command(url: str) -> Optional[List[str]]:
    """The command that prints a PR's description, or None when it is not read."""
    return pr_command("FM_FACTORY_PR_BODY", url, "body")


def pr_merged_command(url: str) -> Optional[List[str]]:
    """The command that prints when a PR was merged, or None when it is not read."""
    return pr_command("FM_FACTORY_PR_MERGED", url, "mergedAt")


def kept_pr_reads(home: str, name: str, urls: List[str], now: int, command, parse, key: str,
                  settled=lambda value: False) -> Dict[str, Any]:
    """One reading of each PR, kept in state/factory/<name>: for PR_SUMMARY_KEEP, or for good once <settled>.

    A PR that cannot be read is kept as read empty for the same time, so a
    rebuild never waits on it again and again; the reads run side by side.
    """
    path = os.path.join(pane_dir(home), name)
    try:
        kept = json.loads(read_text(path, 8_000_000) or "{}")
    except ValueError:
        kept = {}
    kept = kept if isinstance(kept, dict) else {}
    wanted = sorted(set(u for u in urls if u))
    fresh = {u: kept[u] for u in wanted if isinstance(kept.get(u), dict) and isinstance(kept[u].get("at"), int)
             and (settled(kept[u].get(key)) or 0 <= now - kept[u]["at"] < PR_SUMMARY_KEEP)}
    stale = [u for u in wanted if u not in fresh and command(u)]

    def read(url: str) -> Dict[str, Any]:
        try:
            out = subprocess.run(command(url) or ["false"], capture_output=True, text=True, timeout=15,
                                 stdin=subprocess.DEVNULL)
            text = out.stdout if out.returncode == 0 else ""
        except (OSError, subprocess.SubprocessError):
            text = ""
        return {"at": now, key: parse(text)}

    if stale:
        for url, entry in zip(stale, side_by_side(*[(lambda u=u: read(u)) for u in stale])):
            fresh[url] = entry
    if stale or set(kept) - set(fresh):
        try:
            write_atomic(path, json.dumps(fresh))
        except OSError:
            pass
    return {u: e.get(key) for u, e in fresh.items()}


def pr_summaries(home: str, urls: List[str], now: int) -> Dict[str, List[Dict[str, str]]]:
    """Each PR's short section, read once and kept in state/factory/pr-summaries.json for PR_SUMMARY_KEEP."""
    read = kept_pr_reads(home, "pr-summaries.json", urls, now, pr_body_command, pr_summary, "summary")
    return {u: list(value or []) for u, value in read.items()}


def merge_times(home: str, urls: List[str], now: int) -> Dict[str, Optional[int]]:
    """When each merged PR was merged, kept in state/factory/merged-at.json for good once known."""
    return kept_pr_reads(home, "merged-at.json", urls, now, pr_merged_command,
                         lambda text: parse_iso(text.strip() or None), "merged",
                         settled=lambda value: isinstance(value, int))


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
    return "checks running"


def held_state(row: Dict[str, Any], today: str = "") -> str:
    """The state word for work held back by its hold rather than waiting on the owner."""
    until = row.get("hold_until")
    if until and (row.get("hold_bucket") == "dated" or (row.get("hold_kind") != "captain" and until > today > "")):
        return "on hold until %s" % until
    if row.get("hold_bucket") == "blocked" or row.get("unresolved_blocker_ids"):
        return "waits on other work"
    return "on hold"


QUEUE_WORDS = ("starts on its own", "parked", "in line", "on hold", "waits on other work", "waits on you",
               "older call", "deferred")


def queue_word(row: Dict[str, Any], asked: bool, today: str) -> Optional[str]:
    """Where a work item nobody has started stands in the queue, as one of QUEUE_WORDS.

    A decision held for the owner waits on you; it is deferred while its date
    is still ahead, an older call once it has waited undated past the
    snapshot's age, and it waits on other work while a blocker of it is still
    open, since it cannot be decided before then. Work parked until a date
    still ahead is parked: it is looked at again on that date and never starts
    by itself (its date is the job's parked_until). Anything else starts on its
    own when it waits on other work or on a date still ahead, is on hold when
    it is held with neither, and is in line when nothing is set to start it.
    Work listed as in flight with no worker is not queued.
    """
    if asked:
        return "waits on you"
    if row.get("hold_kind") == "captain":
        if row.get("hold_bucket") == "blocked" or row.get("unresolved_blocker_ids"):
            return "waits on other work"
        return {"dated": "deferred", "aged": "older call"}.get(row.get("hold_bucket"), "waits on you")
    if row.get("hold_kind") == "parked" and (row.get("hold_until") or "") > today:
        return "parked"
    if row.get("unresolved_blocker_ids"):
        return "starts on its own"
    if row.get("hold_kind"):
        return "starts on its own" if (row.get("hold_until") or "") > today else "on hold"
    return None if row.get("state") == "in_flight" else "in line"


def queue_counts(jobs: List[Dict[str, Any]]) -> Dict[str, Any]:
    """The queue of these jobs as counts; the ones waiting on you include the older calls and the deferred.

    The parked are counted once in all and once per date they are parked until, soonest first.
    """
    words = [j["queue"] for j in jobs if j.get("queue")]
    dates = sorted(j.get("parked_until") or "" for j in jobs if j.get("queue") == "parked")
    return {"total": len(words), "starts_on_its_own": words.count("starts on its own"),
            "parked": len(dates),
            "parked_until": [{"until": date or None, "count": dates.count(date)} for date in sorted(set(dates))],
            "in_line": words.count("in line"), "on_hold": words.count("on hold"),
            "waits_on_other_work": words.count("waits on other work"),
            "waits_on_you": words.count("waits on you") + words.count("older call") + words.count("deferred"),
            "deferred": words.count("deferred"), "older": words.count("older call")}


def parked_words(count: int, dates: List[Optional[str]]) -> str:
    """The parked as one count: until their one date, or the soonest of their dates."""
    known = sorted({d for d in dates if d})
    if not known:
        return "%d parked" % count
    if len(set(dates)) == 1:
        return "%d parked until %s" % (count, day_words(known[0]))
    return "%d parked, soonest %s" % (count, day_words(known[0]))


def queue_parts(queue: Dict[str, Any]) -> List[Tuple[str, str]]:
    """The queue's counts in words, each with the word it stands for (see queue_counts)."""
    if not queue.get("total"):
        return [("total", "nothing queued")]
    parts = [("total", "%d queued" % queue["total"])]
    own, wait, deferred = queue["starts_on_its_own"], queue["waits_on_you"], queue["deferred"]
    if own:
        parts.append(("starts_on_its_own", "1 starts on its own" if own == 1 else "%d start on their own" % own))
    if queue.get("parked"):   # a record from before parked work was counted has none
        parts.append(("parked", parked_words(queue["parked"], [g["until"] for g in queue["parked_until"]])))
    if queue["in_line"]:
        parts.append(("in_line", "%d in line" % queue["in_line"]))
    if queue["on_hold"]:
        parts.append(("on_hold", "%d on hold" % queue["on_hold"]))
    other = queue.get("waits_on_other_work") or 0   # a record from before this was counted has none
    if other:
        parts.append(("waits_on_other_work", "1 waits on other work" if other == 1
                      else "%d wait on other work" % other))
    if wait:
        words = "1 waits on you" if wait == 1 else "%d wait on you" % wait
        if deferred and deferred == wait:
            words += ", deferred to a date" if wait == 1 else ", all deferred to a date"
        elif deferred:
            words += ", %d of them deferred to a date" % deferred
        parts.append(("waits_on_you", words))
    return parts


# How a factory's page counts the jobs it folds away, per queue word: one and many.
FOLD_NAMES = {"in line": ("more lined up", "more lined up"),
              "starts on its own": ("starts on its own", "start on their own"),
              "on hold": ("on hold", "on hold"),
              "waits on other work": ("waits on other work", "wait on other work"),
              "waits on you": ("more waits on you", "more wait on you"),
              "older call": ("older call waits on you", "older calls wait on you"),
              "deferred": ("deferred to a date", "deferred to a date")}


def job_queue_words(job: Dict[str, Any]) -> str:
    """A queued job's queue word as the pane says it: a parked job says until when."""
    if job.get("queue") == "parked":
        return "parked until %s" % day_words(job["parked_until"]) if job.get("parked_until") else "parked"
    return job.get("queue") or "in line"


def fold_parts(folded: Dict[str, List[Dict[str, Any]]]) -> List[Tuple[str, List[Dict[str, Any]]]]:
    """The folded jobs as counts in words, each with the jobs it stands for; the parked soonest first."""
    parts: List[Tuple[str, List[Dict[str, Any]]]] = []
    for word, jobs in folded.items():
        if not jobs:
            continue
        if word == "parked":
            jobs = sorted(jobs, key=lambda j: j.get("parked_until") or "")
            parts.append((parked_words(len(jobs), [j.get("parked_until") for j in jobs]), jobs))
            continue
        parts.append((plural(len(jobs), *FOLD_NAMES[word]), jobs))
    return parts


def request_id_of(text: str) -> str:
    """A captain inbox request id: the characters the inbox takes, at most 128 of them."""
    return re.sub(r"[^A-Za-z0-9._:-]", "-", text)[:128]


ROUTINE_QUIET_WORDS = ("finished", "report ready", "PR ready", "went live", "closed", "settled")


def routine_folds(job: Dict[str, Any]) -> bool:
    """Whether a routine job folds into its factory's routine line: only while it runs as expected or waits."""
    return bool(job.get("routine")) and (job["state"] == "waiting" or (job["state"] == "busy"
                                                                       and not job.get("quiet")))


def routine_lines(factory: Dict[str, Any],
                  runs: Dict[Tuple[str, str], Dict[str, List[Tuple[int, str]]]]) -> List[Dict[str, Any]]:
    """One line per routine kind of a factory: its runs today, the last of them, and what it folds."""
    lines = []
    for kind in factory["routine"]:
        today = runs.get((factory["id"], kind), {})
        folded = [j for j in factory["jobs"] if j.get("routine") == kind and routine_folds(j)]
        if not today and not folded:
            continue
        marks = [mark for task_marks in today.values() for mark in task_marks]
        last = max(marks) if marks else None
        lines.append({"kind": kind, "today": len(today),
                      "last": last[0] if last else None, "last_word": last[1] if last else None,
                      "running": len([j for j in folded if j["state"] == "busy"]),
                      "folded": [j["id"] for j in folded]})
    return lines


RESOLUTION_RE = re.compile(r"^Resolution recorded by fm-(captain|decision)-hold\.$")


def recorded_answer(lines: Any) -> str:
    """What the owner answered on a closed call, from its resolution record (bin/fm-captain-hold.sh answer).

    Records are prepended, so the newest is the first, up to the next one; only
    its words under `Captain decision:` are the owner's, and a captured answer
    names the option as it was shown, which reads better than its key.
    """
    lines = [str(line).strip() for line in lines or [] if isinstance(line, str)]
    starts = [i for i, line in enumerate(lines) if RESOLUTION_RE.match(line)]
    if not starts:
        return ""
    record = lines[starts[0] + 1:starts[1] if len(starts) > 1 else len(lines)]
    labels = [line for line in record if line in ("Captain decision:", "Reconciliation evidence:")]
    if labels[:1] != ["Captain decision:"]:
        return ""
    block = [line for line in record[record.index("Captain decision:") + 1:] if line]
    shown = next((line.split(":", 1)[1] for line in block if line.startswith("Answer as shown to the captain:")), None)
    if shown is not None:
        words = shown.rsplit(" -> ", 1)[0]
    else:
        words = next((line.split(":", 1)[1] for line in block if line.startswith("Answer:")), None) or \
            next((line for line in block if not line.startswith("Captain answered this")), "")
    return tidy(card_words(words.strip()), 200)


def report_time(home: str, row: Dict[str, Any]) -> Optional[int]:
    """When a closed work item's report was written: its file's time, or None without one."""
    data = os.path.join(home, "data")
    paths = [os.path.join(data, row["id"], "report.md")] if TASK_ID_RE.match(row.get("id") or "") else []
    if row.get("report_path"):
        path = os.path.expanduser(str(row["report_path"]))
        paths.append(path if os.path.isabs(path) else os.path.join(home, path))
    for path in paths:
        stamp = mtime(path)
        if stamp is not None:
            return stamp
    return None


def build_record(home: str, now: int, snapshot: Dict[str, Any], since: Optional[int] = None,
                 activity: Optional[Dict[str, int]] = None, notes: Optional[List[Dict[str, Any]]] = None,
                 backlog: Optional[Dict[str, Any]] = None,
                 known_shapes: Optional[Dict[str, Dict[str, Any]]] = None,
                 buckets: Optional[Dict[str, str]] = None,
                 reconciles: Optional[Dict[str, int]] = None,
                 overview: Optional[Dict[str, Any]] = None,
                 calls: Optional[Tuple[List[str], List[str], List[Dict[str, Any]], Dict[str, Dict[str, Any]],
                                       List[Dict[str, str]]]] = None
                 ) -> Dict[str, Any]:
    """The pane's record. <calls> is read_calls already taken on these same buckets
    and backlog, so a caller can read it beside other slow reads; without it,
    it is read here, on the merges <overview>'s ready work names
    (overview_call_buckets)."""
    factories, registry_source = load_registry(home)
    project_rows = load_projects(home)
    quiet_after = env_int("FM_FACTORY_QUIET_MINUTES", 15) * 60
    activity = activity or {}
    notes = notes or []
    reconciles = reconciles or {}
    settled_notes: Dict[str, int] = {}
    for note in notes:
        named = re.match(r"factory\.[^.]+\.settled\.(.+)\.(\d+)$", note.get("request_id") or "")
        if named:
            settled_notes[named.group(1)] = max(settled_notes.get(named.group(1), 0), int(named.group(2)))
    since_from = "last look"
    if since is None:
        since, since_from = now - LOOK_BACK_DEFAULT, "12 hours"
    if since < now - LOOK_BACK_MAX:
        since, since_from = now - LOOK_BACK_MAX, "48 hours"

    # Project name (and alias) -> factory id.
    owner_of = project_owner(factories, project_rows)
    other = {"name": "Other work", "id": "other-work", "about": "work no factory claims", "projects": [],
             "rules": [], "learned": [], "routine": []}

    def factory_of(project: Optional[str]) -> str:
        claimed = owner_of(project)
        if claimed:
            return claimed
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
    history = bool(rows)
    tasks = live_tasks(snapshot)
    if buckets is None:
        buckets = buckets_for(tasks)
    # NEEDS YOU is exactly the owner's calls, the one count the bridge strip and
    # the tap page show; a worker's question, a pause or the checks never are.
    # Its merges are the overview reading's ready work (overview_call_buckets).
    ready_list = overview_ready_list(overview)
    if calls is None:
        calls = read_calls(home, overview_call_buckets(overview, buckets), backlog, known_shapes)
    decision_ids, merge_ids, adapter_rows, shapes, mate_prs = calls
    # The tasks the overview reads as stopped, the ones behind the bridge
    # strip's "N stopped", so the job that stopped says so on its row.
    lost = set(overview_counts(overview, 0)["lost_list"])
    known = {r["id"] for r in rows}
    # The adapter is the backlog's own reading of what is held and what still
    # waits on other work, the one the owner's calls are counted from. The
    # markdown reading cannot tell a blocker that was finished and archived
    # from one still open, so for open work the adapter's reading wins.
    adapter = {r["id"]: r for r in adapter_rows}
    for row in rows:
        read = adapter.get(row["id"])
        if read and row.get("state") != "done":
            row.update({key: read[key] for key in ("hold_kind", "hold_until", "hold_bucket",
                                                   "unresolved_blocker_ids") if key in read})
    rows += [r for r in adapter_rows if r.get("hold_bucket") and r["id"] not in known]
    row_of = {r["id"]: r for r in rows}
    today = (iso(now) or "")[:10]
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
        # The options and recommendation are the ones its tap card shows; with
        # none recorded the question is shown plainly, never as a stand-in word.
        shape = shapes.get(row["id"]) or {}
        title = card_words(plain_words(shape.get("title")) or plain_words(row.get("title"))) or row["id"]
        question = plain_words(shape.get("question")) if shape else plain_words(row.get("hold_reason"))
        labels = [plain_words(o) for o in shape.get("options") or []]
        labels = [label for label in labels if label][:9]
        recommended = plain_words(shape.get("recommended_option"))
        options = [{"key": str(index + 1), "label": tidy(label, 240), "suggested": label == recommended}
                   for index, label in enumerate(labels)]
        recommendation = plain_words(shape.get("recommendation"))
        if any(o["suggested"] for o in options) or recommendation in labels:
            recommendation = ""
        if options or recommendation:
            # The options and the suggestion get rows of their own below.
            cut = re.search(r"\b(?:Options?|Choose|Captain must choose|Recommend(?:ation|ed)?)\s*:", question, re.I)
            question = question[:cut.start()] if cut else question
        since_at = (parse_iso(shape.get("held_since")) or parse_iso(row.get("hold_set"))
                    or parse_iso(row.get("since")))
        # Checking while a reconcile request is pending and it, or a settled
        # note the pane sent for it, is from since the call was last held.
        requested = reconciles.get(row["id"])
        checking = requested is not None and (since_at is None or requested >= since_at
                                              or settled_notes.get(row["id"], -1) >= since_at)
        return {"id": row["id"], "factory": fid, "kind": "question", "ask": title, "title": title,
                "why": tidy(card_words(question), None), "options": options,
                "suggested_by": "Starship" if any(o["suggested"] for o in options) else None,
                "recommendation": tidy(card_words(recommendation), None) or None,
                "holds_up": holds_up(row["id"]), "since": since_at, "for": "you", "pr": row.get("pr_url"),
                "checking": checking,
                "read": read_sources(home, row["id"], (row.get("hold_reason"), shape.get("question")))}

    # Live work: every task with metadata whose work item is not queued or done.
    unverified_alive = alive_ids([t for t in tasks if not buckets.get(t["id"])
                                  and (t.get("current_state") or {}).get("source") == "run-step"
                                  and (t.get("current_state") or {}).get("state") == "unknown"])
    running_ids = []
    for task in tasks:
        row = row_of.get(task["id"])
        if row and row.get("state") in ("queued", "done") and task["id"] not in merge_ids:
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
                               "until": None, "pr": (task.get("pr") or {}).get("url"), "queue": None,
                               "parked_until": None, "look": None,
                               "routine": routine_kind(by_id[fid]["routine"], title),
                               "read": read_sources(home, task["id"], ((row or {}).get("hold_reason"),))}
        if task["id"] in merge_ids:
            bucket = "ready"
        if bucket == "working":
            job.update(state="busy", step="planning" if kind == "scout" else "building")
        elif bucket == "validating" or task["id"] in unverified_alive:
            # A run the fold reads validating (running, or parked short of a
            # decision), or an unknown run-step reading on a worker
            # _fm_fleet_liveness reads alive (which the overview counts busy)
            # reads busy at checking. A dead worker's unknown reading does not.
            job.update(state="busy", step="checking", doing=checking_sentence(detail), doing_from="checks")
        elif bucket == "decision":
            # A worker's question, or a review finding the checks put to
            # Starship (ask-user): Starship answers it or brings it to the owner
            # as a held decision, so it needs a look from Starship, as the
            # status bar counts it. Its row says which of the two it was.
            job.update(state="needs a look", look="checks" if state.get("source") == "run-step" else "question")
        elif bucket == "ready" and task["id"] not in merge_ids and not (row and row["id"] in decision_ids):
            # Held work waits on its hold; otherwise the shared overview has
            # not listed it as ready yet, so it stays busy at checking and
            # becomes ready to merge once the overview lists it.
            if row and (row.get("hold_kind") or row.get("hold_bucket")):
                job["state"] = held_state(row, today)
            else:
                job.update(state="busy", step="checking")
        elif bucket == "ready":
            job.update(state="ready to merge", step="ready to merge")
            pr = job["pr"]
            found = re.search(r"pr=(https?://\S+)", detail)
            if found:
                pr = found.group(1)
            done_at = [e["at"] for e in status_events(((task.get("paths") or {}).get("status_log") or {}).get("path"))
                       if e["verb"] == "done" and e["at"]]
            if task["id"] in merge_ids:
                needs.append({"id": task["id"], "factory": fid, "kind": "finished work",
                              "ask": "%s is ready to merge" % title, "title": title, "why": None,
                              "options": [], "suggested_by": None, "recommendation": None,
                              "holds_up": [], "since": done_at[-1] if done_at else None,
                              "for": "you", "pr": pr, "checking": False,
                              "read": read_sources(home, task["id"])})
        elif bucket == "finished":
            job.update(state="finished" if "PR merged" in detail else "with Starship")
        elif bucket == "paused":
            job.update(state="waiting")
            found = re.search(r"\buntil (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}Z)", detail)
            job["until"] = parse_iso(found.group(1)) if found else None
        elif bucket == "attention":
            if state.get("state") == "failed":
                job.update(state="failed")
            else:
                job.update(state="needs a look", look="stuck")   # a blocked worker asks Starship for help
        elif "gone" in detail or "dead" in detail:
            job.update(state="stopped")
        else:
            job.update(state="no reading")
        # A job the checks still carry is busy without its worker, so only one
        # with nothing carrying it reads stopped.
        if task["id"] in lost and job["state"] not in ("busy", "ready to merge", "finished", "with Starship"):
            job.update(state="stopped", step=None)
        if row and row["id"] in decision_ids:
            needs.append(hold_need(row, fid))
            if job["state"] in ("stopped", "no reading", "with Starship", "ready to merge", "needs a look"):
                job["state"] = "decision for you"
        if job["state"] != "needs a look":
            job["look"] = None   # what it waits on Starship for is said only while it does
        if job["state"] == "busy":
            running_ids.append(task["id"])
        by_id[fid]["jobs"].append(job)

    # A PR a second mate has ready for the owner's merge word is the owner's
    # call too, though the job is the mate's: it is listed beside this home's own, named by the
    # mate, in the factory of the PR's repository.
    for pr in mate_prs:
        found = re.match(r"https?://[^/]+/(?:[^/]+/)*?([^/]+)/(?:pull|-/merge_requests|merge_requests)/\d+",
                         pr["url"])
        needs.append({"id": "%s:%s" % (pr["mate"], pr["child"]),
                      "factory": factory_of(found.group(1) if found else None), "kind": "finished work", "ask": "%s is ready for you to look at" % pr["child"],
                      "title": pr["child"], "why": None, "options": [], "suggested_by": None,
                      "recommendation": None, "holds_up": [], "since": pr["since"], "for": "you",
                      "pr": pr["url"], "checking": False, "read": [], "mate": pr["mate"]})

    # Finished work shows its PR's short section beside the merge choice.
    summaries = pr_summaries(home, [n["pr"] for n in needs if n["kind"] == "finished work" and n.get("pr")], now)
    for need in needs:
        if need["kind"] == "finished work":
            need["summary"] = summaries.get(need.get("pr") or "", [])

    activity = dict(activity)
    seen_pane = activity
    for factory in factories:
        for job in factory["jobs"]:
            if job["state"] != "busy":
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
            if job["step"] != "checking" and job["last_sign_of_life"] and now - job["last_sign_of_life"] >= quiet_after:
                job["quiet"] = True

    # Queued work and held work items with no live worker. The owner's calls
    # that left NEEDS YOU go on its two shelves: an older question (undated,
    # waiting past the snapshot's age) and one put off to a date, which comes
    # back on that date.
    older: List[Dict[str, Any]] = []
    coming_back: List[Dict[str, Any]] = []
    for row in rows:
        if row["id"] in task_factory or row.get("state") == "done":
            continue
        fid = factory_of(row.get("repo"))
        title = row.get("title") or row["id"]
        titles[row["id"]] = title
        task_factory.setdefault(row["id"], fid)
        job = {"id": row["id"], "title": title, "kind": row.get("kind") or "task", "state": None, "step": None,
               "started": None, "doing": None, "doing_from": None, "last_sign_of_life": None,
               "sign_of_life_from": None, "quiet": False, "until": None, "pr": row.get("pr_url"),
               "queue": queue_word(row, row["id"] in decision_ids, today),
               "parked_until": None,
               "routine": routine_kind(by_id[fid]["routine"], title),
               "read": read_sources(home, row["id"], (row.get("hold_reason"),))}
        if job["queue"] == "parked":
            job["parked_until"] = row.get("hold_until")
        if job["queue"] == "older call":
            held = str(row.get("hold_set") or row.get("since") or "")[:10] or None
            older.append({"id": row["id"], "factory": fid, "title": card_words(plain_words(title)) or row["id"],
                          "since": held, "asking": held or "0"})
        elif job["queue"] == "deferred" and row.get("hold_until"):
            coming_back.append({"id": row["id"], "factory": fid,
                                "title": card_words(plain_words(title)) or row["id"], "until": row["hold_until"]})
        if row["id"] in decision_ids:
            job["state"] = "decision for you"
            needs.append(hold_need(row, fid))
        elif row.get("hold_kind"):
            job["state"] = held_state(row, today)
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
        order = {"busy": 0, "decision for you": 1, "ready to merge": 2, "failed": 3, "needs a look": 3,
                 "waiting": 4, "stopped": 5, "no worker": 5, "no reading": 5, "with Starship": 6, "finished": 6,
                 "next": 7, "later": 8}
        factory["jobs"].sort(key=lambda j: order.get(j["state"], 9))
        lined = [j for j in factory["jobs"] if j["state"] in ("next", "later", "decision for you")
                 and not any(n["id"] == j["id"] and n["kind"] == "finished work" for n in needs)]
        lined = [j for j in lined if j["state"] != "decision for you" or j["started"] is None]
        factory["next"] = None
        if lined:
            first = next((j for j in lined if j["state"] == "next"), lined[0])
            factory["next"] = {"id": first["id"], "title": first["title"],
                               "once_you_answer": first["state"] == "decision for you",
                               "then": len(lined) - 1}
        factory["queue"] = queue_counts(factory["jobs"])

    # The feed since the last look: outcomes and the owner's own calls, never a
    # worker's pause, a question a worker put to Starship, or a blocker.
    done_rows: List[Tuple[Dict[str, Any], str, Dict[str, str]]] = []
    # A routine job's runs today, per factory and routine kind: each task id
    # with the times it started, finished or failed.
    local_today = time.strftime("%Y-%m-%d", time.localtime(now))
    routine_of: Dict[str, str] = {}
    runs: Dict[Tuple[str, str], Dict[str, List[Tuple[int, str]]]] = {}

    def is_today(at: Optional[int]) -> bool:
        return bool(at) and time.strftime("%Y-%m-%d", time.localtime(at)) == local_today

    def note_run(fid: str, kind: str, task_id: str, at: Optional[int] = None, word: str = "") -> None:
        routine_of[task_id] = kind
        marks = runs.setdefault((fid, kind), {}).setdefault(task_id, [])
        if at:
            marks.append((at, word))

    for factory in factories:
        for job in factory["jobs"]:
            if job.get("routine") and job["started"] and is_today(job["started"]):
                note_run(factory["id"], job["routine"], job["id"], job["started"], "started")
            elif job.get("routine"):
                routine_of[job["id"]] = job["routine"]
    for task in snapshot.get("tasks") or []:
        task_id = task.get("id")
        if not task_id or task.get("kind") == "secondmate":
            continue
        fid = task_factory.get(task_id)
        if not fid:
            row = row_of.get(task_id)
            fid = factory_of((row or {}).get("repo") or os.path.basename((task.get("project") or "").rstrip("/")))
        meta = meta_values(((task.get("paths") or {}).get("meta") or {}).get("path"))
        title = titles.get(task_id) or title_of(task_id, meta)
        kind = routine_kind(by_id[fid]["routine"], title)
        if kind:
            routine_of[task_id] = kind
        for event in status_events(((task.get("paths") or {}).get("status_log") or {}).get("path")):
            verb, at = event["verb"], event["at"]
            if kind and verb in ("done", "failed") and at and at <= now and is_today(at):
                note_run(fid, kind, task_id, at, "finished" if verb == "done" else "failed")
            if not at or not since <= at <= now:
                continue
            base = {"at": at, "date": None, "actor": by_id[fid]["name"], "factory": fid, "job": task_id}
            if verb == "failed":
                feed.append(dict(base, word="failed", title=title, text="%s failed; Starship is on it." % title))
            elif verb == "done":
                done_rows.append((dict(base, title=title, line=event),
                                  task.get("kind") or meta.get("kind") or "ship", meta))
    # A ship's done is an outcome only when it is the ready report; the handoff
    # of a build into the checks is not, and a scout's report always is.
    gated = ready_reports([(kind, meta.get("mode", ""), "done: %s" % item["line"]["text"])
                           for item, kind, meta in done_rows if kind == "ship"])
    answers = iter(gated)
    for item, kind, _meta in done_rows:
        if kind == "ship" and not next(answers, False):
            continue
        text, title = item.pop("line")["text"], item["title"]
        if kind == "ship" and re.search(r"https?://\S+/(?:pull|merge_requests)/\d+", text):
            feed.append(dict(item, word="PR ready", text="%s has its PR ready." % title))
        elif kind == "ship":
            feed.append(dict(item, word="finished", text="%s is finished." % title))
        else:
            feed.append(dict(item, word="report ready", text=title, read=read_sources(home, item["job"])))
    for need in needs:
        if need["kind"] == "question" and need.get("since") and since <= need["since"] <= now:
            feed.append({"at": need["since"], "date": None, "actor": by_id[need["factory"]]["name"],
                         "factory": need["factory"], "job": need["id"], "word": "asked you",
                         "text": "%s needs your call." % need["title"]})
    # A closed work item is finished work only on the backlog's own evidence:
    # a merged change or a local landing went live, a report is ready, and one
    # closed with neither was only closed; a call of the owner's that was
    # closed is settled. Each of those rows leads with what happened and then
    # names the work, so its text is the title alone.
    finished_in_feed = {e["job"] for e in feed if e["word"] in ("finished", "report ready")}
    since_day = time.strftime("%Y-%m-%d", time.localtime(since))
    closed = [r for r in rows if r.get("state") == "done" and ((r.get("completion") or {}).get("date") or "") >= since_day]
    delivered = delivered_ids(closed)
    for row in closed:
        completion = row.get("completion") or {}
        title = row.get("title") or row["id"]
        fid = factory_of(row.get("repo"))
        kind = routine_kind(by_id[fid]["routine"], title)
        if kind:
            routine_of[row["id"]] = kind
            if completion.get("date") == local_today:
                note_run(fid, kind, row["id"])
        event = {"at": None, "date": completion["date"], "actor": by_id[fid]["name"], "factory": fid,
                 "job": row["id"], "title": title}
        if row["id"] not in delivered:
            if "captain" in (row.get("kind"), row.get("hold_kind")):
                # A settled call says what the owner answered, from its resolution record.
                answer = recorded_answer(row.get("body_lines"))
                event.update(word="settled", answer=answer,
                             text="%s%s You answered: %s" % (title, "" if title[-1:] in ".?!" else ".", answer)
                             if answer else title)
            else:
                event.update(word="closed", text="%s was closed; no change or report on record." % title)
        elif completion.get("verb") == "reported" or (row.get("kind") == "scout" and row.get("report_path")):
            if row["id"] in finished_in_feed:
                continue
            # A report's real time is when it was written, when that is since the start.
            event.update(word="report ready", text=title,
                         read=read_sources(home, row["id"], (row.get("report_path"),)))
            written = report_time(home, row)
            if written is not None and since <= written <= now:
                event["at"] = written
        else:
            event.update(word="went live", text=title, pr=row.get("pr_url"))
        feed.append(event)
    # A change that went live through a PR takes its real time from the PR's merge.
    merged = merge_times(home, [e["pr"] for e in feed if e["word"] == "went live" and e.get("pr")], now)
    for event in feed:
        at = merged.get(event.get("pr") or "") if event["word"] == "went live" else None
        if at is not None and since <= at <= now:
            event["at"] = at
    for at, fid, who in steer_log(home):
        if fid in by_id and since <= at <= now:
            feed.append({"at": at, "date": None, "actor": "you", "factory": fid, "job": None,
                         "word": "took the helm" if who == "you" else "handed back",
                         "text": ("You steer %s now." if who == "you" else "Starship steers %s again.")
                         % by_id[fid]["name"]})
    note_words = {"answer": "answered", "keep": "asked to keep", "change": "asked for changes", "talk": "said",
                  "settled": "asked to check", "revive": "asked to bring back", "drop": "said no longer needed"}
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
    # When the owner answered each call, and with which option, so an answered
    # call reads as answered until Starship has acted on it.
    for need in needs:
        stem = "factory.%s." % need["factory"]
        answers = {request_id_of("%sanswer.%s.%s.%s" % (stem, need["id"], asking(need), option["key"])): option["key"]
                   for option in need["options"]}
        answers[request_id_of("%skeep.%s.%s" % (stem, need["id"], asking(need)))] = None
        found = [{"at": parse_iso(note.get("at")), "key": answers[note.get("request_id")]}
                 for note in notes if note.get("request_id") in answers]
        need["answered"] = max(found, key=lambda item: item["at"] or 0) if found else None
    # A routine job's outcomes fold into its factory's routine line; a failed
    # run, and a call it put to the owner, still show as usual.
    feed = [e for e in feed if not (e.get("job") in routine_of and e["word"] in ROUTINE_QUIET_WORDS)]
    feed.sort(key=lambda e: (e["at"] if e["at"] is not None else (parse_iso(e["date"]) or 0)), reverse=True)
    # What moved since the last look, counted before the feed is cut short.
    news = {"went_live": len([e for e in feed if e["word"] == "went live"]),
            "report_ready": len([e for e in feed if e["word"] == "report ready"])}
    feed = feed[:FEED_CAP]

    # Most pressing first, in the one order fm_owner_calls gives the owner's
    # calls, so the first card is the most urgent call the bridge strip names.
    pressing = {ident: index for index, ident in enumerate(
        decision_ids + merge_ids + ["%s:%s" % (pr["mate"], pr["child"]) for pr in mate_prs])}
    needs.sort(key=lambda n: pressing.get(n["id"], len(pressing)))
    # Whether the owner already asked to bring an older question back or said it is no longer needed.
    for item in older:
        stem = "factory.%s." % item["factory"]
        kinds = {request_id_of("%s%s.%s.%s" % (stem, kind, item["id"], item["asking"])): kind
                 for kind in ("revive", "drop")}
        found = [{"at": parse_iso(note.get("at")), "what": kinds[note.get("request_id")]}
                 for note in notes if note.get("request_id") in kinds]
        item["asked"] = max(found, key=lambda mark: mark["at"] or 0) if found else None
    older.sort(key=lambda item: (item["since"] or "9999", item["title"]))
    coming_back.sort(key=lambda item: (item["until"], item["title"]))
    for factory in factories:
        factory["needs"] = [n["id"] for n in needs if n["factory"] == factory["id"]]
        running = [j for j in factory["jobs"] if j["state"] == "busy" and not routine_folds(j)]
        if factory["needs"]:
            factory["state"] = "needs you"
        elif running:
            factory["state"] = "at work"
        else:
            factory["state"] = "idle"
        factory["routine_runs"] = routine_lines(factory, runs)
        idle_marks = [e["at"] for e in feed if e["factory"] == factory["id"] and e["at"]] + \
            [line["last"] for line in factory["routine_runs"] if line["last"]]
        factory["idle_since"] = max(idle_marks) if factory["state"] == "idle" and idle_marks else None
        factory["crew"] = {"workers": len([j for j in factory["jobs"] if j["started"]]), "busy": len(running)}

    if other in factories and not other["jobs"] and not other["needs"]:
        factories.remove(other)
    idle_total = sum(1 for f in factories if f["state"] == "idle")
    queue = queue_counts([j for f in factories for j in f["jobs"]])
    counts = overview_counts(overview, idle_total)
    return {
        "schema": SCHEMA,
        "as_of": iso(now),
        "as_of_epoch": now,
        "since": iso(since),
        "since_epoch": since,
        "since_from": since_from,
        "home": home,
        "factories_from": registry_source,
        "counts": counts,
        "count_line": count_line_text(counts),
        "ready_list": ready_list,
        "queue": queue,
        "queue_line": " · ".join(words for _key, words in queue_parts(queue)),
        "needs_you": needs,
        "older": older,
        "coming_back": coming_back,
        "news": news,
        "factories": [{k: f[k] for k in ("id", "name", "about", "projects", "steered_by", "state",
                                         "idle_since", "crew", "needs", "jobs", "next", "queue", "rules",
                                         "learned", "talk", "routine", "routine_runs")}
                      | {"rules_size": profile_size(f["rules"])}
                      for f in factories],
        "rules_cap": PROFILE_CAP,
        "feed": feed,
        "history": history,
        "snapshot": {"generated": snapshot.get("generated"), "schema": snapshot.get("schema")},
    }


# --------------------------------------------------------------------------
# The cached record
# --------------------------------------------------------------------------

def read_looks(home: str) -> Tuple[Optional[int], Optional[int]]:
    """The newest sign of the owner looking, and when the look before it ended."""
    lines = read_text(os.path.join(pane_dir(home), "last-look"), 128).split()
    marks = [int(word) if word.isdigit() else None for word in lines[:2]] + [None, None]
    return marks[0], marks[1]


def last_look(home: str, now: int) -> Optional[int]:
    """Where New and the feed start: the end of the owner's last look.

    While a look is under way that is the end of the look before it, so
    pressing keys or keeping the pane focused never empties the list being
    read; once no sign of a look has come for LOOK_GAP, the look is over and
    its last sign is the start.
    """
    latest, previous = read_looks(home)
    if latest is None:
        return None
    return latest if now - latest > LOOK_GAP else previous


def note_look(home: str, now: int) -> None:
    """Record a sign of the owner looking at the pane now."""
    latest, previous = read_looks(home)
    if latest is not None and now - latest > LOOK_GAP:
        previous = latest
    if latest == now:
        return
    lines = "%d\n" % now + ("%d\n" % previous if previous is not None else "")
    try:
        write_atomic(os.path.join(pane_dir(home), "last-look"), lines)
    except OSError:
        pass


def calls_signal(home: str) -> str:
    """The owner's calls signal (bin/fm-owner-calls-signal-lib.sh), or "" when it cannot be read."""
    script = '. "$1/fm-owner-calls-signal-lib.sh" && fm_owner_calls_signal "$2"'
    try:
        out = subprocess.run(["bash", "-c", script, "fm-factory", BIN, os.path.join(home, "state")],
                             capture_output=True, text=True, timeout=10, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return ""
    return out.stdout.strip() if out.returncode == 0 else ""


def snapshot_age(record: Dict[str, Any]) -> int:
    """Seconds since the record's slow fleet reading was taken."""
    return now_epoch() - int(record.get("snapshot_epoch") or record.get("as_of_epoch") or 0)


def basis_path(home: str) -> str:
    return os.path.join(pane_dir(home), "basis.json")


def kept_shapes(home: str, signal: str, now: int) -> Tuple[Dict[str, Dict[str, Any]], int]:
    """The held questions' shapes the last whole refresh read, and when they were read.

    Reading a question's options costs a second or more each, so a whole refresh
    reuses them while the owner's calls signal is still the one taken before they
    were read (every command that changes a call moves it, and so does any
    write to data/backlog.md) and they are younger than FM_FACTORY_MAX_AGE, the
    same bound as the pane's safety refresh. shapes_for still reads afresh any
    question held again since. Otherwise it returns no shapes and <now>.
    """
    basis = read_basis(home) if signal else None
    shapes = (basis or {}).get("shapes")
    read = (basis or {}).get("shapes_epoch")
    if not isinstance(shapes, dict) or not isinstance(read, int) or basis.get("calls_signal") != signal \
            or not 0 <= now - read < env_int("FM_FACTORY_MAX_AGE", 300):
        return {}, now
    return dict(shapes), read


def refresh(home: str) -> Dict[str, Any]:
    now = now_epoch()
    # Taken before anything is read, so a call that changes meanwhile is caught.
    signal_at_start = calls_signal(home)
    inputs = inputs_digest(home)
    read_at = time.time()
    # The reads that do not depend on one another run side by side: the fleet
    # snapshot, the backlog as its adapter reads it and then its held
    # questions' shapes (which held decisions are the owner's calls depends on
    # the backlog alone), the inbox, the reconcile requests and the shared
    # overview reading; then the panes beside the owner's calls, which need the
    # snapshot's buckets and the overview's ready work and take the shapes
    # already read.
    shapes, shapes_epoch = kept_shapes(home, signal_at_start, now)
    held_shapes: Dict[str, Dict[str, Any]] = {}

    def backlog_and_shapes():
        taken = axi_backlog(home)
        decision_ids, _merges, rows, _mate_prs = owner_calls(home, {}, taken)
        held_shapes.update(shapes_for(home, decision_ids, {r["id"]: r for r in rows}, shapes))
        return taken

    snapshot, backlog, notes, reconciles, overview = side_by_side(
        lambda: load_snapshot(home), backlog_and_shapes,
        lambda: inbox_receipts(home), lambda: reconcile_pending(home),
        lambda: overview_reading(home))
    running = [t["id"] for t in snapshot.get("tasks") or []
               if (t.get("current_state") or {}).get("state") == "working"
               and (t.get("current_state") or {}).get("source") == "pane"]

    def calls_with_buckets():
        taken = buckets_for(live_tasks(snapshot))
        decision_ids, merge_ids, rows, mate_prs = owner_calls(home, overview_call_buckets(overview, taken), backlog)
        return taken, (decision_ids, merge_ids, rows,
                       {ident: held_shapes[ident] for ident in decision_ids if ident in held_shapes}, mate_prs)

    activity, (buckets, calls) = side_by_side(lambda: pane_activity(home, running, now, write=True),
                                              calls_with_buckets)
    record = build_record(home, now, snapshot, since=last_look(home, now), activity=activity,
                          notes=notes, backlog=backlog, known_shapes=shapes, buckets=buckets,
                          reconciles=reconciles, calls=calls, overview=overview)
    record.update(snapshot_epoch=now, calls_signal=signal_at_start, read_at=read_at)
    try:
        held = {ident: shapes[ident] for ident in calls[0] if ident in shapes}
        write_atomic(basis_path(home), json.dumps({"taken_epoch": now, "snapshot": snapshot,
                                                   "activity": activity, "shapes": held,
                                                   "shapes_epoch": shapes_epoch if held else now,
                                                   "calls_signal": signal_at_start,
                                                   "buckets": buckets}))
        write_atomic(inputs_path(home), inputs + "\n")
        kept = True
    except OSError:
        kept = False
    # The slow reading took long enough for a call to change under it; catch the
    # calls up from this same reading rather than publish them behind.
    if kept and signal_at_start and calls_signal(home) != signal_at_start:
        try:
            caught_up = refresh_calls(home)
            if caught_up is not None:
                return caught_up
        except (RuntimeError, OSError, ValueError, subprocess.SubprocessError):
            pass
    try:
        write_atomic(os.path.join(pane_dir(home), "record.json"), json.dumps(record, indent=1))
    except OSError:
        pass
    return record


def load_backlog(home: str) -> Dict[str, Any]:
    """The backlog part of a fleet snapshot, read on its own (`fm-fleet-snapshot.sh --backlog`)."""
    seam = os.environ.get("FM_FACTORY_SNAPSHOT")
    if seam:
        with open(seam, encoding="utf-8") as handle:
            return json.load(handle).get("backlog") or {}
    out = subprocess.run(["bash", os.path.join(BIN, "fm-fleet-snapshot.sh"), "--backlog"],
                         capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL,
                         env=dict(os.environ, FM_HOME=home))
    if out.returncode != 0:
        raise RuntimeError("the backlog could not be read")
    return json.loads(out.stdout)


def side_by_side(*reads):
    """Run each read in its own thread and return their results in order; the
    failure of the earliest read in the list is raised, so the error does not
    depend on which thread finished first."""
    results: List[Any] = [None] * len(reads)
    errors: List[Tuple[int, BaseException]] = []

    def run(index: int) -> None:
        try:
            results[index] = reads[index]()
        except Exception as error:  # handed back to the caller below
            errors.append((index, error))

    threads = [threading.Thread(target=run, args=(index,)) for index in range(len(reads))]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    if errors:
        raise min(errors, key=lambda pair: pair[0])[1]
    return results


def read_basis(home: str) -> Optional[Dict[str, Any]]:
    """The fleet reading the last full refresh kept (basis.json), or None when it is missing or unreadable."""
    try:
        basis = json.loads(read_text(basis_path(home), 256_000_000) or "null")
    except ValueError:
        return None
    if not isinstance(basis, dict) or not isinstance(basis.get("snapshot"), dict):
        return None
    return basis


def refresh_calls(home: str) -> Optional[Dict[str, Any]]:
    """Rebuild the record with fresh owner's calls on the last slow fleet reading.

    The slow part of a refresh is reading the workers. A decision answered,
    parked, released, closed or added, or a note to Starship, changes only the
    backlog and the inbox, so those are read again (side by side) and the record
    is rebuilt on the workers as the last full refresh read them: the next call
    is on screen within a second or two instead of at the next full refresh.
    Without a usable reading it returns None, since only a full refresh can
    make one.
    """
    basis = read_basis(home)
    if basis is None:
        return None
    signal_at_start = calls_signal(home)
    read_at = time.time()
    overview = overview_reading(home)
    backlog, axi, notes, reconciles = side_by_side(lambda: load_backlog(home), lambda: axi_backlog(home),
                                                   lambda: inbox_receipts(home), lambda: reconcile_pending(home))
    snapshot = dict(basis["snapshot"], backlog=backlog)
    activity = {k: v for k, v in (basis.get("activity") or {}).items() if isinstance(v, int)}
    buckets = basis.get("buckets")
    # Shapes read by an earlier calls rebuild on this same reading stand beside
    # the reading's own, under the same held-stamp rule (shapes_for), so a
    # question held since the reading has its options read once, not by every
    # rebuild until the next whole refresh.
    known = dict(basis.get("shapes") or {})
    learned_path = os.path.join(pane_dir(home), "shapes.json")
    try:
        learned = json.loads(read_text(learned_path, 64_000_000) or "null")
    except ValueError:
        learned = None
    if isinstance(learned, dict) and learned.get("taken_epoch") == basis.get("taken_epoch") \
            and isinstance(learned.get("shapes"), dict):
        known.update(learned["shapes"])
    before = dict(known)
    now = now_epoch()
    record = build_record(home, now, snapshot, since=last_look(home, now), activity=activity,
                          notes=notes, backlog=axi, known_shapes=known,
                          buckets=buckets if isinstance(buckets, dict) else None, reconciles=reconciles,
                          overview=overview)
    if known != before:
        try:
            write_atomic(learned_path, json.dumps({"taken_epoch": basis.get("taken_epoch"), "shapes": known}))
        except OSError:
            pass
    record.update(snapshot_epoch=int(basis.get("taken_epoch") or 0), calls_signal=signal_at_start,
                  read_at=read_at)
    newer = cached(home)
    if newer and int(newer.get("snapshot_epoch") or 0) > record["snapshot_epoch"]:
        return newer
    write_atomic(os.path.join(pane_dir(home), "record.json"), json.dumps(record, indent=1))
    return record


def cached(home: str) -> Optional[Dict[str, Any]]:
    try:
        record = json.loads(read_text(os.path.join(pane_dir(home), "record.json")) or "null")
    except ValueError:
        return None
    if isinstance(record, dict) and record.get("schema") == SCHEMA:
        return record
    return None


def inputs_path(home: str) -> str:
    return os.path.join(pane_dir(home), "inputs")


def inputs_digest(home: str) -> str:
    """A digest of what a whole refresh reads that a file records.

    That is every worker's status, meta, turn and step record in state/, the
    owner's calls stamp, the inbox folders, the backlog, project, factory and
    second-mate registries, the data folder itself, and the pane's own steer
    record. Equal digests mean none of them was written since; reading
    them is a few hundred stats, cheap enough for a pane to check every couple
    of seconds where a whole refresh costs seconds of every worker read.
    """
    state, data = os.path.join(home, "state"), os.path.join(home, "data")
    seen: List[str] = []

    def note(path: str) -> None:
        try:
            info = os.stat(path)
        except OSError:
            return
        seen.append("%s %d %d" % (path, info.st_mtime_ns, info.st_size))

    try:
        names = sorted(os.listdir(state))
    except OSError:
        names = []
    for name in names:
        if name.endswith(INPUT_ENDINGS):
            note(os.path.join(state, name))
    for path in (os.path.join(state, ".owner-calls-changed"), os.path.join(state, "inbox"),
                 os.path.join(state, "inbox", "handled"), os.path.join(state, "inbox", ".replies"), data,
                 os.path.join(data, "backlog.md"), os.path.join(data, "projects.md"),
                 os.path.join(data, "factories.md"), os.path.join(data, "secondmates.md"),
                 os.path.join(pane_dir(home), "steer.log")):
        note(path)
    return hashlib.sha256("\n".join(seen).encode()).hexdigest()


def refresh_due(home: str, record: Dict[str, Any]) -> bool:
    """Whether a whole refresh of <record> is due.

    It is once the record's workers are FM_FACTORY_TTL old and a file a whole
    refresh reads changed since the last one began (inputs_digest), and also
    once they are FM_FACTORY_MAX_AGE old while the machine is not busy, for
    what no file records: a worker's pane activity, a change merged elsewhere,
    a job gone quiet.
    """
    age = snapshot_age(record)
    if age <= env_int("FM_FACTORY_TTL", 60):
        return False
    if age > env_int("FM_FACTORY_MAX_AGE", 300) and not machine_busy():
        return True
    return read_text(inputs_path(home), 256).strip() != inputs_digest(home)


def rebuild_lock(home: str, wait: bool = False) -> Optional[int]:
    """Take the home's one rebuild lock: its descriptor, or None while a rebuild holds it and not <wait>.

    Every pane and live copy of a home starts its rebuilds, whole or of the
    owner's calls only, under this one lock, and the rebuild it starts inherits
    the descriptor and holds the lock until it exits, however long it runs and
    however it ends, so two never run side by side. A pane building its first
    record waits for the lock and holds it itself (first_record).
    """
    try:
        os.makedirs(pane_dir(home), exist_ok=True)
        fd = os.open(os.path.join(pane_dir(home), "rebuild.lock"), os.O_RDWR | os.O_CREAT, 0o600)
    except OSError:
        return None
    try:
        fcntl.flock(fd, fcntl.LOCK_EX if wait else fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        return None
    return fd


def machine_busy() -> bool:
    """Whether the one-minute load average is BUSY_PER_CORE times the cores or more."""
    raw = os.environ.get("FM_FACTORY_LOADAVG", "")
    try:
        load = float(raw) if raw else os.getloadavg()[0]
    except (OSError, ValueError):
        return False
    return load >= BUSY_PER_CORE * (os.cpu_count() or 1)


def rebuild_wait(home: str) -> float:
    """Seconds still to wait before a pane may start the next full refresh.

    The last full refresh's own time is the least rest after it, so one that overran
    leaves the machine that much longer; one that failed leaves at least
    FAILED_GAP, and on a busy machine (machine_busy) the rest is four times the
    last refresh's time and at least BUSY_GAP. A pane that asks meanwhile starts
    nothing and queues nothing: it asks again at its next check. A rebuild of
    the owner's calls takes no rest and records none, so the calls stay
    current; the rebuild lock alone keeps it single.
    """
    try:
        last = json.loads(read_text(os.path.join(pane_dir(home), "rebuild.last"), 4096) or "null")
        ended, took = float(last["ended"]), max(float(last["took"]), 0.0)
    except (ValueError, TypeError, KeyError):
        return 0.0
    rest = max(took, FAILED_GAP) if last.get("failed") else took
    if machine_busy():
        rest = max(4 * took, rest, BUSY_GAP)
    return ended + rest - time.time()


def run_rebuild(home: str, build, rested: bool) -> Dict[str, Any]:
    """Run one rebuild, <build>(home), return its record, and when it is <rested> record when it ended, how long it took and whether it failed.

    A rebuild a pane started holds that pane's rebuild lock (FM_FACTORY_REBUILD_LOCK
    names the inherited descriptor) and stops itself after REBUILD_LIMIT
    seconds, so a stuck read can never hold the lock for good.
    """
    if os.environ.get("FM_FACTORY_REBUILD_LOCK"):
        def overran(*_):
            raise RuntimeError("the rebuild ran past %d seconds" % REBUILD_LIMIT)
        signal.signal(signal.SIGALRM, overran)
        signal.alarm(REBUILD_LIMIT)
    began, failed = time.time(), True
    try:
        record = build(home)
        failed = False
        return record
    finally:
        signal.alarm(0)
        if rested:
            try:
                write_atomic(os.path.join(pane_dir(home), "rebuild.last"),
                             json.dumps({"ended": time.time(), "took": round(time.time() - began, 3), "failed": failed}))
            except OSError:
                pass


def in_background(home: str, command: str) -> None:
    """Start one detached `fm-factory.py <command>` unless a rebuild runs."""
    fd = rebuild_lock(home)
    if fd is None:
        return
    try:
        subprocess.Popen(["python3", os.path.realpath(__file__), command], pass_fds=(fd,),
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True, env=dict(os.environ, FM_HOME=home, FM_FACTORY_REBUILD_LOCK=str(fd)))
    except OSError:
        pass
    finally:
        os.close(fd)


def refresh_in_background(home: str) -> None:
    """Start one detached full refresh when no rebuild is under way and the last one asks for no more rest."""
    if rebuild_wait(home) > 0:
        return
    in_background(home, "refresh")


def refresh_calls_in_background(home: str) -> None:
    """Start one detached refresh of the owner's calls when no rebuild is under way (in_background).

    With no fleet reading to rebuild them on (basis.json missing or empty, one
    stat), only a full refresh can, so it is asked for instead, under the same
    rest (refresh_in_background). A reading that is there but unreadable is
    found by the rebuild itself, which then refreshes whole under that rest.
    """
    try:
        has_basis = os.stat(basis_path(home)).st_size > 0
    except OSError:
        has_basis = False
    if not has_basis:
        refresh_in_background(home)
        return
    in_background(home, "refresh-calls")


def first_record(home: str) -> Dict[str, Any]:
    """The cached record, or one built under the home's rebuild lock when there is none.

    It waits for the lock, so panes opened together on a home with no record
    build one record between them: each looks at the cache again once it holds
    the lock, and only the first finds it empty.
    """
    record = cached(home)
    if record is not None:
        return record
    fd = rebuild_lock(home, wait=True)
    try:
        return cached(home) or run_rebuild(home, refresh, rested=True)
    finally:
        if fd is not None:
            os.close(fd)


def follow_overview(record: Dict[str, Any], overview: Optional[Dict[str, Any]]) -> bool:
    """Show the overview reading's figures on <record>; False when its calls need a rebuild.

    The figures are a cheap cache read, so they follow the overview in place.
    A different list of ready work changes NEEDS YOU itself, which only a
    rebuild of the owner's calls can show.
    """
    if overview is None:
        return True
    counts = overview_counts(overview, int((record.get("counts") or {}).get("idle") or 0))
    record.update(counts=counts, count_line=count_line_text(counts))
    wanted = overview.get("ready_list") if overview.get("known") else None
    return wanted is None or wanted == record.get("ready_list")


def current_record(home: str, fresh: bool) -> Dict[str, Any]:
    if not fresh:
        record = cached(home)
        if record and not refresh_due(home, record):
            signal = calls_signal(home)
            if follow_overview(record, overview_reading(home)) and (
                    not signal or record.get("calls_signal") == signal):
                return record
            try:
                caught_up = refresh_calls(home)
                if caught_up is not None:
                    return caught_up
            except (RuntimeError, OSError, ValueError, subprocess.SubprocessError):
                pass
    return refresh(home)


# --------------------------------------------------------------------------
# Drawing
# --------------------------------------------------------------------------

PALETTE = DARK
BAND = PALETTE["band"]
HULL = PALETTE["hull"]


class Row(list):
    band = False
    hull = False
    stop: Optional[Tuple[str, str]] = None   # the highlight stop this row draws, if any
    read: Optional[Tuple[str, List[str]]] = None   # the title and sources a click on this row reads
    link: Optional[Tuple[str, str]] = None   # the title and PR a click on this row opens


def S(text: Any, colour: str = "ice", bold: bool = False) -> Tuple[str, str, bool]:
    return (str(text), colour, bold)


def seg_len(segs) -> int:
    return sum(len(t) for t, _, _ in segs)


def clip(segs, width: int):
    """Segments cut to the width, ending in an ellipsis on a whole word where one is near."""
    if seg_len(segs) <= width:
        return list(segs)
    out, room = [], max(width - 1, 0)
    for text, colour, bold in segs:
        if len(text) <= room:
            out.append((text, colour, bold))
            room -= len(text)
            continue
        piece = text[:room]
        if not text[room].isspace():
            space = piece.rfind(" ")
            if space >= 0 and len(piece) - space <= 20:
                piece = piece[:space]
        out.append((piece.rstrip(), colour, bold))
        break
    out.append(("…", "faint", False))
    return out


def rules_size_words(size: int, cap: int) -> Tuple[str, str]:
    """A factory's rules size against the cap once it matters, and the colour to show it in:
    said from nine tenths of the cap, and over it the rules reach no job. Under that, no words."""
    words = "rules {:,} / {:,} characters".format(size, cap)
    if size > cap:
        return words + " · over the cap, so its jobs get none of these rules", "red"
    if size * 10 >= cap * 9:
        return words + " · near the cap; past it its jobs get none of these rules", "amber"
    return "", "faint"


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
        # A word wider than the line is broken across lines, never clipped.
        while len(word) > width:
            if line:
                lines.append(line)
            lines.append(word[:width])
            line, word = "", word[width:]
        if line and len(line) + 1 + len(word) > width:
            lines.append(line)
            line = word
        else:
            line = (line + " " + word).strip()
    if line:
        lines.append(line)
    return lines or [""]


def flow(width: int, lead, text: str, colour: str = "ice", bold: bool = False, indent: Optional[int] = None,
         tail=(), cap: Optional[int] = None, rest: Optional[str] = None) -> List[Row]:
    """Text wrapped to the width after a lead, its later lines under the text.

    `tail` (a note such as "Starship suggests this") follows the last line, or
    takes a line of its own when it does not fit; `cap` keeps that many lines,
    the last ending in an ellipsis; `rest` colours the lines after the first.
    """
    lead = list(lead)
    indent = seg_len(lead) if indent is None else indent
    lines = wrap(text, max(width - max(seg_len(lead), indent) - 1, 10))
    if cap and len(lines) > cap:
        lines = lines[:cap]
        lines[-1] += "…"
    lefts = [(lead if index == 0 else [S(" " * indent)])
             + [S(line, colour if index == 0 or rest is None else rest, bold)]
             for index, line in enumerate(lines)]
    tail = [seg for seg in tail if seg[0]]
    if tail and seg_len(lefts[-1]) + seg_len(tail) < width:
        lefts[-1] += tail
    elif tail:
        lefts.append([S(" " * indent), (tail[0][0].lstrip(), tail[0][1], tail[0][2])] + tail[1:])
    return [row(width, left) for left in lefts]


STATE_COLOUR = {"busy": "amber", "decision for you": "red", "ready to merge": "green", "needs a look": "amber",
                "failed": "amber",
                "waiting": "amber", "stopped": "amber", "no worker": "faint", "no reading": "faint",
                "with Starship": "mist", "finished": "green", "next": "mist", "later": "faint"}
# What a job's row says for a state whose word alone leaves out whose turn it is
# or that the work is finished. The record keeps the state word, which the
# count line and the status bar count by (docs/status-bar.md).
STATE_WORDS = {"needs a look": "waiting on Starship", "with Starship": "finished, now with Starship",
               "stopped": "stopped, Starship is on it"}
# What a `needs a look` job's row says, by what it waits on Starship for (the job's `look`).
LOOK_WORDS = {"checks": "stopped: its checks raised a question, Starship is on it",
              "question": "stopped: it asked Starship a question, Starship is on it",
              "stuck": "stopped: it is stuck, Starship is on it"}
# A factory's New on the overview: the outcomes it tells, each led by its word, and how many it shows.
NEW_LABELS = {"went live": "Went live", "report ready": "Report ready", "settled": "Settled",
              "PR ready": "PR ready", "finished": "Finished", "failed": "Failed", "closed": "Closed"}
NEW_CAP = 4
# How many of its newest feed events a factory's own page lists, on both screens.
PAGE_FEED = 8
# How many jobs in line a factory's own page names under Up next before it folds the rest.
UP_NEXT = 3
# How long after its start a busy job that has named no step reads `just started`.
JUST_STARTED = 300
FEED_COLOUR = {"finished": "green", "report ready": "green", "PR ready": "green", "went live": "green",
               "closed": "mist", "settled": "mist", "asked you": "red", "failed": "amber",
               "took the helm": "cyan", "handed back": "cyan", "replied": "cyan",
               "answered": "cyan", "asked to keep": "cyan", "asked for changes": "cyan", "said": "cyan",
               "asked to bring back": "cyan", "said no longer needed": "cyan"}


def asking(need: Dict[str, Any]) -> str:
    """Which asking of a need this is: its decision key and when it was asked, held or became ready."""
    return ".".join(str(part) for part in (need.get("key"), need.get("since")) if part) or "0"


def read_row(width: int, lead: str, item: Dict[str, Any]) -> Row:
    """The `r  Read the report` line of a call or job with something to read; a click on it reads it."""
    line = row(width, [S(lead), S("r", "cyan", True), S("  "), S("Read the report", "ice")])
    line.read = (item["title"], list(item["read"]))
    return line


def link_row(width: int, lead: str, item: Dict[str, Any]) -> Row:
    """The `o  See what changed` line of a change that went live; a click on it opens its PR."""
    line = row(width, [S(lead), S("o", "cyan", True), S("  "), S("See what changed", "ice")])
    line.link = (item["title"], item["pr"])
    return line


# How long an item the highlight was asked to go to waits for the record to
# hold it: the bridge strip can name a call a record or two before the pane has it.
WANT_SECONDS = 60

# What an empty overview says, so a first look is never a blank screen.
FIRST_RUN_HINT = "No work yet. Ask Starship for a first report, and it shows up here."


class View:
    """Draws a record; holds the cursor, the talk box and pending notices."""

    def __init__(self, record: Dict[str, Any], opened: Optional[str] = None, in_tab: bool = False,
                 item: Optional[str] = None, voice: bool = False):
        self.opened = opened
        self.in_tab = in_tab
        self.voice = voice    # whether the talk box can listen on this machine
        # What was sent from this pane and is not in the record yet, by need and asking.
        self.answered: Dict[Tuple[str, str], Dict[str, Any]] = {}   # answers sent here a moment ago
        self.cursor = 0
        self.selected: Optional[Tuple[str, str]] = None
        self.unfolded: Optional[str] = None   # the factory whose folded jobs are listed
        # The older questions shelf listed: "" on the overview, else the factory whose page shows it.
        self.older_open: Optional[str] = None
        self.older_asked: Dict[str, Dict[str, Any]] = {}   # older questions asked about here a moment ago
        # An item the highlight was asked to go to (--item, or the focus file),
        # held until the record has it, for at most WANT_SECONDS.
        self.wanted: Optional[Tuple[str, float]] = (item, time.time()) if item else None
        self.tick = 0
        self.talking: Optional[Dict[str, Any]] = None
        self.confirm: Optional[Dict[str, Any]] = None
        self.notice: Optional[Tuple[str, str, float]] = None
        self.top = 0          # the first body row in sight
        self.follow = True    # keep the highlight in sight; scrolling by hand lets go
        self.page = 10        # body rows in sight at the last frame
        self.adopt(record)

    def adopt(self, record: Dict[str, Any]) -> None:
        """Take a new record; whatever pointed at something it no longer holds lets go of it."""
        self.record = record
        if self.opened and not self.has_factory(self.opened):
            self.opened = None
        if self.unfolded and (self.unfolded != self.opened
                              or not any(self.page_jobs(self.factory(self.unfolded))[1].values())):
            self.unfolded = None
        if self.older_open is not None and (self.older_open != (self.opened or "")
                                            or not self.older(self.opened)):
            self.older_open = None
        talk = self.talking
        if talk is not None and not (self.has_factory(talk["factory"]) and (
                "item" not in talk or self.need(talk["item"]))):
            talk["gone"] = True
        confirm = self.confirm
        if confirm is not None:
            if confirm.get("older"):
                item = self.older_item(confirm["item"])
                gone = item is None or item["asking"] != confirm["asked"]
            else:
                need = self.need(confirm["item"])
                gone = need is None or asking(need) != confirm["asked"]
            if gone:
                self.confirm = None
                self.notice = ("Not sent: this was settled elsewhere before you confirmed %s." % confirm["what"],
                               "amber", time.time() + 12)
        asked = {(n["id"], asking(n)) for n in record.get("needs_you") or []}
        self.answered = {key: mark for key, mark in self.answered.items() if key in asked}
        self.older_asked = {ident: mark for ident, mark in self.older_asked.items() if self.older_item(ident)}

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

    def older(self, fid: Optional[str] = None) -> List[Dict[str, Any]]:
        """The older questions still open, oldest first: all of them, or one factory's."""
        return [o for o in self.record.get("older") or [] if fid in (None, o["factory"])]

    def older_item(self, ident: str) -> Optional[Dict[str, Any]]:
        return next((o for o in self.record.get("older") or [] if o["id"] == ident), None)

    def older_asked_of(self, item: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        """What the owner asked of an older question: from the record, or from this pane a moment ago if newer."""
        known, here = item.get("asked"), self.older_asked.get(item["id"])
        if known and here:
            return here if (here["at"] or 0) >= (known["at"] or 0) else known
        return known or here

    def first_up(self) -> Optional[str]:
        """The most pressing of the owner's calls, the first card on the overview."""
        needs = self.needs()
        return needs[0]["id"] if needs else None

    def answered_of(self, need: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        """When the owner answered a need, and how: from the record, or from this pane a moment ago if newer."""
        known, here = need.get("answered"), self.answered.get((need["id"], asking(need)))
        if known and here:
            return here if (here["at"] or 0) >= (known["at"] or 0) else known
        return known or here

    def older_stops(self, fid: Optional[str]) -> List[Tuple[str, str]]:
        """The older questions shelf: its line, and each question while it is listed."""
        older = self.older(fid)
        if not older:
            return []
        stops = [("older", fid or "")]
        if self.older_open == (fid or ""):
            stops += [("old", o["id"]) for o in older]
        return stops

    def stops(self) -> List[Tuple[str, str]]:
        if self.opened:
            stops = [("need", n["id"]) for n in self.needs(self.opened)] + self.older_stops(self.opened)
            stops = stops or [("factory", self.opened)]
            if any(self.page_jobs(self.factory(self.opened))[1].values()):
                stops.append(("fold", self.opened))   # the line the rest of its queue folds into
            return stops
        return [("need", n["id"]) for n in self.needs()] + self.older_stops(None) + \
            [("factory", f["id"]) for f in self.ordered()]

    def want(self, item: str) -> None:
        """Move the highlight to one item of NEEDS YOU, now or once the record has it."""
        if not self.in_tab:
            self.opened = None
        self.wanted = (item, time.time())

    def at(self) -> Tuple[str, str]:
        stops = self.stops()
        if self.wanted:
            item, asked = self.wanted
            if ("need", item) in stops:
                # Going to an item brings it into sight, even after a hand scroll.
                self.selected, self.wanted, self.follow = ("need", item), None, True
            elif time.time() - asked > WANT_SECONDS:
                self.wanted = None
        if not stops:
            return ("none", "")
        if self.selected in stops:
            self.cursor = stops.index(self.selected)
        self.cursor = max(0, min(self.cursor, len(stops) - 1))
        self.selected = stops[self.cursor]
        return self.selected

    def move(self, step: int) -> None:
        """Move the highlight; past the first or last row the view scrolls instead."""
        self.at()
        if not 0 <= self.cursor + step < len(self.stops()):
            self.scroll(3 * step)
            return
        self.cursor += step
        self.selected = None
        self.follow = True

    def scroll(self, lines: int) -> None:
        self.top = max(self.top + lines, 0)
        self.follow = False

    def show(self, fid: Optional[str]) -> None:
        self.opened, self.cursor, self.selected, self.unfolded = fid, 0, None, None
        self.top, self.follow = 0, True

    def here(self, kind: str, ident: str) -> bool:
        return self.at() == (kind, ident)

    def mark(self, kind: str, ident: str):
        return S("▸ ", "cyan", True) if self.here(kind, ident) else S("  ")

    def readable(self) -> Optional[Tuple[str, List[str]]]:
        """What `r` reads: the highlighted call, or on a factory its first job with something to read."""
        kind, ident = self.at()
        if kind == "need":
            need = self.need(ident)
            return (need["title"], need["read"]) if need and need.get("read") else None
        fid = ident if kind == "factory" else self.opened
        if not fid or not self.has_factory(fid):
            return None
        fac = self.factory(fid)
        if self.opened:
            page = self.page_parts(fac)
            drawn = page["now"] + page["next"] + page["lately"]
        else:
            drawn = self.overview_jobs(fac) + self.told(fac)["new"]
        job = next((j for j in drawn if j.get("read")), None)
        return (job["title"], job["read"]) if job else None

    def openable(self) -> Optional[Tuple[str, str]]:
        """What `o` opens: the PR of the first change that went live, in a highlighted factory's New on the
        overview, or in Lately on a factory's own page."""
        kind, ident = self.at()
        if self.opened and kind != "need" and self.has_factory(self.opened):
            items = self.page_parts(self.factory(self.opened))["lately"]
        elif kind == "factory" and not self.opened and self.has_factory(ident):
            items = self.told(self.factory(ident))["new"]
        else:
            return None
        item = next((n for n in items if n["pr"]), None)
        return (item["title"], item["pr"]) if item else None

    @staticmethod
    def overview_jobs(fac: Dict[str, Any]) -> List[Dict[str, Any]]:
        """The jobs a factory shows on the overview: what is moving or stopped, and calls on you that have started."""
        folded = {ident for line in fac.get("routine_runs") or [] for ident in line["folded"]}
        return [job for job in fac["jobs"] if job["id"] not in folded and (
            job["state"] in ("busy", "needs a look", "failed", "waiting", "stopped", "no worker") or (
                job["started"] and job["state"] in ("decision for you", "ready to merge")))]

    @staticmethod
    def page_jobs(fac: Dict[str, Any]) -> Tuple[List[Dict[str, Any]], Dict[str, List[Dict[str, Any]]]]:
        """The jobs a factory's own page shows under its work, and the rest that folds away, per queue word."""
        # Everything moving, then the head of the line; the rest of the queue
        # folds into one count per queue word. A call of the owner's is a card
        # above, never a second row here.
        shown: List[Dict[str, Any]] = []
        shown_line = 0
        folded: Dict[str, List[Dict[str, Any]]] = {word: [] for word in QUEUE_WORDS}
        carded = set(fac.get("needs") or ())   # its card under NEEDS YOU is the job's row on this page
        for job in fac["jobs"]:
            if job["state"] == "finished" or job["id"] in carded or job.get("queue") in ("older call", "deferred"):
                continue   # a call of the owner's that left NEEDS YOU is on its shelves
            word = job.get("queue")
            if word is None and not job["started"] and (
                    job["state"].startswith("on hold") or job["state"] == "waits on other work"):
                word = "on hold"   # a record from before the queue was counted
            if job["state"] in ("next", "later"):
                shown_line += 1
                if shown_line > UP_NEXT:
                    folded["in line"].append(job)
                    continue
            elif word and job["state"] != "decision for you":
                folded[word].append(job)
                continue
            shown.append(job)
        return shown, folded

    def ordered(self) -> List[Dict[str, Any]]:
        """The factories as the overview lists them: at work or needing you, then idle, then the quiet ones."""
        factories = self.record["factories"]
        quiet = [f for f in factories if self.quiet(f)]
        return [f for f in factories if f["state"] != "idle"] + \
            [f for f in factories if f["state"] == "idle" and f not in quiet] + quiet

    # ---- pieces --------------------------------------------------------------

    def count_line(self, width: int) -> List[Row]:
        """The top of the screen: the wordmark, the three sentences (sentences()) and the time."""
        clock = self.clock_words()
        rows: List[Row] = []
        mark = [S(" S T A R S H I P ", "cyan", True), S(" │  ", "faint")]
        if width < 100:
            mark = [S(" STARSHIP ", "cyan", True), S(" │  ", "faint")]
        if width < 72:
            # A narrow pane gives the sentences the whole width under the wordmark.
            rows.append(row(width, [S(" STARSHIP", "cyan", True)], [S(clock, "mist")]))
            mark = [S(" ")]
        indent = seg_len(mark)
        for said in sentences(self.record, self.now()):
            first = not rows
            lines = wrap(said["words"], max(width - indent - (len(clock) + 3 if first else 1), 16))
            if len(lines) > 1:
                # Only the first row makes room for the time.
                lines = lines[:1] + wrap(" ".join(lines[1:]), max(width - indent - 1, 16))
            for line in lines:
                rows.append(row(width, (mark if not rows else [S(" " * indent)]) + [S(line, said["colour"])],
                                [S(clock, "mist")] if not rows else []))
        for line in rows:
            line.hull = True
        return rows

    def waited(self, need: Dict[str, Any]) -> str:
        """How long a need has waited, or that it is answered and waits for Starship."""
        now = self.now()
        question = need["kind"] == "question"
        sent = self.answered_of(need)
        if sent:
            # Answered; it stays listed until Starship has acted on that.
            return "answered %s, waiting for Starship" % (
                when_words(sent["at"], now) if sent.get("at") else "just now")
        if not need.get("since"):
            return "waiting" if question else "ready"
        return ("waiting " if question else "ready ") + minutes_words((now - need["since"]) // 60)

    def need_head(self, need: Dict[str, Any], full: bool):
        """The lead, title and right-hand words of a need's first row."""
        fac = self.factory(need["factory"])
        question = need["kind"] == "question"
        sent = self.answered_of(need)
        right = [S(self.waited(need), "cyan" if sent else "mist")]
        if need.get("mate"):
            right = [S("from %s" % need["mate"], "mist"), S(" · ", "faint")] + right
        if not full:
            right = [S(fac["name"], "mist"), S(" · ", "faint")] + right
        if need.get("checking"):
            right = [S("checking", "amber"), S(" · ", "faint")] + right
        if not full and need["id"] == self.first_up():
            right = [S("first up", "red", True), S(" · ", "faint")] + right
        lead = [S(" "), self.mark("need", need["id"]),
                S("● ", "cyan" if sent else ("red" if question else "green"))]
        return lead, need["ask"], right

    def need_line(self, width: int, need: Dict[str, Any], full: bool = False) -> Row:
        """A need folded to one row: its title, shortened on a whole word when it must be, and how long it waits."""
        lead, ask, right = self.need_head(need, full)
        line = row(width, lead + [S(ask, "ice", True)], right, band=self.here("need", need["id"]))
        line.stop = ("need", need["id"])
        return line

    def need_list(self, width: int, needs: List[Dict[str, Any]], full: bool) -> List[Row]:
        """NEEDS YOU: the highlighted need opens as a card, every other one stays one line."""
        rows: List[Row] = []
        for index, need in enumerate(needs):
            if not self.here("need", need["id"]):
                rows.append(self.need_line(width, need, full))
                continue
            rows += ([row(width)] if index else []) + self.need_rows(width, need, full)
            if index < len(needs) - 1:
                rows.append(row(width))
        return rows + [row(width)]

    def need_rows(self, width: int, need: Dict[str, Any], full: bool) -> List[Row]:
        """A need opened as a card: every word of its title, why and options, wrapped."""
        question = need["kind"] == "question"
        band = self.here("need", need["id"])
        lead, ask, right = self.need_head(need, full)
        pad = S("       ")
        if seg_len(lead) + len(ask) + seg_len(right) + 3 <= width:
            rows = [row(width, lead + [S(ask, "ice", True)], right, band=band)]
        else:
            rows = flow(width, lead, ask, "ice", True)
            for line in rows:
                line.band = band
            rows.append(row(width, [pad] + right))
        confirm = self.confirm if self.confirm and self.confirm["item"] == need["id"] else None
        chosen = (confirm or {}).get("option") or (self.answered_of(need) or {}).get("key")
        if question:
            if need.get("why"):
                rows += flow(width, [pad], need["why"], "mist")
            for option in need["options"]:
                note = []
                if option["suggested"]:
                    note = [S("  · %s suggests this" % (need.get("suggested_by") or "Starship"), "mist")]
                lead = [pad, S(option["key"], "cyan", True), S("  ")]
                if option["key"] == chosen:
                    # The option picked: waiting for enter, or already sent.
                    lead = [S("     "), S("▸ " if confirm else "✓ ", "amber" if confirm else "cyan", True),
                            S(option["key"], "amber" if confirm else "cyan", True), S("  ")]
                rows += flow(width, lead, option["label"], "ice", bold=option["key"] == chosen, tail=note)
            if need.get("recommendation"):
                rows += flow(width, [pad], "Starship suggests: %s" % need["recommendation"], "ice", rest="mist")
            if need.get("read"):
                rows.append(read_row(width, pad[0], need))
            rows.append(row(width, [pad, S("t", "cyan", True), S("  "), S("Talk it through", "ice"),
                                    S(" · by voice" if self.voice else " · typed", "faint")]))
            if need.get("checking"):
                rows.append(row(width, [pad, S("checking", "amber", True),
                                        S("  Starship is re-reading what you said about this", "mist")]))
            else:
                rows.append(row(width, [pad, S("x", "cyan", True), S("  "), S("Already settled?", "ice")]))
            if need.get("holds_up"):
                rows += flow(width, [pad, S("holds up ", "faint")], ", ".join(need["holds_up"][:3]), "mist")
        else:
            # The PR's short section, beside the merge choice it informs.
            for part in need.get("summary") or []:
                rows += flow(width, [pad, S("%-13s" % part["label"], "faint")], part["text"], "ice")
            if need.get("pr") and full:
                rows.append(row(width, [pad, S("the change ", "faint"), S(need["pr"], "mist")]))
            if need.get("read"):
                rows.append(read_row(width, pad[0], need))
            rows.append(row(width, [pad, S("k", "cyan", True), S("  keep it    ", "ice"), S("c", "cyan", True),
                                    S("  ask for changes", "ice")]))
        for line in rows:
            line.stop = ("need", need["id"])
        return rows

    def older_rows(self, width: int, fid: Optional[str] = None) -> List[Row]:
        """The older questions shelf: one line that says how many and since when; enter lists them.

        A listed question is a stop of its own, where `b` asks Starship to
        bring it back into NEEDS YOU and `n` says it is no longer needed.
        """
        words = shelves(self.record, self.now(), fid)
        if not words["older"]:
            return []
        stop = ("older", fid or "")
        listed = self.older_open == stop[1]
        head = flow(width, [S("   "), self.mark(*stop), S("· ", "faint")],
                    "%s. %s" % (words["older_heading"], words["older_note"]), "mist")
        for line in head:
            line.band, line.stop = self.here(*stop), stop
        rows = head
        if not listed:
            return rows + [row(width)]
        names = max(len(self.factory(o["factory"])["name"]) for o in words["older"]) if fid is None else 0
        for item in words["older"]:
            here = self.here("old", item["id"])
            asked = self.older_asked_of(item)
            lead = [S("     "), self.mark("old", item["id"])]
            if fid is None:
                lead.append(S(self.factory(item["factory"])["name"].ljust(names + 2), "mist"))
            right = [S("since %s" % day_words(item["since"]), "mist")] if item.get("since") else []
            lines = [row(width, lead + [S(item["title"], "ice", here)], right, band=here)]
            pad = S(" " * (seg_len(lead)))
            if asked:
                lines.append(row(width, [pad, S("%s, waiting for Starship" % OLDER_ASKED[asked["what"]], "cyan")]))
            elif here:
                lines.append(row(width, [pad, S("b", "cyan", True), S("  Bring back    ", "ice"),
                                         S("n", "cyan", True), S("  No longer needed", "ice")]))
            for line in lines:
                line.stop = ("old", item["id"])
            rows += lines
        return rows + [row(width)]

    def coming_rows(self, width: int, fid: Optional[str] = None) -> List[Row]:
        """The calls put off to a date: the ones back this week by date, then how many more and the next date."""
        coming = shelves(self.record, self.now(), fid)["coming"]
        if not coming["heading"]:
            return []
        rows = flow(width, [S("   "), S("↺ ", "faint")],
                    "%s.%s" % (coming["heading"], " " + coming["rest"] if coming["rest"] else ""), "mist")
        for item in coming["items"]:
            right = [S(self.factory(item["factory"])["name"], "mist")] if fid is None else []
            rows.append(row(width, [S("       "), S(date_words(item["until"]).ljust(12), "faint"),
                                    S(item["title"], "ice")], right))
        if coming["after"] and coming["items"]:
            rows.append(row(width, [S("       "), S(coming["after"], "faint")]))
        elif coming["after"]:
            rows += flow(width, [S("     ")], coming["after"], "faint")
        return rows + [row(width)]

    def track(self, job: Dict[str, Any], width: int = 0, links: int = 5):
        current = STEPS.index(job["step"]) if job.get("step") in STEPS else 1
        lit = self.tick % links
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
                segs.append(S("•" * links, "mist"))
            elif index > current:
                segs.append(S("·" * links, "faint"))
            elif job.get("quiet"):
                segs.append(S("•" * links, "ember"))
            else:
                segs += [S("•" * lit, "ember"), S("•", "amber", True), S("•" * (links - 1 - lit), "ember")]
            segs.append(S(" "))
        if width and links > 2 and 7 + seg_len(segs) > width:
            return self.track(job, width, 2)
        return segs

    def job_words(self, job: Dict[str, Any]) -> Tuple[str, str, bool]:
        """A job's words: what a busy one is doing and how long it has run, else its state; and whether it is quiet."""
        now = self.now()
        if job["state"] == "busy":
            elapsed = minutes_words((now - job["started"]) // 60) if job.get("started") else ""
            if job.get("quiet") and job.get("last_sign_of_life"):
                return "quiet for %d min, no sign of life" % ((now - job["last_sign_of_life"]) // 60), elapsed, True
            fresh = job.get("started") and now - job["started"] < JUST_STARTED
            return job.get("doing") or ("just started" if fresh else "at work"), elapsed, False
        if job["state"] == "waiting" and job.get("until"):
            return "waiting · tries again %s" % clock(job["until"]), "", False
        if job["state"] == "with Starship" and job.get("kind") == "scout":
            return "finished, Starship is reading the report", "", False
        if job["state"] == "needs a look" and job.get("look") in LOOK_WORDS:
            return LOOK_WORDS[job["look"]], "", False
        # Only a job the overview counts stopped, the one the top sentence and
        # the strip count, says Starship is on it; one whose window or worktree
        # is gone without that reading reads plain stopped.
        if job["state"] == "stopped" and job["id"] not in (self.record["counts"].get("lost_list") or []):
            return "stopped", "", False
        return STATE_WORDS.get(job["state"], job["state"]), "", False

    def job_rows(self, width: int, job: Dict[str, Any], full: bool, pad: int = 5) -> List[Row]:
        rows = self.job_lines(width, job, full, pad)
        if job.get("read"):
            rows.append(read_row(width, " " * (pad + 2), job))
        return rows

    def job_lines(self, width: int, job: Dict[str, Any], full: bool, pad: int = 5) -> List[Row]:
        state = job["state"]
        words, elapsed, quiet = self.job_words(job)
        lead, under = S(" " * pad), S(" " * (pad + 2))
        if state == "busy":
            return [row(width, [lead, S("● ", "amber"), S(job["title"], "ice")],
                        [S(elapsed, "mist")] if elapsed else []),
                    row(width, [under] + self.track(job, width - pad + 5)),
                    row(width, [under, S(words, "amber" if quiet else "mist")])]
        colour = STATE_COLOUR.get(state, "faint")
        dot = "● " if state in ("decision for you", "ready to merge", "needs a look", "failed", "waiting",
                                "stopped") else "· "
        title = [lead, S(dot, colour), S(job["title"], "ice" if full else "mist")]
        if seg_len(title) + len(words) + 4 > width:
            # Words too long for the row's end take a line of their own under the title.
            return [row(width, title)] + flow(width, [under], words, colour)
        return [row(width, title, [S(words, colour)])]

    def steer(self, fac: Dict[str, Any]):
        if fac["steered_by"] == "you":
            return [S("you steer", "cyan")]
        return [S("Starship steers", "faint")]

    def factory_rows(self, width: int, fac: Dict[str, Any]) -> List[Row]:
        rows = self.factory_lines(width, fac)
        for line in rows:
            line.stop = ("factory", fac["id"])
        return rows

    def stamp(self, event: Dict[str, Any]) -> str:
        """The time a feed event shows: its clock time, else `today` or its day."""
        now = self.now()
        if event.get("at"):
            return when_words(event["at"], now)
        if event.get("date") == time.strftime("%Y-%m-%d", time.localtime(now)):
            return "today"
        return time.strftime("%d %b", time.gmtime(parse_iso(event.get("date")) or now))

    def news(self, fac: Dict[str, Any]) -> List[Dict[str, Any]]:
        """A factory's outcomes in the feed, newest first: what its New tells.

        Work that went live is told once, so its earlier finished or PR ready is left out.
        """
        mine = [e for e in self.record["feed"] if e["factory"] == fac["id"] and e["word"] in NEW_LABELS]
        live = {e.get("job") for e in mine if e["word"] == "went live"}
        return [e for e in mine if not (e["word"] in ("finished", "PR ready") and e.get("job") in live)]

    def quiet(self, fac: Dict[str, Any]) -> bool:
        """Whether a factory is quiet: nothing needs the owner there, nothing runs or stopped, and nothing is new."""
        return not (fac["needs"] or self.overview_jobs(fac) or fac.get("routine_runs") or self.news(fac))

    def told(self, fac: Dict[str, Any]) -> Dict[str, Any]:
        """A factory told as Now, New and Next, the one composition both screens draw.

        Now is what runs or stopped there (the overview's jobs and routine
        lines), New the outcomes since the feed's start, each with its time,
        its link and, for a settled call, the owner's answer, and Next the
        head of its line. A factory with none of those and nothing that needs
        the owner is quiet: one line of words. docs/factory-pane.md owns it.
        """
        jobs = self.overview_jobs(fac)
        routine = list(fac.get("routine_runs") or [])
        news = self.news(fac)
        new = [self.new_item(event) for event in news[:NEW_CAP]]
        more = news[NEW_CAP:]
        # Its own page's Lately lists the first PAGE_FEED of the same outcomes.
        more_words = ("and %d more" % len(more) + (", on its own page" if len(news) <= PAGE_FEED else "")
                      if more else "")
        nxt = fac.get("next")
        lined = nxt["then"] + 1 if nxt else 0
        needs = len(fac["needs"])
        quiet = self.quiet(fac)
        words = ""
        if quiet:
            later = [c for c in self.record.get("coming_back") or [] if c["factory"] == fac["id"]]
            parts = ["idle since %s" % when_words(fac["idle_since"], self.now()) if fac.get("idle_since")
                     else "nothing is running",
                     plural(lined, "job lined up", "jobs lined up") if lined else "nothing lined up"]
            if later:
                parts.append("%d put off, the next back on %s" % (len(later), day_words(later[0]["until"])))
            words = ", ".join(parts)
            words = words[0].upper() + words[1:] + "."
        return {
            "quiet": quiet, "quiet_words": words,
            "badge": "%d %s you" % (needs, "needs" if needs == 1 else "need") if needs else "",
            "jobs": jobs, "routine": routine,
            "now": "" if any(j["state"] == "busy" for j in jobs) or any(r["running"] for r in routine)
            else "Nothing is running.",
            "new": new, "more": len(more), "more_words": more_words,
            "next": {"title": nxt["title"], "once_you_answer": bool(nxt["once_you_answer"]), "then": nxt["then"],
                     "words": "".join([", once you answer" if nxt["once_you_answer"] else "",
                                       ", then %d more lined up" % nxt["then"] if nxt["then"] else ""])}
            if nxt else None}

    def new_item(self, event: Dict[str, Any]) -> Dict[str, Any]:
        """One outcome as New and Lately tell it: its word as a label, the work's title, its time and links."""
        word = event["word"]
        title = event.get("title") or event["text"]
        if word == "settled":
            text = event["text"]
        elif word == "failed":
            text = "%s. Starship is on it." % title.rstrip(".")
        elif word == "closed":
            text = "%s, with no change or report on record." % title.rstrip(".")
        else:
            text = title
        return {"id": event.get("job"), "word": word, "label": NEW_LABELS[word],
                "text": text, "when": self.stamp(event), "pr": event.get("pr") if word == "went live" else None,
                "read": list(event.get("read") or []), "title": title}

    def lately_events(self, fac: Dict[str, Any]) -> List[Dict[str, Any]]:
        """What a factory's own page lists under Lately: its New (news()), PAGE_FEED of them at most.

        What was said is its CONVERSATION and a call that asks for the owner is a card, so neither is here.
        """
        return self.news(fac)[:PAGE_FEED]

    def page_state(self, fac: Dict[str, Any]) -> str:
        """The one sentence of state under a factory's name on its own page.

        What needs the owner there, what runs or stopped (its Now), and, when
        something moved, what went live and which reports came in (its New).
        """
        told = self.told(fac)
        needs = len(fac["needs"])
        words = ["Nothing needs you." if not needs else "%s %s you." % (
            plural(needs, "thing", "things"), "needs" if needs == 1 else "need")]
        running = sum(1 for j in told["jobs"] if j["state"] == "busy") + \
            sum(1 for r in told["routine"] if r["running"])
        second = "Nothing is running" if not running else "%s %s running" % (
            plural(running, "job", "jobs"), "is" if running == 1 else "are")
        trouble = []
        stopped = sum(1 for j in told["jobs"] if j["state"] == "stopped")
        failed = sum(1 for j in told["jobs"] if j["state"] == "failed")
        if stopped:
            trouble.append("%s %s stopped" % (plural(stopped, "job", "jobs"), "has" if stopped == 1 else "have"))
        if failed:
            trouble.append("%s hit a problem" % plural(failed, "job", "jobs"))
        words.append(second + (", and %s." % " and ".join(trouble) if trouble else "."))
        news = self.news(fac)
        live = sum(1 for e in news if e["word"] == "went live")
        reports = sum(1 for e in news if e["word"] == "report ready")
        moved = []
        if live:
            moved.append("%s went live" % plural(live, "change", "changes"))
        if reports:
            moved.append("%s %s ready" % (plural(reports, "report", "reports"), "is" if reports == 1 else "are"))
        if moved:
            third = "%s %s." % (" and ".join(moved), since_words(self.record, self.now()))
            words.append(third[0].upper() + third[1:])
        return " ".join(words)

    def page_parts(self, fac: Dict[str, Any]) -> Dict[str, Any]:
        """A factory's own page, top to bottom, the one composition both screens draw.

        `now` is what Happening now lists: the overview's Now (told()) and any
        other job under way that the queue does not hold; `next` the first
        UP_NEXT jobs in line and `lined` how many are in line in all; `folded`
        the rest of the queue, one count per queue word, the overflow of the
        line first; `lately` its newest feed events; `coming` every call of
        this factory put off to a date, soonest first. A call with a card
        under NEEDS YOU, or on its older questions shelf, is in neither list.
        """
        told = self.told(fac)
        shown, folded = self.page_jobs(fac)
        line = [j for j in shown if j["state"] in ("next", "later")]
        routine = {ident for r in told["routine"] for ident in r["folded"]}
        carded = set(fac["needs"])
        listed = {j["id"] for j in told["jobs"]} | carded | routine
        now = [j for j in told["jobs"] if j["id"] not in carded] + \
            [j for j in shown if j not in line and j["id"] not in listed]
        return {"state": self.page_state(fac), "now": now, "next": line, "folded": folded,
                "lined": len(line) + len(folded["in line"]),
                "lately": [self.new_item(e) for e in self.lately_events(fac)],
                "coming": [c for c in self.record.get("coming_back") or [] if c["factory"] == fac["id"]]}

    def routine_words(self, line: Dict[str, Any]) -> Tuple[List[str], str]:
        """A routine line's words, how many runs today and the last of them, and what it does now if anything."""
        words = [plural(line["today"], "run today", "runs today") if line["today"] else "no run today"]
        if line.get("last"):
            words.append("last %s %s" % (line["last_word"], when_words(line["last"], self.now())))
        return words, "busy" if line["running"] else ("waiting" if line["folded"] else "")

    def clock_words(self) -> str:
        """The day and time the screen shows as now."""
        return time.strftime("%a %H:%M", time.localtime(self.now()))

    @staticmethod
    def about_words(fac: Dict[str, Any]) -> List[str]:
        """What a factory's page says under its name: what it is for (its HAPPENING NOW says who is at work)."""
        about = fac.get("about") or ", ".join(fac["projects"]) or ""
        return [about] if about else []

    @staticmethod
    def learned(fac: Dict[str, Any]) -> List[Tuple[str, str]]:
        """A factory's latest lessons, each with the day it shows."""
        return [(time.strftime("%d %b", time.gmtime(parse_iso(item["when"]) or 0)) if item.get("when") else "",
                 item["what"]) for item in fac["learned"][-5:]]

    def talk(self, fac: Dict[str, Any]) -> List[Tuple[str, str, str]]:
        """What was said to and by a factory's crew: when, who, and the words."""
        return [(when_words(line["at"], self.now()) if line.get("at") else "", line["who"], line["said"])
                for line in fac["talk"]]

    def routine_rows(self, width: int, fac: Dict[str, Any], pad: int = 5) -> List[Row]:
        """A routine kind's runs folded into one line: how many today, the last, and whether one runs now."""
        rows = []
        for line in fac.get("routine_runs") or []:
            words, now = self.routine_words(line)
            rows.append(row(width, [S(" " * pad), S("↻ ", "faint"), S(line["kind"], "mist"),
                                    S("  " + " · ".join(words), "faint")], [S(now, "amber")] if now else []))
        return rows

    def factory_lines(self, width: int, fac: Dict[str, Any]) -> List[Row]:
        """A factory on the overview, told as Now, New and Next (told()); a quiet one is one line."""
        told = self.told(fac)
        band = self.here("factory", fac["id"])
        head = [S(" "), self.mark("factory", fac["id"]), S(fac["name"], "ice", True)]
        if told["quiet"]:
            return [row(width, head + [S("   " + told["quiet_words"], "faint")], band=band)]
        right = [S(told["badge"], "red")] if told["badge"] else []
        if fac["steered_by"] == "you":
            right += ([S(" · ", "faint")] if right else []) + self.steer(fac)
        rows = [row(width, head, right, band=band)]
        pad = 11

        def labelled(lines: List[Row], label: str) -> List[Row]:
            # The part's word takes the place of the first line's leading spaces.
            if lines:
                lines[0][0] = S(("     " + label).ljust(pad), "faint")
            return lines

        now = flow(width, [S(" " * pad)], told["now"], "mist") if told["now"] else []
        for job in told["jobs"]:
            now += self.job_rows(width, job, full=False, pad=pad)
        now += self.routine_rows(width, fac, pad=pad)
        rows += labelled(now, "now")
        new: List[Row] = []
        for item in told["new"]:
            lead = [S(" " * pad), S(item["when"].ljust(7), "faint"),
                    S(item["label"] + ": ", FEED_COLOUR.get(item["word"], "amber"), True)]
            new += flow(width, lead, item["text"], "ice", indent=pad + 7, cap=3)
            if item["read"]:
                new.append(read_row(width, " " * (pad + 7), item))
            if item["pr"]:
                new.append(link_row(width, " " * (pad + 7), item))
        if told["more"]:
            new.append(row(width, [S(" " * (pad + 7)), S(told["more_words"], "faint")]))
        rows += labelled(new, "new")
        nxt = told["next"]
        if nxt:
            rows += labelled(flow(width, [S(" " * pad), S(nxt["title"], "mist")], nxt["words"], "faint",
                                  indent=pad), "next")
        return rows

    def notice_rows(self, width: int) -> List[Row]:
        """What the last writing key did: sent, not sent, or cancelled, in full."""
        if not self.notice:
            return []
        rows = flow(width, [S(" ")], self.notice[0], self.notice[1], True)
        for line in rows:
            line.band = True
        return rows + [row(width)]

    def talk_words(self, talk: Dict[str, Any]) -> str:
        """How the open talk box takes words: by voice, or typed and why."""
        if talk.get("mode") in ("listening", "writing"):
            return "by voice"
        return "typed" if self.voice else "typed · no desk voice"

    def box_rows(self, width: int) -> List[Row]:
        """The open confirmation or talk box: a floating field, each row exactly as wide as the box.

        Its top edge names what it is about and, in its corner, how it takes
        words or that nothing is sent yet; inside are the words themselves,
        always in sight, and the keys that send or cancel them.
        """
        confirm, talk = self.confirm, self.talking
        wide = min(width - 6, 96)
        inner = wide - 6
        edge = "amber" if confirm is not None else "cyan"
        lines: List[List[Tuple[str, str, bool]]] = []
        hint_colour = "mist"
        if confirm is not None:
            title, corner = confirm["title"], "not sent yet"
            lines = [[S(line, "ice", True)] for line in wrap(confirm["prompt"], inner)[:3]]
            hint = "enter sends it to Starship · esc cancels"
        else:
            title, mode = talk["about"], talk.get("mode")
            heard = [[S(line, "ice", True)] for line in wrap(talk.get("live") or "", inner - 1)[-3:]]
            if mode == "listening":
                corner = "%s %d:%02d" % (("recorded" if talk.get("held") else "● listening",)
                                         + divmod(int(talk.get("seconds") or 0), 60)) \
                    if talk.get("hearing") else "starting the microphone"
                meter = "".join("▁▂▃▄▅▆▇█"[min(int(level * 8), 7)] for level in talk.get("levels") or [])
                if talk.get("live"):
                    heard[-1].append(S("_", "cyan"))
                lines = (heard if talk.get("live") else [[S("speak now", "faint")]]) + [[S(meter, "amber")]]
                hint = ("enter writes it down and sends it" if talk.get("held") else
                        "sends when you stop speaking, or on enter") + " · esc cancels · type to write it instead"
            elif mode == "writing":
                corner = "writing it down"
                lines = heard if talk.get("live") else [[S("…", "amber", True)]]
                hint = "it is sent as soon as it is written down · esc cancels"
            else:
                # Typed text is shown exactly as typed, broken where the field
                # ends; its last three lines stay in sight with the cursor.
                corner = self.talk_words(talk)
                room = max(inner - 3, 8)
                typed = [talk["text"][at:at + room] for at in range(0, len(talk["text"]), room)] or [""]
                if len(typed[-1]) == room:
                    typed.append("")
                shown = typed[-3:]
                lines = [[S("▸ " if index == 0 and len(typed) <= 3 else "  ", "cyan", True), S(line, "ice", True)]
                         for index, line in enumerate(shown)]
                lines[-1].append(S("_", "cyan"))
                hint = "enter sends · esc closes without sending · Starship hears this too"
                if talk.get("gone"):
                    hint, hint_colour = "This was settled elsewhere, so nothing will be sent · esc closes", "amber"
        lines = [[]] + lines + [[]] + [[S(line, hint_colour)] for line in wrap(hint, inner)]
        room = wide - 8 - len(corner)
        if len(title) > room:
            title = title[:room - 1].rstrip() + "…" if room > 0 else ""
        top = [S("╭─ ", edge), S(title, edge, True), S(" " + "─" * (wide - 8 - len(title) - len(corner)) + " ", edge),
               S(corner, edge, True), S(" ─╮", edge)]
        rows = [Row(top)]
        for line in lines:
            rows.append(Row([S("│  ", edge)] + line + [S(" " * (wide - 6 - seg_len(line))), S("  │", edge)]))
        rows.append(Row([S("╰" + "─" * (wide - 2) + "╯", edge)]))
        return rows

    def float_box(self, width: int, sight: List[Row], under: Optional[int]) -> List[Row]:
        """Lay the open box over the rows in sight, which dim behind it.

        It goes just under the row it is about (<under>, that row's place in
        sight) when it fits there, else in the middle. The rows above and
        below stay readable: the box has an outline and no fill of its own.
        """
        box = self.box_rows(width)[:len(sight)]
        inset = (width - seg_len(box[0])) // 2
        top = under + 1 if under is not None and under + 1 + len(box) <= len(sight) else \
            max((len(sight) - len(box)) // 2, 0)
        out = []
        for index, line in enumerate(sight):
            dim = [(text, "faint", False) for text, _, _ in line]
            if top <= index < top + len(box):
                dim = [S(" " * inset)] + list(box[index - top]) + [S(" " * (width - inset - seg_len(box[0])))]
            out.append(Row(dim))
        return out

    def action_stop(self) -> Optional[Tuple[str, str]]:
        """The row an open confirmation or talk box is about, while the record still holds it."""
        if self.confirm is not None:
            return ("old" if self.confirm.get("older") else "need", self.confirm["item"])
        if self.talking is not None and not self.talking.get("gone"):
            return self.talking.get("stop")
        return None

    def action_keys(self) -> str:
        """The keys line while a confirmation or the talk box is open: only what sends and what cancels."""
        talk = self.talking
        if self.confirm is not None:
            return "ENTER  send %s to Starship      ESC  cancel" % self.confirm["what"]
        if talk.get("gone"):
            return "ESC  close · nothing will be sent"
        if talk.get("mode") == "listening":
            return "ENTER  send what you said      ESC  cancel      or type instead"
        if talk.get("mode") == "writing":
            return "ESC  cancel"
        return "ENTER  send      ESC  close without sending"

    def footer(self, width: int) -> List[Row]:
        if self.confirm is not None or self.talking is not None:
            keys = row(width, [S(" " + self.action_keys(), "amber", True)])
            keys.band = True
            return [keys]
        kind, ident = self.at()
        if kind == "none":
            # Nothing to move to, open, talk to or steer: only q does anything.
            return [row(width, [S(" q quit", "faint")])]
        keys = ["↑↓ move"]
        if kind == "need":
            need = self.need(ident)
            if need["kind"] == "question" and need["options"]:
                keys.append("%s answer" % "/".join(o["key"] for o in need["options"]))
            if need["kind"] == "question":
                if not need.get("checking"):
                    keys.append("x settled?")
            else:
                keys.append("k keep · c changes")
        if kind == "fold" and self.unfolded != ident:
            keys.append("enter list them")
        if kind == "older" and self.older_open != ident:
            keys.append("enter list them")
        if kind == "old":
            keys.append("b bring back · n no longer needed")
        if self.readable():
            keys.append("r read")
        if self.openable():
            keys.append("o see the change")
        if self.unfolded or self.older_open is not None:
            keys.append("esc hide the list")
        elif not self.opened or not self.in_tab:
            keys.append("enter open" if not self.opened else "esc back")
        elif self.in_tab:
            keys.append("esc back")
        keys += ["t talk (voice)" if self.voice else "t talk (typed)", "s who steers", "q quit"]
        lines = [""]
        for key in keys:
            joined = "%s · %s" % (lines[-1], key) if lines[-1] else key
            if lines[-1] and len(joined) + 2 > width:
                lines.append(key)
            else:
                lines[-1] = joined
        return [row(width, [S(" " + line, "faint")]) for line in lines]

    # ---- the two screens -----------------------------------------------------

    def overview(self, width: int) -> List[Row]:
        rows: List[Row] = []
        needs = self.needs()
        if needs:
            rows += [row(width, [S(" NEEDS YOU", "red", True), S("  most pressing first", "faint")]), row(width)]
            rows += self.need_list(width, needs, full=False)
        else:
            rows += [row(width, [S(" NOTHING NEEDS YOU", "green", True)]), row(width)]
        rows += self.older_rows(width) + self.coming_rows(width)
        rows += [row(width, [S(" YOUR FACTORIES", "mist", True), S("  " + news_heading(self.record, self.now()),
                                                                     "faint")]), row(width)]
        if not needs and not self.record.get("history", True) and \
                not any(f["jobs"] for f in self.record["factories"]):
            # A first run: say what to do next instead of an empty screen.
            rows += flow(width, [S("     ")], FIRST_RUN_HINT, "ice")
            rows.append(row(width))
        quiet_started = False
        for fac in self.ordered():
            quiet = self.quiet(fac)
            if quiet and not quiet_started:
                quiet_started = True
                rows += [row(width, [S(" QUIET FOR NOW", "mist", True)]), row(width)]
            rows += self.factory_rows(width, fac)
            if not quiet:
                rows.append(row(width))
        if quiet_started:
            rows.append(row(width))
        return rows

    def factory_page(self, width: int) -> List[Row]:
        """A factory's own page, top to bottom (page()): its name, what it is for and one sentence of state,
        then NEEDS YOU with its older questions, HAPPENING NOW, LATELY, UP NEXT, COMING BACK,
        HOW THIS CREW WORKS and the CONVERSATION."""
        fac = self.factory(self.opened)
        page = self.page_parts(fac)
        told = self.told(fac)
        rows: List[Row] = []
        rows += [row(width, [S(" "), S("  " if fac["needs"] else "▸ ", "cyan", True), S(fac["name"], "ice", True)],
                     self.steer(fac), band=not fac["needs"])]
        rows[0].stop = ("factory", fac["id"])
        for about in self.about_words(fac):
            rows += flow(width, [S("   ")], about, "faint")
        rows += flow(width, [S("   ")], page["state"], "red" if fac["needs"] else "mist") + [row(width)]

        def heading(title: str, small: str = "") -> List[Row]:
            return [row(width, [S(" " + title, "mist", True)] + ([S("  " + small, "faint")] if small else [])),
                    row(width)]

        needs = self.needs(fac["id"])
        if needs:
            rows += [row(width, [S(" NEEDS YOU", "red", True)]), row(width)]
            rows += self.need_list(width, needs, full=True)
        older = self.older_rows(width, fac["id"])
        if older and not needs:
            rows += [row(width, [S(" NEEDS YOU", "red", True)]), row(width)]
        rows += older
        rows += heading("HAPPENING NOW")
        if told["now"]:
            rows += flow(width, [S("     ")], told["now"], "mist")
        for job in page["now"]:
            rows += self.job_rows(width, job, full=True)
        rows += self.routine_rows(width, fac)
        rows += [row(width)] + heading("LATELY", since_words(self.record, self.now()))
        if not page["lately"]:
            rows.append(row(width, [S("     Nothing new.", "faint")]))
        for item in page["lately"]:
            lead = [S("   "), S(item["when"].ljust(9), "faint"),
                    S(item["label"] + ": ", FEED_COLOUR.get(item["word"].split(" ·")[0], "amber"), True)]
            rows += flow(width, lead, item["text"], "ice", indent=12, cap=3)
            if item["read"]:
                rows.append(read_row(width, " " * 12, item))
            if item["pr"]:
                rows.append(link_row(width, " " * 12, item))
        rows += [row(width)] + heading("UP NEXT", "%d lined up" % page["lined"] if page["lined"] else "")
        if not page["next"]:
            rows.append(row(width, [S("     Nothing lined up.", "faint")]))
        for job in page["next"]:
            rows += self.job_rows(width, job, full=True)
        parts = fold_parts(page["folded"])
        if parts:
            # The rest of the queue, one count per queue word; enter lists every job it stands for.
            stop = ("fold", fac["id"])
            fold = flow(width, [S("   "), self.mark(*stop), S("· ", "faint")],
                        " · ".join(words for words, _jobs in parts), "faint")
            for line in fold:
                line.band = self.here(*stop)
            if self.unfolded == fac["id"]:
                for words, jobs in parts:
                    fold += [row(width), row(width, [S("       "), S(words, "mist", True)])]
                    fold += [row(width, [S("         · ", "faint"), S(job["title"], "ice")],
                                 [S(job_queue_words(job), "mist")]) for job in jobs]
            for line in fold:
                line.stop = stop
            rows += fold
        if page["coming"]:
            rows += [row(width)] + heading("COMING BACK", "%d put off to a date" % len(page["coming"]))
            dates = [date_words(item["until"]) for item in page["coming"]]
            room = max(len(d) for d in dates) + 2
            for date, item in zip(dates, page["coming"]):
                rows += flow(width, [S("     "), S(date.ljust(room), "faint")], item["title"], "ice")
        rows += [row(width)] + heading("HOW THIS CREW WORKS")
        if not fac["rules"] and not fac["learned"]:
            rows.append(row(width, [S("     No rules written down yet.", "faint")]))
        if fac["rules"]:
            words, colour = rules_size_words(fac.get("rules_size", profile_size(fac["rules"])),
                                             self.record.get("rules_cap", PROFILE_CAP))
            if words:
                rows += flow(width, [S("   ")], words, colour) + [row(width)]
        for rule in fac["rules"]:
            for index, line in enumerate(wrap(rule, max(width - 8, 20))):
                rows.append(row(width, [S("     " if index else "   · ", "faint"), S(line, "mist")]))
        if fac["learned"]:
            rows += [row(width), row(width, [S("   Learned lately", "mist")])]
        for stamp, what in self.learned(fac):
            rows += flow(width, [S("   "), S(stamp.ljust(8), "faint")], what, "mist")
        rows += [row(width)] + heading("CONVERSATION")
        if not fac["talk"]:
            rows.append(row(width, [S("     Nothing said here yet. Press t to talk to this crew.", "faint")]))
        for stamp, who, said in self.talk(fac):
            you = who == "you"
            rows += flow(width, [S("   "), S(stamp.ljust(10), "faint"),
                                 S(who.ljust(10), "cyan" if you else "mist")],
                         said, "ice" if you else "mist")
        return rows

    def frame(self, width: int, height: Optional[int] = None) -> List[Row]:
        """The screen: the count line and any notice on top, the keys at the bottom.

        With a height, the body between them is the part in sight: it follows
        the highlight unless it was scrolled by hand, and the row under the count
        line and the row above the keys say what is out of sight.
        """
        width = max(width, 40)
        head = self.count_line(width)
        notes = self.notice_rows(width)
        body = self.factory_page(width) if self.opened else self.overview(width)
        foot = self.footer(width)
        # An open confirmation or talk box floats just under the row it is about.
        open_box = self.confirm is not None or self.talking is not None
        about = self.action_stop()
        under = [index for index, line in enumerate(body) if about and line.stop == about]
        if not height:
            if open_box:
                body = self.float_box(width, body + [row(width)] * 12, under[-1] if under else None)
            return head + [row(width)] + notes + body + [row(width)] + foot
        room = max(height - len(head) - len(notes) - len(foot) - 2, 1)
        last = max(len(body) - room, 0)
        if self.follow:
            mine = [index for index, line in enumerate(body) if line.stop and line.stop == self.selected]
            if mine and (self.cursor == 0 or mine[0] < self.top):
                # Up onto a row: show the heading or blank row above it too.
                self.top = 0 if self.cursor == 0 else max(mine[0] - 2, 0)
            elif mine and mine[-1] >= self.top + room:
                self.top = min(mine[-1] + 2 - room, mine[0])
        self.top = min(max(self.top, 0), last)
        self.page = room
        sight = body[self.top:self.top + room]
        sight += [row(width)] * (room - len(sight))
        if open_box:
            seen = [index - self.top for index in under if self.top <= index < self.top + room]
            sight = self.float_box(width, sight, seen[-1] if seen else None)
        above, below = self.top, len(body) - self.top - room
        upper = row(width, [S(" ▲ %s above · pgup" % plural(above, "more line", "more lines"), "faint")]) \
            if above > 0 else row(width)
        lower = row(width, [S(" ▼ %s below · pgdn" % plural(below, "more line", "more lines"), "faint")]) \
            if below > 0 else row(width)
        return head + [upper] + notes + sight + [lower] + foot


def screen(view: View) -> Dict[str, Any]:
    """The screen as data (fm-factory-screen.v1): what the overview and each factory's page show.

    It is the same selection and the same words `--plain` draws, taken from
    the same View, for a second screen that lays them out its own way: which
    calls and jobs show, how long each has waited or run, the queue's counts,
    the feed's times. docs/factory-pane.md owns the fields.
    """
    record = view.record

    def need_of(need: Dict[str, Any]) -> Dict[str, Any]:
        fac = view.factory(need["factory"])
        sent = view.answered_of(need)
        return {"id": need["id"], "asking": asking(need), "factory": fac["id"], "factory_name": fac["name"],
                "kind": need["kind"], "ask": need["ask"], "title": need["title"], "why": need.get("why") or "",
                "options": [{"key": o["key"], "label": o["label"], "suggested": bool(o["suggested"])}
                            for o in need["options"]],
                "suggested_by": need.get("suggested_by") or "Starship",
                "recommendation": need.get("recommendation") or "",
                "holds_up": list(need.get("holds_up") or [])[:3], "waited": view.waited(need),
                "answered": {"key": sent.get("key")} if sent else None,
                "checking": bool(need.get("checking")), "mate": need.get("mate"), "pr": need.get("pr"),
                "summary": [{"label": p["label"], "text": p["text"]} for p in need.get("summary") or []],
                "read": bool(need.get("read"))}

    def job_of(job: Dict[str, Any]) -> Dict[str, Any]:
        words, elapsed, quiet = view.job_words(job)
        colour = "amber" if job["state"] == "busy" else STATE_COLOUR.get(job["state"], "faint")
        return {"id": job["id"], "title": job["title"], "state": job["state"], "words": words, "elapsed": elapsed,
                "colour": colour, "quiet": quiet,
                "step": STEPS.index(job["step"]) if job.get("step") in STEPS else 1,
                "queue": job_queue_words(job) if job.get("queue") else "", "read": bool(job.get("read"))}

    def shelves_of(fid: Optional[str]) -> Dict[str, Any]:
        words = shelves(record, view.now(), fid)
        coming = words["coming"]
        return {"older": {"heading": words["older_heading"], "note": words["older_note"],
                          "items": [{"id": o["id"], "asking": o["asking"], "factory": o["factory"],
                                     "factory_name": view.factory(o["factory"])["name"], "title": o["title"],
                                     "since": "since %s" % day_words(o["since"]) if o.get("since") else "",
                                     "asked": OLDER_ASKED[view.older_asked_of(o)["what"]]
                                     if view.older_asked_of(o) else ""} for o in words["older"]]},
                "coming": {"heading": coming["heading"], "rest": coming["rest"], "after": coming["after"],
                           "items": [{"id": c["id"], "factory": c["factory"],
                                      "factory_name": view.factory(c["factory"])["name"], "title": c["title"],
                                      "when": date_words(c["until"])} for c in coming["items"]]}}

    def new_of(item: Dict[str, Any]) -> Dict[str, Any]:
        return {"id": item["id"], "word": item["word"], "label": item["label"], "text": item["text"],
                "when": item["when"], "pr": item["pr"], "read": bool(item["read"]), "title": item["title"],
                "colour": FEED_COLOUR.get(item["word"].split(" ·")[0], "amber")}

    def factory_of(fac: Dict[str, Any]) -> Dict[str, Any]:
        told = view.told(fac)
        routine = []
        for line in told["routine"]:
            words, now = view.routine_words(line)
            routine.append({"kind": line["kind"], "words": words, "now": now})
        page = view.page_parts(fac)
        rules_words, rules_colour = ("", "faint") if not fac["rules"] else rules_size_words(
            fac.get("rules_size", profile_size(fac["rules"])), record.get("rules_cap", PROFILE_CAP))
        return {
            "id": fac["id"], "name": fac["name"], "state": fac["state"], "steered_by": fac["steered_by"],
            "about": view.about_words(fac),
            # Told as Now, New and Next (View.told), the overview's one block for this factory.
            "quiet": told["quiet"], "quiet_words": told["quiet_words"], "badge": told["badge"],
            "now": told["now"], "jobs": [job_of(job) for job in told["jobs"]], "routine": routine,
            "new": [new_of(item) for item in told["new"]],
            "more": told["more"], "more_words": told["more_words"],
            "next": told["next"],
            # Its own page, top to bottom (View.page_parts), as the pane's page draws it.
            "page": {
                "needs": [need["id"] for need in view.needs(fac["id"])],
                "state": page["state"],
                "now": [job_of(job) for job in page["now"]],
                "lately": [new_of(item) for item in page["lately"]],
                "lately_since": since_words(record, view.now()),
                "next": [job_of(job) for job in page["next"]], "lined": page["lined"],
                "workers": [job_of(job) for job in tab_workers(fac)],
                "folded": [{"words": words, "jobs": [{"title": job["title"], "queue": job_queue_words(job)}
                                                     for job in jobs]} for words, jobs in fold_parts(page["folded"])],
                "coming": [{"id": c["id"], "title": c["title"], "when": date_words(c["until"])}
                           for c in page["coming"]],
                "rules": list(fac["rules"]), "rules_size": rules_words,
                "rules_mark": {"red": "over", "amber": "near"}.get(rules_colour, ""),
                "learned": [{"when": stamp, "what": what} for stamp, what in view.learned(fac)],
                "shelves": shelves_of(fac["id"]),
                "talk": [{"when": stamp, "who": who, "said": said} for stamp, who, said in view.talk(fac)]}}

    # The jobs behind the bridge strip's "N stopped", the ones the top sentence counts.
    lost = record["counts"].get("lost_list") or []
    stopped = [{"id": job["id"], "factory": fac["id"], "title": job["title"]}
               for fac in record["factories"] for job in fac["jobs"]
               if job["state"] == "stopped" and job["id"] in lost]
    return {"schema": SCREEN_SCHEMA, "as_of": record.get("as_of"),
            "clock": view.clock_words(),
            "sentences": sentences(record, view.now()),
            "first_up": view.first_up(),
            "shelves": shelves_of(None),
            "stopped": stopped,
            "counts": record["counts"], "count_words": [{"words": words, "colour": colour}
                                                     for words, colour in count_words(record["counts"])],
            "queue": [words for _key, words in queue_parts(record["queue"])] if record.get("queue") else [],
            "needs": [need_of(need) for need in view.needs()],
            "factories": [factory_of(fac) for fac in view.ordered()],
            "factories_heading": news_heading(record, view.now()),
            "steps": list(STEPS), "voice": bool(view.voice)}


def kept_record(home: str) -> Dict[str, Any]:
    """The cached record, kept current the way a live pane keeps it, for a screen that asks again and again.

    It answers at once with the record on disk, built first when there is
    none, shows the overview reading's figures on it, and starts the same
    rebuilds a live pane would, in the background and under the home's one
    rebuild lock: a whole refresh when one is due, or the owner's calls alone
    when their signal or the overview's ready work moved past the record's.
    """
    record = first_record(home)
    if refresh_due(home, record):
        refresh_in_background(home)
    signal = calls_signal(home)
    if not follow_overview(record, overview_reading(home)) or (signal and signal != record.get("calls_signal")):
        refresh_calls_in_background(home)
    return record


ACTIONS = ("answer", "keep", "change", "discuss", "talk", "settled", "steer", "read", "revive", "drop")


def act(home: str, ask: Dict[str, Any]) -> Dict[str, Any]:
    """One writing key, pressed from a screen that is not the pane: the same note down the same path.

    <ask> names the action and what it is about: `answer` (item, option),
    `keep` (item), `change` and `discuss` (item, text), `talk` (factory,
    text), `settled` (item), `steer` (factory, who: you or Starship), `read`
    (item, or factory and job: a job or a report its New tells), and `revive` and `drop` (item: an older
    question, which `b` and `n` send in the pane). An `asking` beside an item is the
    asking the screen showed; when the record's differs the call was settled
    or asked again since, and nothing is sent. The answer says whether it went
    (`ok`) and the words the pane would say (`said`). Every action is a look,
    as a key press in the pane is, unless `in_tab` is true: the button was on
    a factory's own tab, and a factory's tab records no look.
    """
    action = ask.get("action")
    if action not in ACTIONS:
        raise ValueError("unknown action: %s" % action)
    now = now_epoch()
    if ask.get("in_tab") is not True:
        note_look(home, now)
    view = View(first_record(home))
    if action in ("revive", "drop"):
        item = view.older_item(ask.get("item") or "")
        if item is None or ask.get("asking") not in (None, item["asking"]):
            return {"ok": False, "said": "Not sent: this older question was settled or brought back elsewhere."}
        note = older_note(view.factory(item["factory"]), item, action)
        ok, why = send_note(home, note["request_id"], note["body"])
        if not ok:
            return {"ok": False, "said": "✗ NOT SENT: %s. Nothing reached Starship." % why.rstrip(".")}
        refresh_in_background(home)
        return {"ok": True, "said": "✓ SENT to Starship: %s" % note["done"]}
    need = view.need(ask["item"]) if ask.get("item") else None
    if ask.get("item") and action != "read" and (need is None or ask.get("asking") not in (None, asking(need))):
        return {"ok": False, "said": "Not sent: this was settled elsewhere."}
    fid = need["factory"] if need else ask.get("factory")
    if not view.has_factory(fid):
        return {"ok": False, "said": "Not sent: there is no such factory any more."}
    fac = view.factory(fid)
    text = (ask.get("text") or "").strip()

    def send(note: Dict[str, Any]) -> Dict[str, Any]:
        ok, why = send_note(home, note["request_id"], note["body"])
        if not ok:
            return {"ok": False, "said": "✗ NOT SENT: %s. Nothing reached Starship." % why.rstrip(".")}
        refresh_in_background(home)
        return {"ok": True, "said": "✓ SENT to Starship: %s" % note["done"]}

    if action == "answer":
        option = next((o for o in (need or {}).get("options") or [] if o["key"] == ask.get("option")), None)
        if need is None or need["kind"] != "question" or option is None:
            return {"ok": False, "said": "Not sent: that is not one of this question's answers."}
        return send(answer_note(fac, need, option))
    if action == "keep":
        if need is None or need["kind"] != "finished work":
            return {"ok": False, "said": "Not sent: that is not finished work waiting for you."}
        return send(keep_note(fac, need))
    if action in ("change", "discuss", "talk"):
        if not text:
            return {"ok": False, "said": "Nothing to send yet: there were no words in it."}
        if action == "talk":
            return send(talk_note(fac, {"kind": "talk"}, text, bool(ask.get("spoken")), now))
        if need is None or (need["kind"] == "finished work") != (action == "change"):
            return {"ok": False, "said": "Not sent: that is not here to talk about any more."}
        return send(talk_note(fac, {"kind": action, "item": need["id"], "title": need["title"],
                                    "pr": need.get("pr")}, text, bool(ask.get("spoken")), now))
    if action == "settled":
        if need is None or need["kind"] != "question":
            return {"ok": False, "said": "Not asked: that is not a question waiting for you."}
        # The cached record may be from before an earlier ask, so always look for one.
        outcome, words = ask_settled(home, fac, dict(need, checking=True))
        if outcome == "asked":
            refresh_in_background(home)
        return {"ok": outcome in ("asked", "already"), "said": words}
    if action == "steer":
        who = ask.get("who")
        if who not in ("you", "Starship"):
            raise ValueError("who steers is you or Starship")
        note = steer_note(fac, who, now)
        if fac["steered_by"] == who:
            return {"ok": True, "said": note["done"]}
        ok, why = send_note(home, note["request_id"], note["body"])
        if not ok:
            return {"ok": False, "said": "Who steers did not change: %s" % why}
        record_steer(home, fac["id"], who, now)
        refresh_in_background(home)
        return {"ok": True, "said": note["done"]}
    # read
    # A job, or a report its New tells (View.told).
    item = need or next((job for job in fac["jobs"] + view.told(fac)["new"]
                         if job["id"] == ask.get("job") and job.get("read")), None)
    if not item or not item.get("read"):
        return {"ok": False, "said": "Nothing to read here yet."}
    start_reading(home, list(item["read"]))
    return {"ok": True, "said": "Opening %s to read." % item["title"]}


def plain(view: View, width: int, height: Optional[int] = None) -> str:
    return "\n".join("".join(t for t, _, _ in segs).rstrip() for segs in view.frame(width, height))


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
    request_id = request_id_of(request_id)
    try:
        out = subprocess.run(inbox_cmd() + ["note", "--request-id", request_id, "--json", "-"], input=body,
                             capture_output=True, text=True, timeout=30, env=dict(os.environ, FM_HOME=home))
    except (OSError, subprocess.SubprocessError) as error:
        return False, str(error)
    if out.returncode in (0, 3):
        return True, ""
    return False, (out.stderr.strip().splitlines() or ["the inbox refused it"])[-1]


def file_reconcile(home: str, task_id: str) -> Tuple[Optional[int], str]:
    """Ask for a held call to be re-checked, through the captain-hold reconcile intake.

    bin/fm-captain-hold.sh reconcile-requests applies its binding and task
    checks and keeps one request per call; the result is when that request
    was made, which names the wake note so one request is one note.
    """
    try:
        out = subprocess.run(captain_hold_cmd() + ["reconcile-requests", "--source-id", SETTLED_SOURCE,
                                                   "--source", "the Factory pane's Already settled? key"],
                             input=task_id + "\n", capture_output=True, text=True, timeout=60,
                             env=dict(os.environ, FM_HOME=home))
    except (OSError, subprocess.SubprocessError) as error:
        return None, str(error)
    if out.returncode != 0:
        lines = (out.stdout + "\n" + out.stderr).strip().splitlines()
        why = next((l for l in lines if l.startswith("refused:")), lines[-1] if lines else "it was refused")
        if "is not bound" in why:
            why = "the pane is not set up to ask this; run bin/fm-factory-pane.sh install"
        return None, why
    requested = reconcile_pending(home).get(task_id)
    if requested is None:
        return None, "the request did not stay on record"
    return requested, ""


def settled_request_id(fid: str, need: Dict[str, Any], requested: int) -> str:
    """The wake note's request id: one per request, or per hold when the call was held again since."""
    held = need.get("since")
    stamp = held if held is not None and requested < held else requested
    return "factory.%s.settled.%s.%d" % (fid, need["id"], stamp)


def answer_note(fac: Dict[str, Any], need: Dict[str, Any], option: Dict[str, Any]) -> Dict[str, Any]:
    """The note an option key sends for a question: its request id, its body, and the words that say it went."""
    return {
        "request_id": "factory.%s.answer.%s.%s.%s" % (fac["id"], need["id"], asking(need), option["key"]),
        "body": "Answer for %s: %s %s\n\n(from the Factory pane; item %s%s)" % (
            need["title"], option["key"], option["label"], need["id"],
            ", key " + need["key"] if need.get("key") else ""),
        "done": "answer %s, %s (%s)" % (option["key"], option["label"], need["title"]),
        "mark": {"item": need["id"], "key": option["key"]}}


def keep_note(fac: Dict[str, Any], need: Dict[str, Any]) -> Dict[str, Any]:
    """The note `k` sends for finished work: keep it and land it."""
    return {
        "request_id": "factory.%s.keep.%s.%s" % (fac["id"], need["id"], asking(need)),
        "body": "Keep %s: please land it.\n\n(from the Factory pane; item %s%s)" % (
            need["title"], need["id"], ", " + need["pr"] if need.get("pr") else ""),
        "done": "keep %s and land it" % need["title"],
        "mark": {"item": need["id"], "key": None}}


def older_note(fac: Dict[str, Any], item: Dict[str, Any], what: str) -> Dict[str, Any]:
    """The note an older question's button sends: `revive` brings it back into NEEDS YOU, `drop` says it is
    no longer needed. Starship acts on either, as on every other note."""
    if what == "revive":
        body = "Bring back: %s. Hold it for me again so it is back in Needs you." % item["title"]
        done = "bring back %s" % item["title"]
    else:
        body = "No longer needed: %s. Close it; I do not need to decide it any more." % item["title"]
        done = "%s is no longer needed" % item["title"]
    return {"request_id": "factory.%s.%s.%s.%s" % (fac["id"], what, item["id"], item["asking"]),
            "body": body + "\n\n(from the Factory pane; item %s)" % item["id"], "done": done,
            "mark": {"older": item["id"], "what": what}}


def talk_note(fac: Dict[str, Any], talk: Dict[str, Any], text: str, spoken: bool, now: int) -> Dict[str, Any]:
    """The note the talk box sends: to a crew (kind talk), about a question (discuss), or changes to finished work."""
    source = "spoken into the Factory pane" if spoken else "from the Factory pane"
    if talk["kind"] == "talk":
        body = "To the %s crew: %s\n\n(%s)" % (fac["name"], text, source)
        rid = "factory.%s.talk.%d" % (fac["id"], now)
    elif talk["kind"] == "change":
        body = "Changes for %s: %s\n\n(%s; item %s%s)" % (
            talk["title"], text, source, talk["item"], ", " + talk["pr"] if talk.get("pr") else "")
        rid = "factory.%s.change.%s.%d" % (fac["id"], talk["item"], now)
    else:
        body = "About %s: %s\n\n(%s; item %s)" % (talk["title"], text, source, talk["item"])
        rid = "factory.%s.talk.%s.%d" % (fac["id"], talk["item"], now)
    done = '%s"%s"%s' % ("(voice) " if spoken else "", tidy(text, 90),
                         ". It passes it on to the %s crew." % fac["name"] if talk["kind"] == "talk" else "")
    return {"request_id": rid, "body": body, "done": done}


def steer_note(fac: Dict[str, Any], who: str, now: int) -> Dict[str, Any]:
    """The note `s` sends when who steers a factory changes to <who>, `you` or `Starship`."""
    return {
        "request_id": "factory.%s.steer.%d" % (fac["id"], now),
        "body": ("I steer %s myself from now on." if who == "you" else "Starship steers %s again.") % fac["name"]
                + "\n\n(from the Factory pane; who steers is recorded in state/factory/steer.log)",
        "done": ("You steer %s now." if who == "you" else "Starship steers %s again.") % fac["name"]}


def ask_settled(home: str, fac: Dict[str, Any], need: Dict[str, Any]) -> Tuple[str, str]:
    """File a reconcile request for a held call and wake Starship to re-check it.

    The outcome is `already` when Starship is already checking it and nothing
    was filed or sent, `refused` when the request could not be filed, `unsent`
    when the wake note did not go, or `asked`; the second value is the words
    that say so.
    """
    if need.get("checking"):
        pending = reconcile_pending(home).get(need["id"])
        sent = {note.get("request_id") for note in inbox_receipts(home)}
        if pending is not None and settled_request_id(fac["id"], need, pending) in sent:
            return "already", "Starship is already checking this."
    requested, why = file_reconcile(home, need["id"])
    if requested is None:
        return "refused", "Not asked: %s" % why
    body = ("Already settled? %s\n\n"
            "The owner thinks this held call is already settled, all or in part, in conversation. "
            "Re-read the conversation now and record it in this turn: close the call with the evidence "
            "(fm-captain-hold.sh reconcile close), or rewrite what still stands by retitling it with "
            "bin/fm-tasks-axi.sh update %s --title '<new title>', then holding it again with "
            "bin/fm-captain-hold.sh hold %s --reason '<new reason>'. A rewritten call still retires its "
            "pending request with reconcile note. The reconcile request for it is already filed; the "
            "captain-hold-lifecycle skill owns both outcomes."
            "\n\n(from the Factory pane; item %s)" % (need["title"], need["id"], need["id"], need["id"]))
    ok, why = send_note(home, settled_request_id(fac["id"], need, requested), body)
    if not ok:
        return "unsent", "Not sent: %s" % why
    return "asked", "Asked Starship to check whether %s is already settled." % need["title"]


def start_reading(home: str, sources: List[str]) -> subprocess.Popen:
    """Run the reader on <sources> in the background, its words kept in state/factory/read.log."""
    seam = os.environ.get("FM_FACTORY_READ")
    cmd = shlex.split(seam) if seam else ["bash", os.path.join(BIN, "fm-read.sh")]
    os.makedirs(pane_dir(home), exist_ok=True)
    with open(os.path.join(pane_dir(home), "read.log"), "w", encoding="utf-8") as log:
        return subprocess.Popen(cmd + list(sources), stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                start_new_session=True, env=dict(os.environ, FM_HOME=home))


def start_opening(home: str, url: str) -> subprocess.Popen:
    """Open <url> in the browser in the background."""
    seam = os.environ.get("FM_FACTORY_OPEN")
    cmd = shlex.split(seam) if seam else ["open" if sys.platform == "darwin" else "xdg-open"]
    return subprocess.Popen(cmd + [url], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, start_new_session=True, env=dict(os.environ, FM_HOME=home))


def record_steer(home: str, fid: str, who: str, now: int) -> None:
    path = os.path.join(pane_dir(home), "steer.log")
    os.makedirs(pane_dir(home), exist_ok=True)
    with open(path, "a", encoding="utf-8") as handle:
        handle.write("%d\t%s\t%s\n" % (now, fid, who))


def mic_command() -> List[str]:
    """The microphone recorder, or nothing where this machine has none.

    It is a command that writes what the microphone hears to its standard
    output as raw 16-bit little-endian mono samples at VOICE_RATE until it is
    stopped. FM_FACTORY_MIC names one (empty turns voice off); otherwise it is
    ffmpeg reading the Mac's default input, the recorder bin/fm-call-mic.sh
    also uses.
    """
    named = os.environ.get("FM_FACTORY_MIC")
    if named is not None:
        return shlex.split(named)
    if sys.platform != "darwin":
        return []
    ffmpeg = shutil.which("ffmpeg") or next(
        (path for path in ("/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg") if os.access(path, os.X_OK)), None)
    if not ffmpeg:
        return []
    return [ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-f", "avfoundation", "-i", ":default",
            "-ac", "1", "-ar", str(VOICE_RATE), "-f", "s16le", "-"]


def stt_command() -> List[str]:
    """The command that writes a recording down, run as `<cmd> <audio-file>`: the desk voice's own."""
    named = os.environ.get("FM_FACTORY_STT")
    return shlex.split(named) if named else ["bash", os.path.join(BIN, "fm-deepgram-stt.sh")]


def voice_ready(home: str) -> bool:
    """Whether the talk box can listen here: a recorder on this machine and the desk voice's speech key."""
    if not mic_command():
        return False
    if os.environ.get("FM_FACTORY_STT"):
        return True
    script = '. "$1/fm-deepgram-lib.sh" && [ -n "$(fm_deepgram_api_key)" ]'
    try:
        return subprocess.run(["bash", "-c", script, "fm-factory", BIN], capture_output=True, timeout=10,
                              stdin=subprocess.DEVNULL, env=dict(os.environ, FM_HOME=home)).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


class Voice:
    """One spoken note: the microphone heard until the speaker stops, then written down.

    The recorder's samples are read in a thread, a tenth of a second at a time.
    The room's own level is the quietest recent tenth: the first VOICE_SETTLE
    tenths only measure it, and it is taken as no louder than
    VOICE_LOUDEST_ROOM so that speech from the first moment still counts once
    they are over; after them a tenth twice as loud as it, and louder than
    VOICE_SPEECH, is speech.
    The recording ends by itself once VOICE_QUIET_STOP of quiet follows speech,
    when no speech came within VOICE_NO_SPEECH, at VOICE_MAX, or when the
    recorder stops.

    While it listens, only the newest VOICE_LIVE_WINDOW seconds are written
    down, at most every VOICE_LIVE_EVERY seconds, to show the words; what is
    sent is one writing down of the whole note when it ends. So what a note
    costs the speech service grows with its length and no faster. A dropped
    note is never written down afterwards and leaves no file.
    """

    def __init__(self, command: List[str], path: str, home: str):
        self.path = path
        self.home = home
        self.live = ""                     # the newest words heard, written down while it is still listening
        self.live_at = 0                   # how many bytes of samples had been heard when those were written
        self.dropped = False               # cancelled: nothing more of it is written down or kept
        self.stt: Optional[subprocess.Popen] = None   # the writing down under way
        self.lock = threading.Lock()       # a drop and the start of a writing down never interleave
        self.samples = bytearray()
        self.levels: List[float] = []      # each tenth's loudness, 0 to 1 on a scale that suits a meter
        self.spoken = 0                    # tenths that were speech
        self.quiet = 0                     # tenths of quiet since the last speech
        self.loudest = 0.0                 # the loudest tenth, of 32768; nothing at all means no microphone
        self.over = False
        self.floor = float(VOICE_LOUDEST_ROOM)
        self.words: Optional[str] = None   # what was said, once written down
        self.failed = ""                   # why it could not be written down
        self.proc = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, start_new_session=True)
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()
        self.follower = threading.Thread(target=self.follow, daemon=True)
        self.follower.start()

    @property
    def heard(self) -> bool:
        """Speech, not a click: at least three tenths of a second of it."""
        return self.spoken >= 3

    def seconds(self) -> float:
        return len(self.samples) / 2 / VOICE_RATE

    def read(self) -> None:
        stream = self.proc.stdout
        while not self.over and stream is not None:
            data = stream.read(VOICE_CHUNK * 2)
            if not data:
                break
            self.samples += data
            tenth = array.array("h")
            tenth.frombytes(data[:len(data) // 2 * 2])
            if sys.byteorder == "big":
                tenth.byteswap()
            level = math.sqrt(sum(x * x for x in tenth) / max(len(tenth), 1))
            # The floor drops to a quieter tenth at once and creeps up slowly,
            # so it follows the room and not the voice.
            settling = len(self.levels) < VOICE_SETTLE
            self.floor = max(min(level, self.floor if settling else self.floor * 1.01), 1.0)
            self.loudest = max(self.loudest, level)
            if not settling and level > max(self.floor * 2, VOICE_SPEECH):
                self.spoken += 1
                self.quiet = 0
            else:
                self.quiet += 1
            self.levels.append(min(max(math.log10(max(level, 1.0)) - 1.5, 0.0) / 2.5, 1.0))
            if (self.heard and self.quiet >= VOICE_QUIET_STOP) or len(self.levels) >= VOICE_MAX or (
                    not self.heard and len(self.levels) >= VOICE_NO_SPEECH):
                break
        self.over = True

    def stop(self) -> None:
        """Stop the recorder; what was heard so far is kept."""
        self.over = True
        if self.proc.poll() is None:
            try:
                os.killpg(self.proc.pid, signal.SIGTERM)
            except OSError:
                pass
        try:
            self.proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(self.proc.pid, signal.SIGKILL)
            except OSError:
                pass
        self.reader.join(timeout=2)

    def hush(self) -> None:
        """Stop the writing down under way, if any."""
        proc = self.stt
        if proc is not None and proc.poll() is None:
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except OSError:
                pass

    def write(self, path: str, start: int, size: int) -> Tuple[Optional[str], str]:
        """Write the samples from byte <start> up to byte <size> down: the words, or nothing and why.

        A dropped note is not written down: nothing starts once it is dropped,
        and a writing its drop interrupted leaves no file behind.
        """
        def gone() -> Tuple[Optional[str], str]:
            try:
                os.unlink(path)
            except OSError:
                pass
            return None, "it was cancelled"

        if self.dropped:
            return None, "it was cancelled"
        try:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            handle = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)   # the owner's eyes only
            with wave.open(os.fdopen(handle, "wb"), "wb") as out:
                out.setnchannels(1)
                out.setsampwidth(2)
                out.setframerate(VOICE_RATE)
                out.writeframes(bytes(self.samples[start // 2 * 2:size // 2 * 2]))
            with self.lock:
                if self.dropped:
                    return gone()
                proc = self.stt = subprocess.Popen(
                    stt_command() + [path], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE, text=True, start_new_session=True,
                    env=dict(os.environ, FM_HOME=self.home))
            try:
                out_text, err_text = proc.communicate(timeout=900)
            except subprocess.TimeoutExpired:
                self.hush()
                out_text, err_text = proc.communicate()
        except (OSError, subprocess.SubprocessError, wave.Error) as error:
            return gone() if self.dropped else (None, str(error) or "it could not be read")
        if self.dropped:
            return gone()
        if proc.returncode != 0:
            return None, (err_text.strip().splitlines() or ["the speech service did not answer"])[-1]
        return " ".join(out_text.split()), ""

    def follow(self) -> None:
        """While it listens, write the newest few seconds down to show the words being said.

        Only the last VOICE_LIVE_WINDOW seconds go to the speech service, and
        no more often than every VOICE_LIVE_EVERY seconds; a writing that
        failed is tried again only after a wait that doubles each time. An
        ellipsis leads the words once the note is longer than that window.
        """
        part = self.path + ".part"
        window = VOICE_LIVE_WINDOW * VOICE_RATE * 2
        due, wait = 0.0, VOICE_LIVE_BACKOFF
        while not self.over and not self.dropped:
            size = len(self.samples)
            if not self.heard or size - self.live_at < VOICE_RATE * 2 or time.monotonic() < due:
                time.sleep(0.1)
                continue
            began = time.monotonic()
            words, _why = self.write(part, max(size - window, 0), size)
            if words is None:
                due, wait = began + wait, min(wait * 2, VOICE_LIVE_BACKOFF_MAX)
                continue
            due, wait = began + VOICE_LIVE_EVERY, VOICE_LIVE_BACKOFF
            self.live, self.live_at = ("… " if size > window else "") + words, size
        try:
            os.unlink(part)
        except OSError:
            pass

    def write_down(self) -> None:
        """Write the whole recording down once, in a thread; `words` or `failed` says when it is done."""
        def run() -> None:
            self.follower.join()
            if not self.dropped:
                self.words, self.failed = self.write(self.path, 0, len(self.samples))
        self.hush()   # the words being shown are no longer needed
        threading.Thread(target=run, daemon=True).start()

    def keep(self, home: str, why: str) -> Optional[str]:
        """Hand a recording that was not written down to the desk voice's unsent recordings; its new path."""
        try:
            out = subprocess.run(["bash", os.path.join(BIN, "fm-desk-voice.sh"), "keep", "--purpose", "dictate",
                                  "--reason", why, self.path], capture_output=True, text=True, timeout=30,
                                 stdin=subprocess.DEVNULL, env=dict(os.environ, FM_HOME=home))
        except (OSError, subprocess.SubprocessError):
            return None
        return out.stdout.strip() or None if out.returncode == 0 else None

    def drop(self) -> None:
        """Stop and forget: nothing more of it is written down, and no file of it stays."""
        with self.lock:
            self.dropped = True
            self.hush()
        self.stop()
        self.follower.join(timeout=3)
        for path in (self.path, self.path + ".part"):
            try:
                os.unlink(path)
            except OSError:
                pass


class Pane:
    """The live pane: a View plus the keys, the cache and Herdr."""

    def __init__(self, home: str, opened: Optional[str], in_tab: bool, item: Optional[str] = None):
        self.home = home
        record = first_record(home)
        self.view = View(record, opened=opened, in_tab=in_tab, item=item, voice=voice_ready(home))
        self.voice: Optional[Voice] = None   # the spoken note being heard or written down
        # A pane stopped while it listened can leave the part it was writing down.
        for name in os.listdir(pane_dir(home)) if os.path.isdir(pane_dir(home)) else []:
            if re.match(r"^talk-\d+\.wav\.part$", name) and name != "talk-%d.wav.part" % os.getpid():
                part = os.path.join(pane_dir(home), name)
                try:
                    if time.time() - os.stat(part).st_mtime > 900:
                        os.unlink(part)
                except OSError:
                    pass
        self.loaded = self.record_stamp()
        self.calls_checked = 0.0
        self.refresh_checked = 0.0
        self.focus_file = os.environ.get("FM_FACTORY_FOCUS_FILE") or ""
        # Calls asked about from this pane: id -> (the card's since, when asked).
        self.asked: Dict[str, Tuple[Optional[int], float]] = {}
        self.focused_since: Optional[float] = None
        self.last_key = 0.0
        self.drawn: List[Row] = []     # the rows on screen, top first, for clicks
        self.reading: Optional[Tuple[subprocess.Popen, str]] = None
        # The overview reading is read off the drawing thread, about once a
        # second, so a slow read never holds a frame or a key.
        self.overview: List[Optional[Dict[str, Any]]] = [None]
        threading.Thread(target=self.read_overview, daemon=True).start()

    def read_overview(self) -> None:
        """Read the overview again and again, resting at least as long as the
        last read took, so a slow read never takes most of the machine."""
        while True:
            began = time.monotonic()
            self.overview[0] = overview_reading(self.home)
            time.sleep(max(1.0, time.monotonic() - began))

    def take_focus(self) -> bool:
        """Read and remove an item id written to the focus file; True when one came."""
        if not self.focus_file or not os.path.isfile(self.focus_file):
            return False
        item = read_text(self.focus_file, 512).strip().splitlines()[:1]
        try:
            os.unlink(self.focus_file)
        except OSError:
            pass
        if not item or not item[0]:
            return False
        self.view.want(item[0])
        if self.view.need(item[0]) is None:
            refresh_in_background(self.home)
        return True

    def looked(self) -> None:
        """A key was pressed: the owner is looking. A factory's tab records no look."""
        self.last_key = time.time()
        if not self.view.in_tab:
            note_look(self.home, now_epoch())

    def check_focus(self) -> None:
        """The pane focused in Herdr for FOCUS_HOLD seconds is a look.

        Focus alone keeps the look going for at most FOCUS_CAP after the focus
        began or the last key press, whichever is later; after that only a key
        press or a new focus does. Only Herdr saying the pane is not focused
        ends a focus; a failed or unreadable answer leaves it as it was.
        """
        pane_id = os.environ.get("HERDR_PANE_ID")
        if self.view.in_tab or not pane_id:
            return
        ok, data = herdr(["pane", "get", pane_id], timeout=2)
        pane = ((data or {}).get("result") or {}).get("pane") if ok and isinstance(data, dict) else None
        if not isinstance(pane, dict) or pane.get("pane_id") != pane_id:
            return
        if pane.get("focused") is not True:
            self.focused_since = None
            return
        clock = time.time()
        if self.focused_since is None:
            self.focused_since = clock
        if clock - self.focused_since >= FOCUS_HOLD and clock - max(self.focused_since, self.last_key) <= FOCUS_CAP:
            note_look(self.home, now_epoch())

    def say(self, text: str, colour: str = "green", seconds: int = 12) -> None:
        self.view.notice = (text, colour, time.time() + seconds)

    def not_sent(self, why: str) -> None:
        """Say plainly that nothing reached Starship; it stays up until the next key or for a minute."""
        self.say("✗ NOT SENT: %s" % why, "red", 60)

    def record_stamp(self) -> int:
        try:
            return os.stat(os.path.join(pane_dir(self.home), "record.json")).st_mtime_ns
        except OSError:
            return 0

    def reload(self) -> None:
        stamp = self.record_stamp()
        if stamp != self.loaded:
            record = cached(self.home)
            if record:
                self.view.adopt(record)
                self.loaded = stamp
                self.keep_asked()
        now = time.monotonic()
        if now - self.refresh_checked >= REBUILD_CHECK_EVERY:
            self.refresh_checked = now
            if refresh_due(self.home, self.view.record):
                refresh_in_background(self.home)

    def watch_calls(self) -> None:
        """Follow the overview's figures, and rebuild the owner's calls once their
        signal or the overview's ready work moves past the record's, checking at
        most once a second."""
        now = time.monotonic()
        if now - self.calls_checked < 1:
            return
        self.calls_checked = now
        signal = calls_signal(self.home)
        same_calls = follow_overview(self.view.record, self.overview[0])
        if not same_calls or (signal and signal != self.view.record.get("calls_signal")):
            refresh_calls_in_background(self.home)

    def keep_asked(self) -> None:
        """A record read before a press here cannot know its request: the card stays checking."""
        read_at = float(self.view.record.get("read_at") or 0)
        for ident, (since, asked_at) in list(self.asked.items()):
            need = self.view.need(ident)
            if need is None or need.get("since") != since or read_at >= asked_at:
                del self.asked[ident]
            else:
                need["checking"] = True

    def factory_of_stop(self) -> Optional[str]:
        if self.view.opened:
            return self.view.opened
        kind, ident = self.view.at()
        if kind == "factory":
            return ident
        if kind == "need":
            return self.view.need(ident)["factory"]
        if kind == "old":
            item = self.view.older_item(ident)
            return item["factory"] if item else None
        return None

    def need_at(self) -> Optional[Dict[str, Any]]:
        kind, ident = self.view.at()
        return self.view.need(ident) if kind == "need" else None

    def read(self, item: Optional[Tuple[str, List[str]]]) -> None:
        """Open what there is to read about one item, without waiting for the reader."""
        if not item:
            self.say("Nothing to read here yet.", "mist")
            return
        title, sources = item
        try:
            self.reading = (start_reading(self.home, sources), title)
        except OSError as error:
            self.say("%s did not open: %s" % (title, error), "red", 12)
            return
        self.say("Opening %s to read." % title, "cyan")

    def open_change(self, item: Optional[Tuple[str, str]]) -> None:
        """Open the PR of a change that went live in the browser, without waiting for it."""
        if not item:
            self.say("No change to open here.", "mist")
            return
        title, pr = item
        try:
            start_opening(self.home, pr)
        except OSError as error:
            self.say("%s did not open: %s" % (title, error), "red", 12)
            return
        self.say("Opening the change %s." % title, "cyan")

    def check_reading(self) -> None:
        """Say so when the reader stopped without opening the page."""
        if not self.reading or self.reading[0].poll() is None:
            return
        proc, title = self.reading
        self.reading = None
        if proc.returncode != 0:
            said = read_text(os.path.join(pane_dir(self.home), "read.log"), 4096).strip().splitlines()
            self.say("%s did not open: %s" % (title, said[-1] if said else "the reader stopped"), "red", 12)

    def send(self, request_id: str, body: str, done: str, mark: Optional[Dict[str, Any]] = None) -> bool:
        """Send one note to Starship and say whether it went; <mark> is the answer its card then shows."""
        ok, why = send_note(self.home, request_id, body)
        if not ok:
            self.not_sent("%s. Nothing reached Starship; press the key again." % why.rstrip("."))
            return False
        self.say("✓ SENT to Starship: %s" % done, "green")
        if mark and mark.get("older"):
            self.view.older_asked[mark["older"]] = {"at": now_epoch(), "what": mark["what"]}
        elif mark:
            need = self.view.need(mark["item"])
            if need is not None:
                self.view.answered[(need["id"], asking(need))] = {"at": now_epoch(), "key": mark.get("key")}
        refresh_in_background(self.home)
        return True

    def answer(self, need: Dict[str, Any], option: Dict[str, Any]) -> Dict[str, Any]:
        """The confirmation an option key opens on a question."""
        fac = self.view.factory(need["factory"])
        return dict(answer_note(fac, need, option),
                    item=need["id"], asked=asking(need), option=option["key"],
                    what="answer %s" % option["key"], title="Your answer · %s" % need["title"],
                    prompt="%s  %s" % (option["key"], option["label"]))

    def confirm_key(self, key: str) -> bool:
        """A key while a confirmation is open: only enter or esc does anything."""
        view, confirm = self.view, self.view.confirm
        if key == "ctrl-c":
            return False
        if key == "enter":
            view.confirm = None
            self.send(confirm["request_id"], confirm["body"], confirm["done"], confirm["mark"])
        elif key == "esc":
            view.confirm = None
            self.say("Not sent: %s was cancelled." % confirm["what"], "amber")
        else:
            self.say("Press enter to send %s, or esc to cancel." % confirm["what"], "amber")
        return True

    # ---- the talk box ----------------------------------------------------------

    def open_talk(self, talk: Dict[str, Any], listen: bool) -> None:
        """Open the talk box under the highlighted row; by voice first where this machine can listen."""
        talk.update(text="", stop=self.view.at(), mode="typed", live="", held=False)
        self.view.talking = talk
        if not (listen and self.view.voice):
            return
        try:
            self.voice = Voice(mic_command(), os.path.join(pane_dir(self.home), "talk-%d.wav" % os.getpid()),
                               self.home)
            talk["mode"] = "listening"
        except OSError as error:
            self.say("The microphone did not start (%s). Type it instead." % error, "amber")

    def close_voice(self) -> None:
        if self.voice is not None:
            self.voice.drop()
            self.voice = None

    def voice_tick(self) -> None:
        """Move a spoken note on: from listening to written down to sent."""
        voice, talk = self.voice, self.view.talking
        if voice is None:
            return
        if talk is None:
            self.close_voice()
        elif talk["mode"] == "listening":
            talk.update(levels=voice.levels[-8:], seconds=voice.seconds(), hearing=bool(voice.levels),
                        live=voice.live)
            if voice.over and not talk["held"]:
                self.heard(by_enter=False)
        elif talk["mode"] == "writing" and (voice.words is not None or voice.failed):
            self.written()

    def heard(self, by_enter: bool) -> None:
        """The recording is over: write it down, or say that nothing was heard.

        Sound that never counted as speech is not written down on its own: it
        is held, and enter writes it down.
        """
        voice, talk = self.voice, self.view.talking
        voice.stop()
        silent = voice.loudest < 2
        if voice.heard or (by_enter and voice.seconds() >= 0.3):
            talk["mode"] = "writing"
            voice.write_down()
            return
        if not silent and voice.seconds() >= 0.3:
            talk["held"] = True
            self.say("Nothing counted as speech. Press enter to write down what was recorded, or type it instead. "
                     "Esc cancels.", "amber", 60)
            return
        self.close_voice()
        talk["mode"] = "typed"
        self.not_sent("the microphone gave no sound. Type it instead, or check that this terminal may use the "
                      "microphone." if silent else "no speech was heard. Type it instead, or press esc.")

    def written(self) -> None:
        """The recording was written down, or could not be: send the words, or keep the recording."""
        voice, talk = self.voice, self.view.talking
        self.voice = None
        if voice.failed:
            kept = voice.keep(self.home, voice.failed)
            talk["mode"] = "typed"
            self.not_sent("what you said could not be written down (%s). %s Type it instead." % (
                voice.failed.rstrip("."), "The recording is saved with the desk voice's unsent recordings."
                if kept else "The recording is at %s." % voice.path))
            return
        voice.drop()
        talk["text"] = voice.words or ""
        talk["mode"] = "typed"
        if not talk["text"]:
            self.not_sent("no words were heard in what you said. Type it instead, or press esc.")
        elif not talk.get("gone"):
            self.send_talk(spoken=True)

    def send_talk(self, spoken: bool = False) -> None:
        """Send what the talk box holds; the box closes once it went, and keeps its words when it did not."""
        view, talk, now = self.view, self.view.talking, now_epoch()
        text = talk["text"].strip()
        note = talk_note(view.factory(talk["factory"]), talk, text, spoken, now)
        if self.send(note["request_id"], note["body"], note["done"]):
            view.talking = None

    def talk_key(self, key: str) -> bool:
        view, talk = self.view, self.view.talking
        if key == "ctrl-c":
            self.close_voice()
            return False
        if talk["mode"] in ("listening", "writing"):
            if key == "esc":
                self.close_voice()
                view.talking = None
                self.say("Not sent: what you said was dropped.", "amber")
            elif talk["mode"] == "listening" and key == "enter":
                self.heard(by_enter=True)
            elif talk["mode"] == "listening" and (key == "backspace" or key not in NAMED):
                # Typing instead: the recording is dropped and the keys are text.
                self.close_voice()
                talk["mode"] = "typed"
                if key not in NAMED:
                    talk["text"] += "".join(c for c in key if c.isprintable())
            return True
        if key == "esc":
            view.talking = None
            if talk["text"].strip() and not talk.get("gone"):
                self.say("Not sent: the box was closed with your words in it.", "amber")
        elif key == "enter" and talk.get("gone"):
            pass
        elif key == "enter":
            if talk["text"].strip():
                self.send_talk()
            else:
                self.say("Nothing to send yet: type your words, then enter. Esc closes.", "amber")
        elif key == "backspace":
            talk["text"] = talk["text"][:-1]
        elif key not in NAMED:
            # Typed keys arrive one at a time; pasted or sent text arrives whole.
            talk["text"] += "".join(c for c in key if c.isprintable())
        return True

    def settled(self, need: Dict[str, Any]) -> None:
        """File a reconcile request for a held call and wake Starship to re-check it."""
        asked_at = time.time()
        outcome, words = ask_settled(self.home, self.view.factory(need["factory"]), need)
        if outcome != "asked":
            self.say(words, *(("amber",) if outcome == "already" else ("red", 12)))
            return
        need["checking"] = True
        self.asked[need["id"]] = (need.get("since"), asked_at)
        self.say(words, "green")
        refresh_in_background(self.home)

    def key(self, key: str) -> bool:
        view = self.view
        now = now_epoch()
        # Scrolling only moves the view, so it never closes a box or a confirmation.
        if key in ("pgup", "pgdn"):
            view.scroll((1 if key == "pgdn" else -1) * max(view.page - 1, 1))
            return True
        if key in ("wheel-up", "wheel-down"):
            view.scroll(3 if key == "wheel-down" else -3)
            return True
        if key.startswith(CLICK):
            # A click reads the Read line or opens the change line it lands on; anywhere else it does nothing.
            line = int(key[len(CLICK):])
            drawn = self.drawn[line - 1] if 0 < line <= len(self.drawn) else None
            if drawn is not None and view.talking is None and view.confirm is None:
                if drawn.read:
                    self.read(drawn.read)
                elif drawn.link:
                    self.open_change(drawn.link)
            return True
        if key in ("mouse", "other"):
            return True
        if view.talking is not None:
            return self.talk_key(key)
        if view.confirm is not None:
            return self.confirm_key(key)
        # A result stays up until the next key says it was read.
        if view.notice and view.notice[1] == "red":
            view.notice = None
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
        elif key == "enter" and view.at()[0] == "fold":
            # The folded count line lists every job it stands for, or hides them again.
            fid = view.at()[1]
            view.unfolded = None if view.unfolded == fid else fid
            view.follow = True
        elif key == "enter" and view.at()[0] == "older":
            # The older questions shelf lists each question, or hides them again.
            shelf = view.at()[1]
            view.older_open = None if view.older_open == shelf else shelf
            view.follow = True
        elif key == "esc" and view.unfolded:
            view.unfolded = None
            view.follow = True
        elif key == "esc" and view.older_open is not None:
            if view.at()[0] == "old":
                view.selected = ("older", view.older_open)
            view.older_open = None
            view.follow = True
        elif view.at()[0] == "old" and lower in ("b", "n"):
            item = view.older_item(view.at()[1])
            what = "revive" if lower == "b" else "drop"
            if item:
                view.confirm = dict(older_note(view.factory(item["factory"]), item, what),
                                    item=item["id"], asked=item["asking"], older=True,
                                    what="bring back" if what == "revive" else "no longer needed",
                                    title="%s · %s" % ("Bring back" if what == "revive" else "No longer needed",
                                                       item["title"]),
                                    prompt=("Ask Starship to bring %s back into Needs you." if what == "revive"
                                            else "Tell Starship %s is no longer needed.") % item["title"])
                view.follow = True
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
            view.confirm = self.answer(need, next(o for o in need["options"] if o["key"].lower() == lower))
            view.follow = True
        elif need and need["kind"] == "finished work" and lower == "k":
            view.confirm = dict(keep_note(view.factory(need["factory"]), need),
                                item=need["id"], asked=asking(need), what="keep it",
                                title="Keep it · %s" % need["title"],
                                prompt="Keep %s and ask Starship to land it." % need["title"])
            view.follow = True
        elif need and need["kind"] == "finished work" and lower == "c":
            self.open_talk({"kind": "change", "factory": need["factory"], "item": need["id"],
                            "title": need["title"], "pr": need.get("pr"),
                            "about": "What should change · %s" % need["title"]}, listen=False)
        elif need and need["kind"] == "question" and lower == "x":
            self.settled(need)
        elif lower == "r":
            self.read(view.readable())
        elif lower == "o":
            self.open_change(view.openable())
        elif lower == "t":
            fid = self.factory_of_stop()
            if need and need["kind"] == "question":
                self.open_talk({"kind": "discuss", "factory": need["factory"], "item": need["id"],
                                "title": need["title"], "about": "Tell Starship · about %s" % need["title"]},
                               listen=True)
            elif fid:
                self.open_talk({"kind": "talk", "factory": fid,
                                "about": "To the %s crew" % view.factory(fid)["name"]}, listen=True)
        elif lower == "s":
            fid = self.factory_of_stop()
            if fid:
                fac = view.factory(fid)
                who = "Starship" if fac["steered_by"] == "you" else "you"
                note = steer_note(fac, who, now)
                ok, why = send_note(self.home, note["request_id"], note["body"])
                if ok:
                    record_steer(self.home, fid, who, now)
                    fac["steered_by"] = who
                    view.record["feed"].insert(0, {
                        "at": now, "date": None, "actor": "you", "factory": fid, "job": None,
                        "word": "took the helm" if who == "you" else "handed back", "text": note["done"]})
                    self.say(note["done"], "cyan")
                    refresh_in_background(self.home)
                else:
                    self.say("Who steers did not change: %s" % why, "red", 12)
        return True


KEYS = {b"\x1b[A": "up", b"\x1b[B": "down", b"\x1b[C": "right", b"\x1b[D": "left",
        b"\x1bOA": "up", b"\x1bOB": "down", b"\x1b[5~": "pgup", b"\x1b[6~": "pgdn",
        b"\x1b": "esc", b"\r": "enter", b"\n": "enter",
        b"\x7f": "backspace", b"\x08": "backspace", b"\x03": "ctrl-c"}
# A left-button press, as CLICK and the screen row it landed on (1 is the top).
# Typed or pasted text never holds an escape, so it can never read as a click.
CLICK = "\x1bclick "
# Every named key, so none is ever typed into the talk box as text.
NAMED = set(KEYS.values()) | {"wheel-up", "wheel-down", "mouse", "other"}
# One read may hold several keys: a held arrow, a turn of the mouse wheel or a
# click (SGR reports, asked for when the pane starts), or pasted text.
KEY_RE = re.compile(rb"\x1b\[<(\d+);\d+;(\d+)([Mm])|\x1b\[[0-9;?]*[ -/]*[@-~]|\x1bO.|\x1b|[^\x1b]+")


def read_keys(fd: int) -> List[str]:
    keys = []
    for match in KEY_RE.finditer(os.read(fd, 1024)):
        data = match.group(0)
        if match.group(1) is not None:
            button = int(match.group(1))
            if button == 0 and match.group(3) == b"M":
                keys.append(CLICK + match.group(2).decode())
            else:
                keys.append({64: "wheel-up", 65: "wheel-down"}.get(button, "mouse"))
        elif data in KEYS:
            keys.append(KEYS[data])
        elif data.startswith(b"\x1b"):
            keys.append("other")
        else:
            keys.append(data.decode("utf-8", errors="ignore"))
    return keys


def code_bytes() -> bytes:
    try:
        with open(os.path.realpath(__file__), "rb") as handle:
            return handle.read()
    except OSError:
        return b""


START_DIGEST = hashlib.sha1(code_bytes()).hexdigest()


class Watcher:
    """Whether this file changed on disk since this process started running it."""

    def __init__(self) -> None:
        self.path = os.path.realpath(__file__)
        self.start = START_DIGEST
        self.bad: Optional[str] = None

    def changed(self) -> bool:
        """True when the file changed, is not empty and compiles; anything else waits."""
        data = code_bytes()
        if not data:
            return False
        now = hashlib.sha1(data).hexdigest()
        if now == self.start or now == self.bad:
            return False
        try:
            compile(data, self.path, "exec")
        except Exception:  # anything that stops the new file compiling
            self.bad = now
            return False
        return True


def reexec() -> None:
    """Run this file again in this process: same pid, terminal and pane."""
    sys.stdout.flush()
    argv = [sys.executable or "python3", os.path.realpath(__file__)] + sys.argv[1:]
    os.execvp(argv[0], argv)


def use_terminal_theme() -> None:
    global PALETTE, BAND, HULL, THEME_SEEN
    THEME_SEEN = remembered_theme()
    PALETTE = palette(select_theme(query=sys.stdout.isatty()))
    BAND, HULL = PALETTE["band"], PALETTE["hull"]


THEME_SEEN: Optional[str] = None


def theme_switched() -> bool:
    """True, with the new colours in use, when bin/fm-theme.sh switched the
    remembered theme since this pane chose its colours; the caller repaints."""
    now = remembered_theme()
    if now is None or now == THEME_SEEN:
        return False
    use_terminal_theme()
    return True


def live(pane: Pane) -> None:
    use_terminal_theme()
    import termios
    import tty
    watch = Watcher()
    reload = False
    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    out = sys.stdout
    resized = [True]
    signal.signal(signal.SIGWINCH, lambda *_: resized.__setitem__(0, True))
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(SystemExit(0)))
    signal.signal(signal.SIGHUP, lambda *_: (_ for _ in ()).throw(SystemExit(0)))
    # The alternate screen, no cursor, no autowrap, and mouse button and wheel
    # reports in SGR form, which Herdr passes to a pane that asks for them.
    out.write("\x1b[?1049h\x1b[?25l\x1b[?7l\x1b[?1000h\x1b[?1006h")
    focus_checked = 0.0
    try:
        tty.setraw(fd)
        while True:
            view = pane.view
            if view.notice and time.time() > view.notice[2]:
                view.notice = None
            if view.talking is None and view.confirm is None and view.notice is None and watch.changed():
                reload = True
                break
            if theme_switched():
                resized[0] = True
            pane.reload()
            pane.watch_calls()
            if time.time() - focus_checked > 3:
                pane.check_focus()
                focus_checked = time.time()
            pane.take_focus()
            pane.voice_tick()
            pane.check_reading()
            size = os.get_terminal_size()
            rows = view.frame(size.columns, size.lines)
            pane.drawn = rows[:size.lines]
            buf = ["\x1b[?2026h\x1b[H"]
            if resized[0]:
                buf.append("\x1b[2J")
                resized[0] = False
            # Each row is cleared before it is drawn, never after: with autowrap
            # off the cursor stays on the last column, and clearing from there
            # would erase the character a full-width row put in it.
            buf.append("\r\n".join("\x1b[K" + paint(segs) for segs in rows[:size.lines]))
            buf.append("\x1b[?2026l")
            out.write("".join(buf))
            out.flush()
            # A spoken note's meter and its end are followed more closely.
            deadline = time.time() + (0.15 if pane.voice else 0.4)
            while True:
                wait = deadline - time.time()
                if wait <= 0:
                    view.tick += 1
                    break
                ready, _, _ = select.select([fd], [], [], wait)
                if ready:
                    pane.looked()
                    for key in read_keys(fd):
                        if not pane.key(key):
                            return
                    break
    finally:
        pane.close_voice()
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)
        # A reload keeps the screen as it is for the new code to redraw, and
        # is not the owner closing the pane.
        if not reload:
            out.write("\x1b[?1006l\x1b[?1000l\x1b[?7h\x1b[?25h\x1b[?1049l")
            out.flush()
    if reload:
        reexec()


# --------------------------------------------------------------------------
# Herdr: the factory tab and its live worker copies
# --------------------------------------------------------------------------

def herdr(args: List[str], timeout: int = 20) -> Tuple[bool, Any]:
    binary = shlex.split(os.environ.get("HERDR_BIN_PATH") or "herdr")
    try:
        out = subprocess.run(binary + args, capture_output=True, text=True, timeout=timeout)
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
    for name in ("HERDR_BIN_PATH", "FM_FACTORY_TTL", "FM_FACTORY_MAX_AGE", "FM_FACTORY_QUIET_MINUTES", "FM_FACTORY_SNAPSHOT",
                 "FM_FACTORY_PEEK", "FM_FACTORY_INBOX", "FM_FACTORY_READ", "FM_FACTORY_OPEN",
                 "FM_FACTORY_PANE_CONFIG_DIR"):
        if name in os.environ:
            words.append("%s=%s" % (name, os.environ[name]))
    words += ["bash", os.path.join(BIN, "fm-factory-pane.sh")] + list(args)
    return " ".join(shlex.quote(w) for w in words)


def open_tab(home: str, fid: str) -> Tuple[bool, str]:
    """Open (or focus) one factory's tab: its page left, its live workers right."""
    record = first_record(home)
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
    ok, why = split_workers(home, factory, page)
    if not ok:
        return False, "the tab opened, but %s" % why
    herdr(["pane", "focus", page])
    return True, ""


def tab_workers(factory: Dict[str, Any]) -> List[Dict[str, Any]]:
    """The jobs of <factory> its tab shows a live worker beside: the started ones at work (MIRROR_STATES), up to MIRROR_CAP."""
    return [j for j in factory["jobs"] if j["started"] and j["state"] in MIRROR_STATES][:MIRROR_CAP]


def split_workers(home: str, factory: Dict[str, Any], page: str) -> Tuple[bool, str]:
    """Split a live copy of each worker at work (MIRROR_STATES) of <factory> beside its page pane <page>, stacked on the right."""
    workers = tab_workers(factory)
    above = None
    for index, job in enumerate(workers):
        target, direction = (page, "right") if index == 0 else (above, "down")
        ok, data = herdr(["pane", "split", target, "--direction", direction, "--no-focus"])
        new = dig(data, "result.pane.pane_id", "result.pane.id") if ok else None
        if not new:
            return False, "a worker's live view did not open: %s" % (data if not ok else "no pane")
        herdr(["pane", "run", new, pane_command(home, "follow", job["id"])])
        above = new
    return True, ""


def open_workers(home: str, fid: str, page: str) -> Tuple[bool, str]:
    """The workers command: live copies of one factory's running workers beside its page pane <page>."""
    record = first_record(home)
    factory = next((f for f in record["factories"] if f["id"] == fid), None)
    if factory is None:
        return False, "no factory %s" % fid
    return split_workers(home, factory, page)


def job_in(record: Dict[str, Any], task_id: str) -> Optional[Dict[str, Any]]:
    for factory in record.get("factories") or []:
        for job in factory.get("jobs") or []:
            if job["id"] == task_id:
                return job
    return None


def follow(home: str, task_id: str) -> None:
    """A read-only live copy of one worker's pane, refreshed every 2 seconds.

    It closes its own pane once the record says its job ended (MIRROR_KEEP).
    """
    use_terminal_theme()
    peek = os.environ.get("FM_FACTORY_PEEK") or os.path.join(BIN, "fm-peek.sh")
    watch = Watcher()
    job = job_in(cached(home) or {}, task_id)
    title = job["title"] if job else task_id
    out = sys.stdout
    out.write("\x1b[?25l\x1b[?7l")
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(SystemExit(0)))
    reload = ended = False
    try:
        while True:
            if watch.changed():
                reload = True
                break
            theme_switched()
            record = cached(home)
            if record is not None:
                job = job_in(record, task_id)
                if job is None or job["state"] not in MIRROR_KEEP:
                    ended = True
                    break
                if refresh_due(home, record):
                    refresh_in_background(home)
            size = os.get_terminal_size()
            try:
                got = subprocess.run(shlex.split(peek) + [task_id, str(max(size.lines - 2, 1))],
                                     capture_output=True, text=True, timeout=10, env=dict(os.environ, FM_HOME=home))
                lines = got.stdout.splitlines() if got.returncode == 0 else ["(this worker's pane cannot be read)"]
            except (OSError, subprocess.SubprocessError):
                lines = ["(this worker's pane cannot be read)"]
            # The peek is the whole visible pane, blank rows below the text
            # included; drop those so the tail keeps the worker's real text.
            while lines and not lines[-1].strip():
                lines.pop()
            head = paint(row(size.columns, [S(" " + title, "cyan", True)], [S("live copy · read only", "faint")]))
            body = [line[:size.columns] for line in lines[-(size.lines - 2):]]
            out.write("\x1b[H\x1b[2J" + head + "\r\n\r\n" + "\r\n".join(body))
            out.flush()
            time.sleep(2)
    finally:
        if not reload:
            out.write("\x1b[?7h\x1b[?25h")
            out.flush()
    if reload:
        reexec()
    if ended and os.environ.get("HERDR_PANE_ID"):
        herdr(["pane", "close", os.environ["HERDR_PANE_ID"]])


# --------------------------------------------------------------------------
# Entry
# --------------------------------------------------------------------------

def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(prog="fm-factory.py", add_help=True,
                                     description="The Factory pane. See the header of this file.")
    parser.add_argument("command", nargs="?", choices=["view", "follow", "open-tab", "workers", "refresh", "refresh-calls",
                                                          "profile", "act"])
    parser.add_argument("target", nargs="?")
    parser.add_argument("--data", action="store_true")
    parser.add_argument("--plain", action="store_true")
    parser.add_argument("--screen", action="store_true")
    parser.add_argument("--fresh", action="store_true")
    parser.add_argument("--factory")
    parser.add_argument("--width", type=int, default=92)
    parser.add_argument("--height", type=int)
    parser.add_argument("--origin-tab")
    parser.add_argument("--page")
    parser.add_argument("--item")
    parser.add_argument("--data-dir")
    try:
        args = parser.parse_args(argv)
    except SystemExit as stop:
        return 2 if stop.code else 0
    home = home_dir()
    try:
        if args.screen:
            if args.command or args.data or args.plain:
                parser.print_usage(sys.stderr)
                return 2
            fresh = args.fresh or bool(os.environ.get("FM_FACTORY_SNAPSHOT"))
            record = current_record(home, True) if fresh else kept_record(home)
            print(json.dumps(screen(View(record, voice=voice_ready(home))), ensure_ascii=False))
            return 0
        if args.command == "act":
            try:
                ask = json.loads(sys.stdin.read())
                if not isinstance(ask, dict):
                    raise ValueError("the action is not an object")
                print(json.dumps(act(home, ask), ensure_ascii=False))
            except (ValueError, KeyError, TypeError) as error:
                print("fm-factory: act: %s" % error, file=sys.stderr)
                return 2
            return 0
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
                height = max(args.height, 8) if args.height else None
                view = View(record, opened=args.factory, item=args.item, voice=voice_ready(home))
                print(plain(view, max(args.width, 40), height))
            return 0
        if args.command in ("refresh", "refresh-calls"):
            if args.command == "refresh":
                run_rebuild(home, refresh, rested=True)
                return 0
            if run_rebuild(home, refresh_calls, rested=False) is None and rebuild_wait(home) <= 0:
                run_rebuild(home, refresh, rested=True)
            return 0
        if args.command == "view":
            if args.origin_tab:
                os.environ["FM_FACTORY_ORIGIN_TAB"] = args.origin_tab
            live(Pane(home, args.factory, in_tab=bool(args.factory and os.environ.get("HERDR_PANE_ID")),
                      item=args.item))
            return 0
        if args.command == "profile" and args.target:
            return print_profile(args.data_dir or os.path.join(home, "data"), args.target)
        if args.command == "follow" and args.target:
            follow(home, args.target)
            return 0
        if (args.command == "open-tab" and args.target) or (args.command == "workers" and args.target and args.page):
            ok, why = open_tab(home, args.target) if args.command == "open-tab" else \
                open_workers(home, args.target, args.page)
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
