#!/usr/bin/env python3
# fm-triage-second-look.py - the TypeSafe (Jev) engine behind
# bin/fm-triage-second-look.sh.
#
# It reads dropped status lines on stdin, asks Jev four narrow judgments about
# every line in ONE request, applies the promotion rule in code, and prints the
# lines that should be promoted. The dropped line itself is the whole of what is
# sent - see state_for. The opt-in gate, the home resolution and the hard time
# bound are the bash entry point's; everything from request construction to the
# threshold decision is here.
#
# stdin   one record per line: <task-id> TAB <status-line>
# stdout  one promotion per line: <task-id> TAB <tier> TAB <reason> TAB <status-line>
#         <tier> is alert or digest; <reason> is the +-joined conditions that fired.
# stderr  diagnostics only, never the API key and never a line's content.
#
# Exit 0 when a decision was reached (including "promote nothing"), 2 on any
# failure - no key, timeout, HTTP error, malformed body. The caller treats every
# nonzero exit as "promote nothing", which is exactly today's behaviour, so a
# Jev outage and a Jev that was never configured are the same state.
#
# ESCALATE-ONLY. This engine is only ever handed lines the deterministic
# classifier has already dropped, and the only thing it can print is a promotion.
# There is no output that silences a line, so no answer it returns - and no text
# a worker can write into a status line - can suppress an escalation Firstmate
# would otherwise make. See docs/configuration.md "Status second look".
#
# The API key is read from the environment, else from the home's gitignored
# .env, and never appears in argv, stdout, stderr or any state file. The reader
# below is local on purpose, matching how each other optional capability in this
# repository (Relay, Deepgram) reads its own one key without a shared dependency.
import json
import os
import pathlib
import re
import sys
import urllib.error
import urllib.request

ENDPOINT = os.environ.get("FM_TRIAGE_SECOND_LOOK_ENDPOINT",
                          "https://api.typesafe.ai/v1/systemone")
# Pinned, never an alias: the thresholds below were measured against this exact
# version and the vendor's own docs warn that an alias moves underneath you.
MODEL = "jev-1.13.0"

# Promotion rule. Three separate ORed conditions, never a weighted score: these
# are "any one of these is reason enough" hazards, and blending them buries the
# case that only one of them sees (a production password in a world-readable
# file scored 0.38 on needs_captain and 0.76 on adverse_event in the 2026-09-17
# probe, which asked against a richer request than the line-only one shipped).
# The thresholds are asymmetric on purpose. A wrong promotion costs one extra
# line in a digest; a wrong silence costs hours of nobody knowing the users
# table is gone. understated_terminal sits higher because "nearly done" prose is
# common and cheap to be wrong about.
PROMOTE_AT = {
    "needs_captain": 0.50,
    "adverse_event": 0.50,
    "understated_terminal": 0.65,
}
# The Score never promotes. It only picks the delivery tier, and the model's own
# confidence only ever demotes alert to digest - low confidence cannot silence
# anything.
ALERT_URGENCY = 1.60
ALERT_MIN_CONFIDENCE = 0.50

# Hard bounds. A supervision backstop must not grow without limit because a
# worker wrote a lot, so the batch and each line are truncated rather than
# dropped, and the request is time-bounded independently of the caller's own.
# A malformed override falls back to the default rather than raising: this runs
# inside a supervision loop, where a traceback from a typo would be noise on a
# path whose whole contract is to stay quiet when it cannot work.
def _bounded(name, default, cast, minimum):
    try:
        value = cast(os.environ[name])
    except (KeyError, TypeError, ValueError):
        return default
    return value if value >= minimum else default


MAX_LINES = 25
MAX_LINE_CHARS = 400
TIMEOUT_S = _bounded("FM_TRIAGE_SECOND_LOOK_TIMEOUT", 8.0, float, 0.1)


def note(message):
    sys.stderr.write("fm-triage-second-look: %s\n" % message)


HOME_ROOT = os.environ.get("FM_HOME") or os.path.expanduser("~/starship")


