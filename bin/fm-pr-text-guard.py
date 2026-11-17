#!/usr/bin/env python3
# fm-pr-text-guard.py - the PR text check: before a Claude session publishes
# text to a public repository's pull requests, it refuses the command when the
# text holds a word from this home's private word list or a live key or token
# shape, and, when that repository is this Starship repository, a word that
# never appeared in it before or a customer data shape (bin/fm-leak-guard.sh
# --new-names).
#
# Usage:
#   fm-pr-text-guard.py hook --home DIR
#       The Claude Code PreToolUse hook on Bash that bin/fm-spawn.sh installs
#       for every spawned Claude worker (ship or scout), and that
#       bin/fm-pr-text-pretool-check.sh runs for a first mate or second mate
#       session from the tracked .claude/settings.json. Reads the hook payload
#       on stdin. On a refusal it prints the documented PreToolUse deny object
#       on stdout; on an allow it prints nothing. It always exits 0.
#
# docs/fork-configuration.md "Private leak words" owns the operator contract. The
# word list, its format and where it is found belong to bin/fm-leak-guard.sh,
# whose --text mode this hook runs with FM_HOME set to DIR from the command's
# working directory, so the words of the branch checked out there count as
# known to this repository; this file never reads the list itself.
#
# WHERE, NEVER WHAT. A refusal says how many listed words and token shapes the
# text holds and where, as the command or a file it names and the line, and
# never the words or tokens themselves, so a command that names the word list
# file does not put the list on the screen. New words, which the owner must
# approve by name, and customer data shapes are named.
#
# WHAT IS CHECKED. Only a Bash command that publishes text: gh or gh-axi
# `pr|issue create|new|edit|comment|review|close|reopen|merge`, a `gh api` call that sends
# a body (a -f, -F, --field, --raw-field or --input flag, or a -X/--method other
# than GET or HEAD), and `no-mistakes axi run|respond`, whose intent and
# answers reach the PR the pipeline writes. Each gh call is read on its own,
# between shell operators, so a flag given to another command (`grep -F`,
# `rm -f`) never makes a read-only `gh api` call publish; a gh call inside a
# word that holds a command of its own, such as a `bash -c` script, counts too,
# but the text a gh call publishes (a --body, -b, --title, -t, --comment or -c
# value, or a gh api field value) is read as a command only where it holds a
# `$(...)` or backtick substitution. The body of a quoted heredoc that a plain
# `cat` writes to a file is left out when finding gh calls and their
# repositories when the command only reads that file: as a --body-file, -F
# or --input value, an @file field value, a `$(cat FILE)` or `$(<FILE)` given
# as a text flag's or field's value, a `cat FILE` piped into a gh call reading
# `--body-file -` or `--input -`, or an argument of rm, test or [ outside a
# command substitution and not piped onward.
# Any other mention may run it, so the body is read as commands.
# A command whose words still cannot be parsed is judged on its whole text.
# Every other command passes untouched, whatever files it names, and so does
# every other tool. The text checked is the whole
# command, so inline titles, bodies, heredocs and variables set earlier in the
# same command all count, plus every existing file the command names anywhere:
# a body or input flag, a redirect, a `cat` or `$(cat ...)`, or a pipe into
# `--body-file -`. A listed word in a path or branch name of such a command is
# refused too, because a branch name is published. The repository a gh call
# names as its target (a -R/--repo value, a GH_REPO= assignment before gh, a
# gh api repos/<owner>/<repo> path, or a PR or issue URL given as the target)
# is where the text goes, not text it publishes, so its own name is blanked
# before the check; the same name elsewhere in the text still counts. Token shapes are checked
# only in the command and in the files it sends as content: a --body-file, -F
# or --input value, an @file value of -f, -F, --field or --raw-field, a
# `$(cat FILE)`, `$(<FILE)` or backtick `cat FILE` outside single quotes and
# quoted heredoc bodies, a `< FILE` redirect into, or the files
# of a `cat FILE |` stage piped into, a command reading --body-file - or
# --input -, or every file it names when its words cannot be parsed. A file it merely names,
# such as a test fixture with synthetic keys, is checked for every other hit. A `pr create` or `pr new` given
# --fill, -f, --fill-first or --fill-verbose before the next shell operator
# takes its text from commit messages this check cannot see, so on a public
# repository it is refused whenever the home has a list.
#
# PUBLIC ONLY. A private repository may hold these words, so a hit is refused
# unless every repository the command could reach is proven private. A new word
# or data shape is refused only on a public repository that one of the remotes
# of this script's own checkout points at, by the owner/repo gh reports for it,
# or on one whose visibility or name cannot be read; other public repositories
# may hold them. When the
# command calls gh or gh-axi as a word of its own, or names a publishing gh
# form that is not part of a no-mistakes command, those repositories are, for
# each gh call that publishes, the repositories it names as its target, or
# gh's own default for the working directory, which `gh repo view` reads
# there, when it names none, plus any other PR or issue URL among its words
# and every GH_REPO= value in the command. A command whose words cannot be
# parsed, or whose publishing gh form cannot be placed in a call, reaches
# every --repo/-R value, GH_REPO= value, PR or issue URL argument and
# repos/<owner>/<repo> path among its words plus gh's default. A gh form named only
# inside quoted text of a no-mistakes command, such as its intent, adds none.
# For `no-mistakes axi run|respond`, the repository is the owner/repo of the
# origin remote, whether its host is github.com or a dotless SSH alias; an
# origin on any other dotted host is not checked, and one that cannot be
# parsed is refused. A command whose words cannot be parsed while it names a
# gh form, often because of an unmatched quote in a heredoc or comment, counts
# as possibly public and is refused, placing the listed words, so the worker
# rewrites the text without them, or drops such comments and passes the text
# with --body-file <file> and an explicit --repo. Such a command that names a
# `pr create` or `pr new` form and a standalone --fill flag counts as --fill.
# A repository whose visibility cannot be
# read, and an origin that cannot be parsed, count as possibly public too: the
# refusal places the words and names that repository, and tells the worker to rewrite
# the text without them, or to append a blocked: status line and stop when the
# repository is private and still cannot be read. The visibility read happens
# only after a hit, so a clean command costs no network call.
#
# FAILURES. No list means only token shapes are checked: bin/fm-leak-guard.sh
# --text says nothing at all for a clean text then, and nothing is refused. An
# unreadable payload passes, because it cannot be known to publish anything.
# Once a command is known to publish, any failure inside the check refuses it.
# Every call the check makes shares one deadline, BUDGET seconds from the
# start (FM_PR_TEXT_GUARD_BUDGET when set), well inside the hook timeout
# bin/fm-spawn.sh sets, so the check refuses when time runs out instead of
# being cut off by the hook timeout, which would let the command run.
import json
import os
import pathlib
import re
import shlex
import subprocess
import sys
import tempfile
import time

