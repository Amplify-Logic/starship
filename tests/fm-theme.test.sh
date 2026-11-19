#!/usr/bin/env bash
# The workspace theme switch: bin/fm-theme.sh.
#
# A fake Terminal (an AppleScript runner that keeps its profiles, default and
# tabs in files), a fake `open` that imports a profile file the way Terminal
# does, and a fake herdr that records reloads stand in for the real ones, so
# no Terminal window, Herdr config or Herdr server is touched. Herdr's config
# is a fixture copy given through HERDR_CONFIG_PATH.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-theme)
BINDIR="$TMP_ROOT/bin"
mkdir -p "$BINDIR"
THEME="$ROOT/bin/fm-theme.sh"
CREAM='Starship Cream'
DARK='Night Deck'

# The fake Terminal. State, under $FM_THEME_TEST_TERMINAL:
#   running   present while Terminal is open
#   profiles  one profile name per line
#   default startup   the default and startup profile names
#   tabs      <window id> TAB <profile> TAB <font size>, one tab per line
#   fonts     <profile> TAB <font name> TAB <font size>
cat > "$BINDIR/osascript" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = - ] || exit 2
shift
T=$FM_THEME_TEST_TERMINAL
script=$(cat)
printf '%s\n' "$*" >> "$T/calls"
has() { grep -qxF -- "$1" "$T/profiles"; }
case "$script" in
  *'is running'*)
    [ -e "$T/running" ] || { echo not-running; exit 0; }
    if has "$1"; then c=true; else c=false; fi
    printf '%s\t%s\n' "$(cat "$T/default")" "$c" ;;
  *'close w'*)
    cream=$1; shift
    has "$cream" || { echo "Terminal did not add the profile $cream" >&2; exit 1; }
    awk -F '\t' -v cream="$cream" -v known=" $* " '
      index(known, " " $1 " ") || $2 != cream' "$T/tabs" > "$T/tabs.new" && mv "$T/tabs.new" "$T/tabs" ;;
  *'id of w'*)
    cut -f1 "$T/tabs" | sort -u ;;
  *'font name'*)
    from=$(awk -F '\t' -v p="$1" '$1 == p { print $2 "\t" $3 }' "$T/fonts")
    [ -z "$from" ] || printf '%s\t%s\n' "$2" "$from" >> "$T/fonts" ;;
  *'set moved'*)
    has "$2" || { echo "Terminal has no profile named $2" >&2; exit 1; }
    awk -F '\t' -v OFS='\t' -v from="$1" -v to="$2" '$2 == from { $2 = to; n++ } { print } END { print n + 0 > "/dev/stderr" }' \
      "$T/tabs" > "$T/tabs.new" 2> "$T/moved" && mv "$T/tabs.new" "$T/tabs"
    for f in default startup; do [ "$(cat "$T/$f")" != "$1" ] || printf '%s\n' "$2" > "$T/$f"; done
    cat "$T/moved" ;;
  *) echo "unknown script" >&2; exit 3 ;;
esac
SH
# The fake `open`: Terminal adds a profile named after the file and opens a
# window in it.
cat > "$BINDIR/open" <<'SH'
#!/usr/bin/env bash
T=$FM_THEME_TEST_TERMINAL
printf 'open %s\n' "$*" >> "$T/calls"
[ "$1" = -g ] && shift
name=${1##*/}
name=${name%.terminal}
printf '%s\n' "$name" >> "$T/profiles"
printf '9999\t%s\t11\n' "$name" >> "$T/tabs"
SH
cat > "$BINDIR/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_THEME_TEST_HERDR_CALLS"
case "$1 $2" in
  'plugin config-dir')
    [ -n "${FM_THEME_TEST_PLUGINS:-}" ] || exit 1
    echo "$FM_THEME_TEST_PLUGINS/$3" ;;
  'config check')
    [ -z "${FM_THEME_TEST_CHECK_FAILS:-}" ] || { echo "config: issues found"; exit 1; }
    grep -q '^\[theme\]' "$HERDR_CONFIG_PATH" || exit 1
    echo "config: ok" ;;
  'server reload-config')
    [ -z "${FM_THEME_TEST_NO_SERVER:-}" ] || { echo '{"error":"no server"}' >&2; exit 1; }
    echo ok ;;
  *) exit 2 ;;
esac
SH
chmod +x "$BINDIR/osascript" "$BINDIR/open" "$BINDIR/herdr"

