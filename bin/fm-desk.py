#!/usr/bin/env python3
"""fm-desk.py - the `starship` desk command: open the owner's whole desk in Herdr.

One command starts Herdr's default session (or attaches to it when it is
already running), fills in
whatever the owner's desk layout names that is missing, and opens the Terminal
windows that show the session. Run it again and it changes nothing.
docs/desk.md owns what the desk is and why; docs/configuration.md owns the
config/desk-layout format; this header owns the commands.

Usage:
  fm-desk.py [open]             open the desk: start or attach, fill in what is
                                missing, open the missing Terminal views
  fm-desk.py layout             print the running session as a desk layout file,
                                a starting config/desk-layout
  fm-desk.py install-command    put `starship` on PATH: ~/.local/bin/starship
                                becomes a link to this script, unless another
                                `starship` is there or already on PATH

The layout lives in the home's config/desk-layout. Without one, `open` stops
and says how to write it.

What `open` does, in this order, re-reading Herdr after every step:
  1. With `sidebar` set, makes Herdr's config start the sidebar that way, before
     any view opens (Herdr reads it when a client starts).
  2. When the session is not running, starts its server in the background;
     Herdr restores the saved layout itself. Starting the server before any
     view attaches matters: a client attaching to an empty session makes a
     workspace of its own.
  3. Creates the workspace when no workspace has its label; with `main` set,
     names the new workspace's first tab after it.
  4. In the main tab (the tab labelled `main`, else the workspace's first
     tab): starts the first mate in a pane that is only
     an idle shell, shows the bridge strip and the Factory pane when missing,
     and restarts either inside its own pane when that pane is only an idle
     shell (Herdr brings plugin panes back as plain shells after a restart).
  5. Opens every missing tab; a factory tab opens through bin/fm-factory.py
     open-tab. An existing factory tab whose page pane is only an idle shell
     gets its page started again, its other panes that are only idle shells
     are closed (they are the worker copies Herdr brought back as plain
     shells), and bin/fm-factory.py workers splits a fresh live copy of each
     running worker beside the page. A factory tab is the tab open-tab
     recorded for that factory in this session, else the tab with its label.
  6. Opens Terminal windows until as many Herdr clients show the session as
     the layout names views, each with its Terminal profile and font size.
It never restarts or moves a pane, tab or workspace, never closes one except
the leftover idle shells of a factory tab whose page it restarts, never renames
one it did not just create, never starts anything in a pane that runs
something other than a shell, and never touches any other workspace. A pane
counts as an idle shell only when the bare shell itself is in its foreground
(a shell running a command is not) and Herdr records no agent in it. The desk
types into, or closes, an idle shell only when its screen also shows the
shell's prompt as the last line with nothing typed after it. It gives such a
pane still starting up FM_DESK_WAIT to reach its prompt, and opens no view
meanwhile; one that does not, or one holding typed-ahead input, is left alone
with a note. A pane with no agent that runs a command but shows nothing on
screen yet, as a shell running a command from its startup file does, counts as
still starting up too.

Environment:
  FM_HOME                 the home whose config/desk-layout is read (default:
                          this code root)
  HERDR_BIN_PATH          the Herdr binary (default: herdr on PATH)
  HERDR_CONFIG_PATH       Herdr's config file (default ~/.config/herdr/config.toml)
Test seams:
  FM_DESK_BIN             directory holding fm-bridge-strip.sh, fm-factory-pane.sh
                          and fm-factory.py (default: this script's directory)
  FM_DESK_PS              process lister printing `pid tty command` lines
                          (default: ps -axo pid=,tty=,command=)
  FM_DESK_OSASCRIPT       AppleScript runner (default: osascript)
  FM_DESK_COMMAND_DIR     where install-command links `starship` (default
                          ~/.local/bin)
  FM_DESK_WAIT            seconds to wait for a started server, a new view, or
                          the prompt of a starting shell the desk would type
                          into or close (default 30)
Exit: 0 on success; 1 when a step fails, with the reason on stderr; 2 on a usage
error or an unreadable layout.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
from typing import Any, Dict, List, Optional, Tuple

ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
SCRIPT = os.path.realpath(__file__)
ME = "starship"
SHELLS = {"zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "csh", "nu"}
SESSION = "default"
SINGLE_KEYS = ("workspace", "main", "sidebar", "firstmate")


class Failure(Exception):
    pass


class Refused(Exception):
    pass


def say(text: str) -> None:
    print(text, flush=True)


def home_dir() -> str:
    return os.environ.get("FM_HOME") or ROOT


def bin_dir() -> str:
    return os.environ.get("FM_DESK_BIN") or os.path.join(ROOT, "bin")


def wait_limit() -> float:
    raw = os.environ.get("FM_DESK_WAIT", "")
    try:
        return float(raw) if raw else 30.0
    except ValueError:
        return 30.0


# --------------------------------------------------------------------------
# The layout file
# --------------------------------------------------------------------------

def layout_path(home: str) -> str:
    return os.path.join(home, "config", "desk-layout")


def parse_layout(text: str, where: str = "config/desk-layout") -> Dict[str, Any]:
    """Read a desk layout. docs/configuration.md "Desk layout" owns the format."""
    layout: Dict[str, Any] = {
        "workspace": "starship", "main": "", "sidebar": "", "firstmate": "", "tabs": [], "views": [],
    }
    seen = set()
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise Refused("%s line %d: expected `key = value`" % (where, number))
        key, value = (part.strip() for part in line.split("=", 1))
        if key in SINGLE_KEYS:
            if key in seen:
                raise Refused("%s line %d: %s is set twice" % (where, number, key))
            seen.add(key)
        if key == "workspace":
            if not value:
                raise Refused("%s line %d: workspace needs a label" % (where, number))
            layout["workspace"] = value
        elif key == "main":
            if not value:
                raise Refused("%s line %d: main needs a tab label" % (where, number))
            layout["main"] = value
        elif key == "sidebar":
            if value not in ("collapsed", "open"):
                raise Refused("%s line %d: sidebar is collapsed or open" % (where, number))
            layout["sidebar"] = value
        elif key == "firstmate":
            layout["firstmate"] = value
        elif key == "tab":
            label, _, kind = (part.strip() for part in value.partition("|"))
            if not label:
                raise Refused("%s line %d: a tab needs a label" % (where, number))
            factory = ""
            if kind:
                words = kind.split()
                if len(words) != 2 or words[0] != "factory":
                    raise Refused("%s line %d: a tab is `<label>` or `<label> | factory <id>`" % (where, number))
                factory = words[1]
            if any(tab["label"] == label for tab in layout["tabs"]):
                raise Refused("%s line %d: two tabs are labelled %s" % (where, number, label))
            layout["tabs"].append({"label": label, "factory": factory})
        elif key == "view":
            profile, _, size = (part.strip() for part in value.partition("|"))
            if size and not re.match(r"^[0-9]{1,3}$", size):
                raise Refused("%s line %d: a view's font size is a whole number" % (where, number))
            layout["views"].append({"profile": profile, "size": size})
        else:
            raise Refused("%s line %d: unknown setting %s" % (where, number, key))
    return layout


def load_layout(home: str) -> Dict[str, Any]:
    path = layout_path(home)
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except FileNotFoundError:
        raise Refused("there is no desk layout at %s yet; start from `%s layout > %s` "
                         "and see docs/desk.md" % (path, ME, path))
    return parse_layout(text)


# --------------------------------------------------------------------------
# Herdr
# --------------------------------------------------------------------------

def herdr_bin() -> str:
    configured = os.environ.get("HERDR_BIN_PATH", "")
    if configured:
        return configured
    found = shutil.which("herdr")
    if not found:
        raise Failure("Herdr is not installed (no herdr on PATH); bin/fm-herdr-setup.sh installs it")
    return found


def base_env() -> Dict[str, str]:
    """This process's environment without the pane identity a Herdr pane hands down.

    The desk names the default session explicitly, so a run from inside some
    other pane never reaches that pane's session by accident.
    """
    env = dict(os.environ)
    for name in ("HERDR_SOCKET_PATH", "HERDR_PANE_ID", "HERDR_TAB_ID", "HERDR_WORKSPACE_ID", "HERDR_SESSION"):
        env.pop(name, None)
    return env


class Herdr:
    def __init__(self) -> None:
        self.session = SESSION
        self.binary = herdr_bin()

    def call(self, *args: str, check: bool = True) -> Any:
        argv = [self.binary, "--session", self.session] + list(args)
        try:
            out = subprocess.run(argv, capture_output=True, text=True, timeout=30,
                                 env=base_env(), stdin=subprocess.DEVNULL)
        except (OSError, subprocess.SubprocessError) as error:
            raise Failure("Herdr could not be run: %s" % error)
        if out.returncode != 0:
            if not check:
                return None
            why = (out.stderr.strip() or out.stdout.strip() or "no reason given").splitlines()[-1]
            raise Failure("Herdr refused `%s`: %s" % (" ".join(args[:3]), why))
        try:
            return json.loads(out.stdout) if out.stdout.strip() else {}
        except ValueError:
            return {}

    def screen(self, pane_id: str) -> str:
        """The visible text of <pane_id>, or "" when Herdr cannot read it."""
        argv = [self.binary, "--session", self.session, "pane", "read", pane_id, "--source", "visible"]
        try:
            out = subprocess.run(argv, capture_output=True, text=True, timeout=30,
                                 env=base_env(), stdin=subprocess.DEVNULL)
        except (OSError, subprocess.SubprocessError):
            return ""
        return out.stdout if out.returncode == 0 else ""

    def session_entry(self) -> Optional[Dict[str, Any]]:
        data = self.call("session", "list", "--json", check=False) or {}
        for entry in data.get("sessions") or []:
            if entry.get("default") or entry.get("name") == self.session:
                return entry
        return None


def result_list(data: Any, key: str) -> List[Dict[str, Any]]:
    node = (data or {}).get("result") or {}
    items = node.get(key) or []
    return [item for item in items if isinstance(item, dict)]


def plugin_title(manifest: str) -> str:
    """The title a plugin gives its pane, from its herdr-plugin.toml [[panes]] entry."""
    try:
        with open(manifest, encoding="utf-8") as handle:
            text = handle.read()
    except OSError:
        return ""
    match = re.search(r"^\[\[panes\]\][^\[]*?^title\s*=\s*\"([^\"]*)\"", text, re.M | re.S)
    return match.group(1) if match else ""


BRIDGE_TITLE = plugin_title(os.path.join(ROOT, "herdr-plugins", "starship-bridge", "herdr-plugin.toml"))
FACTORY_TITLE = plugin_title(os.path.join(ROOT, "herdr-plugins", "starship-factory", "herdr-plugin.toml"))


# --------------------------------------------------------------------------
# Reading the desk as it is
# --------------------------------------------------------------------------

def herdr_clients() -> List[str]:
    """ttys of the Herdr clients showing the default session right now."""
    lister = os.environ.get("FM_DESK_PS")
    argv = shlex.split(lister) if lister else ["ps", "-axo", "pid=,tty=,command="]
    try:
        out = subprocess.run(argv, capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    ttys = []
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) < 3 or parts[1] in ("??", "?", "-"):
            continue
        try:
            words = shlex.split(parts[2])
        except ValueError:
            continue
        if not words or os.path.basename(words[0]) != "herdr":
            continue
        if words[1:] in ([], ["--session", SESSION], ["session", "attach", SESSION]):
            ttys.append(parts[1])
    return ttys


def bare_shell(cmdline: str) -> bool:
    """True for an interactive shell's own command line: -zsh, zsh, /bin/bash -l."""
    words = cmdline.split()
    if not words or os.path.basename(words[0]).lstrip("-") not in SHELLS:
        return False
    return all(word in ("-l", "-i", "-il", "-li", "--login") for word in words[1:])


