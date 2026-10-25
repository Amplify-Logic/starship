#!/usr/bin/env python3
# fm-outward-check.py - the worker outward-action check: before a spawned
# Claude worker acts outward through a connected account or the captain's
# browser, it refuses the action unless this job or the home allows it.
#
# Usage:
#   fm-outward-check.py hook --config DIR --state DIR --task ID
#       The Claude Code PreToolUse hook bin/fm-spawn.sh installs for every
#       spawned Claude worker (ship or scout). Reads the hook payload on stdin.
#       On a refusal it prints the documented PreToolUse deny object on stdout;
#       on an allow it prints nothing. It always exits 0, and any failure inside
#       the check refuses the action.
#   fm-outward-check.py seen --state DIR --task ID
#       The matching PostToolUse hook. When a calendar tool's answer shows an
#       event, it records that event's organizer in state/<task>.outward-seen.json
#       so an `invites from` permission can be checked against the real
#       organizer. It decodes JSON only from the answer itself when Claude Code
#       passes it as one string (as it does for the calendar connector) or from
#       its MCP text blocks, never from a string inside the decoded answer, so
#       an event's own text cannot name an organizer. It never blocks anything
#       and always exits 0.
#   fm-outward-check.py parse TEXT...
#       Check permission text (several permissions separated by ";" or new
#       lines) and print its normalized form on one line, each permission once
#       ("none" when there is none), or name what is not understood on stderr
#       and exit 1. bin/fm-brief.sh, bin/fm-spawn.sh and
#       bin/fm-outward-grant.sh use it for `--outward`.
#   fm-outward-check.py check-config --config DIR
#       Print each line of config/outward-permissions that is not understood
#       and exit 1 when there is one; exit 0 when the file is absent or clean.
#       This operator view names the file; the worker's refusal never does.
#   fm-outward-check.py style --config DIR [show]
#   fm-outward-check.py style --config DIR fine-print|no-block
#   fm-outward-check.py style --config DIR broad [SWITCH[, SWITCH...]]
#       Show or switch the home's outward style; bin/fm-outward-style.sh is
#       the operator entry point and its header owns the usage. `show` prints
#       one line, "Outward: <style>". A switch rewrites only the style line (and,
#       for broad with SWITCHES, the broad lines) and prints one sentence saying
#       which style is now on and what it means.
#
# docs/configuration.md "Worker outward actions" owns the operator contract:
# what counts as outward, the permission words, standing permissions and the
# outward styles. This header owns the mechanics.
#
# WHAT IS GUARDED. Only MCP tools named mcp__claude_ai_<connector>__<action>
# (the claude.ai connectors: Gmail, Google Calendar, Drive, Zapier, Claude
# Docs and any connector added later) and mcp__claude-in-chrome__<action>
# (control of the captain's Chrome). Every other tool passes untouched.
# An action is split into words on "_". It passes without any permission when
# none of its words is an outward word (OUTWARD_WORDS) and its first word reads
# (READ_WORDS), or it creates or updates a draft, or on the browser it only
# moves between tabs, resizes the window or records a GIF (BROWSER_LOOK_WORDS).
# A first word that repeats the connector's own name, the last word of its
# server (slack_read_channel on claude_ai_Slack), is skipped for those tests,
# never for the outward words; an org word, the first half of a two-word name
# or a word that already reads or drafts is never skipped.
# Opening a URL (navigate) is an action, because a link in the captain's
# logged-in browser can itself answer an invite or submit a form. Every Zapier
# tool is an action. Everything else needs a permission, so a tool a connector adds later
# is refused until something allows it.
#
# PERMISSIONS. A refused kind of action is named in the words a permission uses:
# "send email" (any mail action with send, reply or forward), "respond to
# invites" (calendar respond, accept, decline, rsvp), "change calendar" (any
# other calendar change), "organise mail" (any other mailbox change), "control
# browser" (any other browser action), "use zapier" (any Zapier tool). "reply
# to email" allows only a mail action with reply among its words. Other
# connectors have no kind and are allowed only by "use <tool name or glob>",
# which also names a single Zapier tool. "send email to <addresses>" holds
# only when every recipient is visible in the tool input (to, cc, bcc; a reply
# needs an explicit to, and a reply-all an explicit cc; a draft sent by id never
# shows its recipients), each field is a list whose every item is exactly one
# plain address (no display name, brackets, commas or spaces), and each one is a
# listed address or a listed @domain.
# "accept|decline|respond to invites from <addresses>" holds only when this
# worker has read the event (get, list or search) so `seen` recorded its
# organizer, and accept or decline also requires that answer.
# The job's permissions are the last `outward=` line of state/<task>.meta;
# the home's standing permissions are config/outward-permissions, read on every
# call, so a change takes effect at once.
#
# STYLES. A line `style fine print|broad switches|no block` in that file picks
# the home's outward style; with none the style is fine print, and the older
# bare `no block` line still means no block. Lines naming two different styles
# are a problem and leave fine print. Fine print checks the job's permissions
# and the plain standing lines. Broad switches also honours each `broad
# <switch>` line, where a switch is exactly one of BROAD_SWITCHES, for every
# worker; in any other style those lines are kept but allow nothing. The style
# and switch names are only those exact words. No block switches the
# check off for every worker in the home. A switch through `style` drops only
# style lines and, when SWITCHES are given, the broad lines, so narrow standing
# permissions, comments and lines not understood survive every switch. Broad
# with no SWITCHES keeps the existing broad lines, and with none turns no
# switch on and asks which to allow.
# A refusal names the permission that would allow the action but never the
# grant command, the permissions file or any other path: only the captain
# widens what a worker may do, through Firstmate.
#
# RECORD. Every refusal and every outward action a permission, a broad switch
# or no block let through is appended as one JSON line to
# state/outward-check.log: time, task, tool, kind, decision and the permission
# that decided. Tool inputs, such as message bodies, are never logged.
import fnmatch
import json
import os
import pathlib
import re
import sys
import time

