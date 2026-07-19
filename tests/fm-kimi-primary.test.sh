#!/usr/bin/env bash
# Kimi primary detection and worker-boundary regressions.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_stable_primary_marker_wins() {
  local out config
  out=$(FM_PRIMARY_HARNESS=kimi CLAUDECODE=1 "$ROOT/bin/fm-harness.sh")
  [ "$out" = kimi ] || fail "stable Kimi child marker did not win over inherited runtime markers (got $out)"
  config=$(fm_test_tmproot fm-kimi-harness-config)
  mkdir -p "$config"
  printf 'codex\n' > "$config/crew-harness"
  out=$(FM_PRIMARY_HARNESS=kimi FM_CONFIG_OVERRIDE="$config" "$ROOT/bin/fm-harness.sh" crew)
  [ "$out" = codex ] || fail "configured worker runtime was coupled to the Kimi primary (got $out)"
  pass "fm-harness: stable Kimi marker detects the primary while configured worker selection stays separate"
}

test_worker_set_remains_closed() {
  local usage known
  usage=$(sed -n '1,90p' "$ROOT/bin/fm-spawn.sh")
  known=$(grep '^KNOWN_HARNESSES=' "$ROOT/bin/fm-spawn.sh" || true)
  assert_contains "$usage" 'claude|codex|opencode|pi|grok' "documented verified worker set changed unexpectedly"
  assert_not_contains "$usage" 'claude|codex|opencode|pi|grok|kimi' "Kimi leaked into the documented worker set"
  assert_not_contains "$known" 'kimi' "Kimi leaked into fm-spawn's accepted worker set"
  pass "fm-spawn: Kimi primary support does not accept Kimi workers"
}

test_stable_primary_marker_wins
test_worker_set_remains_closed