# The characters an interactive shell's prompt ends in: zsh %, sh/bash $, a root
# #, plain >, and the glyphs of common prompt themes.
PROMPT_ENDS = ("%", "$", "#", ">", "\u276f", "\u279c")


def at_prompt(screen: str) -> bool:
    """True when the last non-blank line of <screen> ends in a shell prompt with nothing typed after it."""
    lines = [line for line in screen.splitlines() if line.strip()]
    return bool(lines) and lines[-1].rstrip().endswith(PROMPT_ENDS)


def classify(pane: Dict[str, Any], info: Any) -> Dict[str, Any]:
    """What a pane is doing, from its pane list entry and `pane process-info`.

    A shell that runs a command hands the terminal to that command's own
    process group, so the shell itself is among the foreground processes only
    while it waits at its prompt or runs its own startup. An idle pane is one
    whose foreground holds the bare shell and where Herdr records no agent
    (Herdr resumes a recorded agent itself after a restart). Whether its
    prompt is showing is read separately, see with_screen.
    """
    process_info = ((info or {}).get("result") or {}).get("process_info") if info is not None else None
    cmdlines = [str(proc.get("cmdline") or "") for proc in (process_info or {}).get("foreground_processes") or []
                if isinstance(proc, dict)]
    has_agent = bool(pane.get("agent") or pane.get("agent_session"))
    return {
        "id": pane.get("pane_id"),
        "tab": pane.get("tab_id"),
        "label": pane.get("label") or "",
        "cmdlines": cmdlines,
        "agent": has_agent,
        "idle": not has_agent and any(bare_shell(c) for c in cmdlines),
    }