CONNECTOR_PREFIX = "claude_ai_"
BROWSER_SERVER = "claude-in-chrome"

READ_WORDS = {"get", "list", "search", "read", "query", "find", "fetch",
              "suggest", "guide", "export", "download", "view", "count",
              "describe", "lookup"}
BROWSER_LOOK_WORDS = {"tabs", "resize", "select", "switch", "gif"}
DRAFT_WORDS = {"draft", "drafts"}
DRAFT_VERBS = {"create", "update"}
OUTWARD_WORDS = {"send", "reply", "forward", "share", "unshare", "publish",
                 "post", "delete", "remove", "trash", "move", "accept",
                 "decline", "respond", "rsvp", "invite", "submit", "pay"}
SEND_WORDS = {"send", "reply", "forward"}
RESPOND_WORDS = {"respond", "accept", "decline", "rsvp"}

SEND = "send email"
REPLY = "reply to email"
INVITES = "respond to invites"
CALENDAR = "change calendar"
MAILBOX = "organise mail"
BROWSER = "control browser"
ZAPIER = "use zapier"
USE = "use"

DOES = {
    SEND: "would send email",
    INVITES: "would answer a calendar invite",
    CALENDAR: "would change the calendar",
    MAILBOX: "would change the mailbox",
    BROWSER: "would act in the captain's browser",
    ZAPIER: "would run a Zapier action",
    None: "would act through a connected account",
}

FINE_PRINT = "fine print"
BROAD = "broad switches"
NO_BLOCK = "no block"
STYLES = (FINE_PRINT, BROAD, NO_BLOCK)
STYLE_COMMANDS = {"fine-print": FINE_PRINT, "broad": BROAD, "no-block": NO_BLOCK}
BROAD_SWITCHES = (SEND, REPLY, INVITES, CALENDAR, BROWSER, ZAPIER)
SWITCH_PROSE = {SEND: "send email", REPLY: "reply to email", INVITES: "answer calendar invites",
                CALENDAR: "change the calendar", BROWSER: "control the browser",
                ZAPIER: "run Zapier actions"}

