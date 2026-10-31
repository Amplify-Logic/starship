#!/usr/bin/env python3
# fm-leak-shapes.py - the new-name check and the customer-data shape checks of
# the public-repo leak guard. bin/fm-leak-guard.sh is the only caller and owns
# when each check runs; docs/configuration.md "Private leak words" owns the
# operator contract.
#
# Usage:
#   fm-leak-shapes.py [--exempt GLOB]... [--names REPO REV [--approved FILE]]
#                     (--files PATH... | --diff BASE | --text LABEL PATH...)
#
# INPUT. --files reads whole files (each named relative to the current
# directory), --diff reads the lines `git diff BASE` adds in the current
# directory's checkout (committed and uncommitted changes to tracked files),
# and --text reads draft text, each file shown by its LABEL. A file matching an
# --exempt glob (fnmatch on its path) skips the shape checks; the new-name
# check still reads it.
#
# NEW NAMES (only with --names). A word is a maximal run of letters, digits and
# underscores. It is name-shaped when it holds letters only, starts with a
# capital letter and continues with a small one: a capitalised word such as a
# first name, or a CamelCase one such as a product name. Hyphens, apostrophes
# and other punctuation split words, so each part of a hyphenated name is its
# own word. Words in capitals, words with a digit or underscore, and words that
# start small, which is how code identifiers usually look, are never
# name-shaped. In a source code file (by extension, CODE_SUFFIXES below) a word
# with a further capital, such as a type name, is a code identifier too, while
# a plain capitalised word there is still checked. A name-shaped word is new when it occurs nowhere in the tracked
# files of REPO at REV, ignoring case and counting every maximal run of letters
# there as a word, and is not a line of the approvals FILE (one word per line,
# ignoring case, blank and # lines skipped). Each new word is reported once per
# file or label, at its first line.
#
# SHAPES (always). slack-id: a Slack user, channel or direct-message id (U, W,
# C, G or D, a digit, then 7 to 9 capitals and digits); slack-link: a link
# into a named Slack workspace (not app, api, example and other shared hosts); hubspot-link: a HubSpot
# record or portal link; phone: a phone number in international form (a plus,
# then 8 to 15 digits, optionally grouped); iban: an IBAN whose check digits
# are valid.
#
# OUTPUT. One `LEAK_HIT: <kind>: <where>: <value>` line on stdout per finding,
# where <where> is `<path>:<line>` for files and diffs and the LABEL for text,
# and <kind> is new-name or a shape. The approvals file is never printed.
# Exits 0 when clean, 1 when anything was reported, and 2 on a usage or git
# error.
import fnmatch
import os
import re
import subprocess
import sys

WORD = re.compile(r"\w+")
NAME = re.compile(r"[^\W\d_][^\W\d_]*")
LETTERS = re.compile(r"[^\W\d_]+")

SLACK_ID = re.compile(r"(?<![A-Za-z0-9_])[UWCGD][0-9][A-Z0-9]{7,9}(?![A-Za-z0-9_])")
SLACK_GENERIC = {"app", "api", "www", "hooks", "files", "status", "slack", "edgeapi", "my", "get", "example"}
SLACK_LINK = re.compile(r"(?<![\w.-])([a-z0-9][a-z0-9-]*)\.(?:enterprise\.)?slack\.com\b", re.I)
HUBSPOT = re.compile(r"\bapp(?:-[a-z0-9]+)?\.hubspot\.com/[\w-]+/\d+|\bhubspot\.com/\S*?[?&]portalId=\d+", re.I)
PHONE = re.compile(r"(?<![\w+])\+\d[\d .()-]{6,22}\d(?!\d)")
IBAN = re.compile(r"(?<![A-Za-z0-9])[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,3})?(?![A-Za-z0-9])")


CODE_SUFFIXES = (".swift", ".py", ".js", ".mjs", ".cjs", ".ts", ".tsx", ".jsx", ".go", ".rs",
                 ".java", ".kt", ".c", ".h", ".m", ".mm", ".cc", ".cpp", ".hpp", ".cs", ".rb")


def name_shaped(word, code=False):
    if len(word) < 2 or NAME.fullmatch(word) is None or not (word[0].isupper() and word[1].islower()):
        return False
    return not (code and any(c.isupper() for c in word[1:]))


def iban_valid(compact):
    if not 15 <= len(compact) <= 34:
        return False
    moved = compact[4:] + compact[:4]
    digits = "".join(str(int(c, 36)) for c in moved)
    return int(digits) % 97 == 1


def ibans(line):
    for m in IBAN.finditer(line):
        parts = m.group(0).split(" ")
        # A spaced IBAN may have swallowed a following word in capitals, so
        # try each group boundary from the longest down.
        for end in range(len(parts), 0, -1):
            compact = "".join(parts[:end])
            if iban_valid(compact):
                yield " ".join(parts[:end])
                break


def shapes(line):
    for m in SLACK_ID.finditer(line):
        yield "slack-id", m.group(0)
    for m in SLACK_LINK.finditer(line):
        if m.group(1).lower() not in SLACK_GENERIC:
            yield "slack-link", m.group(0)
    for m in HUBSPOT.finditer(line):
        yield "hubspot-link", m.group(0)
    for m in PHONE.finditer(line):
        digits = sum(c.isdigit() for c in m.group(0))
        if 8 <= digits <= 15:
            yield "phone", m.group(0)
    for value in ibans(line):
        yield "iban", value