def with_screen(herdr: Herdr, pane: Dict[str, Any]) -> Dict[str, Any]:
    """<pane> marked free when it is idle and its screen ends at an empty shell prompt.

    An idle shell still runs its own startup before it shows a prompt, and
    input typed at the prompt waits there unseen by the process check; typing
    into either would mix the desk's command with the owner's.

    A shell whose startup file runs a command directly (a slow tool, a sleep)
    hands its foreground to that command before it has shown anything, so a
    pane with no agent, a foreground other than the shell or one of the
    desk's own scripts, and nothing on screen is marked starting.
    """
    maybe_starting = not pane["idle"] and not pane["agent"] and bool(pane["cmdlines"]) and \
        not runs(pane, "fm-bridge-strip.sh") and not runs(pane, "fm-factory-pane.sh")
    screen = herdr.screen(pane["id"]) if pane["idle"] or maybe_starting else ""
    pane["free"] = bool(pane["idle"]) and at_prompt(screen)
    pane["starting"] = maybe_starting and not screen.strip()
    return pane


def not_ready(pane: Dict[str, Any]) -> bool:
    """True for a shell not yet at an empty prompt: still starting, or holding typed-ahead input."""
    return bool(pane["idle"] and not pane["free"]) or bool(pane["starting"])


def busy_note(what: str) -> str:
    return "%s's pane has input waiting or no prompt yet; it was left alone" % what


def runs(pane: Dict[str, Any], marker: str, without: str = "") -> bool:
    return any(marker in c and (not without or without not in c) for c in pane["cmdlines"])


def is_bridge(pane: Dict[str, Any]) -> bool:
    return runs(pane, "fm-bridge-strip.sh run") or (bool(BRIDGE_TITLE) and pane["label"] == BRIDGE_TITLE)


def is_factory_pane(pane: Dict[str, Any]) -> bool:
    return runs(pane, "fm-factory-pane.sh run", without="--factory") or \
        (bool(FACTORY_TITLE) and pane["label"] == FACTORY_TITLE)


def main_tab(tabs: List[Dict[str, Any]], label: str) -> Optional[str]:
    """The id of the desk's main tab among <tabs>: the one labelled <label> when set, else the first."""
    named = next((t["id"] for t in tabs if label and t["label"] == label), None)
    return named or (tabs[0]["id"] if tabs else None)