GUARD = pathlib.Path(__file__).resolve().parent / "fm-leak-guard.sh"
FILE_CAP = 1 << 20
BUDGET = 35.0
DEADLINE = None

REPO_FLAG = r"(?:(?:(?:-R|--repo)(?:=|\s+)|-R)\S+\s+)?"
PR_CREATE = re.compile(r"(?:^|[\s/;&|(`])gh(?:-axi)?\s+" + REPO_FLAG + r"pr\s+" + REPO_FLAG + r"(?:create|new)\b")
PR_TEXT = re.compile(r"(?:^|[\s/;&|(`])gh(?:-axi)?\s+" + REPO_FLAG + r"(?:pr|issue)\s+" + REPO_FLAG
                     + r"(?:create|new|edit|comment|review|close|reopen|merge)\b")
API = re.compile(r"(?:^|[\s/;&|(`])gh(?:-axi)?\s+api\b")
API_SENDS = re.compile(r"(?:^|\s)(?:-f|-F|--field|--raw-field|--input)(?:=|\s|$)"
                       r"|(?:-X|--method)(?:=|\s*)(?:POST|PATCH|PUT)\b", re.I)
PIPELINE = re.compile(r"(?:^|[\s/;&|(`])no-mistakes\s+axi\s+(?:run|respond)\b")
SEPARATORS = "();<>|&\n"
ENDPOINT_REPO = re.compile(r"^/?repos/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(?:/|$)")
URL_REPO = re.compile(r"https?://([^/\s]+/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/(?:pull|issues)/\d+(?:[/#?]\S*)?")
PATH_CAP = 1024
FILL = re.compile(r"--fill(?:-first|-verbose)?(?:=(?!false$).*)?|-[dwe]*f[dwe]*")
STAGE_BREAK = "();|&\n"
CAT_SUB = re.compile(r"(?:\$\(|`)\s*(?:cat\s+|<\s*)([^()`|;&<>]*)")
HEREDOC = re.compile(r"<<(-?)\s*(?:'([^'\n]*)'|\"([^\"\n]*)\"|\\?([^\s;&|<>()'\"]+))")
PATHLIKE = re.compile(r"[^\s'\"`()<>|;&=]+")
REMOTE = re.compile(r"^(?:[a-z+]+://)?(?:[^@/]+@)?([^/:]+)[:/]+(.+?)(?:\.git)?/?$")
HIT = re.compile(r"^LEAK_HIT: ([a-z-]+): (.*)$")
NESTED_GH = re.compile(r"(?:^|[\s/;&|(`])gh(?:-axi)?\s")
DATA_FILE = r"(?:>>?[ \t]*(?P<f%d>[^\s;&|<>()`$'\"]+)[ \t]*)?"
DATA_HEREDOC = re.compile(r"(?:^|(?<=[\n;&|]))[ \t]*cat[ \t]+" + DATA_FILE % 1
                          + r"<<(?P<dash>-?)[ \t]*(?:'(?P<q1>[^'\n]+)'|\"(?P<q2>[^\"\n]+)\")[ \t]*" + DATA_FILE % 2
                          + r"(?=\n)")