CASE=0
reset_case() {
  CASE=$((CASE + 1))
  HOME_FIX="$TMP_ROOT/case$CASE/home"
  T="$TMP_ROOT/case$CASE/terminal"
  HCONF="$TMP_ROOT/case$CASE/herdr/config.toml"
  mkdir -p "$HOME_FIX" "$T" "${HCONF%/*}"
  : > "$T/calls"
  : > "$TMP_ROOT/case$CASE/herdr-calls"
  touch "$T/running"
  printf '%s\nBasic\n' "$DARK" > "$T/profiles"
  printf '%s\n' "$DARK" > "$T/default"
  printf '%s\n' "$DARK" > "$T/startup"
  printf '101\t%s\t13\n102\t%s\t10\n103\tBasic\t12\n' "$DARK" "$DARK" > "$T/tabs"
  printf '%s\tB612Mono-Regular\t10\n' "$DARK" > "$T/fonts"
  # The owner's config: settings around a theme of his own.
  cat > "$HCONF" <<'TOML'
onboarding = false
[ui]
sidebar_start_collapsed = true

[theme]
name = "tokyo-night"
# his own colours
[theme.custom]
accent = "#123456"
text   = "#abcdef"

[ui.sound]
enabled = false
TOML
  cp "$HCONF" "$TMP_ROOT/case$CASE/original.toml"
}

theme() {
  FM_HOME="$HOME_FIX" HERDR_BIN_PATH="$BINDIR/herdr" HERDR_CONFIG_PATH="$HCONF" \
    FM_THEME_OSASCRIPT="${FM_THEME_OSASCRIPT-$BINDIR/osascript}" FM_THEME_OPEN="$BINDIR/open -g" \
    FM_THEME_TEST_TERMINAL="$T" FM_THEME_TEST_HERDR_CALLS="$TMP_ROOT/case$CASE/herdr-calls" \
    bash "$THEME" "$@"
}

assert_eq() { [ "$1" = "$2" ] || fail "$3: expected [$2], got [$1]"; }
assert_has() { case "$1" in *"$2"*) ;; *) fail "$3: [$2] not in [$1]" ;; esac; }
assert_lacks() { case "$1" in *"$2"*) fail "$3: [$2] in [$1]" ;; esac; }

test_light_and_back_to_dark() {
  local out
  reset_case
  out=$(theme light) || fail "light failed: $out"
  # Terminal: the cream profile was imported once, its window closed, and every
  # dark tab moved across keeping its size; other profiles were left alone.
  assert_eq "$(grep -c '^open ' "$T/calls")" 1 "the cream profile was not imported exactly once"
  assert_has "$(cat "$T/calls")" "$HOME_FIX/data/workspace-theme/Starship Cream.terminal" "the cream profile file was not opened"
  python3 -c 'import plistlib, sys; d = plistlib.load(open(sys.argv[1], "rb")); assert d["name"] == "Starship Cream" and len(d) == 23, sorted(d)' \
    "$HOME_FIX/data/workspace-theme/Starship Cream.terminal" || fail "the cream profile file is not a Terminal profile"
  assert_eq "$(cat "$T/tabs")" "$(printf '101\t%s\t13\n102\t%s\t10\n103\tBasic\t12' "$CREAM" "$CREAM")" "Terminal tabs after light"
  assert_eq "$(cat "$T/default") $(cat "$T/startup")" "$CREAM $CREAM" "new Terminal windows do not open in cream"
  assert_has "$(cat "$T/fonts")" "$CREAM	B612Mono-Regular	10" "the cream profile did not get the dark profile's font"
  # Herdr: the theme tables are the cream ones; every other line is as it was.
  assert_has "$(cat "$HCONF")" 'panel_bg      = "#ece4d4"' "Herdr config has no cream theme"
  assert_lacks "$(cat "$HCONF")" '#123456' "Herdr config kept the dark colours"
  assert_eq "$(grep -v -e '^\[theme' -e '^[a-z_0-9]* *=.*#' -e '^#' -e '^$' -e '^name' -e '^auto_switch' "$HCONF")" \
    "$(printf 'onboarding = false\n[ui]\nsidebar_start_collapsed = true\n[ui.sound]\nenabled = false')" "Herdr settings outside the theme changed"
  assert_has "$(cat "$TMP_ROOT/case$CASE/herdr-calls")" 'server reload-config' "Herdr was not reloaded"
  # The choice is remembered for the panes, new panes and the desk's views.
  assert_eq "$(cat "$HOME_FIX/config/workspace-theme")" light "light was not remembered"
  assert_eq "$(theme terminal-profile)" "$CREAM" "the desk would not open its views in cream"
  assert_has "$out" '/theme' "the chat line is missing"
  assert_has "$out" 'Light mode' "the chat line does not name the light theme"

  out=$(theme dark) || fail "dark failed: $out"
  assert_eq "$(cat "$T/tabs")" "$(printf '101\t%s\t13\n102\t%s\t10\n103\tBasic\t12' "$DARK" "$DARK")" "Terminal tabs after dark"
  assert_eq "$(cat "$T/default") $(cat "$T/startup")" "$DARK $DARK" "new Terminal windows do not open in the dark profile"
  cmp -s "$HCONF" "$TMP_ROOT/case$CASE/original.toml" || fail "dark did not give back Herdr's config exactly: $(diff "$TMP_ROOT/case$CASE/original.toml" "$HCONF")"
  assert_eq "$(cat "$HOME_FIX/config/workspace-theme")" dark "dark was not remembered"
  assert_eq "$(theme terminal-profile)" "" "the desk would still open views in cream"
  assert_has "$out" 'Dark mode' "the chat line does not name the dark theme"
  pass "theme: light moves Terminal, Herdr and the panes to cream, and dark gives back exactly what was there"
}