def factory_tab(tabs: List[Dict[str, Any]], records: Dict[str, str], tab: Dict[str, Any]) -> Optional[str]:
    """The id of a layout's factory tab among <tabs>: the tab open-tab recorded, else the one with its label."""
    ids = {t["id"] for t in tabs}
    recorded = next((tid for tid, fid in records.items() if fid == tab["factory"] and tid in ids), None)
    return recorded or next((t["id"] for t in tabs if t["label"] == tab["label"]), None)


def survey(herdr: Herdr, layout: Dict[str, Any], home: str) -> Dict[str, Any]:
    """Everything the plan needs, read from Herdr, the factory tab records and the process list."""
    found: Dict[str, Any] = {"running": False, "socket": "", "workspace": None, "tabs": [], "main": None,
                             "factory_tabs": {}, "panes": {}, "clients": herdr_clients()}
    entry = herdr.session_entry()
    if not entry or not entry.get("running"):
        return found
    found["running"] = True
    found["socket"] = str(entry.get("socket_path") or "")
    for workspace in result_list(herdr.call("workspace", "list"), "workspaces"):
        if workspace.get("label") == layout["workspace"]:
            found["workspace"] = workspace.get("workspace_id")
            break
    if not found["workspace"]:
        return found
    found["tabs"] = [{"id": t.get("tab_id"), "label": t.get("label") or ""}
                     for t in result_list(herdr.call("tab", "list", "--workspace", found["workspace"]), "tabs")]
    panes = result_list(herdr.call("pane", "list", "--workspace", found["workspace"]), "panes")
    main = found["main"] = main_tab(found["tabs"], layout["main"])
    records = factory_tab_records(home, found["socket"])
    found["factory_tabs"] = {t["factory"]: factory_tab(found["tabs"], records, t)
                             for t in layout["tabs"] if t["factory"]}
    wanted_tabs = set(found["factory_tabs"].values()) - {None}
    first_in_tab: Dict[str, str] = {}
    for pane in panes:
        first_in_tab.setdefault(pane.get("tab_id"), pane.get("pane_id"))
    for pane in panes:
        tab = pane.get("tab_id")
        # Only panes the plan may act on are inspected: the main tab's, and
        # the panes of factory tabs the layout names.
        if tab != main and tab not in wanted_tabs:
            continue
        info = herdr.call("pane", "process-info", "--pane", pane.get("pane_id"), check=False)
        found["panes"].setdefault(tab, []).append(with_screen(herdr, classify(pane, info)))
    found["first_in_tab"] = first_in_tab
    return found


# --------------------------------------------------------------------------
# The plan: what is missing, in order
# --------------------------------------------------------------------------

def step(kind: str, text: str, **extra: Any) -> Dict[str, Any]:
    item = {"kind": kind, "text": text}
    item.update(extra)
    item["key"] = json.dumps([kind] + [extra[k] for k in sorted(extra)], sort_keys=True)
    return item


def view_text(index: int, view: Dict[str, Any]) -> str:
    parts = []
    if view["profile"]:
        parts.append("profile %s" % view["profile"])
    if view["size"]:
        parts.append("size %s" % view["size"])
    return "view %d in Terminal%s" % (index + 1, " (%s)" % ", ".join(parts) if parts else "")


def plan(layout: Dict[str, Any], found: Dict[str, Any],
         sidebar_now: Optional[bool]) -> Tuple[List[Dict[str, Any]], List[str], bool]:
    """The steps `open` would take from this reading, notes it can only report, and whether a pane
    it would type into or close is an idle shell not yet at an empty prompt.

    A step marked held waits while such a pane may still be starting: every view, and a factory
    page restart whose leftover shells are not all at their prompt yet.
    """
    steps: List[Dict[str, Any]] = []
    notes: List[str] = []
    starting = False
    if layout["sidebar"]:
        want = layout["sidebar"] == "collapsed"
        if sidebar_now is not want:
            steps.append(step("sidebar", "make Herdr start with the sidebar %s" % layout["sidebar"], collapsed=want))
    if not found["running"]:
        steps.append(step("start", "start Herdr"))
        notes.append("the rest of the desk is filled in once Herdr is running")
        return steps, notes, starting

    workspace = found["workspace"]
    label = layout["workspace"]
    if not workspace:
        steps.append(step("workspace", "create the workspace %s" % label, label=label))
    main = found["main"] if workspace else None
    main_panes = found["panes"].get(main, []) if main else []
    bridge = next((p for p in main_panes if is_bridge(p)), None)
    factory = next((p for p in main_panes if is_factory_pane(p)), None)
    seat = next((p for p in main_panes if p is not bridge and p is not factory), None)

    if not workspace:
        if layout["firstmate"]:
            steps.append(step("firstmate", "start the first mate (%s)" % layout["firstmate"], pane=None))
    elif seat is None:
        notes.append("the main tab of %s has no pane for the first mate; nothing was started" % label)
    elif seat["idle"] and not layout["firstmate"]:
        notes.append("the first mate's pane is an idle shell; name its command as `firstmate =` in the layout")
    elif seat["free"]:
        steps.append(step("firstmate", "start the first mate (%s)" % layout["firstmate"], pane=seat["id"]))
    elif not_ready(seat) and layout["firstmate"]:
        notes.append(busy_note("the first mate"))
        starting = True

    for kind, pane, name in (("bridge", bridge, "the Starship bridge"), ("factory", factory, "the Factory pane")):
        if pane is None:
            steps.append(step(kind, "show %s" % name, seat=seat["id"] if seat else None))
        elif pane["free"]:
            steps.append(step(kind + "-revive", "start %s again in its pane" % name, pane=pane["id"]))
        elif not_ready(pane):
            notes.append(busy_note(name))
            starting = True

    labels = {t["label"]: t["id"] for t in found["tabs"]}
    for tab in layout["tabs"]:
        tab_id = found["factory_tabs"].get(tab["factory"]) if tab["factory"] else labels.get(tab["label"])
        if tab_id is None:
            if tab["factory"]:
                steps.append(step("factory-tab", "open the %s tab" % tab["label"], factory=tab["factory"],
                                  label=tab["label"]))
            else:
                steps.append(step("tab", "open the %s tab" % tab["label"], label=tab["label"]))
            continue
        if not tab["factory"]:
            continue
        panes = found["panes"].get(tab_id, [])
        if any(runs(p, "fm-factory-pane.sh run") for p in panes):
            continue
        first = next((p for p in panes if p["id"] == found.get("first_in_tab", {}).get(tab_id)), None)
        if first is not None and first["free"]:
            others = [p for p in panes if p is not first]
            item = step("page-revive", "start the %s page again in its tab" % tab["label"],
                        pane=first["id"], factory=tab["factory"], main=main or "",
                        close=[p["id"] for p in others if p["free"]])
            item["kept"] = ["a leftover pane in the %s tab is not a shell waiting at an empty prompt; "
                            "it was left open" % tab["label"] for p in others if not p["free"]]
            item["held"] = any(not_ready(p) for p in others)
            starting = starting or item["held"]
            steps.append(item)
        elif first is not None and not_ready(first):
            notes.append(busy_note("the %s tab" % tab["label"]))
            starting = True
        else:
            notes.append("the %s tab is showing something else; it was left as it is" % tab["label"])

    for index in range(len(found["clients"]), len(layout["views"])):
        item = step("view", "open " + view_text(index, layout["views"][index]), view=index)
        item["held"] = True
        steps.append(item)
    return steps, notes, starting


