#!/usr/bin/env bash
# Show the captain an always-on-top card of on-screen steps over a page they
# must fill in themselves, such as a form in a web console.
#
# Usage:
#   fm-screen-steps.sh show [--url <http(s)-url>] --steps-file <file>
#   fm-screen-steps.sh hide
#   fm-screen-steps.sh reply done|stuck [--step <n>]
#   fm-screen-steps.sh --help
#
# show opens <url> as a new tab in Arc's main browser window (never a
# Little Arc popup) and brings that window to the front, so the page shows at
# the full size the captain keeps that window; Arc makes a new window when it
# has none. An existing Arc window is never moved or resized. Without Arc, or
# when Arc refuses, the URL opens in the default browser. Then the card shows
# above the page: the title, any note, the numbered steps, and every value to
# type with its own Copy button, plus Done and Stuck buttons. Without --url
# the card is shown over whatever is already on screen. Only http and https
# URLs are opened. A second show replaces the card's contents (and clears its
# ticks); hide closes it. One line per action on stdout:
#   opened: arc <url>                     opened in Arc
#   opened: default-browser <url>         Arc is missing or refused (the
#                                         reason goes to stderr)
#   card: <card.json path>                the card shows these steps
#
# The steps file is simple Markdown:
#   # Create the app in App Store Connect     <- title (first "# " line)
#   Open My Apps first.                       <- note: lines before step 1
#   1. Click + and choose New App.            <- a step: "1." "1)" "-" "*"
#   2. Platform: tick `iOS`.                  <- `code` is a value to copy
#   3. Name: `Harbour Logbook`
#      Keep the capital letters.              <- other lines join the step
# Every `code` span in a step becomes a value with a Copy button; the step
# text shows it in monospace, and any **bold** too. Blank lines are ignored.
# A file with no step is refused.
#
# The card is the native panel in screen-steps/, built on first use (and
# after any change to its sources) into screen-steps/.build/ScreenSteps.app
# with the linker's ad-hoc signature; it needs no macOS permission. It floats
# above every app and Space, never takes keyboard focus from the page (Copy
# writes the clipboard; clicking the card leaves the cursor in the form), can
# be dragged anywhere by its background, sits in the bottom-right corner, and
# its X button runs hide. The card reads
#   $FM_HOME/state/screen-steps/card.json
# which show writes and hide removes; the card closes itself once that file
# is gone. One card runs per home; its pid is kept in card.pid there.
#
# Done and Stuck run reply, which sends one short line of the captain's own
# into the primary Firstmate chat through the desk floater's delivery path,
# bin/fm-desk-voice.sh send --source screen-steps (typed into the chat, or
# saved to its mailbox when the chat cannot take it; docs/desk-floater.md),
# and prints that script's outcome line. Done also closes the card once the
# line is on its way. A step the captain ticks on the card marks it done;
# Stuck names the first step not ticked when any is ticked:
#   Done with the on-screen steps: <title>
#   Stuck on the on-screen steps: <title>
#   Stuck at step <n> of the on-screen steps: <title> (<step text>)
#
# Arc: osascript tells Arc to open the tab, which needs the Automation
# permission for Arc from the app running this script; macOS asks once. Every
# osascript call is bounded by FM_SCREEN_STEPS_ARC_TIMEOUT seconds (default
# 20), so a permission dialog nobody answers never hangs show.
#
# Automated runs never reach the captain's screen or chat: under CI,
# GITHUB_ACTIONS or a no-mistakes gate (NO_MISTAKES_GATE, or this script
# running from a no-mistakes worktree), show and reply refuse before opening
# a page, starting the card or sending anything. The tests drive show and
# reply only through stand-ins with those variables cleared.
#
# Environment: FM_HOME selects the home (default: this code root);
# FM_STATE_OVERRIDE its state directory.
#
# Exit: 0 ok, 1 failure, 2 bad usage, 3 refused in an automated run.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CARD_DIR="$STATE/screen-steps"
CARD="$CARD_DIR/card.json"
PIDFILE="$CARD_DIR/card.pid"
PKG="$ROOT/screen-steps"
RELEASE_BIN="$PKG/.build/release/ScreenSteps"
APP_DIR="$PKG/.build/ScreenSteps.app"
APP_BIN="$APP_DIR/Contents/MacOS/ScreenSteps"
ARC_TIMEOUT="${FM_SCREEN_STEPS_ARC_TIMEOUT:-20}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

note() {
  printf 'fm-screen-steps: %s\n' "$*" >&2
}

die() {
  note "$*"
  exit 1
}

refuse() {
  note "$*"
  exit 2
}

