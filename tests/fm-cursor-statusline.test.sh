#!/usr/bin/env bash
# Cursor status-line installer: single-key, preference-preserving, reversible.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-cursor-statusline)

seed_config() {  # <dir> [extra-json]
  local dir=$1 extra=${2:-'{}'}
  mkdir -p "$dir"
  jq -n --argjson extra "$extra" \
    '{version: 1, editor: {vimMode: true}, permissions: {allow: ["Shell(ls)"], deny: []},
      hasChangedDefaultModel: true} * $extra' > "$dir/cli-config.json"
}

run_installer() {  # <dir> <subcommand>
  CURSOR_CONFIG_DIR="$1" "$ROOT/bin/fm-cursor-statusline.sh" "$2" 2>&1
}

test_install_is_single_key_and_preserves_preferences() {
  local dir="$TMP_ROOT/plain" before after out
  seed_config "$dir"
  before=$(jq -S -c 'del(.statusLine)' "$dir/cli-config.json")

  out=$(run_installer "$dir" install) || fail "install failed: $out"
  assert_contains "$out" 'installed:' "install did not report success"

  after=$(jq -S -c 'del(.statusLine)' "$dir/cli-config.json")
  [ "$before" = "$after" ] \
    || fail "install changed settings other than statusLine: $before -> $after"

  assert_contains "$(jq -r '.statusLine.type' "$dir/cli-config.json")" 'command' \
    "installed statusLine is not the native command type"
  assert_contains "$(jq -r '.statusLine.command' "$dir/cli-config.json")" 'fm-status-bar.sh --adapter cursor' \
    "installed statusLine does not use the canonical renderer"

  # A backup must exist so the change is reversible outside this tool too.
  [ -n "$(find "$dir" -name 'cli-config.json.fm-backup.*' -print -quit)" ] \
    || fail "install did not leave a backup"
  pass "cursor installer: install adds only statusLine and keeps existing preferences"
}

test_uninstall_restores_the_original_config() {
  local dir="$TMP_ROOT/round" before after
  seed_config "$dir"
  before=$(jq -S -c . "$dir/cli-config.json")
  run_installer "$dir" install >/dev/null || fail "install failed"
  run_installer "$dir" uninstall >/dev/null || fail "uninstall failed"
  after=$(jq -S -c . "$dir/cli-config.json")
  [ "$before" = "$after" ] || fail "uninstall did not restore the config: $before -> $after"
  pass "cursor installer: uninstall restores the original configuration exactly"
}

test_foreign_status_line_is_never_overwritten_or_removed() {
  local dir="$TMP_ROOT/foreign" out
  seed_config "$dir" '{"statusLine": {"type": "command", "command": "/usr/local/bin/someone-else"}}'

  out=$(run_installer "$dir" install) && fail "install overwrote a foreign statusLine"
  assert_contains "$out" 'already has a different statusLine' "install did not explain its refusal"

  out=$(run_installer "$dir" uninstall) && fail "uninstall removed a foreign statusLine"
  assert_contains "$out" 'belongs to something else' "uninstall did not explain its refusal"

  assert_contains "$(jq -r '.statusLine.command' "$dir/cli-config.json")" 'someone-else' \
    "a foreign statusLine was modified"
  pass "cursor installer: a foreign status line is never overwritten or removed"
}

test_foreign_status_line_without_a_command_key_is_still_foreign() {
  local dir out shape before
  # Presence of the key is what makes it somebody else's, not the shape Cursor
  # happens to document today.
  for shape in '{"statusLine": {"type": "builtin", "preset": "compact"}}' \
    '{"statusLine": "compact"}' \
    '{"statusLine": []}'; do
    dir="$TMP_ROOT/foreign-shape-$(printf '%s' "$shape" | cksum | cut -d' ' -f1)"
    seed_config "$dir" "$shape"
    before=$(jq -S -c . "$dir/cli-config.json")

    out=$(run_installer "$dir" install) && fail "install replaced a foreign statusLine shaped as $shape"
    assert_contains "$out" 'already has a different statusLine' "install did not explain its refusal"

    out=$(run_installer "$dir" uninstall) && fail "uninstall removed a foreign statusLine shaped as $shape"
    assert_contains "$out" 'belongs to something else' "uninstall did not explain its refusal"

    out=$(run_installer "$dir" status)
    assert_contains "$out" 'foreign:' "status did not report a foreign statusLine shaped as $shape"

    [ "$(jq -S -c . "$dir/cli-config.json")" = "$before" ] \
      || fail "a foreign statusLine shaped as $shape was modified"
  done
  pass "cursor installer: a statusLine without a command key is still refused in both directions"
}

