#!/usr/bin/env bash
# Cursor primary detection and worker-boundary regressions.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_stable_primary_marker_wins() {
  local out config
  out=$(FM_PRIMARY_HARNESS=cursor CLAUDECODE=1 "$ROOT/bin/fm-harness.sh")
  [ "$out" = cursor ] || fail "stable Cursor child marker did not win over inherited runtime markers (got $out)"
  config=$(fm_test_tmproot fm-cursor-harness-config)
  mkdir -p "$config"
  printf 'codex\n' > "$config/crew-harness"
  out=$(FM_PRIMARY_HARNESS=cursor FM_CONFIG_OVERRIDE="$config" "$ROOT/bin/fm-harness.sh" crew)
  [ "$out" = codex ] || fail "configured worker runtime was coupled to the Cursor primary (got $out)"
  pass "fm-harness: stable Cursor marker detects the primary while configured worker selection stays separate"
}

test_worker_set_still_includes_cursor() {
  local usage accepted
  usage=$(sed -n '1,90p' "$ROOT/bin/fm-spawn.sh")
  accepted=$(grep -E "^\s+''\|claude\|codex\|opencode\|pi\|grok\|cursor\)" "$ROOT/bin/fm-spawn.sh" || true)
  assert_contains "$usage" 'claude|codex|opencode|pi|grok|cursor' "documented verified worker set lost cursor"
  assert_contains "$accepted" 'cursor' "fm-spawn lost cursor from the accepted worker harness case"
  pass "fm-spawn: Cursor primary support does not remove Cursor workers"
}

test_stable_primary_marker_wins
test_worker_set_still_includes_cursor