test_switching_twice_keeps_the_saved_dark_look() {
  local out
  reset_case
  theme light >/dev/null || fail "first light failed"
  out=$(theme light) || fail "second light failed: $out"
  assert_eq "$(grep -c '^open ' "$T/calls")" 1 "the cream profile was imported again"
  assert_has "$out" 'Herdr: already light' "a second light rewrote Herdr's config"
  theme dark >/dev/null || fail "dark failed"
  cmp -s "$HCONF" "$TMP_ROOT/case$CASE/original.toml" || fail "a second light lost the saved dark theme"
  assert_eq "$(cat "$T/default")" "$DARK" "a second light lost the dark Terminal profile"
  pass "theme: switching to light twice imports once and keeps the dark look to come back to"
}

test_a_theme_herdr_refuses_leaves_its_config_alone() {
  local out rc=0
  reset_case
  out=$(FM_THEME_TEST_CHECK_FAILS=1 theme light 2>&1) || rc=$?
  assert_eq "$rc" 1 "a refused Herdr theme did not fail the run"
  assert_has "$out" 'config.toml is unchanged' "the refusal is not explained"
  cmp -s "$HCONF" "$TMP_ROOT/case$CASE/original.toml" || fail "a refused theme was written anyway"
  assert_lacks "$(cat "$TMP_ROOT/case$CASE/herdr-calls")" 'reload-config' "Herdr was reloaded after a refusal"
  assert_eq "$(cat "$HOME_FIX/config/workspace-theme")" light "the other steps did not still run"
  assert_eq "$(cat "$T/default")" "$CREAM" "Terminal was not switched beside the refusal"
  pass "theme: a theme Herdr's own check refuses leaves config.toml as it was, and the rest still switches"
}

test_dark_with_nothing_saved_leaves_terminal_and_herdr_alone() {
  local out before
  reset_case
  before=$(cat "$T/tabs" "$T/default" "$T/startup")
  out=$(theme dark) || fail "dark failed: $out"
  cmp -s "$HCONF" "$TMP_ROOT/case$CASE/original.toml" || fail "dark with nothing saved changed Herdr's config"
  assert_lacks "$(cat "$TMP_ROOT/case$CASE/herdr-calls")" 'reload-config' "Herdr was reloaded with nothing written"
  assert_eq "$(cat "$T/tabs" "$T/default" "$T/startup")" "$before" "dark with nothing remembered changed Terminal"
  assert_has "$out" 'Terminal: no dark profile is remembered' "the untouched Terminal is not reported"
  assert_has "$out" 'Herdr: no dark theme is saved' "the untouched Herdr config is not reported"
  assert_has "$(theme status)" 'Herdr: a theme of its own' "status claims the owner's own theme is Starship's dark"
  out=$(FM_THEME_TEST_NO_SERVER=1 theme light) || fail "light without a Herdr server failed: $out"
  assert_has "$out" 'no running workspace took the reload' "a missing Herdr server is not reported"
  pass "theme: with nothing saved, dark leaves Terminal and Herdr as they are, and no Herdr server is not a failure"
}