PERMISSIONS_FILE = "outward-permissions"
LOG_NAME = "outward-check.log"
LOG_MAX_BYTES = 1_000_000
SEEN_MAX = 2000
VOCABULARY = ("send email [to <addresses>]; reply to email; respond to invites [from <addresses>]; "
              "accept invites [from <addresses>]; decline invites [from <addresses>]; "
              "change calendar; organise mail; control browser; use zapier; use <tool name or glob>")

PLAIN_ADDRESS_RE = re.compile(r"^[^@\s,;<>]+@[^@\s,;<>]+$")
ADDRESS_RE = re.compile(r"^(?:[^@\s,;<>]+)?@[^@\s,;<>]+\.[^@\s,;<>]+$")
SEND_RE = re.compile(r"^send (?:e-?mails?|mail)(?: to (?P<who>.+))?$", re.I)
REPLY_RE = re.compile(r"^reply to (?:e-?mails?|mail)$", re.I)
ZAPIER_RE = re.compile(r"^use zapier$", re.I)
INVITES_RE = re.compile(
    r"^(?P<verb>respond to|accept|decline) (?:calendar )?invit(?:es?|ations?)(?: from (?P<who>.+))?$",
    re.I)
CALENDAR_RE = re.compile(r"^(?:change|edit) (?:the )?calendar$", re.I)
MAILBOX_RE = re.compile(r"^organi[sz]e (?:e-?)?mail$", re.I)
BROWSER_RE = re.compile(r"^control (?:the )?browser$", re.I)
USE_RE = re.compile(r"^use (?P<pattern>mcp__\S+)$", re.I)
INSTANCE_SUFFIX_RE = re.compile(r"_\d{8}(?:T\d{6}Z?)?$")


# --- permission text --------------------------------------------------------

def parse_addresses(text):
    words = [w for w in re.split(r"[\s,]+", text.strip().lower()) if w and w != "and"]
    bad = [w for w in words if not ADDRESS_RE.match(w)]
    if not words or bad:
        raise ValueError("'%s' is not a list of email addresses or @domains" % text.strip())
    return words


def parse_one(piece):
    """One permission phrase -> dict, or ValueError naming what is wrong."""
    text = " ".join(piece.split())
    m = SEND_RE.match(text)
    if m:
        who = parse_addresses(m.group("who")) if m.group("who") else []
        return {"kind": SEND, "who": who}
    if REPLY_RE.match(text):
        return {"kind": REPLY}
    m = INVITES_RE.match(text)
    if m:
        verb = m.group("verb").lower()
        verb = "respond" if verb == "respond to" else verb
        who = parse_addresses(m.group("who")) if m.group("who") else []
        return {"kind": INVITES, "verb": verb, "who": who}
    if CALENDAR_RE.match(text):
        return {"kind": CALENDAR}
    if MAILBOX_RE.match(text):
        return {"kind": MAILBOX}
    if BROWSER_RE.match(text):
        return {"kind": BROWSER}
    if ZAPIER_RE.match(text):
        return {"kind": ZAPIER}
    m = USE_RE.match(text)
    if m:
        return {"kind": USE, "pattern": m.group("pattern")}
    raise ValueError("'%s' is not understood; use one of: %s" % (text, VOCABULARY))


def render(grant):
    kind = grant["kind"]
    if kind == SEND:
        return SEND + (" to " + ", ".join(grant["who"]) if grant["who"] else "")
    if kind == INVITES:
        verb = "respond to" if grant["verb"] == "respond" else grant["verb"]
        return "%s invites%s" % (verb, " from " + ", ".join(grant["who"]) if grant["who"] else "")
    if kind == USE:
        return "use " + grant["pattern"]
    return kind


