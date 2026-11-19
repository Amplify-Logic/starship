#!/usr/bin/env bash
# fm-theme.sh - flip the whole Starship workspace between dark and light in one
# go, and remember the choice.
#
# Light is cream: warm paper backgrounds, brown-black ink and muted lamps, not
# bright white. Dark is the flight deck the workspace already wears. One run
# switches every part that can be switched from outside, each step kept when it
# is already done:
#   - Terminal (macOS): every tab in the dark profile moves to the cream
#     profile, Starship Cream, keeping its font size, and so do Terminal's
#     default and startup profiles, so new windows open in it. The first
#     switch to light writes the cream profile (bin/fm_terminal_theme.py
#     --terminal-profile) into data/workspace-theme/ and imports it (Terminal
#     opens one window to do that, which is closed again), then gives it the
#     dark profile's font. The dark profile is the one Terminal used by default
#     before that first switch, remembered in
#     data/workspace-theme/terminal-dark-profile; dark moves the cream tabs back
#     to it, and leaves Terminal as it is when none is remembered.
#   - Herdr: the [theme] tables of Herdr's config.toml are replaced with
#     assets/themes/herdr-light.toml, or for dark with the tables that were
#     there before the first switch to light (saved in
#     data/workspace-theme/herdr-dark.toml); with nothing saved, dark leaves
#     config.toml as it is. Every other line of config.toml stays as it was. The new file must pass
#     `herdr config check` before it replaces the old one, and the old one is
#     kept as data/workspace-theme/herdr-config.before.toml; then
#     `herdr server reload-config` applies it to the running workspace.
#   - The bridge strip and the Factory pane: the choice is written to the
#     home's config/workspace-theme, which bin/fm_terminal_theme.py reads. A
#     running strip or Factory pane repaints in the new colours within about a
#     second, in place, so no tab or pane closes; new ones start in it.
#   - Claude Code chats keep their own theme, which nothing outside them sets
#     reliably, so the run ends with one line saying to type /theme in each.
# A step that cannot run (no Terminal on this computer, Terminal not open, no
# Herdr) is reported and skipped; a step that fails is reported, the other
# steps still run, and the run exits 1.
#
# Usage:
#   fm-theme.sh light               switch everything to cream
#   fm-theme.sh dark                switch everything back to the dark look
#   fm-theme.sh status              print the remembered choice and what each
#                                   part is showing; changes nothing
#   fm-theme.sh terminal-profile    print the cream Terminal profile's name when
#                                   the remembered choice is light, else nothing
#                                   (bin/fm-desk.py opens its views in it)
#
# Environment:
#   FM_HOME            the home whose choice is remembered (default: this code
#                      root)
#   HERDR_BIN_PATH     the Herdr binary (default: herdr on PATH)
#   HERDR_CONFIG_PATH  Herdr's config file (default: ~/.config/herdr/config.toml)
# Test seams:
#   FM_THEME_OSASCRIPT  AppleScript runner, given the script on stdin
#                       (default: osascript on macOS; empty on other systems
#                       skips the Terminal step)
#   FM_THEME_OPEN       the command that imports the cream profile file
#                       (default: open -g)
# Exit: 0 when every step that could run succeeded; 1 when a step failed, with
# the reason printed; 2 on a usage error.
set -u

SCRIPT_DIR=$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(CDPATH='' cd -P -- "$SCRIPT_DIR/.." && pwd -P)
ME=fm-theme.sh
FM_HOME=${FM_HOME:-$ROOT}
CHOICE_FILE="$FM_HOME/config/workspace-theme"
SAVED="$FM_HOME/data/workspace-theme"
THEMES="$ROOT/assets/themes"
PALETTES="$SCRIPT_DIR/fm_terminal_theme.py"
HERDR_CONFIG=${HERDR_CONFIG_PATH:-$HOME/.config/herdr/config.toml}
FAILED=0

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

say() { printf '%s\n' "$*"; }
fail() { printf '%s: %s\n' "$ME" "$*" >&2; FAILED=1; }

herdr_bin() { printf '%s' "${HERDR_BIN_PATH:-herdr}"; }

remembered() {
  local value=''
  [ -f "$CHOICE_FILE" ] && IFS= read -r value < "$CHOICE_FILE" 2>/dev/null
  case "$value" in light|dark) printf '%s' "$value" ;; esac
}

# The cream profile's name, owned by bin/fm_terminal_theme.py.
cream_name() { python3 "$PALETTES" --terminal-profile; }

write_atomic() {  # <file> <content>
  local tmp="$1.$$"
  mkdir -p "$(dirname "$1")" && printf '%s\n' "$2" > "$tmp" && mv -f "$tmp" "$1"
}