TEXT_VERBS = ("create", "new", "edit", "comment", "review", "close", "reopen", "merge")
TEXT_FLAGS = {"pr": ("--body", "-b", "--title", "-t", "--comment", "-c"),
              "issue": ("--body", "-b", "--title", "-t", "--comment", "-c"),
              "api": ("-f", "-F", "--field", "--raw-field")}


class UnparsedCommand(Exception):
    """A gh command whose words cannot be parsed, so the repositories it could reach are unknown."""


class UnknownTarget(Exception):
    """A repository the command could reach that cannot be named, so it counts as possibly public."""


def left():
    """The seconds left before the check's deadline; TimeoutError once it has passed."""
    remaining = DEADLINE - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("the check ran out of its %g seconds" % BUDGET)
    return remaining


def deny(reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }}))


def opts(argv, names):
    found = {}
    i = 0
    while i < len(argv):
        name = argv[i][2:] if argv[i].startswith("--") else None
        if name not in names or i + 1 >= len(argv):
            raise SystemExit("usage: fm-pr-text-guard.py hook --home DIR (see the header)")
        found[name] = argv[i + 1]
        i += 2
    missing = [n for n in names if n not in found]
    if missing:
        raise SystemExit("fm-pr-text-guard.py: missing --%s" % missing[0])
    return found


def is_operator(word):
    return bool(word) and set(word) <= set(SEPARATORS)


def stages(words):
    """The words split at each run of shell operators."""
    out = [[]]
    for word in words:
        if is_operator(word):
            out.append([])
        else:
            out[-1].append(word)
    return out


def gh_word(word):
    return os.path.basename(word.strip("`")) in ("gh", "gh-axi")


def repo_flag(args, i):
    """(the repository a -R/--repo flag at args[i] names, words it takes) or (None, 0)."""
    word = args[i]
    if word in ("-R", "--repo"):
        return (args[i + 1], 2) if i + 1 < len(args) else (None, 1)
    if word.startswith("--repo="):
        return word.split("=", 1)[1], 1
    if word.startswith("-R") and not word.startswith("--") and len(word) > 2:
        return (word[3:] if word.startswith("-R=") else word[2:]), 1
    return None, 0


def api_sends(args):
    """Whether gh api args send a body: a field or input flag, or a method other than GET or HEAD."""
    def method_sends(method):
        return method.lstrip("=").upper() not in ("GET", "HEAD")
    for i, word in enumerate(args):
        flag, eq, value = word.partition("=")
        if flag in ("--input", "--field", "--raw-field"):
            return True
        if flag == "--method":
            if method_sends(value if eq else (args[i + 1] if i + 1 < len(args) else "")):
                return True
        elif word.startswith("-") and not word.startswith("--"):
            for k, letter in enumerate(word[1:]):
                if letter in "fF":
                    return True
                if letter == "X":
                    rest = word[k + 2:]
                    if method_sends(rest or (args[i + 1] if i + 1 < len(args) else "")):
                        return True
                    break
                if letter != "i":
                    break
    return False


def gh_call(args):
    """(publishes, explicit repositories, other repositories, whether it is a pr or issue form) for the words
    after one gh or gh-axi word."""
    explicit, i = [], 0
    while i < len(args):
        repo, used = repo_flag(args, i)
        if not used:
            break
        explicit += [repo] if repo else []
        i += used
    sub = args[i] if i < len(args) else ""
    rest = args[i + 1:]
    if sub == "api":
        explicit += [m.group(1) for m in (ENDPOINT_REPO.match(w) for w in rest if not any(c.isspace() for c in w)) if m]
        return api_sends(rest), explicit, [], False
    if sub not in ("pr", "issue"):
        return False, explicit, [], False
    j = 0
    while j < len(rest):
        repo, used = repo_flag(rest, j)
        if not used:
            break
        explicit += [repo] if repo else []
        j += used
    verb, rest = (rest[j], rest[j + 1:]) if j < len(rest) else ("", [])
    held = [f for f in TEXT_FLAGS[sub] + ("--subject",) if verb != "review" or f not in ("--comment", "-c")]
    for k, word in enumerate(rest):
        if URL_REPO.fullmatch(word) and (rest[k - 1] if k else "") not in held:
            explicit.append(URL_REPO.fullmatch(word).group(1))
            break
    explicit += [r for r in (repo_flag(rest, n)[0] for n in range(len(rest))) if r]
    others = [m.group(1) for m in (URL_REPO.fullmatch(w) for w in rest) if m]
    return verb in TEXT_VERBS, list(dict.fromkeys(explicit)), others, True


