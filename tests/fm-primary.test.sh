#!/usr/bin/env bash
# Focused behavior coverage for the guarded primary profile launcher.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-primary)
HOME_FIX="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/cli.log"
mkdir -p "$HOME_FIX/state" "$HOME_FIX/data"

make_cli() { # <name>
  cat > "$FAKEBIN/$1" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ] && [ "$(basename "$0")" = agent ]; then
  printf '%s\n' "${FM_PRIMARY_TEST_CURSOR_VERSION:-2026.07.20-8cc9c0b}"
  exit 0
fi
if [ "${1:-}" = status ] && [ "$(basename "$0")" = agent ]; then
  printf '%s\n' "${FM_PRIMARY_TEST_CURSOR_STATUS:-✓ Logged in as exam@example.invalid}"
  exit 0
fi
if [ "${1:-}" = auth ] && [ "${2:-}" = status ] && [ "$(basename "$0")" = claude ]; then
  # Shape verified on claude 2.1.258: JSON on stdout either way, exit 0 logged
  # in and 1 logged out.
  if [ -n "${FM_PRIMARY_TEST_LOGGED_OUT:-}" ]; then
    printf '{\n  "loggedIn": false,\n  "authMethod": "none"\n}\n'
    exit 1
  fi
  printf '{\n  "loggedIn": true,\n  "email": "seat@example.invalid",\n  "orgId": "%s"\n}\n' \
    "${FM_PRIMARY_TEST_CLAUDE_ORG:-org-fake-0001}"
  exit 0
fi
if [ "${1:-}" = login ] && [ "${2:-}" = status ] && [ "$(basename "$0")" = codex ]; then
  # Matches codex-cli 0.144.6: the status lands on stderr with empty stdout and
  # a non-zero exit. An empty fixture stays a quiet, non-blocking probe.
  if [ -n "${FM_PRIMARY_TEST_CODEX_LOGIN_STATUS:-}" ]; then
    printf '%s\n' "$FM_PRIMARY_TEST_CODEX_LOGIN_STATUS" >&2
    exit 1
  fi
  exit 0
fi
printf 'cli=%s\n' "$(basename "$0")" >> "$FM_PRIMARY_TEST_LOG"
printf 'pwd=%s\n' "$PWD" >> "$FM_PRIMARY_TEST_LOG"
printf 'harness=%s\n' "${FM_PRIMARY_HARNESS:-}" >> "$FM_PRIMARY_TEST_LOG"
printf 'role=%s\n' "${FM_PRIMARY_ROLE:-}" >> "$FM_PRIMARY_TEST_LOG"
printf 'opencode_permissions=%s\n' "${OPENCODE_CONFIG_CONTENT:-}" >> "$FM_PRIMARY_TEST_LOG"
printf 'claude_bg_shell_pressure_reap=%s\n' "${CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP:-}" >> "$FM_PRIMARY_TEST_LOG"
printf 'claude_auto_compact_window=%s\n' "${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}" >> "$FM_PRIMARY_TEST_LOG"
printf 'argv=' >> "$FM_PRIMARY_TEST_LOG"
printf '<%s>' "$@" >> "$FM_PRIMARY_TEST_LOG"
printf '\n' >> "$FM_PRIMARY_TEST_LOG"
exit "${FM_PRIMARY_TEST_EXIT:-0}"
SH
  chmod +x "$FAKEBIN/$1"
}
for cli in pi claude codex opencode grok agent herdr tmux; do make_cli "$cli"; done

strip_ansi() {
  sed $'s/\033\\[[0-9;?]*[a-zA-Z]//g'
}

dry() { # <profile> [<args>...]
  ( cd "$TMP_ROOT" && \
    env -u CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP \
    -u CLAUDE_CODE_AUTO_COMPACT_WINDOW \
    PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_DRY_RUN=1 \
    FM_PRIMARY_TEST_LOG="$LOG" \
    "$ROOT/bin/fm-primary.sh" "$@" )
}

# live: the same launcher with NO dry-run seam, so everything below the dry-run
# early exit runs - the credential gates included. The fake CLIs exec harmlessly
# and log to $LOG, so a launch that passes every gate simply ends there.
live() { # <profile> [<args>...]
  ( cd "$TMP_ROOT" && \
    PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_TEST_LOG="$LOG" \
    "$ROOT/bin/fm-primary.sh" "$@" )
}

test_profiles_and_root() {
  local out help
  help=$("$ROOT/bin/fm-primary.sh" --help)
  assert_contains "$help" 'claude-fable' "help omitted the Claude Fable profile"
  assert_contains "$help" 'claude-opus' "help omitted the Claude Opus profile"
  assert_contains "$help" 'CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP' "help omitted the Claude background-shell pressure-reap export"
  assert_contains "$help" 'cursor-grok' "help omitted the Cursor Grok profile"
  assert_contains "$help" 'astra' "help omitted the Astra profile"
  assert_contains "$help" 'opus -> claude-opus' "help omitted the Opus alias"
  assert_contains "$help" 'cursor-grok45' "help omitted the Cursor Grok 4.5 profile"
  assert_contains "$help" 'cursor -> cursor-grok.' "help omitted exact alias ownership"
  assert_contains "$help" 'There is no alias for cursor-grok45' \
    "help did not say the 4.5 profile is deliberately alias-free"
  assert_contains "$help" 'Pi has no permission system' "help did not explain Pi's no-bypass posture"
  out=$(dry pi)
  assert_contains "$out" "root=$ROOT" "Pi profile did not resolve the tracked root from another cwd"
  assert_contains "$out" "'pi' '--name' 'FIRSTMATE'" "Pi profile argv is wrong"
  assert_not_contains "$out" 'permission' "Pi profile invented a permission bypass"

  out=$(dry claude-fable)
  assert_contains "$out" "'claude' '--model' 'claude-fable-5-1' '--effort' 'xhigh' '--name' 'FIRSTMATE' '--dangerously-skip-permissions'" \
    "Claude Fable profile did not pin model, default effort, role, and bypass"
  assert_contains "$out" "CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP=1" \
    "Claude Fable dry-run omitted the background-shell pressure-reap disable"
  [ "$(dry claude)" = "$out" ] || fail "Claude alias did not expand exactly to claude-fable"
  out=$(dry pi)
  assert_not_contains "$out" "CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP" \
    "Pi dry-run leaked the Claude pressure-reap env line"

  out=$(dry claude-opus)
  assert_contains "$out" "'claude' '--model' 'claude-opus-5-5' '--effort' 'xhigh' '--name' 'FIRSTMATE' '--dangerously-skip-permissions'" \
    "Claude Opus profile did not pin model, default effort, role, and bypass"
  assert_contains "$out" "CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP=1" \
    "Claude Opus dry-run omitted the background-shell pressure-reap disable"
  [ "$(dry opus)" = "$out" ] || fail "Opus alias did not expand exactly to claude-opus"

  out=$(dry codex)
  assert_contains "$out" "'codex' '--dangerously-bypass-hook-trust' '--dangerously-bypass-approvals-and-sandbox'" \
    "Codex profile lost its verified full bypass flags"
  out=$(dry opencode)
  assert_contains "$out" "'opencode'" "OpenCode verified primary profile is missing"
  out=$(dry grok)
  assert_contains "$out" "'grok' '--permission-mode' 'bypassPermissions'" "Grok verified primary bypass is wrong"
  out=$(dry astra)
  assert_contains "$out" "'codex' '--model' 'gpt-6-astra' '-c' 'model_reasoning_effort=\"xhigh\"' '--dangerously-bypass-hook-trust' '--dangerously-bypass-approvals-and-sandbox'" \
    "Astra profile did not pin model, default effort, and Codex bypass flags"
  out=$(dry cursor-grok)
  assert_contains "$out" "'agent' '--yolo' '--model' 'cursor-grok-4.6-high'" \
    "Cursor Grok profile did not pin yolo and the high-tier model id"
  [ "$(dry cursor)" = "$out" ] || fail "Cursor alias did not expand exactly to cursor-grok"
  out=$(dry cursor-grok45)
  assert_contains "$out" "'agent' '--yolo' '--model' 'cursor-grok-4.5-high'" \
    "Cursor Grok 4.5 profile did not pin yolo and the 4.5 high-tier model id"
  pass "fm-primary: profiles expand exact flags and always launch from the tracked root"
}

