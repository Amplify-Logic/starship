#!/usr/bin/env python3
"""fm_meeting_sources.py - where finished meetings come from, for bin/fm-meetings.py.

bin/fm-meetings.sh's header owns the intake contract; this module owns the
source seam, the one place a new kind of meeting recorder plugs in. A source
turns one place meetings are recorded into the records the intake reads, and
the intake itself never knows which recorder a meeting came from.

A source is a class registered in SOURCES under the word `config/meetings`
names it by (`source = <name>`). It gets the intake's Home (paths, config, and
exclusion_hits(text), the exclude words found in a text) and provides:

  config_defaults   the config/meetings keys it adds, each with its default,
                    prefixed with its name so a key reads as its owner's
  numeric_keys      the subset that must be whole numbers above zero
  poll(records, problems, deadline)
                    look at the recorder once, stopping new work after
                    `deadline` (a time.time() value), and move each meeting's
                    record in records["meetings"] toward phase "ready" with
                    mark_ready(), adding a record (new_record()) for each
                    meeting first seen. A meeting that ended before
                    records["baseline"] gets phase "baseline" and is left
                    alone. A problem worth one wake is appended to `problems`;
                    a Failure raised here is reported once as
                    "<name> cannot be read: ..." until it clears. A poll never
                    sends a meeting anywhere, such as to a transcription
                    service, while home.exclusion_hits(meeting_text(...))
                    finds an exclude word in it.
  load(record)      the finished meeting as a Meeting (below) for intake,
                    raising Unreachable when the recorder itself cannot be
                    reached and Failure when only this meeting cannot be read
  search(terms, limit)
                    brief Meetings matching the recall words that no intake
                    record covers yet; [] by default

A record is the source's own state for one meeting, kept in
state/meetings/records.json by the intake, with these keys the intake reads
or sets: id, source (the source's name), phase, title, date, first_seen,
transcript (set by mark_ready), and the intake's own phases "ready",
"taking", "taken", "excluded" and "failed". Everything else in it belongs to
the source.

A Meeting is a plain dict with:
  id, source, title, date (ISO 8601), origin (how it was captured, in words:
  "meeting", "imported recording", "call"),
  participants ([display names]), participant_details (one string of every
  participant field, for the exclusion check), speakers ([{"name", "is_self"}]),
  note (the owner's own notes), summary, action_items ([str]),
  transcript (paragraphs "Speaker: words" separated by blank lines),
  final_transcript (a second transcript of the same meeting made after it,
  with speaker labels, or ""), transcript_kind (one of KIND_TEXT),
  transcript_note (why that kind) and language.
"""

import datetime
import json
import os
import re
import subprocess
import time

SETTLE_SECONDS = 120          # quiet time after the last change before a meeting counts as finished
SUMMARY_WAIT_SECONDS = 600    # how long after the end to wait for the recorder's own summary or notes
CLI_TIMEOUT = 15
LIST_LIMIT = 50
AUDIO_EXTENSIONS = {".wav", ".mp3", ".ogg", ".mp4", ".m4a", ".flac", ".webm", ".aac"}
KIND_TEXT = {"final": "final transcript with speaker labels", "live": "live transcript only",
             "none": "notes and summary only, with no transcript"}


class Failure(Exception):
    pass


class Unreachable(Failure):
    """A Failure about the recorder itself, such as its tool missing or not answering, not about one meeting."""


class Missing(Failure):
    """A Failure where the recorder confirms it no longer holds the meeting asked for."""


def now():
    value = os.environ.get("FM_MEETINGS_NOW", "")
    return int(value) if value.isdigit() else int(time.time())


def iso_epoch(value):
    """Epoch seconds for an ISO 8601 timestamp, or None when empty or unreadable."""
    if not value:
        return None
    text = re.sub(r"\.\d+", "", value.strip()).replace("Z", "+00:00")
    try:
        stamp = datetime.datetime.fromisoformat(text)
    except ValueError:
        return None
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=datetime.timezone.utc)
    return int(stamp.timestamp())


def mark_ready(record, kind, note="", source_meeting=None):
    record["phase"] = "ready"
    record["transcript"] = {"kind": kind, "note": note, "source_meeting": source_meeting or record["id"]}
    record["ready_at"] = now()


def new_record(records, meeting_id, source, **fields):
    record = {"id": meeting_id, "source": source, "phase": "waiting", "first_seen": now()}
    record.update(fields)
    records["meetings"][meeting_id] = record
    return record


