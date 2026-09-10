#!/usr/bin/env bash
# Behavior tests for the portable Baby Menu quota widget: the installer's effect
# on a Baby Menu home, and the widget modules that must not misread a provider.
#
# These tests never touch a real Baby Menu home, never start or stop the app, and
# never read a credential. Every install runs against a temporary home built here.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALL="$ROOT/bin/fm-install-baby-menu-quota.sh"
ASSETS="$ROOT/assets/baby-menu/weekly-quota"
WIDGET_FILES="components.tsx local-settings.ts quota-windows.ts server.ts store.ts widget.tsx"

assert_present "$INSTALL" "bin/fm-install-baby-menu-quota.sh is missing"
[ -x "$INSTALL" ] || fail "fm-install-baby-menu-quota.sh must be executable"
assert_present "$ASSETS" "assets/baby-menu/weekly-quota is missing"

# A Baby Menu home with an unrelated extension and the app's own files already in
# it, so an install can be shown to leave them alone.
make_home() {
  local root=$1 home="$1/baby-menu-home"
  mkdir -p "$home/extensions/some-other-widget" "$home/cache"
  printf 'export const other = 1;\n' >"$home/extensions/some-other-widget/widget.tsx"
  printf '{"theme":"dark"}\n' >"$home/preferences.json"
  printf 'not-a-real-database\n' >"$home/baby-menu.db"
  printf '%s\n' "$home"
}

test_install_places_every_widget_file() {
  local root home out file
  root=$(fm_test_tmproot fm-bm-install)
  home=$(make_home "$root")

  out=$("$INSTALL" --home "$home" 2>&1)
  expect_code 0 $? "install into a fresh home"
  assert_contains "$out" "installed the quota widget" "install must report what it installed"

  for file in $WIDGET_FILES; do
    assert_present "$home/extensions/weekly-quota/$file" "install must place $file"
    cmp -s "$ASSETS/$file" "$home/extensions/weekly-quota/$file" \
      || fail "installed $file must match the tracked source byte for byte"
  done
  pass "install places every tracked widget file into the home"
}

test_install_preserves_unrelated_extensions_and_app_files() {
  local root home
  root=$(fm_test_tmproot fm-bm-preserve)
  home=$(make_home "$root")

  "$INSTALL" --home "$home" >/dev/null 2>&1 || fail "install failed"

  assert_grep 'export const other = 1;' "$home/extensions/some-other-widget/widget.tsx" \
    "install must leave an unrelated extension untouched"
  assert_grep '"theme":"dark"' "$home/preferences.json" \
    "install must leave app preferences untouched"
  assert_grep 'not-a-real-database' "$home/baby-menu.db" \
    "install must leave the app database untouched"
  pass "install leaves unrelated extensions, preferences, and the database alone"
}

test_second_run_is_safe_and_keeps_local_settings() {
  local root home out
  root=$(fm_test_tmproot fm-bm-rerun)
  home=$(make_home "$root")

  "$INSTALL" --home "$home" >/dev/null 2>&1 || fail "first install failed"
  printf '{"claudeTeamConfigDir":"/opt/example/seat"}\n' >"$home/weekly-quota.local.json"

  out=$("$INSTALL" --home "$home" 2>&1)
  expect_code 0 $? "second install run"
  assert_contains "$out" "already matches" "an unchanged second run must be a no-op"
  assert_grep '/opt/example/seat' "$home/weekly-quota.local.json" \
    "a second run must never overwrite the machine's own settings file"

  # No backup copy is left behind when nothing needed replacing.
  local backups
  backups=$(find "$home/extensions" -maxdepth 1 -name '.weekly-quota-backup-*' | wc -l | tr -d ' ')
  [ "$backups" = "0" ] || fail "an unchanged second run must not create a backup"
  pass "a second run changes nothing and preserves machine-local settings"
}