test_unknown_dependency_and_integration_refusals() {
  local status=0 out mini="$TMP_ROOT/mini"
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FIX" "$ROOT/bin/fm-primary.sh" mystery 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "unknown profile was accepted"
  assert_contains "$out" 'unknown or unverified primary profile' "unknown profile refusal was unclear"

  mkdir -p "$mini/bin" "$mini-home/state" "$mini-home/data"
  cp "$ROOT/bin/fm-primary.sh" "$ROOT/bin/fm-lock.sh" "$mini/bin/"
  # The session-lock status read sources its libraries, so the mini root carries
  # them; only the tracked harness integration is missing.
  cp "$ROOT"/bin/fm-*-lib.sh "$mini/bin/"
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

# A launch links the home's switched-on opt-in skills into the launched root
# before the CLI starts, because the CLI lists skills only once, at start.
test_launch_links_switched_on_opt_in_skills_first() {
  local status=0 mini="$TMP_ROOT/optin" home="$TMP_ROOT/optin-home" out
  mkdir -p "$mini" "$home/state" "$home/data" "$home/config"
  cp -R "$ROOT/bin" "$ROOT/.agents" "$ROOT/.claude" "$ROOT/.pi" "$mini/"
  rm -f "$mini"/.agents/skills/adhd "$mini"/.agents/skills/macos-computer-use
  : > "$home/config/computer-use"
  : > "$LOG"
  ( cd "$TMP_ROOT" && \
    env -u HERDR_ENV -u HERDR_SESSION -u HERDR_PANE_ID -u TMUX_PANE \
      PATH="$FAKEBIN:$PATH" TERM=dumb FM_HOME="$home" FM_PRIMARY_TEST_LOG="$LOG" \
      "$mini/bin/fm-primary.sh" pi ) || status=$?
  [ "$status" -eq 0 ] || fail "the opt-in launch fixture failed (status $status)"
  out=$(cat "$LOG")
  assert_contains "$out" "pwd=$mini" "the opt-in launch fixture did not reach the CLI"
  assert_equals "../opt-in-skills/macos-computer-use" "$(readlink "$mini/.agents/skills/macos-computer-use")" \
    "a launch must link a switched-on opt-in skill before the CLI starts"
  [ ! -e "$mini/.agents/skills/adhd" ] || fail "a launch must not link a skill this home did not switch on"
  pass "fm-primary: a launch links the home's switched-on opt-in skills before the CLI starts"
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
    FM_PRIMARY_TEST_LOG="$LOG" "$shimdir/firstmate" cursor)
  assert_contains "$out" "root=$ROOT" "installed shim did not launch from the tracked root"
  assert_contains "$out" 'profile=cursor-grok' "installed shim did not expand the Cursor alias"
  assert_contains "$out" "'agent' '--yolo' '--model' 'cursor-grok-4.6-high'" \
    "installed shim did not reach the Cursor primary launch path"
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

test_kimi_primary_profile_is_removed() {
  local profile out status
  # The Kimi PRIMARY profile was removed; Kimi remains a worker adapter only.
  for profile in kimi kimi-k3; do
    status=0
    out=$(dry "$profile" 2>&1) || status=$?
    [ "$status" -ne 0 ] || fail "the removed Kimi primary profile '$profile' still launched"
    assert_contains "$out" "unknown or unverified primary profile '$profile'" \
      "the removed Kimi primary profile '$profile' was not refused as unknown"
  done
  pass "fm-primary: the removed Kimi primary profile refuses as unknown"
}

test_codex_tmux_companion_status_bar() {
  local out
  : > "$LOG"
  env -u HERDR_ENV -u HERDR_SESSION -u HERDR_PANE_ID \
    PATH="$FAKEBIN:$PATH" \
    TERM=dumb \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_TEST_LOG="$LOG" \
    TMUX_PANE=%42 \
    "$ROOT/bin/fm-primary.sh" codex
  out=$(cat "$LOG")
  assert_contains "$out" 'argv=<split-window><-d><-v><-l><1><-t><%42>' \
    "Codex primary did not add a detached one-row tmux companion"
  assert_contains "$out" "$ROOT/bin/fm-status-bar.sh" \
    "Codex tmux companion does not invoke the canonical status renderer"
  assert_contains "$out" '--adapter codex' "Codex tmux companion omitted its adapter"
  assert_contains "$out" '--model codex' "Codex tmux companion omitted its model"
  assert_contains "$out" '--effort --' "Codex tmux companion did not preserve unavailable effort"
  assert_contains "$out" "--follow-pane '%42'" "Codex tmux companion does not follow the primary pane"
  pass "fm-primary: Codex gets a scoped tmux companion without replacing native controls"
}

# The argv the launcher EMITS is not evidence that the companion runs: a command
# string can carry every expected token and still fail to parse. These two cases
# execute the constructed command exactly as the session provider would and
# require the canonical row to actually appear.
test_tmux_companion_command_renders_the_canonical_row() {
  local out="$TMP_ROOT/tmux-companion-out"
  : > "$out"
  cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  split-window)
    # The command string is the final argument, run exactly as tmux would.
    FM_STATUS_BAR_INTERVAL=0 bash -c "${!#}" >> "$FM_PRIMARY_TEST_COMPANION_OUT" 2>&1
    ;;
  display-message)
    count=0
    [ ! -f "$FM_PRIMARY_TEST_PANE_COUNT" ] || count=$(<"$FM_PRIMARY_TEST_PANE_COUNT")
    count=$((count + 1))
    printf '%s\n' "$count" > "$FM_PRIMARY_TEST_PANE_COUNT"
    [ "$count" -eq 1 ] || exit 1
    printf '%s\n' '%42'
    ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN/tmux"
  env -u HERDR_ENV -u HERDR_SESSION -u HERDR_PANE_ID \
    PATH="$FAKEBIN:$PATH" \
    TERM=dumb \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_TEST_LOG="$LOG" \
    FM_PRIMARY_TEST_COMPANION_OUT="$out" \
    FM_PRIMARY_TEST_PANE_COUNT="$TMP_ROOT/tmux-companion-count" \
    FM_CODEX_METRICS_ROLLOUT="$TMP_ROOT/no-rollout" \
    FM_ACCOUNT_NAME=Team \
    TMUX_PANE=%42 \
    "$ROOT/bin/fm-primary.sh" codex
  make_cli tmux
  assert_contains "$(strip_ansi < "$out")" '⚓ codex·-- [Team]' \
    "the constructed tmux companion command did not render the canonical row"
  pass "fm-primary: the tmux companion command the launcher builds actually renders"
}

test_herdr_chrome_hides_the_companion_only_on_an_uncrowded_tab() {
  local calls="$TMP_ROOT/chrome-calls" cmd="$TMP_ROOT/chrome-cmd" title="$TMP_ROOT/chrome-title"
  # make_cli replaces the shared fake, so it is written fresh before each launch.
  write_chrome_herdr_fake() {
    cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_PRIMARY_TEST_CHROME_CALLS"
if [ "${1:-}" = --session ]; then
  shift 2
fi
case "${1:-} ${2:-}" in
  "status --json")
    printf '{"client":{"protocol":%s}}\n' "${FM_PRIMARY_TEST_CHROME_PROTOCOL:-16}"
    exit 0
    ;;
esac
[ "${1:-}" = pane ] || exit 0
shift
case "${1:-}" in
  split) printf '{"result":{"pane":{"pane_id":"w1:p2"}}}\n' ;;
  run) printf '%s\n' "$3" >> "$FM_PRIMARY_TEST_CHROME_CMD" ;;
  layout)
    [ "${FM_PRIMARY_TEST_CHROME_LAYOUT:-ok}" = ok ] || exit 1
    printf '{"result":{"layout":{"panes":%s}}}\n' "$FM_PRIMARY_TEST_CHROME_PANES"
    ;;
  report-metadata)
    # Record what the capability probe published, so `pane get` can answer with
    # the stored title a real server would resolve for that pane.
    while [ "$#" -gt 1 ]; do
      if [ "$1" = --title ]; then
        printf '%s' "$2" > "$FM_PRIMARY_TEST_CHROME_TITLE"
        break
      fi
      shift
    done
    ;;
  get)
    stored=
    [ ! -f "$FM_PRIMARY_TEST_CHROME_TITLE" ] || stored=$(<"$FM_PRIMARY_TEST_CHROME_TITLE")
    case "${FM_PRIMARY_TEST_CHROME_READBACK:-match}" in
      mismatch) stored="a-different-title" ;;
      absent) stored= ;;
    esac
    printf '{"result":{"pane":{"pane_id":"w1:p1","title":"%s"}}}\n' "$stored"
    ;;
  zoom) ;;