def notice(records, key, text):
    """Report a standing problem once, and again only after it has cleared and come back."""
    if records["notices"].get(key) == text:
        return None
    records["notices"][key] = text
    return text


def meeting(**fields):
    """A Meeting with every key present, so the intake never guesses at an absent one."""
    base = {"id": "", "source": "", "title": "Untitled meeting", "date": "", "origin": "meeting",
            "participants": [], "participant_details": "", "speakers": [], "note": "", "summary": "",
            "action_items": [], "transcript": "", "final_transcript": "", "transcript_kind": "none",
            "transcript_note": "", "language": ""}
    base.update(fields)
    return base


def meeting_text(found):
    """Every part of a Meeting the exclude words are checked against, as one text."""
    return "\n".join([found["title"], found["participant_details"], found["note"], found["summary"],
                      found["transcript"], found["final_transcript"]] + list(found["action_items"]))


def key_value_setting(path, key, default):
    """One `key = value` setting from a file in this repository's config format, or the default."""
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.readlines()
    except OSError:
        return default
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        found, value = (part.strip() for part in line.split("=", 1))
        if found == key:
            return value
    return default


class Source:
    name = ""
    config_defaults = {}
    numeric_keys = ()

    def __init__(self, home):
        self.home = home

    def poll(self, records, problems, deadline):
        raise Failure(f"the {self.name} source cannot poll yet")

    def load(self, record):
        raise Failure(f"the {self.name} source cannot load a meeting yet")

    def search(self, terms, limit):
        return []


# --- Anarlog ------------------------------------------------------------------
#
# Anarlog (anarlog.so) records meetings on this Mac and keeps them in its own
# local database. This source reads it only through Anarlog's own command-line
# tool (`anarlog --json meetings ...`, local source) and never opens that
# database itself. The one thing it asks Anarlog to add is a recording import,
# through Anarlog's supported `meetings import` command, which needs the
# desktop app open on the same database.
#
# A recorded meeting counts as finished once Anarlog shows an end time, has no
# capture still pending, nothing changed for SETTLE_SECONDS, and its summary
# exists or SUMMARY_WAIT_SECONDS have passed. Anarlog's live model writes the
# transcript during the call; its batch model, which labels speakers, runs
# after the call on its own only in some cases. So a transcript Anarlog
# already rewrote with its batch pass is used as is; otherwise the meeting's
# own recording is imported as a second meeting titled "<title> (speaker
# pass)" whose batch transcript the intake reads; and the live transcript is
# used only when no recording was kept, or the speaker pass failed or did not
# finish within anarlog_speaker_pass_wait_minutes, which the intake's outcome
# then says. A meeting an exclude word marks gets no speaker pass: it goes to
# the intake as it stands, which keeps it out.

SPEAKER_PASS_TITLE = " (speaker pass)"
REQUEST_PREFIX = "fm-meetings-"
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.IGNORECASE)