def parse_grants(text):
    """Text holding permissions separated by ';' or new lines -> (grants, errors)."""
    grants, errors = [], []
    for piece in re.split(r"[;\n]", text or ""):
        if not piece.strip() or piece.strip().lower() == "none":
            continue
        try:
            grants.append(parse_one(piece))
        except ValueError as e:
            errors.append(str(e))
    return grants, errors


def error_text(e):
    """An error's text without the file name an OSError carries."""
    return e.strerror if isinstance(e, OSError) and e.strerror else str(e)


def plain(raw):
    """A file line without its comment, lower case with single spaces."""
    return " ".join(raw.split("#", 1)[0].lower().split())


def line_style(line):
    """A plain line -> the style it names, or None when it names none."""
    if line == "no block":
        return NO_BLOCK
    if line.startswith("style "):
        style = line[len("style "):]
        return style if style in STYLES else ""
    return None


def parse_switch(text):
    """One broad switch name -> that name, or ValueError."""
    name = " ".join(text.lower().split())
    if name not in BROAD_SWITCHES:
        raise ValueError("'%s' is not a broad switch; use one of: %s" % (text.strip(), "; ".join(BROAD_SWITCHES)))
    return name


def read_config(config_dir):
    """config/outward-permissions -> {style, standing, broad, problems}; problems never name the file's path."""
    path = pathlib.Path(config_dir) / PERMISSIONS_FILE
    config = {"style": FINE_PRINT, "standing": [], "broad": [], "problems": []}
    if not path.exists():
        return config
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError) as e:
        config["problems"].append("the standing permissions could not be read (%s)" % error_text(e))
        return config
    styles = []
    for number, raw in enumerate(lines, 1):
        line = plain(raw)
        if not line:
            continue
        style = line_style(line)
        if style == "":
            config["problems"].append("standing permission line %d: '%s' is not a style; use one of: %s"
                                      % (number, line, "; ".join(STYLES)))
        elif style:
            if style not in styles:
                styles.append(style)
        elif line.startswith("broad "):
            try:
                name = parse_switch(line[len("broad "):])
                if name not in config["broad"]:
                    config["broad"].append(name)
            except ValueError as e:
                config["problems"].append("standing permission line %d: %s" % (number, e))
        else:
            try:
                config["standing"].append(parse_one(line))
            except ValueError as e:
                config["problems"].append("standing permission line %d: %s" % (number, e))
    if len(styles) > 1:
        config["problems"].append("the standing permissions name more than one style (%s), so fine print holds"
                                  % ", ".join(styles))
    elif styles:
        config["style"] = styles[0]
    return config


def task_grants(state_dir, task):
    value = ""
    try:
        with open(pathlib.Path(state_dir) / (task + ".meta"), encoding="utf-8") as f:
            for line in f:
                if line.startswith("outward="):
                    value = line[len("outward="):].rstrip("\n")
    except FileNotFoundError:
        pass
    return parse_grants(value)


# --- tools -------------------------------------------------------------------

def split_tool(name):
    if not isinstance(name, str) or not name.startswith("mcp__"):
        return None
    server, sep, action = name[len("mcp__"):].partition("__")
    if not sep or not action:
        return None
    if not (server.startswith(CONNECTOR_PREFIX) or server == BROWSER_SERVER):
        return None
    return server, action


def family(server):
    s = server.lower()
    if s == BROWSER_SERVER:
        return "browser"
    if "zapier" in s:
        return "zapier"
    if "calendar" in s:
        return "calendar"
    if "mail" in s:
        return "mail"
    return "other"


def words_of(action):
    return [w for w in re.split(r"[^a-z0-9]+", action.lower()) if w]