test_replacing_a_modified_widget_keeps_the_previous_copy() {
  local root home backup
  root=$(fm_test_tmproot fm-bm-backup)
  home=$(make_home "$root")

  "$INSTALL" --home "$home" >/dev/null 2>&1 || fail "first install failed"
  printf '// locally edited\n' >>"$home/extensions/weekly-quota/store.ts"
  "$INSTALL" --home "$home" >/dev/null 2>&1 || fail "reinstall failed"

  backup=$(find "$home/extensions" -maxdepth 1 -name '.weekly-quota-backup-*' | head -1)
  [ -n "$backup" ] || fail "replacing a modified widget must keep the previous copy"
  assert_grep '// locally edited' "$backup/store.ts" "the backup must hold the replaced content"
  assert_no_grep '// locally edited' "$home/extensions/weekly-quota/store.ts" \
    "the reinstalled widget must be the tracked source"
  pass "replacing a modified widget keeps the previous copy beside it"
}

test_repeated_replacements_keep_separate_backups() {
  local root home count nested
  root=$(fm_test_tmproot fm-bm-backups)
  home=$(make_home "$root")

  # Two replacements in quick succession: a backup name with one-second
  # resolution would put the second copy inside the first while the script
  # reported the top level, so the earlier edit would not be where it says.
  "$INSTALL" --home "$home" >/dev/null 2>&1 || fail "first install failed"
  printf '// first local edit\n' >>"$home/extensions/weekly-quota/store.ts"
  "$INSTALL" --home "$home" >/dev/null 2>&1 || fail "first reinstall failed"
  printf '// second local edit\n' >>"$home/extensions/weekly-quota/store.ts"
  "$INSTALL" --home "$home" >/dev/null 2>&1 || fail "second reinstall failed"

  count=$(find "$home/extensions" -maxdepth 1 -type d -name '.weekly-quota-backup-*' | wc -l | tr -d ' ')
  [ "$count" = "2" ] || fail "two replacing installs must keep two separate backups, found $count"
  nested=$(find "$home/extensions" -maxdepth 1 -type d -name '.weekly-quota-backup-*' \
    -exec test -e '{}/weekly-quota' \; -print)
  [ -z "$nested" ] || fail "a backup must never be nested inside another backup: $nested"
  grep -rq -e '// first local edit' "$home/extensions"/.weekly-quota-backup-* \
    || fail "the first replaced copy must be recoverable from its own backup"
  grep -rq -e '// second local edit' "$home/extensions"/.weekly-quota-backup-* \
    || fail "the second replaced copy must be recoverable from its own backup"
  pass "each replacing install keeps its own backup beside the widget"
}

test_example_settings_written_only_when_the_real_file_is_absent() {
  local root home
  root=$(fm_test_tmproot fm-bm-example)
  home=$(make_home "$root")

  "$INSTALL" --home "$home" >/dev/null 2>&1 || fail "install failed"
  assert_present "$home/weekly-quota.local.example.json" "install must seed an example settings file"
  assert_absent "$home/weekly-quota.local.json" "install must never write the real settings file"
  assert_no_grep '/Users/' "$home/weekly-quota.local.example.json" \
    "the example settings file must not carry any machine's real path"
  pass "install seeds an example settings file and never the real one"
}

test_missing_home_is_refused_rather_than_created() {
  local root out status
  root=$(fm_test_tmproot fm-bm-missing)

  out=$("$INSTALL" --home "$root/never-created" 2>&1) && status=0 || status=$?
  expect_code 1 "$status" "install into a missing home"
  assert_contains "$out" "does not exist" "a missing home must be reported, not created"
  assert_absent "$root/never-created" "install must not create a home it was pointed at by mistake"
  pass "a mistyped home is refused instead of silently created"
}

test_dry_run_writes_nothing() {
  local root home out
  root=$(fm_test_tmproot fm-bm-dry)
  home=$(make_home "$root")

  out=$("$INSTALL" --home "$home" --dry-run 2>&1)
  expect_code 0 $? "dry run"
  assert_contains "$out" "would install" "dry run must report the intended install"
  assert_absent "$home/extensions/weekly-quota" "dry run must not install anything"
  assert_absent "$home/weekly-quota.local.example.json" "dry run must not write the example file"
  pass "dry run reports without writing"
}