# Writes the card for <steps-file> atomically, with a fresh revision so the
# card resets its ticks even when the steps are unchanged.
write_card() {  # <steps-file> <url>
  mkdir -p "$CARD_DIR" || die "cannot create $CARD_DIR"
  chmod 700 "$CARD_DIR" 2>/dev/null || true
  python3 - "$1" "$2" "$CARD" <<'PY'
import json, os, re, secrets, sys, time

src, url, out = sys.argv[1:4]
with open(src, encoding="utf-8") as fh:
    lines = fh.read().splitlines()

step_re = re.compile(r"^(?:\d+[.)]|[-*+])\s+(.*)$")
title, note, steps = None, [], []
for raw in lines:
    line = raw.rstrip()
    if not line.strip():
        continue
    if title is None and not steps and not note and line.startswith("# "):
        title = line[2:].strip()
        continue
    match = step_re.match(line)
    if match:
        steps.append([match.group(1).strip()])
    elif steps:
        steps[-1].append(line.strip())
    else:
        note.append(line.strip())

if not steps:
    sys.stderr.write("fm-screen-steps: no steps in %s: write numbered lines such as '1. Click New App'\n" % src)
    sys.exit(2)

def values(text):
    seen = []
    for value in re.findall(r"`([^`\n]+)`", text):
        if value.strip() and value not in seen:
            seen.append(value)
    return seen

card = {
    "schema": "fm-screen-steps-card.v1",
    "revision": "%d-%s" % (time.time_ns(), secrets.token_hex(4)),
    "title": title or "Steps",
    "note": " ".join(note),
    "url": url,
    "steps": [{"text": "\n".join(s), "values": values("\n".join(s))} for s in steps],
}
tmp = out + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(card, fh, ensure_ascii=False)
os.chmod(tmp, 0o600)
os.replace(tmp, out)
PY
}

# Runs <cmd...> for at most <seconds>; 124 when it had to be stopped.
run_bounded() {  # <seconds> <cmd...>
  local limit=$1 pid ticks=0
  shift
  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge $((limit * 5)) ]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.2
    ticks=$((ticks + 1))
  done
  wait "$pid"
}

# Opens the URL as a tab of Arc's main browser window (the first window
# with a space, so never a Little Arc popup), making that window when Arc has
# none, and brings it to the front.
ARC_OPEN_SCRIPT='on run argv
  tell application id "company.thebrowser.Browser"
    set target to missing value
    repeat with w in windows
      if (count of spaces of w) > 0 and incognito of w is false then
        set target to w
        exit repeat
      end if
    end repeat
    if target is missing value then
      make new window
      set target to front window
    end if
    tell target to make new tab with properties {URL:item 1 of argv}
    try
      set index of target to 1
    end try
    activate
  end tell
end run'

# Runs one osascript under the time bound and prints why it failed, if it
# did; a freshly started Arc may not have its window yet, so a failure other
# than a timeout or a refused permission is tried again a few times.
arc_script() {  # <osascript args...>
  local err="$CARD_DIR/arc.err" attempt=1 rc
  while :; do
    rc=0
    run_bounded "$ARC_TIMEOUT" osascript "$@" >/dev/null 2>"$err" || rc=$?
    if [ "$rc" -eq 0 ]; then
      rm -f "$err"
      return 0
    fi
    if [ "$rc" -eq 124 ]; then
      printf 'Arc did not answer within %ss\n' "$ARC_TIMEOUT"
    elif grep -q -- '-1743' "$err" 2>/dev/null; then
      printf 'no Automation permission for Arc\n'
    elif [ "$attempt" -ge 6 ]; then
      tr '\n' ' ' < "$err" | sed 's/[[:space:]]*$//'
      printf '\n'
    else
      attempt=$((attempt + 1))
      sleep 0.5
      continue
    fi
    rm -f "$err"
    return 1
  done
}

# Asks LaunchServices, without starting anything, whether Arc is installed.
arc_installed() {
  run_bounded "$ARC_TIMEOUT" osascript -l JavaScript -e 'ObjC.import("AppKit");
$.NSWorkspace.sharedWorkspace.URLForApplicationWithBundleIdentifier("company.thebrowser.Browser").isNil() ? "no" : "yes"' \
    2>/dev/null | grep -qx yes
}

# Opens <url> in Arc, else in the default browser.
open_url() {  # <url>
  local why="Arc is not installed"
  if arc_installed; then
    if why=$(arc_script -e "$ARC_OPEN_SCRIPT" "$1"); then
      printf 'opened: arc %s\n' "$1"
      return 0
    fi
  fi
  note "Arc could not open the page ($why); using the default browser"
  open "$1" >/dev/null 2>&1 || die "could not open $1"
  printf 'opened: default-browser %s\n' "$1"
}

write_info_plist() {
  cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.firstmate.screen-steps</string>
  <key>CFBundleName</key>
  <string>ScreenSteps</string>
  <key>CFBundleExecutable</key>
  <string>ScreenSteps</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST
}