def verb_words(server, words):
    """words without a leading word that repeats the connector's own name, the last word of its server."""
    name = words_of(server[len(CONNECTOR_PREFIX):])[-1:] if server.startswith(CONNECTOR_PREFIX) else []
    if len(words) > 1 and words[:1] == name and words[0] not in READ_WORDS | DRAFT_VERBS:
        return words[1:]
    return words


def classify(server, action):
    """-> (needs_permission, kind)."""
    fam = family(server)
    words = words_of(action)
    if fam != "zapier" and words and not set(words) & OUTWARD_WORDS:
        verbs = verb_words(server, words)
        if verbs[0] in READ_WORDS:
            return False, None
        if fam == "browser" and verbs[0] in BROWSER_LOOK_WORDS:
            return False, None
        if verbs[0] in DRAFT_VERBS and set(verbs) & DRAFT_WORDS:
            return False, None
    if fam == "mail":
        return True, SEND if set(words) & SEND_WORDS else MAILBOX
    if fam == "calendar":
        return True, INVITES if set(words) & RESPOND_WORDS else CALENDAR
    if fam == "browser":
        return True, BROWSER
    if fam == "zapier":
        return True, ZAPIER
    return True, None


def address_list(field, value):
    """-> (addresses, None) or (None, why they cannot be confirmed); each item must be one plain address."""
    if value is None:
        return [], None
    if not isinstance(value, list):
        return None, "%s is not a list of plain email addresses, so its recipients cannot be confirmed" % field
    out = []
    for item in value:
        if not isinstance(item, str) or not PLAIN_ADDRESS_RE.match(item.strip()):
            return None, ("%s entry %s is not exactly one plain email address, so its recipients cannot be confirmed"
                          % (field, json.dumps(item)))
        out.append(item.strip().lower())
    return out, None


def recipients(action, tool_input):
    """-> (addresses, None) or (None, why they cannot be seen)."""
    words = set(words_of(action))
    if tool_input.get("draftId") or words & DRAFT_WORDS:
        return None, "it sends a saved draft, whose recipients the check cannot see"
    fields = {}
    for field in ("to", "cc", "bcc"):
        fields[field], why = address_list(field, tool_input.get(field))
        if why:
            return None, why
    to, cc, bcc = fields["to"], fields["cc"], fields["bcc"]
    if "reply" in words:
        if not to:
            return None, "a reply to the default recipients does not show who receives it; name them in to"
        if tool_input.get("replyAll") and not cc:
            return None, "a reply-all without an explicit cc does not show who receives it"
    found = to + cc + bcc
    if not found:
        return None, "no recipients are visible in the request"
    return found, None


def address_allowed(address, allowed):
    for entry in allowed:
        if entry.startswith("@"):
            if address.count("@") == 1 and address.endswith(entry):
                return True
        elif address == entry:
            return True
    return False


def organizer_of(state_dir, task, event_id):
    seen = read_seen(state_dir, task)
    if not isinstance(event_id, str):
        return None
    return seen.get(event_id) or seen.get(INSTANCE_SUFFIX_RE.sub("", event_id))


def invite_answer(action, tool_input):
    status = tool_input.get("responseStatus")
    if isinstance(status, str) and status:
        return status.lower()
    words = set(words_of(action))
    if "accept" in words:
        return "accepted"
    if "decline" in words:
        return "declined"
    return ""