class Anarlog(Source):
    name = "anarlog"
    config_defaults = {"anarlog_speaker_pass_wait_minutes": "180"}
    numeric_keys = ("anarlog_speaker_pass_wait_minutes",)

    def __init__(self, home):
        super().__init__(home)
        self.binary = os.environ.get("FM_MEETINGS_ANARLOG") or self._default_binary()

    @staticmethod
    def _default_binary():
        for folder in os.environ.get("PATH", "").split(os.pathsep):
            candidate = os.path.join(folder, "anarlog")
            if folder and os.access(candidate, os.X_OK):
                return candidate
        return os.path.expanduser("~/.local/bin/anarlog")

    # -- the command-line tool --

    def cli(self, *args, as_json=True, timeout=CLI_TIMEOUT):
        command = [self.binary] + (["--json"] if as_json else []) + list(args)
        label = "anarlog " + " ".join(a for a in args[:4] if a not in ("--source", "local"))
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
        except FileNotFoundError:
            raise Unreachable(f"the Anarlog command-line tool is not installed at {self.binary}")
        except subprocess.TimeoutExpired:
            raise Unreachable(f"{label} did not answer within {timeout}s")
        if result.returncode != 0:
            detail, code = "", ""
            for stream in (result.stdout, result.stderr):
                try:
                    error = json.loads(stream).get("error")
                    detail = error.get("message", "") if isinstance(error, dict) else str(error or "")
                    code = error.get("code", "") if isinstance(error, dict) else ""
                except (ValueError, AttributeError):
                    continue
                if detail:
                    break
            if not detail:
                lines = (result.stderr or result.stdout).strip().splitlines()
                detail = lines[-1] if lines else f"exit {result.returncode}"
            raise (Missing if code == "not_found" else Failure)(f"{label} failed: {detail[:200]}")
        if not as_json:
            return result.stdout
        try:
            return json.loads(result.stdout).get("data")
        except (ValueError, AttributeError):
            raise Failure(f"{label} returned output that is not its JSON contract")

    def meetings(self, *args, **kwargs):
        return self.cli("meetings", "--source", "local", *args, **kwargs)

    def export_json(self, meeting_id):
        return self.meetings("export", meeting_id, "--format", "json")

    def export_markdown(self, meeting_id):
        return self.meetings("export", meeting_id, "--format", "markdown", as_json=False)

    def import_recording(self, path, title, request_key):
        return self.meetings("import", path, "--title", title, "--request-key", request_key)

    @staticmethod
    def session_dir(sessions, meeting_id, depth=0):
        """Anarlog's own lookup: a meeting's folder sits under sessions/, inside any meeting folders."""
        try:
            entries = sorted(os.scandir(sessions), key=lambda e: e.name)
        except OSError:
            return None
        for entry in entries:
            if not entry.is_dir(follow_symlinks=False):
                continue
            if entry.name == meeting_id:
                return entry.path
            if depth < 8 and not UUID.match(entry.name):
                found = Anarlog.session_dir(entry.path, meeting_id, depth + 1)
                if found:
                    return found
        return None

    @staticmethod
    def described(export, title="Untitled meeting"):
        """The Meeting fields an export carries, mapped the same way for intake, the exclusion check and recall."""
        details = []
        for person in export.get("participants") or []:
            details += [person.get(key) or "" for key in ("display_name", "email", "organization_name", "job_title")]
        return {
            "title": (export.get("title") or title).strip(),
            "date": export.get("started_at") or export.get("created_at") or "",
            "participants": [p.get("display_name") for p in export.get("participants") or [] if p.get("display_name")],
            "participant_details": "\n".join(d for d in details if d),
            "note": (export.get("note") or {}).get("markdown") or "",
            "summary": "\n\n".join(s.get("markdown") or "" for s in export.get("summaries") or []).strip(),
            "action_items": [a.get("text") for a in export.get("action_items") or [] if a.get("text")],
        }

    def excluded(self, export):
        transcript = self.split_transcript(self.export_markdown(export["id"]))[1]
        return self.home.exclusion_hits(meeting_text(meeting(**self.described(export), transcript=transcript)))

    def recording_path(self, export):
        """The meeting's own audio recording on this Mac, and why there is none when there is none."""
        audio = []
        for attachment in export.get("attachments") or []:
            relative = attachment.get("relative_path") or ""
            name = attachment.get("filename") or relative
            if ((attachment.get("content_type") or "").startswith("audio/")
                    or os.path.splitext(name)[1].lower() in AUDIO_EXTENSIONS) and relative \
                    and not os.path.isabs(relative) and ".." not in relative.split("/"):
                audio.append(relative)
        if not audio:
            return None, "Anarlog kept no recording to run the speaker pass on"
        database = (self.cli("doctor").get("database") or {}).get("path") or ""
        folder = self.session_dir(os.path.join(os.path.dirname(database), "sessions"), export["id"])
        for relative in audio:
            candidate = os.path.join(folder, relative) if folder else ""
            if candidate and os.path.isfile(candidate) and os.path.getsize(candidate) > 0:
                return candidate, ""
        return None, "the meeting's recording could not be found on this Mac"

    # -- poll --

    @staticmethod
    def has_batch_transcript(export):
        return any((t.get("source") == "batch_transcription") or "batch" in (t.get("model") or "")
                   for t in export.get("transcripts") or [])

    @staticmethod
    def last_change(export):
        stamps = [iso_epoch(export.get("updated_at")), iso_epoch(export.get("ended_at"))]
        stamps += [iso_epoch((export.get("note") or {}).get("updated_at"))]
        stamps += [iso_epoch(s.get("updated_at")) for s in export.get("summaries") or []]
        stamps += [int(t["ended_at_ms"] / 1000) for t in export.get("transcripts") or [] if t.get("ended_at_ms")]
        return max([s for s in stamps if s] or [0])

    def wait_seconds(self):
        return int(self.home.config["anarlog_speaker_pass_wait_minutes"]) * 60

    def poll_recorded(self, record, export):
        """Move a finished recording toward ready, asking Anarlog for its batch pass when it ran none."""
        if export.get("capture_pending"):
            record["phase"] = "waiting"
            return None
        ended = iso_epoch(export.get("ended_at")) or 0
        if now() - self.last_change(export) < SETTLE_SECONDS:
            record["phase"] = "waiting"
            return None
        if not export.get("summaries") and now() - ended < SUMMARY_WAIT_SECONDS:
            record["phase"] = "waiting"
            return None
        if self.has_batch_transcript(export):
            mark_ready(record, "final", "Anarlog ran its own speaker pass")
            return None
        if not export.get("transcripts"):
            mark_ready(record, "none", "Anarlog kept no transcript")
            return None
        title = (export.get("title") or "Meeting").strip() + SPEAKER_PASS_TITLE
        try:
            if self.excluded(export):
                mark_ready(record, "live", "an exclude word marks it, so no speaker pass was asked for")
                return None
            path, why = self.recording_path(export)
            if not path:
                mark_ready(record, "live", why)
                return None
            job = self.import_recording(path, title, REQUEST_PREFIX + "speakers-" + record["id"])
        except Failure as error:
            record["speaker_pass"] = {"error": str(error),
                                      "tries": record.get("speaker_pass", {}).get("tries", 0) + 1}
            if now() - ended >= self.wait_seconds():
                mark_ready(record, "live", f"Anarlog could not start the speaker pass ({error})")
            else:
                record["phase"] = "waiting"
            return None
        record["phase"] = "speaker-pass"
        record["speaker_pass"] = {"job_id": job.get("job_id"), "meeting_id": job.get("meeting_id"),
                                  "requested_at": now()}
        return job.get("meeting_id")

    def poll_speaker_pass(self, record):
        job = record.get("speaker_pass") or {}
        wait = self.wait_seconds()
        try:
            status = self.meetings("import-status", job["job_id"])
        except Failure as error:
            if now() - job.get("requested_at", 0) >= wait:
                mark_ready(record, "live", f"the speaker pass could not be read back ({error})")
            return
        state = status.get("processing_status")
        if state == "done":
            mark_ready(record, "final", "Starship asked Anarlog for the speaker pass", job.get("meeting_id"))
        elif state == "failed":
            mark_ready(record, "live", f"the speaker pass failed ({status.get('error') or 'no reason given'})")
        elif now() - job.get("requested_at", 0) >= wait:
            mark_ready(record, "live", f"the speaker pass did not finish within {wait // 60} minutes")

    @staticmethod
    def poll_import(record, item):
        """An imported recording is ready when its job ends and its summary is in, or SUMMARY_WAIT_SECONDS
        after the transcript was."""
        job = item.get("recording_import") or {}
        state = job.get("processing_status") or item.get("processing_status")
        if state == "done":
            transcribed = record.setdefault("transcribed_at", now())
            if job.get("summary_status") != "done" and now() - transcribed < SUMMARY_WAIT_SECONDS:
                record["phase"] = "waiting"
                return
            mark_ready(record, "final", "transcribed by Anarlog from the imported recording")
        elif state == "failed":
            record["phase"] = "failed"
            record["error"] = job.get("error") or "Anarlog could not transcribe the recording"
        else:
            record["phase"] = "waiting"

    def poll_one(self, records, meeting_id, record, item, problems):
        known = records["meetings"]
        if record and record.get("phase") == "speaker-pass":
            self.poll_speaker_pass(record)
            return
        found = self.meetings("get", meeting_id)
        if record is None:
            record = new_record(records, meeting_id, self.name, origin="recorded")
        record.pop("error", None)
        record["title"] = found.get("title") or record.get("title") or "Untitled meeting"
        record["date"] = found.get("started_at") or found.get("created_at") or ""
        record["seen_updated"] = item.get("updated_at") or found.get("updated_at")
        baseline = records.get("baseline", 0)
        if found.get("recording_import"):
            if record["origin"] == "recorded":
                record["origin"] = "imported"
                if (iso_epoch(found.get("created_at")) or 0) < baseline:
                    record["phase"] = "baseline"
                    return
            self.poll_import(record, found)
            if record["phase"] == "failed":
                problems.append(f"{record['title']} could not be transcribed ({record['error']})")
            return
        if not found.get("ended_at"):
            record["phase"] = "idle"
            return
        if (iso_epoch(found.get("ended_at")) or 0) < baseline:
            record["phase"] = "baseline"
            return
        child = self.poll_recorded(record, self.export_json(meeting_id))
        if child:
            new_record(records, child, self.name, phase="child", origin="speaker-pass", parent=meeting_id,
                       title=record["title"] + SPEAKER_PASS_TITLE)

    def poll(self, records, problems, deadline):
        listing = self.meetings("list", "--limit", str(LIST_LIMIT)) or []
        known = records["meetings"]
        ids = [item["id"] for item in listing]
        ids += [mid for mid, rec in known.items() if rec.get("source") == self.name
                and rec.get("phase") in ("waiting", "speaker-pass") and mid not in ids]
        by_id = {item["id"]: item for item in listing}
        for meeting_id in ids:
            if time.time() > deadline:
                break
            record = known.get(meeting_id)
            item = by_id.get(meeting_id, {})
            if record and record.get("source", self.name) != self.name:
                continue
            if record and record.get("phase") not in ("idle", "waiting", "speaker-pass"):
                continue
            if record and record.get("phase") == "idle" and record.get("seen_updated") == item.get("updated_at") \
                    and not item.get("ended_at"):
                continue
            try:
                self.poll_one(records, meeting_id, record, item, problems)
            except Failure as error:
                (known.get(meeting_id) or {})["error"] = str(error)

    # -- load --

    @staticmethod
    def split_transcript(markdown):
        head, marker, transcript = markdown.partition("\n## Transcript\n")
        return head.rstrip(), transcript.strip() if marker else ""

    def load(self, record):
        meeting_id = record["id"]
        export = self.export_json(meeting_id)
        transcript = record.get("transcript") or {}
        if transcript:
            kind = transcript.get("kind", "none")
        else:
            kind = "final" if self.has_batch_transcript(export) else ("live" if export.get("transcripts") else "none")
        own = self.split_transcript(self.export_markdown(meeting_id))[1]
        exports = [export]
        final = ""
        pass_id = transcript.get("source_meeting")
        if pass_id and pass_id != meeting_id:
            try:
                exports.append(self.export_json(pass_id))
                final = self.split_transcript(self.export_markdown(pass_id))[1]
            except Missing:
                raise Failure("the meeting's speaker-pass copy is missing in Anarlog")
        origin = "imported recording" if record.get("origin") == "imported" else "meeting"
        return meeting(
            id=meeting_id, source=self.name, **self.described(export, record.get("title") or "Untitled meeting"),
            origin=origin,
            speakers=[{"name": (s.get("name") or "").strip(), "is_self": bool(s.get("is_self"))}
                      for e in exports for s in e.get("speakers") or [] if (s.get("name") or "").strip()],
            transcript=own, final_transcript=final if final and final != own else "",
            transcript_kind=kind, transcript_note=transcript.get("note") or "read as it stood when the intake ran",
            language=next((t.get("language") for e in exports for t in e.get("transcripts") or [] if t.get("language")), ""),
        )

    def search(self, terms, limit):
        hits = []
        for term in terms[:3]:
            for item in self.meetings("list", "--query", term, "--limit", str(limit)) or []:
                if any(hit["id"] == item["id"] for hit in hits):
                    continue
                hits.append(meeting(
                    id=item["id"], source=self.name, **self.described(self.export_json(item["id"])),
                    transcript=self.split_transcript(self.export_markdown(item["id"]))[1],
                ))
        return hits