# --------------------------------------------------------------------------
# Herdr's sidebar setting
# --------------------------------------------------------------------------

def herdr_config_path() -> str:
    return os.environ.get("HERDR_CONFIG_PATH") or os.path.expanduser("~/.config/herdr/config.toml")


SIDEBAR_KEY = "sidebar_start_collapsed"


def sidebar_setting(text: str) -> Optional[bool]:
    section = ""
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        header = re.match(r"^\[([^\[\]]+)\]$", line)
        if header:
            section = header.group(1).strip()
            continue
        if section == "ui":
            match = re.match(r"^%s\s*=\s*(true|false)$" % SIDEBAR_KEY, line)
            if match:
                return match.group(1) == "true"
    return None


def with_sidebar(text: str, collapsed: bool) -> str:
    """<text> with [ui] sidebar_start_collapsed set, every other line kept."""
    value = "%s = %s" % (SIDEBAR_KEY, "true" if collapsed else "false")
    lines = text.splitlines()
    section, ui_at = "", None
    for index, raw in enumerate(lines):
        line = raw.split("#", 1)[0].strip()
        header = re.match(r"^\[([^\[\]]+)\]$", line)
        if header:
            section = header.group(1).strip()
            if section == "ui" and ui_at is None:
                ui_at = index
            continue
        if section == "ui" and re.match(r"^%s\s*=" % SIDEBAR_KEY, line):
            lines[index] = value
            return "\n".join(lines) + "\n"
    if ui_at is not None:
        lines.insert(ui_at + 1, value)
        return "\n".join(lines) + "\n"
    tail = "\n" if text and not text.endswith("\n") else ""
    return text + tail + ("\n" if text else "") + "[ui]\n" + value + "\n"


def read_sidebar() -> Optional[bool]:
    try:
        with open(herdr_config_path(), encoding="utf-8") as handle:
            return sidebar_setting(handle.read())
    except OSError:
        return None


def write_sidebar(collapsed: bool) -> None:
    path = herdr_config_path()
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except FileNotFoundError:
        text = ""
    except OSError as error:
        raise Failure("Herdr's config could not be read: %s" % error)
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    temp = path + ".desk-tmp"
    with open(temp, "w", encoding="utf-8") as handle:
        handle.write(with_sidebar(text, collapsed))
    os.replace(temp, path)


# --------------------------------------------------------------------------
# Terminal views
# --------------------------------------------------------------------------

OPEN_VIEW = r'''
on run argv
  set cmd to item 1 of argv
  set prof to item 2 of argv
  set fsize to item 3 of argv
  set wasRunning to (application "Terminal" is running)
  tell application "Terminal"
    if prof is not "" then
      if not (exists settings set prof) then error "Terminal has no profile named " & prof
    end if
    set t to missing value
    if not wasRunning then
      -- Terminal just started and may have opened its own empty window: use it.
      repeat 30 times
        if (count of windows) > 0 then exit repeat
        delay 0.1
      end repeat
      if (count of windows) is 1 then
        if not (busy of selected tab of window 1) then set t to do script cmd in selected tab of window 1
      end if
    end if
    if t is missing value then set t to do script cmd
    if prof is not "" then set current settings of t to settings set prof
    if fsize is not "" then set font size of t to (fsize as integer)
    activate
    return tty of t
  end tell
end run
'''

