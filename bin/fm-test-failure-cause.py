#!/usr/bin/env python3
# fm-test-failure-cause.py - the TypeSafe (Jev) engine behind the advisory
# failure-cause labels bin/fm-test-run.sh prints after a run with failures.
#
# It reads the run's failing scripts, asks Jev in ONE request why each one
# failed - a bug in the code, a test that is out of date, or the environment -
# and prints one label per failure. Below the confidence floor the label is
# "unclear". The runner owns when this runs, the hard time bound and the marker
# it prints; everything from request construction to the floor is here.
#
# Usage:
#   fm-test-failure-cause.py --root <repo> --base <git-ref> <failures.tsv>
#   fm-test-failure-cause.py --dry-run --root <repo> --base <git-ref> <failures.tsv>
#
# <failures.tsv>  one record per line: <script> TAB <path to that script's output>
# stdout          one label per line: <script> TAB <cause> TAB <confidence>
#                 <cause> is code-bug, test-out-of-date, environment or unclear.
#                 A failure the size limit left out of the request instead
#                 prints <script> TAB not-labelled TAB over-size-limit.
#                 --dry-run prints the exact request body instead and makes no
#                 network call.
# stderr          diagnostics only, never the API key and never any content sent.
#
# Exit 0 when labels were reached, 2 on any failure - no key, timeout, HTTP
# error, malformed body. The runner prints nothing for a nonzero exit, so a Jev
# outage and a Jev that was never configured look exactly like a run before
# this existed. A single answer that cannot be read drops that one label only.
#
# ADVISORY ONLY. Nothing here can change a run's exit status: the runner has
# already decided it before this is called and never reads this exit code into
# it. A label is a hint for whoever reads the failure, never a verdict.
#
# What leaves the machine: each failing script's path and the tail of its
# output, and the tracked diff of the repository against the merge base with
# <base> (committed and uncommitted), with the captain-private paths excluded
# even if a fork tracks them. The runner only ever passes Firstmate's own
# repository root, so this is Firstmate's own public code. The whole request,
# state and every question, is trimmed to fit the model's 32k-token window:
# every failure's question and output tail share one budget, so the tails
# shrink as the failure count grows, and only a run with more failures than
# that budget can describe leaves its last ones unlabelled.
#
# The API key is read from the environment, else from $FM_HOME/.env (the runner
# passes FM_HOME, defaulting to its own root), exactly as the status second look
# (bin/fm-triage-second-look.py) reads it, and never appears in argv, stdout,
# stderr or the request body: a key that shows up in an output tail or the diff
# is replaced before anything is sent.
#
# Env:
#   TYPESAFE_API_KEY                   wins over the .env; never logged
#   FM_HOME                            home whose .env holds the key
#   FM_TEST_FAILURE_CAUSE_TIMEOUT      per-request bound in seconds (default 15)
#   FM_TEST_FAILURE_CAUSE_ENDPOINT     API endpoint
#   FM_TEST_FAILURE_CAUSE_RESPONSE     test seam: a recorded response body used
#                                      instead of the network, so the real request
#                                      build and the real floor still run
import json
import os
import pathlib
import re
import subprocess
import sys
import urllib.error
import urllib.request

ENDPOINT = os.environ.get("FM_TEST_FAILURE_CAUSE_ENDPOINT",
                          "https://api.typesafe.ai/v1/systemone")
# Pinned, never an alias: the 0.6 floor below was checked against this exact
# version on six probe cases and one real failing run
# (docs/verification/test-failure-cause.md), and the vendor's own docs warn that
# an alias moves underneath you.
MODEL = "jev-1.13.0"

# A label is shown only at this confidence; below it the runner says "unclear".
CONFIDENCE_FLOOR = 0.6

# The model's answer keys and the labels the runner prints for them.
CAUSES = {
    "code_bug": "code-bug",
    "test_out_of_date": "test-out-of-date",
    "environment": "environment",
}

# Size bounds. The whole request - the state and every question - must fit in
# 32k tokens; at a conservative three characters a token for code and test
# output, that is 80,000 characters of serialized request. Every failure's
# question and output tail share FAILURE_CHAR_BUDGET, each tail getting an equal
# share of what the questions leave, up to MAX_TAIL_CHARS; a run whose share
# would fall under MIN_TAIL_CHARS labels the first ones in run order and
# reports the rest as over the size limit. The diff gets whatever remains.
MAX_TAIL_CHARS = 4000
MIN_TAIL_CHARS = 400
FAILURE_CHAR_BUDGET = 40000
REQUEST_CHAR_BUDGET = 80000