def grant_allows(grant, tool, server, action, kind, tool_input, ctx):
    """-> (allowed, why-not or None)."""
    if grant["kind"] == USE:
        return fnmatch.fnmatchcase(tool.lower(), grant["pattern"].lower()), None
    if grant["kind"] == REPLY:
        return kind == SEND and "reply" in words_of(action), None
    if grant["kind"] != kind:
        return False, None
    label = "'%s'" % render(grant)
    if kind == SEND and grant["who"]:
        found, why = recipients(action, tool_input)
        if found is None:
            return False, "%s does not cover this: %s" % (label, why)
        others = [a for a in found if not address_allowed(a, grant["who"])]
        if others:
            return False, "%s does not cover %s" % (label, ", ".join(others))
        return True, None
    if kind == INVITES:
        if grant["verb"] in ("accept", "decline"):
            want = {"accept": "accepted", "decline": "declined"}[grant["verb"]]
            answer = invite_answer(action, tool_input)
            if answer != want:
                return False, "%s does not cover answering '%s'" % (label, answer or "unknown")
        if grant["who"]:
            organizer = organizer_of(ctx["state"], ctx["task"], tool_input.get("eventId"))
            if not organizer:
                return False, ("%s needs the event's organizer, which this job has not seen yet; "
                               "read the event with get_event first" % label)
            if not address_allowed(organizer, grant["who"]):
                return False, "%s does not cover invites from %s" % (label, organizer)
        return True, None
    return True, None


def suggestion(tool, action, kind, tool_input, state_dir, task):
    if kind == SEND:
        found, _ = recipients(action, tool_input)
        return render({"kind": SEND, "who": found or []})
    if kind == INVITES:
        organizer = organizer_of(state_dir, task, tool_input.get("eventId"))
        answer = invite_answer(action, tool_input)
        verb = {"accepted": "accept", "declined": "decline"}.get(answer, "respond")
        return render({"kind": INVITES, "verb": verb, "who": [organizer] if organizer else []})
    if kind in (None, ZAPIER):
        return "use " + tool
    return kind


# --- the record ----------------------------------------------------------------

def append_log(state_dir, entry):
    try:
        path = pathlib.Path(state_dir) / LOG_NAME
        try:
            if path.stat().st_size > LOG_MAX_BYTES:
                os.replace(path, path.with_name(LOG_NAME + ".1"))
        except FileNotFoundError:
            pass
        with open(path, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, sort_keys=True) + "\n")
    except OSError:
        pass


def seen_path(state_dir, task):
    return pathlib.Path(state_dir) / (task + ".outward-seen.json")


def read_seen(state_dir, task):
    try:
        data = json.loads(seen_path(state_dir, task).read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def collect_organizers(obj, out, depth=0, decoded=False):
    if depth > 40:
        return
    if isinstance(obj, str):
        if depth == 0:
            try:
                collect_organizers(json.loads(obj), out, depth + 1, True)
            except ValueError:
                pass
        return
    if isinstance(obj, dict):
        if not decoded and obj.get("type") == "text" and isinstance(obj.get("text"), str):
            try:
                collect_organizers(json.loads(obj["text"]), out, depth + 1, True)
            except ValueError:
                pass
            return
        event_id = obj.get("id") or obj.get("eventId")
        organizer = obj.get("organizer")
        if isinstance(event_id, str) and isinstance(organizer, dict) \
                and isinstance(organizer.get("email"), str):
            out[event_id] = organizer["email"].strip().lower()
        for value in obj.values():
            collect_organizers(value, out, depth + 1, decoded)
    elif isinstance(obj, list):
        for value in obj:
            collect_organizers(value, out, depth + 1, decoded)


# --- commands -------------------------------------------------------------------

def opts(argv, names):
    values = {}
    i = 0
    while i < len(argv):
        key = argv[i].lstrip("-")
        if not argv[i].startswith("--") or key not in names or i + 1 >= len(argv):
            raise SystemExit("error: unexpected argument %r" % argv[i])
        values[key] = argv[i + 1]
        i += 2
    missing = [n for n in names if n not in values]
    if missing:
        raise SystemExit("error: missing --%s" % " --".join(missing))
    return values


def deny(reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}))