def text_values(args):
    """The indexes of the words among the words after one gh or gh-axi word that are text a flag publishes:
    a --body, -b, --title, -t, --comment or -c value of a pr or issue form, a -f, -F, --field or --raw-field
    value of gh api."""
    i = 0
    while i < len(args):
        used = repo_flag(args, i)[1]
        if not used:
            break
        i += used
    flags = TEXT_FLAGS.get(args[i] if i < len(args) else "", ())
    found = set()
    for k in range(i + 1, len(args)):
        word = args[k]
        if word in flags:
            found.add(k + 1)
        elif any(word.startswith(f + "=") if f.startswith("--") else word.startswith(f) for f in flags):
            found.add(k)
    return found


def commands(stage):
    """The stage's words without the text its gh call publishes, unless that text holds a $(...) or backtick
    substitution, which runs."""
    g = next((k for k, w in enumerate(stage) if gh_word(w)), None)
    text = set() if g is None else {g + 1 + k for k in text_values(stage[g + 1:])}
    return [w for n, w in enumerate(stage) if n not in text or "$(" in w or "`" in w]


def gh_calls(words, depth=0):
    """Each gh or gh-axi call among the words, as gh_call reads it,
    including one inside a word that holds a command of its own, such as a bash -c script, a $(...) in double
    quotes or a heredoc line; None when such a word cannot be parsed or nests too deep. A word of a no-mistakes
    stage is its intent or answer, never a command of its own."""
    if depth > 8:
        return None
    calls = []
    for stage in stages(words):
        if not any(os.path.basename(w) == "no-mistakes" for w in stage):
            for word in commands(stage):
                if any(c.isspace() for c in word) and NESTED_GH.search(word):
                    inner = tokens(word)
                    inner = None if inner is None else gh_calls(inner, depth + 1)
                    if inner is None:
                        return None
                    calls += inner
        for g, word in enumerate(stage):
            if gh_word(word):
                sends, explicit, others, text = gh_call(stage[g + 1:])
                explicit += [w.split("=", 1)[1] for w in stage[:g] if w.startswith("GH_REPO=")]
                calls.append((sends, explicit, others, text))
                break
    return calls


def word_spans(command, words):
    """The (start, end) of each of the command's words in it, or None when they cannot be lined up with words."""
    spans, i, n = [], 0, len(command)
    while i < n:
        if command[i] in " \t\r":
            i += 1
            continue
        start = i
        if command[i] in SEPARATORS:
            while i < n and command[i] in SEPARATORS:
                i += 1
        else:
            quote = None
            while i < n and (quote or (command[i] not in " \t\r" and command[i] not in SEPARATORS)):
                c = command[i]
                if quote == "'":
                    quote = None if c == "'" else quote
                elif c == "\\":
                    i += 1
                elif quote == '"':
                    quote = None if c == '"' else quote
                elif c in "'\"":
                    quote = c
                i += 1
        spans.append((start, min(i, n)))
    if len(spans) != len(words):
        return None
    for (start, end), word in zip(spans, words):
        raw = command[start:end]
        if raw != word and (is_operator(word) or tokens(raw) != [word]):
            return None
    return spans


def without_target_names(command, words):
    """The command with the repository each gh call names as its target blanked, keeping every line and column:
    a -R/--repo value, a GH_REPO= assignment before gh, a gh api repos/<owner>/<repo> path and a PR or issue URL
    given as the target. A repository's own name is where the text goes, not text it publishes."""
    spans = word_spans(command, words or [])
    if spans is None:
        return command
    out, index = list(command), 0
    for stage in stages(words):
        here = list(range(index, index + len(stage)))
        index += len(stage) + 1
        g = next((k for k, w in enumerate(stage) if gh_word(w)), None)
        blank = [k for k, w in enumerate(stage[:g]) if w.startswith("GH_REPO=")]
        if g is not None:
            explicit = gh_call(stage[g + 1:])[1]
            api = stage[g + 1:g + 2] == ["api"]
            for k in range(g + 1, len(stage)):
                repo, used = repo_flag(stage, k)
                if used and repo in explicit:
                    blank += range(k, k + used)
                elif api and ENDPOINT_REPO.match(stage[k]) and not any(c.isspace() for c in stage[k]):
                    blank.append(k)
                elif not api and URL_REPO.fullmatch(stage[k]) and URL_REPO.fullmatch(stage[k]).group(1) in explicit:
                    blank.append(k)
        for k in blank:
            start, end = spans[here[k]]
            out[start:end] = [c if c == "\n" else " " for c in command[start:end]]
    return "".join(out)