test_tracked_sources_carry_no_machine_identity() {
  local hit
  # The whole point of the tracked copy: a second machine can use it as-is, and
  # publishing it leaks nothing about the machine it came from.
  hit=$(grep -rEl '/Users/|/home/[a-z]|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$ASSETS" || true)
  [ -z "$hit" ] || fail "tracked widget sources must carry no machine path or address: $hit"
  hit=$(grep -rEli 'sk-[a-z0-9]{16}|Bearer [A-Za-z0-9]{16}' "$ASSETS" || true)
  [ -z "$hit" ] || fail "tracked widget sources must carry no literal credential: $hit"
  pass "tracked widget sources carry no machine path, address, or credential"
}

# --- widget module behavior --------------------------------------------------

node_check() {
  local script=$1 root out
  root=$(fm_test_tmproot fm-bm-node)
  printf '%s' "$script" >"$root/check.mjs"
  out=$(cd "$root" && node "$root/check.mjs" 2>&1) || fail "node check failed: $out"
  printf '%s\n' "$out"
}

# These checks import the tracked .ts modules directly, which relies on Node
# stripping the type annotations at load time; older builds refuse the .ts
# extension outright. The capability is probed by importing a throwaway module
# rather than by comparing versions, and a runtime without it skips these checks
# instead of failing them - no CI image pins the Node version here. Nothing is
# compiled or installed either way.
node_imports_typescript() {
  local root
  command -v node >/dev/null 2>&1 || return 1
  root=$(fm_test_tmproot fm-bm-node-probe)
  printf 'export const probe: string = "type-stripping-ok";\n' >"$root/probe.ts"
  printf 'import { probe } from "./probe.ts";\nconsole.log(probe);\n' >"$root/probe.mjs"
  [ "$(cd "$root" && node "$root/probe.mjs" 2>/dev/null)" = "type-stripping-ok" ]
}

test_codex_windows_are_classified_by_identity_not_position() {
  node_imports_typescript || {
    echo "skip: node cannot import TypeScript modules on this build"
    return 0
  }

  local out
  out=$(node_check "
import { classifyCodexWindows } from '$ASSETS/quota-windows.ts';
const labels = (windows) => classifyCodexWindows(windows).map((w) => w.label + ':' + String(Math.round(w.percentUsed)));

// A plan that publishes only its weekly window. Reading position instead of
// identity labelled this 'SESSION' with a multi-day countdown.
console.log('lone-weekly=' + labels([{ used_percent: 3, limit_window_seconds: 604800, reset_at: 1788000000 }]).join(','));
// The ordinary two-window response, and the same response with the keys swapped.
console.log('both=' + labels([
  { used_percent: 14, limit_window_seconds: 18000 },
  { used_percent: 51, limit_window_seconds: 604800 },
]).join(','));
console.log('both-swapped=' + labels([
  { used_percent: 51, limit_window_seconds: 604800 },
  { used_percent: 14, limit_window_seconds: 18000 },
]).join(','));
// A lone five-hour window must not be promoted to the weekly one either.
console.log('lone-session=' + labels([{ used_percent: 40, limit_window_seconds: 18000 }]).join(','));
// Unfamiliar and undeclared lengths stay honest instead of being forced.
console.log('unknown=' + labels([
  { used_percent: 9, limit_window_seconds: 86400 },
  { used_percent: 20 },
]).join(','));
// Two windows of the same length: only one can be the weekly one.
console.log('duplicate=' + labels([
  { used_percent: 5, limit_window_seconds: 604800 },
  { used_percent: 6, limit_window_seconds: 604800 },
]).join(','));
// A window that declares no length but names itself is still identified.
console.log('named=' + labels([{ used_percent: 7, name: 'weekly' }]).join(','));
// A declared length the widget does not recognise keeps its own honest label: a
// name substring must not relabel a window as one whose length it does not have.
console.log('declared-wins=' + labels([
  { used_percent: 11, limit_window_seconds: 86400, name: 'weekly_rollover' },
]).join(','));
// Two windows of the same unrecognised length are two allowances, so they must
// not collapse onto one id and one row key.
const unknownIds = classifyCodexWindows([
  { used_percent: 4, limit_window_seconds: 86400 },
  { used_percent: 8, limit_window_seconds: 86400 },
]).map((w) => w.id);
console.log('unique-ids=' + String(new Set(unknownIds).size) + '/' + String(unknownIds.length));
")

  assert_contains "$out" "lone-weekly=WEEKLY:3" "a lone weekly window must not be labelled SESSION"
  assert_contains "$out" "both=SESSION:14,WEEKLY:51" "both windows must keep their own identity"
  assert_contains "$out" "both-swapped=SESSION:14,WEEKLY:51" "classification must not depend on response order"
  assert_contains "$out" "lone-session=SESSION:40" "a lone five-hour window must stay SESSION"
  assert_contains "$out" "unknown=1D WINDOW:9,WINDOW (LENGTH UNKNOWN):20" \
    "an unfamiliar or undeclared window length must be reported honestly"
  assert_contains "$out" "duplicate=WEEKLY:5,7D WINDOW:6" \
    "two windows of the same length must not both claim that window"
  assert_contains "$out" "named=WEEKLY:7" "a window naming itself must be identified by that name"
  assert_contains "$out" "declared-wins=1D WINDOW:11" \
    "a declared length must outrank a name substring that claims another window"
  assert_contains "$out" "unique-ids=2/2" \
    "two windows of the same unrecognised length must not share one id"
  pass "Codex windows are classified by declared length or name, never by position"
}

test_window_identity_is_shared_by_every_reader() {
  node_imports_typescript || {
    echo "skip: node cannot import TypeScript modules on this build"
    return 0
  }

  local out
  out=$(node_check "
import {
  declaresCredits,
  describeDuration,
  durationSeconds,
  identifyByDeclaredUnit,
  identifyByDuration,
  identifyUnclaimed,
} from '$ASSETS/quota-windows.ts';
const show = (i) => i.id + '/' + i.label + '/' + String(i.recognized);
const identity = (seconds) => show(identifyByDuration(seconds));
const declared = (duration, timeUnit) => show(identifyByDeclaredUnit(duration, timeUnit));

// The Kimi five-hour limit as the provider states it: 300 MINUTE. Named from
// that declared length, never from where the limit sat in the response.
console.log('kimi-session=' + String(durationSeconds(300, 'MINUTE')) + '|' + identity(durationSeconds(300, 'MINUTE')));
// The same length however the unit is spelled, and a weekly limit stated in days.
console.log('units=' + [
  durationSeconds(300, 'MINUTES'),
  durationSeconds(300, 'TIME_UNIT_MINUTE'),
  durationSeconds(5, 'HOUR'),
  durationSeconds(7, 'DAYS'),
  durationSeconds(1, 'WEEK'),
].join(','));
// A unit with no fixed length, and one this module does not model, stay unknown
// rather than being mistaken for a unit it does model.
console.log('not-fixed=' + [
  String(durationSeconds(1, 'MONTH')),
  String(durationSeconds(1, 'YEAR')),
  String(durationSeconds(500, 'MILLISECONDS')),
  String(durationSeconds(0, 'MINUTE')),
].join(','));
// A declared length that is not a known allowance keeps its own honest name.
console.log('unfamiliar=' + identity(86400));
// A row that states its length as a count and a unit is named from that. A row
// that states no usable length is unknown in every response - the Kimi account
// rollup carries no duration, so it must never read as a week it was not told
// about, whatever else the response contained.
console.log('declared=' + [
  declared(300, 'MINUTE'),
  declared(7, 'DAYS'),
  declared(1, 'MONTH'),
  declared(undefined, undefined),
  declared(3, undefined),
].join('|'));
// A known name is spent once per read: a second window of that length is
// described by its own length instead of taking the name a second time.
console.log('contended=' + [
  show(identifyUnclaimed(identifyByDeclaredUnit(7, 'DAYS'), new Set(['weekly']))),
  show(identifyUnclaimed(identifyByDeclaredUnit(7, 'DAYS'), new Set())),
  show(identifyUnclaimed(identifyByDeclaredUnit(undefined, undefined), new Set(['window_unknown']))),
].join('|'));
// Credits are money and are refused whichever field the reader states them in.
// A label is display text, so the word only counts there when it stands alone: a
// real allowance that merely mentions credits keeps its row rather than vanishing
// with no row and no error.
console.log('credits=' + [
  declaresCredits({ structural: ['credits'] }),
  declaresCredits({ structural: [undefined, 'credit_balance'] }),
  declaresCredits({ display: ['Credits remaining'] }),
  declaresCredits({ structural: [undefined, 'included_credits'], display: ['INCLUDED'] }),
  declaresCredits({ structural: [undefined, 'five_hour'], display: ['SESSION (credit-backed)'] }),
  declaresCredits({ structural: [undefined, 'five_hour'], display: ['SESSION'] }),
  declaresCredits({ structural: [undefined, 'monthly_allowance'] }),
  declaresCredits({}),
].join(','));
console.log('describe=' + [describeDuration(18000), describeDuration(604800)].join('|'));
")

  assert_contains "$out" "kimi-session=18000|five_hour/SESSION/true" \
    "a 300 MINUTE limit must be named from its declared length"
  assert_contains "$out" "units=18000,18000,18000,604800,604800" \
    "a declared length must convert the same however its unit is spelled"
  assert_contains "$out" "not-fixed=null,null,null,null" \
    "a unit with no fixed length must stay unknown rather than be assumed"
  assert_contains "$out" "unfamiliar=window_86400s/1D WINDOW/false" \
    "an unfamiliar declared length must keep its own label and say it is unknown"
  assert_contains "$out" \
    "declared=five_hour/SESSION/true|weekly/WEEKLY/true|window_unknown/WINDOW (LENGTH UNKNOWN)/false|window_unknown/WINDOW (LENGTH UNKNOWN)/false|window_unknown/WINDOW (LENGTH UNKNOWN)/false" \
    "a row states its own length or is unknown, never named by what accompanied it"
  assert_contains "$out" \
    "contended=window_604800s/7D WINDOW/false|weekly/WEEKLY/true|window_unknown/WINDOW (LENGTH UNKNOWN)/false" \
    "a known name must be spent once per read, and an unknown row must not contend"
  assert_contains "$out" "credits=true,true,true,true,false,false,false,false" \
    "credits must be refused when stated, and display text must not drop an allowance"
  assert_contains "$out" "describe=5H WINDOW|7D WINDOW" "a duration must describe itself"
  pass "window identity comes from the declared length, and credits are not an allowance"
}

test_second_seat_is_machine_local_and_optional() {
  node_imports_typescript || {
    echo "skip: node cannot import TypeScript modules on this build"
    return 0
  }

  local out
  out=$(node_check "
import { readLocalSettings, localSettingsPath } from '$ASSETS/local-settings.ts';
const read = (files) => (p) => (p in files ? files[p] : null);

// No settings file: no second seat, and no error.
const none = readLocalSettings({ env: {}, homeDir: '/home/example', readTextFile: () => null });
console.log('none=' + String(none.claudeTeamConfigDir));
// A settings file under the machine's own Baby Menu home.
const p = localSettingsPath({}, '/home/example');
console.log('path=' + p);
const set = readLocalSettings({
  env: {},
  homeDir: '/home/example',
  readTextFile: read({ [p]: JSON.stringify({ claudeTeamConfigDir: '/opt/seat', claudeTeamSeatLabel: 'work' }) }),
});
console.log('configured=' + String(set.claudeTeamConfigDir) + '|' + set.claudeTeamSeatLabel);
// The environment wins over the file.
console.log('env=' + String(readLocalSettings({
  env: { BABY_MENU_CLAUDE_TEAM_CONFIG_DIR: '/opt/from-env' },
  homeDir: '/home/example',
  readTextFile: read({ [p]: JSON.stringify({ claudeTeamConfigDir: '/opt/seat' }) }),
}).claudeTeamConfigDir));
// Junk must not take the panel down, and a relative path is not trusted.
console.log('broken=' + String(readLocalSettings({ env: {}, homeDir: '/home/example', readTextFile: read({ [p]: 'not json' }) }).claudeTeamConfigDir));
console.log('relative=' + String(readLocalSettings({
  env: {},
  homeDir: '/home/example',
  readTextFile: read({ [p]: JSON.stringify({ claudeTeamConfigDir: 'relative/seat' }) }),
}).claudeTeamConfigDir));
// BABY_MENU_HOME relocates the settings file.
console.log('relocated=' + localSettingsPath({ BABY_MENU_HOME: '/opt/bm' }, '/home/example'));
")

  assert_contains "$out" "none=undefined" "an unconfigured machine must report no second seat"
  assert_contains "$out" "path=/home/example/.baby-menu/weekly-quota.local.json" \
    "the settings file must live in the machine's own Baby Menu home"
  assert_contains "$out" "configured=/opt/seat|WORK" "a configured seat and its label must be read back"
  assert_contains "$out" "env=/opt/from-env" "the environment must override the settings file"
  assert_contains "$out" "broken=undefined" "a malformed settings file must not break the panel"
  assert_contains "$out" "relative=undefined" "a relative path must not be trusted as a config dir"
  assert_contains "$out" "relocated=/opt/bm/weekly-quota.local.json" \
    "BABY_MENU_HOME must relocate the settings file"
  pass "the second Claude seat is optional, machine-local, and honestly absent"
}

test_typescript_modules_parse() {
  command -v node >/dev/null 2>&1 || { echo "skip: node not found for widget module checks"; return 0; }
  # A build check the app would otherwise be the first to make. Node's type
  # stripper parses TypeScript but not JSX, so this covers the .ts modules; the
  # two .tsx files are carried unmodified from a source the app already compiles.
  local out
  out=$(node -e '
const { stripTypeScriptTypes } = require("node:module");
const fs = require("node:fs");
const dir = process.argv[1];
let failed = 0;
for (const file of ["server.ts", "store.ts", "quota-windows.ts", "local-settings.ts"]) {
  try {
    stripTypeScriptTypes(fs.readFileSync(dir + "/" + file, "utf8"), { mode: "strip" });
  } catch (error) {
    console.log("PARSE FAIL " + file + ": " + error.message);
    failed = 1;
  }
}
if (failed === 0) console.log("PARSE OK");
' "$ASSETS" 2>/dev/null) || { echo "skip: node cannot strip TypeScript types on this build"; return 0; }
  case "$out" in
    *"PARSE OK"*) : ;;
    *) fail "tracked widget TypeScript must parse: $out" ;;
  esac
  pass "the tracked TypeScript modules parse"
}

test_install_places_every_widget_file
test_install_preserves_unrelated_extensions_and_app_files
test_second_run_is_safe_and_keeps_local_settings
test_replacing_a_modified_widget_keeps_the_previous_copy
test_repeated_replacements_keep_separate_backups
test_example_settings_written_only_when_the_real_file_is_absent
test_missing_home_is_refused_rather_than_created
test_dry_run_writes_nothing
test_tracked_sources_carry_no_machine_identity
test_typescript_modules_parse
test_codex_windows_are_classified_by_identity_not_position
test_window_identity_is_shared_by_every_reader
test_second_seat_is_machine_local_and_optional