def refusal(tool, kind, suggest, reasons, problems):
    lines = ["Starship refused %s: it %s, and neither this job nor this home has permission for that."
             % (tool, DOES.get(kind, DOES[None]))]
    lines += [r[0].upper() + r[1:] + "." for r in reasons]
    lines += ["Note: %s." % p for p in problems]
    lines.append("The permission that would allow it is '%s'; only the captain can give it." % suggest)
    lines.append("Reading, searching, listing and creating drafts stay allowed.")
    lines.append("Do not retry this or reach the same result another way (another tool, the browser, a script),"
                 " and do not try to give yourself the permission.")
    lines.append("If the job needs it, append a blocked: status line naming exactly what was refused"
                 " and the permission '%s', and stop." % suggest)
    return "\n".join(lines)


def cmd_hook(argv):
    o = opts(argv, ("config", "state", "task"))
    tool = "an unreadable tool call"
    try:
        payload = json.load(sys.stdin)
        tool = payload.get("tool_name") or ""
        parts = split_tool(tool)
        if not parts:
            return 0
        server, action = parts
        needs, kind = classify(server, action)
        if not needs:
            return 0
        tool_input = payload.get("tool_input")
        tool_input = tool_input if isinstance(tool_input, dict) else {}
        entry = {"ts": int(time.time()), "task": o["task"], "tool": tool, "kind": kind or "other"}
        config = read_config(o["config"])
        if config["style"] == NO_BLOCK:
            append_log(o["state"], dict(entry, decision="allow", by="no block"))
            return 0
        own, own_errors = task_grants(o["state"], o["task"])
        problems = ["this job's permission %s" % e for e in own_errors] + config["problems"]
        ctx = {"state": o["state"], "task": o["task"]}
        reasons = []
        sources = [("job", own), ("standing", config["standing"])]
        if config["style"] == BROAD:
            sources.append(("broad", [parse_one(name) for name in config["broad"]]))
        for source, grants in sources:
            for grant in grants:
                ok, why = grant_allows(grant, tool, server, action, kind, tool_input, ctx)
                if ok:
                    append_log(o["state"], dict(entry, decision="allow", by="%s: %s" % (source, render(grant))))
                    return 0
                if why:
                    reasons.append(why)
        suggest = suggestion(tool, action, kind, tool_input, o["state"], o["task"])
        append_log(o["state"], dict(entry, decision="refuse", by="none"))
        deny(refusal(tool, kind, suggest, reasons, problems))
    except Exception as e:  # any failure refuses: this check never steps aside
        deny("Starship refused %s because its outward check failed (%s: %s). "
             "Do not retry it or route around it; append a blocked: status line naming this error and stop."
             % (tool, type(e).__name__, error_text(e)))
    return 0


def cmd_seen(argv):
    o = opts(argv, ("state", "task"))
    try:
        payload = json.load(sys.stdin)
        parts = split_tool(payload.get("tool_name") or "")
        if not parts or family(parts[0]) != "calendar":
            return 0
        found = {}
        collect_organizers(payload.get("tool_response"), found)
        if not found:
            return 0
        seen = read_seen(o["state"], o["task"])
        for event_id, organizer in found.items():
            seen.pop(event_id, None)
            seen[event_id] = organizer
        while len(seen) > SEEN_MAX:
            seen.pop(next(iter(seen)))
        path = seen_path(o["state"], o["task"])
        tmp = path.with_name(".%s.%d" % (path.name, os.getpid()))
        tmp.write_text(json.dumps(seen), encoding="utf-8")
        os.replace(tmp, path)
    except Exception:  # recording is best effort; the refusal side never depends on it succeeding
        pass
    return 0


def cmd_parse(argv):
    grants, errors = parse_grants("\n".join(argv))
    if errors:
        for e in errors:
            print("error: %s" % e, file=sys.stderr)
        return 1
    rendered = []
    for grant in grants:
        if render(grant) not in rendered:
            rendered.append(render(grant))
    print("; ".join(rendered) or "none")
    return 0


def cmd_check_config(argv):
    o = opts(argv, ("config",))
    problems = read_config(o["config"])["problems"]
    for p in problems:
        print("%s: %s" % (pathlib.Path(o["config"]) / PERMISSIONS_FILE, p))
    return 1 if problems else 0