esac
exit 0
SH
    chmod +x "$FAKEBIN/herdr"
  }

  launch_chrome_primary() {  # <panes json> [extra env assignments...]
    write_chrome_herdr_fake
    : > "$calls"; : > "$cmd"; rm -f "$title"
    local panes=$1
    shift
    env -u HERDR_ENV -u TMUX_PANE \
      PATH="$FAKEBIN:$PATH" TERM=dumb FM_HOME="$HOME_FIX" \
      FM_PRIMARY_TEST_LOG="$LOG" \
      FM_PRIMARY_TEST_CHROME_CALLS="$calls" \
      FM_PRIMARY_TEST_CHROME_CMD="$cmd" \
      FM_PRIMARY_TEST_CHROME_TITLE="$title" \
      FM_PRIMARY_TEST_CHROME_PANES="$panes" \
      HERDR_SESSION=fm-lab-status HERDR_PANE_ID=w1:p1 \
      "$@" \
      "$ROOT/bin/fm-primary.sh" codex
    make_cli herdr
  }

  # An uncrowded tab: the primary and the companion just created, nothing else.
  launch_chrome_primary '[{"pane_id":"w1:p1"},{"pane_id":"w1:p2"}]'

  # Nothing is hidden on a protocol number alone: the launcher publishes the row
  # to the primary's own border under chrome mode's source, with an expiry, and
  # reads it back before it trusts any of it.
  assert_contains "$(cat "$calls")" 'pane report-metadata w1:p1' \
    "the launcher never published a probe row, so it hid the companion on no evidence"
  assert_contains "$(cat "$calls")" '--source firstmate-primary-status-v1' \
    "the probe row must use chrome mode's own source, never the launcher's supervision record"
  assert_contains "$(cat "$calls")" '--ttl-ms' \
    "a probe row with no expiry would freeze on the border if no renderer followed it"
  assert_contains "$(cat "$calls")" 'pane get w1:p1' \
    "the launcher never read the published row back, so the store was never proven"

  assert_contains "$(cat "$cmd")" "--chrome-pane 'w1:p1'" \
    "the launcher did not hand the companion the primary pane to decorate"
  assert_contains "$(cat "$cmd")" "--chrome-role 'FM'" \
    "the launcher did not hand the companion a visible role marker"
  assert_contains "$(cat "$calls")" 'pane zoom w1:p1 --on' \
    "the launcher never hid the companion, so its empty rows are not reclaimed"
  [ "$(grep -c 'pane zoom' "$calls")" -eq 1 ] \
    || fail "the launcher must zoom exactly once; repeating it would fight a deliberate unzoom"
  # The renderer may only release a zoom this launcher actually applied.
  assert_contains "$(cat "$cmd")" '--chrome-zoomed' \
    "the launcher hid the companion without telling the renderer it owns that zoom"

  # A crowded tab: something else already shares it, and zooming would hide
  # that pane's live work, so the rows stay visible instead.
  launch_chrome_primary '[{"pane_id":"w1:p1"},{"pane_id":"w1:p2"},{"pane_id":"w1:p9"}]'

  assert_not_contains "$(cat "$calls")" 'pane zoom' \
    "the launcher hid a tab that already had a co-tenant pane, which would hide its live work"
  assert_contains "$(cat "$cmd")" "--chrome-pane 'w1:p1'" \
    "the border row must still be published on a crowded tab; only the zoom is withheld"
  assert_not_contains "$(cat "$cmd")" '--chrome-zoomed' \
    "the renderer was armed to release a zoom the launcher never applied"

  # A client that answers the protocol pre-filter but does not actually store
  # the row: the readback disagrees, so nothing is hidden at all and the
  # in-pane row stays the only surface, exactly as before chrome mode.
  launch_chrome_primary '[{"pane_id":"w1:p1"},{"pane_id":"w1:p2"}]' \
    FM_PRIMARY_TEST_CHROME_READBACK=mismatch
  assert_not_contains "$(cat "$calls")" 'pane zoom' \
    "the launcher hid the companion even though the border row did not read back"
  assert_not_contains "$(cat "$cmd")" '--chrome-pane' \
    "chrome mode stayed on for a client that never stored the published row"

  # Same for a client whose `pane layout` cannot be read: the pane count is the
  # other surface chrome mode depends on, so an unparseable answer is a refusal.
  launch_chrome_primary '[{"pane_id":"w1:p1"},{"pane_id":"w1:p2"}]' \
    FM_PRIMARY_TEST_CHROME_LAYOUT=broken
  assert_not_contains "$(cat "$calls")" 'pane zoom' \
    "the launcher hid the companion without a readable pane count"
  assert_not_contains "$(cat "$cmd")" '--chrome-pane' \
    "chrome mode stayed on for a client whose pane layout could not be read"

  # Below the protocol pre-filter nothing is even probed.
  launch_chrome_primary '[{"pane_id":"w1:p1"},{"pane_id":"w1:p2"}]' \
    FM_PRIMARY_TEST_CHROME_PROTOCOL=15
  assert_not_contains "$(cat "$calls")" 'pane report-metadata' \
    "the launcher probed a client below the presentation protocol floor"
  assert_not_contains "$(cat "$cmd")" '--chrome-pane' \
    "chrome mode stayed on below the presentation protocol floor"
  assert_contains "$(cat "$cmd")" '--follow-pane' \
    "the companion must still render its in-pane row when chrome mode is off"

  rm -f "$FAKEBIN/herdr"
  pass "fm-primary: the companion is hidden only on proven capability and an uncrowded tab, and the zoom is applied once"
}

test_herdr_launcher_keeps_its_own_fm_root() {
  # The launcher derives FM_ROOT from its own symlink-resolved script path and
  # then uses it for the tracked-integration checks, the status-bar path it
  # execs, the companion split's --cwd, and the cd before launching the agent.
  # A sourced library that re-derives FM_ROOT from FM_ROOT_OVERRIDE would
  # silently repoint every one of those at another tree.
  local out
  out=$(env -u HERDR_ENV -u TMUX_PANE -u HERDR_PANE_ID \
    PATH="$FAKEBIN:$PATH" TERM=dumb FM_HOME="$HOME_FIX" \
    FM_ROOT_OVERRIDE=/tmp/not-the-tracked-root \
    FM_PRIMARY_TEST_LOG="$LOG" \
    "$ROOT/bin/fm-primary.sh" codex 2>&1)

  assert_not_contains "$out" '/tmp/not-the-tracked-root' \
    "an ambient FM_ROOT_OVERRIDE displaced the launcher's own resolved root"
  pass "fm-primary: the launcher's own FM_ROOT survives an ambient FM_ROOT_OVERRIDE"
}

test_herdr_companion_command_renders_in_the_pane_the_split_created() {
  local out="$TMP_ROOT/herdr-companion-out"
  : > "$out"
  cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --session ] || exit 1
session=$2
shift 2
[ "${1:-}" = pane ] || exit 1
shift
case "${1:-}" in
  split)
    printf '{"result":{"type":"pane_info","pane":{"pane_id":"w1:p2"}}}\n'
    ;;
  layout)
    # A pre-existing co-tenant of the same tab. Selecting a pane from here
    # instead of from the split response would take over somebody else's row.
    printf '{"result":{"layout":{"panes":[{"pane_id":"w1:p1"},{"pane_id":"w1:p9"}]}}}\n'
    ;;
  run)
    printf 'run-target=%s\n' "$2" >> "$FM_PRIMARY_TEST_COMPANION_OUT"
    # A managed pane's environment does not carry HERDR_SESSION, so the
    # companion must have been handed the session it was launched from.
    env -u HERDR_SESSION FM_STATUS_BAR_INTERVAL=0 bash -c "$3" \
      >> "$FM_PRIMARY_TEST_COMPANION_OUT" 2>&1
    ;;
  get)
    # Liveness answers only within the session the primary launched from, so a
    # companion that re-derived 'default' resolves nothing and never renders.
    [ "$session" = "$FM_PRIMARY_TEST_HERDR_SESSION" ] || exit 1
    count=0
    [ ! -f "$FM_PRIMARY_TEST_PANE_COUNT" ] || count=$(<"$FM_PRIMARY_TEST_PANE_COUNT")
    count=$((count + 1))
    printf '%s\n' "$count" > "$FM_PRIMARY_TEST_PANE_COUNT"
    [ "$count" -eq 1 ] || { printf '{"result":{"pane":{}}}\n'; exit 0; }
    printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$2"
    ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN/herdr"
  env -u HERDR_ENV -u TMUX_PANE \
    PATH="$FAKEBIN:$PATH" \
    TERM=dumb \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_TEST_LOG="$LOG" \
    FM_PRIMARY_TEST_COMPANION_OUT="$out" \
    FM_PRIMARY_TEST_PANE_COUNT="$TMP_ROOT/herdr-companion-count" \
    FM_PRIMARY_TEST_HERDR_SESSION=fm-lab-status \
    HERDR_SESSION=fm-lab-status \
    HERDR_PANE_ID=w1:p1 \
    "$ROOT/bin/fm-primary.sh" codex
  make_cli herdr
  assert_contains "$(cat "$out")" 'run-target=w1:p2' \
    "the herdr companion did not run in the pane the split itself reported"
  assert_not_contains "$(cat "$out")" 'run-target=w1:p9' \
    "the herdr companion took over a pre-existing pane of the primary's tab"
  assert_contains "$(strip_ansi < "$out")" '⚓ codex·--' \
    "the constructed herdr companion command did not render the canonical row"
  pass "fm-primary: the herdr companion runs in its own new pane and follows the launching session"
}

test_herdr_split_outcomes_are_reported_separately() {
  local out log="$TMP_ROOT/herdr-outcome-log"
  : > "$log"
  cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --session ] || exit 1
