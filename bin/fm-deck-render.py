#!/usr/bin/env python3
"""Render the captain's private Action Deck pane.

bin/fm-deck.sh collects every source and pipes one sentinel-delimited payload
here; this file is presentation only. It reads no files, runs no commands, and
holds nothing between frames. Section semantics, source ownership, and the
Herdr registration line live in bin/fm-deck.sh's header.

Two renderings share one reading of the payload. The default draws the
terminal frame. `--json` (before the sentinel) emits the same sections as one
structured model, schema `fm-deck.v1`, so a second surface - the bridge's
/deck page - shows exactly what the pane shows without re-deriving "what needs
you" from the raw records. Every selection rule (which worker asks for what,
which pull request is unconfirmed, which staged card is expired) lives in the
*_rows and *_groups helpers below and is consumed by both renderings.
"""

import csv
import io
import json
import re
import sys
import time
import unicodedata

JUST_IN_DEFAULT = 5
LOOSE_ENDS_DEFAULT = 5
NEEDS_YOU_DEFAULT = 8
MIN_WIDTH = 60
MAX_WIDTH = 160

# tasks-axi renders an absent value as one of these, never as an empty field.
EMPTY_TOKENS = {"", "-", "none"}

# Urgency order, and the single place the deck decides what outranks what.
# It matches fm_visible_aggregate's order in bin/fm-visible-format-lib.sh so the
# pane and the workspace tab strip can never disagree about what is most urgent.
STATE_RANK = {
    "parked": 0,
    "failed": 1,
    "blocked": 2,
    "working": 3,
    "paused": 4,
    "done": 5,
    "unknown": 6,
    "none": 7,
}