# --- Terminal -----------------------------------------------------------------

# The AppleScript runner, or nothing where there is no Terminal to script.
osa_runner() {
  if [ -n "${FM_THEME_OSASCRIPT+set}" ]; then
    printf '%s' "$FM_THEME_OSASCRIPT"
  elif [ "$(uname -s)" = Darwin ] && command -v osascript >/dev/null 2>&1; then
    printf osascript
  fi
}

have_osa() { [ -n "$(osa_runner)" ]; }

osa() {  # <script> [args...]; the runner gets the script on stdin
  local runner script=$1
  runner=$(osa_runner)
  shift
  # shellcheck disable=SC2086  # the runner may carry its own words
  printf '%s\n' "$script" | $runner - "$@"
}

# The default profile's name and whether <cream> exists, tab-separated, or
# "not-running". Asking never starts Terminal.
TERMINAL_QUERY='on run argv
  set cream to item 1 of argv
  if not (application "Terminal" is running) then return "not-running"
  tell application "Terminal"
    set out to (name of default settings) & (ASCII character 9) & ((exists settings set cream) as text)
  end tell
  return out
end run'

TERMINAL_WINDOWS='on run argv
  set out to ""
  tell application "Terminal"
    repeat with w in windows
      set out to out & (id of w) & linefeed
    end repeat
  end tell
  return out
end run'

# After the profile file was opened: wait for Terminal to add the profile and
# open its window, then close only new windows showing that profile.
TERMINAL_IMPORTED='on run argv
  set cream to item 1 of argv
  set known to rest of argv
  tell application "Terminal"
    repeat 100 times
      if exists settings set cream then exit repeat
      delay 0.1
    end repeat
    if not (exists settings set cream) then error "Terminal did not add the profile " & cream
    repeat 30 times
      set fresh to {}
      repeat with w in windows
        if known does not contain ((id of w) as text) then set end of fresh to w
      end repeat
      if (count of fresh) > 0 then exit repeat
      delay 0.1
    end repeat
    repeat with w in fresh
      if name of current settings of selected tab of w is cream then close w
    end repeat
  end tell
end run'

TERMINAL_FONT='on run argv
  set fromName to item 1 of argv
  set toName to item 2 of argv
  tell application "Terminal"
    if exists settings set fromName then
      set font name of settings set toName to font name of settings set fromName
      set font size of settings set toName to font size of settings set fromName
    end if
  end tell
end run'

# Move every tab showing <from> to <to>, each keeping its font size, and the
# default and startup profiles when they are <from>. Prints how many tabs moved.
TERMINAL_SWITCH='on run argv
  set fromName to item 1 of argv
  set toName to item 2 of argv
  set moved to 0
  tell application "Terminal"
    if not (exists settings set toName) then error "Terminal has no profile named " & toName
    set target to settings set toName
    repeat with w in windows
      repeat with t in tabs of w
        if name of current settings of t is fromName then
          set fsize to font size of t
          set current settings of t to target
          set font size of t to fsize
          set moved to moved + 1
        end if
      end repeat
    end repeat
    if name of default settings is fromName then set default settings to target
    if name of startup settings is fromName then set startup settings to target
  end tell
  return moved
end run'

