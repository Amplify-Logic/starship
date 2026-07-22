#!/usr/bin/env bash
# Focused behavior coverage for the guarded primary profile launcher.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-primary)
HOME_FIX="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/cli.log"
KIMI_SOURCE="$TMP_ROOT/kimi-source"
mkdir -p "$HOME_FIX/state" "$HOME_FIX/data" "$KIMI_SOURCE/plugins"
printf 'model = "kimi-code/k3"\n' > "$KIMI_SOURCE/config.toml"
printf 'theme = "dark"\n' > "$KIMI_SOURCE/tui.toml"
printf 'secret-material\n' > "$KIMI_SOURCE/credentials"
printf '{"version":1,"plugins":[{"id":"operator-plugin","root":"/safe/operator-plugin","enabled":true}]}\n' \
  > "$KIMI_SOURCE/plugins/installed.json"

make_cli() { # <name>
  cat > "$FAKEBIN/$1" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ] && [ "$(basename "$0")" = kimi ]; then
  printf '%s\n' "${FM_PRIMARY_TEST_KIMI_VERSION:-0.27.0}"
  exit 0
fi
if [ "${1:-}" = --version ] && [ "$(basename "$0")" = agent ]; then
  printf '%s\n' "${FM_PRIMARY_TEST_CURSOR_VERSION:-2026.07.20-8cc9c0b}"
  exit 0
fi
if [ "${1:-}" = doctor ] && [ "$(basename "$0")" = kimi ]; then
  printf 'doctor KIMI_CODE_HOME=%s\n' "${KIMI_CODE_HOME:-}" >> "$FM_PRIMARY_TEST_LOG"
  exit "${FM_PRIMARY_TEST_DOCTOR_EXIT:-0}"
fi
printf 'cli=%s\n' "$(basename "$0")" >> "$FM_PRIMARY_TEST_LOG"
printf 'pwd=%s\n' "$PWD" >> "$FM_PRIMARY_TEST_LOG"
printf 'harness=%s\n' "${FM_PRIMARY_HARNESS:-}" >> "$FM_PRIMARY_TEST_LOG"
printf 'role=%s\n' "${FM_PRIMARY_ROLE:-}" >> "$FM_PRIMARY_TEST_LOG"
printf 'kimi_home=%s\n' "${KIMI_CODE_HOME:-}" >> "$FM_PRIMARY_TEST_LOG"
printf 'opencode_permissions=%s\n' "${OPENCODE_CONFIG_CONTENT:-}" >> "$FM_PRIMARY_TEST_LOG"
printf 'argv=' >> "$FM_PRIMARY_TEST_LOG"
printf '<%s>' "$@" >> "$FM_PRIMARY_TEST_LOG"
printf '\n' >> "$FM_PRIMARY_TEST_LOG"
exit "${FM_PRIMARY_TEST_EXIT:-0}"
SH
  chmod +x "$FAKEBIN/$1"
}
for cli in pi claude codex opencode grok kimi agent herdr tmux; do make_cli "$cli"; done

dry() { # <profile>
  ( cd "$TMP_ROOT" && \
    PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_DRY_RUN=1 \
    FM_PRIMARY_TEST_LOG="$LOG" \
    FM_KIMI_SOURCE_HOME="$KIMI_SOURCE" \
    "$ROOT/bin/fm-primary.sh" "$1" )
}