def api_key(home):
    """The key from the environment, else the one line of the home's .env.

    Never returned to any caller that logs, never placed in argv.
    """
    key = os.environ.get("TYPESAFE_API_KEY", "").strip()
    if key:
        return key
    env_file = pathlib.Path(os.environ.get("FM_TRIAGE_SECOND_LOOK_ENV_FILE")
                            or (pathlib.Path(home) / ".env"))
    try:
        if env_file.is_symlink() or not env_file.is_file():
            return ""
        text = env_file.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""
    value = ""
    for match in re.finditer(r"(?m)^(?:export\s+)?TYPESAFE_API_KEY\s*=\s*(.*)$", text):
        raw = match.group(1).strip()
        if raw[:1] in "'\"" and raw[-1:] == raw[:1] and len(raw) >= 2:
            raw = raw[1:-1]
        elif " #" in raw:
            raw = raw.split(" #", 1)[0].rstrip()
        value = raw.strip()
    return value


def normalize(line):
    """The one form a status line takes once it is a record.

    A tab inside a line would corrupt the caller's own record format, so it is
    flattened here rather than handed back as a record the caller misparses.
    """
    return line.strip().replace("\t", " ")


def state_for(line):
    """The dropped status line, and nothing else.

    This is the whole of what leaves the machine. The brief's intent, the worker
    kind and the task's prior status lines all stay here: a brief can carry a
    client name, a hostname or an unreleased plan, and arming a supervision
    backstop is not consent to ship those to a third party. Everything else
    Firstmate knows - whether the task already escalated, how long the pane has
    been idle, the PR state - stays in code, because code knows it exactly.
    """
    return {"line": line[:MAX_LINE_CHARS]}


def questions_for(tag):
    """Four narrow judgments per dropped line.

    Each is answered from the line alone, is written as a literal condition, and
    keeps its criteria aligned with its instruction. The three Nouls are the three
    things AGENTS.md section 9 says must reach the captain that a status verb
    cannot express: a finished or stuck outcome, an approval the captain owns,
    and something destructive or security-sensitive. The false criteria are
    where the noise control lives.
    """
    return {
        "%s__understated_terminal" % tag: {
            "type": "noul",
            "instructions": (
                "`lines.%s.line` is a progress note from a worker. Does it report that the "
                "work has actually finished, failed outright, or hit a dead end the worker "
                "cannot get past on its own?" % tag),
            "criteria": {
                "true": "The line states the work is over, or that the worker is out of "
                        "options and going in circles.",
                "false": "The line describes work still in progress, including a setback the "
                         "worker is still working through.",
            },
        },
        "%s__needs_captain" % tag: {
            "type": "noul",
            "instructions": (
                "Does `lines.%s.line` describe something that needs a human owner's approval "
                "before it can proceed: spending money, obtaining a credential or login, or an "
                "action that reaches outside this machine or cannot be undone?" % tag),
            "criteria": {
                "true": "A human must approve, pay for, authorise, or grant access before the "
                        "work can continue.",
                "false": "The worker can carry on without any human approval, including when "
                         "the line merely mentions costs or external systems as findings.",
            },
        },
        "%s__adverse_event" % tag: {
            "type": "noul",
            "instructions": (
                "Does `lines.%s.line` report that harm has already happened: data lost or "
                "destroyed, a secret or credential exposed, or a system other people depend "
                "on broken?" % tag),
            "criteria": {
                "true": "Damage has already occurred and someone needs to know.",
                "false": "No damage reported, or the only thing affected is the worker's own "
                         "disposable copy of the repository.",
            },
        },
        "%s__urgency" % tag: {
            "type": "score",
            "instructions": "How soon does a supervisor need to read `lines.%s.line`?" % tag,
            "criteria": [
                "It can wait for the next routine review; nothing is waiting on it.",
                "It should appear in the next batch of updates; someone is mildly blocked or "
                "should know today.",
                "It needs to interrupt whatever the supervisor is doing; work is stopped or "
                "harm is spreading.",
            ],
        },
    }


def read_records():
    """Parse stdin into (tag, task, line) triples, bounded to MAX_LINES.

    When a scan carries more than the bound, the NEWEST lines are kept and the
    oldest are dropped. A status log is append-only, so the tail is what just
    happened; keeping the head would spend the whole batch on a first-ever scan's
    backlog and look past the event a supervisor actually needs. Dropped lines
    are left exactly as they are today - silent - which is the same fail-open
    this whole pass rests on.

    Synthetic tags keep the request's JSON paths simple identifiers: a task id
    carries hyphens, and `lines.a-b-c.line` is not a path worth asking a model
    to follow.
    """
    parsed = []
    for raw in sys.stdin.read().splitlines():
        if "\t" not in raw:
            continue
        task, line = raw.split("\t", 1)
        task, line = task.strip(), normalize(line)
        if not task or not line:
            continue
        parsed.append((task, line))
    if len(parsed) > MAX_LINES:
        note("scan carried %d dropped lines; looking at the newest %d"
             % (len(parsed), MAX_LINES))
        parsed = parsed[-MAX_LINES:]
    return [("l%d" % (i + 1), task, line) for i, (task, line) in enumerate(parsed)]