LIST_VIEWS = r'''
on run argv
  if not (application "Terminal" is running) then return ""
  set out to ""
  set sep to ASCII character 9
  tell application "Terminal"
    repeat with w in windows
      repeat with t in tabs of w
        set out to out & (tty of t) & sep & (name of current settings of t) & sep & (font size of t) & linefeed
      end repeat
    end repeat
  end tell
  return out
end run
'''


def osascript(script: str, *args: str) -> str:
    runner = os.environ.get("FM_DESK_OSASCRIPT")
    argv = (shlex.split(runner) if runner else ["osascript"]) + ["-"] + list(args)
    try:
        out = subprocess.run(argv, input=script, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError) as error:
        raise Failure("Terminal could not be asked: %s" % error)
    if out.returncode != 0:
        why = (out.stderr.strip() or "no reason given").splitlines()[-1]
        raise Failure("Terminal refused: %s" % why)
    return out.stdout.strip()


def open_view(layout: Dict[str, Any], index: int) -> None:
    view = layout["views"][index]
    before = len(herdr_clients())
    osascript(OPEN_VIEW, "exec " + shlex.quote(herdr_bin()), view["profile"], view["size"])
    deadline = time.time() + wait_limit()
    while time.time() < deadline:
        if len(herdr_clients()) > before:
            return
        time.sleep(0.3)
    raise Failure("%s opened, but no Herdr client showed up in it" % view_text(index, view))


# --------------------------------------------------------------------------
# Doing each step
# --------------------------------------------------------------------------

def child_env(herdr: Herdr, found: Dict[str, Any], home: str, tab: str = "") -> Dict[str, str]:
    """The environment a pane of the desk's session would hand a script it runs."""
    env = base_env()
    env["FM_HOME"] = home
    env["HERDR_BIN_PATH"] = herdr.binary
    env["HERDR_SESSION"] = herdr.session
    if found.get("socket"):
        env["HERDR_SOCKET_PATH"] = found["socket"]
    if found.get("workspace"):
        env["HERDR_WORKSPACE_ID"] = found["workspace"]
    main = tab or found.get("main") or ""
    if main:
        env["HERDR_TAB_ID"] = main
    return env


def run_script(argv: List[str], env: Dict[str, str], what: str) -> None:
    try:
        out = subprocess.run(argv, capture_output=True, text=True, timeout=90, env=env, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError) as error:
        raise Failure("%s failed: %s" % (what, error))
    if out.returncode != 0:
        why = (out.stderr.strip() or out.stdout.strip() or "no reason given").splitlines()[-1]
        raise Failure("%s failed: %s" % (what, why))


def pane_command(home: str, herdr: Herdr, *words: str) -> str:
    env = ["FM_HOME=%s" % home, "HERDR_BIN_PATH=%s" % herdr.binary]
    argv = ["exec", "env"] + env + list(words)
    return " ".join(shlex.quote(w) for w in argv)


def wait_running(herdr: Herdr) -> None:
    deadline = time.time() + wait_limit()
    while time.time() < deadline:
        entry = herdr.session_entry()
        if entry and entry.get("running") and herdr.call("workspace", "list", check=False) is not None:
            return
        time.sleep(0.3)
    raise Failure("Herdr did not start the %s session within %d seconds" % (herdr.session, wait_limit()))


def pane_looks(herdr: Herdr, pane_id: str) -> Dict[str, Any]:
    info = herdr.call("pane", "process-info", "--pane", pane_id, check=False)
    return classify({"pane_id": pane_id}, info)


def settle(ready: Any, limit: Optional[float] = None) -> bool:
    """Wait until <ready>() is true, at most FM_DESK_WAIT (or <limit>) seconds."""
    deadline = time.time() + (wait_limit() if limit is None else limit)
    while True:
        if ready():
            return True
        if time.time() >= deadline:
            return False
        time.sleep(0.3)


def tab_page_runs(herdr: Herdr, found: Dict[str, Any], home: str, wanted: Dict[str, Any]) -> bool:
    workspace = found["workspace"]
    tabs = [{"id": t.get("tab_id"), "label": t.get("label") or ""}
            for t in result_list(herdr.call("tab", "list", "--workspace", workspace, check=False), "tabs")]
    tab = factory_tab(tabs, factory_tab_records(home, found["socket"]), wanted)
    if not tab:
        return False
    panes = result_list(herdr.call("pane", "list", "--workspace", workspace, check=False), "panes")
    return any(runs(pane_looks(herdr, p.get("pane_id")), "fm-factory-pane.sh run")
               for p in panes if p.get("tab_id") == tab)