# --- the call recorder -----------------------------------------------------------
#
# bin/fm-call-companion.sh records a call on this Mac and, when it stops,
# writes end-of-call notes and moves the call into data/calls/archive/ under
# the stamp it got when it started (<stamp>-transcript.txt, <stamp>-notes.json
# and the rest). Each transcript line is "[HH:MM:SS] label: text", where the
# label says how the speech was heard: the home's speaker_name setting for
# speech from this Mac's own microphone, "others" for the call audio, a name
# shown by captions, or "unknown speaker". This source reads only that archive:
# an archived call is ready once its notes are there, or SUMMARY_WAIT_SECONDS
# after it was first seen when the notes failed. Its owner's speech is the
# speaker_name label, which is how a spoken order said into this Mac's
# microphone counts as the owner's.

STAMP = re.compile(r"^(\d{8}-\d{6})-transcript\.txt$")
CALL_LINE = re.compile(r"^\[(\d{2}:\d{2}:\d{2})\]\s+([^:]+):\s*(.*)$")
ACTIVE_ITEM = ("confirmed", "revised", "new", "not reviewed")


def stamp_epoch(stamp):
    try:
        return int(time.mktime(time.strptime(stamp, "%Y%m%d-%H%M%S")))
    except Exception:  # a stamp the platform clock cannot place
        return None