test_profiles_and_root() {
  local out help
  help=$("$ROOT/bin/fm-primary.sh" --help)
  assert_contains "$help" 'claude-fable' "help omitted the Claude Fable profile"
  assert_contains "$help" 'kimi-k3' "help omitted the Kimi K3 profile"
  assert_contains "$help" 'cursor-grok' "help omitted the Cursor Grok profile"
  assert_contains "$help" 'Aliases: claude -> claude-fable; kimi -> kimi-k3; cursor -> cursor-grok.' "help omitted exact alias ownership"
  assert_contains "$help" 'Pi has no permission system' "help did not explain Pi's no-bypass posture"
  out=$(dry pi)
  assert_contains "$out" "root=$ROOT" "Pi profile did not resolve the tracked root from another cwd"
  assert_contains "$out" "'pi' '--name' 'FIRSTMATE'" "Pi profile argv is wrong"
  assert_not_contains "$out" 'permission' "Pi profile invented a permission bypass"

  out=$(dry claude-fable)
  assert_contains "$out" "'claude' '--model' 'claude-fable-5' '--effort' 'high' '--name' 'FIRSTMATE' '--dangerously-skip-permissions'" \
    "Claude Fable profile did not pin model, effort, role, and bypass"
  [ "$(dry claude)" = "$out" ] || fail "Claude alias did not expand exactly to claude-fable"

  out=$(dry codex)
  assert_contains "$out" "'codex' '--dangerously-bypass-hook-trust' '--dangerously-bypass-approvals-and-sandbox'" \
    "Codex profile lost its verified full bypass flags"
  out=$(dry opencode)
  assert_contains "$out" "'opencode'" "OpenCode verified primary profile is missing"
  out=$(dry grok)
  assert_contains "$out" "'grok' '--permission-mode' 'bypassPermissions'" "Grok verified primary bypass is wrong"
  out=$(dry cursor-grok)
  assert_contains "$out" "'agent' '--yolo' '--model' 'cursor-grok-4.5-high'" \
    "Cursor Grok profile did not pin yolo and the high-tier model id"
  [ "$(dry cursor)" = "$out" ] || fail "Cursor alias did not expand exactly to cursor-grok"
  pass "fm-primary: profiles expand exact flags and always launch from the tracked root"
}

test_unknown_dependency_and_integration_refusals() {
  local status=0 out mini="$TMP_ROOT/mini"
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FIX" "$ROOT/bin/fm-primary.sh" mystery 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "unknown profile was accepted"
  assert_contains "$out" 'unknown or unverified primary profile' "unknown profile refusal was unclear"

  mkdir -p "$mini/bin" "$mini-home/state" "$mini-home/data"
  cp "$ROOT/bin/fm-primary.sh" "$ROOT/bin/fm-lock.sh" "$mini/bin/"
  status=0
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$mini-home" FM_PRIMARY_DRY_RUN=1 "$mini/bin/fm-primary.sh" pi 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "profile launched without its tracked integration"
  assert_contains "$out" 'missing tracked primary integration' "missing-integration refusal was unclear"

  mv "$FAKEBIN/grok" "$FAKEBIN/grok.hidden"
  status=0
  out=$(PATH="$FAKEBIN:/usr/bin:/bin" FM_HOME="$HOME_FIX" FM_PRIMARY_DRY_RUN=1 "$ROOT/bin/fm-primary.sh" grok 2>&1) || status=$?
  mv "$FAKEBIN/grok.hidden" "$FAKEBIN/grok"
  [ "$status" -ne 0 ] || fail "profile launched without its CLI dependency"
  assert_contains "$out" "requires 'grok' on PATH" "missing dependency refusal was unclear"
  pass "fm-primary: unknown profiles, missing CLIs, and missing integrations fail closed"
}

test_active_lock_refusal() {
  local pid status=0 out
  bash -c 'while :; do sleep 5; done' codex-primary &
  pid=$!
  printf '%s\n' "$pid" > "$HOME_FIX/state/.lock"
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FIX" FM_PRIMARY_DRY_RUN=1 "$ROOT/bin/fm-primary.sh" pi 2>&1) || status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -f "$HOME_FIX/state/.lock"
  [ "$status" -ne 0 ] || fail "launcher stole an active Firstmate lock"
  assert_contains "$out" 'another Firstmate session is active' "active-session refusal was unclear"
  pass "fm-primary: a live Firstmate lock is refused without killing or replacing it"
}