def execute(item: Dict[str, Any], layout: Dict[str, Any], herdr: Herdr, found: Dict[str, Any], home: str) -> None:
    kind = item["kind"]
    tools = bin_dir()
    if kind == "sidebar":
        write_sidebar(item["collapsed"])
    elif kind == "start":
        try:
            subprocess.Popen([herdr.binary, "--session", herdr.session, "server"], env=base_env(),
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
        except OSError as error:
            raise Failure("Herdr could not be started: %s" % error)
        wait_running(herdr)
    elif kind == "workspace":
        made = herdr.call("workspace", "create", "--label", item["label"], "--cwd", home, "--no-focus")
        result = (made or {}).get("result") or {}
        first = (result.get("tab") or {}).get("tab_id")
        if layout["main"] and first:
            herdr.call("tab", "rename", first, layout["main"])
        root = result.get("root_pane") or {}
        # The first mate starts in the new workspace's first pane, so wait for
        # its shell's prompt before reading the desk again.
        if root.get("pane_id"):
            settle(lambda: with_screen(herdr, pane_looks(herdr, root["pane_id"]))["free"])
    elif kind == "firstmate":
        pane = item["pane"]
        if pane is None:
            raise Failure("the new workspace has no pane yet")
        herdr.call("pane", "run", pane, layout["firstmate"])
        settle(lambda: not pane_looks(herdr, pane).get("idle"), limit=min(wait_limit(), 5.0))
    elif kind in ("bridge", "factory"):
        if not item["seat"]:
            raise Failure("there is no pane to put %s beside" % ("the bridge" if kind == "bridge" else "the Factory pane"))
        script = "fm-bridge-strip.sh" if kind == "bridge" else "fm-factory-pane.sh"
        run_script(["bash", os.path.join(tools, script), "open", "--pane", item["seat"]],
                   child_env(herdr, found, home), item["text"])
    elif kind in ("bridge-revive", "factory-revive", "page-revive"):
        script = "fm-bridge-strip.sh" if kind == "bridge-revive" else "fm-factory-pane.sh"
        words = ["bash", os.path.join(tools, script), "run"]
        if kind == "page-revive":
            words += ["--factory", item["factory"], "--origin-tab", item["main"]]
        herdr.call("pane", "run", item["pane"], pane_command(home, herdr, *words))
        settle(lambda: runs(pane_looks(herdr, item["pane"]), script + " run"))
        if kind == "page-revive":
            for pane in item["close"]:
                herdr.call("pane", "close", pane)
            run_script([sys.executable, os.path.join(tools, "fm-factory.py"), "workers", item["factory"],
                        "--page", item["pane"]], child_env(herdr, found, home),
                       "the %s workers' live copies" % item["factory"])
    elif kind == "factory-tab":
        run_script([sys.executable, os.path.join(tools, "fm-factory.py"), "open-tab", item["factory"]],
                   child_env(herdr, found, home), item["text"])
        # Until its page runs, the new tab would read as an idle shell to restart.
        wanted = {"label": item["label"], "factory": item["factory"]}
        settle(lambda: tab_page_runs(herdr, found, home, wanted))
    elif kind == "tab":
        herdr.call("tab", "create", "--workspace", found["workspace"], "--label", item["label"], "--cwd", home)
    elif kind == "view":
        open_view(layout, item["view"])
    else:
        raise Failure("unknown step %s" % kind)


# Steps that change the layout inside the session; after any of them the desk
# hands focus back to the main tab, since opening a tab focuses it.
LAYOUT_KINDS = {"workspace", "firstmate", "bridge", "factory", "bridge-revive", "factory-revive",
                "page-revive", "factory-tab", "tab"}


def cmd_open() -> int:
    home = home_dir()
    layout = load_layout(home)
    herdr = Herdr()
    done: List[Dict[str, Any]] = []
    taken = set()
    notes: List[str] = []
    kept: List[str] = []
    # One step at a time, reading the desk again after each, so every step
    # acts on what is really there. A step is never taken twice in one run:
    # one that still shows as missing afterwards is reported, not repeated.
    pending: List[Dict[str, Any]] = []
    starting_until: Optional[float] = None
    taken_count = 0
    while True:
        found = survey(herdr, layout, home)
        steps, notes, starting = plan(layout, found, read_sidebar())
        pending = [item for item in steps if item["key"] in taken]
        fresh = [item for item in steps if item["key"] not in taken]
        # A shell still running its startup shows no prompt yet, and just
        # after a restart every restored pane starts its shell at once; give
        # the shells the desk would type into or close FM_DESK_WAIT to reach
        # their prompt before leaving them alone. Held steps wait too: views,
        # so nobody can type into such a pane through a view meanwhile, and a
        # factory page restart, so its leftover shells can still be closed.
        if starting:
            starting_until = starting_until or time.time() + wait_limit()
            if time.time() < starting_until:
                fresh = [item for item in fresh if not item.get("held")]
                if not fresh:
                    time.sleep(1)
                    continue
        if not fresh:
            break
        taken_count += 1
        if taken_count > 64:
            raise Failure("the desk did not settle after 64 steps")
        item = fresh[0]
        execute(item, layout, herdr, found, home)
        taken.add(item["key"])
        done.append(item)
        kept += item.get("kept", [])
        say("  done: %s" % item["text"])
    for item in pending:
        notes.append("asked to %s, but it has not shown up yet" % item["text"])
    if any(item["kind"] in LAYOUT_KINDS for item in done):
        found = survey(herdr, layout, home)
        if found["main"]:
            herdr.call("tab", "focus", found["main"], check=False)
    for note in kept + notes:
        say("  note: %s" % note)
    if done:
        say("The desk is open: %d thing(s) started, everything else was already there." % len(done))
    else:
        say("The desk was already open; nothing changed.")
    return 0


# --------------------------------------------------------------------------
# Reading the running session into a layout file
# --------------------------------------------------------------------------

def factory_tab_records(home: str, socket: str) -> Dict[str, str]:
    """tab id -> factory id, from the tab records bin/fm-factory.py open-tab keeps."""
    records: Dict[str, str] = {}
    folder = os.path.join(home, "state", "factory", "tabs")
    try:
        names = sorted(os.listdir(folder))
    except OSError:
        return records
    for name in names:
        try:
            with open(os.path.join(folder, name), encoding="utf-8") as handle:
                lines = handle.read().split("\n")
        except OSError:
            continue
        if len(lines) >= 2 and lines[0] and lines[1] == socket:
            records[lines[0]] = name
    return records


def cmd_layout() -> int:
    home = home_dir()
    try:
        current = load_layout(home)
    except Refused:
        current = parse_layout("")
    herdr = Herdr()
    entry = herdr.session_entry()
    if not entry or not entry.get("running"):
        raise Failure("the default Herdr session is not running, so there is no layout to read")
    socket = str(entry.get("socket_path") or "")
    workspaces = result_list(herdr.call("workspace", "list"), "workspaces")
    chosen = next((w for w in workspaces if w.get("label") == current["workspace"]), None)
    if chosen is None:
        chosen = next((w for w in workspaces if w.get("focused")), workspaces[0] if workspaces else None)
    if chosen is None:
        raise Failure("the default Herdr session has no workspace to read")
    wsid = chosen.get("workspace_id")
    tabs = [{"id": t.get("tab_id"), "label": t.get("label") or ""}
            for t in result_list(herdr.call("tab", "list", "--workspace", wsid), "tabs")]
    panes = result_list(herdr.call("pane", "list", "--workspace", wsid), "panes")
    main = main_tab(tabs, current["main"])
    main_label = next((t["label"] for t in tabs if t["id"] == main), "")
    main_panes = [{"label": p.get("label") or "", "cmdlines": [], "pane": p} for p in panes if p.get("tab_id") == main]
    seat = next((p["pane"] for p in main_panes if not is_bridge(p) and not is_factory_pane(p)), None)
    agent = ""
    if seat is not None:
        agent = str(seat.get("agent") or (seat.get("agent_session") or {}).get("agent") or "")
    records = factory_tab_records(home, socket)
    sidebar = read_sidebar()
    lines = ["# The desk `%s` opens (docs/desk.md), read from the running Herdr session." % ME,
             "workspace = %s" % chosen.get("label")]
    if main_label and not main_label.isdigit():
        lines.append("main = %s" % main_label)
    if sidebar is not None:
        lines.append("sidebar = %s" % ("collapsed" if sidebar else "open"))
    if current["firstmate"]:
        lines.append("firstmate = %s" % current["firstmate"])
    else:
        hint = " (it runs %s now)" % agent if agent else ""
        lines.append("# firstmate = firstmate <profile>   the first mate's launch command%s" % hint)
    for tab in tabs:
        if tab["id"] == main:
            continue
        fid = records.get(tab["id"])
        lines.append("tab = %s%s" % (tab["label"], " | factory %s" % fid if fid else ""))
    clients = set(herdr_clients())
    listed = osascript(LIST_VIEWS) if clients else ""
    for row in listed.splitlines():
        parts = row.split("\t")
        if len(parts) < 3:
            continue
        tty = parts[0].replace("/dev/", "")
        if tty in clients:
            size = parts[2].split(".")[0].strip()
            lines.append("view = %s%s" % (parts[1], " | %s" % size if size else ""))
    say("\n".join(lines))
    return 0


# --------------------------------------------------------------------------
# The `starship` command
# --------------------------------------------------------------------------

def cmd_install_command() -> int:
    folder = os.environ.get("FM_DESK_COMMAND_DIR") or os.path.expanduser("~/.local/bin")
    link = os.path.join(folder, ME)
    if os.path.islink(link) and os.path.realpath(link) == SCRIPT:
        say("`%s` already opens the desk (%s)." % (ME, link))
        return 0
    if os.path.lexists(link):
        raise Failure("%s already exists and is something else; it was left as it is" % link)
    other = shutil.which(ME)
    if other and os.path.realpath(other) != SCRIPT:
        raise Failure("another `%s` is already on PATH (%s), such as the starship.rs shell prompt; a link at %s "
                      "would hide it or be hidden by it, so nothing was linked" % (ME, other, link))
    os.makedirs(folder, exist_ok=True)
    os.symlink(SCRIPT, link)
    say("`%s` now opens the desk (%s -> %s)." % (ME, link, SCRIPT))
    if folder not in os.environ.get("PATH", "").split(":"):
        say("  note: %s is not on PATH in this shell" % folder)
    return 0


def usage(stream: Any = sys.stderr) -> None:
    lines = __doc__.split("\n")
    start = next(i for i, line in enumerate(lines) if line.startswith("Usage:"))
    end = next(i for i, line in enumerate(lines) if line.startswith("The layout lives"))
    stream.write("\n".join(lines[start:end]).rstrip() + "\n")


def main(argv: List[str]) -> int:
    command = argv[0] if argv else "open"
    try:
        if command in ("-h", "--help", "help"):
            usage(sys.stdout)
            return 0
        if command == "open" and len(argv) <= 1:
            return cmd_open()
        if command == "layout" and len(argv) == 1:
            return cmd_layout()
        if command == "install-command" and len(argv) == 1:
            return cmd_install_command()
        usage()
        return 2
    except Refused as error:
        print("%s: %s" % (ME, error), file=sys.stderr)
        return 2
    except Failure as error:
        print("%s: %s" % (ME, error), file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