def format_age(secs):
    """Compact age: 45s, 12m, 3h, 5d. Negative or unknown renders as '-'."""
    if secs is None or secs < 0:
        return "-"
    if secs < 60:
        return "%ds" % secs
    if secs < 3600:
        return "%dm" % (secs // 60)
    if secs < 86400:
        return "%dh" % (secs // 3600)
    return "%dd" % (secs // 86400)


# The state dots and the title's anchor are east-asian wide: each occupies two
# terminal columns while len() counts it as one, so measuring characters pushed
# every dotted row and the clock past the frame and wrapped them. Every place
# this file measures or pads goes through these two helpers, so the rule lives
# in one spot the way the control-character strip does. Ambiguous-width
# characters - the rules' ─, the · and … separators - stay one column, which is
# how the terminals this pane is read in draw them.
def display_width(text):
    return sum(2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1 for ch in text)


def pad(text, width):
    """Left-justify to `width` display columns. Never truncates; clip() does."""
    return text + " " * max(0, width - display_width(text))


def clip(text, width):
    text = " ".join(str(text).split())
    if width <= 1 or display_width(text) <= width:
        return text
    # Cut on display width, so a clipped cell cannot end mid-wide-glyph and the
    # "…" that replaces the cut still leaves the cell inside its column.
    kept = []
    used = 0
    for ch in text:
        step = display_width(ch)
        if used + step > width - 1:
            break
        kept.append(ch)
        used += step
    return "".join(kept) + "…"


def parse_payload(stream, mark):
    """Split the sentinel-delimited payload into {section_name: raw_text}."""
    sections = {}
    name = None
    buf = []
    for raw in stream:
        line = raw.rstrip("\n")
        if line.startswith(mark + " "):
            if name is not None:
                sections[name] = "\n".join(buf)
            name = line[len(mark) + 1 :].strip()
            buf = []
            continue
        if name is not None:
            buf.append(line)
    if name is not None:
        sections[name] = "\n".join(buf)
    return sections


def payload_lines(text):
    """Split a section on the one separator the payload is framed with.

    str.splitlines() also breaks on \x0b, \x0c, U+0085, U+2028 and U+2029, and
    worker-authored text reaches these parsers with those characters intact. One
    of them inside a backlog title or a worker's outcome would split its row in
    half, and half a row is dropped - silently taking the rest of the backlog or
    that whole worker off the pane with it.
    """
    return text.split("\n")


def first_line(text):
    for line in payload_lines(text):
        if line.strip():
            return line.strip()
    return ""


def to_int(text, default):
    try:
        return int(str(text).strip())
    except (TypeError, ValueError):
        return default


def clean(value):
    """Normalize a tasks-axi field, mapping its absent markers to ''."""
    value = "" if value is None else str(value).strip()
    return "" if value in EMPTY_TOKENS else value


# tasks-axi truncates a long title and appends a pointer to `show --full`.
# That pointer is machine chatter, not the captain's sentence, so strip it.
TRUNCATION = re.compile(r"(?:\\n|\n)\.\.\.\s*\(truncated,.*$", re.DOTALL)


def clean_title(value):
    value = "" if value is None else str(value)
    trimmed = TRUNCATION.sub("", value)
    # Keep a visible mark when tasks-axi cut the sentence, so a title that stops
    # mid-word reads as shortened rather than as a badly written backlog entry.
    cut = trimmed != value
    trimmed = trimmed.replace("\\n", " ")
    trimmed = " ".join(trimmed.split())
    return (trimmed + "…") if cut and trimmed else trimmed


def parse_backlog(text):
    """Parse `tasks-axi list --fields ...` into a list of dicts.

    Returns [] for empty, unreadable, or unexpected output: an unusable backlog
    renders as an honest empty section, never as a traceback in his pane.
    """
    header = re.compile(r"^tasks\[\d+\]\{(?P<fields>[^}]*)\}:\s*$")
    fields = None
    rows = []
    for line in payload_lines(text):
        if fields is None:
            match = header.match(line.strip())
            if match:
                fields = [f.strip() for f in match.group("fields").split(",")]
            continue
        if not line.strip():
            continue
        if not line.startswith("  "):
            break  # trailing help block; the row list has ended
        try:
            values = next(csv.reader(io.StringIO(line.strip())))
        except (csv.Error, StopIteration):
            continue
        if len(values) < len(fields):
            continue
        row = dict(zip(fields, values))
        row["title"] = clean_title(row.get("title"))
        for key in list(row):
            if key != "title":
                row[key] = clean(row[key])
        row["link_map"] = parse_links(row.get("links", ""))
        rows.append(row)
    return rows


def parse_links(value):
    """`pr:https://...,report:data/x/report.md` into {'pr': url, ...}."""
    links = {}
    if not value:
        return links
    for part in value.split(","):
        part = part.strip()
        if not part or ":" not in part:
            continue
        kind, target = part.split(":", 1)
        kind = kind.strip()
        target = target.strip()
        if kind and target and kind not in links:
            links[kind] = target
    return links


def parse_tray(text):
    try:
        rows = json.loads(text or "[]")
    except (TypeError, ValueError):
        return []
    return rows if isinstance(rows, list) else []


def parse_orders(text):
    """`<slug>\\t<status line>\\t<key>=<value>...` into a dict.

    The deck asks for the depth-free listing, so `tray=` is normally absent; any
    trailing `<key>=<value>` field is read, and only last_fire is shown.
    """
    orders = {}
    for line in payload_lines(text):
        if not line.strip() or "\t" not in line:
            continue
        parts = line.split("\t")
        slug = parts[0].strip()
        if not slug:
            continue
        status_line = parts[1].strip() if len(parts) > 1 else ""
        token = ""
        if ":" in status_line:
            rest = status_line.split(":", 1)[1].split()
            if rest:
                token = rest[0].upper()
        fields = {}
        for part in parts[2:]:
            if "=" in part:
                key, value = part.split("=", 1)
                fields[key.strip()] = value.strip()
        orders[slug] = {
            "slug": slug,
            "status": token or "UNKNOWN",
            "last_fire": fields.get("last_fire", "-"),
        }
    return orders


def parse_tasks(text):
    rows = []
    for line in payload_lines(text):
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 7:
            continue
        rows.append(
            {
                "id": parts[0],
                "kind": parts[1],
                "project": parts[2] or "-",
                "outcome": parts[3],
                "state": parts[4] or "none",
                "heard": to_int(parts[5], -1),
                "pr": parts[6],
            }
        )
    return rows


def parse_vocabulary(text):
    vocab = {}
    for line in payload_lines(text):
        parts = line.split("\t")
        if len(parts) >= 3 and parts[0]:
            vocab[parts[0]] = (parts[1], parts[2])
    return vocab


# --- loose ends -------------------------------------------------------------

LOOSE_NUMBERED = re.compile(r"^\s{0,3}\d+\.\s+(?P<text>\S.*)$")
LOOSE_BULLET = re.compile(r"^\s{0,3}[-*]\s+(?P<text>\S.*)$")
LOOSE_HEADING = re.compile(r"^#{2,3}\s+(?P<title>.+?)\s*$")
LOOSE_TITLE = re.compile(r"^#\s+(?P<title>.+?)\s*$")


def strip_markdown(text):
    text = re.sub(r"~~(.+?)~~", r"\1", text)
    text = re.sub(r"\*\*(.+?)\*\*", r"\1", text)
    text = re.sub(r"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)", r"\1", text)
    text = re.sub(r"`(.+?)`", r"\1", text)
    text = re.sub(r"\[(.+?)\]\((.+?)\)", r"\1", text)
    return " ".join(text.split())


def classify_loose_section(title):
    lowered = title.lower()
    if "urgent" in lowered or "today" in lowered:
        return "urgent"
    if "waiting" in lowered:
        return "waiting"
    return "other"


def parse_loose_ends(text):
    """Parse the manual inbox sweep at data/loose-ends/latest.md.

    Returns None when the sweep does not exist, so the section is simply absent
    rather than an empty box the captain has to read past every refresh.
    """
    if not text.strip():
        return None
    path = ""
    age = -1
    body_lines = []
    in_body = False
    for line in payload_lines(text):
        if in_body:
            body_lines.append(line)
            continue
        if line.strip() == "body":
            in_body = True
            continue
        if "\t" in line:
            key, value = line.split("\t", 1)
            if key == "path":
                path = value.strip()
            elif key == "age_secs":
                age = to_int(value, -1)
    # The sweep numbers its actual loose ends and uses plain bullets for the
    # prose around them (corrections, calendar, context), so numbered entries
    # are the item list when the file has any. A sweep written entirely in
    # bullets still counts, rather than reporting zero open items.
    pattern = LOOSE_BULLET
    for line in body_lines:
        if LOOSE_NUMBERED.match(line):
            pattern = LOOSE_NUMBERED
            break

    title = ""
    bucket = "other"
    items = []
    total = 0
    for line in body_lines:
        if not title:
            match = LOOSE_TITLE.match(line)
            if match:
                title = strip_markdown(match.group("title"))
                continue
        match = LOOSE_HEADING.match(line)
        if match:
            bucket = classify_loose_section(match.group("title"))
            continue
        match = pattern.match(line)
        if not match:
            continue
        total += 1
        body = strip_markdown(match.group("text"))
        if not body:
            continue
        if bucket in ("urgent", "waiting"):
            items.append((bucket, body))
    return {
        "path": path,
        "age": age,
        "title": title,
        "total": total,
        "items": items,
    }


# --- section builders -------------------------------------------------------


def expiry_text(row):
    """One phrase for a staged card's expiry: EXPIRED, no expiry, expires in 2h."""
    expiry = str(row.get("expiry") or "-")
    if row.get("expired"):
        return "EXPIRED"
    if expiry == "-":
        return "no expiry"
    return "expires in " + expiry


def staged_groups(tray, orders):
    """Staged cards grouped by standing order, plus the orders with none.

    Oldest card first inside a group, and the group holding the oldest card
    first overall: age is the headline. Returns (groups, quiet_orders) where
    each group is {"order", "count", "oldest", "status", "last_fire", "cards"}
    with status and last_fire None when no standing order is on file.
    """
    grouped = {}
    for row in tray:
        grouped.setdefault(str(row.get("domain") or "-"), []).append(row)
    ordered = sorted(
        grouped.items(),
        key=lambda kv: -max(to_int(r.get("age_secs"), 0) for r in kv[1]),
    )
    groups = []
    for slug, rows in ordered:
        rows = sorted(rows, key=lambda r: -to_int(r.get("age_secs"), 0))
        order = orders.get(slug)
        cards = []
        for row in rows:
            cards.append(
                {
                    "digest": str(row.get("digest") or ""),
                    "digest_short": str(row.get("digest_short") or "")[:12],
                    "action_kind": str(row.get("action_kind") or "-"),
                    "target": str(row.get("target") or "-"),
                    "requester_id": str(row.get("requester_id") or "-"),
                    "age": str(row.get("age") or "-"),
                    "age_secs": to_int(row.get("age_secs"), -1),
                    "expiry": expiry_text(row),
                    "expired": bool(row.get("expired")),
                }
            )
        groups.append(
            {
                "order": slug,
                "count": len(cards),
                "oldest": format_age(to_int(rows[0].get("age_secs"), -1)),
                "status": order["status"] if order else None,
                "last_fire": order["last_fire"] if order else None,
                "cards": cards,
            }
        )
    quiet = [
        {"order": o["slug"], "status": o["status"], "last_fire": o["last_fire"]}
        for slug, o in sorted(orders.items())
        if not any(str(r.get("domain")) == slug for r in tray)
    ]
    return groups, quiet


def build_staged(tray, orders, width):
    """Staged actions awaiting his click, grouped by standing order."""
    groups, quiet = staged_groups(tray, orders)
    lines = []
    if not groups:
        lines.append("  nothing staged for you right now")
    for group in groups:
        if group["status"] is not None:
            context = "%s · last ran %s" % (group["status"], group["last_fire"])
        else:
            context = "no standing order on file"
        lines.append(
            "  %s  —  %d waiting, oldest %s  ·  %s"
            % (group["order"], group["count"], group["oldest"], context)
        )
        for card in group["cards"]:
            lines.append(
                "      %s %s %s %s"
                % (
                    pad(clip(card["age"], 5), 5),
                    pad(clip(card["expiry"], 14), 14),
                    pad(clip(card["action_kind"], 22), 22),
                    clip(card["target"], max(10, width - 55)),
                )
            )
    if quiet:
        summary = " · ".join(
            "%s %s (ran %s)" % (o["order"], o["status"], o["last_fire"]) for o in quiet
        )
        lines.append("  watching, nothing staged: " + clip(summary, max(20, width - 30)))
    return lines


# What each row is asking of him, in the order he should work through it.
# "check" sits below "review" because it is the weaker ask of the two: a review
# row is corroborated by a backlog this pane could actually read, and a check row
# is this home's own record of a pull request with nothing to confirm it against.
NEEDS_RANK = {"answer": 0, "unblock": 1, "review": 2, "check": 3, "decide": 4}

# Why the backlog could not be read, in the captain's words. bin/fm-deck.sh's
# collect_backlog owns these tokens; "ok" and anything unrecognised mean the
# section says nothing extra, which is the normal case.
BACKLOG_UNAVAILABLE = {
    "manual": "the backlog is kept by hand here and this pane cannot read it",
    "no-tool": "the backlog reader is not installed",
    "no-file": "this home has no backlog file",
    "unreadable": "the backlog could not be read",
}


def backlog_note(status, width, fallback):
    """What this section could NOT see, or [] when it saw everything.

    Without it the pane reports an unreadable backlog exactly the way it reports
    an empty one, and "nothing is waiting on you" becomes a claim the captain
    has no way to doubt. Two lines rather than one because both halves have to
    survive the clip: what is missing, and - only when a fallback row is
    actually standing below it - how much that row is worth. Both lead with the
    part that carries the doubt, because the clip eats the tail first.
    """
    reason = BACKLOG_UNAVAILABLE.get(status)
    if not reason:
        return []
    limit = max(20, width - 4)
    lines = ["  " + clip("%s, so rows it alone would raise are missing" % reason, limit)]
    if fallback:
        lines.append(
            "  "
            + clip(
                "not confirmed here: the pull requests below come from this "
                "home's own record",
                limit,
            )
        )
    return lines


def needs_you_rows(tasks, backlog, backlog_status="ok"):
    """Everything that cannot move without him, most immediate first.

    Returns the sorted list of (ask, title, url, where) tuples both renderings
    show. A worker's own status note never reaches either surface. Those notes
    are written for firstmate and carry pipeline vocabulary; the captain gets
    the outcome the work was commissioned for plus what is being asked of him.
    The detail lives one command away, on the decision surface.
    """
    backlog_readable = backlog_status not in BACKLOG_UNAVAILABLE
    rows = []
    seen_ids = set()

    for task in tasks:
        if task["state"] == "parked":
            rows.append(("answer", task["outcome"], "", task["project"]))
            seen_ids.add(task["id"])
        elif task["state"] == "blocked":
            rows.append(("unblock", task["outcome"], "", task["project"]))
            seen_ids.add(task["id"])

    # A dead worker still owns its pull request, so its URL is recorded even
    # though no row is emitted: without that, the backlog's row for the same URL
    # re-raises the review this pass just withheld. A finished worker is the one
    # case the pass leaves untouched - its work IS ready to look at, and while
    # its backlog row is still in flight that row is what carries it here.
    #
    # Unless there is no backlog to read. Then no such row will ever arrive, the
    # handover has nobody on the other end, and the finished work drops off the
    # pane entirely - the one place it was certain to be looked at. So the pass
    # falls back to this home's own record of the pull request and asks him to
    # check it rather than presenting it as reviewed-and-ready: a recorded URL
    # and a status line the worker wrote some time ago say the branch exists,
    # not that its checks are green or that it is fit to merge.
    #
    # Recording a URL only claims it against the backlog; it never silences
    # another worker. Where several records carry one pull request - the retry
    # that is still running alongside the attempt that died on it - they collapse
    # into a single row carrying the strongest ask any of them makes, so one pull
    # request asks for one look without a dead or finished record speaking over a
    # live one.
    pr_seen = set()
    pr_rows = {}
    for task in tasks:
        if not task["pr"]:
            continue
        if task["state"] == "done" and backlog_readable:
            continue
        pr_seen.add(task["pr"])
        if task["state"] == "failed" or task["id"] in seen_ids:
            continue
        label = "check" if task["state"] == "done" else "review"
        strongest = pr_rows.get(task["pr"])
        if strongest is None or NEEDS_RANK[label] < NEEDS_RANK[strongest[0][0]]:
            pr_rows[task["pr"]] = (
                (label, task["outcome"], task["pr"], task["project"]),
                task["id"],
            )
    for row, task_id in pr_rows.values():
        if task_id in seen_ids:
            continue
        rows.append(row)
        seen_ids.add(task_id)
    for row in backlog:
        if row.get("state") == "done":
            continue
        url = row["link_map"].get("pr", "")
        if url and url not in pr_seen:
            rows.append(("review", row.get("title", ""), url, row.get("repo", "")))
            pr_seen.add(url)

    for row in backlog:
        if row.get("state") == "done" or row.get("hold_kind") != "captain":
            continue
        if row.get("id") in seen_ids:
            continue
        rows.append(("decide", row.get("title", ""), "", row.get("repo", "")))

    rows.sort(key=lambda r: NEEDS_RANK.get(r[0], 9))
    return rows


def build_needs_you(tasks, backlog, limit, width, backlog_status="ok"):
    """The NEEDS YOU section: needs_you_rows drawn to the frame width."""
    rows = needs_you_rows(tasks, backlog, backlog_status)
    if not rows:
        note = backlog_note(backlog_status, width, False)
        return note + ["  nothing is waiting on you"], 0

    shown = rows[:limit]

    # After the slice, and over the slice: "check" is the lowest-ranked ask, so
    # it is the first row the limit drops, and a caveat about rows that are no
    # longer on the pane points at nothing.
    lines = backlog_note(backlog_status, width, any(r[0] == "check" for r in shown))
    for label, text, url, where in shown:
        where_text = (" · " + where) if where and where != "-" else ""
        lines.append(
            "  %s %s%s"
            % (
                pad(label, 8),
                clip(text, max(20, width - 15 - display_width(where_text))),
                where_text,
            )
        )
        if url:
            lines.append("           " + url)
    remaining = len(rows) - len(shown)
    if remaining > 0:
        lines.append("  %-8s %d more waiting on you" % ("", remaining))
    return lines, len(rows)


def build_loose_ends(loose, limit, width):
    headline = "  %d open · swept %s ago" % (loose["total"], format_age(loose["age"]))
    if loose["title"]:
        headline += " · " + clip(loose["title"], max(20, width - 40))
    lines = [headline]
    shown = loose["items"][:limit]
    if not shown:
        lines.append("  nothing urgent or waiting on the last sweep")
        return lines
    for bucket, text in shown:
        lines.append("  %-8s %s" % (bucket, clip(text, max(20, width - 12))))
    remaining = len(loose["items"]) - len(shown)
    if remaining > 0:
        lines.append(
            "  %-8s %d more urgent or waiting · %s"
            % ("", remaining, loose["path"] or "data/loose-ends/latest.md")
        )
    return lines


PROJECT_COL = 18
# The widest thing the last column carries is "not reported yet", and every
# state dot is two columns; the outcome column is what the frame has left over
# once the indent, the dot, the label and the two trailing columns are paid for.
HEARD_COL = 16
ICON_COL = 2
LABEL_COL = 11
UNDER_WAY_FIXED = 2 + ICON_COL + 1 + LABEL_COL + 1 + 2 + PROJECT_COL + 1 + HEARD_COL


def under_way_rows(tasks, vocab):
    """Every recorded worker, most urgent first, with its captain-facing label."""
    ordered = sorted(
        tasks, key=lambda t: (STATE_RANK.get(t["state"], 9), -t["heard"])
    )
    rows = []
    for task in ordered:
        label, icon = vocab.get(task["state"], ("WAITING", "\U0001f7e1"))
        rows.append(
            {
                "id": task["id"],
                "kind": task["kind"],
                "project": task["project"],
                "outcome": task["outcome"],
                "state": task["state"],
                "label": label,
                "icon": icon,
                "heard_secs": task["heard"],
                "pr": task["pr"],
            }
        )
    return rows


def build_under_way(tasks, vocab, width):
    if not tasks:
        return ["  no work under way"]
    # Fixed columns: he scans this section down the state dot, so the outcome
    # column cannot shift width from row to row.
    outcome_col = max(20, width - UNDER_WAY_FIXED)
    lines = []
    for task in under_way_rows(tasks, vocab):
        label, icon = task["label"], task["icon"]
        heard = format_age(task["heard_secs"])
        heard_text = ("heard %s ago" % heard) if heard != "-" else "not reported yet"
        lines.append(
            "  %s %s %s  %s %s"
            % (
                pad(icon, ICON_COL),
                pad(clip(label, LABEL_COL), LABEL_COL),
                pad(clip(task["outcome"], outcome_col), outcome_col),
                pad(clip(task["project"], PROJECT_COL), PROJECT_COL),
                clip(heard_text, HEARD_COL),
            )
        )
    return lines


def short_date(value):
    """2026-09-03 -> '03 Sep'; anything else passes through untouched."""
    try:
        return time.strftime("%d %b", time.strptime(value, "%Y-%m-%d"))
    except (TypeError, ValueError):
        return value or "-"


def just_in_rows(backlog):
    """Completed backlog items, newest first, each with the artifact it left."""
    done = [r for r in backlog if r.get("state") == "done"]
    done.sort(key=lambda r: r.get("closed", ""), reverse=True)
    rows = []
    for row in done:
        links = row["link_map"]
        if "pr" in links:
            what, artifact = "merged", links["pr"]
        elif "report" in links:
            what, artifact = "findings", links["report"]
        else:
            what, artifact = "settled", ""
        rows.append(
            {
                "id": row.get("id", ""),
                "closed": row.get("closed", ""),
                "what": what,
                "title": row.get("title", ""),
                "artifact": artifact,
                "project": row.get("repo", ""),
            }
        )
    return rows


def build_just_in(backlog, limit, width):
    done = just_in_rows(backlog)
    if not done:
        return ["  nothing has landed recently"]
    lines = []
    for row in done[:limit]:
        lines.append(
            "  %s %s %s"
            % (
                pad(short_date(row["closed"]), 7),
                pad(row["what"], 9),
                clip(row["title"], max(20, width - 21)),
            )
        )
        if row["artifact"]:
            lines.append("          " + row["artifact"])
    return lines


# --- frame ------------------------------------------------------------------


# Worker-authored text - a tray target or action kind, a backlog title, a
# commissioned outcome, a loose-ends item - reaches an always-on terminal here.
# An ESC inside any of it could move the cursor, clear regions, or forge a whole
# frame on the captain's private pane, and str.split() in clip() does not treat
# C0 or C1 as whitespace, so it survives every other normalization on the way.
# Every line of the frame passes through scrub() at the single write below; the
# pane's own text is plain (its rules, dots and labels are literal characters),
# so refusing the whole range costs nothing legitimate.
CONTROL_CHARS = re.compile(r"[\x00-\x1f\x7f-\x9f]")


def scrub(line):
    return CONTROL_CHARS.sub("", line)


def rule(width):
    return "─" * width


def heading(title, width):
    label = " " + title + " "
    return label + "─" * max(0, width - display_width(label))


def read_payload(stream, mark):
    """Parse every section once, for whichever rendering is asked for."""
    sections = parse_payload(stream, mark)
    limits = first_line(sections.get("limits", "")).split("\t")
    return {
        "now": to_int(first_line(sections.get("now", "")), int(time.time())),
        "width": max(
            MIN_WIDTH,
            min(MAX_WIDTH, to_int(first_line(sections.get("width", "")), 100)),
        ),
        "home": first_line(sections.get("home", "")) or "this home",
        "interval": first_line(sections.get("interval", "")),
        "just_in_limit": to_int(limits[0] if limits else "", JUST_IN_DEFAULT),
        "loose_limit": to_int(limits[1] if len(limits) > 1 else "", LOOSE_ENDS_DEFAULT),
        "needs_limit": to_int(limits[2] if len(limits) > 2 else "", NEEDS_YOU_DEFAULT),
        "vocab": parse_vocabulary(sections.get("vocabulary", "")),
        "tray": parse_tray(sections.get("tray", "")),
        "orders": parse_orders(sections.get("orders", "")),
        "backlog": parse_backlog(sections.get("backlog", "")),
        "backlog_status": first_line(sections.get("backlog_status", "")) or "ok",
        "tasks": parse_tasks(sections.get("tasks", "")),
        "loose": parse_loose_ends(sections.get("loose_ends", "")),
    }


def scrub_deep(value):
    """scrub() applied through a JSON model, so a browser renderer receives
    the same control-character-free text the terminal does."""
    if isinstance(value, str):
        return scrub(value)
    if isinstance(value, list):
        return [scrub_deep(item) for item in value]
    if isinstance(value, dict):
        return {key: scrub_deep(item) for key, item in value.items()}
    return value


def build_model(payload):
    """The `fm-deck.v1` structured model: the pane's sections, unclipped.

    Limits are reported, not applied - a web renderer folds the remainder
    instead of dropping it, so nothing that the terminal would count as
    "+n more" goes missing here. `needs_you.rows` is the same sorted list the
    terminal draws, `unconfirmed` mirrors the terminal's caveat about pull
    requests that come from this home's own record, and completed work sits
    only in `just_in` so a renderer cannot mistake it for something to act on.
    """
    tray = payload["tray"]
    groups, quiet = staged_groups(tray, payload["orders"])
    needs = needs_you_rows(payload["tasks"], payload["backlog"], payload["backlog_status"])
    backlog_reason = BACKLOG_UNAVAILABLE.get(payload["backlog_status"])
    loose = payload["loose"]
    oldest = max((to_int(r.get("age_secs"), 0) for r in tray), default=-1)
    model = {
        "schema": "fm-deck.v1",
        "now": payload["now"],
        "home": payload["home"],
        "limits": {
            "needs_you": payload["needs_limit"],
            "loose_ends": payload["loose_limit"],
            "just_in": payload["just_in_limit"],
        },
        "counts": {
            "needs_you": len(needs),
            "staged": len(tray),
            "staged_oldest": format_age(oldest) if tray else None,
            "loose_ends": loose["total"] if loose is not None else None,
            "under_way": len(payload["tasks"]),
        },
        "staged": {"groups": groups, "quiet_orders": quiet},
        "needs_you": {
            "rows": [
                {"ask": ask, "title": title, "url": url, "project": where}
                for ask, title, url, where in needs
            ],
            "backlog_status": payload["backlog_status"],
            "backlog_reason": backlog_reason,
            "unconfirmed": any(ask == "check" for ask, _t, _u, _w in needs),
        },
        "loose_ends": None
        if loose is None
        else {
            "path": loose["path"],
            "age_secs": loose["age"],
            "title": loose["title"],
            "total": loose["total"],
            "items": [{"bucket": bucket, "text": text} for bucket, text in loose["items"]],
        },
        "under_way": under_way_rows(payload["tasks"], payload["vocab"]),
        "just_in": just_in_rows(payload["backlog"]),
    }
    return scrub_deep(model)


def main():
    args = sys.argv[1:]
    as_json = False
    if args and args[0] == "--json":
        as_json = True
        args = args[1:]
    mark = args[0] if args else "__FM_DECK_SECTION__"
    payload = read_payload(sys.stdin, mark)

    if as_json:
        sys.stdout.write(json.dumps(build_model(payload), ensure_ascii=False) + "\n")
        return

    now = payload["now"]
    width = payload["width"]
    home = payload["home"]
    interval = payload["interval"]
    just_in_limit = payload["just_in_limit"]
    loose_limit = payload["loose_limit"]
    needs_limit = payload["needs_limit"]
    vocab = payload["vocab"]
    tray = payload["tray"]
    orders = payload["orders"]
    backlog = payload["backlog"]
    backlog_status = payload["backlog_status"]
    tasks = payload["tasks"]
    loose = payload["loose"]

    staged = build_staged(tray, orders, width)
    needs_you, needs_count = build_needs_you(
        tasks, backlog, needs_limit, width, backlog_status
    )
    under_way = build_under_way(tasks, vocab, width)
    just_in = build_just_in(backlog, just_in_limit, width)

    oldest = format_age(max((to_int(r.get("age_secs"), 0) for r in tray), default=-1))

    counts = [
        "%d need you" % needs_count,
        "%d staged%s" % (len(tray), (" (oldest %s)" % oldest) if tray else ""),
    ]
    if loose is not None:
        counts.append("%d loose ends" % loose["total"])
    counts.append("%d under way" % len(tasks))

    clock = time.strftime("%a %d %b %H:%M:%S", time.localtime(now))
    title = "⚓  ACTION DECK · " + home
    gap = max(1, width - display_width(title) - display_width(clock))

    out = [
        rule(width),
        title + " " * gap + clock,
        "   " + clip(" · ".join(counts), width - 4),
        rule(width),
        "",
        heading("STAGED FOR YOUR CLICK", width),
    ]
    out += staged
    out += ["", heading("NEEDS YOU", width)]
    out += needs_you
    if loose is not None:
        out += ["", heading("LOOSE ENDS", width)]
        out += build_loose_ends(loose, loose_limit, width)
    out += ["", heading("UNDER WAY", width)]
    out += under_way
    out += ["", heading("JUST IN", width)]
    out += just_in
    out += ["", rule(width)]

    cadence = ("refreshing every %ss" % interval) if interval else "snapshot"
    out.append(
        clip(
            "%s · view only · approve fm-action-gateway.sh · "
            "decide fm-decision-surface.sh · live fm-fleet-view.sh" % cadence,
            width,
        )
    )

    sys.stdout.write("\n".join(scrub(line) for line in out) + "\n")


if __name__ == "__main__":
    main()