shift 2
[ "${1:-}" = pane ] || exit 1
shift
case "${1:-}" in
  split)
    [ "${FM_PRIMARY_TEST_SPLIT_REFUSED:-0}" = 1 ] && exit 1
    # A successful split that names no pane: herdr's own status is zero, so a
    # pipeline that reads jq's status instead cannot tell this from a refusal.
    printf '{"result":{"type":"ok"}}\n'
    ;;
  layout)
    # Between these two reads a co-tenant pane (w1:p0) appears alongside the
    # split's own pane, so a before/after comparison cannot tell them apart and
    # sorts the co-tenant first. It must never be a candidate for closing.
    count=0
    [ ! -f "$FM_PRIMARY_TEST_PANE_COUNT" ] || count=$(<"$FM_PRIMARY_TEST_PANE_COUNT")
    count=$((count + 1))
    printf '%s\n' "$count" > "$FM_PRIMARY_TEST_PANE_COUNT"
    if [ "$count" -eq 1 ]; then
      printf '{"result":{"layout":{"panes":[{"pane_id":"w1:p1"}]}}}\n'
    else
      printf '{"result":{"layout":{"panes":[{"pane_id":"w1:p0"},{"pane_id":"w1:p1"},{"pane_id":"w1:p2"}]}}}\n'
    fi
    ;;
  close)
    printf 'closed=%s\n' "$2" >> "$FM_PRIMARY_TEST_LOG"
    [ "${FM_PRIMARY_TEST_CLOSE_FAILS:-0}" = 1 ] && exit 1
    ;;
  run)
    printf 'ran=%s\n' "$2" >> "$FM_PRIMARY_TEST_LOG"
    [ "${FM_PRIMARY_TEST_RUN_FAILS:-0}" = 1 ] && exit 1
    ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN/herdr"

  out=$(env -u HERDR_ENV -u TMUX_PANE \
    PATH="$FAKEBIN:$PATH" \
    TERM=dumb \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_TEST_LOG="$log" \
    FM_PRIMARY_TEST_PANE_COUNT="$TMP_ROOT/herdr-outcome-count" \
    HERDR_SESSION=fm-lab-status \
    HERDR_PANE_ID=w1:p1 \
    "$ROOT/bin/fm-primary.sh" codex 2>&1)
  assert_contains "$out" 'did not name it' \
    "a split that succeeded without naming its pane was not reported as such"
  assert_not_contains "$out" 'continuing with the native TUI' \
    "an already-shrunk primary was reported as an untouched native TUI"
  # An unnamed pane is left alone: guessing which pane to close can destroy a
  # co-tenant the captain is using, which is worse than one unused pane.
  assert_not_contains "$(cat "$log")" 'closed=' \
    "a pane the split never named was closed on a guess"
  assert_not_contains "$(cat "$log")" 'ran=' \
    "the renderer was started in a pane the split never named"

  : > "$log"
  rm -f "$TMP_ROOT/herdr-outcome-count"
  out=$(env -u HERDR_ENV -u TMUX_PANE \
    PATH="$FAKEBIN:$PATH" \
    TERM=dumb \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_TEST_LOG="$log" \
    FM_PRIMARY_TEST_PANE_COUNT="$TMP_ROOT/herdr-outcome-count" \
    FM_PRIMARY_TEST_SPLIT_REFUSED=1 \
    HERDR_SESSION=fm-lab-status \
    HERDR_PANE_ID=w1:p1 \
    "$ROOT/bin/fm-primary.sh" codex 2>&1)
  assert_contains "$out" 'continuing with the native TUI' \
    "a refused split lost its quiet native-TUI fallback"
  assert_not_contains "$(cat "$log")" 'closed=' \
    "a refused split closed a pane it never created"
  make_cli herdr
  pass "fm-primary: a refused herdr split and an unnamed companion pane are reported apart"
}

test_herdr_cleanup_only_ever_closes_the_pane_the_split_named() {
  local out log="$TMP_ROOT/herdr-cleanup-log"
  : > "$log"
  cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --session ] || exit 1
shift 2
[ "${1:-}" = pane ] || exit 1
shift
case "${1:-}" in
  split)
    printf '{"result":{"type":"pane_info","pane":{"pane_id":"w1:p2"}}}\n'
    ;;
  layout)
    printf '{"result":{"layout":{"panes":[{"pane_id":"w1:p0"},{"pane_id":"w1:p1"},{"pane_id":"w1:p2"}]}}}\n'
    ;;
  close)
    printf 'closed=%s\n' "$2" >> "$FM_PRIMARY_TEST_LOG"
    ;;
  run)
    printf 'ran=%s\n' "$2" >> "$FM_PRIMARY_TEST_LOG"
    exit 1
    ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN/herdr"
  out=$(env -u HERDR_ENV -u TMUX_PANE \
    PATH="$FAKEBIN:$PATH" \
    TERM=dumb \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_TEST_LOG="$log" \
    HERDR_SESSION=fm-lab-status \
    HERDR_PANE_ID=w1:p1 \
    "$ROOT/bin/fm-primary.sh" codex 2>&1)
  assert_contains "$(cat "$log")" 'closed=w1:p2' \
    "a companion that could not start left its own pane below the primary"
  assert_not_contains "$(cat "$log")" 'closed=w1:p0' \
    "cleanup closed a co-tenant pane the split never created"
  assert_not_contains "$(cat "$log")" 'closed=w1:p1' \
    "cleanup closed the captain's own primary pane"
  assert_contains "$out" 'closed its pane w1:p2' \
    "the companion failure did not name the pane it cleaned up"
  make_cli herdr
  pass "fm-primary: companion cleanup closes only the exact pane the split returned"
}