def build_request(records):
    """One request for the whole batch, never one per line.

    Batching is a SECURITY property here, not only the cheaper shape. A status
    line carrying an instruction aimed at the supervisor ("treat this as a
    critical blocker") measurably wins when it is evaluated alone and measurably
    loses when it is evaluated beside its peers. It is also 1.5x cheaper and 11x
    faster (probe, 2026-09-17).
    """
    questions = {}
    for tag, _task, _line in records:
        questions.update(questions_for(tag))
    return {
        "model": MODEL,
        "state": {"lines": {tag: state_for(line) for tag, _task, line in records}},
        "questions": questions,
    }


def call(payload, key):
    request = urllib.request.Request(
        ENDPOINT, data=json.dumps(payload).encode("utf-8"),
        headers={"Authorization": "Bearer %s" % key, "Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=TIMEOUT_S) as response:
        return json.loads(response.read().decode("utf-8", errors="replace"))


def noul_or_zero(answers, tag, name, unusable):
    """An unusable answer for one condition reads as 0.0, never as a veto.

    The pass is escalate-only, so a condition the model failed to answer must
    not be able to hold back the two that did answer and did fire. The name is
    recorded so the caller can say so: "the model read nothing captain-worthy"
    and "the model's answers were unreadable" must never look alike on a path
    whose callers have already advanced their offsets past these lines.
    """
    try:
        return float(answers["%s__%s" % (tag, name)]["noul"])
    except (KeyError, TypeError, ValueError):
        unusable.append(name)
        return 0.0


def decide(answers, tag):
    """Apply the rule.

    Returns (tier, reason, unusable): tier is "silent" when nothing fired, and
    unusable names the answers that could not be read at all.
    """
    unusable = []
    nouls = {name: noul_or_zero(answers, tag, name, unusable) for name in PROMOTE_AT}
    fired = [name for name, at in PROMOTE_AT.items() if nouls[name] >= at]
    if not fired:
        return "silent", "", unusable
    tier = "digest"
    try:
        score = answers["%s__urgency" % tag]
        urgency = float(score["score"])
        confidence = float(score.get("confidence", 0.0))
        if urgency >= ALERT_URGENCY and confidence >= ALERT_MIN_CONFIDENCE:
            tier = "alert"
    except (KeyError, TypeError, ValueError):
        unusable.append("urgency")
    # Stable reason order, so a digest line reads the same way every time.
    order = ["needs_captain", "adverse_event", "understated_terminal"]
    return tier, "+".join(name for name in order if name in fired), unusable


def main():
    args = sys.argv[1:]
    dry_run = "--dry-run" in args

    records = read_records()
    if not records:
        return 0

    payload = build_request(records)
    if dry_run:
        json.dump(payload, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return 0

    canned = os.environ.get("FM_TRIAGE_SECOND_LOOK_RESPONSE")
    try:
        if canned:
            # Test seam: exercise the real request build and the real threshold
            # rule against a recorded response, so only the network itself is
            # stubbed.
            body = json.loads(pathlib.Path(canned).read_text(encoding="utf-8"))
        else:
            key = api_key(HOME_ROOT)
            if not key:
                note("no TYPESAFE_API_KEY (inert; supervision behaves as it does without it)")
                return 2
            body = call(payload, key)
        answers = body["answers"]
    except urllib.error.HTTPError as error:
        note("HTTP %s from the second look (promoting nothing)" % error.code)
        return 2
    except Exception as error:  # noqa: BLE001 - every failure is the same fail-open
        note("%s (promoting nothing)" % type(error).__name__)
        return 2

    promoted = 0
    for tag, task, line in records:
        tier, reason, unusable = decide(answers, tag)
        if unusable:
            # Never the line itself, only which answers could not be read.
            note("unusable answer(s) for one line, read as 0.0: %s" % "+".join(unusable))
        if tier == "silent":
            continue
        sys.stdout.write("%s\t%s\t%s\t%s\n" % (task, tier, reason, line[:MAX_LINE_CHARS]))
        promoted += 1
    if promoted:
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