def only_read(name, text):
    """Whether every mention of the file name in the text only reads it: a --body-file, -F or --input value, an
    @file field value, a $(cat FILE) or $(<FILE) given as a text flag's or field's value, a cat FILE piped into
    a gh call reading --body-file - or --input -, or an argument of rm, test or [ outside a command substitution and not piped onward."""
    base = re.escape(os.path.basename(name))
    path = r"['\"]?(?:[^\s;&|<>()`'\"=@]*/)?" + base + r"['\"]?(?=[\s;&|)`'\"]|$)"
    start = r"(?:^|(?<=[\n;&|(]))[ \t]*"
    for form in (r"(?<=\s)(?:--body-file|--input|-F)(?:=|[ \t]+)" + path,
                 r"=@" + path,
                 r"(?:(?<=\s)(?:--body|--title|--subject|-b|-t)(?:=|[ \t]+)|(?<=\s)(?:-f|-F|--field|--raw-field)[ \t]+\w+=)"
                 r"['\"]?\$\((?:cat[ \t]+|<[ \t]*)" + path + r"[ \t]*\)",
                 start + r"cat[ \t]+" + path + r"[ \t]*\|[ \t]*(?:\S*/)?gh(?:-axi)?[ \t][^\n;&|`()]*?"
                 r"(?:--body-file|--input|-F)(?:=|[ \t]+)-(?=[\s;&|)]|$)",
                 r"(?:^|(?<=[\n;&|])|(?<![$<>]\()(?<=\())[ \t]*(?:rm|test|\[)(?:[ \t]+[^\s;&|<>()`$]+)*?[ \t]+" + path
                 + r"(?![^\n;|]*\|(?!\|))"):
        text = re.sub(form, " ", text)
    return not re.search(r"(?<![\w.-])" + base + r"(?![\w.-])", text)


def script(command):
    """The command as the shell runs it, for finding its gh calls: the body of a quoted heredoc that a plain cat
    writes to a file the command only reads (see only_read), which is data and never run, blanked,
    keeping every line."""
    out, pos = [], 0
    for m in DATA_HEREDOC.finditer(command):
        if m.start() < pos:
            continue
        dash, delim = m.group("dash"), m.group("q1") if m.group("q1") is not None else m.group("q2")
        name = m.group("f1") or m.group("f2")
        body, i = [], m.end()
        while i < len(command):
            end = command.find("\n", i + 1)
            end = len(command) if end < 0 else end
            line = command[i + 1:end]
            if (line.lstrip("\t") if dash else line) == delim:
                break
            body.append("\n" + " " * len(line))
            i = end
        if not name or not only_read(name, command[:m.start()] + command[i:]):
            continue
        out += [command[pos:m.end()]] + body
        pos = i
    out.append(command[pos:])
    return "".join(out)


def publishes(command):
    """Whether the command publishes text: a gh pr or issue form that writes, a gh api call that sends a body,
    or the pipeline; read per gh call when the command parses, else from the whole command."""
    if PIPELINE.search(command):
        return True
    command = script(command)
    calls = read_calls(tokens(command))
    if calls is None:
        return bool(PR_TEXT.search(command) or (API.search(command) and API_SENDS.search(command)))
    return any(call[0] for call in calls) or bool(PR_TEXT.search(command))


def read_calls(words):
    """gh_calls(words), or None when the words or a call among them cannot be read."""
    try:
        return None if words is None else gh_calls(words)
    except Exception:  # an unforeseen command shape falls back to the whole-command reading
        return None


def tokens(command):
    """The command's shell words, each run of shell operators or a newline its own word; None when unparsable."""
    lexer = shlex.shlex(command, posix=True, punctuation_chars=SEPARATORS)
    lexer.whitespace = " \t\r"
    lexer.whitespace_split = True
    lexer.commenters = ""
    try:
        return list(lexer)
    except ValueError:
        return None


def fills(words):
    """Whether a `pr create` or `pr new` among the words is given a --fill flag before the next shell operator."""
    for i, word in enumerate(words or []):
        j = i - 1
        if j >= 0 and (words[j].startswith("--repo=") or (words[j].startswith("-R") and len(words[j]) > 2)):
            j -= 1
        elif j >= 1 and words[j - 1] in ("-R", "--repo"):
            j -= 2
        if word in ("create", "new") and j >= 0 and words[j] == "pr":
            for arg in words[i + 1:]:
                if arg and set(arg) <= set(SEPARATORS):
                    break
                if FILL.fullmatch(arg):
                    return True
    return False


