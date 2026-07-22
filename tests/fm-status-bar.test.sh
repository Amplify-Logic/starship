#!/usr/bin/env bash
# Canonical Firstmate status-bar contract and adapter integration regressions.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-status-bar)
HOME_FIX="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
mkdir -p "$HOME_FIX/state"

cat > "$FAKEBIN/stat" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_STATUS_BAR_TEST_BEAT_EPOCH:-900}"
SH
chmod +x "$FAKEBIN/stat"

strip_ansi() {
  sed $'s/\033\\[[0-9;]*m//g'
}

render() {
  PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS=pi \
    FM_STATUS_BAR_NOW=1000 \
    "$ROOT/bin/fm-status-bar.sh" \
      --adapter pi \
      --model "${1:-Opus}" \
      --effort "${2:-high}" \
      --context-used "${3:---}" \
      --quota-used "${4:---}" \
      --cost "${5:---}"
}

test_contract_order_and_fleet_projection() {
  local out
  fm_write_meta "$HOME_FIX/state/working.meta" "kind=crew"
  printf 'working: implementation\n' > "$HOME_FIX/state/working.status"
  fm_write_meta "$HOME_FIX/state/paused.meta" "kind=crew"
  printf 'working: setup\n\npaused: upstream release\n' > "$HOME_FIX/state/paused.status"
  fm_write_meta "$HOME_FIX/state/attention.meta" "kind=scout"
  printf 'working: diagnosis\nblocked: missing fixture\n' > "$HOME_FIX/state/attention.status"
  fm_write_meta "$HOME_FIX/state/domain.meta" "kind=secondmate"
  printf 'blocked: must not count\n' > "$HOME_FIX/state/domain.status"
  : > "$HOME_FIX/state/.last-watcher-beat"
  : > "$HOME_FIX/state/.afk"

  out=$(render Opus high 42 73 1.235 | strip_ansi)
  [ "$out" = "⚓ Opus·high │ 🧠42% ⚡73% │ 🚢3 ⏸1 ⚠1 │ 👁 100s │ \$1.24 │ 💤AFK" ] \
    || fail "canonical fields, order, fleet counts, or formatting drifted: $out"
  pass "status bar: canonical field order and fleet projection are stable"
}

test_threshold_colors_and_placeholders() {
  local out
  # Context-used thresholds invert the prior remaining bands: green at/under 70%,
  # yellow at 71-85% (was under 30% remaining), red at 86%+ (was under 15%).
  out=$(render Opus high 70 69 0)
  assert_contains "$out" $'\033[92m🧠70%' "70% context used is not bright green"
  assert_contains "$out" $'\033[92m⚡69%' "69% quota used is not bright green"

  out=$(render Opus high 71 70 0)
  assert_contains "$out" $'\033[93m🧠71%' "71% context used is not bright yellow"
  assert_contains "$out" $'\033[93m⚡70%' "70% quota used is not bright yellow"

  out=$(render Opus high 85 70 0)
  assert_contains "$out" $'\033[93m🧠85%' "85% context used is not bright yellow"

  out=$(render Opus high 86 90 0)
  assert_contains "$out" $'\033[91m🧠86%' "86% context used is not bright red"
  assert_contains "$out" $'\033[91m⚡90%' "90% quota used is not bright red"

  out=$(render Opus high -- -- -- | strip_ansi)
  assert_contains "$out" '🧠-- ⚡--' "unavailable provider metrics do not use canonical placeholders"
  assert_contains "$out" '$--' "unavailable session cost does not use the canonical placeholder"
  pass "status bar: threshold colors and unavailable-metric placeholders are canonical"
}

test_no_watch_is_bright_red_when_missing_or_stale() {
  local out
  rm -f "$HOME_FIX/state/.last-watcher-beat"
  out=$(render Opus high 50 10 0)
  assert_contains "$out" $'\033[91;1m👁 NO-WATCH --' "missing supervision beacon is not a bright-red NO-WATCH alert"

  : > "$HOME_FIX/state/.last-watcher-beat"
  out=$(FM_STATUS_BAR_TEST_BEAT_EPOCH=800 render Opus high 50 10 0)
  assert_contains "$out" $'\033[91;1m👁 NO-WATCH 200s' "stale supervision beacon is not a bright-red NO-WATCH alert"

  out=$(PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS=pi \
    FM_STATUS_BAR_NOW=invalid \
    "$ROOT/bin/fm-status-bar.sh" \
      --adapter pi \
      --model Opus \
      --effort high)
  assert_contains "$out" $'\033[91;1m👁 NO-WATCH --' "unreadable supervision time is not a bright-red NO-WATCH alert"
  pass "status bar: missing and stale supervision are loud NO-WATCH alerts"
}

