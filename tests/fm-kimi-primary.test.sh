#!/usr/bin/env bash
# Kimi primary detection and primary/worker role separation regressions.
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

test_worker_set_includes_kimi() {
  local usage
  usage=$(sed -n '1,90p' "$ROOT/bin/fm-spawn.sh")
  assert_contains "$usage" 'claude|codex|opencode|pi|grok|cursor|kimi' \
    "documented verified worker set missing kimi"
  assert_grep "kimi) printf '%s' 'KIMI_CODE_HOME=__KIMIHOME__ kimi --yolo __MODELFLAG__'" \
    "$ROOT/bin/fm-spawn.sh" \
    "fm-spawn missing kimi worker launch template"
  pass "fm-spawn: Kimi is a verified worker while primary detection stays separate"
}

test_stable_primary_marker_wins
test_worker_set_includes_kimi
