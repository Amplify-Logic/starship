#!/usr/bin/env bash
# Partial Kimi worker certification must not enable fm-spawn dispatch.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

test_kimi_still_refused_from_fm_spawn() {
  local spawn="$ROOT/bin/fm-spawn.sh"
  # kimi must not appear anywhere in fm-spawn, in any spelling
  if grep -inE '\bkimi\b' "$spawn" >/dev/null; then
    fail "partial Kimi worker evidence accidentally entered fm-spawn"
  fi
  # the verified-adapter case lists must keep their known-good shape
  local case_lists
  case_lists=$(grep -cE 'claude\|codex\|opencode\|pi\|grok\|cursor\)' "$spawn" || true)
  [ "$case_lists" -ge 2 ] || \
    fail "fm-spawn verified-adapter case lists changed shape; re-verify kimi stays refused"
  if grep -E '^\s*kimi\)' "$spawn" >/dev/null; then
    fail "fm-spawn launch_template gained a kimi branch on partial evidence"
  fi
  pass "fm-spawn still refuses kimi as a worker"
}

test_kimi_harness_doc_marks_unverified_and_refused() {
  local doc="$ROOT/docs/kimi-harness.md"
  [ -f "$doc" ] || fail "docs/kimi-harness.md missing"
  assert_grep 'UNVERIFIED' "$doc" "partial record lacks UNVERIFIED markers"
  assert_grep '403' "$doc" "partial record omits the 403 quota reason"
  assert_grep 'worker dispatch stays refused' "$doc" \
    "partial record does not state that worker dispatch stays refused"
  assert_grep '0.27.0' "$doc" "partial record omits Kimi 0.27.0"
  assert_grep '2026-07-21' "$doc" "partial record omits the lab date"
  # Must not claim busy/interrupt/turn-end as verified worker facts.
  if grep -iE 'busy-pane signature.*verified live|interrupt of a running turn.*verified live|crewmate turn-end.*verified live' "$doc" >/dev/null; then
    fail "docs/kimi-harness.md claims a mid-turn surface was verified live"
  fi
  pass "docs/kimi-harness.md records partial verify and refuse-dispatch"
}

test_harness_adapters_keeps_kimi_out_of_verified_workers() {
  local skill="$ROOT/.agents/skills/harness-adapters/SKILL.md"
  assert_grep 'Worker dispatch stays refused' "$skill" \
    "harness-adapters does not keep Kimi worker dispatch refused"
  # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
  assert_grep 'The verified WORKER adapters are `claude`, `codex`, `opencode`, `pi`, `grok`, and `cursor`' "$skill" \
    "verified WORKER adapter list unexpectedly changed"
  if grep -E 'The verified WORKER adapters are .*kimi' "$skill" >/dev/null; then
    fail "kimi was added to the verified WORKER adapter list on partial evidence"
  fi
  pass "harness-adapters keeps kimi out of the verified worker set"
}

test_kimi_still_refused_from_fm_spawn
test_kimi_harness_doc_marks_unverified_and_refused
test_harness_adapters_keeps_kimi_out_of_verified_workers