terminal_step() {  # light|dark
  local mode=$1 cream answer default has_cream dark before opener moved profile
  have_osa || { say "Terminal: not on this computer; skipped"; return 0; }
  cream=$(cream_name)
  [ -n "$cream" ] || { fail "Terminal: cannot read the cream profile's name from $PALETTES"; return 0; }
  answer=$(osa "$TERMINAL_QUERY" "$cream" 2>&1) || { fail "Terminal: could not be asked: $answer"; return 0; }
  if [ "$answer" = not-running ]; then
    say "Terminal: not open; open it and run this again to switch its windows"
    return 0
  fi
  default=${answer%%$'\t'*}
  has_cream=${answer#*$'\t'}
  dark=''
  [ ! -f "$SAVED/terminal-dark-profile" ] || IFS= read -r dark < "$SAVED/terminal-dark-profile"
  if [ "$mode" = light ]; then
    if [ "$default" != "$cream" ]; then
      dark=$default
      write_atomic "$SAVED/terminal-dark-profile" "$dark" \
        || { fail "Terminal: could not remember the dark profile in $SAVED"; return 0; }
    fi
    [ -n "$dark" ] || { fail "Terminal: no dark profile is remembered to switch from"; return 0; }
    if [ "$has_cream" != true ]; then
      profile=$(mkdir -p "$SAVED" && python3 "$PALETTES" --terminal-profile "$SAVED") \
        || { fail "Terminal: could not write the cream profile into $SAVED"; return 0; }
      before=$(osa "$TERMINAL_WINDOWS" 2>&1) || { fail "Terminal: could not list its windows: $before"; return 0; }
      opener=${FM_THEME_OPEN:-open -g}
      # shellcheck disable=SC2086  # the opener may carry its own words
      $opener "$profile" >/dev/null 2>&1 \
        || { fail "Terminal: could not open $profile to add the cream profile"; return 0; }
      # shellcheck disable=SC2046,SC2086  # one argument per window id
      answer=$(osa "$TERMINAL_IMPORTED" "$cream" $before 2>&1) \
        || { fail "Terminal: adding the cream profile failed: $answer"; return 0; }
    fi
    answer=$(osa "$TERMINAL_FONT" "$dark" "$cream" 2>&1) \
      || { fail "Terminal: could not give the cream profile the font of $dark: $answer"; return 0; }
    moved=$(osa "$TERMINAL_SWITCH" "$dark" "$cream" 2>&1) \
      || { fail "Terminal: switching to $cream failed: $moved"; return 0; }
    say "Terminal: $moved tab(s) and new windows now use $cream (from $dark)"
  else
    if [ -z "$dark" ]; then
      say "Terminal: no dark profile is remembered from a switch to light; left as it is"
      return 0
    fi
    moved=$(osa "$TERMINAL_SWITCH" "$cream" "$dark" 2>&1) \
      || { fail "Terminal: switching to $dark failed: $moved"; return 0; }
    say "Terminal: $moved tab(s) and new windows now use $dark"
  fi
}

# --- Herdr --------------------------------------------------------------------

# theme_split <config> <keep-out> <theme-out>: copy every line of <config>
# outside a [theme] or [theme.*] table to <keep-out>, with one marker line
# where the first such table began, and the theme tables' own lines, in order,
# to <theme-out>. A table runs from its header to the next table header.
theme_split() {
  awk -v keep="$2" -v theme="$3" '
    BEGIN { in_theme = 0; marked = 0; printf "" > keep; printf "" > theme }
    /^[[:space:]]*\[/ {
      in_theme = ($0 ~ /^[[:space:]]*\[[[:space:]]*theme[[:space:]]*(\.[^]]*)?\][[:space:]]*(#.*)?$/)
      if (in_theme && !marked) { print "@@FM_THEME@@" > keep; marked = 1 }
    }
    { if (in_theme) print > theme; else print > keep }
  ' "$1"
}

# theme_join <keep> <block-file> <out>: put <block-file> back where the marker
# is, or at the end when there was no theme table.
theme_join() {
  awk -v block="$2" '
    function put(   line) { while ((getline line < block) > 0) print line; close(block) }
    $0 == "@@FM_THEME@@" { put(); done = 1; next }
    { print }
    END { if (!done) put() }
  ' "$1" > "$3"
}

# The [theme] tables of a shipped theme file, without its leading comments.
shipped_block() {  # <file> <out>
  awk '/^[[:space:]]*\[[[:space:]]*theme[[:space:]]*\]/ { on = 1 } on' "$1" > "$2"
}

same_block() {  # <a> <b>: equal apart from blank lines
  [ "$(grep -v '^[[:space:]]*$' "$1")" = "$(grep -v '^[[:space:]]*$' "$2")" ]
}

herdr_step() {  # light|dark
  local herdr tmp
  herdr=$(herdr_bin)
  if ! command -v "$herdr" >/dev/null 2>&1; then
    say "Herdr: not installed; skipped"
    return 0
  fi
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-theme.XXXXXX") || { fail "Herdr: no temporary directory"; return 0; }
  herdr_switch "$1" "$herdr" "$tmp"
  rm -rf "$tmp"
}

herdr_switch() {  # light|dark <herdr> <temporary directory>
  local mode=$1 herdr=$2 tmp=$3 out
  if [ -f "$HERDR_CONFIG" ]; then
    theme_split "$HERDR_CONFIG" "$tmp/keep" "$tmp/current" || { fail "Herdr: could not read $HERDR_CONFIG"; return 0; }
  else
    : > "$tmp/keep"
    : > "$tmp/current"
  fi
  shipped_block "$THEMES/herdr-light.toml" "$tmp/light"
  if [ "$mode" = light ]; then
    if [ -s "$tmp/current" ] && [ "$(remembered)" != light ] && ! same_block "$tmp/current" "$tmp/light"; then
      { mkdir -p "$SAVED" && cp "$tmp/current" "$SAVED/herdr-dark.toml"; } \
        || { fail "Herdr: could not save the dark theme in $SAVED"; return 0; }
    fi
    cp "$tmp/light" "$tmp/block"
  elif [ -s "$SAVED/herdr-dark.toml" ]; then
    cp "$SAVED/herdr-dark.toml" "$tmp/block"
  else
    say "Herdr: no dark theme is saved from a switch to light; config.toml left as it is"
    return 0
  fi
  if [ -f "$HERDR_CONFIG" ] && same_block "$tmp/current" "$tmp/block"; then
    say "Herdr: already $mode"
  else
    theme_join "$tmp/keep" "$tmp/block" "$tmp/new"
    out=$(HERDR_CONFIG_PATH="$tmp/new" "$herdr" config check 2>&1) \
      || { fail "Herdr: the $mode theme did not pass herdr config check, so config.toml is unchanged: $(printf '%s' "$out" | tr '\n' ' ')"; return 0; }
    mkdir -p "$SAVED" "$(dirname "$HERDR_CONFIG")" || { fail "Herdr: could not create $SAVED"; return 0; }
    [ ! -f "$HERDR_CONFIG" ] || cp "$HERDR_CONFIG" "$SAVED/herdr-config.before.toml" \
      || { fail "Herdr: could not keep a copy of $HERDR_CONFIG"; return 0; }
    cat "$tmp/new" > "$HERDR_CONFIG" || { fail "Herdr: could not write $HERDR_CONFIG"; return 0; }
    say "Herdr: $mode theme written to $HERDR_CONFIG"
  fi
  if out=$("$herdr" server reload-config 2>&1); then
    say "Herdr: the running workspace reloaded it"
  else
    say "Herdr: no running workspace took the reload ($(printf '%s' "$out" | tail -n 1)); it starts in $mode"
  fi
}

# --- the panes and the memory -------------------------------------------------

remember_step() {  # light|dark
  write_atomic "$CHOICE_FILE" "$1" || { fail "could not remember $1 in $CHOICE_FILE"; return 0; }
  say "Bridge strip and Factory pane: $1 (they repaint within a second)"
  case "${FM_TERMINAL_THEME:-}" in
    light|dark) [ "$FM_TERMINAL_THEME" = "$1" ] \
      || say "Note: FM_TERMINAL_THEME=$FM_TERMINAL_THEME is set here, and it wins over the switch in panes started with it" ;;
  esac
}

claude_line() {  # light|dark
  if [ "$1" = light ]; then
    say "Chat: type /theme in each Claude Code chat and choose Light mode."
  else
    say "Chat: type /theme in each Claude Code chat and choose Dark mode."
  fi
}

cmd_switch() {  # light|dark
  terminal_step "$1"
  herdr_step "$1"
  remember_step "$1"
  claude_line "$1"
  return "$FAILED"
}

cmd_status() {
  local choice cream answer tmp
  choice=$(remembered)
  [ -n "$choice" ] || choice="nothing yet (panes follow the terminal background)"
  say "Remembered: $choice"
  case "${FM_TERMINAL_THEME:-}" in
    light|dark) say "Note: FM_TERMINAL_THEME=$FM_TERMINAL_THEME is set here and wins in panes started with it" ;;
  esac
  if have_osa; then
    cream=$(cream_name)
    if answer=$(osa "$TERMINAL_QUERY" "$cream" 2>/dev/null); then
      if [ "$answer" = not-running ]; then
        say "Terminal: not open"
      else
        say "Terminal: new windows use ${answer%%$'\t'*}"
      fi
    else
      say "Terminal: could not be asked"
    fi
  else
    say "Terminal: not on this computer"
  fi
  if [ ! -f "$HERDR_CONFIG" ]; then
    say "Herdr: no config at $HERDR_CONFIG"
  else
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-theme.XXXXXX") || return 1
    theme_split "$HERDR_CONFIG" "$tmp/keep" "$tmp/current"
    shipped_block "$THEMES/herdr-light.toml" "$tmp/light"
    if same_block "$tmp/current" "$tmp/light"; then
      say "Herdr: light theme in config.toml"
    elif [ -s "$SAVED/herdr-dark.toml" ] && same_block "$tmp/current" "$SAVED/herdr-dark.toml"; then
      say "Herdr: dark theme in config.toml"
    else
      say "Herdr: a theme of its own in config.toml"
    fi
    rm -rf "$tmp"
  fi
}

[ "$#" -eq 1 ] || { usage; exit 2; }
case "$1" in
  light|dark) cmd_switch "$1"; exit $? ;;
  status) cmd_status ;;
  terminal-profile) [ "$(remembered)" != light ] || cream_name ;;
  -h|--help) usage ;;
  *) usage; exit 2 ;;
esac
