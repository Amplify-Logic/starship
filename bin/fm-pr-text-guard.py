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
# docs/configuration.md "Private leak words" owns the operator contract. The
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
# fields or an input file, and `no-mistakes axi run|respond`, whose intent and
# answers reach the PR the pipeline writes. Every other command passes
# untouched, and so does every other tool. The text checked is the whole
# command, so inline titles, bodies, heredocs and variables set earlier in the
# same command all count, plus every existing file the command names anywhere:
# a body or input flag, a redirect, a `cat` or `$(cat ...)`, or a pipe into
# `--body-file -`. A listed word in a path or branch name of such a command is
# refused too, because a branch name is published. A `pr create` or `pr new` given
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
# form that is not part of a no-mistakes command, those repositories are every
# --repo/-R value, GH_REPO= value, PR or issue URL argument and
# repos/<owner>/<repo> path among its words, plus gh's own default for the
# working directory, which `gh repo view` reads there. A gh form named only
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
PATHLIKE = re.compile(r"[^\s'\"`()<>|;&=]+")
REMOTE = re.compile(r"^(?:[a-z+]+://)?(?:[^@/]+@)?([^/:]+)[:/]+(.+?)(?:\.git)?/?$")
HIT = re.compile(r"^LEAK_HIT: ([a-z-]+): (.*)$")


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


def publishes(command):
    if PR_TEXT.search(command) or PIPELINE.search(command):
        return True
    return bool(API.search(command) and API_SENDS.search(command))


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


def targets(command, words, cwd):
    """Each (repository for gh repo view or None for gh's default in cwd, name to show) the command could reach."""
    gh_form = PR_TEXT.search(command) or (API.search(command) and API_SENDS.search(command))
    pipeline = PIPELINE.search(command)
    if words is None and gh_form:
        raise UnparsedCommand("Starship could not read which repository this gh command publishes to")
    repos = []
    if any(os.path.basename(w) in ("gh", "gh-axi") for w in words or []) or (gh_form and not pipeline):
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
        pieces = [("the command", command)]
        for path in named_files(command, words, cwd):
            with open(path, "rb") as f:
                pieces.append((str(path), f.read(FILE_CAP).decode("utf-8", "replace")))
        found = check_text(pieces, o["home"], cwd)
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
            reached = targets(command, words, cwd)
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