# Captain-private paths (AGENTS.md section 1), excluded from the diff even when
# a fork tracks one of them.
PRIVATE_PATHS = (".env", "data", "state", "config", "projects", ".no-mistakes")

ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")


def _bounded(name, default, cast, minimum):
    try:
        value = cast(os.environ[name])
    except (KeyError, TypeError, ValueError):
        return default
    return value if value >= minimum else default


TIMEOUT_S = _bounded("FM_TEST_FAILURE_CAUSE_TIMEOUT", 15.0, float, 0.1)


def note(message):
    sys.stderr.write("fm-test-failure-cause: %s\n" % message)


def api_key(home):
    """The key from the environment, else the one line of the home's .env.

    The same reading as bin/fm-triage-second-look.py's api_key, kept local for
    the same reason that one is: each optional capability reads its own key
    without a shared dependency.
    """
    key = os.environ.get("TYPESAFE_API_KEY", "").strip()
    if key:
        return key
    if not home:
        return ""
    env_file = pathlib.Path(home) / ".env"
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


def output_tail(path):
    """The end of a failing script's output, where its failure is reported."""
    try:
        data = pathlib.Path(path).read_bytes()
    except OSError:
        return ""
    text = ANSI.sub("", data[-(MAX_TAIL_CHARS * 4):].decode("utf-8", errors="replace"))
    return text[-MAX_TAIL_CHARS:]


def read_failures(path):
    """(script, output tail) per failure, in run order."""
    failures = []
    try:
        lines = pathlib.Path(path).read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return failures
    for raw in lines:
        if "\t" not in raw:
            continue
        script, out = raw.split("\t", 1)
        script = script.strip()
        if script:
            failures.append((script, output_tail(out)))
    return failures


