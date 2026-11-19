#!/usr/bin/env python3
"""Shared Factory/bridge colours, selected once before drawing.

The theme is chosen in this order:
  1. FM_TERMINAL_THEME set to light or dark (other values act as unset);
  2. the home's remembered workspace theme, config/workspace-theme, holding
     light or dark, which bin/fm-theme.sh writes (FM_HOME selects the home,
     default this code root);
  3. auto: query OSC 11 on the controlling tty for at most 150 ms, then try
     COLORFGBG's final ANSI colour index, otherwise keep the dark theme.
Usage: python3 fm_terminal_theme.py [--query]
Print semicolon-separated RGB triples in bridge order. --query is for callers
whose output is a terminal even though they capture this command's stdout.
       python3 fm_terminal_theme.py --terminal-profile [DIR]
Print the cream Terminal profile's name, or with DIR write the profile file
there and print its path (bin/fm-theme.sh imports it).
Running panes call remembered_theme() again while they draw, so a switch by
bin/fm-theme.sh repaints them in place.
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
# Cream: warm paper and brown-black ink, matching assets/themes/herdr-light.toml.
LIGHT = {
    "ice": (58, 49, 40), "mist": (84, 73, 59),
    "faint": (106, 94, 77), "cyan": (26, 98, 107),
    "amber": (126, 76, 14), "ember": (118, 88, 52),
    "green": (52, 104, 63), "red": (156, 56, 47),
    "band": (230, 221, 203), "hull": (236, 228, 212),
    "lamp_off": (163, 151, 131),
}

# The cream Terminal profile bin/fm-theme.sh imports, written by
# terminal_profile(). Terminal names an imported profile after its file.
TERMINAL_PROFILE_NAME = "Starship Cream"
TERMINAL_PROFILE = {
    "BackgroundColor": "#f6f0e4", "TextColor": "#3a3128",
    "TextBoldColor": "#241d16", "CursorColor": "#1a626b",
    "SelectionColor": "#e0d3bb",
    "ANSIBlackColor": "#3a3128", "ANSIRedColor": "#9c382f",
    "ANSIGreenColor": "#34683f", "ANSIYellowColor": "#7e4c0e",
    "ANSIBlueColor": "#3b64a0", "ANSIMagentaColor": "#84499a",
    "ANSICyanColor": "#1a626b", "ANSIWhiteColor": "#e4dac7",
    "ANSIBrightBlackColor": "#6a5e4d", "ANSIBrightRedColor": "#b8524a",
    "ANSIBrightGreenColor": "#4b8657", "ANSIBrightYellowColor": "#9e6620",
    "ANSIBrightBlueColor": "#4f78b4", "ANSIBrightMagentaColor": "#9a5fae",
    "ANSIBrightCyanColor": "#2b7f89", "ANSIBrightWhiteColor": "#fbf8f1",
}

ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))


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


def remembered_theme(home=None):
    """The home's config/workspace-theme, light or dark, else None."""
    home = home or os.environ.get("FM_HOME") or ROOT
    try:
        with open(os.path.join(home, "config", "workspace-theme"), encoding="utf-8") as handle:
            value = handle.readline().strip()
    except (OSError, UnicodeDecodeError):
        return None
    return value if value in ("light", "dark") else None


def select_theme(query=True, home=None):
    override = os.environ.get("FM_TERMINAL_THEME", "auto")
    if override in ("light", "dark"):
        return override
    remembered = remembered_theme(home)
    if remembered:
        return remembered
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


def archived_colour(hex_colour):
    """One sRGB colour as the keyed archive a Terminal profile stores."""
    import plistlib
    rgb = " ".join("%.6f" % (int(hex_colour[i:i + 2], 16) / 255) for i in (1, 3, 5))
    archive = {
        "$archiver": "NSKeyedArchiver", "$version": 100000,
        "$top": {"root": plistlib.UID(1)},
        "$objects": [
            "$null",
            {"NSColorSpace": 2, "NSRGB": rgb.encode() + b"\0", "$class": plistlib.UID(2)},
            {"$classname": "NSColor", "$classes": ["NSColor", "NSObject"]},
        ],
    }
    return plistlib.dumps(archive, fmt=plistlib.FMT_BINARY)


def terminal_profile(directory):
    """Write the cream profile file into <directory>; return its path."""
    import plistlib
    settings = {"name": TERMINAL_PROFILE_NAME, "type": "Window Settings"}
    for key, value in TERMINAL_PROFILE.items():
        settings[key] = archived_colour(value)
    path = os.path.join(directory, TERMINAL_PROFILE_NAME + ".terminal")
    with open(path, "wb") as handle:
        plistlib.dump(settings, handle)
    return path


if __name__ == "__main__":
    if sys.argv[1:2] == ["--terminal-profile"]:
        print(terminal_profile(sys.argv[2]) if len(sys.argv) > 2 else TERMINAL_PROFILE_NAME)
        sys.exit(0)
    colours = palette(select_theme(query="--query" in sys.argv[1:]))
    for role in ("hull", "ice", "mist", "faint", "lamp_off", "cyan", "amber", "green", "red"):
        print(";".join(map(str, colours[role])))