test_status_changes_nothing() {
  local out before
  reset_case
  before=$(cat "$HCONF" "$T/tabs" "$T/default")
  out=$(theme status) || fail "status failed"
  assert_has "$out" 'Remembered: nothing yet' "status does not say nothing is remembered"
  assert_has "$out" "Terminal: new windows use $DARK" "status does not name Terminal's profile"
  assert_has "$out" 'Herdr: a theme of its own' "status does not read the owner's own Herdr theme"
  theme light >/dev/null
  out=$(theme status)
  assert_has "$out" 'Remembered: light' "status does not show the remembered choice"
  assert_has "$out" "Terminal: new windows use $CREAM" "status does not show the cream profile"
  assert_has "$out" 'Herdr: light theme' "status does not read the cream Herdr theme"
  theme dark >/dev/null
  assert_has "$(theme status)" 'Herdr: dark theme' "status does not recognise the saved dark theme"
  assert_eq "$(cat "$HCONF" "$T/tabs" "$T/default")" "$before" "status or the round trip changed something"
  pass "theme: status reports the choice, Terminal and Herdr without changing them"
}

test_missing_parts_are_skipped_not_failed() {
  local out
  reset_case
  rm "$T/running"
  out=$(theme light) || fail "Terminal not open failed the run: $out"
  assert_has "$out" 'Terminal: not open' "a closed Terminal is not reported"
  assert_eq "$(grep -c '^open ' "$T/calls")" 0 "a closed Terminal was opened"
  out=$(FM_THEME_OSASCRIPT='' theme dark) || fail "no Terminal failed the run: $out"
  assert_has "$out" 'Terminal: not on this computer' "a computer without Terminal is not reported"
  out=$(HERDR_BIN_PATH="$TMP_ROOT/no-herdr" FM_HOME="$HOME_FIX" HERDR_CONFIG_PATH="$HCONF" FM_THEME_OSASCRIPT='' \
    bash "$THEME" light) || fail "no Herdr failed the run: $out"
  assert_has "$out" 'Herdr: not installed' "a missing Herdr is not reported"
  assert_eq "$(cat "$HOME_FIX/config/workspace-theme")" light "the panes' choice was not remembered"
  pass "theme: a closed Terminal, no Terminal or no Herdr is reported and skipped"
}

# With no FM_HOME, the choice goes to the home the bridge strip was installed
# for (recorded by its install in Herdr's plugin config), which is where the
# strip and the Factory pane read it.
test_without_fm_home_the_installed_home_is_used() {
  local plugins out
  reset_case
  plugins="$TMP_ROOT/case$CASE/plugins"
  mkdir -p "$plugins/starship.bridge"
  printf '%s\n' "$HOME_FIX" > "$plugins/starship.bridge/home"
  out=$(env -u FM_HOME FM_THEME_TEST_PLUGINS="$plugins" HERDR_BIN_PATH="$BINDIR/herdr" HERDR_CONFIG_PATH="$HCONF" \
    FM_THEME_OSASCRIPT='' FM_THEME_TEST_HERDR_CALLS="$TMP_ROOT/case$CASE/herdr-calls" bash "$THEME" light) \
    || fail "light failed: $out"
  assert_eq "$(cat "$HOME_FIX/config/workspace-theme")" light "light was not remembered in the strip's installed home"
  out=$(env -u FM_HOME FM_THEME_TEST_PLUGINS="$plugins" HERDR_BIN_PATH="$BINDIR/herdr" FM_THEME_OSASCRIPT='' \
    HERDR_CONFIG_PATH="$HCONF" bash "$THEME" status)
  assert_has "$out" "Home: $HOME_FIX" "status does not name the home it read"
  assert_has "$out" 'Remembered: light' "status did not read the installed home"
  assert_eq "$(env -u FM_HOME FM_THEME_TEST_PLUGINS="$plugins" HERDR_BIN_PATH="$BINDIR/herdr" bash "$THEME" terminal-profile)" \
    "$CREAM" "the desk would not read the installed home"
  pass "theme: with no FM_HOME, the choice is kept in the home the bridge strip was installed for"
}

test_usage() {
  local rc=0
  theme sepia >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" 2 "an unknown theme is not a usage error"
  rc=0
  theme >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" 2 "no argument is not a usage error"
  pass "theme: an unknown or missing choice is a usage error"
}

fm_test_run \
  test_light_and_back_to_dark \
  test_switching_twice_keeps_the_saved_dark_look \
  test_a_theme_herdr_refuses_leaves_its_config_alone \
  test_dark_with_nothing_saved_leaves_terminal_and_herdr_alone \
  test_status_changes_nothing \
  test_missing_parts_are_skipped_not_failed \
  test_without_fm_home_the_installed_home_is_used \
  test_usage