def read_lines(path):
    with open(path, "rb") as f:
        data = f.read()
    if b"\0" in data[:8192]:
        return []
    return data.decode("utf-8", "replace").splitlines()


def diff_lines(base):
    """(path, line number, text) for every line `git diff base` adds."""
    out = subprocess.run(["git", "-c", "core.quotePath=false", "diff", "--no-color", "--no-ext-diff",
                          "-U0", "-M", base, "--"], capture_output=True)
    if out.returncode != 0:
        raise RuntimeError("git diff %s failed: %s" % (base, out.stderr.decode("utf-8", "replace").strip()))
    path, number, old, new = None, 0, 0, 0
    for raw in out.stdout.decode("utf-8", "replace").splitlines():
        if old > 0 or new > 0:  # inside a hunk, where every line is a removed or added one
            if raw.startswith("+"):
                yield path, number, raw[1:]
                number += 1
                new -= 1
            elif raw.startswith("-"):
                old -= 1
            continue
        hunk = re.match(r"@@ -\d+(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", raw)
        if hunk:
            old = int(hunk.group(1) or 1)
            number, new = int(hunk.group(2)), int(hunk.group(3) or 1)
        elif raw.startswith("+++ "):
            name = raw[4:].rstrip("\t")
            if len(name) > 1 and name.startswith('"') and name.endswith('"'):
                name = name[1:-1]
            path = name[2:] if name.startswith("b/") else name


def approved_words(path):
    if not path or not os.path.isfile(path):
        return set()
    words = set()
    for line in read_lines(path):
        line = line.strip()
        if line and not line.startswith("#"):
            words.add(line.lower())
    return words


def known_words(repo, rev, candidates):
    """The candidates that occur as a whole run of letters in repo's tracked files at rev."""
    if not candidates:
        return set()
    out = subprocess.run(["git", "-C", repo, "grep", "-I", "-h", "-e", "", rev, "--"], capture_output=True)
    if out.returncode not in (0, 1):
        raise RuntimeError("git grep at %s failed: %s" % (rev, out.stderr.decode("utf-8", "replace").strip()))
    return candidates & set(LETTERS.findall(out.stdout.decode("utf-8", "replace").lower()))


def main(argv):
    exempt, names, approved, mode, inputs = [], None, None, None, []
    i = 0
    try:
        while i < len(argv):
            arg = argv[i]
            if arg == "--exempt":
                exempt.append(argv[i + 1]); i += 2
            elif arg == "--names":
                names = (argv[i + 1], argv[i + 2]); i += 3
            elif arg == "--approved":
                approved = argv[i + 1]; i += 2
            elif arg in ("--files", "--diff", "--text") and mode is None:
                mode = arg[2:]; inputs = argv[i + 1:]; break
            else:
                raise IndexError
    except IndexError:
        mode = None
    if mode is None or (mode == "diff" and len(inputs) != 1) or (mode == "text" and (not inputs or len(inputs) % 2)):
        print("usage: fm-leak-shapes.py [--exempt GLOB]... [--names REPO REV [--approved FILE]]"
              " (--files PATH... | --diff BASE | --text LABEL PATH...)", file=sys.stderr)
        return 2

    # records: (where-prefix, line number or None, text, shapes apply)
    def is_exempt(path):
        return any(fnmatch.fnmatch(path, g) for g in exempt)

    records = []
    try:
        if mode == "files":
            for path in inputs:
                if not os.path.isfile(path):
                    continue
                skip = is_exempt(path)
                for n, line in enumerate(read_lines(path), 1):
                    records.append((path, n, line, not skip))
        elif mode == "diff":
            for path, n, line in diff_lines(inputs[0]):
                records.append((path, n, line, not is_exempt(path)))
        else:
            for label, path in zip(inputs[::2], inputs[1::2]):
                for line in read_lines(path):
                    records.append((label, None, line, True))
    except (OSError, RuntimeError) as e:
        print("fm-leak-shapes.py: %s" % e, file=sys.stderr)
        return 2

    hits = []
    for where, n, line, check in records:
        if check:
            for kind, value in shapes(line):
                hits.append((kind, where if n is None else "%s:%d" % (where, n), value))

    if names:
        allowed = approved_words(approved)
        first = {}
        for where, n, line, _ in records:
            code = n is not None and where.lower().endswith(CODE_SUFFIXES)
            for word in WORD.findall(line):
                if name_shaped(word, code) and word.lower() not in allowed:
                    first.setdefault((where, word.lower()), (n, word))
        try:
            known = known_words(names[0], names[1], {low for _, low in first})
        except RuntimeError as e:
            print("fm-leak-shapes.py: %s" % e, file=sys.stderr)
            return 2
        for (where, low), (n, word) in first.items():
            if low not in known:
                hits.append(("new-name", where if n is None else "%s:%d" % (where, n), word))

    for kind, where, value in hits:
        print("LEAK_HIT: %s: %s: %s" % (kind, where, value))
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
