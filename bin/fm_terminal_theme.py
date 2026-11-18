#!/usr/bin/env python3
"""Shared Factory/bridge colours, selected once before drawing.

FM_TERMINAL_THEME: auto (default), light, dark; invalid values act as auto.
In auto, query OSC 11 on the controlling tty for at most 150 ms, then try
COLORFGBG's final ANSI colour index, otherwise keep the original dark theme.
Usage: python3 fm_terminal_theme.py [--query]
Print semicolon-separated RGB triples in bridge order. --query is for callers
whose output is a terminal even though they capture this command's stdout.
"""

import os
import re
import select
import sys
import termios
import time


DARK = {
    "ice": (232, 238, 247), "mist": (163, 180, 203),
    "faint": (107, 127, 156), "cyan": (116, 215, 234),
    "amber": (255, 182, 72), "ember": (150, 110, 58),
    "green": (98, 221, 154), "red": (255, 122, 107),
    "band": (38, 53, 78), "hull": (13, 21, 36),
    "lamp_off": (61, 82, 115),
}
LIGHT = {
    "ice": (25, 39, 58), "mist": (62, 80, 104),
    "faint": (86, 103, 125), "cyan": (0, 99, 120),
    "amber": (139, 78, 0), "ember": (121, 86, 41),
    "green": (21, 108, 65), "red": (179, 43, 35),
    "band": (217, 229, 241), "hull": (242, 246, 251),
    "lamp_off": (129, 146, 166),
}


def background_theme(reply):
    """Classify an OSC 11 rgb reply (1 to 4 hex digits per channel)."""
    match = re.search(rb"\x1b\]11;rgb:([0-9a-fA-F]{1,4})/([0-9a-fA-F]{1,4})/([0-9a-fA-F]{1,4})(?:\x07|\x1b\\)", reply)
    if not match:
        return None
    channels = [int(c, 16) / (16 ** len(c) - 1) for c in match.groups()]
    linear = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in channels]
    luminance = sum(c * w for c, w in zip(linear, (0.2126, 0.7152, 0.0722)))
    return "light" if luminance > 0.179 else "dark"


def query_background():
    """Bounded tty query, restoring input settings even on a missing reply."""
    fd = None
    saved = None
    try:
        fd = os.open("/dev/tty", os.O_RDWR | os.O_NONBLOCK | os.O_NOCTTY)
        # A background process must never change its foreground owner's tty.
        if os.tcgetpgrp(fd) != os.getpgrp():
            return None
        saved = termios.tcgetattr(fd)
        mode = termios.tcgetattr(fd)
        mode[3] &= ~(termios.ECHO | termios.ICANON)
        mode[6][termios.VMIN] = 0
        mode[6][termios.VTIME] = 0
        termios.tcsetattr(fd, termios.TCSANOW, mode)
        os.write(fd, b"\x1b]11;?\x1b\\")
        deadline = time.monotonic() + 0.15
        reply = b""
        while len(reply) < 1024:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
                break
            chunk = os.read(fd, 1024 - len(reply))
            if not chunk:
                break
            reply += chunk
            theme = background_theme(reply)
            if theme:
                return theme
    except (OSError, ValueError, termios.error):
        pass
    finally:
        if fd is not None:
            try:
                if saved is not None:
                    termios.tcsetattr(fd, termios.TCSANOW, saved)
            finally:
                os.close(fd)
    return None


def select_theme(query=True):
    override = os.environ.get("FM_TERMINAL_THEME", "auto")
    if override in ("light", "dark"):
        return override
    theme = query_background() if query else None
    if theme:
        return theme
    background = os.environ.get("COLORFGBG", "").split(";")[-1]
    if background.isdigit() and 0 <= int(background) <= 15:
        # ANSI white and bright colours, except bright black, indicate light.
        return "light" if int(background) == 7 or int(background) >= 9 else "dark"
    return "dark"


def palette(theme):
    return LIGHT if theme == "light" else DARK


if __name__ == "__main__":
    colours = palette(select_theme(query="--query" in sys.argv[1:]))
    for role in ("hull", "ice", "mist", "faint", "lamp_off", "cyan", "amber", "green", "red"):
        print(";".join(map(str, colours[role])))