test_exec_environment_and_exit_status() {
  local status=0 out
  : > "$LOG"
  ( cd "$TMP_ROOT" && \
    env -u HERDR_ENV -u HERDR_SESSION -u HERDR_PANE_ID -u TMUX_PANE \
      PATH="$FAKEBIN:$PATH" \
      TERM=dumb \
      FM_HOME="$HOME_FIX" \
      FM_PRIMARY_TEST_LOG="$LOG" \
      FM_PRIMARY_TEST_EXIT=37 \
      "$ROOT/bin/fm-primary.sh" pi ) || status=$?
  [ "$status" -eq 37 ] || fail "launcher did not return the launched CLI exit status (got $status)"
  out=$(cat "$LOG")
  assert_contains "$out" "pwd=$ROOT" "launched CLI did not run at the tracked Starship root"
  assert_contains "$out" 'harness=pi' "launched CLI did not inherit the stable primary marker"
  assert_contains "$out" 'role=FIRSTMATE' "launched CLI did not inherit the visible role"
  pass "fm-primary: exec preserves root, stable child marker, role, and CLI exit status"
}

test_visible_role_marks_only_current_surface() {
  local out
  : > "$LOG"
  PATH="$FAKEBIN:$PATH" \
    TERM=dumb \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_TEST_LOG="$LOG" \
    HERDR_ENV=1 \
    HERDR_SESSION=default \
    HERDR_PANE_ID=w9:p4 \
    "$ROOT/bin/fm-primary.sh" pi
  out=$(cat "$LOG")
  assert_contains "$out" 'argv=<pane><report-metadata><w9:p4>' \
    "Herdr role marker did not target the current pane"
  assert_contains "$out" '<--title><FIRSTMATE · WAITING>' \
    "Herdr role marker omitted the visible Firstmate role"
  assert_not_contains "$out" '<workspace>' "Herdr role marker renamed a workspace"
  assert_not_contains "$out" '<tab>' "Herdr role marker renamed a tab"

  : > "$LOG"
  env -u HERDR_ENV -u HERDR_SESSION -u HERDR_PANE_ID \
    PATH="$FAKEBIN:$PATH" \
    TERM=dumb \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_TEST_LOG="$LOG" \
    TMUX_PANE=%42 \
    "$ROOT/bin/fm-primary.sh" pi
  out=$(cat "$LOG")
  assert_contains "$out" 'argv=<rename-window><-t><%42><FIRSTMATE · WAITING>' \
    "tmux role marker did not target only the current pane's window"
  assert_not_contains "$out" '<rename-session>' "tmux role marker renamed the session"
  pass "fm-primary: visible role metadata is scoped to the current pane or window"
}