def fit_failures(failures):
    """(tag, script, tail) records sharing FAILURE_CHAR_BUDGET, and the scripts left over."""
    count = min(len(failures), FAILURE_CHAR_BUDGET // MIN_TAIL_CHARS)
    while count:
        share = (FAILURE_CHAR_BUDGET - len(json.dumps(questions_for(count)))) // count
        if share >= MIN_TAIL_CHARS:
            break
        count -= 1
    share = min(MAX_TAIL_CHARS, share) if count else 0
    records = [("f%d" % (i + 1), script, tail[-share:])
               for i, (script, tail) in enumerate(failures[:count])]
    return records, [script for script, _tail in failures[count:]]


def git(root, *args):
    result = subprocess.run(["git", "-C", root] + list(args), capture_output=True,
                            timeout=20, check=False)
    if result.returncode != 0:
        return None
    return result.stdout.decode("utf-8", errors="replace")


def branch_diff(root, base):
    """The tracked change on this branch: the merge base with <base> to the work tree."""
    since = (git(root, "merge-base", "HEAD", base) or "").strip() or "HEAD"
    excludes = [":(exclude,top)%s" % path for path in PRIVATE_PATHS]
    return git(root, "diff", "--no-color", "--no-ext-diff", since, "--", ".", *excludes) or ""


def fit_diff(diff, budget):
    """Trim the diff to <budget> characters, sharing the room fairly by file.

    A file smaller than its share is kept whole and its unused room goes to the
    rest, so one huge file cannot crowd out a small test change that decides
    whether a failure is a stale test.
    """
    if len(diff) <= budget:
        return diff
    if budget <= 0:
        return ""
    files = re.split(r"(?m)^(?=diff --git )", diff)
    files = [f for f in files if f]
    marker = "\n[trimmed]\n"
    allowed = {}
    remaining, left = budget, len(files)
    for index in sorted(range(len(files)), key=lambda i: len(files[i])):
        share = remaining // left
        allowed[index] = min(len(files[index]), share)
        remaining -= allowed[index]
        left -= 1
    parts = []
    for index, text in enumerate(files):
        keep = allowed[index]
        if keep >= len(text):
            parts.append(text)
        elif keep > len(marker):
            parts.append(text[:keep - len(marker)] + marker)
    return "".join(parts)


def build_state(records, diff):
    return {
        "failures": {tag: {"script": script, "output_tail": tail}
                     for tag, script, tail in records},
        "diff": diff,
    }


def question_for(tag):
    return {
        "type": "choice",
        "instructions": (
            "`failures.%s` is a test script that failed, with the end of its output; "
            "`diff` is the code change on this branch. Why did `failures.%s` fail?" % (tag, tag)),
        "criteria": {
            "code_bug": "The code under test is wrong: the change, or existing code, behaves "
                        "differently from what the test correctly expects.",
            "test_out_of_date": "The code now behaves as intended, and the test still expects "
                                "the old behaviour, output, name or path, so the test needs "
                                "updating.",
            "environment": "Neither the code nor the test is wrong: a missing or different tool "
                           "version, the network, permissions, disk, timing or this machine "
                           "made it fail.",
        },
    }


def questions_for(count):
    return {"f%d__cause" % i: question_for("f%d" % i) for i in range(1, count + 1)}


def build_request(records, diff):
    """One request for every failure, with the diff trimmed so the whole request fits the window."""
    questions = questions_for(len(records))

    def request(fitted):
        return {"model": MODEL, "state": build_state(records, fitted), "questions": questions}

    room = REQUEST_CHAR_BUDGET - len(json.dumps(request("")))
    fitted = fit_diff(diff, room)
    # JSON escaping grows code; shrink until the serialized request really fits.
    while fitted and len(json.dumps(request(fitted))) > REQUEST_CHAR_BUDGET:
        room = int(room * 0.9)
        fitted = fit_diff(diff, room)
    return request(fitted)


def redact(value, key):
    if isinstance(value, dict):
        return {k: redact(v, key) for k, v in value.items()}
    if isinstance(value, str) and key:
        return value.replace(key, "[redacted]")
    return value


def call(payload, key):
    request = urllib.request.Request(
        ENDPOINT, data=json.dumps(payload).encode("utf-8"),
        headers={"Authorization": "Bearer %s" % key, "Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=TIMEOUT_S) as response:
        return json.loads(response.read().decode("utf-8", errors="replace"))


def label(answers, tag):
    """(cause, confidence) for one failure, or None when its answer is unreadable."""
    try:
        answer = answers["%s__cause" % tag]
        choice = answer["choice"]
        confidence = answer["confidence"]
    except (KeyError, TypeError):
        return None
    if choice not in CAUSES or isinstance(confidence, bool):
        return None
    try:
        confidence = float(confidence)
    except (TypeError, ValueError):
        return None
    if not 0.0 <= confidence <= 1.0:
        return None
    cause = CAUSES[choice] if confidence >= CONFIDENCE_FLOOR else "unclear"
    return cause, confidence


def main():
    args = sys.argv[1:]
    dry_run = False
    root, base, failures_file = "", "origin/main", ""
    while args:
        arg = args.pop(0)
        if arg == "--dry-run":
            dry_run = True
        elif arg == "--root" and args:
            root = args.pop(0)
        elif arg == "--base" and args:
            base = args.pop(0)
        elif not failures_file and not arg.startswith("-"):
            failures_file = arg
        else:
            note("unknown argument: %s" % arg)
            return 2
    if not root or not failures_file:
        note("usage: fm-test-failure-cause.py [--dry-run] --root <repo> --base <ref> <failures.tsv>")
        return 2

    failures = read_failures(failures_file)
    if not failures:
        return 0
    records, over_limit = fit_failures(failures)

    canned = os.environ.get("FM_TEST_FAILURE_CAUSE_RESPONSE")
    key = "" if canned else api_key(os.environ.get("FM_HOME", root))
    if not (dry_run or canned or key):
        note("no TYPESAFE_API_KEY (inert)")
        return 2

    try:
        payload = build_request(records, branch_diff(root, base))
    except (OSError, subprocess.SubprocessError) as error:
        note("%s reading the diff (labelling nothing)" % type(error).__name__)
        return 2
    payload["state"] = redact(payload["state"], key)
    if dry_run:
        json.dump(payload, sys.stdout)
        sys.stdout.write("\n")
        return 0

    try:
        if canned:
            body = json.loads(pathlib.Path(canned).read_text(encoding="utf-8"))
        else:
            body = call(payload, key)
        answers = body["answers"]
    except urllib.error.HTTPError as error:
        note("HTTP %s (labelling nothing)" % error.code)
        return 2
    except Exception as error:  # noqa: BLE001 - every failure is the same silence
        note("%s (labelling nothing)" % type(error).__name__)
        return 2

    for tag, script, _tail in records:
        result = label(answers, tag)
        if result is None:
            note("unreadable answer for one failure; no label")
            continue
        sys.stdout.write("%s\t%s\t%.2f\n" % (script, result[0], result[1]))
    for script in over_limit:
        sys.stdout.write("%s\tnot-labelled\tover-size-limit\n" % script)
    return 0


if __name__ == "__main__":
    sys.exit(main())