class Recorder(Source):
    name = "call-recorder"

    def archive(self):
        data = os.environ.get("CALL_COMPANION_DATA_DIR") or os.path.join(self.home.data_root, "calls")
        return os.path.join(data, "archive")

    def speaker_name(self):
        path = os.environ.get("CALL_COMPANION_CONFIG") or os.path.join(self.home.config_dir, "call-companion")
        return key_value_setting(path, "speaker_name", "me") or "me"

    @staticmethod
    def title(stamp):
        epoch = stamp_epoch(stamp)
        when = datetime.datetime.fromtimestamp(epoch).strftime("%Y-%m-%d %H:%M") if epoch else stamp
        return f"Call {when}"

    def poll(self, records, problems, deadline):
        folder = self.archive()
        try:
            names = sorted(os.listdir(folder))
        except FileNotFoundError:
            return
        except OSError as error:
            raise Failure(f"the call archive cannot be read ({error})")
        baseline = records.get("baseline", 0)
        for name in names:
            if time.time() > deadline:
                break
            match = STAMP.match(name)
            if not match:
                continue
            stamp = match.group(1)
            meeting_id = "call-" + stamp
            record = records["meetings"].get(meeting_id)
            if record and record.get("phase") != "waiting":
                continue
            epoch = stamp_epoch(stamp)
            if record is None:
                date = datetime.datetime.fromtimestamp(epoch).astimezone().isoformat() if epoch else ""
                record = new_record(records, meeting_id, self.name, origin="call", stamp=stamp,
                                    title=self.title(stamp), date=date)
                if epoch is not None and epoch < baseline:
                    record["phase"] = "baseline"
                    continue
            if os.path.exists(os.path.join(folder, f"{stamp}-notes.json")):
                mark_ready(record, "final", "recorded by the call recorder, with its end-of-call notes")
            elif now() - record.get("first_seen", now()) >= SUMMARY_WAIT_SECONDS:
                mark_ready(record, "final", "recorded by the call recorder; its end-of-call notes never came")

    def load(self, record):
        stamp = record.get("stamp") or record["id"][len("call-"):]
        folder = self.archive()
        try:
            with open(os.path.join(folder, f"{stamp}-transcript.txt"), encoding="utf-8") as handle:
                lines = [CALL_LINE.match(raw.rstrip("\n")) for raw in handle]
        except FileNotFoundError:
            raise Missing("the call's transcript is gone from the call archive")
        except OSError as error:
            raise Failure(f"the call's transcript cannot be read ({error.strerror or error})")
        paragraphs, labels = [], []
        for match in lines:
            if not match:
                continue
            _, label, text = match.groups()
            label = label.strip()
            if label not in labels:
                labels.append(label)
            if paragraphs and paragraphs[-1][0] == label:
                paragraphs[-1][1].append(text)
            else:
                paragraphs.append((label, [text]))
        transcript = "\n\n".join(f"{label}: {' '.join(texts)}" for label, texts in paragraphs)
        summary, action_items = "", []
        try:
            with open(os.path.join(folder, f"{stamp}-notes.json"), encoding="utf-8") as handle:
                notes = json.load(handle)
            summary = str(notes.get("summary") or "")
            action_items = [str(item.get("text") or "") for item in notes.get("items") or []
                            if item.get("kind") == "next_step" and item.get("status") in ACTIVE_ITEM and item.get("text")]
        except (OSError, ValueError):
            pass
        me = self.speaker_name()
        return meeting(
            id=record["id"], source=self.name, title=record.get("title") or self.title(stamp),
            date=record.get("date") or "", origin="call",
            speakers=[{"name": label, "is_self": label == me} for label in labels],
            summary=summary, action_items=action_items, transcript=transcript,
            transcript_kind="final" if transcript else "none",
            transcript_note=(record.get("transcript") or {}).get("note") or "recorded by the call recorder",
        )


SOURCES = {Anarlog.name: Anarlog, Recorder.name: Recorder}