needs_build() {
  local src
  [ -x "$APP_BIN" ] || return 0
  [ "$PKG/Package.swift" -nt "$APP_BIN" ] && return 0
  for src in "$PKG"/Sources/*.swift; do
    [ "$src" -nt "$APP_BIN" ] && return 0
  done
  return 1
}

# Builds the card app; the binary replaces the old one by rename, so a card
# still running from it is not disturbed.
build_app() {
  command -v swift >/dev/null 2>&1 || die "swift is not installed"
  note "building ScreenSteps (release)"
  ( cd "$PKG" && swift build -c release --product ScreenSteps >&2 ) || die "swift build failed"
  [ -x "$RELEASE_BIN" ] || die "expected binary missing: $RELEASE_BIN"
  mkdir -p "$APP_DIR/Contents/MacOS"
  cp "$RELEASE_BIN" "$APP_BIN.new"
  chmod +x "$APP_BIN.new"
  mv -f "$APP_BIN.new" "$APP_BIN"
  write_info_plist
}

# True when this home's card is already running from this code root's app.
card_running() {
  local pid
  pid=$(cat "$PIDFILE" 2>/dev/null) || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  ps -p "$pid" -o command= 2>/dev/null | grep -qF "$APP_BIN"
}

launch_card() {
  local env=(--env "FM_HOME=$FM_HOME" --env "FM_SCREEN_STEPS_ROOT=$ROOT" --env "FM_SCREEN_STEPS_DIR=$CARD_DIR")
  [ -z "${FM_STATE_OVERRIDE:-}" ] || env+=(--env "FM_STATE_OVERRIDE=$FM_STATE_OVERRIDE")
  card_running && return 0
  if needs_build; then
    build_app
  fi
  # -n: a card of its own for this home; -g: never brought to the front, so
  # the page keeps keyboard focus.
  open -n -g "${env[@]}" "$APP_DIR" || die "could not start the card at $APP_DIR"
}

# Refuses <action> in an automated run, so a test or pipeline agent never
# opens Arc, shows the card or types into the captain's chat.
refuse_automated() {  # <action>
  local why=""
  if [ -n "${CI:-}" ]; then
    why=CI
  elif [ -n "${GITHUB_ACTIONS:-}" ]; then
    why=GITHUB_ACTIONS
  elif [ -n "${NO_MISTAKES_GATE:-}" ]; then
    why=NO_MISTAKES_GATE
  else
    case "$ROOT" in */.no-mistakes/worktrees/*) why="a no-mistakes worktree" ;; esac
  fi
  [ -n "$why" ] || return 0
  note "refusing to $1 in an automated run ($why): the captain's screen and Firstmate chat are off limits to tests and pipeline agents"
  exit 3
}

cmd_show() {
  local url="" steps=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --url) [ "$#" -ge 2 ] || refuse "--url needs a value"; url=$2; shift 2 ;;
      --steps-file) [ "$#" -ge 2 ] || refuse "--steps-file needs a value"; steps=$2; shift 2 ;;
      *) refuse "unexpected argument: $1" ;;
    esac
  done
  [ -n "$steps" ] || refuse "show needs --steps-file <file>"
  [ -f "$steps" ] || refuse "no such steps file: $steps"
  case "$url" in
    ''|http://*|https://*) ;;
    *) refuse "only http and https URLs are opened: $url" ;;
  esac
  refuse_automated "open a page or show the card"
  write_card "$steps" "$url" || exit $?
  [ -z "$url" ] || open_url "$url"
  launch_card
  printf 'card: %s\n' "$CARD"
}

cmd_hide() {
  [ "$#" -eq 0 ] || refuse "unexpected argument: $1"
  rm -f "$CARD"
}

cmd_reply() {
  local kind="" step="" text
  case "${1:-}" in
    done|stuck) kind=$1; shift ;;
    *) refuse "reply needs done or stuck" ;;
  esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --step) [ "$#" -ge 2 ] || refuse "--step needs a value"; step=$2; shift 2 ;;
      *) refuse "unexpected argument: $1" ;;
    esac
  done
  case "$step" in ''|[1-9]|[1-9][0-9]) ;; *) refuse "--step must be a step number: $step" ;; esac
  refuse_automated "send a reply into the Firstmate chat"
  [ -f "$CARD" ] || die "no card is showing"
  text=$(python3 - "$CARD" "$kind" "$step" <<'PY'
import json, sys

path, kind, step = sys.argv[1:4]
with open(path, encoding="utf-8") as fh:
    card = json.load(fh)
title = card.get("title") or "Steps"
steps = card.get("steps") or []
if kind == "done":
    print("Done with the on-screen steps: %s" % title)
elif step and 1 <= int(step) <= len(steps):
    text = " ".join(steps[int(step) - 1].get("text", "").replace(chr(96), "").replace("**", "").split())
    print("Stuck at step %s of the on-screen steps: %s (%s)" % (step, title, text))
else:
    print("Stuck on the on-screen steps: %s" % title)
PY
  ) || die "cannot read $CARD"
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-desk-voice.sh" send --source screen-steps -- "$text"
}

main() {
  case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    show) shift; cmd_show "$@" ;;
    hide) shift; cmd_hide "$@" ;;
    reply) shift; cmd_reply "$@" ;;
    '') usage; exit 2 ;;
    *) refuse "unknown command: $1" ;;
  esac
}

main "$@"