test_claude_payload_adapter_and_primary_guard() {
  local input out
  input='{"model":{"display_name":"Claude Fable"},"effort":{"level":"high"},"context_window":{"used_percentage":35.2,"remaining_percentage":64.8},"rate_limits":{"five_hour":{"used_percentage":12.9}},"cost":{"total_cost_usd":2.345}}'
  out=$(printf '%s' "$input" | \
    PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS=claude \
    FM_STATUS_BAR_NOW=1000 \
    "$ROOT/bin/fm-status-bar.sh" --adapter claude | strip_ansi)
  assert_contains "$out" '⚓ Claude Fable·high' "Claude adapter did not normalize model and effort"
  assert_contains "$out" '🧠35% ⚡12%' "Claude adapter did not prefer context used over remaining"
  assert_contains "$out" "\$2.35" "Claude adapter did not normalize session cost"

  input='{"model":{"display_name":"Claude Fable"},"effort":{"level":"high"},"context_window":{"remaining_percentage":64.8}}'
  out=$(printf '%s' "$input" | \
    PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS=claude \
    FM_STATUS_BAR_NOW=1000 \
    "$ROOT/bin/fm-status-bar.sh" --adapter claude | strip_ansi)
  assert_contains "$out" '🧠36%' "Claude adapter did not derive context used from remaining when used is absent"

  input='{"model":{"display_name":"Bad\u0007Model"},"effort":{"level":"high"}}'
  out=$(printf '%s' "$input" | \
    PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS=claude \
    FM_STATUS_BAR_NOW=1000 \
    "$ROOT/bin/fm-status-bar.sh" --adapter claude)
  assert_not_contains "$out" $'\a' "Claude model label can inject terminal control bytes"
  assert_contains "$(printf '%s' "$out" | strip_ansi)" '⚓ BadModel·high' \
    "Claude model label was not sanitized without changing its printable text"

  out=$(printf '%s' "$input" | \
    PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS='' \
    FM_STATUS_BAR_NOW=1000 \
    "$ROOT/bin/fm-status-bar.sh" --adapter claude)
  [ -z "$out" ] || fail "Claude status bar rendered outside the guarded primary launcher"
  pass "status bar: Claude payload normalization is guarded to a primary launch"
}

test_follow_mode_exits_when_primary_pane_is_gone() {
  local out count_file="$TMP_ROOT/tmux-count"
  cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$FM_STATUS_BAR_TMUX_COUNT" ] || count=$(<"$FM_STATUS_BAR_TMUX_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$FM_STATUS_BAR_TMUX_COUNT"
if [ "$count" -eq 1 ]; then
  printf '\n'
  exit 0
fi
exit 1
SH
  chmod +x "$FAKEBIN/tmux"
  out=$(PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_FIX" \
    FM_PRIMARY_HARNESS=kimi \
    FM_STATUS_BAR_INTERVAL=0 \
    FM_STATUS_BAR_TMUX_COUNT="$count_file" \
    "$ROOT/bin/fm-status-bar.sh" \
      --adapter kimi \
      --model kimi-code/k3 \
      --effort -- \
      --follow-pane %42)
  assert_not_contains "$out" '⚓' "tmux companion rendered after its primary pane disappeared"
  pass "status bar: tmux companion exits when its exact primary pane is gone"
}

test_tracked_adapter_wiring_and_cursor_boundary() {
  local status_command pi_extension
  status_command=$(jq -r '.statusLine.command // ""' "$ROOT/.claude/settings.json")
  assert_contains "$status_command" "\$CLAUDE_PROJECT_DIR" "Claude status command is not anchored to the tracked project"
  assert_contains "$status_command" 'bin/fm-status-bar.sh --adapter claude' "Claude status command does not use the canonical renderer"
  assert_not_contains "$status_command" "$HOME" "Claude status command writes or depends on the operator-global home"

  pi_extension=$(cat "$ROOT/.pi/extensions/fm-primary-status-bar.ts")
  assert_contains "$pi_extension" 'ctx.ui.setFooter' "Pi adapter does not use the installed custom-footer API"
  assert_contains "$pi_extension" 'truncateToWidth' "Pi adapter is not terminal-width safe"
  assert_contains "$pi_extension" 'bin/fm-status-bar.sh' "Pi adapter does not derive output from the canonical renderer"
  assert_not_contains "$pi_extension" 'setEditorComponent' "Pi adapter replaces native interaction controls"

  assert_grep 'fm-primary-status-bar.ts' "$ROOT/bin/fm-primary.sh" \
    "the guarded primary launcher does not verify the Pi status-bar integration"
  assert_grep 'split-window' "$ROOT/bin/fm-primary.sh" \
    "the guarded primary launcher does not provide Kimi's non-native tmux line"
  assert_grep 'worker-only' "$ROOT/docs/status-bar.md" \
    "the status-bar owner does not preserve Cursor's worker-only boundary"
  assert_grep 'not applicable' "$ROOT/docs/status-bar.md" \
    "the status-bar owner does not state why Cursor has no captain-facing renderer"
  pass "status bar: tracked adapters preserve guarded installation and Cursor's worker-only boundary"
}

test_contract_order_and_fleet_projection
test_threshold_colors_and_placeholders
test_no_watch_is_bright_red_when_missing_or_stale
test_claude_payload_adapter_and_primary_guard
test_follow_mode_exits_when_primary_pane_is_gone
test_tracked_adapter_wiring_and_cursor_boundary