def prose_list(items):
    return items[0] if len(items) == 1 else ", ".join(items[:-1]) + " and " + items[-1]


def style_line(config):
    if config["style"] == BROAD:
        return "Outward: %s (%s)" % (BROAD, ", ".join(config["broad"]) or "none on")
    return "Outward: " + config["style"]


def style_sentence(config):
    style = config["style"]
    if style == NO_BLOCK:
        return ("Outward style is now no block: the check is off, so every worker acts outward"
                " whenever its instructions say to.")
    if style == BROAD:
        if not config["broad"]:
            return ("Outward style is now broad switches, but no switch is on, so workers still act outward"
                    " only with their job's own permission or a standing permission; which should every worker"
                    " be allowed to do: %s?"
                    % prose_list([SWITCH_PROSE[name] for name in BROAD_SWITCHES]).replace(" and ", " or "))
        return ("Outward style is now broad switches: every worker may %s without asking, and anything else"
                " still needs its job's own permission or a standing permission."
                % prose_list([SWITCH_PROSE[name] for name in config["broad"]]))
    count = len(config["standing"])
    if not count:
        return ("Outward style is now fine print: workers act outward only with their job's own permission,"
                " since this home has no standing permissions.")
    return ("Outward style is now fine print: workers act outward only with their job's own permission"
            " or one of this home's %d standing permission%s." % (count, "" if count == 1 else "s"))


def write_style(config_dir, style, switches):
    """Rewrite the style line, and the broad lines when switches is a list, keeping every other line."""
    path = pathlib.Path(config_dir) / PERMISSIONS_FILE
    lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
    kept = []
    for raw in lines:
        line = plain(raw)
        if line_style(line) is not None:
            continue
        if switches is not None and line.startswith("broad "):
            continue
        kept.append(raw)
    out = ["style " + style] + kept + ["broad " + name for name in switches or []]
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(".%s.%d" % (path.name, os.getpid()))
    tmp.write_text("\n".join(out) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def cmd_style(argv):
    if len(argv) < 2 or argv[0] != "--config":
        raise SystemExit("error: missing --config")
    config_dir, rest = argv[1], argv[2:]
    action = rest[0] if rest else "show"
    if action == "show" and len(rest) <= 1:
        print(style_line(read_config(config_dir)))
        return 0
    style = STYLE_COMMANDS.get(action)
    if not style or (style != BROAD and len(rest) > 1):
        print("usage: fm-outward-style.sh [show] | fine-print | no-block | broad [<switch>[, <switch>...]]",
              file=sys.stderr)
        return 2
    switches = None
    if len(rest) > 1:
        switches = []
        try:
            for piece in " ".join(rest[1:]).split(","):
                if not piece.strip():
                    continue
                name = parse_switch(piece)
                if name not in switches:
                    switches.append(name)
        except ValueError as e:
            print("error: %s" % e, file=sys.stderr)
            return 1
        if not switches:
            print("error: no broad switch given", file=sys.stderr)
            return 1
    try:
        write_style(config_dir, style, switches)
    except (OSError, UnicodeDecodeError) as e:
        print("error: the outward style could not be changed (%s)" % error_text(e), file=sys.stderr)
        return 1
    config = read_config(config_dir)
    print(style_sentence(config))
    for p in config["problems"]:
        print("note: %s" % p, file=sys.stderr)
    return 0


def main(argv):
    commands = {"hook": cmd_hook, "seen": cmd_seen, "parse": cmd_parse, "check-config": cmd_check_config,
                "style": cmd_style}
    if len(argv) < 2 or argv[1] not in commands:
        print("usage: fm-outward-check.py hook|seen|parse|check-config|style ... (see the header)", file=sys.stderr)
        return 2
    return commands[argv[1]](argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