test_shim_install_safety() {
  local shimdir="$TMP_ROOT/shims" chain="$TMP_ROOT/relative-chain" out status=0
  out=$(FM_PRIMARY_SHIM_DIR="$shimdir" "$ROOT/bin/fm-primary.sh" --install-shim)
  [ -L "$shimdir/firstmate" ] || fail "opt-in shim was not installed"
  [ "$(readlink "$shimdir/firstmate")" = "$ROOT/bin/fm-primary.sh" ] || fail "shim target is wrong"
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FIX" FM_PRIMARY_DRY_RUN=1 \
    FM_PRIMARY_TEST_LOG="$LOG" FM_KIMI_SOURCE_HOME="$KIMI_SOURCE" "$shimdir/firstmate" kimi)
  assert_contains "$out" "root=$ROOT" "installed shim did not launch from the tracked root"
  assert_contains "$out" 'profile=kimi-k3' "installed shim did not expand the Kimi alias"
  assert_contains "$out" "'kimi' '--model' 'kimi-code/k3' '--yolo'" \
    "installed shim did not reach the Kimi primary launch path"
  mkdir -p "$chain"
  ln -s "../$(basename "$shimdir")/firstmate" "$chain/firstmate"
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FIX" FM_PRIMARY_DRY_RUN=1 "$chain/firstmate" pi)
  assert_contains "$out" "root=$ROOT" "relative chained shim did not resolve the tracked root"
  assert_contains "$(FM_PRIMARY_SHIM_DIR="$shimdir" "$shimdir/firstmate" --install-shim)" 'already installed' \
    "exact shim reinstall through the installed command was not idempotent"
  rm "$shimdir/firstmate"
  printf 'unrelated\n' > "$shimdir/firstmate"
  out=$(FM_PRIMARY_SHIM_DIR="$shimdir" "$ROOT/bin/fm-primary.sh" --install-shim 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "shim installer replaced an unrelated file"
  assert_contains "$out" 'refusing to replace an existing file' "unrelated-file refusal was unclear"
  rm "$shimdir/firstmate"
  ln -s /tmp/unrelated "$shimdir/firstmate"
  status=0
  out=$(FM_PRIMARY_SHIM_DIR="$shimdir" "$ROOT/bin/fm-primary.sh" --install-shim 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "shim installer replaced a different symlink"
  assert_contains "$out" 'refusing to replace a different symlink' "different-symlink refusal was unclear"
  pass "fm-primary: opt-in shim is idempotent only for the exact safe symlink"
}

test_kimi_primary_only_profile() {
  local out source_before source_after managed="$HOME_FIX/data/primary/kimi-k3"
  source_before=$(shasum "$KIMI_SOURCE/config.toml" "$KIMI_SOURCE/tui.toml" "$KIMI_SOURCE/credentials" "$KIMI_SOURCE/plugins/installed.json")
  out=$(dry kimi-k3)
  assert_contains "$out" "'kimi' '--model' 'kimi-code/k3' '--yolo'" "Kimi profile did not pin K3 with automatic approval"
  [ "$(dry kimi)" = "$out" ] || fail "Kimi alias did not expand exactly to kimi-k3"
  source_after=$(shasum "$KIMI_SOURCE/config.toml" "$KIMI_SOURCE/tui.toml" "$KIMI_SOURCE/credentials" "$KIMI_SOURCE/plugins/installed.json")
  [ "$source_before" = "$source_after" ] || fail "Kimi preparation modified the source home"
  assert_grep 'sessionStart' "$managed/plugins/managed/firstmate-primary/kimi.plugin.json" \
    "managed Kimi plugin lacks native session-start context injection"
  assert_grep 'PreToolUse' "$managed/plugins/managed/firstmate-primary/kimi.plugin.json" \
    "managed Kimi plugin lacks blockable pre-tool hooks"
  assert_grep '"event": "Stop"' "$managed/plugins/managed/firstmate-primary/kimi.plugin.json" \
    "managed Kimi plugin lacks the no-blind-stop backstop"
  assert_grep 'fm-session-start.sh' "$managed/plugins/managed/firstmate-primary/skills/firstmate-session-start/SKILL.md" \
    "managed Kimi plugin nudge does not enter model context"
  jq -e '.plugins | map(.id) | contains(["operator-plugin", "firstmate-primary"])' \
    "$managed/plugins/installed.json" >/dev/null 2>&1 \
    || fail "managed Kimi registry did not preserve the operator's existing plugins"
  assert_not_contains "$(sed -n '1,90p' "$ROOT/bin/fm-spawn.sh")" 'claude|codex|opencode|pi|grok|kimi' \
    "primary-only Kimi accidentally entered fm-spawn's verified worker set"
  pass "fm-primary: Kimi is pinned, isolated, lifecycle-integrated, and remains primary-only"
}

test_kimi_tmux_companion_status_bar() {
  local out
  : > "$LOG"
  env -u HERDR_ENV -u HERDR_SESSION -u HERDR_PANE_ID \
    PATH="$FAKEBIN:$PATH" \
    TERM=dumb \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_TEST_LOG="$LOG" \
    FM_KIMI_SOURCE_HOME="$KIMI_SOURCE" \
    TMUX_PANE=%42 \
    "$ROOT/bin/fm-primary.sh" kimi-k3
  out=$(cat "$LOG")
  assert_contains "$out" 'argv=<split-window><-d><-v><-l><1><-t><%42>' \
    "Kimi primary did not add a detached one-row tmux companion"
  assert_contains "$out" "$ROOT/bin/fm-status-bar.sh" \
    "Kimi tmux companion does not invoke the canonical status renderer"
  assert_contains "$out" '--adapter kimi' "Kimi tmux companion omitted its adapter"
  assert_contains "$out" '--model kimi-code/k3' "Kimi tmux companion omitted the pinned model"
  assert_contains "$out" '--effort --' "Kimi tmux companion did not preserve unavailable effort"
  assert_contains "$out" "--follow-pane '%42'" "Kimi tmux companion does not follow the primary pane"
  pass "fm-primary: Kimi gets a scoped tmux companion without replacing native controls"
}

test_kimi_version_doctor_and_symlink_refusals() {
  local out rc=0 unsafe_home="$TMP_ROOT/unsafe-home" sentinel="$TMP_ROOT/sentinel-config"
  out=$(PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_DRY_RUN=1 \
    FM_PRIMARY_TEST_LOG="$LOG" \
    FM_PRIMARY_TEST_KIMI_VERSION=0.28.0 \
    FM_KIMI_SOURCE_HOME="$KIMI_SOURCE" \
    "$ROOT/bin/fm-primary.sh" kimi-k3 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "unverified Kimi version was accepted"
  assert_contains "$out" 'verified only for 0.27.0; found 0.28.0' "Kimi version refusal was unclear"

  rc=0
  out=$(PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_DRY_RUN=1 \
    FM_PRIMARY_TEST_LOG="$LOG" \
    FM_PRIMARY_TEST_DOCTOR_EXIT=9 \
    FM_KIMI_SOURCE_HOME="$KIMI_SOURCE" \
    "$ROOT/bin/fm-primary.sh" kimi-k3 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "Kimi launched after its managed doctor check failed"
  assert_contains "$out" "failed 'kimi doctor'" "Kimi doctor refusal was unclear"

  mkdir -p "$unsafe_home/state" "$unsafe_home/data/primary/kimi-k3"
  printf 'do-not-overwrite\n' > "$sentinel"
  ln -s "$sentinel" "$unsafe_home/data/primary/kimi-k3/config.toml"
  rc=0
  out=$(PATH="$FAKEBIN:$PATH" \
    FM_HOME="$unsafe_home" \
    FM_PRIMARY_DRY_RUN=1 \
    FM_PRIMARY_TEST_LOG="$LOG" \
    FM_KIMI_SOURCE_HOME="$KIMI_SOURCE" \
    "$ROOT/bin/fm-primary.sh" kimi-k3 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "managed Kimi setup followed an unrelated config symlink"
  assert_contains "$out" 'managed Kimi integration file is an unrelated symlink' \
    "managed Kimi symlink refusal was unclear"
  [ "$(cat "$sentinel")" = 'do-not-overwrite' ] || fail "managed Kimi setup overwrote the symlink target"
  pass "fm-primary: Kimi version, doctor, and managed-path checks fail closed"
}

test_kimi_corrupt_source_registry_atomicity() {
  local out rc=0 home="$TMP_ROOT/kimi-atomic-home" source="$TMP_ROOT/kimi-atomic-source"
  local managed="$home/data/primary/kimi-k3" before leftovers
  mkdir -p "$home/state" "$home/data" "$source/plugins"
  cp "$KIMI_SOURCE/config.toml" "$source/config.toml"
  printf '{"version":1,"plugins":[{"id":"operator-plugin","root":"/safe/operator-plugin","enabled":true}]}\n' \
    > "$source/plugins/installed.json"
  ( cd "$TMP_ROOT" && \
    PATH="$FAKEBIN:$PATH" \
    FM_HOME="$home" \
    FM_PRIMARY_DRY_RUN=1 \
    FM_PRIMARY_TEST_LOG="$LOG" \
    FM_KIMI_SOURCE_HOME="$source" \
    "$ROOT/bin/fm-primary.sh" kimi-k3 >/dev/null ) || fail "valid source Kimi registry did not merge"
  before=$(cat "$managed/plugins/installed.json")
  printf '{"version":1,"plugins":[' > "$source/plugins/installed.json"
  out=$( cd "$TMP_ROOT" && \
    PATH="$FAKEBIN:$PATH" \
    FM_HOME="$home" \
    FM_PRIMARY_DRY_RUN=1 \
    FM_PRIMARY_TEST_LOG="$LOG" \
    FM_KIMI_SOURCE_HOME="$source" \
    "$ROOT/bin/fm-primary.sh" kimi-k3 2>&1 ) || rc=$?
  [ "$rc" -ne 0 ] || fail "corrupt source Kimi registry was accepted"
  assert_contains "$out" 'could not merge the source and managed Kimi plugin registries' \
    "corrupt source registry refusal was unclear"
  [ "$(cat "$managed/plugins/installed.json")" = "$before" ] \
    || fail "corrupt source registry merge clobbered the prior managed registry"
  leftovers=$(find "$managed/plugins" -name '.installed.*' -o -name '.manifest.*')
  [ -z "$leftovers" ] || fail "failed Kimi registry merge leaked temporary files: $leftovers"
  pass "fm-primary: a corrupt source Kimi registry fails closed and leaves no temp files"
}

test_lab_role_guard() {
  local out status=0
  out=$(PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_DRY_RUN=1 \
    FM_PRIMARY_VISIBLE_PREFIX=LAB \
    HERDR_ENV=1 \
    HERDR_SESSION=fm-lab-primary \
    FM_KIMI_SOURCE_HOME="$KIMI_SOURCE" \
    "$ROOT/bin/fm-primary.sh" kimi-k3)
  assert_contains "$out" 'role=LAB · PRIMARY' "lab primary was not visibly LAB-prefixed"
  assert_not_contains "$out" 'role=FIRSTMATE' "lab primary inherited the captain-facing role"
  out=$(PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_DRY_RUN=1 \
    FM_PRIMARY_VISIBLE_PREFIX=LAB \
    HERDR_ENV=1 \
    HERDR_SESSION=default \
    FM_KIMI_SOURCE_HOME="$KIMI_SOURCE" \
    "$ROOT/bin/fm-primary.sh" kimi-k3 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "LAB role was accepted in the default Herdr session"
  assert_contains "$out" 'requires a named fm-lab-* Herdr session, never default' \
    "default-session LAB refusal was unclear"
  pass "fm-primary: LAB role cannot appear as FIRSTMATE or run in default Herdr"
}

test_cursor_grok_primary_profile() {
  local out status=0
  out=$(dry cursor-grok)
  assert_contains "$out" "profile=cursor-grok" "Cursor dry-run omitted profile"
  assert_contains "$out" "'agent' '--yolo' '--model' 'cursor-grok-4.5-high'" \
    "Cursor primary argv is wrong"
  assert_not_contains "$out" 'status-bar' "Cursor primary invented a status-bar install"
  : > "$LOG"
  ( cd "$TMP_ROOT" && \
    env -u HERDR_ENV -u HERDR_SESSION -u HERDR_PANE_ID -u TMUX_PANE \
      PATH="$FAKEBIN:$PATH" \
      TERM=dumb \
      FM_HOME="$HOME_FIX" \
      FM_PRIMARY_TEST_LOG="$LOG" \
      "$ROOT/bin/fm-primary.sh" cursor-grok )
  out=$(cat "$LOG")
  assert_contains "$out" 'cli=agent' "Cursor primary did not exec agent"
  assert_contains "$out" 'harness=cursor' "Cursor primary did not export FM_PRIMARY_HARNESS=cursor"
  assert_contains "$out" 'argv=<--yolo><--model><cursor-grok-4.5-high>' \
    "Cursor primary lost yolo or the high model id"
  status=0
  out=$(PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_DRY_RUN=1 \
    FM_PRIMARY_TEST_CURSOR_VERSION=2026.07.16-899851b \
    "$ROOT/bin/fm-primary.sh" cursor-grok 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "unverified Cursor CLI version was accepted"
  assert_contains "$out" 'verified only for 2026.07.20-8cc9c0b; found 2026.07.16-899851b' \
    "Cursor version refusal was unclear"
  pass "fm-primary: Cursor Grok is pinned, lifecycle-integrated, and version-gated"
}

test_profiles_and_root
test_unknown_dependency_and_integration_refusals
test_active_lock_refusal
test_exec_environment_and_exit_status
test_visible_role_marks_only_current_surface
test_shim_install_safety
test_kimi_primary_only_profile
test_kimi_tmux_companion_status_bar
test_kimi_version_doctor_and_symlink_refusals
test_kimi_corrupt_source_registry_atomicity
test_lab_role_guard
test_cursor_grok_primary_profile