test_our_key_is_recognised_from_another_checkout() {
  local dir="$TMP_ROOT/other-checkout" out before
  # The key an install from the main checkout leaves behind, seen by an
  # uninstall run from a worktree: same renderer, different absolute path.
  seed_config "$dir" \
    '{"statusLine": {"type": "command", "command": "/elsewhere/firstmate/bin/fm-status-bar.sh --adapter cursor", "updateIntervalMs": 1000}}'
  before=$(jq -S -c 'del(.statusLine)' "$dir/cli-config.json")

  out=$(run_installer "$dir" status)
  assert_contains "$out" 'installed:' "our own key installed from another checkout read as foreign"
  assert_contains "$out" '/elsewhere/firstmate' "status hid which renderer is actually installed"

  out=$(run_installer "$dir" install) || fail "install refused to re-point our own key: $out"
  assert_contains "$(jq -r '.statusLine.command' "$dir/cli-config.json")" "$ROOT/bin/fm-status-bar.sh" \
    "install did not re-point the key at the running checkout"
  [ "$(jq -S -c 'del(.statusLine)' "$dir/cli-config.json")" = "$before" ] \
    || fail "re-pointing the key changed other settings"

  seed_config "$dir" \
    '{"statusLine": {"type": "command", "command": "/elsewhere/firstmate/bin/fm-status-bar.sh --adapter cursor"}}'
  out=$(run_installer "$dir" uninstall) || fail "uninstall refused our own key from another checkout: $out"
  jq -e 'has("statusLine")' "$dir/cli-config.json" >/dev/null 2>&1 \
    && fail "uninstall left our own key behind"
  pass "cursor installer: its own key stays removable when install and uninstall run from different checkouts"
}

test_invalid_or_absent_config_is_refused_not_rewritten() {
  local dir="$TMP_ROOT/invalid" out
  mkdir -p "$dir"
  printf 'not json at all\n' > "$dir/cli-config.json"
  out=$(run_installer "$dir" install) && fail "install rewrote an unparseable config"
  assert_contains "$out" 'not valid JSON' "install did not explain its refusal"
  assert_contains "$(cat "$dir/cli-config.json")" 'not json at all' "an unparseable config was modified"

  out=$(run_installer "$TMP_ROOT/missing" status)
  assert_contains "$out" 'absent:' "status did not report an absent Cursor config"
  pass "cursor installer: an invalid or absent config is refused rather than rewritten"
}

test_install_never_touches_credentials() {
  local dir="$TMP_ROOT/creds"
  seed_config "$dir"
  printf 'SECRET\n' > "$dir/auth-token"
  run_installer "$dir" install >/dev/null || fail "install failed"
  assert_contains "$(cat "$dir/auth-token")" 'SECRET' "installer modified a credential file"
  [ "$(find "$dir" -name 'auth-token*' | wc -l | tr -d ' ')" = 1 ] \
    || fail "installer copied credential material"
  pass "cursor installer: credentials are never read, copied, or modified"
}

test_install_is_single_key_and_preserves_preferences
test_uninstall_restores_the_original_config
test_foreign_status_line_is_never_overwritten_or_removed
test_foreign_status_line_without_a_command_key_is_still_foreign
test_our_key_is_recognised_from_another_checkout
test_invalid_or_absent_config_is_refused_not_rewritten
test_install_never_touches_credentials