def named_files(command, words, cwd):
    """Every existing regular file the command names anywhere, as a word or inside one."""
    candidates = set(PATHLIKE.findall(command))
    candidates.update(w.split("=", 1)[-1] for w in words or [])
    found = []
    for candidate in sorted(c.lstrip("@") for c in candidates):
        if candidate in ("", "-") or len(candidate) > PATH_CAP:
            continue
        try:
            path = pathlib.Path(cwd, os.path.expanduser(candidate))
            if path.is_file() and path.resolve() not in found:
                found.append(path.resolve())
        except (OSError, ValueError):
            continue
    return found


def executed(command):
    """The command with the single-quoted strings and quoted heredoc bodies the shell never runs blanked."""
    out, i, stack, pending = [], 0, [], []
    while i < len(command):
        c = command[i]
        top = stack[-1] if stack else None
        if top == "'":
            if c == "'":
                stack.pop()
            out.append(c if c in "'\n" else " ")
        elif c == "\\":
            out.append(command[i:i + 2])
            i += 1
        elif top == '"':
            if c == '"':
                stack.pop()
            elif command.startswith("$(", i):
                stack.append("(")
                out.append("$")
                i += 1
                c = "("
            out.append(c)
        elif c in "'\"(":
            stack.append(c)
            out.append(c)
        elif c == ")" and top == "(":
            stack.pop()
            out.append(c)
        elif command.startswith("<<<", i):
            out.append("<<<")
            i += 2
        elif HEREDOC.match(command, i):
            m = HEREDOC.match(command, i)
            pending.append((m.group(1), m.group(2) if m.group(2) is not None else m.group(3), m.group(4)))
            out.append(m.group())
            i = m.end() - 1
        elif c == "\n" and pending:
            out.append(c)
            for dash, quoted, bare in pending:
                delim = bare if quoted is None else quoted
                while i + 1 < len(command):
                    end = command.find("\n", i + 1)
                    end = len(command) if end < 0 else end
                    line = command[i + 1:end]
                    out.append(line if quoted is None or (line.lstrip("\t") if dash else line) == delim
                               else " " * len(line))
                    out.append(command[end:end + 1])
                    i = end
                    if (line.lstrip("\t") if dash else line) == delim:
                        break
            pending = []
        else:
            out.append(c)
        i += 1
    return "".join(out)


def sent_files(command, words, cwd):
    """The resolved files a command sends as content: a --body-file, -F or --input value, an @file field value,
    a $(cat FILE), $(<FILE) or `cat FILE` the shell runs, and a file redirected or piped from cat into
    --body-file - or --input -."""
    candidates = []
    for m in CAT_SUB.finditer(executed(command)):
        try:
            candidates += [a for a in shlex.split(m.group(1)) if not a.startswith("-")]
        except ValueError:
            continue
    stages, breaks = [[]], []
    for word in words:
        if word and set(word) <= set(STAGE_BREAK):
            stages.append([])
            breaks.append(word)
        else:
            stages[-1].append(word)
    for k, stage in enumerate(stages):
        reads_stdin = False
        for i, word in enumerate(stage):
            flag, eq, value = word.partition("=")
            if not eq:
                flag, value = word, stage[i + 1] if i + 1 < len(stage) else ""
            if flag in ("-f", "-F", "--field", "--raw-field") and "=" in value:
                value = value.split("=", 1)[1]
                if value.startswith("@"):
                    candidates.append(value[1:])
            elif flag in ("--body-file", "-F", "--input"):
                if value == "-":
                    reads_stdin = True
                else:
                    candidates.append(value)
        if reads_stdin:
            candidates += [stage[i + 1] for i, word in enumerate(stage[:-1]) if word == "<"]
            if k and breaks[k - 1] == "|" and stages[k - 1][:1] == ["cat"]:
                candidates += [a for a in stages[k - 1][1:] if not a.startswith("-")]
    found = set()
    for candidate in candidates:
        try:
            path = pathlib.Path(cwd, os.path.expanduser(candidate))
            if path.is_file():
                found.add(path.resolve())
        except (OSError, ValueError):
            continue
    return found


def check_text(pieces, home, cwd):
    """Run bin/fm-leak-guard.sh --text --new-names in cwd on pieces, each (where, text): returns
    (listed places, token places, new words and data shapes), each place a (where, line), or None when
    the home has no list or approvals file and the text holds no token."""
    env = dict(os.environ, FM_HOME=home)
    with tempfile.TemporaryDirectory(prefix="fm-pr-text.") as tmp:
        shown = {}
        for i, (where, text) in enumerate(pieces):
            path = os.path.join(tmp, str(i))
            with open(path, "wb") as f:
                f.write(text.encode("utf-8", "replace"))
            shown[path] = where
        result = subprocess.run(["bash", str(GUARD), "--text", "--new-names"] + list(shown), capture_output=True,
                                env=env, cwd=cwd, timeout=left())
    if result.returncode == 0:
        return ([], [], []) if result.stdout.strip() or result.stderr.strip() else None
    places = {"private-word": [], "token": []}
    fresh = []
    for line in result.stderr.decode("utf-8", "replace").splitlines():
        m = HIT.match(line)
        if not m:
            continue
        kind, rest = m.groups()
        if kind in places:
            path, line_no, _ = rest.rsplit(":", 2)
            places[kind].append((shown.get(path, path), int(line_no)))
        else:
            fresh.append(rest.partition(": ")[2])
    if result.returncode != 1 or not (places["private-word"] or places["token"] or fresh):
        raise RuntimeError("the word check exited %d: %s" % (
            result.returncode, result.stderr.decode("utf-8", "replace").strip()[:300]))
    return places["private-word"], places["token"], list(dict.fromkeys(fresh))