test_lab_role_guard() {
  local out status=0
  out=$(PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_DRY_RUN=1 \
    FM_PRIMARY_VISIBLE_PREFIX=LAB \
    HERDR_ENV=1 \
    HERDR_SESSION=fm-lab-primary \
    "$ROOT/bin/fm-primary.sh" pi)
  assert_contains "$out" 'role=LAB · PRIMARY' "lab primary was not visibly LAB-prefixed"
  assert_not_contains "$out" 'role=FIRSTMATE' "lab primary inherited the captain-facing role"
  out=$(PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_DRY_RUN=1 \
    FM_PRIMARY_VISIBLE_PREFIX=LAB \
    HERDR_ENV=1 \
    HERDR_SESSION=default \
    "$ROOT/bin/fm-primary.sh" pi 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "LAB role was accepted in the default Herdr session"
  assert_contains "$out" 'requires a named fm-lab-* Herdr session, never default' \
    "default-session LAB refusal was unclear"
  pass "fm-primary: LAB role cannot appear as FIRSTMATE or run in default Herdr"
}

test_cursor_grok_primary_profile() {
  local out status=0
  out=$(dry cursor-grok)
  assert_contains "$out" "profile=cursor-grok" "Cursor dry-run omitted profile"
  assert_contains "$out" "'agent' '--yolo' '--model' 'cursor-grok-4.6-high'" \
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
  assert_contains "$out" 'argv=<--yolo><--model><cursor-grok-4.6-high>' \
    "Cursor primary lost yolo or the high model id"
  # An uncertified build WARNS and still launches. Cursor self-updates, so an
  # exact-match block turned every publisher release into an outage of the
  # certified primary rather than a merely uncertified one.
  status=0
  out=$(PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_DRY_RUN=1 \
    FM_PRIMARY_TEST_CURSOR_VERSION=2026.07.16-899851b \
    "$ROOT/bin/fm-primary.sh" cursor-grok 2>&1) || status=$?
  [ "$status" -eq 0 ] || fail "an uncertified Cursor build must warn, not block the primary"
  assert_contains "$out" 'certified on 2026.08.11-e8db854; found 2026.07.16-899851b' \
    "Cursor version warning was unclear"
  assert_contains "$out" "'agent' '--yolo' '--model' 'cursor-grok-4.6-high'" \
    "Cursor primary did not launch after the version warning"
  # An explicitly logged-out CLI still refuses: the primary would otherwise boot
  # to a login screen instead of a session.
  status=0
  out=$(PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_DRY_RUN=1 \
    FM_PRIMARY_TEST_CURSOR_STATUS='Not logged in' \
    "$ROOT/bin/fm-primary.sh" cursor-grok 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "a logged-out Cursor CLI was accepted as a primary"
  assert_contains "$out" 'not logged in' "Cursor logged-out refusal was unclear"
  pass "fm-primary: Cursor Grok is pinned, lifecycle-integrated, version-warned, and login-gated"
}

# The 4.5 profile exists to keep the previous Grok generation launchable. It must
# differ from the certified cursor-grok profile in the model id ALONE, so this
# test compares the two launches field by field rather than re-asserting one
# hardcoded expectation per mechanic.
test_cursor_grok45_primary_profile() {
  local out status=0 certified new
  out=$(dry cursor-grok45)
  assert_contains "$out" "profile=cursor-grok45" "Cursor 4.5 dry-run omitted profile"
  assert_contains "$out" "'agent' '--yolo' '--model' 'cursor-grok-4.5-high'" \
    "Cursor 4.5 primary argv is wrong"
  assert_not_contains "$out" 'status-bar' "Cursor 4.5 primary invented a status-bar install"
  assert_not_contains "$out" 'cursor-grok-4.6' "Cursor 4.5 primary leaked the 4.6 model id"

  # Every launch field except the profile name and the model id must be identical
  # to the certified profile's.
  certified=$(dry cursor-grok | sed 's/cursor-grok-4\.6-high/MODEL/; s/^profile=.*/profile=PROFILE/')
  new=$(dry cursor-grok45 | sed 's/cursor-grok-4\.5-high/MODEL/; s/^profile=.*/profile=PROFILE/')
  [ "$certified" = "$new" ] || fail \
    "cursor-grok45 diverges from cursor-grok beyond the model id: '$certified' vs '$new'"

  : > "$LOG"
  ( cd "$TMP_ROOT" && \
    env -u HERDR_ENV -u HERDR_SESSION -u HERDR_PANE_ID -u TMUX_PANE \
      PATH="$FAKEBIN:$PATH" \
      TERM=dumb \
      FM_HOME="$HOME_FIX" \
      FM_PRIMARY_TEST_LOG="$LOG" \
      "$ROOT/bin/fm-primary.sh" cursor-grok45 )
  out=$(cat "$LOG")
  assert_contains "$out" 'cli=agent' "Cursor 4.5 primary did not exec agent"
  assert_contains "$out" 'harness=cursor' "Cursor 4.5 primary did not export FM_PRIMARY_HARNESS=cursor"
  assert_contains "$out" 'argv=<--yolo><--model><cursor-grok-4.5-high>' \
    "Cursor 4.5 primary lost yolo or the 4.5 model id"

  # The shared Cursor gates apply unchanged: an uncertified build warns and
  # still launches, and an explicitly logged-out CLI refuses.
  status=0
  out=$(PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_DRY_RUN=1 \
    FM_PRIMARY_TEST_CURSOR_VERSION=2026.07.16-899851b \
    "$ROOT/bin/fm-primary.sh" cursor-grok45 2>&1) || status=$?
  [ "$status" -eq 0 ] || fail "an uncertified Cursor build must warn, not block the 4.5 primary"
  assert_contains "$out" 'certified on 2026.08.11-e8db854; found 2026.07.16-899851b' \
    "Cursor 4.5 version warning was unclear"
  status=0
  out=$(PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_DRY_RUN=1 \
    FM_PRIMARY_TEST_CURSOR_STATUS='Not logged in' \
    "$ROOT/bin/fm-primary.sh" cursor-grok45 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "a logged-out Cursor CLI was accepted as the 4.5 primary"
  assert_contains "$out" 'not logged in' "Cursor 4.5 logged-out refusal was unclear"

  # `cursor` keeps resolving to the certified profile: adding a second Cursor
  # profile must not move the alias.
  assert_contains "$(dry cursor)" "'agent' '--yolo' '--model' 'cursor-grok-4.6-high'" \
    "the cursor alias stopped resolving to the certified 4.6 profile"
  pass "fm-primary: Cursor Grok 4.5 differs from the certified profile in the model id alone"
}

test_claude_effort() {
  local out status=0 effort_file="$HOME_FIX/config/primary-effort"
  mkdir -p "$HOME_FIX/config"

  out=$(dry claude-fable 2>&1)
  assert_contains "$out" "'--model' 'claude-fable-5-1'" \
    "absent primary-effort did not launch claude-fable-5-1"
  assert_contains "$out" "'--effort' 'xhigh'" \
    "absent primary-effort did not default to xhigh"
  assert_contains "$out" "launching model claude-fable-5-1 at effort xhigh" \
    "absent primary-effort did not print the resolved model and effort"

  printf 'high\n' > "$effort_file"
  out=$(dry claude-fable 2>/dev/null)
  assert_contains "$out" "'--effort' 'high'" \
    "primary-effort high did not resolve to high"
  assert_contains "$out" "'--model' 'claude-fable-5-1'" \
    "primary-effort high lost the Fable 5.1 model pin"

  out=$(dry claude-opus 2>/dev/null)
  assert_contains "$out" "'--effort' 'high'" \
    "primary-effort high did not apply to Claude Opus"
  assert_contains "$out" "'--model' 'claude-opus-5-5'" \
    "primary-effort high lost the Opus 5.5 model pin"

  printf '  high \n' > "$effort_file"
  out=$(dry claude-opus 2>/dev/null)
  assert_contains "$out" "'--effort' 'high'" \
    "padded primary-effort high was not trimmed to high"

  printf 'turbo\n' > "$effort_file"
  status=0
  out=$(dry claude-opus 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "primary-effort turbo was accepted"
  assert_contains "$out" "$effort_file" "invalid-effort refusal did not name the file"
  assert_contains "$out" "turbo" "invalid-effort refusal did not name the bad value"
  assert_contains "$out" "low medium high xhigh max" \
    "invalid-effort refusal did not name the accepted set"
  assert_not_contains "$out" "'--effort' 'xhigh'" \
    "invalid-effort silently fell back to the default"

  : > "$effort_file"
  status=0
  out=$(dry claude-fable 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "empty primary-effort was accepted"
  assert_contains "$out" "$effort_file" "empty-effort refusal did not name the file"
  assert_contains "$out" "low medium high xhigh max" \
    "empty-effort refusal did not name the accepted set"

  rm -f "$effort_file"
  pass "fm-primary: Claude effort applies to Fable and Opus and refuses invalid tokens"
}

# The extended Astra context window. The captain's installation grants Astra far
# more context than its catalog default, but only if the launch asks; this is
# that ask, made persistent and checked against what the installation actually
# offers rather than against a remembered number or an API model page.
test_astra_context_window_is_selectable_and_bounded_by_the_catalog() {
  local out status=0 codex_home="$TMP_ROOT/astra-codex-home"
  local ctx_file="$HOME_FIX/config/astra-context"
  local compact_file="$HOME_FIX/config/astra-compact-at"
  mkdir -p "$HOME_FIX/config" "$codex_home"
  printf 'high\n' > "$HOME_FIX/config/astra-effort"
  cat > "$codex_home/models_cache.json" <<'JSON'
{"models":[{"slug":"gpt-6-astra","context_window":272000,"max_context_window":872000,
"effective_context_window_percent":95},{"slug":"gpt-5.5","max_context_window":400000}]}
JSON

  astra_dry() {
    ( cd "$TMP_ROOT" && \
      env -u CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP \
      PATH="$FAKEBIN:$PATH" \
      FM_HOME="$HOME_FIX" \
      FM_PRIMARY_DRY_RUN=1 \
      FM_PRIMARY_TEST_LOG="$LOG" \
      CODEX_HOME="$codex_home" \
      "$ROOT/bin/fm-primary.sh" astra )
  }

  # Absent is a complete no-op: exactly the launch that shipped before.
  rm -f "$ctx_file" "$compact_file"
  out=$(astra_dry 2>&1)
  assert_not_contains "$out" 'model_context_window' \
    "an absent config/astra-context still changed the launch"
  assert_contains "$out" 'model_reasoning_effort="high"' \
    "an absent config/astra-context disturbed the resolved effort"

  # max resolves to the installation's own ceiling, never to a remembered number.
  printf 'max\n' > "$ctx_file"
  out=$(astra_dry 2>&1)
  assert_contains "$out" "'-c' 'model_context_window=872000'" \
    "config/astra-context max did not resolve to the catalog ceiling"
  assert_contains "$out" 'requesting context window 872000' \
    "the resolved window was not reported for verification after launch"
  assert_contains "$out" "'-c' 'model_auto_compact_token_limit=500000'" \
    "selecting a window without config/astra-compact-at moved the 500k default"

  # An explicit window at or below the ceiling is honoured verbatim.
  printf '  400000  \n' > "$ctx_file"
  out=$(astra_dry 2>&1)
  assert_contains "$out" "'-c' 'model_context_window=400000'" \
    "a padded explicit window was not trimmed and honoured"

  # Above the ceiling REFUSES. Passing it through, or silently clamping it, would
  # both leave the launcher asserting a window the provider never granted.
  printf '1050000\n' > "$ctx_file"
  status=0
  out=$(astra_dry 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "a context window above the installed ceiling was accepted"
  assert_contains "$out" '872000' "the over-ceiling refusal did not name the real ceiling"
  assert_not_contains "$out" "'-c' 'model_context_window=872000'" \
    "an over-ceiling window was silently clamped instead of refused"

  # An unreadable catalog refuses rather than guessing a ceiling.
  printf 'max\n' > "$ctx_file"
  status=0
  out=$( ( cd "$TMP_ROOT" && env -u CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP \
    PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FIX" FM_PRIMARY_DRY_RUN=1 \
    FM_PRIMARY_TEST_LOG="$LOG" CODEX_HOME="$TMP_ROOT/no-such-codex-home" \
    "$ROOT/bin/fm-primary.sh" astra ) 2>&1 ) || status=$?
  [ "$status" -ne 0 ] || fail "an unreadable model catalog still resolved a context window"
  assert_not_contains "$out" 'model_context_window=' \
    "an unreadable catalog produced a context window anyway"

  # A malformed value refuses instead of falling back to the default window.
  printf 'wide\n' > "$ctx_file"
  status=0
  out=$(astra_dry 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "a malformed config/astra-context was accepted"
  assert_contains "$out" "$ctx_file" "the malformed-window refusal did not name the file"

  # The compaction point is the captain's operational choice, never derived.
  printf 'max\n' > "$ctx_file"
  printf '750000\n' > "$compact_file"
  out=$(astra_dry 2>&1)
  assert_contains "$out" "'-c' 'model_auto_compact_token_limit=750000'" \
    "an explicit compaction point did not reach the launch"
  assert_not_contains "$out" 'model_auto_compact_token_limit=500000' \
    "the explicit compaction point was added alongside the 500k default instead of replacing it"

  printf '900000\n' > "$compact_file"
  status=0
  out=$(astra_dry 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "a compaction point at or above the window was accepted"

  # A compaction point with no window selected is a misconfiguration, not a hint.
  rm -f "$ctx_file"
  printf '750000\n' > "$compact_file"
  status=0
  out=$(astra_dry 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "a compaction point without a selected window was accepted"

  rm -f "$ctx_file" "$compact_file" "$HOME_FIX/config/astra-effort"
  unset -f astra_dry
  pass "fm-primary: the Astra context window is selectable, bounded by the installed catalog, and never invented"
}

test_astra_primary_profile() {
  local out status=0 probe_out probe_err
  local effort_file="$HOME_FIX/config/astra-effort" override="$TMP_ROOT/astra-config"
  mkdir -p "$HOME_FIX/config" "$override"

  rm -f "$effort_file"
  out=$(dry astra 2>&1)
  assert_contains "$out" "profile=astra" "Astra dry-run omitted profile"
  assert_contains "$out" "'--model' 'gpt-6-astra'" "absent astra-effort did not launch gpt-6-astra"
  assert_contains "$out" 'model_reasoning_effort="xhigh"' "absent astra-effort did not default to xhigh"
  assert_contains "$out" "'--dangerously-bypass-hook-trust'" "Astra dry-run lost hook-trust bypass"
  assert_contains "$out" "'--dangerously-bypass-approvals-and-sandbox'" "Astra dry-run lost approvals-and-sandbox bypass"
  assert_contains "$out" "launching model gpt-6-astra at effort xhigh" \
    "absent astra-effort did not print the resolved model and effort"

  printf 'high\n' > "$effort_file"
  out=$(dry astra 2>/dev/null)
  assert_contains "$out" 'model_reasoning_effort="high"' "astra-effort high did not resolve to high"
  assert_contains "$out" "'--model' 'gpt-6-astra'" "astra-effort high lost the model pin"

  for token in low medium xhigh; do
    printf '%s\n' "$token" > "$effort_file"
    out=$(dry astra 2>/dev/null)
    assert_contains "$out" "model_reasoning_effort=\"$token\"" \
      "astra-effort $token was not accepted"
  done

  printf 'medium\n' > "$override/astra-effort"
  out=$(PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_CONFIG_OVERRIDE="$override" \
    FM_PRIMARY_DRY_RUN=1 \
    "$ROOT/bin/fm-primary.sh" astra 2>/dev/null)
  assert_contains "$out" 'model_reasoning_effort="medium"' \
    "FM_CONFIG_OVERRIDE astra-effort did not win"

  printf '  high \n' > "$effort_file"
  out=$(dry astra 2>/dev/null)
  assert_contains "$out" 'model_reasoning_effort="high"' \
    "padded astra-effort high was not trimmed to high"

  printf 'max\n' > "$effort_file"
  status=0
  out=$(dry astra 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "astra-effort max was accepted"
  assert_contains "$out" "$effort_file" "max-effort refusal did not name the file"
  assert_contains "$out" "max" "max-effort refusal did not name the bad value"
  assert_contains "$out" "low medium high xhigh" "max-effort refusal did not name the accepted set"
  assert_not_contains "$out" 'model_reasoning_effort="xhigh"' "max-effort silently fell back to the default"

  : > "$effort_file"
  status=0
  out=$(dry astra 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "empty astra-effort was accepted"
  assert_contains "$out" "$effort_file" "empty astra-effort refusal did not name the file"

  printf 'turbo\n' > "$effort_file"
  status=0
  out=$(dry astra 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "astra-effort turbo was accepted"
  assert_contains "$out" "turbo" "junk astra-effort refusal did not name the bad value"

  rm -f "$effort_file"

  status=0
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FIX" "$ROOT/bin/fm-primary.sh" mystery 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "unknown profile was accepted"
  assert_contains "$out" 'astra' "unknown profile refusal omitted astra from the verified list"

  : > "$LOG"
  ( cd "$TMP_ROOT" && \
    env -u HERDR_ENV -u HERDR_SESSION -u HERDR_PANE_ID -u TMUX_PANE \
      PATH="$FAKEBIN:$PATH" \
      TERM=dumb \
      FM_HOME="$HOME_FIX" \
      FM_PRIMARY_TEST_LOG="$LOG" \
      "$ROOT/bin/fm-primary.sh" astra )
  out=$(cat "$LOG")
  assert_contains "$out" 'cli=codex' "Astra primary did not exec codex"
  assert_contains "$out" 'harness=codex' "Astra primary did not export FM_PRIMARY_HARNESS=codex"
  assert_contains "$out" 'argv=<--model><gpt-6-astra>' "Astra primary lost the model pin at exec"

  # The gate can only be trusted if the fixture speaks the stream the real CLI
  # speaks: stderr, with nothing at all on stdout.
  probe_out=$(FM_PRIMARY_TEST_CODEX_LOGIN_STATUS='Not logged in' \
    "$FAKEBIN/codex" login status 2>/dev/null) || true
  [ -z "$probe_out" ] || \
    fail "codex login status fixture put the logged-out message on stdout, unlike the real CLI"
  probe_err=$(FM_PRIMARY_TEST_CODEX_LOGIN_STATUS='Not logged in' \
    "$FAKEBIN/codex" login status 2>&1 >/dev/null) || true
  assert_contains "$probe_err" 'Not logged in' \
    "codex login status fixture did not report the logged-out state on stderr"

  status=0
  out=$(PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_DRY_RUN=1 \
    FM_PRIMARY_TEST_CODEX_LOGIN_STATUS='Not logged in' \
    "$ROOT/bin/fm-primary.sh" astra 2>&1) || status=$?
  [ "$status" -eq 0 ] || fail "logged-out Codex blocked astra dry-run"
  assert_contains "$out" 'gpt-6-astra' "logged-out Codex hid astra dry-run argv"

  status=0
  out=$(
    env -u HERDR_ENV -u HERDR_SESSION -u HERDR_PANE_ID -u TMUX_PANE \
      PATH="$FAKEBIN:$PATH" \
      TERM=dumb \
      FM_HOME="$HOME_FIX" \
      FM_PRIMARY_TEST_CODEX_LOGIN_STATUS='Not logged in' \
      "$ROOT/bin/fm-primary.sh" astra 2>&1
  ) || status=$?
  [ "$status" -ne 0 ] || fail "a logged-out Codex CLI was accepted as an astra primary"
  assert_contains "$out" 'not logged in' "Astra logged-out refusal was unclear"

  status=0
  out=$(
    env -u HERDR_ENV -u HERDR_SESSION -u HERDR_PANE_ID -u TMUX_PANE \
      PATH="$FAKEBIN:$PATH" \
      TERM=dumb \
      FM_HOME="$HOME_FIX" \
      FM_PRIMARY_TEST_CODEX_LOGIN_STATUS='Not logged in' \
      "$ROOT/bin/fm-primary.sh" codex 2>&1
  ) || status=$?
  [ "$status" -ne 0 ] || fail "a logged-out Codex CLI was accepted as a codex primary"
  assert_contains "$out" 'not logged in' "Codex logged-out refusal was unclear"

  # A banner-heavy build must not be able to push the negative out of reach.
  status=0
  out=$(
    env -u HERDR_ENV -u HERDR_SESSION -u HERDR_PANE_ID -u TMUX_PANE \
      PATH="$FAKEBIN:$PATH" \
      TERM=dumb \
      FM_HOME="$HOME_FIX" \
      FM_PRIMARY_TEST_CODEX_LOGIN_STATUS=$'update available: 0.153.4\nrun codex --upgrade\nconfig key deprecated\nsee docs\nreading auth\nNot logged in' \
      "$ROOT/bin/fm-primary.sh" astra 2>&1
  ) || status=$?
  [ "$status" -ne 0 ] || fail "a stderr preamble hid the logged-out Codex state from the astra gate"
  assert_contains "$out" 'not logged in' "Astra logged-out refusal was unclear behind a preamble"

  # A probe that fails for any other reason is not evidence of a logged-out CLI,
  # so only the message may block and never the exit status.
  : > "$LOG"
  status=0
  out=$(
    env -u HERDR_ENV -u HERDR_SESSION -u HERDR_PANE_ID -u TMUX_PANE \
      PATH="$FAKEBIN:$PATH" \
      TERM=dumb \
      FM_HOME="$HOME_FIX" \
      FM_PRIMARY_TEST_LOG="$LOG" \
      FM_PRIMARY_TEST_CODEX_LOGIN_STATUS='error: could not read auth.json' \
      "$ROOT/bin/fm-primary.sh" astra 2>&1
  ) || status=$?
  [ "$status" -eq 0 ] || fail "an unreadable Codex login probe blocked the astra primary: $out"
  assert_contains "$(cat "$LOG")" 'cli=codex' "an unreadable Codex login probe stopped the astra exec"

  rm -f "$effort_file"
  pass "fm-primary: astra pins gpt-6-astra, effort, Codex harness, and the Codex login gate"
}
# Named vendor account pinning. The compatibility guarantee comes first: with no
# config/accounts.json every profile's argv and environment are exactly what they
# were before account pinning existed.
test_account_absent_registry_changes_nothing() {
  local profile out registry="$HOME_FIX/config/accounts.json"
  mkdir -p "$HOME_FIX/config"
  rm -f "$registry"
  for profile in pi claude-fable claude-opus codex opencode grok cursor-grok cursor-grok45; do
    out=$(dry "$profile" 2>/dev/null)
    assert_not_contains "$out" 'account=' "$profile leaked an account line with no registry"
    assert_not_contains "$out" 'CLAUDE_CONFIG_DIR' "$profile pinned a Claude home with no registry"
    assert_not_contains "$out" 'CODEX_HOME' "$profile pinned a Codex home with no registry"
  done
  out=$(dry claude-fable 2>/dev/null)
  assert_contains "$out" "'claude' '--model' 'claude-fable-5-1' '--effort' 'xhigh' '--name' 'FIRSTMATE' '--dangerously-skip-permissions'" \
    "an absent registry changed the Claude Fable argv"
  out=$(dry codex 2>/dev/null)
  assert_contains "$out" "'codex' '--dangerously-bypass-hook-trust' '--dangerously-bypass-approvals-and-sandbox'" \
    "an absent registry changed the Codex argv"
  pass "fm-primary: an absent config/accounts.json leaves every profile byte-identical"
}

write_account_registry() {
  mkdir -p "$HOME_FIX/config"
  cat > "$HOME_FIX/config/accounts.json" <<'JSON'
{
  "claude": {
    "default": "team",
    "accounts": {
      "team": {"label": "Company Team (connectors)"},
      "max": {"label": "Personal Max"}
    }
  },
  "codex": {
    "default": "robin",
    "accounts": {
      "robin": {"label": "Robin personal"},
      "alex": {"label": "Alex"}
    }
  }
}
JSON
}

test_account_selection_and_refusals() {
  local out status registry="$HOME_FIX/config/accounts.json"
  local claude_max="$HOME_FIX/data/accounts/claude/max"
  local claude_team="$HOME_FIX/data/accounts/claude/team"
  local codex_alex="$HOME_FIX/data/accounts/codex/alex"
  write_account_registry
  mkdir -p "$claude_max" "$claude_team" "$codex_alex"

  # A valid pin exports the vendor's own isolation variable at the derived home.
  out=$(dry claude-fable --account max 2>/dev/null)
  assert_contains "$out" "account=max" "a valid Claude pin did not report the account"
  assert_contains "$out" "CLAUDE_CONFIG_DIR=$claude_max" "a valid Claude pin did not export the derived home"
  assert_not_contains "$out" 'CODEX_HOME' "a Claude pin exported a Codex home"

  out=$(dry codex --account alex 2>/dev/null)
  assert_contains "$out" "account=alex" "a valid Codex pin did not report the account"
  assert_contains "$out" "CODEX_HOME=$codex_alex" "a valid Codex pin did not export the derived home"
  assert_not_contains "$out" 'CLAUDE_CONFIG_DIR' "a Codex pin exported a Claude home"

  # astra is a Codex-vendor profile, so it takes a codex account like codex does.
  out=$(dry astra --account alex 2>/dev/null)
  assert_contains "$out" "account=alex" "astra did not report the pinned Codex account"
  assert_contains "$out" "CODEX_HOME=$codex_alex" "astra did not export the derived Codex home"
  assert_contains "$out" "'--model' 'gpt-6-astra'" "pinning an account changed the astra model"

  # The vendor default applies when the flag is omitted.
  out=$(dry claude-opus 2>/dev/null)
  assert_contains "$out" "account=team" "the Claude default account was not applied"
  assert_contains "$out" "CLAUDE_CONFIG_DIR=$claude_team" "the Claude default did not export its derived home"

  # The default is the only path that picks a name nobody typed, so it gets the
  # same name rule: an unsafe default refuses with no --account flag anywhere.
  printf '%s\n' '{"claude":{"default":"_team","accounts":{"_team":{}}}}' > "$registry"
  status=0
  out=$(dry claude-fable 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "an unsafe vendor default was accepted"
  assert_contains "$out" "invalid claude account name '_team'" "default refusal did not name the invalid account"
  assert_not_contains "$out" 'CLAUDE_CONFIG_DIR' "an unsafe default still pinned a home"
  write_account_registry

  # An unknown name refuses and names the accounts that ARE defined.
  status=0
  out=$(dry claude-fable --account ghost 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "an unknown account name was accepted"
  assert_contains "$out" "unknown claude account 'ghost'" "refusal did not name the bad account"
  assert_contains "$out" "team max" "refusal did not name the defined accounts"

  # A profile whose vendor has no account concept refuses rather than ignoring.
  for profile in pi opencode grok cursor-grok cursor-grok45; do
    status=0
    out=$(dry "$profile" --account max 2>&1) || status=$?
    [ "$status" -ne 0 ] || fail "--account was silently ignored on $profile"
    assert_contains "$out" "no vendor account to pin" "$profile refusal did not explain the missing account concept"
  done

  # Every OTHER extra argument still refuses with the original message.
  for extra in --resume -c --continue --account-ish nonsense; do
    status=0
    out=$(dry claude-fable "$extra" 2>&1) || status=$?
    [ "$status" -ne 0 ] || fail "extra argument '$extra' was accepted"
    assert_contains "$out" "profiles accept no extra arguments; use the launched CLI's normal resume UI" \
      "extra argument '$extra' lost the original refusal"
  done
  status=0
  out=$(dry claude-fable --account 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "--account without a name was accepted"
  assert_contains "$out" "--account requires an account name" "bare --account lost its own message"

  rm -f "$registry"
  pass "fm-primary: --account selects, defaults, and refuses unknown names, vendorless profiles, and other arguments"
}

test_account_login_and_identity_gates() {
  local out status registry="$HOME_FIX/config/accounts.json"
  local claude_team="$HOME_FIX/data/accounts/claude/team"
  write_account_registry
  rm -rf "$claude_team"

  # A home that does not exist yet refuses with the exact login command.
  status=0
  out=$(live claude-fable --account team 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "a missing account home was accepted"
  assert_contains "$out" "has no home yet" "refusal did not report the missing home"
  assert_contains "$out" "CLAUDE_CONFIG_DIR=$claude_team claude" "refusal did not name the exact login command"

  # An explicitly logged-out home refuses the same way, and copies nothing.
  mkdir -p "$claude_team"
  status=0
  out=$( FM_PRIMARY_TEST_LOGGED_OUT=1 live claude-fable --account team 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "a logged-out account home was accepted"
  assert_contains "$out" "is not logged in" "refusal did not report the logged-out home"
  assert_contains "$out" "CLAUDE_CONFIG_DIR=$claude_team claude" "logged-out refusal did not name the login command"
  assert_contains "$out" "no credential is ever copied from another account" \
    "logged-out refusal dropped the no-credential-copying rule"
  [ -z "$(ls -A "$claude_team")" ] || fail "the account home was seeded with something"

  # An expect identity is verified against the pinned home before exec.
  cat > "$registry" <<'JSON'
{
  "claude": {
    "accounts": {
      "team": {"label": "Company Team", "expect": "org-team-0001"}
    }
  }
}
JSON
  status=0
  out=$( FM_PRIMARY_TEST_CLAUDE_ORG=org-personal-0002 live claude-fable --account team 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "a pinned home signed in as another account was accepted"
  assert_contains "$out" "expects 'org-team-0001'" "refusal did not name the expected identity"
  assert_contains "$out" "org-personal-0002" "refusal did not name the actual identity"

  # A matching identity launches, and the dry-run preview of the same pin still
  # reports the derived home.
  : > "$LOG"
  status=0
  ( FM_PRIMARY_TEST_CLAUDE_ORG=org-team-0001 live claude-fable --account team >/dev/null 2>&1 ) || status=$?
  expect_code 0 "$status" "a matching identity refused its own launch"
  assert_contains "$(cat "$LOG")" "cli=claude" "a matching identity never reached the CLI"
  out=$( FM_PRIMARY_TEST_CLAUDE_ORG=org-team-0001 dry claude-fable --account team 2>/dev/null)
  assert_contains "$out" "CLAUDE_CONFIG_DIR=$claude_team" "a matching identity did not launch pinned"

  rm -f "$registry"
  pass "fm-primary: a missing, logged-out, or wrong-identity account home refuses before launch"
}

# The account half of the dry-run contract, stated in the fm-primary header: a
# preview shows argv BEFORE the pinned home's credential is inspected, so a
# missing, logged-out, or wrong seat can never hide what would have been
# launched. An unresolvable pin is a different thing - a bad request - and still
# refuses. Other profiles' own login gates are out of scope here and keep their
# existing placement.
test_account_credential_gates_never_hide_dry_run_argv() {
  local out status registry="$HOME_FIX/config/accounts.json"
  local claude_team="$HOME_FIX/data/accounts/claude/team"
  write_account_registry
  rm -rf "$claude_team"

  out=$(dry claude-fable --account team 2>&1)
  status=$?
  expect_code 0 "$status" "a missing account home hid the dry-run preview"
  assert_contains "$out" "account=team" "the preview lost the account it would have used"
  assert_contains "$out" "CLAUDE_CONFIG_DIR=$claude_team" "the preview lost the derived home"
  assert_contains "$out" "'claude' '--model' 'claude-fable-5-1'" "the preview lost argv"

  mkdir -p "$claude_team"
  out=$( FM_PRIMARY_TEST_LOGGED_OUT=1 dry claude-fable --account team 2>&1)
  status=$?
  expect_code 0 "$status" "a logged-out account home hid the dry-run preview"
  assert_contains "$out" "'claude' '--model' 'claude-fable-5-1'" "the logged-out preview lost argv"

  cat > "$registry" <<'JSON'
{
  "claude": {
    "accounts": {
      "team": {"label": "Company Team", "expect": "org-team-0001"}
    }
  }
}
JSON
  out=$( FM_PRIMARY_TEST_CLAUDE_ORG=org-personal-0002 dry claude-fable --account team 2>&1)
  status=$?
  expect_code 0 "$status" "a wrong-seat account home hid the dry-run preview"
  assert_contains "$out" "'claude' '--model' 'claude-fable-5-1'" "the wrong-seat preview lost argv"

  # Resolution refusals are NOT credential gates and still refuse in dry run.
  write_account_registry
  status=0
  out=$(dry claude-fable --account ghost 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "an unknown account still previewed argv"
  assert_contains "$out" "unknown claude account 'ghost'" "unknown-account refusal was lost in dry run"
  status=0
  out=$(dry pi --account team 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "a vendorless profile still previewed argv"
  assert_contains "$out" "no vendor account to pin" "vendorless refusal was lost in dry run"

  rm -f "$registry"
  pass "fm-primary: dry run previews argv before the account credential gate, and still refuses an unresolvable pin"
}

# A broken registry is a diagnostic, not an outage: bootstrap reports it, an
# explicit pin refuses, and a launch that asked for no pin still runs.
test_account_invalid_registry_warns_without_crashing_a_launch() {
  local out status registry="$HOME_FIX/config/accounts.json"
  mkdir -p "$HOME_FIX/config"
  printf '{"claude":' > "$registry"

  out=$(dry claude-fable 2>&1)
  status=$?
  expect_code 0 "$status" "a malformed registry crashed an unpinned launch"
  assert_contains "$out" "is not valid JSON" "a malformed registry did not warn"
  assert_contains "$out" "'claude' '--model' 'claude-fable-5-1'" "a malformed registry changed the unpinned argv"
  assert_not_contains "$out" 'CLAUDE_CONFIG_DIR' "a malformed registry still pinned a home"

  status=0
  out=$(dry claude-fable --account team 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "a malformed registry still resolved an explicit pin"
  assert_contains "$out" "cannot be resolved" "explicit pin refusal did not explain the unreadable registry"

  rm -f "$registry"
  pass "fm-primary: an unreadable registry warns and still launches, but refuses an explicit pin"
}

test_claude_disables_bg_shell_pressure_reap() {
  local out
  : > "$LOG"
  ( cd "$TMP_ROOT" && \
    env -u HERDR_ENV -u HERDR_SESSION -u HERDR_PANE_ID -u TMUX_PANE \
      -u CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP \
      PATH="$FAKEBIN:$PATH" \
      TERM=dumb \
      FM_HOME="$HOME_FIX" \
      FM_PRIMARY_TEST_LOG="$LOG" \
      "$ROOT/bin/fm-primary.sh" claude-fable )
  out=$(cat "$LOG")
  assert_contains "$out" 'cli=claude' "Claude Fable primary did not exec claude"
  assert_contains "$out" 'claude_bg_shell_pressure_reap=1' \
    "Claude Fable primary did not export CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP=1"

  : > "$LOG"
  ( cd "$TMP_ROOT" && \
    env -u HERDR_ENV -u HERDR_SESSION -u HERDR_PANE_ID -u TMUX_PANE \
      -u CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP \
      PATH="$FAKEBIN:$PATH" \
      TERM=dumb \
      FM_HOME="$HOME_FIX" \
      FM_PRIMARY_TEST_LOG="$LOG" \
      "$ROOT/bin/fm-primary.sh" claude-opus )
  out=$(cat "$LOG")
  assert_contains "$out" 'cli=claude' "Claude Opus primary did not exec claude"
  assert_contains "$out" 'claude_bg_shell_pressure_reap=1' \
    "Claude Opus primary did not export CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP=1"

  : > "$LOG"
  ( cd "$TMP_ROOT" && \
    env -u HERDR_ENV -u HERDR_SESSION -u HERDR_PANE_ID -u TMUX_PANE \
      -u CLAUDE_CODE_DISABLE_BG_SHELL_PRESSURE_REAP \
      PATH="$FAKEBIN:$PATH" \
      TERM=dumb \
      FM_HOME="$HOME_FIX" \
      FM_PRIMARY_TEST_LOG="$LOG" \
      "$ROOT/bin/fm-primary.sh" pi )
  out=$(cat "$LOG")
  assert_contains "$out" 'cli=pi' "Pi primary did not exec pi"
  assert_not_contains "$out" 'claude_bg_shell_pressure_reap=1' \
    "Pi primary exported Claude's pressure-reap disable"
  pass "fm-primary: Claude Fable and Opus disable background-shell pressure reap; other profiles do not"
}

# The captain's 2026-09-13 order: every FUTURE launch caps its auto-compaction
# window at 500k tokens. This pins the exact per-harness mechanism, including
# the two harnesses that deliberately get nothing, so a later edit cannot
# quietly drop the cap or invent a knob that does not exist.
test_context_window_is_capped_at_500k() {
  local out profile
  for profile in claude-fable claude-opus; do
    out=$(dry "$profile")
    assert_contains "$out" 'CLAUDE_CODE_AUTO_COMPACT_WINDOW=500000' \
      "$profile dry-run omitted the 500k auto-compact window"
  done

  for profile in codex astra; do
    out=$(dry "$profile")
    assert_contains "$out" "'-c' 'model_auto_compact_token_limit=500000'" \
      "$profile argv omitted the 500k auto-compact limit"
  done

  # Pi and Cursor expose no context or compaction knob, so their launches must
  # stay bare rather than carry an invented one.
  for profile in pi cursor-grok; do
    out=$(dry "$profile")
    assert_not_contains "$out" 'AUTO_COMPACT' \
      "$profile invented a Claude auto-compact window"
    assert_not_contains "$out" 'auto_compact' \
      "$profile invented a Codex auto-compact limit"
    assert_not_contains "$out" 'context=' \
      "$profile invented a context-window flag"
    assert_not_contains "$out" '--context' \
      "$profile invented a --context flag"
  done

  # The real exec path, not just the preview: the launched CLI must actually see
  # the variable in its environment.
  : > "$LOG"
  ( cd "$TMP_ROOT" && \
    env -u HERDR_ENV -u HERDR_SESSION -u HERDR_PANE_ID -u TMUX_PANE \
      -u CLAUDE_CODE_AUTO_COMPACT_WINDOW \
      PATH="$FAKEBIN:$PATH" \
      TERM=dumb \
      FM_HOME="$HOME_FIX" \
      FM_PRIMARY_TEST_LOG="$LOG" \
      "$ROOT/bin/fm-primary.sh" claude-fable )
  out=$(cat "$LOG")
  assert_contains "$out" 'claude_auto_compact_window=500000' \
    "the launched Claude primary did not inherit CLAUDE_CODE_AUTO_COMPACT_WINDOW=500000"

  : > "$LOG"
  ( cd "$TMP_ROOT" && \
    env -u HERDR_ENV -u HERDR_SESSION -u HERDR_PANE_ID -u TMUX_PANE \
      -u CLAUDE_CODE_AUTO_COMPACT_WINDOW \
      PATH="$FAKEBIN:$PATH" \
      TERM=dumb \
      FM_HOME="$HOME_FIX" \
      FM_PRIMARY_TEST_LOG="$LOG" \
      "$ROOT/bin/fm-primary.sh" pi )
  out=$(cat "$LOG")
  assert_contains "$out" 'claude_auto_compact_window=' "Pi primary did not exec through the fake CLI"
  assert_not_contains "$out" 'claude_auto_compact_window=500000' \
    "the Pi primary leaked Claude's auto-compact window into its environment"

  # --help is the launcher's own owner of launch mechanics, so the mechanism has
  # to be readable there and not only in the source.
  out=$("$ROOT/bin/fm-primary.sh" --help)
  assert_contains "$out" 'CLAUDE_CODE_AUTO_COMPACT_WINDOW=500000' \
    "help omitted the Claude auto-compact window"
  assert_contains "$out" 'model_auto_compact_token_limit=500000' \
    "help omitted the Codex auto-compact limit"
  assert_contains "$out" 'Pi has no context-window or auto-compaction launch' \
    "help did not state that Pi has no context-window knob"
  assert_contains "$out" 'The Cursor CLI exposes no context or' \
    "help did not state that Cursor has no context-window knob"
  pass "fm-primary: Claude and Codex launches cap the window at 500k; Pi and Cursor stay bare"
}

test_preflight_is_read_only_and_checks_accounts() {
  local profile out status=0 holder
  # A synthetic live owner must not prevent checking a replacement.
  bash -c 'while :; do sleep 1; done' claude-preflight-holder &
  holder=$!
  printf '%s\n' "$holder" > "$HOME_FIX/state/.lock"
  : > "$LOG"
  for profile in pi claude-fable claude-opus codex astra opencode grok cursor-grok cursor-grok45; do
    out=$(live "$profile" --preflight 2>&1) || status=$?
    [ "$status" -eq 0 ] || { kill "$holder"; fail "$profile preflight failed: $out"; }
  done
  kill "$holder"
  wait "$holder" 2>/dev/null || true
  rm -f "$HOME_FIX/state/.lock"
  [ ! -s "$LOG" ] || fail "preflight launched a CLI or changed a runtime surface: $(cat "$LOG")"
  [ ! -f "$HOME_FIX/state/.primary-active" ] || fail "preflight published an active launch"
  status=0
  out=$(FM_PRIMARY_TEST_CODEX_LOGIN_STATUS='Not logged in' live codex --preflight 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "preflight skipped account availability"
  assert_contains "$out" 'not logged in' "preflight account failure was unclear"
  pass "fm-primary: preflight checks all profile gates without launch, state, or terminal changes"
}

test_preflight_is_read_only_and_checks_accounts

test_profiles_and_root
test_context_window_is_capped_at_500k
test_claude_effort
test_astra_primary_profile
test_astra_context_window_is_selectable_and_bounded_by_the_catalog
test_claude_disables_bg_shell_pressure_reap
test_account_absent_registry_changes_nothing
test_account_selection_and_refusals
test_account_login_and_identity_gates
test_account_credential_gates_never_hide_dry_run_argv
test_account_invalid_registry_warns_without_crashing_a_launch
test_unknown_dependency_and_integration_refusals
test_active_lock_refusal
test_exec_environment_and_exit_status
test_launch_links_switched_on_opt_in_skills_first
test_visible_role_marks_only_current_surface
test_shim_install_safety
test_kimi_primary_profile_is_removed
test_codex_tmux_companion_status_bar
test_tmux_companion_command_renders_the_canonical_row
test_herdr_companion_command_renders_in_the_pane_the_split_created
test_herdr_chrome_hides_the_companion_only_on_an_uncrowded_tab
test_herdr_launcher_keeps_its_own_fm_root
test_herdr_split_outcomes_are_reported_separately
test_herdr_cleanup_only_ever_closes_the_pane_the_split_named
test_lab_role_guard
test_cursor_grok_primary_profile
test_cursor_grok45_primary_profile