def counted(n, noun):
    return "%d %s%s" % (n, noun, "" if n == 1 else "s")


def where_lines(places):
    """'the command, line 1; /x/body.md, lines 3 and 9' for (where, line) places."""
    lines = {}
    for where, n in places:
        lines.setdefault(where, set()).add(n)
    out = []
    for where, numbers in lines.items():
        numbers = [str(n) for n in sorted(numbers)]
        joined = numbers[0] if len(numbers) == 1 else ", ".join(numbers[:-1]) + " and " + numbers[-1]
        out.append("%s, line%s %s" % (where, "" if len(numbers) == 1 else "s", joined))
    return "; ".join(out)


def own_repos():
    """The owner/repo, lowercased, of every remote of this script's own checkout: this Starship repository."""
    out = subprocess.run(["git", "-C", str(GUARD.parent), "remote", "-v"], capture_output=True, text=True, timeout=left())
    repos = set()
    for line in out.stdout.splitlines():
        fields = line.split()
        m = REMOTE.match(fields[1]) if len(fields) > 1 else None
        if m:
            repos.add(m.group(2).lower())
    return repos


def named_repos(words):
    """Every repository the words name: --repo/-R and GH_REPO= values, PR or issue URLs, repos/<owner>/<repo> paths."""
    repos = []
    for i, word in enumerate(words):
        m = URL_REPO.fullmatch(word) or ENDPOINT_REPO.match(word)
        if word in ("-R", "--repo") and i + 1 < len(words):
            repos.append(words[i + 1])
        elif word.startswith(("--repo=", "GH_REPO=")):
            repos.append(word.split("=", 1)[1])
        elif word.startswith("-R") and len(word) > 2:
            repos.append(word[3:] if word.startswith("-R=") else word[2:])
        elif m:
            repos.append(m.group(1))
    return repos


def targets(command, cwd):
    """Each (repository for gh repo view or None for gh's default in cwd, name to show) the command could reach."""
    command = script(command)
    words = tokens(command)
    gh_form = PR_TEXT.search(command) or (API.search(command) and API_SENDS.search(command))
    pipeline = PIPELINE.search(command)
    if words is None and gh_form:
        raise UnparsedCommand("Starship could not read which repository this gh command publishes to")
    repos = []
    calls = read_calls(words)
    if calls is None:
        if any(gh_word(w) for w in words or []) or (gh_form and not pipeline):
            repos += named_repos(words) + [None]
    else:
        sending = [c for c in calls if c[0]]
        for _, explicit, others, _ in sending:
            repos += (explicit or [None]) + others
        if sending:
            repos += [w.split("=", 1)[1] for w in words if w.startswith("GH_REPO=")]
        unread = " ; ".join(" ".join(commands(stage)) for stage in stages(words))
        if PR_TEXT.search(unread) and not pipeline and not any(c[3] for c in sending):
            repos += named_repos(words) + [None]
    if pipeline:
        url = subprocess.run(["git", "-C", cwd, "remote", "get-url", "origin"],
                             capture_output=True, text=True, timeout=left()).stdout.strip()
        m = REMOTE.match(url)
        if not m:
            raise UnknownTarget("this checkout's origin remote %r is not a repository URL it can read" % url)
        host = m.group(1).lower()
        if "." not in host or host == "github.com" or host.endswith(".github.com"):
            repos.append(m.group(2))
    return [(r, r or "the repository this command reaches") for r in dict.fromkeys(repos)]


def visibility(repo, cwd):
    """('private' or 'public' or the reason it could not be read, the owner/repo gh names or None)."""
    args = (["gh", "repo", "view"] + ([repo] if repo else [])
            + ["--json", "isPrivate,nameWithOwner", "--jq", ".isPrivate, .nameWithOwner"])
    try:
        result = subprocess.run(args, capture_output=True, text=True, cwd=cwd, timeout=left())
    except (OSError, subprocess.TimeoutExpired) as e:
        return "gh could not run (%s)" % type(e).__name__, None
    answer = result.stdout.split()
    if result.returncode == 0 and answer and answer[0] in ("true", "false"):
        return ("private" if answer[0] == "true" else "public"), (answer[1] if len(answer) > 1 else None)
    return "gh repo view failed: %s" % (result.stderr.strip().splitlines() or ["no output"])[-1][:200], None


def check_hint(home, names=False):
    return "FM_HOME=%s %s --text%s <file>" % (shlex.quote(home), shlex.quote(str(GUARD)), " --new-names" if names else "")


def cmd_hook(argv):
    global BUDGET, DEADLINE
    start = time.monotonic()
    o = opts(argv, ("home",))
    try:
        payload = json.load(sys.stdin)
        if payload.get("tool_name") != "Bash":
            return 0
        tool_input = payload.get("tool_input")
        command = tool_input.get("command") if isinstance(tool_input, dict) else None
        if not isinstance(command, str) or not publishes(command):
            return 0
        cwd = payload.get("cwd") or os.getcwd()
    except Exception:  # an unreadable payload cannot be known to publish anything
        return 0
    try:
        BUDGET = float(os.environ.get("FM_PR_TEXT_GUARD_BUDGET") or BUDGET)
        DEADLINE = start + BUDGET
        words = tokens(command)
        files = named_files(command, words, cwd)
        sent = set(files) if words is None else sent_files(command, words, cwd)
        pieces, named = [("the command", without_target_names(command, words))], []
        for path in files:
            with open(path, "rb") as f:
                (pieces if path in sent else named).append((str(path), f.read(FILE_CAP).decode("utf-8", "replace")))
        found = check_text(pieces, o["home"], cwd)
        if found is not None and named:
            more = check_text(named, o["home"], cwd) or ([], [], [])
            found = (found[0] + more[0], found[1], list(dict.fromkeys(found[2] + more[2])))
        if words is None:
            fill = bool(PR_CREATE.search(command) and any(FILL.fullmatch(w) for w in command.split()))
        else:
            fill = fills(words)
        if found is None:
            return 0
        listed, keys, fresh = found
        hits = listed + keys
        if not (hits or fresh or fill):
            return 0
        if hits:
            parts = []
            if listed:
                parts.append("%s from this home's private word list (%s)"
                             % (counted(len(listed), "word"), where_lines(listed)))
            if keys:
                parts.append("%s (%s)" % (counted(len(keys), "live key or token shape"), where_lines(keys)))
            named = "contains " + " and ".join(parts)
            fix = "Rewrite those lines without %s" % ("it" if len(hits) == 1 else "them")
        elif fill:
            named = "comes from commit messages through --fill, which this check cannot read"
            fix = "Pass --title and --body-file instead of --fill"
        else:
            named = ("contains %s, which never appeared in this Starship repository or are customer data shapes"
                     % ", ".join('"%s"' % w for w in fresh))
            fix = ("Rewrite the text without %s, or append a needs-decision: status line naming each new word"
                   " so the owner can approve it once" % ("it" if len(fresh) == 1 else "them"))
        own = own_repos() if fresh and not (hits or fill) else set()
        unknown = None
        try:
            reached = targets(command, cwd)
        except UnparsedCommand as e:
            deny("Starship refused this command: the text it would publish %s, and %s, because the command"
                 " could not be read, often because of an unmatched quote in a heredoc or comment."
                 " %s, or drop such comments and pass the text with --body-file <file> and an explicit --repo,"
                 " and run it again." % (named, e, fix))
            return 0
        except UnknownTarget as e:
            reached, unknown = [], str(e)
        for repo, where in reached:
            seen, name = visibility(repo, cwd)
            if seen == "private":
                continue
            if seen == "public" and own and name and name.lower() not in own:
                continue
            if seen == "public":
                deny("Starship refused this command: the text it would publish to %s, a public repository, %s."
                     " Personal and work details never go into a public"
                     " repository's PR titles, descriptions, comments or pipeline intent."
                     " %s and run it again; check a draft first with: %s"
                     % (where, named, fix, check_hint(o["home"], bool(own))))
                return 0
            unknown = "%s: %s" % (where, seen)
            break
        if unknown:
            deny("Starship refused this command: the text it would publish %s,"
                 " and Starship could not confirm the repository is private (%s)."
                 " %s and run it again; if the repository is private and its visibility still cannot be read,"
                 " append a blocked: status line naming this and stop." % (named, unknown, fix))
    except Exception as e:  # a command known to publish never passes a check that failed
        deny("Starship refused this command because its PR text check failed (%s: %s)."
             " Do not route around it; append a blocked: status line naming this error and stop."
             % (type(e).__name__, str(e)[:300]))
    return 0


def main(argv):
    if len(argv) < 2 or argv[1] != "hook":
        print("usage: fm-pr-text-guard.py hook --home DIR (see the header)", file=sys.stderr)
        return 2
    return cmd_hook(argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
